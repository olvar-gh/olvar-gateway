import argparse
import importlib.util
import json
from pathlib import Path

import httpx
import pytest

_SPEC = importlib.util.spec_from_file_location(
    "setup_plant", Path(__file__).resolve().parents[1] / "tools" / "setup_plant.py"
)
assert _SPEC and _SPEC.loader
setup_plant = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(setup_plant)

URL = "http://supabase.test"
ENV = {"SUPABASE_URL": URL, "SUPABASE_SECRET_KEY": "sb_secret_test"}
OWNER = "11111111-1111-1111-1111-111111111111"
OTHER = "22222222-2222-2222-2222-222222222222"


class FakeSupabase:
    def __init__(self) -> None:
        self.migrated = True
        self.profiles = [{"id": "spathiphyllum"}]
        self.users = [{"id": OTHER, "email": "other@example.com"}] * 250 + [
            {"id": OWNER, "email": "Owner@Example.com"}
        ]
        self.plants: list[dict] = []
        self.devices: dict[str, dict] = {}
        self.writes: list[tuple[str, str, dict]] = []

    def handler(self, request: httpx.Request) -> httpx.Response:
        assert request.headers["apikey"] == "sb_secret_test"
        path, q = request.url.path, dict(request.url.params)
        if path == "/auth/v1/admin/users":
            page, size = int(q["page"]), int(q["per_page"])
            return httpx.Response(200, json={"users": self.users[(page - 1) * size : page * size]})
        table = path.removeprefix("/rest/v1/")
        if not self.migrated:
            return httpx.Response(404, json={"code": "PGRST205", "message": "not found"})
        body = json.loads(request.content) if request.content else None
        if request.method != "GET":
            self.writes.append((request.method, table, body))
        if table == "plant_profiles":
            return httpx.Response(200, json=self.profiles)
        if table == "plants":
            return self.plants_endpoint(request.method, q, body)
        if table == "devices":
            return self.devices_endpoint(request.method, q, body)
        raise AssertionError(path)

    def plants_endpoint(self, method: str, q: dict, body: dict | None) -> httpx.Response:
        if body and body.get("timezone") == "Asia/Seol":
            return httpx.Response(
                400, json={"code": "22023", "message": "unknown timezone: Asia/Seol"}
            )
        if method == "GET":
            owner = q["owner_id"].removeprefix("eq.")
            return httpx.Response(200, json=[p for p in self.plants if p["owner_id"] == owner])
        if method == "POST":
            plant = {"id": f"plant-{len(self.plants) + 1}", **body}
            self.plants.append(plant)
            return httpx.Response(201, json=[plant])
        plant_id = q["id"].removeprefix("eq.")
        next(p for p in self.plants if p["id"] == plant_id).update(body)
        return httpx.Response(204)

    def devices_endpoint(self, method: str, q: dict, body: dict | None) -> httpx.Response:
        if method == "GET":
            rows = list(self.devices.values())
            if "id" in q and q["id"].startswith("eq."):
                rows = [d for d in rows if d["id"] == q["id"][3:]]
            if "plant_id" in q:
                rows = [
                    d
                    for d in rows
                    if d.get("plant_id") == q["plant_id"][3:] and d["id"] != q["id"][4:]
                ]
            return httpx.Response(200, json=rows)
        assert q["on_conflict"] == "id"
        self.devices.setdefault(body["id"], {}).update(body)
        return httpx.Response(201)


def args(**overrides) -> argparse.Namespace:
    values = {
        "owner_email": "owner@example.com",
        "device_id": "olvar-a1b2c3",
        "timezone": "Asia/Seoul",
        "nickname": None,
        "location": None,
        "env_file": None,
    }
    values.update(overrides)
    return argparse.Namespace(**values)


def run(fake: FakeSupabase, **overrides) -> str:
    client = httpx.Client(transport=httpx.MockTransport(fake.handler))
    return setup_plant.run(args(**overrides), ENV, client)


def test_creates_plant_and_device_and_prints_passwd_command_without_c():
    fake = FakeSupabase()
    out = run(fake)
    assert fake.plants == [
        {
            "id": "plant-1",
            "owner_id": OWNER,
            "profile_id": "spathiphyllum",
            "timezone": "Asia/Seoul",
        }
    ]
    assert fake.devices == {
        "olvar-a1b2c3": {"id": "olvar-a1b2c3", "owner_id": OWNER, "plant_id": "plant-1"}
    }
    assert "sudo mosquitto_passwd /etc/mosquitto/passwd olvar-a1b2c3" in out
    assert " -c " not in out


def test_rerun_reuses_plant_and_keeps_existing_device_columns():
    fake = FakeSupabase()
    run(fake)
    fake.devices["olvar-a1b2c3"]["soil_dry_raw"] = 3000
    out = run(fake, timezone="Europe/Berlin", nickname="Lily")
    assert len(fake.plants) == 1
    assert fake.plants[0]["timezone"] == "Europe/Berlin"
    assert fake.plants[0]["nickname"] == "Lily"
    assert fake.devices["olvar-a1b2c3"]["soil_dry_raw"] == 3000
    assert "updated" in out
    device_writes = [body for _, table, body in fake.writes if table == "devices"]
    assert all(set(body) == {"id", "owner_id", "plant_id"} for body in device_writes)


def test_device_created_by_gateway_before_setup_gets_linked():
    fake = FakeSupabase()
    fake.devices["olvar-a1b2c3"] = {"id": "olvar-a1b2c3", "owner_id": None, "fw": "0.1.0"}
    run(fake)
    assert fake.devices["olvar-a1b2c3"]["owner_id"] == OWNER
    assert fake.devices["olvar-a1b2c3"]["fw"] == "0.1.0"


def test_missing_migrations_says_db_push():
    fake = FakeSupabase()
    fake.migrated = False
    with pytest.raises(setup_plant.SetupError, match="supabase db push --remote"):
        run(fake)
    assert fake.writes == []


def test_missing_profile_says_db_push():
    fake = FakeSupabase()
    fake.profiles = []
    with pytest.raises(setup_plant.SetupError, match=r"spathiphyllum.*db push --remote"):
        run(fake)


def test_unknown_owner_email():
    fake = FakeSupabase()
    with pytest.raises(setup_plant.SetupError, match=r"no user with email nobody@example\.com"):
        run(fake, owner_email="nobody@example.com")
    assert fake.writes == []


def test_device_of_another_owner_is_refused():
    fake = FakeSupabase()
    fake.devices["olvar-a1b2c3"] = {"id": "olvar-a1b2c3", "owner_id": OTHER}
    with pytest.raises(setup_plant.SetupError, match="another user"):
        run(fake)
    assert fake.devices["olvar-a1b2c3"]["owner_id"] == OTHER


def test_second_device_for_the_plant_is_refused():
    fake = FakeSupabase()
    run(fake)
    with pytest.raises(setup_plant.SetupError, match="already linked to device olvar-a1b2c3"):
        run(fake, device_id="olvar-ffffff")


def test_unknown_timezone_is_explained():
    fake = FakeSupabase()
    with pytest.raises(setup_plant.SetupError, match=r"unknown timezone: Asia/Seol.*IANA"):
        run(fake, timezone="Asia/Seol")


@pytest.mark.parametrize("device_id", ["olvar-gateway", "Olvar-A1", "x", "olvar_a1b2c3"])
def test_bad_device_id_fails_before_any_request(device_id):
    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("no request expected")

    client = httpx.Client(transport=httpx.MockTransport(handler))
    with pytest.raises(setup_plant.SetupError, match="invalid device id"):
        setup_plant.run(args(device_id=device_id), ENV, client)


def test_publishable_key_is_refused():
    client = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(500)))
    env = {**ENV, "SUPABASE_SECRET_KEY": "sb_publishable_x"}
    with pytest.raises(setup_plant.SetupError, match="secret key"):
        setup_plant.run(args(), env, client)


def test_env_file_parsing(tmp_path):
    env_file = tmp_path / "gateway.env"
    env_file.write_text(
        "# c\nSUPABASE_URL=https://x.supabase.co\nSUPABASE_SECRET_KEY='sb_secret_y'\n\n"
    )
    assert setup_plant.read_env_file(env_file) == {
        "SUPABASE_URL": "https://x.supabase.co",
        "SUPABASE_SECRET_KEY": "sb_secret_y",
    }
