from __future__ import annotations

import json
from pathlib import Path

from app import parser as parsing
from app.config import load_settings

from .conftest import RD, UP, auth, expected_kills, kills_of, sample, sha, upload

QUICK_MATCH = "06659973-6323-47f3-9024-7df88d907e2a"


def first(res):
    return res.json()["results"][0]


# ---------- access ----------
def test_health_needs_no_token_and_leaks_nothing(client):
    j = client.get("/health").json()
    assert j["ok"] is True and j["dissect"] is True
    assert "token" not in json.dumps(j).lower()


def test_docs_are_not_exposed(client):
    for p in ("/docs", "/redoc", "/openapi.json"):
        assert client.get(p).status_code == 404


def test_endpoints_need_the_right_token(client):
    assert client.post("/v1/upload").status_code == 401  # no token
    assert client.get("/v1/rounds").status_code == 401
    assert client.get("/v1/rounds", headers=auth("wrong")).status_code == 401
    # each token only does its own job
    assert upload(client, "quick_1.rec", token=RD).status_code == 403
    assert client.get("/v1/rounds", headers=auth(UP)).status_code == 403
    assert client.post("/v1/ack", headers=auth(UP), json={"ids": [1]}).status_code == 403
    assert client.delete("/v1/rounds/1", headers=auth(UP)).status_code == 403


def test_x_api_key_header_also_works(client):
    r = client.get("/v1/rounds", headers={"X-Api-Key": RD})
    assert r.status_code == 200


# ---------- upload and parse ----------
def test_real_replay_is_parsed_with_exact_kill_times(client):
    r = first(upload(client, "quick_1.rec"))
    assert r["status"] == "parsed" and r["parser"] == "dissect"
    assert r["matchId"] == QUICK_MATCH and r["round"] == 1
    item = client.get("/v1/rounds", headers=auth(RD)).json()["rounds"][0]
    assert item["recAvailable"] is False and item["status"] == "parsed"   # the analysis is stored, the .rec is already released
    assert kills_of(item["data"]) == expected_kills("quick_1.rec.json")  # same killers, victims, headshots and times


def test_second_real_replay(client):
    r = first(upload(client, "ranked_2.rec"))
    assert r["status"] == "parsed" and r["round"] == 5
    data = client.get("/v1/rounds", headers=auth(RD)).json()["rounds"][0]["data"]
    assert kills_of(data) == expected_kills("ranked_2.rec.json")


def test_replayFiles_field_name_is_accepted_too(client):
    assert first(upload(client, "quick_1.rec", field="replayFiles"))["status"] == "parsed"


def test_raw_octet_stream_upload(client):
    r = client.post("/v1/upload/raw?filename=round1.rec", headers=auth(UP), content=sample("quick_1.rec"))
    assert r.json()["results"][0]["status"] == "parsed"


def test_same_file_twice_is_a_duplicate(client):
    a = first(upload(client, "quick_1.rec"))
    b = first(upload(client, "quick_1.rec"))
    assert b["status"] == "duplicate" and b["id"] == a["id"]
    assert len(client.get("/v1/rounds", headers=auth(RD)).json()["rounds"]) == 1


def test_several_files_in_one_request(client):
    files = [("files", ("a.rec", sample("quick_1.rec"), "application/octet-stream")), ("files", ("b.rec", sample("ranked_2.rec"), "application/octet-stream"))]
    res = client.post("/v1/upload", headers=auth(UP), files=files).json()["results"]
    assert [r["status"] for r in res] == ["parsed", "parsed"]


def test_bad_files_are_rejected_without_being_stored(client, settings):
    assert first(upload(client, "not_zstd.rec"))["status"] == "rejected"
    assert first(upload(client, "empty.rec", data=b""))["status"] == "rejected"
    assert first(upload(client, "text.rec", data=b"hello world, not a replay"))["status"] == "rejected"
    assert list(settings.rec_dir.glob("*.rec")) == []
    assert list(settings.tmp_dir.glob("*")) == [], "temporary files must be cleaned up"


def test_oversized_file_is_rejected(make):
    c = make(max_file_bytes=1024 * 1024)
    r = first(upload(c, "quick_1.rec"))
    assert r["status"] == "rejected" and "larger" in r["error"]


def test_too_many_files(make):
    c = make(max_files_per_request=1)
    files = [("files", ("a.rec", sample("quick_1.rec"), "x")), ("files", ("b.rec", sample("ranked_2.rec"), "x"))]
    assert c.post("/v1/upload", headers=auth(UP), files=files).status_code == 413


def test_no_files_is_a_clear_400(client):
    assert client.post("/v1/upload", headers=auth(UP), data={"x": "y"}).status_code == 400


def test_storage_limit(make):
    c = make(max_storage_bytes=1024 * 1024)
    r = first(upload(c, "quick_1.rec"))
    assert r["status"] == "rejected" and "storage" in r["error"].lower()


def test_hostile_file_names_cannot_escape_the_data_folder(client, settings):
    r = client.post("/v1/upload", headers=auth(UP), files={"files": ("../../../etc/evil.rec", sample("quick_1.rec"), "x")}).json()["results"][0]
    assert ".." not in r["filename"] and "/" not in r["filename"]
    assert all(p.parent == settings.rec_dir for p in settings.rec_dir.glob("*"))


def test_corrupted_replay_fails_cleanly_and_keeps_the_file(client, settings):
    r = first(upload(client, "corrupted.rec"))
    assert r["status"] == "failed" and r["error"]
    item = client.get("/v1/rounds", headers=auth(RD)).json()["rounds"][0]
    assert item["status"] == "failed" and item["data"] is None and item["recAvailable"] is True


# ---------- the phone's side ----------
def test_pagination_with_a_cursor(client):
    upload(client, "quick_1.rec")
    upload(client, "ranked_2.rec")
    p1 = client.get("/v1/rounds?limit=1", headers=auth(RD)).json()
    assert len(p1["rounds"]) == 1 and p1["hasMore"] is True
    p2 = client.get(f"/v1/rounds?limit=1&after={p1['nextCursor']}", headers=auth(RD)).json()
    assert p2["rounds"][0]["id"] > p1["rounds"][0]["id"] and p2["hasMore"] is False
    p3 = client.get(f"/v1/rounds?after={p2['nextCursor']}", headers=auth(RD)).json()
    assert p3["rounds"] == [] and p3["nextCursor"] == p2["nextCursor"]


def test_a_round_fixed_by_retry_reappears_after_the_phone_already_passed_it(make, monkeypatch):
    c = make()
    bad = first(upload(c, "corrupted.rec"))["id"]
    page = c.get("/v1/rounds", headers=auth(RD)).json()
    cursor = page["nextCursor"]
    assert page["rounds"][0]["status"] == "failed"
    assert c.get(f"/v1/rounds?after={cursor}", headers=auth(RD)).json()["rounds"] == []
    monkeypatch.setattr(parsing, "parse_with_arenyze", lambda s, r, client=None: _fake_arenyze(s, r))
    c2 = make(arenyze_key="key")
    assert c2.post(f"/v1/rounds/{bad}/retry", headers=auth(RD)).json()["status"] == "parsed"
    later = c2.get(f"/v1/rounds?after={cursor}", headers=auth(RD)).json()["rounds"]
    assert [r["id"] for r in later] == [bad] and later[0]["status"] == "parsed", "the phone must see the fix"


def test_download_returns_the_original_bytes(make):
    client = make(keep_rec=True)
    rid = first(upload(client, "quick_1.rec"))["id"]
    r = client.get(f"/v1/rounds/{rid}/rec", headers=auth(RD))
    assert r.status_code == 200 and sha(r.content) == sha(sample("quick_1.rec"))


# ---------- acknowledge and delete ----------
def test_ack_deletes_the_rec_but_keeps_the_data(make, settings):
    client = make(keep_rec=True)
    rid = first(upload(client, "quick_1.rec"))["id"]
    rec = next(settings.rec_dir.glob("*.rec"))
    size = rec.stat().st_size
    res = client.post("/v1/ack", headers=auth(RD), json={"ids": [rid]}).json()
    assert res["results"][0]["result"] == "deleted" and res["freedBytes"] == size
    assert not rec.exists()
    item = client.get("/v1/rounds", headers=auth(RD)).json()["rounds"][0]
    assert item["recAvailable"] is False and item["data"] is not None, "the small parsed data stays available"
    assert client.get(f"/v1/rounds/{rid}/rec", headers=auth(RD)).status_code == 404


def test_ack_is_idempotent_and_handles_unknown_ids(client):
    rid = first(upload(client, "quick_1.rec"))["id"]
    client.post("/v1/ack", headers=auth(RD), json={"ids": [rid]})
    res = client.post("/v1/ack", headers=auth(RD), json={"ids": [rid, rid, 9999]}).json()["results"]
    assert [r["result"] for r in res] == ["alreadyGone", "unknown"]


def test_ack_refuses_to_delete_a_file_that_failed_to_parse(client, settings):
    rid = first(upload(client, "corrupted.rec"))["id"]
    res = client.post("/v1/ack", headers=auth(RD), json={"ids": [rid]}).json()["results"][0]
    assert res["result"] == "refused"
    assert len(list(settings.rec_dir.glob("*.rec"))) == 1, "it is the only copy"
    assert client.delete(f"/v1/rounds/{rid}", headers=auth(RD)).status_code == 409
    assert client.delete(f"/v1/rounds/{rid}?force=true", headers=auth(RD)).status_code == 200
    assert list(settings.rec_dir.glob("*.rec")) == []


def test_purge_drops_the_data_and_a_reupload_is_still_ignored(client):
    rid = first(upload(client, "quick_1.rec"))["id"]
    assert client.post("/v1/ack", headers=auth(RD), json={"ids": [rid], "purge": True}).status_code == 200
    assert client.get("/v1/rounds", headers=auth(RD)).json()["rounds"] == []
    again = first(upload(client, "quick_1.rec"))
    assert again["status"] == "duplicate", "the PC re-sending an old file must not bring it back"
    assert client.get("/v1/rounds", headers=auth(RD)).json()["rounds"] == []


def test_ack_validates_its_input(client):
    assert client.post("/v1/ack", headers=auth(RD), json={"ids": []}).status_code == 422
    assert client.post("/v1/ack", headers=auth(RD), json={"ids": list(range(501))}).status_code == 422
    assert client.post("/v1/ack", headers=auth(RD), json={"ids": ["x"]}).status_code == 422


def test_stats_reflect_what_is_stored(client):
    upload(client, "quick_1.rec")
    upload(client, "corrupted.rec")
    s = client.get("/v1/stats", headers=auth(RD)).json()
    assert (s["n"], s["parsed"], s["failed"], s["recs"]) == (2, 1, 1, 1)   # only the failed file still has its .rec
    assert s["rec_bytes"] == len(sample("corrupted.rec"))


# ---------- fallback parser and retry ----------
def _fake_arenyze(settings, rec, client=None):
    return {"header": {"matchID": "arenyze-match", "roundNumber": 3, "map": {"name": "Bank"}}, "matchFeedback": [], "analysis": {"outcome": {}}, "parserEngine": "x"}


def test_arenyze_fallback_is_used_only_when_dissect_fails(make, monkeypatch):
    calls = []
    monkeypatch.setattr(parsing, "parse_with_arenyze", lambda s, r, client=None: (calls.append(1), _fake_arenyze(s, r))[1])
    c = make(arenyze_key="key")
    assert first(upload(c, "quick_1.rec"))["parser"] == "dissect" and calls == []
    bad = first(upload(c, "corrupted.rec"))
    assert bad["status"] == "parsed" and bad["parser"] == "arenyze" and bad["round"] == 3 and calls == [1]


def test_without_a_key_there_is_no_fallback_and_the_reason_is_reported(client):
    err = first(upload(client, "corrupted.rec"))["error"]
    assert "dissect" in err and "arenyze" not in err.split("|")[0]


def test_retry_reparses_a_failed_file(make, monkeypatch):
    c = make()
    rid = first(upload(c, "corrupted.rec"))["id"]
    monkeypatch.setattr(parsing, "parse_with_arenyze", lambda s, r, client=None: _fake_arenyze(s, r))
    again = c.post(f"/v1/rounds/{rid}/retry", headers=auth(RD)).json()
    assert again["status"] == "failed", "still no key configured"
    c2 = make(arenyze_key="key")
    assert c2.post(f"/v1/rounds/{rid}/retry", headers=auth(RD)).json()["status"] == "parsed"


def test_arenyze_rounds_are_trimmed_of_position_data():
    big = {"header": {"matchID": "m"}, "matchFeedback": [], "locationUpdates": [1] * 1000, "positions": [2] * 1000, "runtimeAnalysis": {"x": 1},
           "analysis": {"outcome": {"planted": False}, "shots": [1] * 1000, "players": []}, "parserEngine": "p"}
    t = parsing.trim_arenyze_round(big)
    assert "locationUpdates" not in t and "positions" not in t and "runtimeAnalysis" not in t
    assert set(t["analysis"]) == {"outcome", "players"}


# ---------- housekeeping ----------
def test_old_recs_expire_but_their_data_stays(make, settings):
    c = make(keep_rec=True)
    upload(c, "quick_1.rec")
    c2 = make(rec_retention_days=-1)  # everything uploaded before "tomorrow" is old
    assert list(settings.rec_dir.glob("*.rec")) == []
    item = c2.get("/v1/rounds", headers=auth(RD)).json()["rounds"][0]
    assert item["recAvailable"] is False and item["data"] is not None


def test_tokens_are_generated_once_and_kept(tmp_path):
    env = {"R6_DATA_DIR": str(tmp_path / "d")}
    a, created = load_settings(env)
    b, created2 = load_settings(env)
    assert created is True and created2 is False
    assert (a.upload_token, a.read_token) == (b.upload_token, b.read_token)
    assert a.upload_token != a.read_token and len(a.upload_token) >= 24
    assert oct((tmp_path / "d" / "tokens.json").stat().st_mode)[-3:] == "600"
    c, _ = load_settings({**env, "UPLOAD_TOKEN": "fixed"})
    assert c.upload_token == "fixed" and c.read_token == a.read_token


def test_known_reports_which_fingerprints_the_server_has(client):
    import hashlib
    have = hashlib.sha256(sample("quick_1.rec")).hexdigest()
    missing = hashlib.sha256(b"never uploaded").hexdigest()
    assert client.post("/v1/known", headers=auth(UP), json={"hashes": [have]}).json()["known"] == []
    first(upload(client, "quick_1.rec"))
    r = client.post("/v1/known", headers=auth(UP), json={"hashes": [have.upper(), missing, "not-a-hash"]})
    assert r.json()["known"] == [have]
    ids = client.get("/v1/rounds", headers=auth(RD)).json()["rounds"]
    client.post("/v1/ack", headers=auth(RD), json={"ids": [i["id"] for i in ids], "purge": True})
    assert client.post("/v1/known", headers=auth(UP), json={"hashes": [have]}).json()["known"] == [have], "purged files are still known"


def test_known_needs_the_upload_token(client):
    assert client.post("/v1/known", json={"hashes": []}).status_code == 401
    assert client.post("/v1/known", headers=auth(RD), json={"hashes": []}).status_code == 403


def test_a_plain_dissect_replay_is_accepted_not_rejected(client):
    """Current game versions write .rec files uncompressed, starting with 'dissect'. They must reach the parser."""
    r = first(upload(client, "raw.rec", b"dissect\x00" + b"\x01" * 5000))
    assert r["status"] in ("failed", "parsed"), r   # the parser gets it; this fake body simply cannot be read
    assert "Not a Siege replay" not in str(r)
    assert first(upload(client, "short.rec", b"dissec"))["status"] == "rejected"


def test_dissect_failures_report_the_panic_message_not_the_stack_trace():
    from app.parser import _reason
    trace = "panic: role unknown for operator ID 374667787937\n\ngoroutine 1 [running]:\nmain.main()\n\t/github/workspace/main.go:68 +0x3a5\n"
    assert _reason(trace).startswith("panic: role unknown for operator ID 374667787937")
    assert "update r6-dissect" in _reason(trace)
    assert "main.go" not in _reason(trace)
    assert _reason("") == "r6-dissect failed"


def test_the_rec_is_deleted_as_soon_as_its_analysis_is_stored(client, settings):
    r = first(upload(client, "quick_1.rec"))
    assert r["status"] == "parsed"
    assert list(settings.rec_dir.glob("*.rec")) == [], "the big file is gone, only the small analysis stays"
    item = client.get("/v1/rounds", headers=auth(RD)).json()["rounds"][0]
    assert item["status"] == "parsed" and item["data"] is not None and item["recAvailable"] is False
    assert first(upload(client, "quick_1.rec"))["status"] == "duplicate", "its fingerprint is kept, so a re-upload is still ignored"
    assert client.get(f"/v1/rounds/{r['id']}/rec", headers=auth(RD)).status_code == 404
    assert client.post("/v1/ack", headers=auth(RD), json={"ids": [r["id"]]}).json()["results"][0]["result"] == "alreadyGone"


def test_a_failed_parse_keeps_its_rec_until_a_retry_succeeds(make, settings, monkeypatch):
    c = make()
    rid = first(upload(c, "corrupted.rec"))["id"]
    assert len(list(settings.rec_dir.glob("*.rec"))) == 1
    monkeypatch.setattr(parsing, "parse_with_arenyze", lambda s, r, client=None: _fake_arenyze(s, r))
    c2 = make(arenyze_key="key")
    assert c2.post(f"/v1/rounds/{rid}/retry", headers=auth(RD)).json()["status"] == "parsed"
    assert list(settings.rec_dir.glob("*.rec")) == [], "once it parses, the file is released"
