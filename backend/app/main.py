"""HTTP API. The PC uploads .rec files; the phone lists parsed rounds and acknowledges them,
which deletes the heavy .rec from the server."""
from __future__ import annotations

import hashlib
import hmac
import re
import shutil
import uuid
from pathlib import Path
from typing import Any, AsyncIterator

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

from . import parsed as parsed_rounds
from . import highlights as clip_routes
from . import population as pop
from . import parser as parsing
from .config import Settings
from .store import Store, now, row_to_item

VERSION = "0.1.0"


class KnownBody(BaseModel):
    hashes: list[str] = Field(max_length=2000)  # SHA-256 of .rec files, lowercase hex


class AckBody(BaseModel):
    ids: list[int] = Field(min_length=1, max_length=500)
    purge: bool = False  # also drop the parsed data, keeping only the fingerprint so a re-upload is ignored


def create_app(settings: Settings) -> FastAPI:
    store = Store(settings.db_path)
    app = FastAPI(title="R6 replay server", version=VERSION, docs_url=None, redoc_url=None, openapi_url=None)

    # ----- auth -----
    def token_of(request: Request) -> str | None:
        auth = request.headers.get("authorization", "")
        if auth.lower().startswith("bearer "):
            return auth[7:].strip()
        return request.headers.get("x-api-key")

    def require(request: Request, role: str) -> None:
        got = token_of(request)
        if not got:
            raise HTTPException(401, "Missing token. Send 'Authorization: Bearer <token>'.")
        want, other = (settings.upload_token, settings.read_token) if role == "upload" else (settings.read_token, settings.upload_token)
        if hmac.compare_digest(got, want):
            return
        if hmac.compare_digest(got, other):
            raise HTTPException(403, f"This token cannot do that. It needs the {role} token.")
        raise HTTPException(401, "Invalid token.")

    # ----- housekeeping -----
    def delete_rec(row: Any, purge: bool) -> int:
        freed = 0
        if row["rec_path"]:
            p = Path(row["rec_path"])
            if p.exists():
                freed = p.stat().st_size
                p.unlink()
        fields: dict[str, Any] = {"rec_path": None, "rec_deleted_at": now()}
        if purge:
            fields.update(data=None, status="purged")
        store.update(row["id"], **fields)
        return freed

    def expire_old() -> None:
        for r in store.expired_recs(settings.rec_retention_days):
            note = (r["error"] + " " if r["error"] else "") + "(the .rec was removed after the retention period)"
            p = Path(r["rec_path"])
            p.unlink(missing_ok=True)
            store.update(r["id"], rec_path=None, rec_deleted_at=now(), error=note if r["status"] == "failed" else r["error"])

    def drop_rec_after_parse(rid: int, rec: Path) -> None:
        """The analysis is stored, so the big .rec has done its job. A failed parse keeps its file for a retry."""
        if settings.keep_rec:
            return
        rec.unlink(missing_ok=True)
        store.update(rid, rec_path=None, rec_deleted_at=now())

    def storage_used() -> int:
        return store.stats()["rec_bytes"]

    # ----- ingest -----
    async def ingest(filename: str, chunks: AsyncIterator[bytes]) -> dict[str, Any]:
        name = re.sub(r"[^A-Za-z0-9._ -]", "_", Path(filename).name)[:120] or "replay.rec"
        tmp = settings.tmp_dir / f"{uuid.uuid4().hex}.part"
        sha, size, head = hashlib.sha256(), 0, b""
        try:
            with tmp.open("wb") as out:
                async for chunk in chunks:
                    if len(head) < 8:
                        head = (head + chunk)[:8]
                    size += len(chunk)
                    if size > settings.max_file_bytes:
                        return {"filename": name, "status": "rejected", "error": f"File is larger than {settings.max_file_bytes // 1048576} MB."}
                    sha.update(chunk)
                    out.write(chunk)
            if size == 0 or not parsing.is_replay_header(head):
                return {"filename": name, "status": "rejected", "error": "Not a Siege replay: a .rec file starts with 'dissect' or is zstd-compressed."}
            digest = sha.hexdigest()
            if (old := store.by_sha(digest)) is not None:
                return {"filename": name, "status": "duplicate", "id": old["id"], "parseStatus": old["status"]}
            if storage_used() + size > settings.max_storage_bytes:
                return {"filename": name, "status": "rejected", "error": "Server storage is full. Acknowledge or delete old files first."}
            rec = settings.rec_dir / f"{digest}.rec"
            shutil.move(tmp, rec)
        finally:
            tmp.unlink(missing_ok=True)

        try:
            data, who = await run_in_threadpool(parsing.parse, settings, rec)
            match_id, rnd = parsing.ids_of(data)
            rid = store.insert(sha256=digest, filename=name, size=size, uploaded_at=now(), status="parsed", parser=who, match_id=match_id, round_number=rnd, data=__import__("json").dumps(data), rec_path=str(rec))
            drop_rec_after_parse(rid, rec)
            return {"filename": name, "status": "parsed", "id": rid, "parser": who, "matchId": match_id, "round": rnd}
        except parsing.ParseError as e:
            rid = store.insert(sha256=digest, filename=name, size=size, uploaded_at=now(), status="failed", error=str(e)[:600], rec_path=str(rec))
            return {"filename": name, "status": "failed", "id": rid, "error": str(e)[:600]}

    async def stream_of(upload: Any) -> AsyncIterator[bytes]:
        while chunk := await upload.read(1 << 20):
            yield chunk

    @app.post("/v1/upload")
    async def upload(request: Request) -> JSONResponse:
        """Multipart upload. Send each file in a `files` (or `replayFiles`) field."""
        require(request, "upload")
        cap = settings.max_files_per_request * settings.max_file_bytes + (1 << 20)
        if int(request.headers.get("content-length") or 0) > cap:
            raise HTTPException(413, "Request too large.")
        form = await request.form(max_files=settings.max_files_per_request + 1, max_fields=20)
        files = [v for _, v in form.multi_items() if hasattr(v, "filename") and v.filename]
        if not files:
            raise HTTPException(400, "No files. Send multipart/form-data with each file in a 'files' field.")
        if len(files) > settings.max_files_per_request:
            raise HTTPException(413, f"At most {settings.max_files_per_request} files per request.")
        results = [await ingest(f.filename, stream_of(f)) for f in files]
        await run_in_threadpool(expire_old)
        return JSONResponse({"results": results})

    @app.post("/v1/upload/raw")
    async def upload_raw(request: Request, filename: str = Query("replay.rec", max_length=200)) -> JSONResponse:
        """Raw upload: the request body is the .rec file itself (Content-Type application/octet-stream)."""
        require(request, "upload")
        return JSONResponse({"results": [await ingest(filename, request.stream())]})

    @app.post("/v1/known")
    def known(body: KnownBody, request: Request) -> dict[str, Any]:
        """Which of these file fingerprints the server already has (parsed, failed or purged), so the PC can skip them."""
        require(request, "upload")
        wanted = {h.lower() for h in body.hashes if re.fullmatch(r"[0-9a-fA-F]{64}", h)}
        # `failed` is a subset of `known`: those are stored as failed, so a newer parser may be worth another try.
        return {"known": sorted(store.known(wanted)), "failed": sorted(store.failed(wanted))}

    @app.middleware("http")
    async def deprecate_raw_upload(request: Request, call_next):
        resp = await call_next(request)
        if request.url.path in ("/v1/upload", "/v1/upload/raw"):
            # Still works. New uploaders read the .rec on the PC and send small JSON to /v1/parsed instead.
            resp.headers["Deprecation"] = "true"
            resp.headers["Link"] = '</v1/parsed>; rel="successor-version"'
        return resp

    @app.post("/v1/parsed")
    async def upload_parsed(request: Request) -> JSONResponse:
        """One round that the PC already parsed: small JSON instead of a multi-megabyte .rec. Strictly validated, deduped by the .rec's SHA-256."""
        require(request, "upload")
        if int(request.headers.get("content-length") or 0) > parsed_rounds.MAX_BODY_BYTES:
            raise HTTPException(413, f"Too large. A round is a few KB; the limit is {parsed_rounds.MAX_BODY_BYTES // 1024} KB.")
        raw = b""
        async for chunk in request.stream():
            raw += chunk
            if len(raw) > parsed_rounds.MAX_BODY_BYTES:
                raise HTTPException(413, f"Too large. A round is a few KB; the limit is {parsed_rounds.MAX_BODY_BYTES // 1024} KB.")
        try:
            body = __import__("json").loads(raw)
        except ValueError:
            return JSONResponse(status_code=422, content={"error": "invalid_payload", "message": "The body is not valid JSON.", "problems": []})
        minimum = parsed_rounds.parse_version(settings.min_parser) or (0, 0, 0)
        theirs = parsed_rounds.parse_version(body.get("parser_version", "")) if isinstance(body, dict) else None
        if theirs is not None and theirs < minimum:
            return JSONResponse(status_code=426, content={"error": "parser_too_old", "message": f"Please update your uploader: this server needs reader version {settings.min_parser} or newer, and yours is {body['parser_version']}.", "minParser": settings.min_parser})
        try:
            ok = parsed_rounds.validate_payload(body, max_size=settings.max_file_bytes)
        except parsed_rounds.Problems as e:
            return JSONResponse(status_code=422, content={"error": "invalid_payload", "message": "The data did not pass validation: " + "; ".join(e.problems[:3]), "problems": e.problems})
        src = ok["source"]
        name = re.sub(r"[^A-Za-z0-9._ -]", "_", Path(src["file"]).name)[:120] or "replay.rec"
        who = f"client:{ok['parser_version']}"
        old = store.by_sha(src["sha256"])

        if "failed" in ok:
            if old is not None:
                return JSONResponse({"results": [{"filename": name, "status": "duplicate", "id": old["id"], "parseStatus": old["status"]}]})
            rid = store.insert(sha256=src["sha256"], filename=name, size=src["size"], uploaded_at=now(), status="failed", parser=who, error=("The PC could not read this replay: " + ok["failed"])[:600])
            return JSONResponse({"results": [{"filename": name, "status": "failed", "id": rid, "error": ok["failed"]}]})

        data = ok["round"]
        match_id, rnd = parsing.ids_of(data)
        dump = __import__("json").dumps(data, separators=(",", ":"))
        if old is not None and old["status"] == "failed":
            # A newer reader got what an older one could not: replace the failure, and move it to the end of the feed so phones see it.
            if old["rec_path"]:
                Path(old["rec_path"]).unlink(missing_ok=True)
            store.update(old["id"], bump=True, status="parsed", parser=who, error=None, match_id=match_id, round_number=rnd, data=dump, rec_path=None, rec_deleted_at=now())
            return JSONResponse({"results": [{"filename": name, "status": "parsed", "id": old["id"], "parser": who, "matchId": match_id, "round": rnd, "replaced": True}]})
        if old is not None:
            return JSONResponse({"results": [{"filename": name, "status": "duplicate", "id": old["id"], "parseStatus": old["status"]}]})
        rid = store.insert(sha256=src["sha256"], filename=name, size=src["size"], uploaded_at=now(), status="parsed", parser=who, match_id=match_id, round_number=rnd, data=dump, rec_deleted_at=now())
        return JSONResponse({"results": [{"filename": name, "status": "parsed", "id": rid, "parser": who, "matchId": match_id, "round": rnd}]})

    # ----- the phone's side -----
    @app.get("/v1/rounds")
    def rounds(request: Request, after: int = Query(0, ge=0), limit: int = Query(25, ge=1, le=100)) -> dict[str, Any]:
        """Rounds changed since `after`, oldest change first. Pass `nextCursor` as `after` for the next page."""
        require(request, "read")
        rows = store.after(after, limit + 1)
        page = rows[:limit]
        return {"rounds": [row_to_item(r) for r in page], "nextCursor": page[-1]["seq"] if page else after, "hasMore": len(rows) > limit}

    @app.get("/v1/rounds/{rid}/rec")
    def download(rid: int, request: Request) -> FileResponse:
        require(request, "read")
        row = store.get(rid)
        if row is None or not row["rec_path"] or not Path(row["rec_path"]).exists():
            raise HTTPException(404, "That file is not on the server (it may already have been deleted).")
        return FileResponse(row["rec_path"], media_type="application/octet-stream", filename=row["filename"])

    def release(rid: int, purge: bool, force: bool) -> dict[str, Any]:
        row = store.get(rid)
        if row is None:
            return {"id": rid, "result": "unknown"}
        if row["status"] == "failed" and not force:
            return {"id": rid, "result": "refused", "reason": "This file could not be parsed, so the .rec is the only copy. Use force to delete it anyway."}
        had = row["rec_path"] is not None
        freed = delete_rec(row, purge)
        return {"id": rid, "result": "deleted" if had else "alreadyGone", "freedBytes": freed}

    @app.post("/v1/ack")
    def ack(body: AckBody, request: Request) -> dict[str, Any]:
        """The phone confirms it saved these rounds. The server deletes their .rec files."""
        require(request, "read")
        results = [release(i, body.purge, False) for i in dict.fromkeys(body.ids)]
        return {"results": results, "freedBytes": sum(r.get("freedBytes", 0) for r in results)}

    @app.delete("/v1/rounds/{rid}")
    def delete_one(rid: int, request: Request, purge: bool = False, force: bool = False) -> dict[str, Any]:
        require(request, "read")
        r = release(rid, purge, force)
        if r["result"] == "unknown":
            raise HTTPException(404, "No such round.")
        if r["result"] == "refused":
            raise HTTPException(409, r["reason"])
        return r

    @app.post("/v1/rounds/{rid}/retry")
    async def retry(rid: int, request: Request) -> dict[str, Any]:
        """Parse a failed file again, for example after the Arenyze fallback key was added."""
        require(request, "read")
        row = store.get(rid)
        if row is None or not row["rec_path"] or not Path(row["rec_path"]).exists():
            raise HTTPException(404, "The .rec is no longer on the server.")
        try:
            data, who = await run_in_threadpool(parsing.parse, settings, Path(row["rec_path"]))
        except parsing.ParseError as e:
            store.update(rid, status="failed", error=str(e)[:600])
            return {"id": rid, "status": "failed", "error": str(e)[:600]}
        match_id, rnd = parsing.ids_of(data)
        store.update(rid, bump=True, status="parsed", parser=who, error=None, match_id=match_id, round_number=rnd, data=__import__("json").dumps(data))
        drop_rec_after_parse(rid, Path(row["rec_path"]))
        return {"id": rid, "status": "parsed", "parser": who}

    clip_routes.register(app, settings, require)   # highlight clips: /v1/highlights...

    pop_cache: dict[str, Any] = {}

    @app.get("/v1/population")
    def population(request: Request) -> dict[str, Any]:
        """Percentiles of the other players in the stored replays. Recomputed only when a round was added or changed."""
        require(request, "read")
        top, rows = store.parsed_data()
        if pop_cache.get("seq") != top:
            pop_cache["seq"], pop_cache["body"] = top, pop.population(rows)
        return pop_cache["body"]

    @app.get("/v1/stats")
    def stats(request: Request) -> dict[str, Any]:
        require(request, "read")
        return {**store.stats(), "storageLimitBytes": settings.max_storage_bytes}

    @app.get("/health")
    def health() -> dict[str, Any]:
        return {"ok": True, "version": VERSION, "dissect": bool(settings.dissect_bin and settings.dissect_bin.exists()), "arenyzeFallback": bool(settings.arenyze_key), "parsed": True, "population": True, "highlights": True, "schema": parsed_rounds.SCHEMA_VERSION, "minParser": settings.min_parser}

    expire_old()
    return app
