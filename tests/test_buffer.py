import logging
import subprocess
import sys
import textwrap
from dataclasses import replace
from datetime import UTC, datetime, timedelta

import pytest

from olvar_gateway.buffer import BEYOND_RETENTION, Outbox
from olvar_gateway.clock import Clock, Stamp
from olvar_gateway.models import ReadingRow

T0 = datetime(2026, 11, 16, 12, 0, tzinfo=UTC)
BOOT = "boot-a"


def row(seq: int = 0, recorded_at: datetime | None = T0, **changes) -> ReadingRow:
    base = ReadingRow(
        device_id="olvar-a1b2c3",
        boot_id="3fa9c2e1",
        seq=seq,
        uptime_ms=60_000 * seq,
        recorded_at=recorded_at,
        temperature_c=23.4,
        humidity_pct=48.2,
        lux=1520.0,
        soil_raw=2214,
        rssi_dbm=-61,
        clock_source="ntp" if recorded_at else "unsynced",
    )
    return replace(base, **changes)


def stamp(mono_ns: int = 0, boot: str = BOOT, wall: datetime | None = T0, synced=True) -> Stamp:
    return Stamp(wall=wall, mono_ns=mono_ns, pi_boot_id=boot, synced=synced)


class Fake:
    def __init__(self) -> None:
        self.wall = T0
        self.mono = 10**12


@pytest.fixture
def fake():
    return Fake()


@pytest.fixture
def clock(tmp_path, fake):
    return Clock(
        sync_flag=tmp_path / "synchronized",
        boot_id=BOOT,
        wall=lambda: fake.wall,
        mono_ns=lambda: fake.mono,
    )


@pytest.fixture
def outbox(tmp_path, fake):
    box = Outbox(tmp_path / "outbox.db", now=lambda: fake.wall)
    yield box
    box.close()


def test_put_and_ready_round_trip(outbox):
    r = row(seq=1, rssi_dbm=None, soil_raw=None)
    assert outbox.put(r, stamp())
    assert outbox.depth() == 1
    [(row_id, got)] = outbox.ready(10)
    assert got == r
    assert got.recorded_at.tzinfo is not None
    outbox.ack([row_id])
    assert outbox.depth() == 0


def test_duplicate_put_is_noop(outbox):
    assert outbox.put(row(seq=5), stamp())
    assert not outbox.put(row(seq=5, temperature_c=99.0), stamp())
    assert outbox.depth() == 1
    assert outbox.ready(10)[0][1].temperature_c == 23.4


def test_ready_is_oldest_first_and_limited(outbox):
    for seq in range(5):
        outbox.put(row(seq=seq), stamp())
    assert [r.seq for _, r in outbox.ready(3)] == [0, 1, 2]


def test_survives_kill(tmp_path):
    db = tmp_path / "outbox.db"
    script = textwrap.dedent(
        f"""
        import os, signal
        from datetime import UTC, datetime
        from olvar_gateway.buffer import Outbox
        from olvar_gateway.clock import Stamp
        from olvar_gateway.models import ReadingRow
        box = Outbox({str(db)!r})
        t = datetime(2026, 11, 16, 12, 0, tzinfo=UTC)
        for seq in range(3):
            box.put(ReadingRow("olvar-a1b2c3", "3fa9c2e1", seq, 0, t, 1.0, 2.0, 3.0, 4, -50, "ntp"),
                    Stamp(t, 0, "b", True))
        os.kill(os.getpid(), signal.SIGKILL)
        """
    )
    proc = subprocess.run([sys.executable, "-c", script], check=False)
    assert proc.returncode == -9
    box = Outbox(db)
    assert box.depth() == 3
    assert [r.seq for _, r in box.ready(10)] == [0, 1, 2]
    box.close()


def test_cap_drops_oldest(tmp_path, caplog):
    box = Outbox(tmp_path / "outbox.db", max_rows=3)
    with caplog.at_level(logging.ERROR):
        for seq in range(5):
            assert box.put(row(seq=seq), stamp())
    assert box.depth() == 3
    assert [r.seq for _, r in box.ready(10)] == [2, 3, 4]
    assert any("dropped" in rec.message for rec in caplog.records if rec.levelno == logging.ERROR)
    box.close()


def test_unsynced_rows_are_held_then_backfilled(outbox, clock, fake, tmp_path):
    held = clock.now()
    assert not held.synced
    assert outbox.put(row(seq=1, recorded_at=None), held)
    assert outbox.ready(10) == []
    assert outbox.resolve_unsynced(clock) == 0  # still unsynced: keep holding
    assert outbox.depth() == 1

    fake.mono += 120 * 10**9
    fake.wall = datetime(2026, 11, 18, 9, 0, tzinfo=UTC)  # NTP fixed the wall clock
    (tmp_path / "synchronized").touch()
    assert outbox.resolve_unsynced(clock) == 1
    [(_, got)] = outbox.ready(10)
    assert got.clock_source == "backfilled"
    assert got.recorded_at == fake.wall - timedelta(seconds=120)


def test_earlier_boot_rows_released_as_unsynced(outbox, clock):
    best_effort = T0 - timedelta(days=1)
    outbox.put(row(seq=1, recorded_at=None), stamp(boot="boot-old", wall=best_effort, synced=False))
    assert outbox.resolve_unsynced(clock) == 1  # even before this boot syncs
    [(_, got)] = outbox.ready(10)
    assert got.clock_source == "unsynced"
    assert got.recorded_at == best_effort


def test_rows_beyond_retention_are_dead_lettered(outbox):
    outbox.put(row(seq=1, recorded_at=T0 - timedelta(days=89, seconds=1)), stamp())
    outbox.put(row(seq=2, recorded_at=T0 - timedelta(days=88)), stamp())
    assert [r.seq for _, r in outbox.ready(10)] == [2]
    assert outbox.dead_letter_count() == 1
    reason = outbox._db.execute("SELECT reason, seq FROM dead_letter").fetchone()
    assert reason == (BEYOND_RETENTION, 1)


def test_dead_letter_moves_rows(outbox):
    for seq in range(3):
        outbox.put(row(seq=seq), stamp())
    ids = [i for i, _ in outbox.ready(10)]
    outbox.dead_letter([ids[1]], "23514: check violation")
    assert outbox.depth() == 2
    assert outbox.dead_letter_count() == 1
    assert [r.seq for _, r in outbox.ready(10)] == [0, 2]


def test_mark_failed_keeps_rows_and_records_last_error(outbox, fake):
    for seq in range(2):
        outbox.put(row(seq=seq), stamp())
    ids = [i for i, _ in outbox.ready(10)]
    assert outbox.last_error() is None
    outbox.mark_failed(ids, "auth 401")
    fake.wall += timedelta(seconds=5)
    outbox.mark_failed(ids, "server 503")
    assert outbox.depth() == 2
    assert outbox.last_error() == "server 503"
    attempts = outbox._db.execute("SELECT attempts FROM outbox").fetchall()
    assert attempts == [(2,), (2,)]
    outbox.ack(ids)
    assert outbox.last_error() is None
