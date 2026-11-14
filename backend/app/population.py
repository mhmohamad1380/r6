"""How the players in the stored replays play, so the phone can say where its owner stands among them.

Every round holds ten players, so even one person's replays describe hundreds of other players: teammates and opponents
at their own level. Each of them is scored with the same rules the phone uses for its owner (kills, deaths, KOST, opening
duels, headshots), and the server returns percentile tables. The people who recorded the replays are left out, so the
table describes who they play with and against, not themselves."""
from __future__ import annotations

import json
from typing import Any, Iterable

MIN_ROUNDS = 5          # fewer rounds than this says more about luck than about the player
METRICS = ("kd", "kost", "headshotRate", "openingRate", "killsPerRound", "survival", "winRate")


def _name(v: Any) -> str | None:
    if isinstance(v, dict):
        return _name(v.get("name"))
    return None if v is None else str(v)


def _same(a: Any, b: Any) -> bool:
    return a is not None and b is not None and str(a).strip().lower() == str(b).strip().lower()


def player_rounds(rnd: dict[str, Any]) -> Iterable[tuple[str, dict[str, Any]]]:
    """(player key, what happened to them) for each player in one round. Mirrors analyzeRound in the app."""
    h = rnd.get("header", rnd)
    players = h.get("players") or []
    teams = h.get("teams") or []
    events = rnd.get("matchFeedback", h.get("matchFeedback")) or []
    team_of = {str(p.get("username", "")).lower(): p.get("teamIndex") for p in players}
    kills = [e for e in events if _name(e.get("type")) == "Kill"]
    deaths = [e for e in events if _name(e.get("type")) == "Death"]   # killed by the map, a fall or their own gadget
    timed = bool(kills) and all(isinstance(e.get("timeInSeconds"), int) for e in kills)

    def friendly(e: dict[str, Any]) -> bool:
        a, t = team_of.get(str(e.get("username", "")).lower()), team_of.get(str(e.get("target", "")).lower())
        return a is not None and a == t

    first = next((e for e in kills if not friendly(e)), None)
    for p in players:
        me = p.get("username")
        if not me:
            continue
        team = p.get("teamIndex")
        k = hs = 0
        died_at = None
        for i, e in enumerate(kills):
            if _same(e.get("username"), me) and not friendly(e):
                k += 1
                hs += e.get("headshot") is True
            if _same(e.get("target"), me) and died_at is None:
                died_at = i
        died = died_at is not None or any(_same(e.get("username"), me) for e in deaths)
        traded = False
        if died_at is not None:
            killer, t0 = kills[died_at].get("username"), kills[died_at].get("timeInSeconds")
            for e in kills[died_at + 1:]:
                if _same(e.get("target"), killer) and team_of.get(str(e.get("username", "")).lower()) == team and not _same(e.get("username"), me):
                    if isinstance(t0, int) and isinstance(e.get("timeInSeconds"), int) and t0 - e["timeInSeconds"] <= 5:
                        traded = True
        objective = any(_same(e.get("username"), me) and ("Plant" in (_name(e.get("type")) or "") or "Disable" in (_name(e.get("type")) or "")) and "Complete" in (_name(e.get("type")) or "") for e in events)
        won = teams[team].get("won") if isinstance(team, int) and 0 <= team < len(teams) else None
        key = p.get("profileID") or ("name:" + str(me).lower())
        yield key, {
            "name": me, "kills": k, "headshots": hs, "died": died, "won": won,
            "kost": k > 0 or objective or not died or (timed and traded),
            "opening": None if first is None else ("kill" if _same(first.get("username"), me) else "death" if _same(first.get("target"), me) else None),
        }


def _quantiles(values: list[float]) -> list[float]:
    """The 0th, 5th, ... 100th percentile, so the phone can place any value between two of them."""
    v = sorted(values)
    out = []
    for q in range(0, 101, 5):
        pos = (len(v) - 1) * q / 100
        lo = int(pos)
        hi = min(lo + 1, len(v) - 1)
        out.append(round(v[lo] + (v[hi] - v[lo]) * (pos - lo), 4))
    return out


def population(rows: Iterable[str]) -> dict[str, Any]:
    """`rows` are the stored round JSON strings."""
    totals: dict[str, dict[str, Any]] = {}
    recorders: set[str] = set()
    rounds = 0
    for raw in rows:
        try:
            rnd = json.loads(raw)
        except ValueError:
            continue
        h = rnd.get("header", rnd)
        if h.get("recordingProfileID"):
            recorders.add(h["recordingProfileID"])
        rounds += 1
        for key, r in player_rounds(rnd):
            t = totals.setdefault(key, {"rounds": 0, "kills": 0, "deaths": 0, "headshots": 0, "kost": 0, "ok": 0, "od": 0, "wins": 0, "decided": 0})
            t["rounds"] += 1
            t["kills"] += r["kills"]
            t["deaths"] += r["died"]
            t["headshots"] += r["headshots"]
            t["kost"] += r["kost"]
            t["ok"] += r["opening"] == "kill"
            t["od"] += r["opening"] == "death"
            if r["won"] is not None:
                t["decided"] += 1
                t["wins"] += r["won"] is True
    people = [t for k, t in totals.items() if k not in recorders and t["rounds"] >= MIN_ROUNDS]
    values: dict[str, list[float]] = {m: [] for m in METRICS}
    for t in people:
        n = t["rounds"]
        values["kd"].append(t["kills"] / max(t["deaths"], 1))   # no deaths: kills per 1, so a perfect sample does not become infinite
        values["kost"].append(t["kost"] / n)
        values["killsPerRound"].append(t["kills"] / n)
        values["survival"].append(1 - t["deaths"] / n)
        if t["kills"]:
            values["headshotRate"].append(t["headshots"] / t["kills"])
        if t["ok"] + t["od"]:
            values["openingRate"].append(t["ok"] / (t["ok"] + t["od"]))
        if t["decided"]:
            values["winRate"].append(t["wins"] / t["decided"])
    return {
        "players": len(people), "rounds": rounds, "minRounds": MIN_ROUNDS,
        "metrics": {m: {"n": len(v), "quantiles": _quantiles(v)} for m, v in values.items() if len(v) >= 10},
    }
