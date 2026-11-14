"""/v1/population: percentiles of the other players in the stored replays."""
import json

from app import population as pop
from .conftest import RD, UP, auth


def rnd(match, n, kills, recorder="me-profile", won_team=0, ids="id"):
    """Ten players; `kills` is a list of (killer, victim, headshot)."""
    players = [{"username": f"p{i}", "teamIndex": i // 5, "profileID": f"{ids}-{i}"} for i in range(10)]
    players[0]["profileID"] = recorder
    return {
        "matchID": match, "roundNumber": n, "recordingProfileID": recorder, "map": "Bank", "matchType": "Ranked", "timestamp": "2026-10-01T20:00:00Z",
        "teams": [{"role": "Attack", "score": 1, "won": won_team == 0}, {"role": "Defense", "score": 0, "won": won_team == 1}],
        "players": players,
        "matchFeedback": [{"type": {"name": "Kill"}, "username": a, "target": b, "headshot": h, "timeInSeconds": 100 - i} for i, (a, b, h) in enumerate(kills)],
    }


def test_each_player_is_scored_like_the_phone_scores_its_owner():
    r = rnd("m1", 1, [("p1", "p5", True), ("p6", "p1", False), ("p2", "p6", False), ("p8", "p3", False)])
    got = dict(pop.player_rounds(r))
    assert got["id-1"]["kills"] == 1 and got["id-1"]["headshots"] == 1 and got["id-1"]["died"]
    assert got["id-1"]["opening"] == "kill" and got["id-5"]["opening"] == "death"
    assert got["id-1"]["kost"]                      # a kill
    assert got["id-6"]["kost"] is True              # p6 got a kill, then died
    assert got["id-4"]["kost"] and not got["id-4"]["died"]   # survived
    assert got["id-5"]["kost"] is True              # died first, but p6 traded the killer a second later
    assert got["id-3"]["kost"] is False             # died, no kill, nobody answered


def test_a_death_without_a_killer_counts_as_a_death():
    r = rnd("m1", 1, [])
    r["matchFeedback"].append({"type": {"name": "Death"}, "username": "p4", "timeInSeconds": 50})
    assert dict(pop.player_rounds(r))["id-4"]["died"] is True


def test_the_people_who_recorded_are_left_out_and_small_samples_too():
    rows = [json.dumps(rnd(f"m{m}", n, [("p1", "p6", n % 2 == 0)])) for m in range(3) for n in range(6)]
    out = pop.population(rows)
    assert out["rounds"] == 18 and out["players"] == 9      # p0 recorded every round
    rows.append(json.dumps({**rnd("x", 1, []), "players": [{"username": "solo", "teamIndex": 0, "profileID": "once"}]}))
    assert pop.population(rows)["players"] == 9              # one round is not enough


def test_a_metric_with_fewer_than_ten_players_is_not_published():
    rows = [json.dumps(rnd("m1", n, [("p1", "p6", True)])) for n in range(6)]
    out = pop.population(rows)
    assert out["players"] == 9 and out["metrics"] == {}


def test_quantiles_run_from_lowest_to_highest():
    q = pop._quantiles([float(i) for i in range(101)])
    assert len(q) == 21 and q[0] == 0 and q[10] == 50 and q[-1] == 100


def test_the_endpoint_needs_the_read_token_and_follows_new_rounds(client):
    assert client.get("/v1/population").status_code == 401
    assert client.get("/v1/population", headers=auth(UP)).status_code == 403
    empty = client.get("/v1/population", headers=auth(RD)).json()
    assert empty["players"] == 0 and empty["metrics"] == {}
    from .test_parsed import payload, post
    for m in range(4):
        for n in range(6):
            body = payload(rnd(f"match-000{m}", n, [("p1", "p6", True), ("p7", "p2", False)], ids=f"m{m}"))  # new people every match
            assert post(client, body).json()["results"][0]["status"] == "parsed"
    full = client.get("/v1/population", headers=auth(RD)).json()
    assert full["players"] == 36 and full["rounds"] == 24
    assert full["metrics"]["kost"]["n"] == 36 and len(full["metrics"]["kost"]["quantiles"]) == 21
