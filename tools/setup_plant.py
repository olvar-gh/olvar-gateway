"""Create (or update) the one plant and device of a v1 install in the hosted Supabase project.

    python tools/setup_plant.py --env-file /etc/olvar-gateway/gateway.env \\
        --owner-email you@example.com --device-id olvar-a1b2c3 --timezone Europe/Berlin

Reads SUPABASE_URL and SUPABASE_SECRET_KEY from --env-file or the environment. Safe to run again: it
reuses the owner's existing plant and only updates what the flags set.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

import httpx

PROFILE_ID = "spathiphyllum"
DEVICE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{2,31}$")
RESERVED_IDS = {"olvar-gateway"}
PASSWD_FILE = "/etc/mosquitto/passwd"
MIGRATIONS_HINT = "apply the migrations first: supabase db push --remote (see docs/DEPLOY.md)"


class SetupError(Exception):
    pass


def read_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip("'\"")
    return values


class Api:
    def __init__(self, url: str, secret_key: str, client: httpx.Client) -> None:
        self._url = url.rstrip("/")
        self._headers = {"apikey": secret_key}
        self._client = client

    def request(
        self,
        method: str,
        path: str,
        *,
        params: Mapping[str, str] | None = None,
        json: Any = None,
        prefer: str | None = None,
    ) -> httpx.Response:
        headers = dict(self._headers)
        if prefer:
            headers["Prefer"] = prefer
        try:
            return self._client.request(
                method, self._url + path, params=params, json=json, headers=headers
            )
        except httpx.HTTPError as exc:
            raise SetupError(f"cannot reach {self._url}: {exc}") from exc

    def rest(self, method: str, table: str, **kwargs: Any) -> Any:
        response = self.request(method, f"/rest/v1/{table}", **kwargs)
        if response.is_success:
            return response.json() if response.content else None
        raise rest_error(response, table)


def rest_error(response: httpx.Response, table: str) -> SetupError:
    try:
        body = response.json()
    except ValueError:
        body = {}
    code = str(body.get("code", "")) if isinstance(body, dict) else ""
    message = str(body.get("message", response.text)) if isinstance(body, dict) else response.text
    if response.status_code in (401, 403) or code == "42501":
        return SetupError(
            f"Supabase refused the key ({response.status_code} {code}): use the secret key "
            "'gateway' (sb_secret_...) of this project"
        )
    if code in ("PGRST205", "42P01") or response.status_code == 404:
        return SetupError(f"table public.{table} does not exist: {MIGRATIONS_HINT}")
    if code == "22023" and "timezone" in message:
        return SetupError(f"{message}; use an IANA name such as Europe/Berlin or Asia/Seoul")
    return SetupError(f"{table}: HTTP {response.status_code} {code} {message}".strip())


def require_profile(api: Api) -> None:
    rows = api.rest("GET", "plant_profiles", params={"select": "id", "id": f"eq.{PROFILE_ID}"})
    if not rows:
        raise SetupError(f"plant profile '{PROFILE_ID}' is missing: {MIGRATIONS_HINT}")


def find_owner_id(api: Api, email: str) -> str:
    wanted = email.strip().lower()
    page = 1
    while True:
        response = api.request(
            "GET", "/auth/v1/admin/users", params={"page": str(page), "per_page": "200"}
        )
        if response.status_code in (401, 403):
            raise SetupError("Supabase Auth refused the key: use the secret key 'gateway'")
        if not response.is_success:
            raise SetupError(f"listing users failed: HTTP {response.status_code} {response.text}")
        users = response.json().get("users", [])
        for user in users:
            if str(user.get("email", "")).lower() == wanted:
                return str(user["id"])
        if not users:
            raise SetupError(
                f"no user with email {email}: create it first in the Supabase dashboard "
                "(Authentication -> Users -> Add user)"
            )
        page += 1


def ensure_plant(
    api: Api, owner_id: str, timezone: str, nickname: str | None, location: str | None
) -> tuple[str, bool]:
    plants = api.rest(
        "GET",
        "plants",
        params={"select": "id", "owner_id": f"eq.{owner_id}", "order": "created_at"},
    )
    fields: dict[str, str] = {"timezone": timezone}
    if nickname is not None:
        fields["nickname"] = nickname
    if location is not None:
        fields["location"] = location
    if plants:
        plant_id = str(plants[0]["id"])
        api.rest("PATCH", "plants", params={"id": f"eq.{plant_id}"}, json=fields)
        return plant_id, False
    created = api.rest(
        "POST",
        "plants",
        json={"owner_id": owner_id, "profile_id": PROFILE_ID, **fields},
        prefer="return=representation",
    )
    return str(created[0]["id"]), True


def ensure_device(api: Api, device_id: str, owner_id: str, plant_id: str) -> None:
    existing = api.rest("GET", "devices", params={"select": "id,owner_id", "id": f"eq.{device_id}"})
    if existing and existing[0].get("owner_id") not in (None, owner_id):
        raise SetupError(f"device {device_id} already belongs to another user")
    others = api.rest(
        "GET",
        "devices",
        params={"select": "id", "plant_id": f"eq.{plant_id}", "id": f"neq.{device_id}"},
    )
    if others:
        raise SetupError(
            f"the plant is already linked to device {others[0]['id']}; v1 supports one device per "
            "plant (see docs/RUNBOOK.md, 'Replace the ESP32')"
        )
    # Only these three columns: the gateway may have created the row already, and calibration
    # must survive.
    api.rest(
        "POST",
        "devices",
        params={"on_conflict": "id"},
        json={"id": device_id, "owner_id": owner_id, "plant_id": plant_id},
        prefer="resolution=merge-duplicates,return=minimal",
    )


def run(args: argparse.Namespace, env: Mapping[str, str], client: httpx.Client) -> str:
    device_id = args.device_id.strip()
    if not DEVICE_ID_RE.fullmatch(device_id) or device_id in RESERVED_IDS:
        raise SetupError(
            f"invalid device id {device_id!r}: use the id from the ESP32 serial log, "
            "e.g. olvar-a1b2c3"
        )
    url = env.get("SUPABASE_URL", "").strip()
    key = env.get("SUPABASE_SECRET_KEY", "").strip()
    if not url or not key:
        raise SetupError("SUPABASE_URL and SUPABASE_SECRET_KEY are required (--env-file or env)")
    if not key.startswith("sb_secret_"):
        raise SetupError("SUPABASE_SECRET_KEY must be the secret key 'gateway' (sb_secret_...)")

    api = Api(url, key, client)
    require_profile(api)
    owner_id = find_owner_id(api, args.owner_email)
    plant_id, created = ensure_plant(api, owner_id, args.timezone, args.nickname, args.location)
    ensure_device(api, device_id, owner_id, plant_id)
    return "\n".join(
        [
            f"owner:  {args.owner_email} ({owner_id})",
            f"plant:  {plant_id} ({'created' if created else 'updated'}, timezone {args.timezone})",
            f"device: {device_id} (linked)",
            "",
            "Next, on the Pi, give the ESP32 its MQTT password (no -c: the file already exists):",
            f"  sudo mosquitto_passwd {PASSWD_FILE} {device_id}",
            f"  sudo chown mosquitto:mosquitto {PASSWD_FILE} && sudo chmod 0600 {PASSWD_FILE}",
            "  sudo systemctl restart mosquitto",
        ]
    )


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--owner-email", required=True)
    parser.add_argument("--device-id", required=True, help="from the ESP32 serial log")
    parser.add_argument("--timezone", required=True, help="IANA name, e.g. Asia/Seoul")
    parser.add_argument("--nickname")
    parser.add_argument("--location")
    parser.add_argument("--env-file", type=Path, help="e.g. /etc/olvar-gateway/gateway.env")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    env: dict[str, str] = dict(os.environ)
    if args.env_file:
        try:
            env.update(read_env_file(args.env_file))
        except OSError as exc:
            print(f"error: cannot read {args.env_file}: {exc.strerror}", file=sys.stderr)
            return 1
    try:
        with httpx.Client(timeout=20.0) as client:
            print(run(args, env, client))
    except SetupError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
