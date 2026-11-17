"""Fixtures for the end-to-end tests: the dev broker (dev/compose.yml), the local Supabase stack
(`supabase start`), the gateway and the fake device as real processes.

    docker compose -f dev/compose.yml up -d && supabase start && uv run pytest -m e2e
"""

from __future__ import annotations

import os
import signal
import socket
from collections.abc import Callable, Iterator
from pathlib import Path
from urllib.parse import urlparse

import httpx
import pytest
from support import (
    MQTT_HOST,
    MQTT_PORT,
    FakeDevice,
    Gateway,
    OutageProxy,
    Supabase,
    discover_supabase,
)


@pytest.fixture(scope="session")
def supabase() -> Supabase:
    stack = discover_supabase()
    with stack.client() as client:
        try:
            response = client.get("/devices", params={"select": "id", "limit": "1"})
        except httpx.HTTPError as exc:
            pytest.skip(f"local Supabase is not reachable at {stack.url}: {exc}")
    assert response.status_code == 200, response.text
    return stack


@pytest.fixture(scope="session")
def broker() -> tuple[str, int]:
    try:
        socket.create_connection((MQTT_HOST, MQTT_PORT), timeout=2).close()
    except OSError:
        pytest.skip(f"dev broker not running on {MQTT_HOST}:{MQTT_PORT}; see dev/compose.yml")
    return MQTT_HOST, MQTT_PORT


@pytest.fixture
def rest(supabase: Supabase) -> Iterator[httpx.Client]:
    with supabase.client() as client:
        yield client


@pytest.fixture
def proxy(supabase: Supabase) -> Iterator[OutageProxy]:
    parsed = urlparse(supabase.url)
    outage = OutageProxy(parsed.hostname or "127.0.0.1", parsed.port or 80)
    yield outage
    outage.close()


@pytest.fixture
def gateway(supabase: Supabase, proxy: OutageProxy, broker, tmp_path: Path) -> Iterator[Gateway]:
    flag = tmp_path / "synchronized"
    flag.touch()
    gw = Gateway(supabase, proxy, tmp_path / "outbox.db", flag, f"olvar-gw-e2e-{os.getpid()}")
    yield gw
    for proc in gw.procs:
        if proc.proc.poll() is None:
            proc.signal(signal.SIGTERM)


@pytest.fixture
def fake_device(broker) -> Iterator[Callable[[str], FakeDevice]]:
    made: list[FakeDevice] = []

    def make(device_id: str) -> FakeDevice:
        device = FakeDevice(device_id)
        made.append(device)
        return device

    yield make
    for device in made:
        for proc in device.procs:
            proc.kill()
