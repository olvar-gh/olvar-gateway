"""Helpers shared by the end-to-end tests."""

from __future__ import annotations

import contextlib
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import httpx
import pytest

ROOT = Path(__file__).resolve().parents[2]
FAKE_ESP32 = ROOT / "tools" / "fake_esp32.py"
GATEWAY_MAIN = Path(__file__).with_name("gateway_main.py")
MQTT_HOST = os.environ.get("OLVAR_DEV_MQTT_HOST", "127.0.0.1")
MQTT_PORT = int(os.environ.get("OLVAR_DEV_MQTT_PORT", "1883"))
MQTT_PASSWORD = os.environ.get("OLVAR_DEV_MQTT_PASSWORD", "olvar-dev")
LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1"}


def wait_for(predicate: Callable[[], Any], timeout: float, interval: float = 0.5) -> Any:
    deadline = time.monotonic() + timeout
    while True:
        result = predicate()
        if result or time.monotonic() >= deadline:
            return result
        time.sleep(interval)


@dataclass(frozen=True)
class Supabase:
    url: str
    secret_key: str

    def client(self) -> httpx.Client:
        return httpx.Client(
            base_url=f"{self.url}/rest/v1",
            headers={"apikey": self.secret_key},
            timeout=10,
        )


def discover_supabase() -> Supabase:
    url = os.environ.get("E2E_SUPABASE_URL")
    key = os.environ.get("E2E_SUPABASE_SECRET_KEY")
    if not (url and key):
        if shutil.which("supabase") is None:
            pytest.skip("supabase CLI not found; set E2E_SUPABASE_URL and E2E_SUPABASE_SECRET_KEY")
        proc = subprocess.run(
            ["supabase", "status", "-o", "json"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        try:
            status = json.loads(proc.stdout[proc.stdout.index("{") : proc.stdout.rindex("}") + 1])
        except ValueError:
            pytest.skip(f"local Supabase is not running (`supabase start`): {proc.stderr[-300:]}")
        url, key = status.get("API_URL"), status.get("SECRET_KEY")
        if not (url and key):
            pytest.skip("`supabase status` did not report API_URL and SECRET_KEY")
    if urlparse(url).hostname not in LOCAL_HOSTS:
        pytest.fail(f"E2E tests only run against a local Supabase stack, not {url}")
    return Supabase(url.rstrip("/"), key)


class OutageProxy:
    """A TCP proxy in front of Supabase that can be switched off.

    Taking the shared local stack down would also break anything else using it; refusing and
    cutting connections here looks the same to the gateway.
    """

    def __init__(self, upstream_host: str, upstream_port: int) -> None:
        self._upstream = (upstream_host, upstream_port)
        self._listener = socket.create_server(("127.0.0.1", 0))
        self.port = self._listener.getsockname()[1]
        self._up = threading.Event()
        self._up.set()
        self._lock = threading.Lock()
        self._open: set[socket.socket] = set()
        self._closed = False
        threading.Thread(target=self._accept, daemon=True).start()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def down(self) -> None:
        self._up.clear()
        with self._lock:
            sockets, self._open = self._open, set()
        for sock in sockets:
            with contextlib.suppress(OSError):
                sock.shutdown(socket.SHUT_RDWR)
            sock.close()

    def up(self) -> None:
        self._up.set()

    def close(self) -> None:
        self._closed = True
        self.down()
        self._listener.close()

    def _accept(self) -> None:
        while not self._closed:
            try:
                client, _ = self._listener.accept()
            except OSError:
                return
            if not self._up.is_set():
                client.close()
                continue
            try:
                upstream = socket.create_connection(self._upstream, timeout=5)
            except OSError:
                client.close()
                continue
            with self._lock:
                self._open.update((client, upstream))
            for src, dst in ((client, upstream), (upstream, client)):
                threading.Thread(target=self._pump, args=(src, dst), daemon=True).start()

    def _pump(self, src: socket.socket, dst: socket.socket) -> None:
        try:
            while chunk := src.recv(65536):
                dst.sendall(chunk)
        except OSError:
            pass
        finally:
            for sock in (src, dst):
                with contextlib.suppress(OSError):
                    sock.shutdown(socket.SHUT_RDWR)


class Process:
    """A child process whose stdout JSON lines are collected as they arrive."""

    def __init__(self, args: list[str], env: dict[str, str]) -> None:
        self.lines: list[dict[str, Any]] = []
        self.raw: list[str] = []
        self.proc = subprocess.Popen(
            args,
            env=env,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()

    def _read(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            self.raw.append(line)
            with contextlib.suppress(ValueError):
                self.lines.append(json.loads(line))

    def output(self) -> str:
        return "".join(self.raw[-60:])

    def kill(self) -> None:
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait(10)

    def signal(self, signum: int, timeout: float = 30) -> int:
        self.proc.send_signal(signum)
        code = self.proc.wait(timeout)
        self._reader.join(5)
        return code


@dataclass
class Gateway:
    supabase: Supabase
    proxy: OutageProxy
    outbox: Path
    sync_flag: Path
    gateway_id: str
    procs: list[Process] = field(default_factory=list)

    def env(self) -> dict[str, str]:
        return {
            **os.environ,
            "SUPABASE_URL": self.proxy.url,
            "SUPABASE_SECRET_KEY": self.supabase.secret_key,
            "MQTT_HOST": MQTT_HOST,
            "MQTT_PORT": str(MQTT_PORT),
            "MQTT_USERNAME": "olvar-gateway",
            "MQTT_PASSWORD": MQTT_PASSWORD,
            "OUTBOX_PATH": str(self.outbox),
            "GATEWAY_ID": self.gateway_id,
            "E2E_SYNC_FLAG": str(self.sync_flag),
            "PYTHONUNBUFFERED": "1",
        }

    def start(self) -> Process:
        proc = Process([sys.executable, str(GATEWAY_MAIN), "run"], self.env())
        self.procs.append(proc)
        connected = wait_for(
            lambda: (
                any(line.get("msg", "").startswith("mqtt connected") for line in proc.lines)
                or proc.proc.poll() is not None
            ),
            timeout=20,
            interval=0.1,
        )
        assert connected and proc.proc.poll() is None, proc.output()
        # The subscribe is sent from the CONNACK callback; give the SUBACK a moment.
        time.sleep(0.5)
        return proc

    def queue_depth(self) -> int:
        out = subprocess.run(
            [sys.executable, str(GATEWAY_MAIN), "status"],
            env=self.env(),
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        depth = next(line for line in out.splitlines() if line.startswith("queue_depth:"))
        return int(depth.split()[1])


@dataclass
class FakeDevice:
    device_id: str
    procs: list[Process] = field(default_factory=list)

    def start(self, *args: str) -> Process:
        proc = Process(
            [
                sys.executable,
                str(FAKE_ESP32),
                "--host",
                MQTT_HOST,
                "--port",
                str(MQTT_PORT),
                "--device-id",
                self.device_id,
                "--password",
                MQTT_PASSWORD,
                *args,
            ],
            {**os.environ, "PYTHONUNBUFFERED": "1"},
        )
        self.procs.append(proc)
        return proc


def published(proc: Process) -> dict[tuple[str, int], dict[str, Any]]:
    """Distinct readings the fake device sent, keyed like the readings dedup constraint."""
    readings = (line for line in proc.lines if line["event"] == "reading")
    return {(line["boot_id"], line["seq"]): line for line in readings}


def stored(rest: httpx.Client, device_id: str, boot_ids: set[str]) -> list[dict[str, Any]]:
    if not boot_ids:
        return []
    response = rest.get(
        "/readings",
        params={
            "device_id": f"eq.{device_id}",
            "boot_id": f"in.({','.join(sorted(boot_ids))})",
            "select": "boot_id,seq,uptime_ms,temperature_c,humidity_pct,lux,soil_raw,rssi_dbm,"
            "clock_source,recorded_at",
            "order": "boot_id,seq",
        },
    )
    response.raise_for_status()
    return response.json()


def device_row(rest: httpx.Client, device_id: str) -> dict[str, Any] | None:
    response = rest.get("/devices", params={"id": f"eq.{device_id}", "select": "*"})
    response.raise_for_status()
    rows = response.json()
    return rows[0] if rows else None
