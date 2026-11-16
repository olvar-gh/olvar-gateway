import contextlib
import io
import json
import logging
import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx
import paho.mqtt.client as mqtt
import pytest
from paho.mqtt.enums import CallbackAPIVersion
from paho.mqtt.packettypes import PacketTypes
from paho.mqtt.properties import Properties

from olvar_gateway import __main__ as cli
from olvar_gateway import config, log
from olvar_gateway.buffer import Outbox
from olvar_gateway.clock import Clock
from olvar_gateway.mqtt_client import CLIENT_ID, MqttClient
from olvar_gateway.service import HEARTBEAT_S, Service
from olvar_gateway.uploader import SupabaseWriter, Uploader

URL = "http://supabase.test"
KEY = "sb_secret_test_key_value"
T0 = datetime(2026, 11, 16, 12, 0, tzinfo=UTC)
DEVICE = "olvar-a1b2c3"
TOPIC = f"olvar/v1/{DEVICE}/telemetry"
STATUS_TOPIC = f"olvar/v1/{DEVICE}/status"
ROOT = Path(__file__).resolve().parents[1]


def telemetry(seq: int, **overrides) -> bytes:
    body = {
        "device_id": DEVICE,
        "boot_id": "3fa9c2e1",
        "seq": seq,
        "uptime_ms": seq * 60_000,
        "temperature_c": 23.4,
        "humidity_pct": 48.2,
        "lux": 1520.0,
        "soil_raw": 2214,
        "rssi_dbm": -61,
        "fw": "0.1.0",
    }
    body.update(overrides)
    return json.dumps(body).encode()


ENV = {
    "SUPABASE_URL": "https://abc.supabase.co",
    "SUPABASE_SECRET_KEY": KEY,
    "MQTT_HOST": "127.0.0.1",
    "MQTT_PASSWORD": "pw",
}


def test_config_defaults():
    cfg = config.load(ENV)
    assert cfg.mqtt_port == 1883
    assert cfg.mqtt_username == "olvar-gateway"
    assert cfg.gateway_id == "olvar-gw"
    assert cfg.outbox_path == Path("/var/lib/olvar-gateway/outbox.db")
    assert cfg.outbox_max_rows == 100_000
    assert KEY not in json.dumps(cfg.redacted())
    assert cfg.redacted()["mqtt_password"] == "***"


def test_config_lists_every_problem():
    with pytest.raises(config.ConfigError) as err:
        config.load({"MQTT_PORT": "abc", "LOG_LEVEL": "loud"})
    text = str(err.value)
    for expected in (
        "SUPABASE_URL is required",
        "SUPABASE_SECRET_KEY is required",
        "MQTT_HOST is required",
        "MQTT_PASSWORD is required",
        "MQTT_PORT must be an integer",
        "LOG_LEVEL must be one of",
    ):
        assert expected in text


@pytest.mark.parametrize(
    ("overrides", "message"),
    [
        ({"SUPABASE_SECRET_KEY": "sb_publishable_x"}, "is a publishable key"),
        ({"SUPABASE_SECRET_KEY": "eyJhbGciOi"}, "must be a secret key"),
        ({"SUPABASE_URL": "abc.supabase.co"}, "must be an http(s) URL"),
        ({"SUPABASE_URL": "https://abc.supabase.co/rest/v1"}, "without a path"),
        ({"MQTT_PORT": "70000"}, "MQTT_PORT must be between"),
    ],
)
def test_config_rejects(overrides, message):
    with pytest.raises(config.ConfigError, match=message.replace("(", r"\(").replace(")", r"\)")):
        config.load({**ENV, **overrides})


def test_logs_are_json_lines():
    stream = io.StringIO()
    log.setup("INFO", stream)
    try:
        logging.getLogger("olvar_gateway.test").warning("hello %s", "pi", extra={"device_id": "d"})
        try:
            raise ValueError("boom")
        except ValueError:
            logging.getLogger("olvar_gateway.test").exception("failed")
    finally:
        logging.getLogger().handlers.clear()
    first, second = (json.loads(line) for line in stream.getvalue().splitlines())
    assert first["level"] == "WARNING"
    assert first["msg"] == "hello pi"
    assert first["device_id"] == "d"
    assert first["logger"] == "olvar_gateway.test"
    assert "ValueError: boom" in second["exc"]


class FakePostgrest:
    def __init__(self) -> None:
        self.requests: list[tuple[str, object]] = []
        self.attempts: list[str] = []
        self.status = 201

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.attempts.append(request.url.path)
        if self.status >= 300:
            return httpx.Response(self.status, json={"message": "down"})
        self.requests.append((request.url.path, json.loads(request.content)))
        return httpx.Response(201)

    def bodies(self, path: str) -> list:
        return [body for p, body in self.requests if p == path]


class FakeTime:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


@pytest.fixture
def server():
    return FakePostgrest()


@pytest.fixture
def fake_time():
    return FakeTime()


@pytest.fixture
def sync_flag(tmp_path):
    flag = tmp_path / "synchronized"
    flag.touch()
    return flag


@pytest.fixture
def make_service(tmp_path, server, fake_time, sync_flag):
    made = []

    def make(**kwargs) -> Service:
        clock = Clock(sync_flag=sync_flag, boot_id="pi-boot", wall=lambda: T0, mono_ns=lambda: 0)
        outbox = Outbox(tmp_path / "outbox.db", now=lambda: T0)
        writer = SupabaseWriter(
            URL, KEY, httpx.Client(transport=httpx.MockTransport(server)), now=lambda: T0
        )
        uploader = Uploader(outbox, writer, clock, rng=lambda: 1.0)
        service = Service(
            outbox=outbox,
            writer=writer,
            clock=clock,
            gateway_id="olvar-gw",
            uploader=uploader,
            monotonic=fake_time,
            sleep=fake_time.sleep,
            **kwargs,
        )
        made.append(service)
        return service

    yield make
    for service in made:
        with contextlib.suppress(Exception):
            service._outbox.close()


def test_telemetry_reaches_readings_and_device(make_service, server):
    service = make_service()
    service.handle_message(TOPIC, telemetry(1))
    service.tick()
    [readings] = server.bodies("/rest/v1/readings")
    assert readings[0]["seq"] == 1
    assert readings[0]["recorded_at"] == T0.isoformat()
    assert readings[0]["clock_source"] == "ntp"
    [device] = server.bodies("/rest/v1/devices")
    assert device == {"id": DEVICE, "fw": "0.1.0", "last_seen_at": T0.isoformat()}
    assert service._outbox.depth() == 0
    assert service.counters["accepted"] == 1


def test_duplicate_is_queued_once(make_service, server):
    service = make_service()
    service.handle_message(TOPIC, telemetry(1))
    service.handle_message(TOPIC, telemetry(1))
    assert service._outbox.depth() == 1
    assert service.counters["duplicate"] == 1


def test_unsynced_clock_holds_rows_and_sends_no_last_seen(make_service, server, sync_flag):
    sync_flag.unlink()
    service = make_service()
    service.handle_message(TOPIC, telemetry(1))
    service.tick()
    assert server.bodies("/rest/v1/readings") == []
    assert server.bodies("/rest/v1/devices") == [{"id": DEVICE, "fw": "0.1.0"}]
    assert service._outbox.depth() == 1


def test_retained_telemetry_is_dropped(make_service, server):
    service = make_service()
    service.handle_message(TOPIC, telemetry(1), retained=True)
    assert service._outbox.depth() == 0
    assert service.counters["invalid.retained_telemetry"] == 1


def test_invalid_messages_are_dropped_and_logged_once_a_minute(make_service, fake_time, caplog):
    service = make_service()
    caplog.set_level(logging.WARNING, "olvar_gateway.service")
    service.handle_message(TOPIC, b"not json")
    service.handle_message(TOPIC, telemetry(1, device_id="olvar-ffffff"))
    service.handle_message(TOPIC, b"x" * 2000)
    assert len(caplog.records) == 1
    fake_time.now += 61
    service.handle_message(TOPIC, b"{}")
    assert len(caplog.records) == 2
    assert caplog.records[1].suppressed == 2
    assert service.counters["invalid.bad_json"] == 1
    assert service.counters["invalid.topic_mismatch"] == 2
    assert service.counters["invalid.too_large"] == 1
    assert service._outbox.depth() == 0


def test_out_of_range_is_counted_and_kept(make_service):
    service = make_service()
    service.handle_message(TOPIC, telemetry(1, temperature_c=500))
    assert service._outbox.depth() == 1
    assert service.counters["out_of_range.temperature_c"] == 1


@pytest.mark.parametrize(
    ("payload", "expected"),
    [
        (b"online", {"status": "online", "last_seen_at": T0.isoformat()}),
        (b"offline", {"status": "offline"}),
    ],
)
def test_status_reaches_devices(make_service, server, payload, expected):
    service = make_service()
    service.handle_message(STATUS_TOPIC, payload, retained=True)
    service.tick()
    [device] = server.bodies("/rest/v1/devices")
    assert device == {"id": DEVICE, **expected, "status_changed_at": T0.isoformat()}


@pytest.mark.parametrize(
    ("topic", "payload"),
    [
        (STATUS_TOPIC, b"sleeping"),
        ("olvar/v1/olvar-gateway/status", b"online"),
        ("olvar/v1/BAD/status", b"online"),
        ("olvar/v1/x/y/status", b"online"),
    ],
)
def test_bad_status_is_ignored(make_service, server, topic, payload):
    service = make_service()
    service.handle_message(topic, payload)
    service.tick()
    assert server.bodies("/rest/v1/devices") == []


def test_cleared_retained_status_is_ignored(make_service, server):
    service = make_service()
    service.handle_message(STATUS_TOPIC, b"", retained=True)
    service.tick()
    assert server.bodies("/rest/v1/devices") == []


def test_device_update_is_retried_after_failure(make_service, server):
    service = make_service()
    service.handle_message(STATUS_TOPIC, b"offline")
    server.status = 503
    service.tick()
    service.handle_message(TOPIC, telemetry(1))
    server.status = 201
    service.tick()
    [device] = server.bodies("/rest/v1/devices")
    assert device["status"] == "offline"
    assert device["fw"] == "0.1.0"


def test_heartbeat_every_five_minutes(make_service, server, fake_time):
    service = make_service()
    service.handle_message(TOPIC, telemetry(1))
    service.tick()
    assert service.tick() <= HEARTBEAT_S
    [beat] = server.bodies("/rest/v1/gateways")
    assert beat["id"] == "olvar-gw"
    assert beat["buffer_depth"] == 1
    assert beat["version"]
    fake_time.now += HEARTBEAT_S - 1
    service.tick()
    assert len(server.bodies("/rest/v1/gateways")) == 1
    fake_time.now += 1
    service.tick()
    assert len(server.bodies("/rest/v1/gateways")) == 2


def test_failed_heartbeat_retries_within_a_minute(make_service, server, fake_time):
    service = make_service()
    server.status = 500
    assert service.tick() <= 60
    server.status = 201
    fake_time.now += 60
    service.tick()
    assert len(server.bodies("/rest/v1/gateways")) == 1


def test_stop_flushes_queue_and_closes_outbox(make_service, server):
    stopped = []

    class FakeMqtt:
        def __init__(self, handler):
            self.handler = handler

        def start(self):
            pass

        def stop(self):
            stopped.append(True)

    service = make_service(connect_mqtt=FakeMqtt)
    for seq in range(3):
        service._mqtt.handler(TOPIC, telemetry(seq), False)
    service.stop()
    assert stopped == [True]
    assert sum(len(b) for b in server.bodies("/rest/v1/readings")) == 3
    with pytest.raises(Exception, match="closed"):
        service._outbox.depth()


def test_flush_gives_up_after_timeout_while_supabase_is_down(make_service, server, fake_time):
    service = make_service()
    service.handle_message(TOPIC, telemetry(1))
    server.status = 503
    start = fake_time.now
    service.flush(10.0)
    assert 10.0 <= fake_time.now - start <= 11.0
    assert service._outbox.depth() == 1
    assert service._outbox.last_error().startswith("server 503")


def test_new_rows_do_not_cut_backoff_short(tmp_path, server, sync_flag):
    clock = Clock(sync_flag=sync_flag, boot_id="pi-boot", wall=lambda: T0, mono_ns=lambda: 0)
    outbox = Outbox(tmp_path / "outbox.db", now=lambda: T0)
    writer = SupabaseWriter(URL, KEY, httpx.Client(transport=httpx.MockTransport(server)))
    service = Service(outbox=outbox, writer=writer, clock=clock, gateway_id="gw")
    server.status = 503
    service.handle_message(TOPIC, telemetry(0))
    service.start()
    assert wait_for(lambda: "/rest/v1/readings" in server.attempts)
    for seq in range(1, 6):
        service.handle_message(TOPIC, telemetry(seq))
        time.sleep(0.02)
    assert server.attempts.count("/rest/v1/readings") == 1
    server.status = 201
    service.stop(flush_timeout=5.0)
    assert sum(len(b) for b in server.bodies("/rest/v1/readings")) == 6


def test_check_config_ok(monkeypatch, capsys):
    for name, value in ENV.items():
        monkeypatch.setenv(name, value)
    assert cli.main(["--check-config"]) == 0
    out = capsys.readouterr().out
    assert "config ok" in out
    assert KEY not in out


def test_check_config_reports_errors(monkeypatch, capsys):
    for name in (*ENV, "MQTT_PORT", "OUTBOX_PATH"):
        monkeypatch.delenv(name, raising=False)
    assert cli.main(["--check-config"]) == 2
    assert "SUPABASE_URL is required" in capsys.readouterr().err


def test_status_command(monkeypatch, capsys, tmp_path, sync_flag):
    path = tmp_path / "outbox.db"
    monkeypatch.setenv("OUTBOX_PATH", str(path))
    assert cli.main(["status"]) == 1
    outbox = Outbox(path, now=lambda: T0)
    clock = Clock(sync_flag=sync_flag, boot_id="b", wall=lambda: T0, mono_ns=lambda: 0)
    service = Service(outbox=outbox, writer=None, clock=clock, gateway_id="gw")
    service.handle_message(TOPIC, telemetry(1))
    service.handle_message(TOPIC, telemetry(2))
    ids = [i for i, _ in outbox.ready(10)]
    outbox.mark_failed(ids[:1], "auth 401 Invalid API key")
    outbox.dead_letter(ids[1:], "23514: bad")
    outbox.close()
    capsys.readouterr()
    assert cli.main(["status"]) == 0
    out = capsys.readouterr().out
    assert "queue_depth: 1" in out
    assert "dead_letters: 1" in out
    assert "last_error: auth 401 Invalid API key" in out


MOSQUITTO = shutil.which("mosquitto") or next(
    (p for p in ("/opt/homebrew/sbin/mosquitto", "/usr/sbin/mosquitto") if os.path.exists(p)),
    None,
)
needs_mosquitto = pytest.mark.skipif(MOSQUITTO is None, reason="mosquitto binary not installed")


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_for(predicate, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return predicate()


@pytest.fixture
def broker(tmp_path):
    port = free_port()
    conf = tmp_path / "mosquitto.conf"
    conf.write_text(f"listener {port} 127.0.0.1\nallow_anonymous true\npersistence false\n")
    proc = subprocess.Popen(
        [MOSQUITTO, "-c", str(conf)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )

    def accepting():
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            return True
        except OSError:
            return False

    assert wait_for(accepting), "mosquitto did not start"
    yield port
    proc.terminate()
    proc.wait(5)


def device_publish(port: int, topic: str, payload: bytes, *, retain: bool = False) -> None:
    client = mqtt.Client(CallbackAPIVersion.VERSION2, client_id="dev", protocol=mqtt.MQTTv5)
    client.connect("127.0.0.1", port)
    client.loop_start()
    client.publish(topic, payload, qos=1, retain=retain).wait_for_publish(5)
    client.disconnect()
    client.loop_stop()


class Received:
    def __init__(self) -> None:
        self.messages: list[tuple[str, bytes, bool]] = []

    def __call__(self, topic: str, payload: bytes, retained: bool) -> None:
        self.messages.append((topic, payload, retained))


@needs_mosquitto
def test_mqtt_delivers_live_telemetry_and_retained_status(broker):
    device_publish(broker, STATUS_TOPIC, b"online", retain=True)
    received = Received()
    client = MqttClient("127.0.0.1", broker, "olvar-gateway", "pw", received)
    client.start()
    try:
        assert client.connected.wait(5)
        assert wait_for(lambda: (STATUS_TOPIC, b"online", True) in received.messages)
        device_publish(broker, TOPIC, telemetry(1))
        assert wait_for(lambda: (TOPIC, telemetry(1), False) in received.messages)
    finally:
        client.stop()


@needs_mosquitto
def test_telemetry_queued_while_gateway_was_down_is_not_replayed(broker):
    # An earlier gateway left a persistent session behind (the pre-fix behaviour); the broker
    # queues QoS 1 telemetry for it while the service is down.
    old = mqtt.Client(CallbackAPIVersion.VERSION2, client_id=CLIENT_ID, protocol=mqtt.MQTTv5)
    props = Properties(PacketTypes.CONNECT)
    props.SessionExpiryInterval = 86_400
    old.connect("127.0.0.1", broker, clean_start=False, properties=props)
    old.loop_start()
    old.subscribe(TOPIC, qos=1)
    time.sleep(0.2)
    old.disconnect()
    old.loop_stop()
    device_publish(broker, TOPIC, telemetry(1))

    received = Received()
    client = MqttClient("127.0.0.1", broker, "olvar-gateway", "pw", received)
    client.start()
    try:
        assert client.connected.wait(5)
        time.sleep(0.3)
        device_publish(broker, TOPIC, telemetry(2))
        assert wait_for(lambda: any(p == telemetry(2) for _, p, _ in received.messages))
        time.sleep(0.2)
        assert [p for _, p, _ in received.messages] == [telemetry(2)]
    finally:
        client.stop()

    device_publish(broker, TOPIC, telemetry(3))
    again = Received()
    client = MqttClient("127.0.0.1", broker, "olvar-gateway", "pw", again)
    client.start()
    try:
        assert client.connected.wait(5)
        time.sleep(0.3)
        assert again.messages == []
    finally:
        client.stop()


class PostgrestHandler(BaseHTTPRequestHandler):
    received: list[tuple[str, object]]

    def do_POST(self) -> None:
        length = int(self.headers["Content-Length"])
        self.server.received.append((self.path.split("?")[0], json.loads(self.rfile.read(length))))
        self.send_response(201)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args) -> None:
        pass


@needs_mosquitto
def test_service_process_end_to_end_and_sigterm(broker, tmp_path):
    http = ThreadingHTTPServer(("127.0.0.1", 0), PostgrestHandler)
    http.received = []
    threading.Thread(target=http.serve_forever, daemon=True).start()
    env = {
        **os.environ,
        "SUPABASE_URL": f"http://127.0.0.1:{http.server_port}",
        "SUPABASE_SECRET_KEY": KEY,
        "MQTT_HOST": "127.0.0.1",
        "MQTT_PORT": str(broker),
        "MQTT_PASSWORD": "pw",
        "OUTBOX_PATH": str(tmp_path / "outbox.db"),
        "PYTHONPATH": str(ROOT / "src"),
    }
    proc = subprocess.Popen(
        [sys.executable, "-m", "olvar_gateway"],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        assert wait_for(lambda: any(p == "/rest/v1/gateways" for p, _ in http.received), 10)
        device_publish(broker, STATUS_TOPIC, b"online", retain=True)
        assert wait_for(
            lambda: any(
                p == "/rest/v1/devices" and b.get("status") == "online" for p, b in http.received
            ),
            10,
        )
        proc.send_signal(signal.SIGTERM)
        out, err = proc.communicate(timeout=15)
    finally:
        if proc.poll() is None:
            proc.kill()
        http.shutdown()
    assert proc.returncode == 0, err
    lines = [json.loads(line) for line in out.splitlines()]
    assert any(line["msg"] == "received SIGTERM, shutting down" for line in lines)
    assert lines[-1]["msg"] == "gateway stopped"
