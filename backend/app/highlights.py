"""Highlight clips: the PC uploads each clip's details and then the video in resumable pieces; the phone lists, plays,
renames, shares and deletes them.

Tokens: the upload token (the PC) creates clips and sends their video; the read token (the phone) does everything else,
the same split as for replays. A share link is a signed URL that plays one clip without a token until it expires;
making the clip private again changes its key, which ends every link to it at once.

Every finished upload is checked to be an MP4 and rewritten with its index first ("fast start"), so a phone can start
playing before the whole file has arrived, whichever encoder made it."""
from __future__ import annotations

import hashlib
import hmac
import json
import re
import secrets
import shutil
import sqlite3
import struct
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterator

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, JSONResponse

SCHEMA = """
CREATE TABLE IF NOT EXISTS highlights (
    id TEXT PRIMARY KEY,
    match_id TEXT NOT NULL,
    meta TEXT NOT NULL,               -- what the PC sent about the moment (validated JSON)
    title TEXT,
    visibility TEXT NOT NULL DEFAULT 'private',   -- private | unlisted (share links work)
    share_key TEXT NOT NULL,
    status TEXT NOT NULL,             -- uploading | ready | failed | deleted
    size INTEGER NOT NULL,            -- bytes the PC said the video has
    received INTEGER NOT NULL DEFAULT 0,
    duration REAL,
    has_thumb INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    seq INTEGER NOT NULL DEFAULT 0    -- changes with every change; the phone's cursor follows it
);
CREATE INDEX IF NOT EXISTS highlights_seq ON highlights(seq);
"""

ID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
TYPES = {"ace", "clutch", "multikill", "entry", "headshot", "kill"}
TAGS = TYPES | {"round_winner"}
MAX_CHUNK = 8 * 1024 * 1024
MAX_THUMB = 1024 * 1024
SHARE_SECONDS = 7 * 24 * 3600


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# ---------------------------------------------------------------- checking what the PC sends

class Bad(Exception):
    pass


def _s(v: Any, name: str, n: int, required: bool = True) -> str | None:
    if v is None and not required:
        return None
    if not isinstance(v, str) or len(v) > n:
        raise Bad(f"{name} must be text of at most {n} characters")
    return v


def _i(v: Any, name: str, lo: int, hi: int) -> int:
    if isinstance(v, bool) or not isinstance(v, int) or not lo <= v <= hi:
        raise Bad(f"{name} must be a whole number from {lo} to {hi}")
    return v


def _f(v: Any, name: str, lo: float, hi: float) -> float:
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not lo <= v <= hi:
        raise Bad(f"{name} must be a number from {lo} to {hi}")
    return float(v)


def _b(v: Any, name: str) -> bool:
    if not isinstance(v, bool):
        raise Bad(f"{name} must be true or false")
    return v


def validate(body: Any, max_size: int) -> dict[str, Any]:
    """The clip's details, rebuilt field by field from what is allowed. Raises Bad."""
    if not isinstance(body, dict):
        raise Bad("the body must be a JSON object")
    hid = _s(body.get("id"), "id", 36)
    if not ID.match(hid or ""):
        raise Bad("id must look like 0123abcd-0000-0000-0000-000000000000")
    t = _s(body.get("type"), "type", 12)
    if t not in TYPES:
        raise Bad("type must be one of " + ", ".join(sorted(TYPES)))
    tags = body.get("tags", [])
    if not isinstance(tags, list) or len(tags) > 8 or any(x not in TAGS for x in tags):
        raise Bad("tags must be a short list of " + ", ".join(sorted(TAGS)))
    kills_in = body.get("kills")
    if not isinstance(kills_in, list) or not 1 <= len(kills_in) <= 10:
        raise Bad("kills must list 1 to 10 kills")
    kills = []
    for i, k in enumerate(kills_in):
        if not isinstance(k, dict):
            raise Bad(f"kills[{i}] must be an object")
        kills.append({
            "t": _f(k.get("t"), f"kills[{i}].t", 0, 600),
            "clock": _i(k.get("clock"), f"kills[{i}].clock", -1, 600),
            "victim": _s(k.get("victim"), f"kills[{i}].victim", 40),
            "victim_operator": _s(k.get("victim_operator", ""), f"kills[{i}].victim_operator", 40),
            "headshot": _b(k.get("headshot"), f"kills[{i}].headshot"),
            "post_plant": _b(k.get("post_plant", False), f"kills[{i}].post_plant"),
        })
    clip = body.get("clip")
    video = body.get("video")
    if not isinstance(clip, dict) or not isinstance(video, dict):
        raise Bad("clip and video are required")
    meta = {
        "id": hid,
        "match_id": _s(body.get("match_id"), "match_id", 64),
        "round": _i(body.get("round"), "round", 1, 60),
        "type": t,
        "tags": tags,
        "score": _i(body.get("score"), "score", 0, 500),
        "clutch_vs": _i(body.get("clutch_vs", 0), "clutch_vs", 0, 5),
        "won": _b(body.get("won"), "won"),
        "side": _s(body.get("side", ""), "side", 12),
        "operator": _s(body.get("operator", ""), "operator", 40),
        "map": _s(body.get("map", ""), "map", 60),
        "mode": _s(body.get("mode", ""), "mode", 40),
        "played_at": _s(body.get("played_at", ""), "played_at", 40),
        "kills": kills,
        "clip": {"from": _f(clip.get("from"), "clip.from", 0, 1200), "to": _f(clip.get("to"), "clip.to", 0, 1200), "approx": _b(clip.get("approx", False), "clip.approx")},
        "video": {"size": _i(video.get("size"), "video.size", 1, max_size), "duration": _f(video.get("duration"), "video.duration", 0.5, 600)},
    }
    if not meta["match_id"]:
        raise Bad("match_id must not be empty")
    title = _s(body.get("title"), "title", 80, required=False)
    if title is not None:
        meta["title"] = title.strip()
    return meta


# ---------------------------------------------------------------- MP4: check, fast start, length

def _boxes(data: bytes, start: int, end: int) -> list[tuple[bytes, int, int]]:
    """(type, offset, size) of the boxes in data[start:end]."""
    out = []
    pos = start
    while pos + 8 <= end:
        size, kind = struct.unpack(">I4s", data[pos:pos + 8])
        if size == 1:
            if pos + 16 > end:
                break
            size = struct.unpack(">Q", data[pos + 8:pos + 16])[0]
        elif size == 0:
            size = end - pos
        if size < 8 or pos + size > end:
            raise ValueError("broken MP4 box")
        out.append((kind, pos, size))
        pos += size
    return out


def _shift_chunk_offsets(moov: bytearray, delta: int) -> None:
    """Adds delta to every chunk offset (stco, co64) inside a moov box, in place."""
    containers = {b"moov", b"trak", b"mdia", b"minf", b"stbl", b"edts", b"dinf", b"udta"}

    def walk(start: int, end: int) -> None:
        for kind, off, size in _boxes(moov, start, end):
            body = off + 8
            if kind in containers:
                walk(body, off + size)
            elif kind == b"stco":
                n = struct.unpack(">I", moov[body + 4:body + 8])[0]
                for i in range(n):
                    p = body + 8 + 4 * i
                    v = struct.unpack(">I", moov[p:p + 4])[0] + delta
                    if v > 0xFFFFFFFF:
                        raise ValueError("clip too large for fast start")
                    moov[p:p + 4] = struct.pack(">I", v)
            elif kind == b"co64":
                n = struct.unpack(">I", moov[body + 4:body + 8])[0]
                for i in range(n):
                    p = body + 8 + 8 * i
                    moov[p:p + 8] = struct.pack(">Q", struct.unpack(">Q", moov[p:p + 8])[0] + delta)

    walk(8, len(moov))


def _duration(moov: bytes) -> float | None:
    for kind, off, size in _boxes(moov, 8, len(moov)):
        if kind == b"mvhd":
            body = off + 8
            version = moov[body]
            if version == 1:
                timescale, dur = struct.unpack(">IQ", moov[body + 20:body + 32])
            else:
                timescale, dur = struct.unpack(">II", moov[body + 12:body + 20])
            return dur / timescale if timescale else None
    return None


def finish_mp4(path: Path) -> float:
    """Checks the file is an MP4, moves its index (moov) before the media (mdat) if needed, and returns its length in
    seconds. Raises ValueError for anything that is not a playable MP4."""
    data = path.read_bytes()
    boxes = _boxes(data, 0, len(data))
    kinds = [b[0] for b in boxes]
    if not boxes or kinds[0] != b"ftyp" or b"moov" not in kinds or b"mdat" not in kinds:
        raise ValueError("not an MP4 video")
    mi = kinds.index(b"moov")
    _, moff, msize = boxes[mi]
    moov = bytearray(data[moff:moff + msize])
    duration = _duration(bytes(moov))
    if mi > kinds.index(b"mdat"):   # index at the end: move it to the front, after ftyp and anything before the media
        _shift_chunk_offsets(moov, msize)
        first_mdat = kinds.index(b"mdat")
        parts = [data[o:o + s] for k, o, s in boxes[:first_mdat]] + [bytes(moov)] + [data[o:o + s] for i, (k, o, s) in enumerate(boxes[first_mdat:], first_mdat) if i != mi]
        tmp = path.with_suffix(".faststart")
        tmp.write_bytes(b"".join(parts))
        tmp.replace(path)
    if duration is None:
        raise ValueError("the MP4 has no length")
    return duration


# ---------------------------------------------------------------- storage

class Clips:
    def __init__(self, db_path: Path, clips_dir: Path, quota: int, max_size: int):
        self.db_path, self.dir, self.quota, self.max_size = db_path, clips_dir, quota, max_size
        self.dir.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()   # one writer at a time for the byte counts
        with self._db() as db:
            db.executescript(SCHEMA)

    @contextmanager
    def _db(self) -> Iterator[sqlite3.Connection]:
        db = sqlite3.connect(self.db_path, timeout=15)
        db.row_factory = sqlite3.Row
        try:
            yield db
            db.commit()
        finally:
            db.close()

    def folder(self, hid: str) -> Path:
        return self.dir / hid

    def get(self, hid: str) -> sqlite3.Row | None:
        with self._db() as db:
            return db.execute("SELECT * FROM highlights WHERE id=?", (hid,)).fetchone()

    def used(self) -> int:
        with self._db() as db:
            return int(db.execute("SELECT COALESCE(SUM(size),0) FROM highlights WHERE status IN ('uploading','ready')").fetchone()[0])

    def _seq(self, db: sqlite3.Connection) -> int:
        return int(db.execute("SELECT COALESCE(MAX(seq),0) FROM highlights").fetchone()[0]) + 1

    def update(self, hid: str, **f: Any) -> None:
        with self._db() as db:
            f["seq"] = self._seq(db)
            f["updated_at"] = now()
            db.execute(f"UPDATE highlights SET {', '.join(k + '=?' for k in f)} WHERE id=?", (*f.values(), hid))

    def create(self, meta: dict[str, Any]) -> sqlite3.Row:
        with self.lock, self._db() as db:
            old = db.execute("SELECT * FROM highlights WHERE id=?", (meta["id"],)).fetchone()
            size = meta["video"]["size"]
            if old is not None and old["status"] == "ready":
                return old   # already here: nothing to send
            free = self.quota - self.used() + (old["size"] if old is not None and old["status"] == "uploading" else 0)
            if size > free:
                raise HTTPException(507, f"The server's clip storage is full ({self.quota // (1024 * 1024)} MB). Delete some clips in the app first.")
            folder = self.folder(meta["id"])
            if old is not None and old["status"] == "uploading" and old["size"] == size:
                return old   # resume where it stopped
            shutil.rmtree(folder, ignore_errors=True)
            folder.mkdir(parents=True)
            stamp = now()
            db.execute(
                "INSERT OR REPLACE INTO highlights(id,match_id,meta,title,visibility,share_key,status,size,received,duration,has_thumb,created_at,updated_at,seq)"
                " VALUES(?,?,?,?,?,?,?,?,0,NULL,0,?,?,?)",
                (meta["id"], meta["match_id"], json.dumps(meta, separators=(",", ":")), meta.get("title"), "private", secrets.token_hex(16), "uploading", size, stamp, stamp, self._seq(db)),
            )
            return db.execute("SELECT * FROM highlights WHERE id=?", (meta["id"],)).fetchone()

    def page(self, after: int, limit: int) -> list[sqlite3.Row]:
        with self._db() as db:
            return db.execute("SELECT * FROM highlights WHERE seq>? AND status IN ('ready','deleted') ORDER BY seq LIMIT ?", (after, limit)).fetchall()


# ---------------------------------------------------------------- the routes

def register(app: FastAPI, settings: Any, require: Callable[[Request, str], None]) -> Clips:
    clips = Clips(settings.db_path, settings.data_dir / "clips", settings.clips_quota_bytes, settings.max_clip_bytes)

    def sign(row: sqlite3.Row, exp: int) -> str:
        return hmac.new(row["share_key"].encode(), f"{row['id']}:{exp}".encode(), hashlib.sha256).hexdigest()

    def must(hid: str, *statuses: str) -> sqlite3.Row:
        row = clips.get(hid) if ID.match(hid) else None
        if row is None or (statuses and row["status"] not in statuses):
            raise HTTPException(404, "No such clip.")
        return row

    def item(row: sqlite3.Row) -> dict[str, Any]:
        if row["status"] == "deleted":
            return {"id": row["id"], "deleted": True, "seq": row["seq"]}
        meta = json.loads(row["meta"])
        meta.pop("video", None)
        return {
            **meta, "title": row["title"], "visibility": row["visibility"], "status": row["status"], "size": row["size"],
            "duration": row["duration"], "createdAt": row["created_at"], "seq": row["seq"],
            "videoUrl": f"/v1/highlights/{row['id']}/video", "thumbnailUrl": f"/v1/highlights/{row['id']}/thumbnail" if row["has_thumb"] else None,
        }

    def may_watch(request: Request, row: sqlite3.Row, exp: int | None, sig: str | None) -> None:
        if exp is not None and sig is not None:
            if row["visibility"] == "unlisted" and exp >= time.time() and hmac.compare_digest(sig, sign(row, exp)):
                return
            raise HTTPException(403, "This link has expired or was turned off.")
        require(request, "read")

    # ----- the PC -----
    @app.post("/v1/highlights")
    async def create(request: Request) -> JSONResponse:
        require(request, "upload")
        try:
            body = json.loads(await request.body())
        except ValueError:
            raise HTTPException(400, "The body is not JSON.")
        try:
            meta = validate(body, clips.max_size)
        except Bad as e:
            raise HTTPException(422, str(e))
        row = clips.create(meta)
        return JSONResponse({"id": row["id"], "status": row["status"], "received": row["received"], "size": row["size"]}, status_code=200 if row["status"] == "ready" else 201)

    @app.get("/v1/highlights/{hid}/upload")
    def upload_state(hid: str, request: Request) -> dict[str, Any]:
        require(request, "upload")
        row = must(hid)
        return {"id": hid, "status": row["status"], "received": row["received"], "size": row["size"]}

    @app.put("/v1/highlights/{hid}/video")
    async def video_piece(hid: str, request: Request, offset: int = Query(..., ge=0)) -> JSONResponse:
        """One piece of the video, starting at `offset`. A piece that does not start where the last one ended is refused
        with the right offset, so an interrupted upload resumes without sending anything twice."""
        require(request, "upload")
        row = must(hid, "uploading")
        if offset != row["received"]:
            return JSONResponse({"error": "wrong_offset", "message": "Continue from the byte the server has.", "received": row["received"]}, status_code=409)
        piece = await request.body()
        if not piece or len(piece) > MAX_CHUNK:
            raise HTTPException(413, f"Send the video in pieces of at most {MAX_CHUNK // (1024 * 1024)} MB.")
        if offset + len(piece) > row["size"]:
            raise HTTPException(400, "That is more than the size given when the clip was created.")
        part = clips.folder(hid) / "video.part"
        with clips.lock:
            row = must(hid, "uploading")
            if offset != row["received"]:   # another request got here first
                return JSONResponse({"error": "wrong_offset", "received": row["received"]}, status_code=409)
            with part.open("r+b" if part.exists() else "wb") as f:
                f.seek(offset)
                f.write(piece)
                f.truncate()
            received = offset + len(piece)
            clips.update(hid, received=received)
        if received < row["size"]:
            return JSONResponse({"id": hid, "status": "uploading", "received": received, "size": row["size"]})
        try:
            duration = finish_mp4(part)
        except (ValueError, struct.error) as e:
            part.unlink(missing_ok=True)
            clips.update(hid, status="failed", received=0)
            raise HTTPException(422, f"The clip is not a playable MP4: {e}")
        part.replace(clips.folder(hid) / "video.mp4")
        clips.update(hid, status="ready", duration=round(duration, 2))
        return JSONResponse({"id": hid, "status": "ready", "received": received, "size": row["size"], "duration": round(duration, 2)})

    @app.put("/v1/highlights/{hid}/thumbnail")
    async def thumbnail(hid: str, request: Request) -> dict[str, Any]:
        require(request, "upload")
        must(hid, "uploading", "ready")
        data = await request.body()
        if len(data) > MAX_THUMB:
            raise HTTPException(413, "The picture is larger than 1 MB.")
        if not data.startswith(b"\xff\xd8\xff"):
            raise HTTPException(422, "The picture must be a JPEG.")
        (clips.folder(hid) / "thumb.jpg").write_bytes(data)
        clips.update(hid, has_thumb=1)
        return {"id": hid, "thumbnail": True}

    # ----- the phone -----
    @app.get("/v1/highlights")
    def list_(request: Request, after: int = Query(0, ge=0), limit: int = Query(50, ge=1, le=200)) -> dict[str, Any]:
        """Clips that changed since `after`, oldest change first. Deleted ones come as {id, deleted: true}."""
        require(request, "read")
        rows = clips.page(after, limit + 1)
        page = rows[:limit]
        return {"highlights": [item(r) for r in page], "nextCursor": page[-1]["seq"] if page else after, "hasMore": len(rows) > limit,
                "storage": {"usedBytes": clips.used(), "quotaBytes": clips.quota}}

    @app.get("/v1/highlights/{hid}")
    def one(hid: str, request: Request) -> dict[str, Any]:
        require(request, "read")
        return item(must(hid, "ready", "uploading"))

    @app.get("/v1/highlights/{hid}/video")
    def video(hid: str, request: Request, exp: int | None = None, sig: str | None = None) -> FileResponse:
        row = must(hid, "ready")
        may_watch(request, row, exp, sig)
        # FileResponse answers Range requests, so players can seek and start before the end arrives.
        return FileResponse(clips.folder(hid) / "video.mp4", media_type="video/mp4", headers={"Cache-Control": "private, max-age=3600"})

    @app.get("/v1/highlights/{hid}/thumbnail")
    def thumb(hid: str, request: Request, exp: int | None = None, sig: str | None = None) -> FileResponse:
        row = must(hid, "ready")
        may_watch(request, row, exp, sig)
        path = clips.folder(hid) / "thumb.jpg"
        if not row["has_thumb"] or not path.exists():
            raise HTTPException(404, "This clip has no picture.")
        return FileResponse(path, media_type="image/jpeg", headers={"Cache-Control": "private, max-age=86400"})

    @app.patch("/v1/highlights/{hid}")
    async def edit(hid: str, request: Request) -> dict[str, Any]:
        require(request, "read")
        row = must(hid, "ready")
        try:
            body = json.loads(await request.body())
        except ValueError:
            raise HTTPException(400, "The body is not JSON.")
        if not isinstance(body, dict):
            raise HTTPException(400, "The body must be a JSON object.")
        changes: dict[str, Any] = {}
        if "title" in body:
            try:
                t = _s(body["title"], "title", 80, required=False)
            except Bad as e:
                raise HTTPException(422, str(e))
            changes["title"] = (t or "").strip() or None
        if "visibility" in body:
            if body["visibility"] not in ("private", "unlisted"):
                raise HTTPException(422, "visibility must be private or unlisted")
            changes["visibility"] = body["visibility"]
            if body["visibility"] == "private":
                changes["share_key"] = secrets.token_hex(16)   # every share link made so far stops working
        if changes:
            clips.update(hid, **changes)
        return item(must(hid))

    @app.post("/v1/highlights/{hid}/share")
    def share(hid: str, request: Request) -> dict[str, Any]:
        """A link that plays this clip for 7 days without a token. Makes the clip unlisted; making it private ends the link."""
        require(request, "read")
        row = must(hid, "ready")
        if row["visibility"] != "unlisted":
            clips.update(hid, visibility="unlisted")
            row = must(hid)
        exp = int(time.time()) + SHARE_SECONDS
        q = f"exp={exp}&sig={sign(row, exp)}"
        return {"id": hid, "expires": datetime.fromtimestamp(exp, timezone.utc).isoformat(timespec="seconds"),
                "videoUrl": f"/v1/highlights/{hid}/video?{q}", "thumbnailUrl": f"/v1/highlights/{hid}/thumbnail?{q}" if row["has_thumb"] else None}

    @app.delete("/v1/highlights/{hid}")
    def delete(hid: str, request: Request) -> dict[str, Any]:
        require(request, "read")
        row = must(hid, "uploading", "ready", "failed")
        shutil.rmtree(clips.folder(hid), ignore_errors=True)
        clips.update(hid, status="deleted", received=0, has_thumb=0)
        return {"id": hid, "deleted": True, "freedBytes": row["size"] if row["status"] == "ready" else row["received"]}

    return clips
