"""Device → Mosquitto → gateway → Supabase, with real processes (docs/PLAN.md §6, T8)."""

from __future__ import annotations

import os
import signal
import time

import paho.mqtt.client as mqtt
import pytest
from paho.mqtt.enums import CallbackAPIVersion
from support import MQTT_PASSWORD, device_row, published, stored, wait_for

pytestmark = pytest.mark.e2e

OUTAGE_S = float(os.environ.get("E2E_OUTAGE_S", "120"))
# After an outage the uploader may be asleep for one more backoff (up to 5 min, with jitter).
RECOVERY_S = 330.0
SEED_DEVICE = "olvar-a1b2c3"


def wait_stored(rest, device_id, sent, timeout=30.0):
    boots = {boot for boot, _ in sent}
    rows = wait_for(
        lambda: (r := stored(rest, device_id, boots)) and len(r) >= len(sent) and r,
        timeout=timeout,
    )
    return rows or stored(rest, device_id, boots)


def assert_exactly(rows, sent):
    keys = [(r["boot_id"], r["seq"]) for r in rows]
    assert len(keys) == len(set(keys)), "duplicate readings stored"
    assert set(keys) == set(sent)


def test_happy_path_stores_every_reading_once(gateway, fake_device, rest):
    gateway.start()
    device = fake_device("olvar-e2e-happy")
    proc = device.start(
        "--count", "16", "--interval", "0.2", "--speed", "3600",
        "--reboot-every", "7", "--null-every", "3", "--dup-every", "4", "--garbage-every", "5",
    )  # fmt: skip
    assert proc.proc.wait(60) == 0, proc.output()
    sent = published(proc)
    assert len(sent) == 16
    events = [line["event"] for line in proc.lines]
    assert events.count("boot") == 3
    assert "duplicate" in events and "garbage" in events

    rows = wait_stored(rest, "olvar-e2e-happy", sent)
    assert_exactly(rows, sent)
    for row in rows:
        reading = sent[(row["boot_id"], row["seq"])]
        for name in ("uptime_ms", "soil_raw", "rssi_dbm"):
            assert row[name] == reading[name]
        for name in ("temperature_c", "humidity_pct", "lux"):
            assert row[name] == pytest.approx(reading[name], abs=0.01)
        assert row["clock_source"] == "ntp"
        assert row["recorded_at"] is not None
    sensors = ("temperature_c", "humidity_pct", "lux", "soil_raw")
    assert any(row[name] is None for row in rows for name in sensors)
    for boot in {b for b, _ in sent}:
        assert [r["seq"] for r in rows if r["boot_id"] == boot] == list(
            range(len([k for k in sent if k[0] == boot]))
        )

    device_state = wait_for(
        lambda: (d := device_row(rest, "olvar-e2e-happy")) and d["status"] == "offline" and d,
        timeout=15,
    )
    assert device_state, device_row(rest, "olvar-e2e-happy")
    assert device_state["fw"] == "0.1.0-fake"
    assert device_state["climate_sensor"] == "sht31"
    assert device_state["last_seen_at"] is not None


def test_supabase_outage_loses_nothing_and_duplicates_nothing(gateway, proxy, fake_device, rest):
    gateway.start()
    device = fake_device("olvar-e2e-outage")
    proc = device.start("--interval", "1", "--speed", "60", "--dup-every", "3")
    assert wait_for(lambda: len(published(proc)) >= 3, timeout=15)
    wait_stored(rest, "olvar-e2e-outage", published(proc))

    proxy.down()
    outage_started = len(published(proc))
    time.sleep(OUTAGE_S)
    sent_during_outage = len(published(proc)) - outage_started
    assert sent_during_outage >= OUTAGE_S * 0.8
    assert gateway.queue_depth() > 0
    proxy.up()

    time.sleep(3)
    assert proc.signal(signal.SIGTERM) == 0, proc.output()
    sent = published(proc)
    rows = wait_stored(rest, "olvar-e2e-outage", sent, timeout=RECOVERY_S)
    assert_exactly(rows, sent)
    assert wait_for(lambda: gateway.queue_depth() == 0, timeout=10)


@pytest.mark.parametrize("stop_signal", [signal.SIGTERM, signal.SIGKILL], ids=["term", "kill"])
def test_gateway_restart_loses_nothing(gateway, proxy, fake_device, rest, stop_signal):
    first = gateway.start()
    proxy.down()
    device = fake_device("olvar-e2e-restart")
    proc = device.start("--count", "5", "--interval", "0.2", "--dup-every", "2")
    assert proc.proc.wait(30) == 0, proc.output()
    before = published(proc)
    assert wait_for(lambda: gateway.queue_depth() == 5, timeout=15)

    first.signal(stop_signal)
    assert gateway.queue_depth() == 5
    proxy.up()
    gateway.start()

    after = device.start("--count", "3", "--interval", "0.2")
    assert after.proc.wait(30) == 0, after.output()
    sent = {**before, **published(after)}
    rows = wait_stored(rest, "olvar-e2e-restart", sent, timeout=60)
    assert_exactly(rows, sent)


def _connect(device_id: str, host: str, port: int) -> mqtt.Client:
    client = mqtt.Client(CallbackAPIVersion.VERSION2, client_id=device_id, protocol=mqtt.MQTTv5)
    client.username_pw_set(device_id, MQTT_PASSWORD)
    client.connect(host, port)
    client.loop_start()
    return client


def test_spoofed_device_id_is_rejected(gateway, fake_device, broker, rest):
    gw = gateway.start()
    host, port = broker
    spoof = _connect("olvar-e2e-spoof", host, port)
    try:
        payload = (
            b'{"device_id":"olvar-e2e-victim","boot_id":"5b00f5b0","seq":0,"uptime_ms":1,'
            b'"temperature_c":20,"humidity_pct":50,"lux":10,"soil_raw":2000,"fw":"x"}'
        )
        # The ACL lets a device write only its own topics; the broker drops this one.
        spoof.publish("olvar/v1/olvar-e2e-victim/telemetry", payload, qos=1).wait_for_publish(5)
        spoof.publish("olvar/v1/olvar-e2e-victim/status", b"offline", qos=1).wait_for_publish(5)
        # Own topic, someone else's id in the payload: the gateway rejects the mismatch.
        spoof.publish("olvar/v1/olvar-e2e-spoof/telemetry", payload, qos=1).wait_for_publish(5)
    finally:
        spoof.disconnect()
        spoof.loop_stop()

    control = fake_device("olvar-e2e-spoof").start("--count", "1", "--interval", "0")
    assert control.proc.wait(30) == 0, control.output()
    wait_stored(rest, "olvar-e2e-spoof", published(control))

    for device_id in ("olvar-e2e-victim", "olvar-e2e-spoof"):
        assert stored(rest, device_id, {"5b00f5b0"}) == []
    assert device_row(rest, "olvar-e2e-victim") is None
    assert any(
        line.get("msg", "").startswith("dropped message")
        and line.get("device_id") == "olvar-e2e-spoof"
        for line in gw.lines
    ), gw.output()


def plant_status(rest, device_id):
    response = rest.get(
        "/plant_status_v",
        params={"device_id": f"eq.{device_id}", "select": "overall,device_status"},
    )
    response.raise_for_status()
    rows = response.json()
    return rows[0] if rows else None


def test_last_will_marks_device_and_plant_offline(gateway, fake_device, rest):
    if plant_status(rest, SEED_DEVICE) is None:
        pytest.skip(f"{SEED_DEVICE} has no plant; run `supabase db reset` to load seed.sql")
    gateway.start()
    proc = fake_device(SEED_DEVICE).start("--interval", "0.5", "--null-every", "0")
    assert wait_for(lambda: len(published(proc)) >= 2, timeout=15)
    wait_stored(rest, SEED_DEVICE, published(proc))
    online = wait_for(
        lambda: (s := plant_status(rest, SEED_DEVICE)) and s["device_status"] == "online" and s,
        timeout=15,
    )
    assert online, plant_status(rest, SEED_DEVICE)
    assert online["overall"] != "offline"

    proc.signal(signal.SIGKILL)
    offline = wait_for(
        lambda: (s := plant_status(rest, SEED_DEVICE)) and s["device_status"] == "offline" and s,
        timeout=30,
    )
    assert offline, plant_status(rest, SEED_DEVICE)
    assert offline["overall"] == "offline"
