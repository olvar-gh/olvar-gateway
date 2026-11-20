import json
import logging
from datetime import UTC, datetime, timedelta

import httpx
import pytest

from olvar_gateway.buffer import Outbox
from olvar_gateway.clock import Clock, Stamp
from olvar_gateway.models import ReadingRow
from olvar_gateway.uploader import (
    BACKOFF_MAX_S,
    IDLE_DELAY_S,
    SupabaseWriter,
    Uploader,
    classify,
)

URL = "http://supabase.test"
KEY = "sb_secret_test"
T0 = datetime(2026, 11, 16, 12, 0, tzinfo=UTC)
CALIBRATION = {"soil_dry_raw", "soil_wet_raw", "soil_calibrated_at", "owner_id", "plant_id"}


def row(seq: int) -> ReadingRow:
    return ReadingRow(
        "olvar-a1b2c3",
        "3fa9c2e1",
        seq,
        seq * 60_000,
        T0 + timedelta(minutes=seq),
        23.4,
        48.2,
        1520.0,
        2214,
        -61,
        "ntp",
    )


class FakePostgrest:
    """Stores readings keyed like readings_dedup; `fail` forces a request-wide error."""

    def __init__(self) -> None:
        self.stored: dict[tuple, dict] = {}
        self.requests: list[httpx.Request] = []
        self.fail: tuple[int, dict | None] | None = None
        self.bad_seqs: set[int] = set()
        self.network_down = False

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.network_down:
            raise httpx.ConnectError("connection refused", request=request)
        if self.fail is not None:
            status, body = self.fail
            return httpx.Response(status, json=body)
        rows = json.loads(request.content)
        if request.url.path == "/rest/v1/readings":
            if any(r["seq"] in self.bad_seqs for r in rows):  # one statement: all or nothing
                return httpx.Response(
                    400, json={"code": "23514", "message": 'new row violates check constraint "x"'}
                )
            for r in rows:
                self.stored.setdefault((r["device_id"], r["boot_id"], r["seq"]), r)
        return httpx.Response(201)


@pytest.fixture
def server():
    return FakePostgrest()


@pytest.fixture
def writer(server):
    client = httpx.Client(transport=httpx.MockTransport(server))
    return SupabaseWriter(URL, KEY, client, now=lambda: T0)


@pytest.fixture
def outbox(tmp_path):
    box = Outbox(tmp_path / "outbox.db", now=lambda: T0)
    yield box
    box.close()


@pytest.fixture
def uploader(outbox, writer, tmp_path):
    clock = Clock(
        sync_flag=tmp_path / "synchronized", boot_id="b", wall=lambda: T0, mono_ns=lambda: 0
    )
    return Uploader(outbox, writer, clock, batch_size=500, rng=lambda: 1.0)


def fill(outbox: Outbox, n: int) -> None:
    for seq in range(n):
        outbox.put(row(seq), Stamp(T0, 0, "b", True))


def test_request_shape(server, writer):
    assert writer.upsert_readings([row(1)]).ok
    [req] = server.requests
    assert req.method == "POST"
    assert req.url.path == "/rest/v1/readings"
    assert req.url.params["on_conflict"] == "device_id,boot_id,seq"
    assert req.headers["apikey"] == KEY
    assert req.headers["prefer"] == "resolution=ignore-duplicates,return=minimal"
    assert req.headers["content-type"] == "application/json"
    [body] = json.loads(req.content)
    assert body == {
        "device_id": "olvar-a1b2c3",
        "boot_id": "3fa9c2e1",
        "seq": 1,
        "uptime_ms": 60_000,
        "recorded_at": "2026-11-16T12:01:00+00:00",
        "temperature_c": 23.4,
        "humidity_pct": 48.2,
        "lux": 1520.0,
        "soil_raw": 2214,
        "rssi_dbm": -61,
        "clock_source": "ntp",
    }


def test_delivers_and_acks(server, outbox, uploader):
    fill(outbox, 3)
    assert uploader.step() == IDLE_DELAY_S
    assert outbox.depth() == 0
    assert len(server.stored) == 3
    assert uploader.step() == IDLE_DELAY_S  # empty outbox: idle tick, no request
    assert len(server.requests) == 1


def test_full_batch_asks_for_immediate_next_step(server, outbox, writer, tmp_path):
    fill(outbox, 5)
    clock = Clock(sync_flag=tmp_path / "s", boot_id="b", wall=lambda: T0, mono_ns=lambda: 0)
    up = Uploader(outbox, writer, clock, batch_size=2)
    assert up.step() == 0.0
    assert up.step() == 0.0
    assert up.step() == IDLE_DELAY_S
    assert outbox.depth() == 0


def test_redelivery_is_idempotent(server, writer):
    assert writer.upsert_readings([row(1), row(2)]).ok
    assert writer.upsert_readings([row(2), row(3)]).ok
    assert len(server.stored) == 3


@pytest.mark.parametrize(
    ("status", "body", "error_class"),
    [
        (500, {"code": "XX000", "message": "boom"}, "server"),
        (503, None, "server"),
        (429, None, "rate_limited"),
    ],
)
def test_transient_errors_back_off_and_recover(server, outbox, uploader, status, body, error_class):
    fill(outbox, 2)
    server.fail = (status, body)
    delays = [uploader.step() for _ in range(12)]
    assert delays[:4] == [1.0, 2.0, 4.0, 8.0]
    assert max(delays) == BACKOFF_MAX_S
    assert outbox.depth() == 2
    assert outbox.dead_letter_count() == 0
    assert outbox.last_error().startswith(error_class)

    server.fail = None
    assert uploader.step() == IDLE_DELAY_S
    assert outbox.depth() == 0
    assert not uploader.backing_off


def test_network_error_keeps_rows(server, outbox, uploader):
    fill(outbox, 2)
    server.network_down = True
    assert uploader.step() == 1.0
    assert outbox.depth() == 2
    assert outbox.last_error().startswith("network")
    server.network_down = False
    uploader.step()
    assert len(server.stored) == 2


@pytest.mark.parametrize(
    ("status", "body", "error_class"),
    [
        (401, {"message": "Invalid API key"}, "auth"),
        (403, {"code": "42501", "message": "permission denied for table readings"}, "auth"),
        (400, {"code": "42501", "message": "permission denied"}, "auth"),
        (404, {"code": "PGRST205", "message": "Could not find the table"}, "not_found"),
        (400, {"code": "PGRST204", "message": "Could not find the column"}, "schema"),
        (400, {"code": "42P01", "message": "relation does not exist"}, "client"),
        (400, None, "client"),
    ],
)
def test_request_wide_failures_never_dead_letter(
    server, outbox, uploader, caplog, status, body, error_class
):
    fill(outbox, 4)
    server.fail = (status, body)
    with caplog.at_level(logging.ERROR):
        for _ in range(3):
            assert uploader.step() >= 1.0
    assert outbox.depth() == 4
    assert outbox.dead_letter_count() == 0
    assert outbox.last_error().startswith(f"{error_class} {status}")
    assert uploader.last_error == outbox.last_error()
    # one request per step: no bisection for request-wide errors
    assert len(server.requests) == 3
    # one ERROR per error-class change, not per attempt
    assert len([r for r in caplog.records if r.levelno == logging.ERROR]) == 1

    server.fail = None  # key rotated / grant fixed
    uploader.step()
    assert outbox.depth() == 0
    assert len(server.stored) == 4
    assert uploader.last_error is None


def test_one_bad_row_is_isolated_by_bisection(server, outbox, uploader):
    fill(outbox, 10)
    server.bad_seqs = {7}
    uploader.step()
    assert outbox.depth() == 0
    assert outbox.dead_letter_count() == 1
    dead = outbox._db.execute("SELECT seq, reason FROM dead_letter").fetchall()
    assert dead == [(7, '23514: new row violates check constraint "x"')]
    assert sorted(k[2] for k in server.stored) == [0, 1, 2, 3, 4, 5, 6, 8, 9]
    assert len(server.requests) <= 1 + 2 * 4  # log2(10) levels, two halves each


def test_bisection_aborts_on_request_wide_error(server, writer):
    server.bad_seqs = {0}
    calls = {"n": 0}
    original = server.__call__

    def flaky(request):
        calls["n"] += 1
        if calls["n"] == 2:
            return httpx.Response(503)
        return original(request)

    writer._client = httpx.Client(transport=httpx.MockTransport(flaky))
    result = writer.upsert_readings([row(0), row(1)])
    assert result.outcome == "retryable"
    assert result.rejected == {}


@pytest.mark.parametrize("code", ["22001", "22P02", "23502", "23503", "23514"])
def test_row_error_codes_are_permanent(code):
    response = httpx.Response(409 if code == "23503" else 400, json={"code": code, "message": "m"})
    assert classify(response).outcome == "permanent"


def test_device_upsert_never_sends_calibration(server, writer):
    seen = T0 + timedelta(seconds=30)
    assert writer.upsert_device("olvar-a1b2c3", fw="0.1.0", last_seen_at=seen).ok
    assert writer.upsert_device("olvar-a1b2c3", status="offline", last_seen_at=seen).ok
    first, second = server.requests
    for req in (first, second):
        assert req.url.path == "/rest/v1/devices"
        assert req.url.params["on_conflict"] == "id"
        assert req.headers["prefer"] == "resolution=merge-duplicates,return=minimal"
        assert req.headers["apikey"] == KEY
        assert not CALIBRATION & set(json.loads(req.content))
    assert json.loads(first.content) == {
        "id": "olvar-a1b2c3",
        "fw": "0.1.0",
        "last_seen_at": seen.isoformat(),
    }
    assert json.loads(second.content) == {
        "id": "olvar-a1b2c3",
        "status": "offline",
        "last_seen_at": seen.isoformat(),
        "status_changed_at": seen.isoformat(),
    }


@pytest.mark.parametrize("value", ["sht31", None])
def test_device_upsert_sends_climate_sensor_only_when_given(server, writer, value):
    assert writer.upsert_device("olvar-a1b2c3", fw="0.1.0", climate_sensor=value).ok
    assert writer.upsert_device("olvar-a1b2c3").ok
    first, second = (json.loads(r.content) for r in server.requests)
    assert first == {"id": "olvar-a1b2c3", "fw": "0.1.0", "climate_sensor": value}
    assert second == {"id": "olvar-a1b2c3"}


def test_heartbeat(server, writer):
    # No owner_id: with merge-duplicates the heartbeat updates only the columns it sends, so the
    # owner claimed by tools/setup_plant.py is never changed or cleared.
    assert writer.heartbeat("olvar-gw", "0.1.0", 12).ok
    [req] = server.requests
    assert req.url.path == "/rest/v1/gateways"
    assert req.url.params["on_conflict"] == "id"
    assert req.headers["prefer"] == "resolution=merge-duplicates,return=minimal"
    assert json.loads(req.content) == {
        "id": "olvar-gw",
        "version": "0.1.0",
        "buffer_depth": 12,
        "last_seen_at": T0.isoformat(),
    }


def test_heartbeat_auth_failure_is_retryable(server, writer):
    server.fail = (401, {"message": "Invalid API key"})
    result = writer.heartbeat("olvar-gw", "0.1.0", 0)
    assert result.outcome == "retryable"
    assert result.error_class == "auth"


def test_backoff_stays_capped_after_very_long_outage(server, outbox, uploader):
    fill(outbox, 1)
    server.fail = (503, None)
    uploader._failures = 5000  # days of failures: 2**5000 would overflow a float
    assert uploader.step() == BACKOFF_MAX_S
    assert outbox.depth() == 1
    server.fail = None
    assert uploader.step() == IDLE_DELAY_S
    assert outbox.depth() == 0
