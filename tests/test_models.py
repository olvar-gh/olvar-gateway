import json
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

import jsonschema
import pytest

from olvar_gateway.models import (
    MAX_PAYLOAD_BYTES,
    InvalidMessage,
    ReadingRow,
    Telemetry,
    parse_message,
    to_row,
)

CONTRACTS = Path(__file__).resolve().parents[1] / "contracts"
SCHEMA = json.loads((CONTRACTS / "telemetry.v1.schema.json").read_text())
EXAMPLES = sorted((CONTRACTS / "examples").glob("*.json"))
TOPIC = "olvar/v1/olvar-a1b2c3/telemetry"

BASE = {
    "device_id": "olvar-a1b2c3",
    "boot_id": "3fa9c2e1",
    "seq": 42,
    "uptime_ms": 2520113,
    "temperature_c": 23.4,
    "humidity_pct": 48.2,
    "lux": 1520.0,
    "soil_raw": 2214,
    "rssi_dbm": -61,
    "fw": "0.1.0",
}


def payload(**changes) -> bytes:
    data = {**BASE, **changes}
    for key in [k for k, v in changes.items() if v is ...]:
        del data[key]
    return json.dumps(data).encode()


@dataclass(frozen=True)
class FakeStamp:
    wall: datetime | None
    synced: bool


def test_schema_is_valid_draft_2020_12():
    jsonschema.Draft202012Validator.check_schema(SCHEMA)


def test_schema_has_no_soil_pct_and_optional_rssi():
    assert "soil_pct" not in SCHEMA["properties"]
    assert "rssi_dbm" in SCHEMA["properties"]
    assert "rssi_dbm" not in SCHEMA["required"]
    assert SCHEMA["additionalProperties"] is True


def test_examples_cover_both_outcomes():
    names = [p.name for p in EXAMPLES]
    assert any(n.startswith("valid-") for n in names)
    assert any(n.startswith("invalid-") for n in names)
    assert all(n.startswith(("valid-", "invalid-")) for n in names)


@pytest.mark.parametrize("path", EXAMPLES, ids=lambda p: p.stem)
def test_schema_and_model_agree_on_examples(path: Path):
    expected_valid = path.name.startswith("valid-")
    data = json.loads(path.read_text())

    schema_valid = jsonschema.Draft202012Validator(SCHEMA).is_valid(data)
    try:
        parse_message(TOPIC, path.read_bytes())
        model_valid = True
    except InvalidMessage:
        model_valid = False

    assert schema_valid is expected_valid
    assert model_valid is expected_valid


def test_parse_full_example():
    t = parse_message(TOPIC, payload())
    assert t.model_dump() == BASE
    assert t.out_of_range == ()


def test_rssi_is_optional():
    assert parse_message(TOPIC, payload(rssi_dbm=...)).rssi_dbm is None


def test_null_sensors_accepted():
    t = parse_message(
        TOPIC, payload(temperature_c=None, humidity_pct=None, lux=None, soil_raw=None)
    )
    assert (t.temperature_c, t.humidity_pct, t.lux, t.soil_raw) == (None, None, None, None)
    assert t.out_of_range == ()


@pytest.mark.parametrize("field", ["temperature_c", "humidity_pct", "lux", "soil_raw", "fw"])
def test_required_fields(field):
    with pytest.raises(InvalidMessage):
        parse_message(TOPIC, payload(**{field: ...}))


def test_unknown_fields_ignored_including_soil_pct():
    t = parse_message(TOPIC, payload(soil_pct=40.0, heap_free=1234, nested={"a": 1}))
    assert not hasattr(t, "soil_pct")
    assert "soil_pct" not in t.model_dump()


def test_integral_float_accepted_for_integer_fields():
    t = parse_message(TOPIC, payload(soil_raw=2214.0, seq=3.0))
    assert t.soil_raw == 2214 and isinstance(t.soil_raw, int)
    assert t.seq == 3 and isinstance(t.seq, int)


def test_ints_accepted_for_float_fields():
    t = parse_message(TOPIC, payload(temperature_c=21, lux=0))
    assert t.temperature_c == 21.0 and t.lux == 0.0


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("temperature_c", -40.1),
        ("temperature_c", 125.5),
        ("humidity_pct", -0.1),
        ("humidity_pct", 100.01),
        ("lux", -1),
        ("lux", 120_000.5),
        ("soil_raw", -1),
        ("soil_raw", 4096),
        ("rssi_dbm", -121),
        ("rssi_dbm", 1),
    ],
)
def test_out_of_range_becomes_null(field, value):
    t = parse_message(TOPIC, payload(**{field: value}))
    assert getattr(t, field) is None
    assert t.out_of_range == (field,)
    others = {k: v for k, v in t.model_dump().items() if k != field}
    assert others == {k: v for k, v in BASE.items() if k != field}


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("temperature_c", -40),
        ("temperature_c", 125),
        ("humidity_pct", 0),
        ("humidity_pct", 100),
        ("lux", 120_000),
        ("soil_raw", 0),
        ("soil_raw", 4095),
        ("rssi_dbm", -120),
        ("rssi_dbm", 0),
    ],
)
def test_range_bounds_are_inclusive(field, value):
    t = parse_message(TOPIC, payload(**{field: value}))
    assert getattr(t, field) == value
    assert t.out_of_range == ()


def test_multiple_out_of_range_fields_reported():
    t = parse_message(TOPIC, payload(temperature_c=-127.0, soil_raw=9999))
    assert set(t.out_of_range) == {"temperature_c", "soil_raw"}


@pytest.mark.parametrize("literal", ["NaN", "Infinity", "-Infinity"])
def test_nan_and_infinity_rejected(literal):
    raw = payload().replace(b'"temperature_c": 23.4', f'"temperature_c": {literal}'.encode())
    assert literal.encode() in raw
    with pytest.raises(InvalidMessage) as exc:
        parse_message(TOPIC, raw)
    assert exc.value.reason == "non_finite"


def test_overflowing_float_rejected():
    # json.loads turns 1e400 into inf; the model must still refuse it.
    raw = payload().replace(b'"lux": 1520.0', b'"lux": 1e400')
    with pytest.raises(InvalidMessage):
        parse_message(TOPIC, raw)


def test_payload_over_1_kib_rejected():
    raw = payload(pad="x" * MAX_PAYLOAD_BYTES)
    assert len(raw) > MAX_PAYLOAD_BYTES
    with pytest.raises(InvalidMessage) as exc:
        parse_message(TOPIC, raw)
    assert exc.value.reason == "too_large"


def test_payload_of_exactly_1_kib_accepted():
    base = payload(pad="")
    raw = payload(pad="x" * (MAX_PAYLOAD_BYTES - len(base)))
    assert len(raw) == MAX_PAYLOAD_BYTES
    assert parse_message(TOPIC, raw).device_id == "olvar-a1b2c3"


def test_topic_device_id_mismatch_rejected():
    with pytest.raises(InvalidMessage) as exc:
        parse_message("olvar/v1/olvar-ffffff/telemetry", payload())
    assert exc.value.reason == "topic_mismatch"


@pytest.mark.parametrize(
    "topic",
    [
        "olvar/v1/olvar-a1b2c3/status",
        "olvar/v2/olvar-a1b2c3/telemetry",
        "olvar/v1/olvar-a1b2c3/telemetry/extra",
        "olvar/v1//telemetry",
    ],
)
def test_bad_topic_rejected(topic):
    with pytest.raises(InvalidMessage) as exc:
        parse_message(topic, payload())
    assert exc.value.reason == "bad_topic"


@pytest.mark.parametrize(
    "boot_id", ["3FA9C2E1", "3fa9c2e", "3fa9c2e10", "3fa9c2eg", "", 12345678, None]
)
def test_bad_boot_id_rejected(boot_id):
    with pytest.raises(InvalidMessage) as exc:
        parse_message(TOPIC, payload(boot_id=boot_id))
    assert exc.value.reason == "invalid_boot_id"


@pytest.mark.parametrize("device_id", ["ab", "-abc", "Olvar-a1b2c3", "olvar_a1b2c3", "a" * 33])
def test_bad_device_id_rejected(device_id):
    with pytest.raises(InvalidMessage):
        parse_message(f"olvar/v1/{device_id}/telemetry", payload(device_id=device_id))


def test_reserved_device_id_rejected():
    with pytest.raises(InvalidMessage):
        parse_message("olvar/v1/olvar-gateway/telemetry", payload(device_id="olvar-gateway"))


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("seq", -1),
        ("seq", 2**31),
        ("seq", True),
        ("seq", "1"),
        ("uptime_ms", -1),
        ("uptime_ms", 1.5),
        ("temperature_c", "23.4"),
        ("temperature_c", True),
        ("soil_raw", 2214.5),
        ("rssi_dbm", -61.5),
        ("fw", ""),
        ("fw", 1),
    ],
)
def test_bad_types_and_bounds_rejected(field, value):
    with pytest.raises(InvalidMessage) as exc:
        parse_message(TOPIC, payload(**{field: value}))
    assert exc.value.reason == f"invalid_{field}"


@pytest.mark.parametrize(
    ("raw", "reason"),
    [
        (b"\xff\xfe{}", "bad_encoding"),
        (b"{not json", "bad_json"),
        (b"", "bad_json"),
        (b"[1, 2]", "not_object"),
        (b'"online"', "not_object"),
    ],
)
def test_malformed_payloads_rejected(raw, reason):
    with pytest.raises(InvalidMessage) as exc:
        parse_message(TOPIC, raw)
    assert exc.value.reason == reason


def test_to_row_synced_clock():
    wall = datetime(2026, 11, 16, 12, 0, tzinfo=UTC)
    row = to_row(parse_message(TOPIC, payload()), FakeStamp(wall=wall, synced=True))
    assert row == ReadingRow(
        device_id="olvar-a1b2c3",
        boot_id="3fa9c2e1",
        seq=42,
        uptime_ms=2520113,
        recorded_at=wall,
        temperature_c=23.4,
        humidity_pct=48.2,
        lux=1520.0,
        soil_raw=2214,
        rssi_dbm=-61,
        clock_source="ntp",
    )


@pytest.mark.parametrize(
    "stamp",
    [
        FakeStamp(wall=datetime(1970, 1, 1, tzinfo=UTC), synced=False),
        FakeStamp(wall=None, synced=False),
        FakeStamp(wall=None, synced=True),
    ],
)
def test_to_row_unsynced_clock_leaves_recorded_at_empty(stamp):
    row = to_row(parse_message(TOPIC, payload()), stamp)
    assert row.recorded_at is None
    assert row.clock_source == "unsynced"


def test_to_row_carries_nulls():
    t = parse_message(TOPIC, payload(temperature_c=None, soil_raw=5000, rssi_dbm=...))
    row = to_row(t, FakeStamp(wall=datetime(2026, 11, 16, tzinfo=UTC), synced=True))
    assert (row.temperature_c, row.soil_raw, row.rssi_dbm) == (None, None, None)


def test_model_validates_directly():
    t = Telemetry.model_validate({**BASE, "lux": -5})
    assert t.lux is None and t.out_of_range == ("lux",)


def test_explicit_null_rssi_rejected():
    with pytest.raises(InvalidMessage) as exc:
        parse_message(TOPIC, payload(rssi_dbm=None))
    assert exc.value.reason == "invalid_rssi_dbm"


@pytest.mark.parametrize(
    ("field", "value"),
    [("boot_id", "3fa9c2e1\n"), ("device_id", "olvar-a1b2c3\n")],
)
def test_trailing_newline_identifiers_rejected_by_schema_and_model(field, value):
    data = {**BASE, field: value}
    assert not jsonschema.Draft202012Validator(SCHEMA).is_valid(data)
    topic = f"olvar/v1/{data['device_id']}/telemetry"
    with pytest.raises(InvalidMessage):
        parse_message(topic, json.dumps(data).encode())
