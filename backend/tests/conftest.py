from __future__ import annotations

import hashlib
import json
from dataclasses import replace
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config import Settings, load_settings
from app.main import create_app

SAMPLES = Path(__file__).parent / "samples"
FIXTURES = Path(__file__).resolve().parents[2] / "mobile" / "test" / "fixtures" / "replays"
UP, RD = "up-token-test", "read-token-test"


def sample(name: str) -> bytes:
    return (SAMPLES / name).read_bytes()


def expected_kills(name: str) -> list[tuple]:
    j = json.loads((FIXTURES / name).read_text())
    return [(e["username"], e["target"], bool(e.get("headshot")), e["timeInSeconds"]) for e in j["matchFeedback"] if e["type"]["name"] == "Kill"]


def kills_of(data: dict) -> list[tuple]:
    return [(e["username"], e["target"], bool(e.get("headshot")), e["timeInSeconds"]) for e in data["matchFeedback"] if e["type"]["name"] == "Kill"]


@pytest.fixture
def settings(tmp_path) -> Settings:
    s, _ = load_settings({"R6_DATA_DIR": str(tmp_path / "data"), "UPLOAD_TOKEN": UP, "READ_TOKEN": RD})
    return s


@pytest.fixture
def make(settings):
    def _make(**over) -> TestClient:
        return TestClient(create_app(replace(settings, **over)))

    return _make


@pytest.fixture
def client(make) -> TestClient:
    return make()


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def upload(client: TestClient, name: str, data: bytes | None = None, token: str = UP, field: str = "files"):
    body = sample(name) if data is None else data
    return client.post("/v1/upload", headers=auth(token), files={field: (name, body, "application/octet-stream")})


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()
