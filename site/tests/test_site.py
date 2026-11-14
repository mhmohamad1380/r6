import json
import re
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.server import create_app, network_key  # noqa: E402

UP, RD = "upload-token-for-tests-aaaaaaaa", "read-token-for-tests-bbbbbbbbbbb"
H = {"X-Requested-With": "r6-site"}


@pytest.fixture
def parts(tmp_path):
    dl = tmp_path / "downloads"
    dl.mkdir()
    (dl / "r6-coach.apk").write_bytes(b"APK" * 1000)
    (dl / "R6ReplayUploader-windows.zip").write_bytes(b"PK" * 500)
    (dl / "R6ReplayUploader-1.1.0-windows7.zip").write_bytes(b"PK" * 300)
    (dl / "secret.txt").write_text("not for visitors")
    (dl / "manifest.json").write_text(json.dumps({"r6-coach.apk": {"version": "1.6.0", "requires": "Android 8 or newer"}}))
    tokens = tmp_path / "tokens.json"
    tokens.write_text(json.dumps({"upload_token": UP, "read_token": RD}))
    return dl, tokens, tmp_path / "state"


def make(parts, ip="203.0.113.7", backend=None):
    dl, tokens, state = parts
    return TestClient(create_app(dl, tokens, state, "https://r6.example.test", backend), base_url="https://r6.example.test", client=(ip, 5000))


def test_the_root_serves_the_page_with_links_and_security_headers(parts):
    r = make(parts).get("/")
    assert r.status_code == 200 and "text/html" in r.headers["content-type"]
    assert "/downloads/r6-coach.apk" in r.text and "/downloads/R6ReplayUploader-windows.zip" in r.text
    assert 'id="tokens"' in r.text and 'id="how"' in r.text
    assert "script-src 'self'" in r.headers["content-security-policy"] and "unsafe-inline" not in r.headers["content-security-policy"]
    assert r.headers["x-content-type-options"] == "nosniff" and r.headers["x-frame-options"] == "DENY"


def test_the_page_uses_nothing_from_other_websites_and_no_inline_code():
    html = (Path(__file__).resolve().parents[1] / "public" / "index.html").read_text()
    assert not re.search(r'(src|href)="https?://', html), "no outside resources"
    assert "style=" not in html and not re.search(r"<script(?![^>]*src=)", html), "the CSP forbids inline style and script"
    css = (Path(__file__).resolve().parents[1] / "public" / "styles.css").read_text()
    assert "@import" not in css and "url(http" not in css


def test_assets_are_served_and_nothing_else_in_the_folder(parts):
    c = make(parts)
    assert c.get("/assets/styles.css").headers["content-type"].startswith("text/css")
    assert c.get("/assets/app.js").headers["content-type"].startswith("text/javascript")
    assert c.get("/favicon.svg").status_code == 200
    assert c.get("/assets/index.html").status_code == 404
    assert c.get("/assets/..%2Fapp%2Fserver.py").status_code == 404
    assert c.get("/assets/%2e%2e/app/server.py").status_code == 404


def test_only_the_two_apps_can_be_downloaded(parts):
    c = make(parts)
    a = c.get("/downloads/r6-coach.apk")
    assert a.status_code == 200 and a.headers["content-type"] == "application/vnd.android.package-archive"
    assert "attachment" in a.headers["content-disposition"] and a.content == b"APK" * 1000
    assert c.get("/downloads/R6ReplayUploader-windows.zip").headers["content-type"] == "application/zip"
    assert c.get("/downloads/R6ReplayUploader-1.1.0-windows7.zip").status_code == 200, "the older build for Windows 7 and 8"
    for bad in ("secret.txt", "manifest.json", "..%2Ftokens.json", "nope.apk"):
        assert c.get(f"/downloads/{bad}").status_code == 404, bad


def test_info_lists_versions_sizes_and_checksums(parts):
    import hashlib

    info = make(parts).get("/api/info").json()
    assert info["serverUrl"] == "https://r6.example.test"
    by = {f["name"]: f for f in info["files"]}
    assert set(by) == {"r6-coach.apk", "R6ReplayUploader-windows.zip", "R6ReplayUploader-1.1.0-windows7.zip"}
    assert by["r6-coach.apk"]["version"] == "1.6.0" and by["r6-coach.apk"]["size"] == 3000
    assert by["r6-coach.apk"]["sha256"] == hashlib.sha256(b"APK" * 1000).hexdigest()


def test_info_notices_a_new_build(parts):
    c = make(parts)
    first = {f["name"]: f["sha256"] for f in c.get("/api/info").json()["files"]}
    import os
    p = parts[0] / "r6-coach.apk"
    p.write_bytes(b"NEWER" * 1000)
    os.utime(p, ns=(2_000_000_000_000_000_000, 2_000_000_000_000_000_000))
    second = {f["name"]: f["sha256"] for f in c.get("/api/info").json()["files"]}
    assert second["r6-coach.apk"] != first["r6-coach.apk"]


def test_a_missing_file_is_left_out_not_an_error(parts):
    (parts[0] / "r6-coach.apk").unlink()
    names = [f["name"] for f in make(parts).get("/api/info").json()["files"]]
    assert names == ["R6ReplayUploader-windows.zip", "R6ReplayUploader-1.1.0-windows7.zip"]


# ---------- tokens ----------
def test_tokens_are_given_once_per_network_address(parts):
    c = make(parts)
    assert c.get("/api/token/status").json()["issued"] is False
    r = c.post("/api/token", headers=H)
    assert r.status_code == 200
    assert r.json() == {"uploadToken": UP, "readToken": RD, "serverUrl": "https://r6.example.test"}
    assert r.headers["cache-control"] == "no-store"
    again = c.post("/api/token", headers=H)
    assert again.status_code == 409 and again.json()["error"] == "already_issued"
    assert UP not in again.text and RD not in again.text, "a second visit never shows them"
    assert c.get("/api/token/status").json()["issued"] is True


def test_a_different_address_gets_its_own_turn(parts):
    assert make(parts, "203.0.113.7").post("/api/token", headers=H).status_code == 200
    assert make(parts, "203.0.113.8").post("/api/token", headers=H).status_code == 200
    assert make(parts, "203.0.113.7").post("/api/token", headers=H).status_code == 409


def test_it_survives_a_restart(parts):
    assert make(parts).post("/api/token", headers=H).status_code == 200
    assert make(parts).post("/api/token", headers=H).status_code == 409, "a new process reads the same record"


def test_ipv6_counts_by_its_64_prefix(parts):
    assert make(parts, "2001:db8:1:2:aaaa::1").post("/api/token", headers=H).status_code == 200
    assert make(parts, "2001:db8:1:2:bbbb::9").post("/api/token", headers=H).status_code == 409, "same /64 is the same household"
    assert make(parts, "2001:db8:1:3::1").post("/api/token", headers=H).status_code == 200
    assert network_key("::ffff:203.0.113.7") == "203.0.113.7"


def test_the_record_holds_only_hashes_never_addresses(parts):
    make(parts, "198.51.100.23").post("/api/token", headers=H)
    stored = (parts[2] / "issued.json").read_text()
    assert "198.51.100.23" not in stored
    assert all(re.fullmatch(r"[0-9a-f]{64}", k) for k in json.loads(stored))
    assert oct((parts[2] / "issued.json").stat().st_mode & 0o777) == "0o600"


def test_a_plain_cross_site_post_is_refused(parts):
    c = make(parts)
    assert c.post("/api/token").status_code == 400
    assert c.get("/api/token/status").json()["issued"] is False, "and it did not use up the turn"


def test_no_tokens_file_is_a_clear_error_and_does_not_use_up_the_turn(parts):
    parts[1].unlink()
    c = make(parts)
    assert c.post("/api/token", headers=H).status_code == 503
    assert c.get("/api/token/status").json()["issued"] is False


def test_two_quick_clicks_give_one_set(parts):
    from concurrent.futures import ThreadPoolExecutor

    c = make(parts)
    with ThreadPoolExecutor(8) as ex:
        codes = sorted(ex.map(lambda _: c.post("/api/token", headers=H).status_code, range(8)))
    assert codes.count(200) == 1 and codes.count(409) == 7


def test_api_answers_are_never_cached(parts):
    c = make(parts)
    for path in ("/api/info", "/api/token/status"):
        assert c.get(path).headers["cache-control"] == "no-store"


def test_the_replay_routes_are_not_part_of_this_service(parts):
    c = make(parts)
    assert c.get("/v1/rounds").status_code == 404 and c.get("/health").status_code == 404


def test_an_address_can_be_freed_without_restarting_the_site(parts):
    from app.server import Issued

    c = make(parts)
    assert c.post("/api/token", headers=H).status_code == 200
    assert c.post("/api/token", headers=H).status_code == 409
    tool = Issued(parts[2] / "issued.json")  # the reset tool is a separate process
    assert tool.forget(network_key("203.0.113.7")) is True and tool.forget(network_key("203.0.113.7")) is False
    assert c.post("/api/token", headers=H).status_code == 200, "the running site noticed"
    assert tool.clear() == 1
    assert c.get("/api/token/status").json()["issued"] is False


# ---------- accounts and the replay view ----------

def item(i, status="parsed", data=True):
    return {"id": i, "seq": i, "uploadedAt": "2026-01-01T00:00:00Z", "status": status, "data": {"matchID": f"m{i}", "roundNumber": 1} if data and status == "parsed" else None}


class FakeBackend:
    """Stands in for the replay server: accepts one read token and serves rounds in pages by cursor."""

    def __init__(self, rows):
        self.rows, self.calls = rows, []

    def __call__(self, path, token):
        self.calls.append(path)
        if token != RD:
            return 401, None
        if path.startswith("/v1/stats"):
            return 200, {"total": len(self.rows)}
        after = int(path.split("after=")[1].split("&")[0])
        limit = int(path.split("limit=")[1])
        rest = [r for r in self.rows if r["seq"] > after]
        page = rest[:limit]
        return 200, {"rounds": page, "nextCursor": page[-1]["seq"] if page else after, "hasMore": len(rest) > limit}


def join(c, name="alex", password="correct horse"):
    return c.post("/api/account/signup", json={"name": name, "password": password}, headers=H)


def test_signing_up_signs_you_in_with_a_cookie_javascript_cannot_read(parts):
    c = make(parts)
    r = join(c)
    assert r.status_code == 200 and r.json() == {"signedIn": True, "name": "alex", "hasToken": False, "tokenHint": None}
    cookie = r.headers["set-cookie"].lower()
    assert "httponly" in cookie and "secure" in cookie and "samesite=strict" in cookie
    assert c.get("/api/account/me").json()["name"] == "alex"


def test_a_visitor_who_is_not_signed_in_is_told_so(parts):
    assert make(parts).get("/api/account/me").json() == {"signedIn": False}
    assert make(parts).get("/api/data/rounds").status_code == 401


def test_sign_up_rules(parts):
    c = make(parts)
    assert c.post("/api/account/signup", json={"name": "alex", "password": "correct horse"}).status_code == 400   # no header
    assert join(c, "ab").status_code == 400
    assert join(c, "bad name!").status_code == 400
    assert join(c, "alex", "short").status_code == 400
    assert join(c, "Alex").status_code == 200              # names are not case sensitive
    assert join(make(parts, "203.0.113.9"), "alex").status_code == 409
    assert c.post("/api/account/signup", content="[]", headers={**H, "content-type": "application/json"}).status_code == 400


def test_passwords_are_not_stored_in_the_clear(parts):
    join(make(parts), password="very secret words")
    raw = b"".join(p.read_bytes() for p in parts[2].glob("accounts.db*"))
    assert b"very secret words" not in raw


def test_login_logout_and_wrong_password(parts):
    c = make(parts)
    join(c)
    c.post("/api/account/logout", headers=H)
    assert c.get("/api/account/me").json() == {"signedIn": False}
    assert c.post("/api/account/login", json={"name": "alex", "password": "nope nope nope"}, headers=H).status_code == 401
    assert c.post("/api/account/login", json={"name": "nobody", "password": "nope nope nope"}, headers=H).status_code == 401
    assert c.post("/api/account/login", json={"name": "ALEX", "password": "correct horse"}, headers=H).status_code == 200
    assert c.get("/api/account/me").json()["signedIn"] is True


def test_guessing_a_password_is_stopped(parts):
    c = make(parts)
    join(c)
    c.post("/api/account/logout", headers=H)
    codes = [c.post("/api/account/login", json={"name": "alex", "password": f"wrong guess {i}"}, headers=H).status_code for i in range(10)]
    assert codes[:8] == [401] * 8 and codes[8:] == [429, 429]
    # even the right password waits, so the limit cannot be used to test guesses
    assert c.post("/api/account/login", json={"name": "alex", "password": "correct horse"}, headers=H).status_code == 429


def test_one_network_cannot_make_accounts_in_bulk(parts):
    c = make(parts)
    codes = [join(c, f"user{i}").status_code for i in range(7)]
    assert codes == [200] * 5 + [429] * 2


def test_saving_a_token_checks_it_with_the_replay_server(parts):
    c = make(parts, backend=FakeBackend([]))
    join(c)
    assert c.put("/api/account/token", json={"token": "short"}, headers=H).status_code == 400
    wrong = c.put("/api/account/token", json={"token": "x" * 30}, headers=H)
    assert wrong.status_code == 400 and "upload token" in wrong.json()["detail"]
    ok = c.put("/api/account/token", json={"token": RD}, headers=H)
    assert ok.status_code == 200 and ok.json()["hasToken"] and ok.json()["tokenHint"] == "…" + RD[-4:]
    assert RD not in c.get("/api/account/me").text
    assert c.delete("/api/account/token", headers=H).json()["hasToken"] is False


def test_an_unreachable_replay_server_is_not_blamed_on_the_token(parts):
    c = make(parts, backend=lambda path, token: (0, None))
    join(c)
    assert c.put("/api/account/token", json={"token": RD}, headers=H).status_code == 502


def test_rounds_need_a_token_and_return_only_what_was_read(parts):
    rows = [item(1), item(2, "failed"), item(3)]
    c = make(parts, backend=FakeBackend(rows))
    join(c)
    assert c.get("/api/data/rounds").status_code == 409
    c.put("/api/account/token", json={"token": RD}, headers=H)
    body = c.get("/api/data/rounds").json()
    assert [r["id"] for r in body["rounds"]] == [1, 3] and body["failed"] == 1 and body["total"] == 3
    assert "token" not in json.dumps(body).lower()


def test_rounds_are_fetched_in_pages_and_then_only_what_changed(parts, monkeypatch):
    be = FakeBackend([item(i) for i in range(1, 251)])
    c = make(parts, backend=be)
    join(c)
    c.put("/api/account/token", json={"token": RD}, headers=H)
    assert len(c.get("/api/data/rounds").json()["rounds"]) == 250
    pages = [p for p in be.calls if p.startswith("/v1/rounds")]
    assert len(pages) == 3                                   # 100 + 100 + 50
    be.rows.append(item(251))
    assert len(c.get("/api/data/rounds").json()["rounds"]) == 250     # within 8 seconds: the same answer, no new fetch
    assert len([p for p in be.calls if p.startswith("/v1/rounds")]) == 3
    import app.server as srv
    real = srv.time.time
    monkeypatch.setattr(srv.time, "time", lambda: real() + 30)
    assert len(c.get("/api/data/rounds").json()["rounds"]) == 251
    assert be.calls[-1].startswith("/v1/rounds?after=250")


def test_a_token_the_server_stopped_accepting_asks_for_a_new_one(parts):
    c = make(parts, backend=FakeBackend([item(1)]))
    join(c)
    c.put("/api/account/token", json={"token": RD}, headers=H)
    c2 = make(parts, backend=lambda path, token: (401, None))
    c2.post("/api/account/login", json={"name": "alex", "password": "correct horse"}, headers=H)
    r = c2.get("/api/data/rounds")
    assert r.status_code == 409 and "save a new one" in r.json()["detail"].lower()


def test_people_do_not_see_each_others_tokens_or_sessions(parts):
    be = FakeBackend([item(1)])
    a, b = make(parts, backend=be), make(parts, "203.0.113.50", backend=be)
    join(a, "alex")
    join(b, "blake")
    a.put("/api/account/token", json={"token": RD}, headers=H)
    assert b.get("/api/account/me").json()["hasToken"] is False
    assert b.get("/api/data/rounds").status_code == 409


def test_deleting_an_account_needs_the_password_and_ends_every_session(parts):
    c = make(parts)
    join(c)
    assert c.post("/api/account/delete", json={"password": "wrong wrong"}, headers=H).status_code == 401
    assert c.post("/api/account/delete", json={"password": "correct horse"}, headers=H).status_code == 200
    assert c.get("/api/account/me").json() == {"signedIn": False}
    assert c.post("/api/account/login", json={"name": "alex", "password": "correct horse"}, headers=H).status_code == 401


def test_the_account_page_is_served_and_html_is_not_an_asset(parts):
    c = make(parts)
    assert c.get("/account").status_code == 200
    assert c.get("/assets/account.html").status_code == 404 and c.get("/assets/index.html").status_code == 404
