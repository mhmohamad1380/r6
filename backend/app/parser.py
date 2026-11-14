"""Turns a .rec into round JSON. r6-dissect first; Arenyze only if dissect cannot read the file."""
from __future__ import annotations

import json
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any

import httpx

from .config import Settings

ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
DISSECT_MAGIC = b"dissect\x00"  # current game versions write the .rec uncompressed, starting with this


def is_replay_header(head: bytes) -> bool:
    """A Siege .rec is either zstd-compressed or a plain dissect stream."""
    return head[:4] == ZSTD_MAGIC or head[:8] == DISSECT_MAGIC

ARENYZE_UPLOAD = "https://r6.arenyze.com/api/replays/api/upload"
_KEEP_ANALYSIS = ("outcome", "players", "killDetails", "timerPhases", "bombSite", "bombPlant", "roundDuration")


class ParseError(Exception):
    pass


def _valid(round_json: dict[str, Any]) -> None:
    header = round_json.get("header", round_json)
    if not isinstance(round_json.get("matchFeedback"), list) or not header.get("matchID"):
        raise ParseError("The parser output has no match id or events.")


def _reason(text: str) -> str:
    """The one line that says what went wrong: Go prints the panic message first and a stack trace after it."""
    lines = [ln.strip() for ln in (text or "").strip().splitlines() if ln.strip()]
    for ln in lines:
        if ln.startswith("panic:"):
            hint = " The game has an operator this r6-dissect version does not know yet; update r6-dissect." if "role unknown" in ln else ""
            return (ln + "." + hint)[:300]
    for ln in lines:
        if "FTL" in ln or "error=" in ln:
            return re.sub(r"\x1b\[[0-9;]*m", "", ln)[:300]
    return (lines[-1] if lines else "r6-dissect failed")[:300]


def parse_with_dissect(settings: Settings, rec: Path) -> dict[str, Any]:
    if settings.dissect_bin is None or not settings.dissect_bin.exists():
        raise ParseError("r6-dissect is not installed on the server.")
    with tempfile.TemporaryDirectory(dir=settings.tmp_dir) as tmp:
        out = Path(tmp) / "round.json"
        try:
            # A list of arguments, never a shell: the file name never reaches a shell.
            run = subprocess.run([str(settings.dissect_bin), str(rec), "-o", str(out)], capture_output=True, timeout=settings.dissect_timeout, text=True)
        except subprocess.TimeoutExpired as e:
            raise ParseError(f"r6-dissect timed out after {settings.dissect_timeout}s.") from e
        if run.returncode != 0 or not out.exists():
            raise ParseError(_reason(run.stderr or run.stdout))
        data = json.loads(out.read_text())
    _valid(data)
    return data


def trim_arenyze_round(r: dict[str, Any]) -> dict[str, Any]:
    """Arenyze rounds carry large position data; the app needs only the header, events and outcome."""
    r = {k: v for k, v in r.items() if k in ("header", "analysis", "matchFeedback", "roundDuration", "parserEngine", "parserVersion")}
    r["analysis"] = {k: v for k, v in (r.get("analysis") or {}).items() if k in _KEEP_ANALYSIS}
    return r


def parse_with_arenyze(settings: Settings, rec: Path, client: httpx.Client | None = None) -> dict[str, Any]:
    if not settings.arenyze_key:
        raise ParseError("No Arenyze key configured for the fallback parser.")
    own = client is None
    client = client or httpx.Client(timeout=180)
    try:
        with rec.open("rb") as fh:
            resp = client.post(ARENYZE_UPLOAD, headers={"api-key": settings.arenyze_key}, files={"replayFiles": (rec.name, fh, "application/octet-stream")})
    except httpx.HTTPError as e:
        raise ParseError(f"Arenyze request failed: {type(e).__name__}") from e
    finally:
        if own:
            client.close()
    if resp.status_code != 200:
        raise ParseError(f"Arenyze returned {resp.status_code}.")
    rounds = resp.json().get("rounds") or []
    if not rounds:
        raise ParseError("Arenyze returned no rounds.")
    data = trim_arenyze_round(rounds[0])
    _valid(data)
    return data


def parse(settings: Settings, rec: Path) -> tuple[dict[str, Any], str]:
    """Returns (round json, parser name). Raises ParseError with every reason if both fail."""
    reasons: list[str] = []
    try:
        return parse_with_dissect(settings, rec), "dissect"
    except ParseError as e:
        reasons.append(f"dissect: {e}")
    if settings.arenyze_key:
        try:
            return parse_with_arenyze(settings, rec), "arenyze"
        except ParseError as e:
            reasons.append(f"arenyze: {e}")
    raise ParseError(" | ".join(reasons))


def ids_of(data: dict[str, Any]) -> tuple[str | None, int | None]:
    header = data.get("header", data)
    rn = header.get("roundNumber")
    return header.get("matchID"), int(rn) if isinstance(rn, (int, str)) and str(rn).isdigit() else None
