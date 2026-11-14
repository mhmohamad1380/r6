"""The public site at the root of r6.cyruson.ir: download links, how it works, and one-time tokens per network address.
The replay backend is a different process on a different port and is not touched by anything here."""
from __future__ import annotations

import hashlib
import ipaddress
import json
import os
import re
import secrets
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from starlette.concurrency import run_in_threadpool

try:
    from .accounts import MAX_PASSWORD, MAX_USERS, MIN_PASSWORD, NAME, Accounts, Throttle
except ImportError:  # run as a plain module in tests
    from app.accounts import MAX_PASSWORD, MAX_USERS, MIN_PASSWORD, NAME, Accounts, Throttle

HERE = Path(__file__).resolve().parent
PUBLIC = HERE.parent / "public"

# Names a visitor may download, with the type each is served as. Nothing else in the folder is reachable.
DOWNLOADS = {
    "r6-coach.apk": "application/vnd.android.package-archive",
    "R6ReplayUploader-windows.zip": "application/zip",
    "R6ReplayUploader-1.1.0-windows7.zip": "application/zip",   # the earlier version, for Windows 7 and 8
}

SECURITY_HEADERS = {
    "Content-Security-Policy": "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "X-Frame-Options": "DENY",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
}


def network_key(host: str) -> str:
    """One visitor is one network address. IPv6 users get a whole /64, so changing the last digits does not count as someone new."""
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return host
    if isinstance(ip, ipaddress.IPv6Address):
        if ip.ipv4_mapped:
            return str(ip.ipv4_mapped)
        return str(ipaddress.ip_network(f"{ip}/64", strict=False).network_address) + "/64"
    return str(ip)


class Issued:
    """Which network addresses already received tokens. Only a salted hash of the address is stored, never the address."""

    def __init__(self, path: Path):
        self.path = path
        self.lock = threading.Lock()
        self.salt_path = path.with_name(path.stem + ".salt")
        path.parent.mkdir(parents=True, exist_ok=True)
        if not self.salt_path.exists():
            self.salt_path.write_text(secrets.token_hex(16))
            self.salt_path.chmod(0o600)
        self.salt = self.salt_path.read_text().strip()
        self.data: dict[str, str] = {}
        self._seen = -1
        self._sync()

    def _sync(self) -> None:
        """Re-read the file when someone (the reset tool) changed it, so no restart is needed."""
        try:
            m = self.path.stat().st_mtime_ns
        except FileNotFoundError:
            self.data, self._seen = {}, -1
            return
        if m != self._seen:
            self.data, self._seen = json.loads(self.path.read_text()), m

    def _h(self, key: str) -> str:
        return hashlib.sha256((self.salt + key).encode()).hexdigest()

    def when(self, key: str) -> str | None:
        with self.lock:
            self._sync()
            return self.data.get(self._h(key))

    def claim(self, key: str) -> bool:
        """True if this address had not received tokens yet; records it. Atomic, so two quick clicks give one set."""
        h = self._h(key)
        with self.lock:
            self._sync()
            if h in self.data:
                return False
            self.data[h] = datetime.now(timezone.utc).isoformat(timespec="seconds")
            self._write()
            return True

    def _write(self) -> None:
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.data))
        tmp.chmod(0o600)
        os.replace(tmp, self.path)
        self._seen = self.path.stat().st_mtime_ns

    def forget(self, key: str) -> bool:
        with self.lock:
            self._sync()
            gone = self.data.pop(self._h(key), None) is not None
            if gone:
                self._write()
            return gone

    def clear(self) -> int:
        with self.lock:
            self._sync()
            n = len(self.data)
            self.data = {}
            self._write()
            return n


COOKIE = "r6s"
TOKEN_OK = re.compile(r"^[\x21-\x7e]{8,200}$")  # printable, no spaces


def backend_get(base: str) -> Callable[[str, str], tuple[int, Any]]:
    """GET on the replay server with a read token. Returns (status, json); status 0 means it could not be reached."""
    def get(path: str, token: str) -> tuple[int, Any]:
        req = urllib.request.Request(base + path, headers={"Authorization": "Bearer " + token, "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, None
        except (OSError, ValueError):
            return 0, None
    return get


def create_app(downloads: Path, tokens_file: Path, state_dir: Path, public_url: str, backend: Callable[[str, str], tuple[int, Any]] | None = None) -> FastAPI:
    app = FastAPI(title="R6 Coach site", docs_url=None, redoc_url=None, openapi_url=None)
    issued = Issued(state_dir / "issued.json")
    accounts = Accounts(state_dir / "accounts.db")
    get_backend = backend or backend_get(os.environ.get("R6_SITE_BACKEND", "http://172.18.0.1:8090"))
    secure_cookie = public_url.startswith("https")
    login_fails, login_fails_ip, signups = Throttle(8, 600), Throttle(30, 600), Throttle(5, 3600)
    replay_cache: dict[str, dict[str, Any]] = {}
    cache_lock = threading.Lock()
    manifest_path = downloads / "manifest.json"

    @app.middleware("http")
    async def headers(request: Request, call_next):
        resp = await call_next(request)
        for k, v in SECURITY_HEADERS.items():
            resp.headers.setdefault(k, v)
        if request.url.path.startswith("/api/"):
            resp.headers["Cache-Control"] = "no-store"
        return resp

    def who(request: Request) -> str:
        return network_key(request.client.host if request.client else "unknown")

    # ----- what can be downloaded -----
    def file_info() -> list[dict[str, Any]]:
        manifest: dict[str, Any] = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
        out = []
        for name in DOWNLOADS:
            p = downloads / name
            if not p.is_file():
                continue
            h = hashlib.sha256()
            with p.open("rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
            out.append({"name": name, "size": p.stat().st_size, "sha256": h.hexdigest(), "updated": datetime.fromtimestamp(p.stat().st_mtime, timezone.utc).date().isoformat(), **manifest.get(name, {})})
        return out

    cache: dict[str, Any] = {}

    @app.get("/api/info")
    def info() -> dict[str, Any]:
        # Hashing a 19 MB file on every visit would be wasteful: recompute only when a file changed.
        sig = tuple((n, (downloads / n).stat().st_mtime_ns if (downloads / n).exists() else 0) for n in DOWNLOADS)
        if cache.get("sig") != sig:
            cache["sig"], cache["files"] = sig, file_info()
        return {"serverUrl": public_url, "files": cache["files"]}

    @app.get("/downloads/{name}")
    def download(name: str) -> Response:
        if name not in DOWNLOADS or not (downloads / name).is_file():
            raise HTTPException(404, "Not found.")
        return FileResponse(downloads / name, media_type=DOWNLOADS[name], filename=name, headers={"Cache-Control": "public, max-age=300"})

    # ----- tokens, once per network address -----
    @app.get("/api/token/status")
    def status(request: Request) -> dict[str, Any]:
        at = issued.when(who(request))
        return {"issued": at is not None, "issuedAt": at}

    @app.post("/api/token")
    def token(request: Request) -> JSONResponse:
        if request.headers.get("x-requested-with") != "r6-site":
            raise HTTPException(400, "Bad request.")  # a plain cross-site form post cannot set this header
        key = who(request)
        try:
            saved = json.loads(tokens_file.read_text())
            upload, read = saved["upload_token"], saved["read_token"]
        except (OSError, KeyError, ValueError):
            raise HTTPException(503, "Tokens are not available right now. Try again later.")
        if not issued.claim(key):
            return JSONResponse(status_code=409, content={"error": "already_issued", "message": "Tokens were already given out to this network address. They are only shown once.", "issuedAt": issued.when(key)})
        return JSONResponse({"uploadToken": upload, "readToken": read, "serverUrl": public_url})


    # ----- accounts -----
    def must_post(request: Request) -> None:
        if request.headers.get("x-requested-with") != "r6-site":
            raise HTTPException(400, "Bad request.")  # a plain cross-site form post cannot set this header

    def start_session(uid: int) -> JSONResponse:
        resp = JSONResponse(me_body(uid))
        resp.set_cookie(COOKIE, accounts.open_session(uid), max_age=30 * 86400, httponly=True, secure=secure_cookie, samesite="strict", path="/")
        return resp

    def me_body(uid: int) -> dict[str, Any]:
        u = accounts.user(uid)
        return {"signedIn": True, "name": u["name"], "hasToken": bool(u["token"]), "tokenHint": ("…" + u["token"][-4:]) if u["token"] else None}

    def current(request: Request) -> int:
        uid = accounts.session_user(request.cookies.get(COOKIE))
        if uid is None:
            raise HTTPException(401, "Please sign in.")
        return uid

    def credentials(body: Any) -> tuple[str, str]:
        if not isinstance(body, dict) or not isinstance(body.get("name"), str) or not isinstance(body.get("password"), str):
            raise HTTPException(400, "Send a name and a password.")
        return body["name"].strip().lower(), body["password"]

    @app.get("/api/account/me")
    def me(request: Request) -> dict[str, Any]:
        uid = accounts.session_user(request.cookies.get(COOKIE))
        return me_body(uid) if uid is not None else {"signedIn": False}

    @app.post("/api/account/signup")
    async def signup(request: Request) -> JSONResponse:
        must_post(request)
        name, password = credentials(await request.json())
        ip = who(request)
        if signups.blocked(ip):
            raise HTTPException(429, "Too many accounts were made from this network. Try again later.")
        if not NAME.match(name):
            raise HTTPException(400, "Pick a name of 3 to 24 letters, numbers, dots, dashes or underscores.")
        if not MIN_PASSWORD <= len(password) <= MAX_PASSWORD:
            raise HTTPException(400, f"The password must have at least {MIN_PASSWORD} characters.")
        if accounts.count() >= MAX_USERS:
            raise HTTPException(503, "Sign-ups are closed right now.")
        uid = accounts.create(name, password)
        if uid is None:
            raise HTTPException(409, "That name is taken. Pick another one.")
        signups.add(ip)
        return start_session(uid)

    @app.post("/api/account/login")
    async def login(request: Request) -> JSONResponse:
        must_post(request)
        name, password = credentials(await request.json())
        ip = who(request)
        if login_fails.blocked(name) or login_fails_ip.blocked(ip):
            raise HTTPException(429, "Too many wrong tries. Wait ten minutes and try again.")
        uid = accounts.check(name, password[:MAX_PASSWORD])
        if uid is None:
            login_fails.add(name)
            login_fails_ip.add(ip)
            raise HTTPException(401, "The name or the password is wrong.")
        login_fails.clear(name)
        return start_session(uid)

    @app.post("/api/account/logout")
    def logout(request: Request) -> JSONResponse:
        must_post(request)
        accounts.close_session(request.cookies.get(COOKIE))
        resp = JSONResponse({"signedIn": False})
        resp.delete_cookie(COOKIE, path="/")
        return resp

    @app.put("/api/account/token")
    async def save_token(request: Request) -> dict[str, Any]:
        must_post(request)
        uid = current(request)
        body = await request.json()
        token = body.get("token", "").strip() if isinstance(body, dict) and isinstance(body.get("token"), str) else ""
        if not TOKEN_OK.match(token):
            raise HTTPException(400, "That does not look like a token. Paste the phone token (the read token) exactly as it was shown.")
        code, _ = await run_in_threadpool(get_backend, "/v1/stats", token)
        if code == 0:
            raise HTTPException(502, "The replay server could not be reached. Try again in a minute.")
        if code in (401, 403):
            raise HTTPException(400, "The replay server did not accept this token. Use the phone token, not the upload token.")
        if code != 200:
            raise HTTPException(502, "The replay server gave an unexpected answer. Try again in a minute.")
        accounts.set_token(uid, token)
        return me_body(uid)

    @app.delete("/api/account/token")
    def remove_token(request: Request) -> dict[str, Any]:
        must_post(request)
        uid = current(request)
        accounts.set_token(uid, None)
        return me_body(uid)

    @app.post("/api/account/delete")
    async def delete_account(request: Request) -> JSONResponse:
        must_post(request)
        uid = current(request)
        body = await request.json()
        u = accounts.user(uid)
        if not isinstance(body, dict) or not isinstance(body.get("password"), str) or accounts.check(u["name"], body["password"][:MAX_PASSWORD]) != uid:
            raise HTTPException(401, "The password is wrong.")
        accounts.delete(uid)
        resp = JSONResponse({"signedIn": False})
        resp.delete_cookie(COOKIE, path="/")
        return resp

    # ----- the replays, fetched with the person's saved token -----
    @app.get("/api/data/rounds")
    def rounds(request: Request) -> dict[str, Any]:
        """Every parsed round the replay server holds for this token. The token never leaves the server; pages are
        fetched once and then only what changed, and a burst of requests within 8 seconds shares one fetch."""
        u = accounts.user(current(request))
        if not u["token"]:
            raise HTTPException(409, "Add your token first.")
        key = hashlib.sha256(u["token"].encode()).hexdigest()
        with cache_lock:
            entry = replay_cache.setdefault(key, {"cursor": 0, "items": {}, "at": 0.0, "lock": threading.Lock()})
            if len(replay_cache) > 50:
                for k in sorted(replay_cache, key=lambda k: replay_cache[k]["at"])[:10]:
                    replay_cache.pop(k, None)
        with entry["lock"]:
            if time.time() - entry["at"] > 8:
                while True:
                    code, page = get_backend(f"/v1/rounds?after={entry['cursor']}&limit=100", u["token"])
                    if code in (401, 403):
                        raise HTTPException(409, "The replay server no longer accepts your saved token. Save a new one.")
                    if code != 200 or not isinstance(page, dict):
                        raise HTTPException(502, "The replay server could not be reached. Try again in a minute.")
                    for it in page.get("rounds", []):
                        entry["items"][it["id"]] = it
                    entry["cursor"] = page.get("nextCursor", entry["cursor"])
                    if not page.get("hasMore"):
                        break
                entry["at"] = time.time()
            items = list(entry["items"].values())
        ok = [{"id": i["id"], "uploadedAt": i["uploadedAt"], "data": i["data"]} for i in items if i.get("status") == "parsed" and i.get("data")]
        return {"rounds": ok, "failed": sum(1 for i in items if i.get("status") == "failed"), "total": len(items)}

    # ----- the page itself -----
    @app.get("/")
    def index() -> FileResponse:
        return FileResponse(PUBLIC / "index.html", media_type="text/html; charset=utf-8", headers={"Cache-Control": "no-cache"})

    @app.get("/account")
    def account_page() -> FileResponse:
        return FileResponse(PUBLIC / "account.html", media_type="text/html; charset=utf-8", headers={"Cache-Control": "no-cache"})

    @app.get("/assets/{name}")
    def asset(name: str) -> FileResponse:
        p = (PUBLIC / name).resolve()
        if p.parent != PUBLIC.resolve() or not p.is_file() or p.suffix == ".html":
            raise HTTPException(404, "Not found.")
        types = {".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".svg": "image/svg+xml", ".png": "image/png"}
        return FileResponse(p, media_type=types.get(p.suffix, "application/octet-stream"), headers={"Cache-Control": "public, max-age=300"})

    @app.get("/favicon.svg")
    def favicon() -> FileResponse:
        return FileResponse(PUBLIC / "favicon.svg", media_type="image/svg+xml", headers={"Cache-Control": "public, max-age=86400"})

    app.state.issued = issued
    return app


def load() -> FastAPI:
    env = os.environ
    return create_app(
        downloads=Path(env.get("R6_SITE_DOWNLOADS", "/opt/r6-site/downloads")),
        tokens_file=Path(env.get("R6_SITE_TOKENS", "/var/lib/r6-replay/tokens.json")),
        state_dir=Path(env.get("R6_SITE_STATE", "/var/lib/r6-site")),
        public_url=env.get("R6_SITE_PUBLIC_URL", "https://r6.cyruson.ir"),
    )
