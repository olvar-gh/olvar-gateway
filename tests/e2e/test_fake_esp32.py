"""The fake device's simulation, without a broker; its payloads must pass the gateway's parser."""

import importlib.util
import json
import random
import sys
from datetime import UTC, datetime, timedelta

from support import FAKE_ESP32

from olvar_gateway.models import parse_message

spec = importlib.util.spec_from_file_location("fake_esp32", FAKE_ESP32)
fake = importlib.util.module_from_spec(spec)
sys.modules["fake_esp32"] = fake
spec.loader.exec_module(fake)

MIDNIGHT = datetime(2026, 11, 17, tzinfo=UTC)


def test_lux_follows_day_and_night():
    plant = fake.Plant(random.Random(1))
    night = plant.sample(MIDNIGHT + timedelta(hours=2))["lux"]
    noon = plant.sample(MIDNIGHT + timedelta(hours=12))["lux"]
    evening = plant.sample(MIDNIGHT + timedelta(hours=17))["lux"]
    assert night < 10
    assert noon > 2000
    assert night < evening < noon


def test_soil_dries_upwards_then_jumps_down_when_watered():
    plant = fake.Plant(random.Random(1), soil_raw=2000)
    raws = []
    for _ in range(24 * 30):
        plant.advance(1.0)
        raws.append(plant.soil_raw)
    assert plant.watered >= 1
    first_watering = next(i for i in range(1, len(raws)) if raws[i] < raws[i - 1])
    assert raws[:first_watering] == sorted(raws[:first_watering])
    assert raws[first_watering - 1] >= fake.SOIL_WATER_AT_RAW - fake.SOIL_DRYING_PER_HOUR
    assert raws[first_watering] < fake.SOIL_WET_RAW + 100


def test_boot_id_is_stable_per_boot_and_seq_restarts():
    firmware = fake.Firmware("olvar-fake", random.Random(7))
    plant = fake.Plant(random.Random(7))
    firmware.boot(100.0)
    first = [firmware.reading(plant.sample(MIDNIGHT), 100.0 + i) for i in range(3)]
    firmware.boot(200.0)
    second = [firmware.reading(plant.sample(MIDNIGHT), 200.5) for _ in range(2)]
    assert {r["boot_id"] for r in first} == {first[0]["boot_id"]}
    assert second[0]["boot_id"] != first[0]["boot_id"]
    assert [r["seq"] for r in first] == [0, 1, 2]
    assert [r["seq"] for r in second] == [0, 1]
    assert [r["uptime_ms"] for r in first] == [0, 1000, 2000]
    assert second[0]["uptime_ms"] == 500


def test_payloads_pass_the_gateway_parser_including_null_sensors():
    firmware = fake.Firmware("olvar-fake", random.Random(3), null_every=2)
    plant = fake.Plant(random.Random(3))
    firmware.boot(0.0)
    nulls = 0
    for i in range(40):
        payload = firmware.reading(plant.sample(MIDNIGHT + timedelta(hours=i)), float(i))
        body = json.dumps(payload, allow_nan=False).encode()
        assert len(body) <= 1024
        parsed = parse_message(fake.telemetry_topic("olvar-fake"), body)
        assert parsed.out_of_range == ()
        assert -120 <= payload["rssi_dbm"] <= 0
        nulls += any(
            payload[k] is None for k in ("temperature_c", "humidity_pct", "lux", "soil_raw")
        )
    assert nulls == 20
