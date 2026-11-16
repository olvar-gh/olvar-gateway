"""MQTT intake → outbox → Supabase, device status and the gateway heartbeat (docs/PLAN.md §5.4).

Two threads, as in decision D3: paho's network thread runs `handle_message` (validate, stamp,
commit to the outbox), and one uploader thread owns every HTTP call (readings, device rows,
heartbeat). They share only the outbox and a small dict of pending device updates.
"""

from __future__ import annotations

import logging
import re
import threading
import time
from collections import Counter
from collections.abc import Callable, Sequence
from typing import Any, Final, Protocol

import httpx

from . import __version__
from .buffer import Outbox
from .clock import Clock
from .config import Config
from .models import (
    DEVICE_ID_PATTERN,
    RESERVED_DEVICE_IDS,
    InvalidMessage,
    ReadingRow,
    parse_message,
    to_row,
)
from .mqtt_client import MessageHandler, MqttClient
from .uploader import SupabaseWriter, Uploader, UploadResult

log = logging.getLogger(__name__)

HEARTBEAT_S: Final = 300.0
HEARTBEAT_RETRY_S: Final = 60.0
INVALID_LOG_INTERVAL_S: Final = 60.0
FLUSH_TIMEOUT_S: Final = 10.0
HTTP_TIMEOUT_S: Final = 15.0
STATUSES: Final = frozenset({"online", "offline"})
_TOPIC_RE: Final = re.compile(r"olvar/v1/([^/]+)/(telemetry|status)")
_DEVICE_ID_RE: Final = re.compile(DEVICE_ID_PATTERN)


class Intake(Protocol):
    def start(self) -> None: ...
    def stop(self) -> None: ...


class DeviceFirstWriter:
    """Makes sure a batch's devices exist before its readings are sent.

    readings.device_id references devices.id, and a missing parent fails with 23503, which the
    uploader would dead-letter as a row error. The device ids come from the queued rows
    themselves, so this also holds for rows left in the outbox by an earlier run.
    """

    def __init__(self, writer: SupabaseWriter) -> None:
        self._writer = writer
        self._confirmed: set[str] = set()

    def confirm(self, device_id: str) -> None:
        self._confirmed.add(device_id)

    def upsert_readings(self, rows: Sequence[ReadingRow]) -> UploadResult:
        for device_id in dict.fromkeys(r.device_id for r in rows):
            if device_id in self._confirmed:
                continue
            result = self._writer.upsert_device(device_id)
            if not result.ok:
                return UploadResult(
                    "retryable",
                    result.error_class,
                    result.status,
                    result.code,
                    f"device {device_id} not created: {result.message}",
                )
            self._confirmed.add(device_id)
        result = self._writer.upsert_readings(rows)
        if any(reason.startswith("23503") for reason in result.rejected.values()):
            # A device row vanished after we confirmed it; recreate it next time instead of
            # dead-lettering valid readings. Rows already stored are re-sent idempotently.
            self._confirmed.clear()
            return UploadResult("retryable", "data", result.status, "23503", result.message)
        return result


class Service:
    def __init__(
        self,
        *,
        outbox: Outbox,
        writer: SupabaseWriter,
        clock: Clock,
        gateway_id: str,
        connect_mqtt: Callable[[MessageHandler], Intake] | None = None,
        rng: Callable[[], float] | None = None,
        heartbeat_s: float = HEARTBEAT_S,
        monotonic: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._outbox = outbox
        self._writer = writer
        self._clock = clock
        self._gateway_id = gateway_id
        self._readings = DeviceFirstWriter(writer)
        uploader_options = {"rng": rng} if rng is not None else {}
        self._uploader = Uploader(outbox, self._readings, clock, **uploader_options)
        self._heartbeat_s = heartbeat_s
        self._mono = monotonic
        self._sleep = sleep
        self._mqtt = connect_mqtt(self.handle_message) if connect_mqtt else None

        self._wake = threading.Event()
        self._stopping = threading.Event()
        self._thread: threading.Thread | None = None
        self._pending_lock = threading.Lock()
        self._pending: dict[str, dict[str, Any]] = {}
        self._next_heartbeat = 0.0
        self._upload_due = 0.0
        self._heartbeat_error: str | None = None
        self._invalid_last: dict[str, float] = {}
        self._invalid_suppressed: Counter[str] = Counter()
        self._last_depth: int | None = None
        self.counters: Counter[str] = Counter()

    # --- intake (paho's thread) -------------------------------------------------------------

    def handle_message(self, topic: str, payload: bytes, retained: bool = False) -> None:
        match = _TOPIC_RE.fullmatch(topic)
        if match is None:
            self._invalid(topic, "bad_topic", topic)
            return
        device_id, kind = match.groups()
        if kind == "telemetry":
            self._telemetry(topic, device_id, payload, retained)
        else:
            self._status(device_id, payload)

    def _telemetry(self, topic: str, device_id: str, payload: bytes, retained: bool) -> None:
        stamp = self._clock.now()
        if retained:
            # Its sampling time is unknown; stamping it now would invent a reading.
            self._invalid(device_id, "retained_telemetry", "devices must not retain telemetry")
            return
        try:
            telemetry = parse_message(topic, payload)
        except InvalidMessage as exc:
            self._invalid(device_id, exc.reason, exc.detail)
            return
        for name in telemetry.out_of_range:
            self.counters[f"out_of_range.{name}"] += 1
        if telemetry.out_of_range:
            self._invalid(device_id, "out_of_range", ",".join(telemetry.out_of_range), drop=False)
        row = to_row(telemetry, stamp)
        if self._outbox.put(row, stamp):
            self.counters["accepted"] += 1
        else:
            self.counters["duplicate"] += 1
        self._touch(device_id, fw=telemetry.fw, last_seen_at=row.recorded_at)
        self._wake.set()

    def _status(self, device_id: str, payload: bytes) -> None:
        if not _DEVICE_ID_RE.fullmatch(device_id) or device_id in RESERVED_DEVICE_IDS:
            self._invalid(device_id, "invalid_device_id", device_id)
            return
        if not payload:
            return
        status = payload.decode("utf-8", errors="replace")
        if status not in STATUSES:
            self._invalid(device_id, "invalid_status", status[:40])
            return
        stamp = self._clock.now()
        seen = stamp.wall if status == "online" and stamp.synced else None
        self.counters[f"status.{status}"] += 1
        log.info("device %s is %s", device_id, status, extra={"device_id": device_id})
        self._touch(device_id, status=status, last_seen_at=seen)
        self._wake.set()

    def _touch(self, device_id: str, **fields: Any) -> None:
        with self._pending_lock:
            pending = self._pending.setdefault(device_id, {})
            pending.update({k: v for k, v in fields.items() if v is not None})

    def _invalid(self, device_id: str, reason: str, detail: str, *, drop: bool = True) -> None:
        if drop:
            self.counters[f"invalid.{reason}"] += 1
        now = self._mono()
        last = self._invalid_last.get(device_id)
        if last is not None and now - last < INVALID_LOG_INTERVAL_S:
            self._invalid_suppressed[device_id] += 1
            return
        self._invalid_last[device_id] = now
        suppressed = self._invalid_suppressed.pop(device_id, 0)
        log.warning(
            "%s from %s: %s",
            "dropped message" if drop else "nulled out-of-range fields",
            device_id,
            reason,
            extra={
                "device_id": device_id,
                "reason": reason,
                "detail": detail,
                "suppressed": suppressed,
            },
        )

    # --- delivery (uploader thread) ---------------------------------------------------------

    def tick(self) -> float:
        """One round of delivery. Returns the seconds until the next round is due.

        Readings and device updates run only once the uploader's own backoff has elapsed, so
        the heartbeat's shorter retry cannot shorten it.
        """
        until_heartbeat = self._maybe_heartbeat()
        if self._mono() >= self._upload_due:
            self._flush_devices()
            self._upload_due = self._mono() + self._uploader.step()
        return max(0.0, min(self._upload_due - self._mono(), until_heartbeat))

    def _flush_devices(self, deadline: float | None = None) -> None:
        with self._pending_lock:
            pending, self._pending = self._pending, {}
        for device_id, fields in pending.items():
            if deadline is not None and self._mono() >= deadline:
                result = None
            else:
                result = self._writer.upsert_device(device_id, **fields)
            if result is None or result.outcome == "retryable":
                with self._pending_lock:
                    self._pending[device_id] = {**fields, **self._pending.get(device_id, {})}
            elif result.ok:
                self._readings.confirm(device_id)
            else:
                log.error("device %s update rejected: %s", device_id, result.describe())

    def _maybe_heartbeat(self) -> float:
        now = self._mono()
        if now < self._next_heartbeat:
            return self._next_heartbeat - now
        result = self._writer.heartbeat(self._gateway_id, __version__, self._outbox.depth())
        if result.ok:
            if self._heartbeat_error is not None:
                log.info("heartbeat recovered")
            self._heartbeat_error = None
            self._next_heartbeat = now + self._heartbeat_s
        else:
            error = result.describe()
            if error != self._heartbeat_error:
                log.error("heartbeat failed: %s", error)
            self._heartbeat_error = error
            self._next_heartbeat = now + min(HEARTBEAT_RETRY_S, self._heartbeat_s)
        return self._next_heartbeat - now

    def _run(self) -> None:
        while not self._stopping.is_set():
            try:
                delay = self.tick()
            except Exception:
                log.exception("delivery round failed")
                delay = HEARTBEAT_RETRY_S
            deadline = self._mono() + delay
            while not self._stopping.is_set():
                remaining = deadline - self._mono()
                if remaining <= 0 or not self._wake.wait(remaining):
                    break
                self._wake.clear()
                # A new row must not cut a backoff short, or a down Supabase gets one call per row.
                if not self._uploader.backing_off:
                    self._upload_due = 0.0
                    break

    # --- lifecycle --------------------------------------------------------------------------

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, name="uploader", daemon=True)
        self._thread.start()
        if self._mqtt is not None:
            self._mqtt.start()
        log.info("gateway %s started", self._gateway_id, extra={"version": __version__})

    def stop(self, flush_timeout: float = FLUSH_TIMEOUT_S) -> None:
        """Stop intake, deliver what can be delivered within `flush_timeout`, close the outbox."""
        if self._mqtt is not None:
            self._mqtt.stop()
        self._stopping.set()
        self._wake.set()
        if self._thread is not None:
            self._thread.join()
        if self.flush(flush_timeout):
            self._outbox.close()
        log.info("gateway stopped", extra={"queue_depth_at_stop": self._last_depth})

    def flush(self, timeout: float) -> bool:
        """Deliver for at most `timeout` seconds. False if a request was still in flight then.

        The drain runs on its own thread so a hung HTTP request cannot hold shutdown past the
        deadline. Undelivered rows stay committed in the outbox; an abandoned drain only loses
        acks, and the rows it already sent are re-sent idempotently on the next start.
        """
        deadline = self._mono() + timeout
        drain = threading.Thread(target=self._drain, args=(deadline,), name="flush", daemon=True)
        drain.start()
        drain.join(timeout)
        finished = not drain.is_alive()
        if not finished:
            log.error("flush still waiting on Supabase after %.0f s; giving up", timeout)
        self._last_depth = self._outbox.depth()
        return finished

    def _drain(self, deadline: float) -> None:
        while self._mono() < deadline:
            self._flush_devices(deadline)
            if self._mono() >= deadline:
                break
            delay = self._uploader.step()
            if delay == 0:
                continue
            with self._pending_lock:
                devices_pending = bool(self._pending)
            if not self._uploader.backing_off and not devices_pending:
                break
            self._sleep(min(delay, max(0.0, deadline - self._mono())))


def build(config: Config) -> Service:
    clock = Clock()
    outbox = Outbox(config.outbox_path, config.outbox_max_rows)
    client = httpx.Client(timeout=HTTP_TIMEOUT_S)
    writer = SupabaseWriter(config.supabase_url, config.supabase_secret_key, client)

    def connect_mqtt(handler: MessageHandler) -> MqttClient:
        return MqttClient(
            config.mqtt_host,
            config.mqtt_port,
            config.mqtt_username,
            config.mqtt_password,
            handler,
        )

    return Service(
        outbox=outbox,
        writer=writer,
        clock=clock,
        gateway_id=config.gateway_id,
        connect_mqtt=connect_mqtt,
    )
