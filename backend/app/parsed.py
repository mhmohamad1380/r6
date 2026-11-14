"""Rounds parsed on the player's PC. The PC reads the .rec and sends a small JSON; the server checks it strictly and stores it.

Nothing a client sends is stored as it came: the round is rebuilt field by field from a whitelist, so extra or oversized
data cannot get in. The limits below come from 190 real rounds: players 8 to 10, round numbers 0 to 8, at most 11 events,
time 0 to 179 seconds, scores 0 to 5. Real data also shows what must NOT be enforced: in 30 of 190 rounds both teams are
flagged `won`, 12 players have an empty name and 8 kill targets are not in the player list, so those are not rules."""
from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from typing import Any

SCHEMA_VERSION = 1
MAX_BODY_BYTES = 128 * 1024
MAX_EVENTS = 400
MAX_PLAYERS = 12
MAX_PROBLEMS = 10

_SHA = re.compile(r"^[0-9a-f]{64}$")
_VERSION = re.compile(r"^(\d{1,4})\.(\d{1,4})\.(\d{1,4})$")
_MATCH_ID = re.compile(r"^[A-Za-z0-9-]{8,64}$")
_ROLES = {"Attack", "Defense"}


def parse_version(text: str) -> tuple[int, int, int] | None:
    m = _VERSION.match(text or "")
    return (int(m[1]), int(m[2]), int(m[3])) if m else None


class Problems(Exception):
    def __init__(self, problems: list[str]):
        super().__init__("; ".join(problems))
        self.problems = problems


class _Check:
    """Collects problems instead of stopping at the first, so the user sees everything wrong at once."""

    def __init__(self) -> None:
        self.problems: list[str] = []

    def bad(self, path: str, why: str) -> None:
        if len(self.problems) < MAX_PROBLEMS:
            self.problems.append(f"{path}: {why}")

    def string(self, v: Any, path: str, max_len: int, *, empty: bool = True, required: bool = True) -> str | None:
        if v is None and not required:
            return None
        if not isinstance(v, str):
            self.bad(path, "must be text")
            return None
        if len(v) > max_len:
            self.bad(path, f"is longer than {max_len} characters")
            return None
        if not empty and not v:
            self.bad(path, "must not be empty")
            return None
        return v

    def integer(self, v: Any, path: str, lo: int, hi: int, *, required: bool = True) -> int | None:
        if v is None and not required:
            return None
        if isinstance(v, bool) or not isinstance(v, int):
            self.bad(path, "must be a whole number")
            return None
        if not lo <= v <= hi:
            self.bad(path, f"must be between {lo} and {hi}")
            return None
        return v

    def named(self, v: Any, path: str, *, required: bool = True) -> Any:
        """The game writes some values as text and some as {name, id}. Both are kept in the shape they came in."""
        if v is None and not required:
            return None
        if isinstance(v, str):
            return v if len(v) <= 80 else self._long(path)
        if isinstance(v, dict) and isinstance(v.get("name"), str) and len(v["name"]) <= 80:
            out: dict[str, Any] = {"name": v["name"]}
            if isinstance(v.get("id"), int) and not isinstance(v.get("id"), bool) and 0 <= v["id"] < 2**53:
                out["id"] = v["id"]
            return out
        self.bad(path, "must be text or {name, id}")
        return None

    def _long(self, path: str) -> None:
        self.bad(path, "is too long")
        return None


def validate_source(src: Any, c: _Check, max_size: int) -> dict[str, Any] | None:
    if not isinstance(src, dict):
        c.bad("source", "is required")
        return None
    sha = src.get("sha256")
    if not isinstance(sha, str) or not _SHA.match(sha):
        c.bad("source.sha256", "must be 64 lowercase hex characters")
    size = c.integer(src.get("size"), "source.size", 1, max_size)
    name = c.string(src.get("file"), "source.file", 200, required=False)
    return {"sha256": sha, "size": size, "file": name or "replay.rec"} if not c.problems else None


def validate_round(r: Any, c: _Check) -> dict[str, Any] | None:
    if not isinstance(r, dict):
        c.bad("round", "must be an object")
        return None
    out: dict[str, Any] = {}
    mid = c.string(r.get("matchID"), "round.matchID", 64, empty=False)
    if mid is not None and not _MATCH_ID.match(mid):
        c.bad("round.matchID", "is not a match id")
    out["matchID"] = mid
    out["roundNumber"] = c.integer(r.get("roundNumber"), "round.roundNumber", 0, 60)
    out["roundsPerMatch"] = c.integer(r.get("roundsPerMatch"), "round.roundsPerMatch", 1, 30, required=False)

    ts = c.string(r.get("timestamp"), "round.timestamp", 40, empty=False)
    if ts is not None:
        try:
            when = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            if when.tzinfo is None:
                when = when.replace(tzinfo=timezone.utc)
            if when < datetime(2015, 12, 1, tzinfo=timezone.utc) or when > datetime.now(timezone.utc) + timedelta(days=1):
                c.bad("round.timestamp", "is not a plausible date for a Siege match")
        except ValueError:
            c.bad("round.timestamp", "is not a date")
    out["timestamp"] = ts

    out["map"] = c.named(r.get("map"), "round.map")
    out["matchType"] = c.named(r.get("matchType"), "round.matchType")
    out["gamemode"] = c.named(r.get("gamemode"), "round.gamemode", required=False)
    out["site"] = c.string(r.get("site"), "round.site", 120, required=False)
    out["recordingProfileID"] = c.string(r.get("recordingProfileID"), "round.recordingProfileID", 64, required=False)
    # since uploader 1.3.0: overtime, the season, and where each player spawned
    out["overtimeRoundNumber"] = c.integer(r.get("overtimeRoundNumber"), "round.overtimeRoundNumber", 0, 60, required=False)
    out["roundsPerMatchOvertime"] = c.integer(r.get("roundsPerMatchOvertime"), "round.roundsPerMatchOvertime", 0, 30, required=False)
    out["gameVersion"] = c.string(r.get("gameVersion"), "round.gameVersion", 40, required=False)

    # teams: two, one attacking and one defending, scores that never go down
    teams = r.get("teams")
    out_teams: list[dict[str, Any]] = []
    if not isinstance(teams, list) or len(teams) != 2:
        c.bad("round.teams", "must hold exactly 2 teams")
    else:
        for i, t in enumerate(teams):
            p = f"round.teams[{i}]"
            if not isinstance(t, dict):
                c.bad(p, "must be an object")
                continue
            role = t.get("role")
            if role not in _ROLES:
                c.bad(p + ".role", "must be Attack or Defense")
            score = c.integer(t.get("score"), p + ".score", 0, 30)
            start = c.integer(t.get("startingScore"), p + ".startingScore", 0, 30, required=False)
            if score is not None and start is not None and start > score:
                c.bad(p, "score is lower than the starting score")
            if not isinstance(t.get("won"), bool):
                c.bad(p + ".won", "must be true or false")
            win = c.string(t.get("winCondition"), p + ".winCondition", 60, required=False)
            tm: dict[str, Any] = {"role": role, "score": score, "won": t.get("won") is True}
            if start is not None:
                tm["startingScore"] = start
            if win:
                tm["winCondition"] = win
            out_teams.append(tm)
        if len(out_teams) == 2 and {t["role"] for t in out_teams} != _ROLES:
            c.bad("round.teams", "must be one Attack team and one Defense team")
    out["teams"] = out_teams

    # players: 1 to 12, usernames may be empty (real replays have them), at most 6 per side
    players = r.get("players")
    out_players: list[dict[str, Any]] = []
    if not isinstance(players, list) or not 1 <= len(players) <= MAX_PLAYERS:
        c.bad("round.players", f"must hold 1 to {MAX_PLAYERS} players")
    else:
        for i, p_ in enumerate(players):
            p = f"round.players[{i}]"
            if not isinstance(p_, dict):
                c.bad(p, "must be an object")
                continue
            out_players.append({  # None values are dropped below
                "username": c.string(p_.get("username"), p + ".username", 40),
                "teamIndex": c.integer(p_.get("teamIndex"), p + ".teamIndex", 0, 1),
                "operator": c.named(p_.get("operator"), p + ".operator", required=False),
                "profileID": c.string(p_.get("profileID"), p + ".profileID", 64, required=False),
                "spawn": c.string(p_.get("spawn"), p + ".spawn", 120, required=False),
            })
        out_players = [{k: v for k, v in q.items() if v is not None or k in ("username", "teamIndex")} for q in out_players]
        for side in (0, 1):
            if sum(1 for q in out_players if q["teamIndex"] == side) > 6:
                c.bad("round.players", f"has more than 6 players on team {side}")
    out["players"] = out_players

    # events: bounded, each with a type; times on the round clock
    events = r.get("matchFeedback")
    out_events: list[dict[str, Any]] = []
    if not isinstance(events, list):
        c.bad("round.matchFeedback", "must be a list")
    elif len(events) > MAX_EVENTS:
        c.bad("round.matchFeedback", f"has more than {MAX_EVENTS} events")
    else:
        for i, e in enumerate(events):
            p = f"round.matchFeedback[{i}]"
            if not isinstance(e, dict):
                c.bad(p, "must be an object")
                continue
            ev: dict[str, Any] = {"type": c.named(e.get("type"), p + ".type")}
            for key in ("username", "target"):
                v = c.string(e.get(key), f"{p}.{key}", 40, required=False)
                if v is not None:
                    ev[key] = v
            if e.get("headshot") is not None:
                if isinstance(e["headshot"], bool):
                    ev["headshot"] = e["headshot"]
                else:
                    c.bad(p + ".headshot", "must be true or false")
            t = c.integer(e.get("timeInSeconds"), p + ".timeInSeconds", -120, 1200, required=False)
            if t is not None:
                ev["timeInSeconds"] = t
            op = c.named(e.get("operator"), p + ".operator", required=False)
            if op is not None:
                ev["operator"] = op
            msg = c.string(e.get("message"), p + ".message", 200, required=False)
            if msg:
                ev["message"] = msg
            out_events.append(ev)
    out["matchFeedback"] = out_events
    return {k: v for k, v in out.items() if v is not None} if not c.problems else None


def validate_payload(body: Any, *, max_size: int) -> dict[str, Any]:
    """Returns {"source", "parser_version", and either "round" (cleaned) or "failed" (reason)}. Raises Problems."""
    c = _Check()
    if not isinstance(body, dict):
        raise Problems(["the body must be a JSON object"])
    if body.get("schema_version") != SCHEMA_VERSION or isinstance(body.get("schema_version"), bool):
        raise Problems([f"schema_version must be {SCHEMA_VERSION}"])
    version = body.get("parser_version")
    if not isinstance(version, str) or parse_version(version) is None:
        raise Problems(["parser_version must look like 1.2.0"])
    source = validate_source(body.get("source"), c, max_size)
    has_round, has_failed = "round" in body, "failed" in body
    if has_round == has_failed:
        c.bad("body", "send exactly one of 'round' or 'failed'")
    result: dict[str, Any] = {"source": source, "parser_version": version}
    meta = body.get("parser")
    if meta is not None:
        if isinstance(meta, dict):
            result["parser"] = {"name": c.string(meta.get("name"), "parser.name", 40, required=False), "build": c.string(meta.get("build"), "parser.build", 80, required=False)}
        else:
            c.bad("parser", "must be an object")
    if has_round:
        result["round"] = validate_round(body["round"], c)
    elif has_failed:
        f = body["failed"]
        reason = c.string(f.get("reason") if isinstance(f, dict) else None, "failed.reason", 300, empty=False)
        result["failed"] = reason
    if c.problems:
        raise Problems(c.problems)
    return result


def trim_dissect(full: dict[str, Any]) -> dict[str, Any]:
    """The fields of r6-dissect's JSON that the apps use, and nothing else. The uploader on the PC must produce exactly this
    (tests compare the two), and the phone reads the result exactly as it read the full JSON before."""
    def pick(d: dict[str, Any], keys: tuple[str, ...]) -> dict[str, Any]:
        return {k: d[k] for k in keys if k in d and d[k] is not None}

    h = full.get("header", full)
    out = pick(h, ("matchID", "roundNumber", "roundsPerMatch", "timestamp", "map", "matchType", "gamemode", "site", "recordingProfileID", "overtimeRoundNumber", "roundsPerMatchOvertime", "gameVersion"))
    out["teams"] = [pick(t, ("role", "score", "startingScore", "won", "winCondition")) for t in h.get("teams", [])]
    out["players"] = [pick(p, ("username", "teamIndex", "operator", "profileID", "spawn")) for p in h.get("players", [])]
    out["matchFeedback"] = [pick(e, ("type", "username", "target", "headshot", "timeInSeconds", "operator", "message")) for e in full.get("matchFeedback", h.get("matchFeedback", []))]
    return out
