"""Telemetry payload contract (docs/PLAN.md §4, §5.3, §5.4).

`parse_message` turns one MQTT telemetry message into a validated `Telemetry`;
`to_row` turns it into a `ReadingRow` (the `readings` columns minus id/received_at).
The JSON Schema twin of `Telemetry` lives in contracts/telemetry.v1.schema.json.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import datetime
from typing import Annotated, Any, Final, Literal, Protocol

from pydantic import (
    BaseModel,
    BeforeValidator,
    ConfigDict,
    Field,
    PrivateAttr,
    ValidationError,
    model_validator,
)

MAX_PAYLOAD_BYTES: Final = 1024
DEVICE_ID_PATTERN: Final = r"^[a-z0-9][a-z0-9-]{2,31}$"
BOOT_ID_PATTERN: Final = r"^[0-9a-f]{8}$"
RESERVED_DEVICE_IDS: Final = frozenset({"olvar-gateway"})
TELEMETRY_TOPIC_RE: Final = re.compile(r"olvar/v1/([^/]+)/telemetry")

PG_INT_MAX: Final = 2**31 - 1
PG_BIGINT_MAX: Final = 2**63 - 1

# Physical ranges (inclusive). Values outside become null instead of rejecting the reading.
SENSOR_RANGES: Final[dict[str, tuple[float, float]]] = {
    "temperature_c": (-40.0, 125.0),
    "humidity_pct": (0.0, 100.0),
    "lux": (0.0, 120_000.0),
    "soil_raw": (0, 4095),
    "rssi_dbm": (-120, 0),
}


class InvalidMessage(Exception):
    """The message cannot become a reading. `reason` is a short, log-friendly code."""

    def __init__(self, reason: str, detail: str = "") -> None:
        super().__init__(f"{reason}: {detail}" if detail else reason)
        self.reason = reason
        self.detail = detail


def _integral(value: Any) -> Any:
    # JSON Schema "integer" accepts 2214.0; mirror that, but leave everything else to strict mode.
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return value


Int = Annotated[int, BeforeValidator(_integral)]


class Telemetry(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True, allow_inf_nan=False)

    device_id: Annotated[str, Field(pattern=DEVICE_ID_PATTERN)]
    boot_id: Annotated[str, Field(pattern=BOOT_ID_PATTERN)]
    seq: Annotated[Int, Field(ge=0, le=PG_INT_MAX)]
    uptime_ms: Annotated[Int, Field(ge=0, le=PG_BIGINT_MAX)]
    temperature_c: float | None
    humidity_pct: float | None
    lux: float | None
    soil_raw: Int | None
    rssi_dbm: Int | None = None
    fw: Annotated[str, Field(min_length=1, max_length=64)]

    _out_of_range: tuple[str, ...] = PrivateAttr(default=())

    @model_validator(mode="after")
    def _check(self) -> Telemetry:
        if self.device_id in RESERVED_DEVICE_IDS:
            raise ValueError(f"device_id {self.device_id!r} is reserved")
        nulled = []
        for name, (low, high) in SENSOR_RANGES.items():
            value = getattr(self, name)
            if value is not None and not low <= value <= high:
                setattr(self, name, None)
                nulled.append(name)
        self._out_of_range = tuple(nulled)
        return self

    @property
    def out_of_range(self) -> tuple[str, ...]:
        """Fields that were present but outside their physical range and were set to null."""
        return self._out_of_range


class Stamp(Protocol):
    """The parts of clock.Stamp that `to_row` reads."""

    @property
    def wall(self) -> datetime | None: ...
    @property
    def synced(self) -> bool: ...


@dataclass(frozen=True)
class ReadingRow:  # == readings columns minus id/received_at
    device_id: str
    boot_id: str
    seq: int
    uptime_ms: int
    recorded_at: datetime | None  # None until clock is trustworthy
    temperature_c: float | None
    humidity_pct: float | None
    lux: float | None
    soil_raw: int | None
    rssi_dbm: int | None
    clock_source: Literal["ntp", "backfilled", "unsynced"]


def _reject_constant(name: str) -> Any:
    raise ValueError(f"{name} is not allowed")


def parse_message(topic: str, payload: bytes) -> Telemetry:
    """Validate one telemetry message; raises InvalidMessage."""
    match = TELEMETRY_TOPIC_RE.fullmatch(topic)
    if match is None:
        raise InvalidMessage("bad_topic", topic)
    topic_id = match.group(1)
    if len(payload) > MAX_PAYLOAD_BYTES:
        raise InvalidMessage("too_large", f"{len(payload)} bytes")
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise InvalidMessage("bad_encoding", str(exc)) from None
    try:
        data = json.loads(text, parse_constant=_reject_constant)
    except ValueError as exc:  # JSONDecodeError and NaN/Infinity literals
        reason = "non_finite" if "not allowed" in str(exc) else "bad_json"
        raise InvalidMessage(reason, str(exc)) from None
    if not isinstance(data, dict):
        raise InvalidMessage("not_object", type(data).__name__)
    if data.get("device_id") != topic_id:
        detail = f"topic {topic_id!r} != payload {data.get('device_id')!r}"
        raise InvalidMessage("topic_mismatch", detail)
    try:
        return Telemetry.model_validate(data)
    except ValidationError as exc:
        err = exc.errors()[0]
        field = ".".join(str(p) for p in err["loc"]) or "payload"
        raise InvalidMessage(f"invalid_{field}", err["msg"]) from None


def to_row(t: Telemetry, stamp: Stamp) -> ReadingRow:
    """Synced clock: recorded_at + 'ntp'. Else recorded_at stays None (outbox backfills)."""
    synced = stamp.synced and stamp.wall is not None
    return ReadingRow(
        device_id=t.device_id,
        boot_id=t.boot_id,
        seq=t.seq,
        uptime_ms=t.uptime_ms,
        recorded_at=stamp.wall if synced else None,
        temperature_c=t.temperature_c,
        humidity_pct=t.humidity_pct,
        lux=t.lux,
        soil_raw=t.soil_raw,
        rssi_dbm=t.rssi_dbm,
        clock_source="ntp" if synced else "unsynced",
    )
