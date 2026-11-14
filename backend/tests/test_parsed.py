"""Rounds parsed on the PC and sent to /v1/parsed: validation, dedupe, version gating, and identical results to the old raw path."""
import copy
import hashlib
import json

import pytest

from app import parsed as P
from .conftest import FIXTURES, RD, UP, auth, sample, upload

REAL = ["ranked_1.rec.json", "ranked_2.rec.json", "quick_1.rec.json", "custom_1.rec.json", "attacker_recorder_site_test.rec.json", "defender_recorder_site_test_1.rec.json"]


def full_round(name: str) -> dict:
    d = json.loads((FIXTURES / name).read_text())
    return d.get("header", d) | ({"matchFeedback": d["matchFeedback"]} if "matchFeedback" in d else {})


def payload(rnd: dict, file: str = "Match-R01.rec", sha: str | None = None, **over) -> dict:
    body = {
        "schema_version": 1,
        "parser_version": "1.2.0",
        "parser": {"name": "r6-dissect", "build": "test"},
        "source": {"sha256": sha or hashlib.sha256(json.dumps(rnd, sort_keys=True).encode()).hexdigest(), "size": 6_000_000, "file": file},
        "round": P.trim_dissect(rnd),
    }
    body.update(over)
    return body


def post(client, body, token=UP):
    return client.post("/v1/parsed", headers=auth(token), content=json.dumps(body))


def result(res):
    return res.json()["results"][0]


# ---------- real rounds are accepted exactly as they are ----------
@pytest.mark.parametrize("name", REAL)
def test_real_dissect_rounds_pass_validation_unchanged(client, name):
    rnd = full_round(name)
    body = payload(rnd)
    r = post(client, body)
    assert r.status_code == 200, r.text
    assert result(r)["status"] == "parsed" and result(r)["matchId"] == rnd["matchID"]
    stored = client.get("/v1/rounds", headers=auth(RD)).json()["rounds"][0]["data"]
    assert stored == P.trim_dissect(rnd), "what is stored is exactly what the PC sent, nothing dropped or invented"


def test_the_new_path_stores_what_the_old_server_side_parse_produced(client):
    """The same replay, once parsed by the server (old path) and once sent as a client payload built from that same parse."""
    assert result(upload(client, "quick_1.rec"))["status"] == "parsed"
    rows = client.get("/v1/rounds", headers=auth(RD)).json()["rounds"]
    old = next(r for r in rows if r["parser"] == "dissect")["data"]
    assert result(post(client, payload(old, sha="a" * 64)))["status"] == "parsed"
    rows = client.get("/v1/rounds", headers=auth(RD)).json()["rounds"]
    new = next(r for r in rows if r["parser"].startswith("client:"))["data"]
    assert new == P.trim_dissect(old), "the new path keeps exactly the fields the apps read"
    assert (new["matchID"], new["roundNumber"]) == (old["matchID"], old["roundNumber"])


# ---------- what must be refused, with a clear reason ----------
def test_auth_is_the_upload_token(client):
    body = payload(full_round(REAL[0]))
    assert client.post("/v1/parsed", content=json.dumps(body)).status_code == 401
    assert post(client, body, token=RD).status_code == 403
    assert post(client, body, token="nope").status_code == 401


def test_the_same_round_twice_is_a_duplicate_and_idempotent(client):
    body = payload(full_round(REAL[0]))
    first = result(post(client, body))
    again = result(post(client, body))
    assert first["status"] == "parsed" and again["status"] == "duplicate" and again["id"] == first["id"]
    assert len(client.get("/v1/rounds", headers=auth(RD)).json()["rounds"]) == 1


def test_an_old_reader_version_is_told_to_update(make):
    c = make(min_parser="1.2.0")
    old = post(c, payload(full_round(REAL[0]), parser_version="1.1.9"))
    assert old.status_code == 426
    j = old.json()
    assert j["error"] == "parser_too_old" and "update your uploader" in j["message"].lower() and "1.2.0" in j["message"] and j["minParser"] == "1.2.0"
    assert post(c, payload(full_round(REAL[0]), parser_version="1.2.0")).status_code == 200
    assert post(c, payload(full_round(REAL[1]), parser_version="2.0.0")).status_code == 200
    assert c.get("/v1/rounds", headers=auth(RD)).json()["rounds"][0]["data"] is not None


def test_a_version_check_comes_before_everything_else(make):
    c = make(min_parser="1.2.0")
    junk = {"schema_version": 1, "parser_version": "1.0.0", "round": "garbage"}
    assert post(c, junk).status_code == 426, "an outdated app is told to update, not shown validation noise"


def test_health_says_what_the_server_wants(make):
    j = make(min_parser="1.2.0").get("/health").json()
    assert j["parsed"] is True and j["minParser"] == "1.2.0" and j["schema"] == 1


@pytest.mark.parametrize("mutate,expect", [
    (lambda b: b.update(schema_version=2), "schema_version"),
    (lambda b: b.update(parser_version="v1"), "parser_version"),
    (lambda b: b["source"].update(sha256="xyz"), "source.sha256"),
    (lambda b: b["source"].update(size=0), "source.size"),
    (lambda b: b["round"].update(matchID="x"), "matchID"),
    (lambda b: b["round"].update(roundNumber=-1), "roundNumber"),
    (lambda b: b["round"].update(roundNumber="3"), "roundNumber"),
    (lambda b: b["round"].update(timestamp="yesterday"), "timestamp"),
    (lambda b: b["round"].update(timestamp="1999-01-01T00:00:00Z"), "plausible"),
    (lambda b: b["round"].update(timestamp="2099-01-01T00:00:00Z"), "plausible"),
    (lambda b: b["round"].update(teams=[b["round"]["teams"][0]]), "exactly 2 teams"),
    (lambda b: b["round"]["teams"][0].update(role="Attack") or b["round"]["teams"][1].update(role="Attack"), "one Attack team and one Defense"),
    (lambda b: b["round"]["teams"][0].update(score=99), "score"),
    (lambda b: b["round"]["teams"][0].update(startingScore=9, score=1), "lower than the starting score"),
    (lambda b: b["round"]["teams"][0].update(won="yes"), "won"),
    (lambda b: b["round"].update(players=[]), "players"),
    (lambda b: b["round"].update(players=b["round"]["players"] * 3), "players"),
    (lambda b: b["round"]["players"][0].update(teamIndex=2), "teamIndex"),
    (lambda b: b["round"]["players"][0].update(username="x" * 41), "longer than 40"),
    (lambda b: b["round"].update(matchFeedback="none"), "matchFeedback"),
    (lambda b: b["round"].update(matchFeedback=[{"type": "Kill", "timeInSeconds": 99999}]), "timeInSeconds"),
    (lambda b: b["round"].update(matchFeedback=[{"type": 5}]), "type"),
    (lambda b: b["round"]["matchFeedback"].__setitem__(0, "str"), "must be an object"),
    (lambda b: (b.pop("round"), b.update(failed={"reason": "x"}), b.update(round={"a": 1})), "exactly one of"),
])
def test_bad_data_is_refused_with_the_reason(client, mutate, expect):
    body = payload(full_round("ranked_1.rec.json"))
    mutate(body)
    r = post(client, body)
    assert r.status_code == 422, r.text
    j = r.json()
    assert j["error"] == "invalid_payload" and any(expect in p for p in j["problems"]) or expect in j["message"], j
    assert client.get("/v1/rounds", headers=auth(RD)).json()["rounds"] == [], "nothing was stored"


def test_not_json_and_wrong_shapes(client):
    assert client.post("/v1/parsed", headers=auth(UP), content=b"not json").status_code == 422
    assert client.post("/v1/parsed", headers=auth(UP), content=b"[1,2,3]").status_code == 422
    assert client.post("/v1/parsed", headers=auth(UP), content=b"{}").status_code == 422


def test_a_very_large_match_is_refused_before_it_costs_anything(client):
    body = payload(full_round("ranked_1.rec.json"))
    body["round"]["matchFeedback"] = [{"type": {"name": "Kill"}, "username": "a", "target": "b", "timeInSeconds": 5}] * 5000
    big = client.post("/v1/parsed", headers=auth(UP), content=json.dumps(body))
    assert big.status_code == 413, "too many bytes: refused while reading"
    body["round"]["matchFeedback"] = [{"type": {"name": "Kill"}, "username": "a", "target": "b"}] * 450
    many = post(client, body)
    assert many.status_code == 422 and "more than 400 events" in many.text
    huge = client.post("/v1/parsed", headers={**auth(UP), "content-length": str(10_000_000)}, content=b"{}")
    assert huge.status_code == 413


def test_extra_fields_are_never_stored(client):
    body = payload(full_round("ranked_1.rec.json"))
    body["round"]["evil"] = "x" * 1000
    body["round"]["players"][0]["secret"] = "x"
    body["round"]["matchFeedback"][0]["junk"] = [1, 2, 3]
    assert post(client, body).status_code == 200
    stored = json.dumps(client.get("/v1/rounds", headers=auth(RD)).json()["rounds"][0]["data"])
    assert "evil" not in stored and "secret" not in stored and "junk" not in stored


def test_real_data_quirks_are_allowed(client):
    """Found in real replays: both teams flagged won, empty player names, a kill target who left."""
    body = payload(full_round("ranked_1.rec.json"))
    for t in body["round"]["teams"]:
        t["won"] = True
    body["round"]["players"][0]["username"] = ""
    body["round"]["matchFeedback"].append({"type": {"name": "Kill"}, "username": body["round"]["players"][1]["username"], "target": "someone_who_left", "headshot": False, "timeInSeconds": 100})
    assert post(client, body).status_code == 200


# ---------- a PC that could not read the file ----------
def test_a_failed_read_is_recorded_with_its_reason_and_shows_on_the_phone(client):
    sha = "b" * 64
    r = post(client, {"schema_version": 1, "parser_version": "1.2.0", "source": {"sha256": sha, "size": 6_000_000, "file": "Match-R03.rec"}, "failed": {"reason": "panic: role unknown for operator ID 123"}})
    assert r.status_code == 200 and result(r)["status"] == "failed"
    item = client.get("/v1/rounds", headers=auth(RD)).json()["rounds"][0]
    assert item["status"] == "failed" and "role unknown" in item["error"] and item["data"] is None
    k = client.post("/v1/known", headers=auth(UP), json={"hashes": [sha, "c" * 64]}).json()
    assert k == {"known": [sha], "failed": [sha]}, "a newer reader can see it is worth another try"


def test_a_newer_reader_replaces_an_earlier_failure_and_phones_see_it(client):
    rnd = full_round("ranked_1.rec.json")
    sha = "d" * 64
    post(client, {"schema_version": 1, "parser_version": "1.2.0", "source": {"sha256": sha, "size": 6_000_000, "file": "R1.rec"}, "failed": {"reason": "unknown operator"}})
    cursor = client.get("/v1/rounds", headers=auth(RD)).json()["nextCursor"]
    better = result(post(client, payload(rnd, sha=sha, parser_version="1.3.0")))
    assert better["status"] == "parsed" and better["replaced"] is True
    later = client.get(f"/v1/rounds?after={cursor}", headers=auth(RD)).json()["rounds"]
    assert len(later) == 1 and later[0]["status"] == "parsed" and later[0]["data"]["matchID"] == rnd["matchID"]
    assert result(post(client, payload(rnd, sha=sha, parser_version="1.3.0")))["status"] == "duplicate"


def test_a_raw_failure_is_also_replaced_and_its_rec_is_released(make, settings):
    c = make()
    rid = result(upload(c, "corrupted.rec"))["id"]
    assert len(list(settings.rec_dir.glob("*.rec"))) == 1
    sha = hashlib.sha256(sample("corrupted.rec")).hexdigest()
    assert result(post(c, payload(full_round("ranked_1.rec.json"), sha=sha)))["id"] == rid
    assert list(settings.rec_dir.glob("*.rec")) == [], "the big file is gone once the PC delivers the analysis"


# ---------- the old path stays, marked deprecated ----------
def test_raw_upload_still_works_and_says_it_is_deprecated(client):
    r = upload(client, "quick_1.rec")
    assert result(r)["status"] == "parsed"
    assert r.headers["deprecation"] == "true" and "/v1/parsed" in r.headers["link"]
    raw = client.post("/v1/upload/raw?filename=a.rec", headers=auth(UP), content=sample("ranked_2.rec"))
    assert raw.status_code == 200 and raw.headers["deprecation"] == "true"
    assert "deprecation" not in {k.lower() for k in client.get("/v1/stats", headers=auth(RD)).headers}


def test_known_still_answers_old_uploaders(client):
    sha = hashlib.sha256(sample("quick_1.rec")).hexdigest()
    upload(client, "quick_1.rec")
    j = client.post("/v1/known", headers=auth(UP), json={"hashes": [sha]}).json()
    assert j["known"] == [sha], "the original field is unchanged"


def test_tokens_never_appear_in_responses_or_errors(client):
    body = payload(full_round("ranked_1.rec.json"))
    for resp in (post(client, body), post(client, {"x": 1}), post(client, body, token=RD)):
        assert UP not in resp.text and RD not in resp.text


# ---------- fields added in uploader 1.3.0 ----------
def test_spawn_overtime_and_season_are_kept(client):
    rnd = full_round("ranked_1.rec.json")
    body = payload(rnd)
    assert body["round"]["gameVersion"] == rnd["gameVersion"] and "overtimeRoundNumber" in body["round"]
    assert any("spawn" in p for p in body["round"]["players"])
    assert result(post(client, body))["status"] == "parsed"
    stored = client.get("/v1/rounds", headers=auth(RD)).json()["rounds"][0]["data"]
    assert [p.get("spawn") for p in stored["players"]] == [p.get("spawn") for p in rnd["players"]]
    assert stored["roundsPerMatchOvertime"] == rnd["roundsPerMatchOvertime"]


def test_an_older_uploader_without_the_new_fields_is_still_accepted(client):
    body = payload(full_round("ranked_1.rec.json"))
    for k in ("gameVersion", "overtimeRoundNumber", "roundsPerMatchOvertime"):
        body["round"].pop(k)
    for p in body["round"]["players"]:
        p.pop("spawn", None)
    assert result(post(client, body))["status"] == "parsed"


@pytest.mark.parametrize("field,value", [("gameVersion", 5), ("overtimeRoundNumber", -1), ("overtimeRoundNumber", "2")])
def test_the_new_fields_are_checked(client, field, value):
    body = payload(full_round("ranked_1.rec.json"))
    body["round"][field] = value
    assert post(client, body).status_code == 422


def test_a_spawn_must_be_short_text(client):
    body = payload(full_round("ranked_1.rec.json"))
    body["round"]["players"][0]["spawn"] = "x" * 500
    assert post(client, body).status_code == 422
