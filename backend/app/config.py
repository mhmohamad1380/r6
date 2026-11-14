"""Settings from environment variables, with auto-generated access tokens."""
from __future__ import annotations

import json
import os
import secrets
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    data_dir: Path
    upload_token: str  # the PC uploader uses this; it can only upload
    read_token: str  # the phone uses this; it can list, download, acknowledge and delete
    dissect_bin: Path | None = None
    arenyze_key: str | None = None  # optional: used only when r6-dissect cannot read a file
    max_file_bytes: int = 60 * 1024 * 1024
    max_files_per_request: int = 20
    max_storage_bytes: int = 2 * 1024 * 1024 * 1024
    rec_retention_days: int = 30  # undelivered .rec files older than this are removed (data is kept)
    dissect_timeout: int = 90
    min_parser: str = "0.0.0"  # uploaders whose parser is older than this are told to update (HTTP 426)
    keep_rec: bool = False  # by default the .rec is deleted as soon as its analysis is stored; only a failed parse keeps it
    clips_quota_bytes: int = 4 * 1024 * 1024 * 1024  # all highlight clips together
    max_clip_bytes: int = 150 * 1024 * 1024  # one clip

    @property
    def rec_dir(self) -> Path:
        return self.data_dir / "rec"

    @property
    def tmp_dir(self) -> Path:
        return self.data_dir / "tmp"

    @property
    def db_path(self) -> Path:
        return self.data_dir / "replays.db"


def _tokens(data_dir: Path, env: dict[str, str]) -> tuple[str, str, bool]:
    """Tokens come from the environment, else from data/tokens.json (created on first run)."""
    path = data_dir / "tokens.json"
    saved: dict[str, str] = json.loads(path.read_text()) if path.exists() else {}
    created = False
    for key in ("upload_token", "read_token"):
        if env.get(key.upper()):
            saved[key] = env[key.upper()]
        elif key not in saved:
            saved[key] = secrets.token_urlsafe(24)
            created = True
    if created:
        path.write_text(json.dumps(saved, indent=2))
        path.chmod(0o600)
    return saved["upload_token"], saved["read_token"], created


def load_settings(env: dict[str, str] | None = None) -> tuple[Settings, bool]:
    """Returns the settings and whether new tokens were just created."""
    env = dict(os.environ if env is None else env)
    data_dir = Path(env.get("R6_DATA_DIR", "data")).resolve()
    for d in (data_dir, data_dir / "rec", data_dir / "tmp"):
        d.mkdir(parents=True, exist_ok=True)
    upload, read, created = _tokens(data_dir, {k.upper(): v for k, v in env.items() if k.upper() in ("UPLOAD_TOKEN", "READ_TOKEN")})
    dissect = env.get("R6_DISSECT_BIN")
    default = Path(__file__).resolve().parent.parent / "bin" / "r6-dissect"
    dissect_path = Path(dissect) if dissect else (default if default.exists() else None)
    return (
        Settings(
            data_dir=data_dir,
            upload_token=upload,
            read_token=read,
            dissect_bin=dissect_path,
            arenyze_key=env.get("R6_ARENYZE_KEY") or None,
            max_file_bytes=int(env.get("R6_MAX_FILE_MB", "60")) * 1024 * 1024,
            max_files_per_request=int(env.get("R6_MAX_FILES", "20")),
            max_storage_bytes=int(env.get("R6_MAX_STORAGE_MB", "2048")) * 1024 * 1024,
            rec_retention_days=int(env.get("R6_REC_RETENTION_DAYS", "30")),
            dissect_timeout=int(env.get("R6_DISSECT_TIMEOUT", "90")),
            min_parser=env.get("R6_MIN_PARSER", "0.0.0"),
            keep_rec=env.get("R6_KEEP_REC", "").lower() in ("1", "true", "yes"),
            clips_quota_bytes=int(env.get("R6_CLIPS_MAX_MB", "4096")) * 1024 * 1024,
            max_clip_bytes=int(env.get("R6_MAX_CLIP_MB", "150")) * 1024 * 1024,
        ),
        created,
    )
