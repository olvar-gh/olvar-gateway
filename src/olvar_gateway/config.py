"""Gateway settings from the environment (systemd EnvironmentFile on the Pi, docs/PLAN.md §5.4)."""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Final
from urllib.parse import urlparse

DEFAULT_OUTBOX_PATH: Final = Path("/var/lib/olvar-gateway/outbox.db")
DEFAULT_MQTT_PORT: Final = 1883
DEFAULT_MQTT_USERNAME: Final = "olvar-gateway"
DEFAULT_GATEWAY_ID: Final = "olvar-gw"
DEFAULT_OUTBOX_MAX_ROWS: Final = 100_000
LOG_LEVELS: Final = ("DEBUG", "INFO", "WARNING", "ERROR")


class ConfigError(Exception):
    def __init__(self, problems: list[str]) -> None:
        super().__init__("invalid configuration:\n" + "\n".join(f"  - {p}" for p in problems))
        self.problems = problems


@dataclass(frozen=True)
class Config:
    supabase_url: str
    supabase_secret_key: str
    mqtt_host: str
    mqtt_port: int
    mqtt_username: str
    mqtt_password: str
    outbox_path: Path
    gateway_id: str
    outbox_max_rows: int = DEFAULT_OUTBOX_MAX_ROWS
    log_level: str = "INFO"

    def redacted(self) -> dict[str, object]:
        return {
            "supabase_url": self.supabase_url,
            "supabase_secret_key": _mask(self.supabase_secret_key),
            "mqtt_host": self.mqtt_host,
            "mqtt_port": self.mqtt_port,
            "mqtt_username": self.mqtt_username,
            "mqtt_password": "***",
            "outbox_path": str(self.outbox_path),
            "gateway_id": self.gateway_id,
            "outbox_max_rows": self.outbox_max_rows,
            "log_level": self.log_level,
        }


def _mask(secret: str) -> str:
    return secret[:10] + "***" if len(secret) > 14 else "***"


def outbox_path(env: Mapping[str, str] | None = None) -> Path:
    """Only the outbox location, for `status`, which must work without the service's secrets."""
    env = os.environ if env is None else env
    return Path(env.get("OUTBOX_PATH", "").strip() or DEFAULT_OUTBOX_PATH)


def load(env: Mapping[str, str] | None = None) -> Config:
    """Read and validate every setting; raises ConfigError listing all problems at once."""
    env = os.environ if env is None else env
    problems: list[str] = []

    def get(name: str, default: str | None = None) -> str:
        value = env.get(name, "").strip()
        if value:
            return value
        if default is None:
            problems.append(f"{name} is required")
            return ""
        return default

    def integer(name: str, default: int, low: int, high: int) -> int:
        raw = get(name, str(default))
        try:
            value = int(raw)
        except ValueError:
            problems.append(f"{name} must be an integer, got {raw!r}")
            return default
        if not low <= value <= high:
            problems.append(f"{name} must be between {low} and {high}, got {value}")
        return value

    url = get("SUPABASE_URL").rstrip("/")
    if url:
        parsed = urlparse(url)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            problems.append(f"SUPABASE_URL must be an http(s) URL, got {url!r}")
        elif parsed.path not in ("", "/"):
            problems.append("SUPABASE_URL must be the project URL without a path (no /rest/v1)")

    key = get("SUPABASE_SECRET_KEY")
    if key and key.startswith("sb_publishable_"):
        problems.append("SUPABASE_SECRET_KEY is a publishable key; use the secret key 'gateway'")
    elif key and not key.startswith("sb_secret_"):
        problems.append("SUPABASE_SECRET_KEY must be a secret key starting with 'sb_secret_'")

    log_level = get("LOG_LEVEL", "INFO").upper()
    if log_level not in LOG_LEVELS:
        problems.append(f"LOG_LEVEL must be one of {', '.join(LOG_LEVELS)}, got {log_level!r}")

    config = Config(
        supabase_url=url,
        supabase_secret_key=key,
        mqtt_host=get("MQTT_HOST"),
        mqtt_port=integer("MQTT_PORT", DEFAULT_MQTT_PORT, 1, 65535),
        mqtt_username=get("MQTT_USERNAME", DEFAULT_MQTT_USERNAME),
        mqtt_password=get("MQTT_PASSWORD"),
        outbox_path=outbox_path(env),
        gateway_id=get("GATEWAY_ID", DEFAULT_GATEWAY_ID),
        outbox_max_rows=integer("OUTBOX_MAX_ROWS", DEFAULT_OUTBOX_MAX_ROWS, 1, 10_000_000),
        log_level=log_level,
    )
    if problems:
        raise ConfigError(problems)
    return config
