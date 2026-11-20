"""A fake ESP32 that speaks the telemetry contract (docs/PLAN.md §4) over MQTT.

    uv run python tools/fake_esp32.py --device-id olvar-fake --password olvar-dev \\
        --interval 1 --speed 600

Each published reading is echoed on stdout as one JSON line, so tests can tell what was sent.
`--speed` runs simulated time faster than real time; the day/night curve and soil drying follow
simulated time while `uptime_ms` and the publish cadence follow `--interval`.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import secrets
import signal
import sys
import threading
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any

import paho.mqtt.client as mqtt
from paho.mqtt.enums import CallbackAPIVersion

FW = "0.1.0-fake"
SOIL_WET_RAW = 1350
SOIL_WATER_AT_RAW = 2750
SOIL_DRYING_PER_HOUR = 9.0
LUX_PEAK = 2500.0
GARBAGE = (b"", b"not json", b"[1,2,3]", b'{"device_id":', b"\xff\xfe", b'{"seq":NaN}')


def telemetry_topic(device_id: str) -> str:
    return f"olvar/v1/{device_id}/telemetry"


def status_topic(device_id: str) -> str:
    return f"olvar/v1/{device_id}/status"


def new_boot_id(rng: random.Random) -> str:
    return f"{rng.getrandbits(32):08x}"


@dataclass
class Plant:
    """The physical world around the sensors, in simulated time."""

    rng: random.Random
    soil_raw: float = 2000.0
    watered: int = 0

    def advance(self, hours: float) -> None:
        self.soil_raw += SOIL_DRYING_PER_HOUR * hours
        if self.soil_raw >= SOIL_WATER_AT_RAW:
            self.soil_raw = SOIL_WET_RAW + self.rng.uniform(-40, 40)
            self.watered += 1

    def sample(self, at: datetime) -> dict[str, float | int]:
        hour = at.hour + at.minute / 60
        daylight = math.sin(math.pi * (hour - 6) / 12) if 6 <= hour <= 18 else 0.0
        lux = LUX_PEAK * daylight + self.rng.uniform(0, 5)
        temperature = 21.5 + 2.5 * math.sin(math.pi * (hour - 9) / 12) + self.rng.gauss(0, 0.2)
        humidity = 52 - 8 * daylight + self.rng.gauss(0, 1)
        soil = self.soil_raw + self.rng.gauss(0, 8)
        return {
            "temperature_c": round(temperature, 2),
            "humidity_pct": round(min(100, max(0, humidity)), 1),
            "lux": round(max(0.0, lux), 1),
            "soil_raw": int(min(4095, max(0, soil))),
        }


@dataclass
class Firmware:
    """Boot state and payload building, as the real firmware does it."""

    device_id: str
    rng: random.Random
    null_every: int = 0
    boot_id: str = ""
    seq: int = 0
    booted_mono: float = 0.0
    sent: int = field(default=0, init=False)

    def boot(self, mono: float) -> None:
        self.boot_id = new_boot_id(self.rng)
        self.seq = 0
        self.booted_mono = mono

    def reading(self, sample: dict[str, float | int], mono: float) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "device_id": self.device_id,
            "boot_id": self.boot_id,
            "seq": self.seq,
            "uptime_ms": int((mono - self.booted_mono) * 1000),
            **sample,
            "rssi_dbm": self.rng.randint(-72, -52),
            "climate_sensor": "sht31",
            "fw": FW,
        }
        self.sent += 1
        if self.null_every and self.sent % self.null_every == 0:
            failed = self.rng.choice(["temperature_c", "humidity_pct", "lux", "soil_raw"])
            payload[failed] = None
            if failed in ("temperature_c", "humidity_pct"):
                # One SHT31 read gives both values, so they fail together.
                payload["temperature_c"] = payload["humidity_pct"] = None
        self.seq += 1
        return payload


class Link:
    """MQTT session with the retained online/offline status and the last will."""

    def __init__(self, host: str, port: int, device_id: str, password: str) -> None:
        self.device_id = device_id
        self.client = mqtt.Client(
            CallbackAPIVersion.VERSION2, client_id=device_id, protocol=mqtt.MQTTv5
        )
        self.client.username_pw_set(device_id, password)
        self.client.will_set(status_topic(device_id), b"offline", qos=1, retain=True)
        self.client.on_connect = self._on_connect
        self.connected = threading.Event()
        self.refused: str | None = None
        self.host, self.port = host, port

    def _on_connect(self, client, userdata, flags, reason_code, properties) -> None:
        if reason_code.is_failure:
            self.refused = str(reason_code)
            return
        client.publish(status_topic(self.device_id), b"online", qos=1, retain=True)
        self.connected.set()

    def open(self, timeout: float = 10.0) -> None:
        self.client.connect(self.host, self.port, keepalive=15)
        self.client.loop_start()
        if not self.connected.wait(timeout):
            self.client.loop_stop()
            raise ConnectionError(self.refused or f"no CONNACK from {self.host}:{self.port}")

    def publish(self, topic: str, payload: bytes) -> None:
        self.client.publish(topic, payload, qos=1).wait_for_publish(10)

    def close(self) -> None:
        """A clean shutdown, like the firmware's goOffline(): publish offline, then disconnect."""
        self.client.publish(status_topic(self.device_id), b"offline", qos=1, retain=True)
        self.client.disconnect()
        self.client.loop_stop()

    def drop(self) -> None:
        """Reboot without a clean disconnect; the broker publishes the will."""
        self.client.loop_stop()
        self.client.socket().close()
        self.connected.clear()


def emit(event: str, **fields: Any) -> None:
    print(json.dumps({"event": event, **fields}), flush=True)


def run(args: argparse.Namespace, sleep: Callable[[float], None] = time.sleep) -> int:
    rng = random.Random(args.seed)
    firmware = Firmware(args.device_id, rng, null_every=args.null_every)
    plant = Plant(rng, soil_raw=args.soil_start)
    sim_now = datetime.now(UTC)
    link = Link(args.host, args.port, args.device_id, args.password)
    firmware.boot(time.monotonic())
    link.open()
    emit("boot", boot_id=firmware.boot_id)

    stopping = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stopping.set())
    signal.signal(signal.SIGINT, lambda *_: stopping.set())

    count = 0
    while not stopping.is_set() and (args.count == 0 or count < args.count):
        payload = firmware.reading(plant.sample(sim_now), time.monotonic())
        body = json.dumps(payload, allow_nan=False).encode()
        link.publish(telemetry_topic(args.device_id), body)
        emit("reading", **payload)
        if args.dup_every and payload["seq"] % args.dup_every == args.dup_every - 1:
            link.publish(telemetry_topic(args.device_id), body)
            emit("duplicate", boot_id=payload["boot_id"], seq=payload["seq"])
        count += 1
        if args.garbage_every and count % args.garbage_every == 0:
            garbage = rng.choice(GARBAGE)
            link.publish(telemetry_topic(args.device_id), garbage)
            emit("garbage", payload=garbage.decode("latin-1"))
        if args.reboot_every and count % args.reboot_every == 0:
            link.drop()
            firmware.boot(time.monotonic())
            link = Link(args.host, args.port, args.device_id, args.password)
            link.open()
            emit("boot", boot_id=firmware.boot_id)
        step = timedelta(seconds=args.interval * args.speed)
        sim_now += step
        plant.advance(step.total_seconds() / 3600)
        stopping.wait(args.interval)

    link.close()
    emit("stopped", sent=count, watered=plant.watered)
    return 0


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=1883)
    parser.add_argument("--device-id", default="olvar-fake")
    parser.add_argument("--password", required=True)
    parser.add_argument("--interval", type=float, default=60.0, help="real seconds per reading")
    parser.add_argument("--speed", type=float, default=1.0, help="simulated seconds per real one")
    parser.add_argument("--count", type=int, default=0, help="readings to send; 0 = forever")
    parser.add_argument("--reboot-every", type=int, default=0, help="readings per boot")
    parser.add_argument("--null-every", type=int, default=7, help="a failed sensor read every N")
    parser.add_argument("--dup-every", type=int, default=5, help="re-send every Nth reading")
    parser.add_argument("--garbage-every", type=int, default=11, help="a garbage payload every N")
    parser.add_argument("--soil-start", type=float, default=2000.0)
    parser.add_argument("--seed", type=int, default=None)
    args = parser.parse_args(argv)
    if args.seed is None:
        args.seed = secrets.randbits(32)
    return args


if __name__ == "__main__":
    sys.exit(run(parse_args(sys.argv[1:])))
