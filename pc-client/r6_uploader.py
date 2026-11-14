#!/usr/bin/env python3
"""R6 Replay Uploader: finds Rainbow Six Siege .rec replay files on this PC and sends them to your
replay server, so the phone app can collect them. Standard library only; Python 3.8 or newer.

  python r6_uploader.py setup            first-time setup (server, token, replay folder)
  python r6_uploader.py                  watch the folder and upload new replays (keep it running)
  python r6_uploader.py discover         show where Siege replays were found
  python r6_uploader.py once             upload what is new, then exit
  python r6_uploader.py status           show settings and what has been uploaded
  python r6_uploader.py install-startup  start automatically when you log in to Windows
  python r6_uploader.py remove-startup
"""
from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import re
import ssl
import sys
import time
import urllib.parse
from datetime import datetime
from pathlib import Path

VERSION = "1.0.0"
ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
GAME_DIR = "Tom Clancy's Rainbow Six Siege"
STABLE_SECONDS = 6  # a file must be this old and unchanged: the game may still be writing it
DEFAULT_POLL = 20


def app_dir() -> Path:
    base = os.environ.get("APPDATA") or os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    d = Path(base) / "r6-replay-uploader"
    d.mkdir(parents=True, exist_ok=True)
    return d


CONFIG = app_dir() / "config.json"
STATE = app_dir() / "uploaded.json"


def log(msg: str) -> None:
    print(f"[{datetime.now():%H:%M:%S}] {msg}", flush=True)


# ---------------------------------------------------------------- discovery
def _drives() -> list[Path]:
    if os.name != "nt":
        return [Path("/")]
    return [Path(f"{c}:\\") for c in "CDEFGHIJKLMNOPQRSTUVWXYZ" if Path(f"{c}:\\").exists()]


def _registry_install_dirs() -> list[Path]:
    """Ubisoft Connect records where Siege (game id 635) is installed."""
    out: list[Path] = []
    try:
        import winreg  # type: ignore
    except ImportError:
        return out
    for hive, sub in ((winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs\635"), (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Ubisoft\Launcher\Installs\635")):
        try:
            with winreg.OpenKey(hive, sub) as k:
                out.append(Path(winreg.QueryValueEx(k, "InstallDir")[0]))
        except OSError:
            pass
    return out


def _steam_libraries() -> list[Path]:
    libs: list[Path] = []
    cands = [Path(os.environ.get(v, "")) / "Steam" for v in ("ProgramFiles(x86)", "ProgramFiles") if os.environ.get(v)]
    for steam in cands + [Path.home() / ".steam" / "steam", Path.home() / ".local" / "share" / "Steam"]:
        vdf = steam / "steamapps" / "libraryfolders.vdf"
        libs.append(steam)
        if vdf.exists():
            for m in re.finditer(r'"path"\s+"([^"]+)"', vdf.read_text(errors="ignore")):
                libs.append(Path(m.group(1).replace("\\\\", "\\")))
    return libs


def candidate_folders() -> list[Path]:
    """Places a MatchReplay folder usually is. The game keeps it inside its own install folder."""
    c: list[Path] = []
    for inst in _registry_install_dirs():
        c.append(inst / "MatchReplay")
    for lib in _steam_libraries():
        c.append(lib / "steamapps" / "common" / GAME_DIR / "MatchReplay")
    for d in _drives():
        for rel in (
            Path("Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games") / GAME_DIR,
            Path("Program Files/Ubisoft/Ubisoft Game Launcher/games") / GAME_DIR,
            Path("Ubisoft Game Launcher/games") / GAME_DIR,
            Path("Ubisoft/Ubisoft Game Launcher/games") / GAME_DIR,
            Path("Games/Ubisoft Game Launcher/games") / GAME_DIR,
            Path("Program Files (x86)/Steam/steamapps/common") / GAME_DIR,
            Path("SteamLibrary/steamapps/common") / GAME_DIR,
            Path("Program Files/Epic Games") / GAME_DIR,
        ):
            c.append(d / rel / "MatchReplay")
    seen: set[str] = set()
    return [p for p in c if not (str(p).lower() in seen or seen.add(str(p).lower()))]


def count_rec(folder: Path) -> int:
    try:
        return sum(1 for _ in folder.rglob("*.rec"))
    except OSError:
        return 0


def discover() -> list[tuple[Path, int]]:
    """Existing candidate folders with how many .rec files each holds, most files first."""
    found = [(p, count_rec(p)) for p in candidate_folders() if p.is_dir()]
    return sorted(found, key=lambda t: -t[1])


# ---------------------------------------------------------------- state and config
def load_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def save_json(path: Path, data) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    tmp.replace(path)


def file_key(p: Path) -> str:
    st = p.stat()
    return f"{p}|{st.st_size}|{int(st.st_mtime)}"


def sha256_of(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def is_stable(p: Path, now: float | None = None) -> bool:
    try:
        st = p.stat()
    except OSError:
        return False
    return st.st_size > 0 and ((now or time.time()) - st.st_mtime) >= STABLE_SECONDS


def looks_like_replay(p: Path) -> bool:
    try:
        with p.open("rb") as f:
            return f.read(4) == ZSTD_MAGIC
    except OSError:
        return False


# ---------------------------------------------------------------- talking to the server
class ServerError(Exception):
    pass


def _conn(url: str, timeout: int = 120):
    u = urllib.parse.urlparse(url)
    if u.scheme == "https":
        return http.client.HTTPSConnection(u.hostname, u.port or 443, timeout=timeout, context=ssl.create_default_context()), u
    return http.client.HTTPConnection(u.hostname, u.port or 80, timeout=timeout), u


def normalize_url(url: str) -> str:
    url = url.strip().rstrip("/")
    if url and "://" not in url:
        url = "https://" + url
    return url


def request(url: str, method: str, path: str, token: str | None = None, body=None, headers=None, timeout: int = 120):
    conn, u = _conn(url, timeout)
    h = dict(headers or {})
    if token:
        h["Authorization"] = f"Bearer {token}"
    try:
        conn.request(method, (u.path.rstrip("/") + path), body=body, headers=h)
        r = conn.getresponse()
        data = r.read()
        return r.status, data
    except (OSError, http.client.HTTPException) as e:
        raise ServerError(f"cannot reach the server ({type(e).__name__}: {e})") from e
    finally:
        conn.close()


def check_server(url: str, token: str) -> str:
    """Raises ServerError with a plain explanation, or returns a short success message."""
    status, data = request(url, "GET", "/health", timeout=20)
    if status != 200 or b'"ok"' not in data:
        raise ServerError("that address is not a replay server")
    # An upload request with no files is answered 400 when the token is right, 401/403 when it is not.
    status, _ = request(url, "POST", "/v1/upload", token, body=b"", headers={"Content-Length": "0"}, timeout=20)
    if status == 401:
        raise ServerError("the server does not accept that token")
    if status == 403:
        raise ServerError("that is the READ token (for the phone). The PC needs the UPLOAD token")
    return "connected, and the upload token is accepted"


def upload_file(url: str, token: str, p: Path) -> dict:
    """Streams one .rec to the server's raw upload endpoint and returns its result."""
    size = p.stat().st_size
    conn, u = _conn(url, timeout=600)
    path = u.path.rstrip("/") + "/v1/upload/raw?" + urllib.parse.urlencode({"filename": p.name})
    try:
        conn.putrequest("POST", path)
        conn.putheader("Authorization", f"Bearer {token}")
        conn.putheader("Content-Type", "application/octet-stream")
        conn.putheader("Content-Length", str(size))
        conn.endheaders()
        with p.open("rb") as f:
            while chunk := f.read(1 << 20):
                conn.send(chunk)
        r = conn.getresponse()
        body = r.read()
    except (OSError, http.client.HTTPException) as e:
        raise ServerError(f"upload failed ({type(e).__name__}: {e})") from e
    finally:
        conn.close()
    if r.status == 401 or r.status == 403:
        raise ServerError("the server rejected the upload token")
    if r.status != 200:
        raise ServerError(f"the server answered {r.status}")
    return json.loads(body)["results"][0]


# ---------------------------------------------------------------- the watcher
def scan(folder: Path, state: dict, now: float | None = None) -> list[Path]:
    """New, finished .rec files in the folder, oldest first."""
    out = []
    for p in folder.rglob("*.rec"):
        try:
            key = file_key(p)
        except OSError:
            continue
        if key in state["done"] or not is_stable(p, now):
            continue
        out.append(p)
    return sorted(out, key=lambda p: p.stat().st_mtime)


def sync_once(cfg: dict, state: dict, out=log) -> dict:
    """Uploads everything new. Returns counts. Network problems stop the pass without losing anything."""
    counts = {"parsed": 0, "duplicate": 0, "failed": 0, "rejected": 0, "error": 0}
    folder = Path(cfg["folder"])
    if not folder.is_dir():
        out(f"The replay folder is missing: {folder}")
        return counts
    todo = scan(folder, state)
    if not todo:
        return counts
    try:  # a rejected token is answered at once, which looks like a network error halfway through a big file
        status, _ = request(cfg["server"], "POST", "/v1/upload", cfg["token"], body=b"", headers={"Content-Length": "0"}, timeout=20)
    except ServerError as e:
        counts["error"] += 1
        out(f"Cannot reach the server: {e}. Will try again.")
        return counts
    if status in (401, 403):
        counts["error"] += 1
        out("That is the READ token. The PC needs the UPLOAD token." if status == 403 else "The server rejected the upload token. Check it in the settings.")
        return counts
    for p in todo:
        if not looks_like_replay(p):
            state["done"][file_key(p)] = {"status": "skipped", "at": datetime.now().isoformat(timespec="seconds")}
            continue
        try:
            res = upload_file(cfg["server"], cfg["token"], p)
        except ServerError as e:
            counts["error"] += 1
            out(f"Could not upload {p.name}: {e}. Will try again.")
            break  # the server is probably unreachable: stop this pass and keep the file for next time
        status = res.get("status", "?")
        counts[status] = counts.get(status, 0) + 1
        state["done"][file_key(p)] = {"status": status, "id": res.get("id"), "at": datetime.now().isoformat(timespec="seconds")}
        save_json(STATE, state)
        extra = f" ({res.get('error')})" if res.get("error") else ""
        out(f"{p.name}: {status}{extra}")
    save_json(STATE, state)
    return counts


def load_state() -> dict:
    s = load_json(STATE, {})
    s.setdefault("done", {})
    return s


def need_config() -> dict:
    cfg = load_json(CONFIG, {})
    if not all(cfg.get(k) for k in ("server", "token", "folder")):
        print("Not set up yet. Run:  python r6_uploader.py setup")
        sys.exit(2)
    return cfg


def cmd_setup(args) -> None:
    cfg = load_json(CONFIG, {})
    print("R6 Replay Uploader setup\n")
    server = normalize_url(args.server or input(f"Server address [{cfg.get('server', '')}]: ") or cfg.get("server", ""))
    token = args.token or input("UPLOAD token (not the phone's read token): ").strip() or cfg.get("token", "")
    try:
        print("Checking the server...", check_server(server, token))
    except ServerError as e:
        print(f"\nCould not finish: {e}.")
        sys.exit(1)
    folder = args.folder
    if not folder:
        found = discover()
        if found:
            print("\nReplay folders found:")
            for i, (p, n) in enumerate(found, 1):
                print(f"  {i}. {p}   ({n} replay file{'s' if n != 1 else ''})")
            pick = input(f"Use which one? [1]: ").strip() or "1"
            folder = str(found[int(pick) - 1][0]) if pick.isdigit() and 1 <= int(pick) <= len(found) else pick
        else:
            print("\nNo replay folder found automatically. It is called MatchReplay and sits inside the game's install folder.")
            folder = input("Paste the full path to the MatchReplay folder: ").strip().strip('"')
    if not Path(folder).is_dir():
        print(f"That folder does not exist: {folder}")
        sys.exit(1)
    cfg = {"server": server, "token": token, "folder": folder, "poll_seconds": cfg.get("poll_seconds", DEFAULT_POLL)}
    save_json(CONFIG, cfg)
    n = count_rec(Path(folder))
    print(f"\nSaved. {n} replay file{'s' if n != 1 else ''} already in the folder.")
    if n and not args.yes:
        if (input("Upload those now? [Y/n]: ").strip().lower() or "y") == "n":
            st = load_state()
            for p in Path(folder).rglob("*.rec"):
                st["done"][file_key(p)] = {"status": "skipped", "at": datetime.now().isoformat(timespec="seconds")}
            save_json(STATE, st)
            print("Existing replays will be ignored. Only new ones are uploaded.")
    print("\nStart it with:  python r6_uploader.py\n(or  python r6_uploader.py install-startup  to run it whenever you log in)")


def cmd_run(args) -> None:
    cfg = need_config()
    state = load_state()
    log(f"Watching {cfg['folder']}  ->  {cfg['server']}   (Ctrl+C to stop)")
    while True:
        try:
            sync_once(cfg, state)
        except Exception as e:  # keep running whatever happens in one pass
            log(f"Unexpected problem: {type(e).__name__}: {e}")
        if args.once:
            return
        time.sleep(int(cfg.get("poll_seconds", DEFAULT_POLL)))


def cmd_discover(_args) -> None:
    found = discover()
    if not found:
        print("No MatchReplay folder found. Is Siege installed here, and has it recorded a match?")
        return
    for p, n in found:
        print(f"{p}   ({n} replay file{'s' if n != 1 else ''})")


def cmd_status(_args) -> None:
    cfg = load_json(CONFIG, {})
    st = load_state()
    print(f"Server : {cfg.get('server', '-')}\nFolder : {cfg.get('folder', '-')}\nConfig : {CONFIG}")
    by: dict[str, int] = {}
    for v in st["done"].values():
        by[v["status"]] = by.get(v["status"], 0) + 1
    print("Uploaded:", ", ".join(f"{n} {k}" for k, n in sorted(by.items())) or "nothing yet")


def _startup_file() -> Path:
    return Path(os.environ.get("APPDATA", "")) / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Startup" / "R6 Replay Uploader.bat"


def cmd_install_startup(_args) -> None:
    if os.name != "nt":
        print("Automatic start is for Windows. On other systems, run it from your session's startup.")
        return
    py = Path(sys.executable)
    pyw = py.with_name("pythonw.exe")
    exe = pyw if pyw.exists() else py
    f = _startup_file()
    f.write_text(f'@echo off\r\nstart "" /min "{exe}" "{Path(__file__).resolve()}"\r\n')
    print(f"Done. It will start when you log in to Windows.\n({f})")


def cmd_remove_startup(_args) -> None:
    f = _startup_file()
    if f.exists():
        f.unlink()
        print("Removed from startup.")
    else:
        print("It was not set to start automatically.")


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description="Uploads Rainbow Six Siege replays to your replay server.")
    ap.add_argument("--version", action="version", version=VERSION)
    sub = ap.add_subparsers(dest="cmd")
    s = sub.add_parser("setup")
    s.add_argument("--server"), s.add_argument("--token"), s.add_argument("--folder")
    s.add_argument("--yes", action="store_true", help="upload existing replays without asking")
    s.set_defaults(fn=cmd_setup)
    r = sub.add_parser("run")
    r.add_argument("--once", action="store_true")
    r.set_defaults(fn=cmd_run)
    o = sub.add_parser("once")
    o.set_defaults(fn=lambda a: cmd_run(argparse.Namespace(once=True)))
    for name, fn in (("discover", cmd_discover), ("status", cmd_status), ("install-startup", cmd_install_startup), ("remove-startup", cmd_remove_startup)):
        sub.add_parser(name).set_defaults(fn=fn)
    args = ap.parse_args(argv)
    if not args.cmd:
        args = argparse.Namespace(fn=cmd_run, once=False)
    try:
        args.fn(args)
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
