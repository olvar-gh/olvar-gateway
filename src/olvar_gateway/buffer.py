"""Durable SQLite outbox between MQTT and the uploader (docs/PLAN.md §5.3, §5.4).

Every valid reading is committed here before anything is sent. Rows are unique on
(device_id, boot_id, seq), so a redelivered message is a no-op. Rows without a trustworthy
`recorded_at` are held until `resolve_unsynced` stamps them.
"""

from __future__ import annotations

import logging
import sqlite3
import threading
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Final

from .clock import Clock, Stamp
from .models import ReadingRow

log = logging.getLogger(__name__)

RETENTION: Final = timedelta(days=89)
BEYOND_RETENTION: Final = "beyond_retention"

_COLUMNS: Final = """
    device_id      TEXT    NOT NULL,
    boot_id        TEXT    NOT NULL,
    seq            INTEGER NOT NULL,
    uptime_ms      INTEGER NOT NULL,
    recorded_at_us INTEGER,            -- UTC epoch microseconds; NULL until the clock is trusted
    temperature_c  REAL,
    humidity_pct   REAL,
    lux            REAL,
    soil_raw       INTEGER,
    rssi_dbm       INTEGER,
    clock_source   TEXT    NOT NULL,
    mono_ns        INTEGER NOT NULL,
    pi_boot_id     TEXT    NOT NULL,
    wall_us        INTEGER,            -- best-effort wall time at receipt (unsynced fallback)
    enqueued_at_us INTEGER NOT NULL,
    attempts       INTEGER NOT NULL DEFAULT 0,
    last_error     TEXT,
    last_error_at_us INTEGER
"""
_FIELDS: Final = (
    "device_id, boot_id, seq, uptime_ms, recorded_at_us, temperature_c, humidity_pct, lux, "
    "soil_raw, rssi_dbm, clock_source, mono_ns, pi_boot_id, wall_us, enqueued_at_us, attempts, "
    "last_error, last_error_at_us"
)
_SCHEMA: Final = f"""
CREATE TABLE IF NOT EXISTS outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, {_COLUMNS});
CREATE UNIQUE INDEX IF NOT EXISTS outbox_dedup ON outbox (device_id, boot_id, seq);
CREATE INDEX IF NOT EXISTS outbox_unsynced ON outbox (id) WHERE recorded_at_us IS NULL;
CREATE TABLE IF NOT EXISTS dead_letter (
    id INTEGER PRIMARY KEY, {_COLUMNS},
    reason TEXT NOT NULL,
    dead_at_us INTEGER NOT NULL
);
"""


def _to_us(value: datetime | None) -> int | None:
    if value is None:
        return None
    if value.tzinfo is None:
        raise ValueError("datetimes must be timezone-aware")
    delta = value - datetime(1970, 1, 1, tzinfo=UTC)
    return delta // timedelta(microseconds=1)


def _from_us(value: int) -> datetime:
    return datetime(1970, 1, 1, tzinfo=UTC) + timedelta(microseconds=value)


class Outbox:
    def __init__(
        self,
        path: Path,
        max_rows: int = 100_000,
        *,
        now: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        self._max_rows = max_rows
        self._now = now
        self._lock = threading.Lock()  # paho's thread puts while the uploader thread reads
        self._db = sqlite3.connect(path, isolation_level=None, check_same_thread=False)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("PRAGMA synchronous=FULL")
        self._db.execute("PRAGMA busy_timeout=5000")
        self._db.executescript(_SCHEMA)

    @contextmanager
    def _tx(self) -> Iterator[sqlite3.Connection]:
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                yield self._db
            except BaseException:
                self._db.execute("ROLLBACK")
                raise
            self._db.execute("COMMIT")

    def close(self) -> None:
        with self._lock:
            self._db.close()

    def put(self, row: ReadingRow, stamp: Stamp) -> bool:
        """Queue a reading. False if (device_id, boot_id, seq) is already queued."""
        with self._tx() as db:
            cur = db.execute(
                "INSERT OR IGNORE INTO outbox (device_id, boot_id, seq, uptime_ms, recorded_at_us,"
                " temperature_c, humidity_pct, lux, soil_raw, rssi_dbm, clock_source, mono_ns,"
                " pi_boot_id, wall_us, enqueued_at_us) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    row.device_id,
                    row.boot_id,
                    row.seq,
                    row.uptime_ms,
                    _to_us(row.recorded_at),
                    row.temperature_c,
                    row.humidity_pct,
                    row.lux,
                    row.soil_raw,
                    row.rssi_dbm,
                    row.clock_source,
                    stamp.mono_ns,
                    stamp.pi_boot_id,
                    _to_us(stamp.wall),
                    _to_us(self._now()),
                ),
            )
            if cur.rowcount != 1:
                return False
            (count,) = db.execute("SELECT count(*) FROM outbox").fetchone()
            excess = count - self._max_rows
            if excess > 0:
                db.execute(
                    "DELETE FROM outbox WHERE id IN (SELECT id FROM outbox ORDER BY id LIMIT ?)",
                    (excess,),
                )
        if excess > 0:
            log.error("outbox full (%d rows): dropped %d oldest row(s)", self._max_rows, excess)
        return True

    def expire(self) -> int:
        """Dead-letter rows whose recorded_at is older than the server's raw retention."""
        cutoff = _to_us(self._now() - RETENTION)
        with self._tx() as db:
            ids = [
                r[0]
                for r in db.execute(
                    "SELECT id FROM outbox WHERE recorded_at_us < ? ORDER BY id", (cutoff,)
                )
            ]
            self._move_to_dead_letter(db, ids, BEYOND_RETENTION)
        if ids:
            log.warning("dead-lettered %d row(s) as %s", len(ids), BEYOND_RETENTION)
        return len(ids)

    def ready(self, limit: int) -> list[tuple[int, ReadingRow]]:
        """Oldest uploadable rows (recorded_at set), after expiring rows beyond retention."""
        self.expire()
        with self._lock:
            rows = self._db.execute(
                "SELECT id, device_id, boot_id, seq, uptime_ms, recorded_at_us, temperature_c,"
                " humidity_pct, lux, soil_raw, rssi_dbm, clock_source FROM outbox"
                " WHERE recorded_at_us IS NOT NULL ORDER BY id LIMIT ?",
                (limit,),
            ).fetchall()
        return [
            (
                r[0],
                ReadingRow(
                    device_id=r[1],
                    boot_id=r[2],
                    seq=r[3],
                    uptime_ms=r[4],
                    recorded_at=_from_us(r[5]),
                    temperature_c=r[6],
                    humidity_pct=r[7],
                    lux=r[8],
                    soil_raw=r[9],
                    rssi_dbm=r[10],
                    clock_source=r[11],
                ),
            )
            for r in rows
        ]

    def ack(self, ids: list[int]) -> None:
        with self._tx() as db:
            db.executemany("DELETE FROM outbox WHERE id = ?", [(i,) for i in ids])

    def dead_letter(self, ids: list[int], reason: str) -> None:
        with self._tx() as db:
            self._move_to_dead_letter(db, ids, reason)

    def _move_to_dead_letter(self, db: sqlite3.Connection, ids: list[int], reason: str) -> None:
        now = _to_us(self._now())
        db.executemany(
            f"INSERT OR REPLACE INTO dead_letter (id, {_FIELDS}, reason, dead_at_us)"
            f" SELECT id, {_FIELDS}, ?, ? FROM outbox WHERE id = ?",
            [(reason, now, i) for i in ids],
        )
        db.executemany("DELETE FROM outbox WHERE id = ?", [(i,) for i in ids])

    def mark_failed(self, ids: list[int], error: str) -> None:
        """Record a request-wide failure on rows that stay queued."""
        now = _to_us(self._now())
        with self._tx() as db:
            db.executemany(
                "UPDATE outbox SET attempts = attempts + 1, last_error = ?, last_error_at_us = ?"
                " WHERE id = ?",
                [(error, now, i) for i in ids],
            )

    def resolve_unsynced(self, clock: Clock) -> int:
        """Stamp held rows: backfill same-boot rows once synced; release earlier-boot rows with
        their best-effort time as 'unsynced'. Returns the number of rows stamped."""
        current_boot = clock.now().pi_boot_id
        with self._lock:
            held = self._db.execute(
                "SELECT id, mono_ns, pi_boot_id, wall_us FROM outbox"
                " WHERE recorded_at_us IS NULL ORDER BY id"
            ).fetchall()
        updates: list[tuple[int, str, int]] = []
        for row_id, mono_ns, pi_boot_id, wall_us in held:
            if pi_boot_id == current_boot:
                wall = clock.backfill(mono_ns, pi_boot_id)
                if wall is not None:
                    updates.append((_to_us(wall), "backfilled", row_id))
            else:
                # An earlier boot that never synced: its best-effort time is all we will ever have.
                fallback = wall_us if wall_us is not None else _to_us(self._now())
                updates.append((fallback, "unsynced", row_id))
        if updates:
            with self._tx() as db:
                db.executemany(
                    "UPDATE outbox SET recorded_at_us = ?, clock_source = ?"
                    " WHERE id = ? AND recorded_at_us IS NULL",
                    updates,
                )
        return len(updates)

    def depth(self) -> int:
        with self._lock:
            return self._db.execute("SELECT count(*) FROM outbox").fetchone()[0]

    def dead_letter_count(self) -> int:
        with self._lock:
            return self._db.execute("SELECT count(*) FROM dead_letter").fetchone()[0]

    def last_error(self) -> str | None:
        """The most recent request-wide error still attached to a queued row."""
        with self._lock:
            found = self._db.execute(
                "SELECT last_error FROM outbox WHERE last_error IS NOT NULL"
                " ORDER BY last_error_at_us DESC, id DESC LIMIT 1"
            ).fetchone()
        return found[0] if found else None
