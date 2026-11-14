"""SQLite storage. One row per uploaded round; the heavy .rec lives on disk until acknowledged."""
from __future__ import annotations

import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterator

SCHEMA = """
CREATE TABLE IF NOT EXISTS rounds (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sha256 TEXT NOT NULL UNIQUE,
    filename TEXT NOT NULL,
    size INTEGER NOT NULL,
    uploaded_at TEXT NOT NULL,
    status TEXT NOT NULL,            -- parsed | failed | purged
    parser TEXT,                     -- dissect | arenyze
    error TEXT,
    match_id TEXT,
    round_number INTEGER,
    data TEXT,                       -- the parsed round as JSON
    rec_path TEXT,                   -- null once the .rec has been deleted
    rec_deleted_at TEXT,
    seq INTEGER NOT NULL DEFAULT 0   -- changes whenever the round's data changes; the phone's cursor follows it
);
CREATE INDEX IF NOT EXISTS rounds_seq ON rounds(seq);
"""


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class Store:
    def __init__(self, path: Path):
        self.path = path
        with self._db() as db:
            db.executescript(SCHEMA)

    @contextmanager
    def _db(self) -> Iterator[sqlite3.Connection]:
        db = sqlite3.connect(self.path, timeout=15)
        db.row_factory = sqlite3.Row
        try:
            yield db
            db.commit()
        finally:
            db.close()

    def by_sha(self, sha: str) -> sqlite3.Row | None:
        with self._db() as db:
            return db.execute("SELECT * FROM rounds WHERE sha256=?", (sha,)).fetchone()

    def known(self, hashes: set[str]) -> set[str]:
        found: set[str] = set()
        todo = sorted(hashes)
        with self._db() as db:
            for i in range(0, len(todo), 500):
                part = todo[i : i + 500]
                found.update(r[0] for r in db.execute(f"SELECT sha256 FROM rounds WHERE sha256 IN ({','.join('?' * len(part))})", part))
        return found

    def failed(self, hashes: set[str]) -> set[str]:
        """Which of these fingerprints are stored as failed, so an uploader with a newer parser knows to try again."""
        found: set[str] = set()
        todo = sorted(hashes)
        with self._db() as db:
            for i in range(0, len(todo), 500):
                part = todo[i : i + 500]
                found.update(r[0] for r in db.execute(f"SELECT sha256 FROM rounds WHERE status='failed' AND sha256 IN ({','.join('?' * len(part))})", part))
        return found

    def get(self, rid: int) -> sqlite3.Row | None:
        with self._db() as db:
            return db.execute("SELECT * FROM rounds WHERE id=?", (rid,)).fetchone()

    @staticmethod
    def _next_seq(db: sqlite3.Connection) -> int:
        return int(db.execute("SELECT COALESCE(MAX(seq), 0) + 1 FROM rounds").fetchone()[0])

    def insert(self, **f: Any) -> int:
        with self._db() as db:
            f["seq"] = self._next_seq(db)
            cols = ", ".join(f)
            cur = db.execute(f"INSERT INTO rounds ({cols}) VALUES ({', '.join('?' for _ in f)})", tuple(f.values()))
            return int(cur.lastrowid)

    def update(self, rid: int, bump: bool = False, **f: Any) -> None:
        """`bump` moves the round to the end of the feed so a phone that already passed it sees the change."""
        with self._db() as db:
            if bump:
                f["seq"] = self._next_seq(db)
            db.execute(f"UPDATE rounds SET {', '.join(k + '=?' for k in f)} WHERE id=?", (*f.values(), rid))

    def after(self, cursor: int, limit: int) -> list[sqlite3.Row]:
        with self._db() as db:
            return db.execute("SELECT * FROM rounds WHERE seq>? AND status != 'purged' ORDER BY seq LIMIT ?", (cursor, limit)).fetchall()

    def parsed_data(self) -> tuple[int, list[str]]:
        """(the newest change number, every parsed round's JSON). The number tells callers whether a cached result is stale."""
        with self._db() as db:
            top = db.execute("SELECT COALESCE(MAX(seq),0) FROM rounds").fetchone()[0]
            return top, [r[0] for r in db.execute("SELECT data FROM rounds WHERE status='parsed' AND data IS NOT NULL")]

    def stats(self) -> dict[str, int]:
        with self._db() as db:
            r = db.execute(
                "SELECT COUNT(*) n, SUM(status='parsed') parsed, SUM(status='failed') failed, SUM(status='purged') purged,"
                " SUM(rec_path IS NOT NULL) recs, COALESCE(SUM(CASE WHEN rec_path IS NOT NULL THEN size END),0) rec_bytes FROM rounds"
            ).fetchone()
        return {k: int(r[k] or 0) for k in r.keys()}

    def expired_recs(self, days: int) -> list[sqlite3.Row]:
        cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat(timespec="seconds")
        with self._db() as db:
            return db.execute("SELECT * FROM rounds WHERE rec_path IS NOT NULL AND uploaded_at < ?", (cutoff,)).fetchall()


def row_to_item(r: sqlite3.Row, include_data: bool = True) -> dict[str, Any]:
    return {
        "id": r["id"],
        "seq": r["seq"],
        "filename": r["filename"],
        "size": r["size"],
        "uploadedAt": r["uploaded_at"],
        "status": r["status"],
        "parser": r["parser"],
        "error": r["error"],
        "matchId": r["match_id"],
        "round": r["round_number"],
        "recAvailable": r["rec_path"] is not None,
        "data": json.loads(r["data"]) if include_data and r["data"] else None,
    }
