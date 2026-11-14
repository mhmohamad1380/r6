"""Website accounts: a name and a password, plus the read token the person saved for the replay server.

Passwords are stored as scrypt hashes with their own salt. A session is a random value in a cookie; only its hash is
stored, so a copy of the database cannot be used to sign in. The read token is kept as given because the site has to send
it to the replay server for the person, which is why the database file is readable by the site's user only."""
from __future__ import annotations

import hashlib
import hmac
import re
import secrets
import sqlite3
import threading
import time
from pathlib import Path

NAME = re.compile(r"^[a-z0-9][a-z0-9_.-]{2,23}$")
MIN_PASSWORD, MAX_PASSWORD = 8, 200
SESSION_DAYS = 30
MAX_USERS = 2000

_SCRYPT = dict(n=2**14, r=8, p=1, maxmem=64 * 1024 * 1024, dklen=32)


def hash_password(password: str, salt: bytes) -> bytes:
    return hashlib.scrypt(password.encode(), salt=salt, **_SCRYPT)


class Throttle:
    """Counts recent failures per key, so guessing a password or making accounts in bulk gets slow."""

    def __init__(self, limit: int, window: int):
        self.limit, self.window = limit, window
        self.hits: dict[str, list[float]] = {}
        self.lock = threading.Lock()

    def _recent(self, key: str, now: float) -> list[float]:
        recent = [t for t in self.hits.get(key, []) if now - t < self.window]
        if recent:
            self.hits[key] = recent
        else:
            self.hits.pop(key, None)
        return recent

    def blocked(self, key: str) -> bool:
        with self.lock:
            return len(self._recent(key, time.time())) >= self.limit

    def add(self, key: str) -> None:
        with self.lock:
            now = time.time()
            self._recent(key, now)
            self.hits.setdefault(key, []).append(now)
            if len(self.hits) > 5000:  # forget the oldest keys rather than grow forever
                for k in sorted(self.hits, key=lambda k: self.hits[k][-1])[:1000]:
                    self.hits.pop(k, None)

    def clear(self, key: str) -> None:
        with self.lock:
            self.hits.pop(key, None)


class Accounts:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.lock = threading.Lock()
        try:
            path.chmod(0o600)
        except OSError:
            pass
        with self.lock:
            self.db.executescript(
                """
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS users(
                  id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL, salt BLOB NOT NULL, hash BLOB NOT NULL,
                  token TEXT, created TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS sessions(
                  sid TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE, expires REAL NOT NULL);
                """
            )
        self._dummy = (secrets.token_bytes(16), None)

    # ----- people -----
    def count(self) -> int:
        with self.lock:
            return self.db.execute("SELECT COUNT(*) FROM users").fetchone()[0]

    def create(self, name: str, password: str) -> int | None:
        """The new person's id, or None when the name is taken."""
        salt = secrets.token_bytes(16)
        h = hash_password(password, salt)
        with self.lock:
            try:
                cur = self.db.execute("INSERT INTO users(name,salt,hash,created) VALUES(?,?,?,datetime('now'))", (name, salt, h))
            except sqlite3.IntegrityError:
                return None
            return cur.lastrowid

    def check(self, name: str, password: str) -> int | None:
        with self.lock:
            row = self.db.execute("SELECT id,salt,hash FROM users WHERE name=?", (name,)).fetchone()
        if row is None:
            hash_password(password, self._dummy[0])  # same work either way, so timing does not reveal which names exist
            return None
        return row["id"] if hmac.compare_digest(hash_password(password, row["salt"]), row["hash"]) else None

    def user(self, uid: int) -> sqlite3.Row | None:
        with self.lock:
            return self.db.execute("SELECT id,name,token,created FROM users WHERE id=?", (uid,)).fetchone()

    def set_token(self, uid: int, token: str | None) -> None:
        with self.lock:
            self.db.execute("UPDATE users SET token=? WHERE id=?", (token, uid))

    def delete(self, uid: int) -> None:
        with self.lock:
            self.db.execute("DELETE FROM sessions WHERE user_id=?", (uid,))
            self.db.execute("DELETE FROM users WHERE id=?", (uid,))

    # ----- sessions -----
    @staticmethod
    def _sid(value: str) -> str:
        return hashlib.sha256(value.encode()).hexdigest()

    def open_session(self, uid: int) -> str:
        value = secrets.token_urlsafe(32)
        with self.lock:
            self.db.execute("DELETE FROM sessions WHERE expires<?", (time.time(),))
            self.db.execute("INSERT INTO sessions(sid,user_id,expires) VALUES(?,?,?)", (self._sid(value), uid, time.time() + SESSION_DAYS * 86400))
        return value

    def session_user(self, value: str | None) -> int | None:
        if not value or len(value) > 100:
            return None
        with self.lock:
            row = self.db.execute("SELECT user_id,expires FROM sessions WHERE sid=?", (self._sid(value),)).fetchone()
        return row["user_id"] if row and row["expires"] > time.time() else None

    def close_session(self, value: str | None) -> None:
        if value:
            with self.lock:
                self.db.execute("DELETE FROM sessions WHERE sid=?", (self._sid(value),))

    def close_all(self, uid: int) -> None:
        with self.lock:
            self.db.execute("DELETE FROM sessions WHERE user_id=?", (uid,))
