"""The PC uploader, run against a real server over real HTTP with real sample replays."""
from __future__ import annotations

import importlib.util
import json
import os
import socket
import threading
import time
from dataclasses import replace
from pathlib import Path

import pytest
import uvicorn

from app.config import load_settings
from app.main import create_app

from .conftest import RD, UP, auth, sample

CLIENT = Path(__file__).resolve().parents[2] / "pc-client" / "r6_uploader.py"


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Live:
    """A real uvicorn server on localhost that can be stopped and restarted on the same port."""

    def __init__(self, settings):
        self.settings, self.port, self.server, self.thread = settings, free_port(), None, None

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def start(self) -> None:
        cfg = uvicorn.Config(create_app(self.settings), host="127.0.0.1", port=self.port, log_level="error")
        self.server = uvicorn.Server(cfg)
        self.thread = threading.Thread(target=self.server.run, daemon=True)
        self.thread.start()
        for _ in range(100):
            if self.server.started:
                return
            time.sleep(0.05)
        raise RuntimeError("server did not start")

    def stop(self) -> None:
        self.server.should_exit = True
        self.thread.join(5)


@pytest.fixture
def live(settings):
    s = Live(settings)
    s.start()
    yield s
    if s.thread.is_alive():
        s.stop()


@pytest.fixture
def uploader(tmp_path, monkeypatch):
    """The client module, loaded fresh with its own config folder."""
    monkeypatch.setenv("APPDATA", str(tmp_path / "appdata"))
    spec = importlib.util.spec_from_file_location("r6_uploader_under_test", CLIENT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    monkeypatch.setattr(mod, "STABLE_SECONDS", 0.2)
    return mod


def put(folder: Path, name: str, src: str | None = None, data: bytes | None = None, age: float = 30) -> Path:
    p = folder / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data if data is not None else sample(src or "quick_1.rec"))
    t = time.time() - age
    os.utime(p, (t, t))
    return p


def cfg_for(live, folder: Path) -> dict:
    return {"server": live.url, "token": UP, "folder": str(folder)}


# ---------------------------------------------------------------- finding the folder
def test_discovery_lists_folders_with_replay_counts(uploader, tmp_path, monkeypatch):
    a, b = tmp_path / "a" / "MatchReplay", tmp_path / "b" / "MatchReplay"
    put(a / "Match-1", "r1.rec"), put(a / "Match-1", "r2.rec"), put(b, "x.rec")
    monkeypatch.setattr(uploader, "candidate_folders", lambda: [a, b, tmp_path / "missing"])
    assert [(p.name, n) for p, n in uploader.discover()] == [("MatchReplay", 2), ("MatchReplay", 1)]
    assert all(p.is_dir() for p, _ in uploader.discover()), "missing folders are not listed"


def test_the_usual_install_locations_are_all_candidates(uploader):
    text = " ".join(str(p).replace("\\", "/") for p in uploader.candidate_folders())
    for part in ("Ubisoft Game Launcher/games/Tom Clancy's Rainbow Six Siege/MatchReplay", "steamapps/common/Tom Clancy's Rainbow Six Siege/MatchReplay"):
        assert part in text


def test_steam_libraries_on_other_drives_are_found(uploader, tmp_path, monkeypatch):
    steam = tmp_path / "Steam"
    (steam / "steamapps").mkdir(parents=True)
    (steam / "steamapps" / "libraryfolders.vdf").write_text('"libraryfolders"\n{\n "1"\n {\n  "path"  "D:\\\\Games\\\\SteamLib"\n }\n}\n')
    monkeypatch.setenv("ProgramFiles(x86)", str(tmp_path))
    libs = [str(p).replace("\\", "/") for p in uploader._steam_libraries()]
    assert any(p.endswith("D:/Games/SteamLib") for p in libs)


# ---------------------------------------------------------------- when a file is ready
def test_a_file_the_game_is_still_writing_is_not_uploaded_yet(uploader, tmp_path):
    monkeypatch_value = uploader.STABLE_SECONDS
    uploader.STABLE_SECONDS = 6
    try:
        fresh = put(tmp_path, "new.rec", age=1)
        old = put(tmp_path, "old.rec", age=60)
        assert uploader.is_stable(fresh) is False and uploader.is_stable(old) is True
        assert uploader.scan(tmp_path, {"done": {}}) == [old]
    finally:
        uploader.STABLE_SECONDS = monkeypatch_value


def test_scan_skips_what_is_done_and_empty_files(uploader, tmp_path):
    a = put(tmp_path, "a.rec", age=60)
    put(tmp_path, "empty.rec", data=b"", age=60)
    b = put(tmp_path / "Match-2", "b.rec", age=60)
    state = {"done": {uploader.file_key(a): {"status": "parsed"}}}
    assert uploader.scan(tmp_path, state) == [b]


# ---------------------------------------------------------------- talking to the server
def test_token_check_tells_the_two_tokens_apart(uploader, live):
    assert "accepted" in uploader.check_server(live.url, UP)
    with pytest.raises(uploader.ServerError, match="READ token"):
        uploader.check_server(live.url, RD)
    with pytest.raises(uploader.ServerError, match="does not accept"):
        uploader.check_server(live.url, "nonsense")


def test_wrong_address_and_dead_server_are_explained(uploader, live):
    live.stop()
    with pytest.raises(uploader.ServerError, match="cannot reach"):
        uploader.check_server(live.url, UP)


def test_url_tidying(uploader):
    assert uploader.normalize_url(" replays.example.com/ ") == "https://replays.example.com"
    assert uploader.normalize_url("http://10.0.0.5:8090//") == "http://10.0.0.5:8090"


# ---------------------------------------------------------------- the whole flow
def test_backlog_is_uploaded_once_and_the_server_has_exact_data(uploader, live, tmp_path):
    folder = tmp_path / "MatchReplay"
    put(folder / "Match-A", "r1.rec", "quick_1.rec")
    put(folder / "Match-B", "r1.rec", "ranked_2.rec")  # 12 MB: streamed, not read into memory at once
    cfg, state, lines = cfg_for(live, folder), {"done": {}}, []
    counts = uploader.sync_once(cfg, state, out=lines.append)
    assert counts["parsed"] == 2 and counts["error"] == 0
    assert len(lines) == 2 and all("parsed" in l for l in lines)
    # the phone's view of the same server
    from fastapi.testclient import TestClient

    items = TestClient(live.settings and create_app(live.settings)).get("/v1/rounds", headers=auth(RD)).json()["rounds"]
    assert sorted(i["round"] for i in items) == [1, 5]
    assert all(i["parser"] == "dissect" and i["data"] is not None and not i["recAvailable"] for i in items)
    # a second pass has nothing to do and sends nothing
    lines.clear()
    assert uploader.sync_once(cfg, state, out=lines.append) == {"parsed": 0, "duplicate": 0, "failed": 0, "rejected": 0, "error": 0}
    assert lines == []


def test_the_same_replay_under_another_name_is_a_duplicate_not_a_second_round(uploader, live, tmp_path):
    folder = tmp_path / "MatchReplay"
    put(folder, "one.rec", "quick_1.rec")
    put(folder, "copy.rec", "quick_1.rec", age=20)
    counts = uploader.sync_once(cfg_for(live, folder), {"done": {}}, out=lambda m: None)
    assert counts["parsed"] == 1 and counts["duplicate"] == 1


def test_files_that_are_not_replays_never_leave_the_pc(uploader, live, tmp_path):
    folder = tmp_path / "MatchReplay"
    put(folder, "notes.rec", data=b"this is not a replay")
    state = {"done": {}}
    assert uploader.sync_once(cfg_for(live, folder), state, out=lambda m: None) == {"parsed": 0, "duplicate": 0, "failed": 0, "rejected": 0, "error": 0}
    assert list(state["done"].values())[0]["status"] == "skipped"


def test_a_corrupted_replay_is_reported_by_the_server_and_not_retried_forever(uploader, live, tmp_path):
    folder = tmp_path / "MatchReplay"
    put(folder, "bad.rec", "corrupted.rec")
    state, lines = {"done": {}}, []
    assert uploader.sync_once(cfg_for(live, folder), state, out=lines.append)["failed"] == 1
    assert "failed" in lines[0]
    assert uploader.sync_once(cfg_for(live, folder), state, out=lines.append)["failed"] == 0


def test_when_the_server_goes_down_nothing_is_lost_and_it_resumes(uploader, live, tmp_path):
    folder = tmp_path / "MatchReplay"
    put(folder, "r1.rec", "quick_1.rec")
    live.stop()
    state, lines = {"done": {}}, []
    c = uploader.sync_once(cfg_for(live, folder), state, out=lines.append)
    assert c["error"] == 1 and state["done"] == {}, "the file must stay pending"
    assert "Will try again" in lines[0]
    live.start()
    assert uploader.sync_once(cfg_for(live, folder), state, out=lines.append)["parsed"] == 1


def test_a_wrong_token_stops_the_pass_with_a_clear_message(uploader, live, tmp_path):
    folder = tmp_path / "MatchReplay"
    put(folder, "r1.rec", "quick_1.rec")
    lines: list[str] = []
    c = uploader.sync_once({**cfg_for(live, folder), "token": "bad"}, {"done": {}}, out=lines.append)
    assert c["error"] == 1 and "rejected the upload token" in lines[0]


def test_setup_command_saves_a_working_config(uploader, live, tmp_path, capsys):
    folder = tmp_path / "MatchReplay"
    put(folder, "r1.rec", "quick_1.rec")
    uploader.main(["setup", "--server", live.url, "--token", UP, "--folder", str(folder), "--yes"])
    cfg = json.loads(uploader.CONFIG.read_text())
    assert cfg["server"] == live.url and cfg["folder"] == str(folder) and cfg["token"] == UP
    assert "connected, and the upload token is accepted" in capsys.readouterr().out
    uploader.main(["once"])
    assert "parsed" in capsys.readouterr().out
    uploader.main(["status"])
    assert "1 parsed" in capsys.readouterr().out


def test_setup_refuses_a_bad_token_and_saves_nothing(uploader, live, tmp_path):
    with pytest.raises(SystemExit) as e:
        uploader.main(["setup", "--server", live.url, "--token", RD, "--folder", str(tmp_path), "--yes"])
    assert e.value.code == 1
    assert not uploader.CONFIG.exists()
