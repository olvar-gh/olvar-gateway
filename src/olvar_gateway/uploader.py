"""Outbox → Supabase over PostgREST (docs/PLAN.md §5.3, §5.4, decision D16).

`SupabaseWriter` makes the HTTP calls and classifies every failure. Only row-specific data errors
(SQLSTATE class 22 or 23) are `permanent`; they are isolated by bisecting the batch. Everything
request-wide (401/403/42501, 404, PGRST*, other 4xx, 5xx, 429, network) is `retryable`: the rows
stay queued and delivery resumes by itself once the cause is fixed.

`Uploader` drives one outbox through one writer with exponential backoff.
"""

from __future__ import annotations

import logging
import random
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime
from enum import Enum
from typing import Any, Final, Literal

import httpx

from .buffer import Outbox
from .clock import Clock
from .models import ReadingRow

log = logging.getLogger(__name__)

READINGS_PATH: Final = "/rest/v1/readings"
DEVICES_PATH: Final = "/rest/v1/devices"
GATEWAYS_PATH: Final = "/rest/v1/gateways"
IGNORE_DUPLICATES: Final = "resolution=ignore-duplicates,return=minimal"
MERGE_DUPLICATES: Final = "resolution=merge-duplicates,return=minimal"

BATCH_SIZE: Final = 500
IDLE_DELAY_S: Final = 5.0
BACKOFF_MIN_S: Final = 1.0
BACKOFF_MAX_S: Final = 300.0

Outcome = Literal["ok", "retryable", "permanent"]
# network | server | rate_limited | auth | not_found | schema | client | data
ErrorClass = str


@dataclass(frozen=True)
class UploadResult:
    outcome: Outcome
    error_class: ErrorClass | None = None
    status: int | None = None
    code: str | None = None
    message: str = ""
    # permanent only: index into the sent rows -> reason. Rows not listed were stored.
    rejected: dict[int, str] = field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return self.outcome == "ok"

    def describe(self) -> str:
        parts = [self.error_class or self.outcome]
        if self.status is not None:
            parts.append(str(self.status))
        if self.code:
            parts.append(self.code)
        if self.message:
            parts.append(self.message)
        return " ".join(parts)


OK: Final = UploadResult("ok")


class _Keep(Enum):
    KEEP = "keep"


# Default for nullable device columns: leave the stored value alone (None would clear it).
KEEP: Final = _Keep.KEEP


def is_row_error(code: str | None) -> bool:
    """SQLSTATE class 22 (data exception) or 23 (integrity constraint violation)."""
    return code is not None and len(code) == 5 and code[:2] in ("22", "23")


def classify(response: httpx.Response) -> UploadResult:
    status = response.status_code
    if 200 <= status < 300:
        return OK
    code: str | None = None
    message = ""
    try:
        body = response.json()
    except ValueError:
        body = None
    if isinstance(body, dict):
        code = body.get("code") if isinstance(body.get("code"), str) else None
        message = str(body.get("message") or "")
    if not message:
        message = response.text[:200]

    def retry(error_class: str) -> UploadResult:
        return UploadResult("retryable", error_class, status, code, message)

    if status >= 500:
        return retry("server")
    if status == 429:
        return retry("rate_limited")
    if status in (401, 403) or code == "42501":
        return retry("auth")
    if status == 404:
        return retry("not_found")
    if code is not None and code.startswith("PGRST"):
        return retry("schema")
    if is_row_error(code):
        return UploadResult("permanent", "data", status, code, message, {0: f"{code}: {message}"})
    return retry("client")


def _reading_json(row: ReadingRow) -> dict[str, Any]:
    if row.recorded_at is None:
        raise ValueError("cannot upload a reading without recorded_at")
    return {
        "device_id": row.device_id,
        "boot_id": row.boot_id,
        "seq": row.seq,
        "uptime_ms": row.uptime_ms,
        "recorded_at": row.recorded_at.isoformat(),
        "temperature_c": row.temperature_c,
        "humidity_pct": row.humidity_pct,
        "lux": row.lux,
        "soil_raw": row.soil_raw,
        "rssi_dbm": row.rssi_dbm,
        "clock_source": row.clock_source,
    }


class SupabaseWriter:
    def __init__(
        self,
        url: str,
        secret_key: str,
        client: httpx.Client,
        *,
        now: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        self._base = url.rstrip("/")
        self._key = secret_key
        self._client = client
        self._now = now

    def _post(self, path: str, params: dict[str, str], prefer: str, body: Any) -> UploadResult:
        try:
            response = self._client.post(
                self._base + path,
                params=params,
                json=body,
                headers={"apikey": self._key, "Prefer": prefer},
            )
        except httpx.TransportError as exc:
            return UploadResult("retryable", "network", message=f"{type(exc).__name__}: {exc}")
        return classify(response)

    def upsert_readings(self, rows: Sequence[ReadingRow]) -> UploadResult:
        """Idempotent bulk insert. A `permanent` result lists the offending rows in `rejected`;
        all other rows were stored. A `retryable` result means nothing can be assumed stored."""
        if not rows:
            return OK
        return self._bisect([_reading_json(r) for r in rows], 0)

    def _bisect(self, body: list[dict[str, Any]], offset: int) -> UploadResult:
        result = self._post(
            READINGS_PATH, {"on_conflict": "device_id,boot_id,seq"}, IGNORE_DUPLICATES, body
        )
        if result.outcome != "permanent":
            return result
        if len(body) == 1:
            return UploadResult(
                "permanent",
                "data",
                result.status,
                result.code,
                result.message,
                {offset: result.rejected[0]},
            )
        mid = len(body) // 2
        rejected: dict[int, str] = {}
        first: UploadResult | None = None
        for part, part_offset in ((body[:mid], offset), (body[mid:], offset + mid)):
            sub = self._bisect(part, part_offset)
            if sub.outcome == "retryable":
                return sub
            if sub.outcome == "permanent":
                rejected.update(sub.rejected)
                first = first or sub
        if first is None:  # the whole batch failed, yet both halves went in: nothing to isolate
            return OK
        return UploadResult("permanent", "data", first.status, first.code, first.message, rejected)

    def upsert_device(
        self,
        device_id: str,
        *,
        status: str | None = None,
        fw: str | None = None,
        last_seen_at: datetime | None = None,
        climate_sensor: str | _Keep | None = KEEP,
    ) -> UploadResult:
        """Touch only {id, fw, last_seen_at, climate_sensor} (+ status, status_changed_at for
        status messages); calibration and owner columns are never sent. climate_sensor=None
        clears the column (telemetry without the field); KEEP leaves it as it is."""
        body: dict[str, Any] = {"id": device_id}
        if fw is not None:
            body["fw"] = fw
        if climate_sensor is not KEEP:
            body["climate_sensor"] = climate_sensor
        if last_seen_at is not None:
            body["last_seen_at"] = last_seen_at.isoformat()
        if status is not None:
            body["status"] = status
            body["status_changed_at"] = (last_seen_at or self._now()).isoformat()
        return self._post(DEVICES_PATH, {"on_conflict": "id"}, MERGE_DUPLICATES, body)

    def heartbeat(self, gateway_id: str, version: str, buffer_depth: int) -> UploadResult:
        body = {
            "id": gateway_id,
            "version": version,
            "buffer_depth": buffer_depth,
            "last_seen_at": self._now().isoformat(),
        }
        return self._post(GATEWAYS_PATH, {"on_conflict": "id"}, MERGE_DUPLICATES, body)


class Uploader:
    """One delivery attempt per `step()`; the caller sleeps for the returned delay (or less, when
    a new row arrives). Thread-unsafe by design: run it from the single uploader thread."""

    def __init__(
        self,
        outbox: Outbox,
        writer: SupabaseWriter,
        clock: Clock,
        *,
        batch_size: int = BATCH_SIZE,
        rng: Callable[[], float] = random.random,
    ) -> None:
        self._outbox = outbox
        self._writer = writer
        self._clock = clock
        self._batch_size = batch_size
        self._rng = rng
        self._failures = 0
        self._error_class: str | None = None
        self.last_error: str | None = None

    @property
    def backing_off(self) -> bool:
        return self._failures > 0

    def _backoff(self) -> float:
        exponent = min(self._failures - 1, 16)  # 2**16 s is already past the cap; avoids overflow
        base = min(BACKOFF_MAX_S, BACKOFF_MIN_S * 2**exponent)
        return max(BACKOFF_MIN_S, base * (0.5 + 0.5 * self._rng()))

    def step(self) -> float:
        """Try to deliver one batch. Returns the seconds to wait before the next step."""
        self._outbox.resolve_unsynced(self._clock)
        batch = self._outbox.ready(self._batch_size)
        if not batch:
            return IDLE_DELAY_S
        ids = [row_id for row_id, _ in batch]
        result = self._writer.upsert_readings([row for _, row in batch])

        if result.outcome == "retryable":
            self._failures += 1
            self.last_error = result.describe()
            self._outbox.mark_failed(ids, self.last_error)
            if result.error_class != self._error_class:
                log.error("upload failed, %d row(s) stay queued: %s", len(ids), self.last_error)
                self._error_class = result.error_class
            return self._backoff()

        if self._error_class is not None:
            log.info("upload recovered after %d failed attempt(s)", self._failures)
        self._failures = 0
        self._error_class = None
        self.last_error = None
        bad = {ids[i]: reason for i, reason in result.rejected.items()}
        for row_id, reason in bad.items():
            self._outbox.dead_letter([row_id], reason)
            log.error("dead-lettered outbox row %d: %s", row_id, reason)
        self._outbox.ack([i for i in ids if i not in bad])
        return 0.0 if len(batch) == self._batch_size else IDLE_DELAY_S
