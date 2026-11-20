# olvar-gateway

Olvar is a talking houseplant monitor for one peace lily (Spathiphyllum). This repo holds the Raspberry Pi gateway
(ESP32 telemetry over MQTT → SQLite outbox → Supabase) and everything that lives in Supabase: migrations, RLS, cron
jobs, `plant_status_v`, the `chat` Edge Function and the generated TypeScript types. The design and the cross-repo
contract are in [docs/PLAN.md](docs/PLAN.md); what changed per release is in [CHANGELOG.md](CHANGELOG.md).

## How the pieces fit

| Part | Repo | What it is |
|---|---|---|
| Sensor | [olvar-firmware](https://github.com/olvar-gh/olvar-firmware) | ESP32-WROOM-32D with an SHT31 (I2C 0x44) for temperature and humidity, or a DHT11 on GPIO4 as the fallback, a BH1750 (GY-302 board, I2C 0x23) for light and a capacitive soil probe on GPIO34. Publishes one reading every 60 s over Wi-Fi/MQTT |
| Gateway | this repo | Raspberry Pi 3B on Raspberry Pi OS Lite 64-bit: Mosquitto plus the `olvar-gateway` Python service, which validates every message, buffers it durably and uploads it to Supabase |
| Backend | this repo, `supabase/` | Hosted Supabase project: Postgres schema with owner-only RLS, hourly/daily rollups, the derived plant status, and the `chat` Edge Function that answers as the plant with Claude (Anthropic Messages API) |
| App | [olvar-dashboard](https://github.com/olvar-gh/olvar-dashboard) | Expo app: the web build is hosted on Cloudflare Pages, the iOS app is built locally with Xcode |

The telemetry contract is [contracts/telemetry.v1.schema.json](contracts/telemetry.v1.schema.json), with examples
in `contracts/examples/`.

## Requirements

- [uv](https://docs.astral.sh/uv/) (Python 3.13)
- Supabase CLI **3.1.0** and Docker (for the local stack)
- Deno 2.x (for the `chat` function tests)
- shellcheck (for the deploy scripts)

## Checks

The same checks run in CI (`.github/workflows/ci.yml`):

```sh
uv sync --locked
uv run ruff check . && uv run ruff format --check .
uv run pytest                                  # unit tests; e2e/supabase markers are deselected

supabase start
supabase db reset --local                      # migrations + seed.sql (local/test data only)
supabase test db --local                       # pgTAP

deno test --allow-net=127.0.0.1 supabase/functions/chat
shellcheck deploy/*.sh deploy/test/*.sh
```

Not in CI, run them before a release:

```sh
# End to end: real Mosquitto, the local Supabase stack, the gateway and a fake ESP32 as processes (about 4 min)
docker compose -f dev/compose.yml up -d
supabase start
uv run pytest -m "e2e or supabase"

# install.sh and update.sh in a Debian Trixie arm64 container with systemd (needs Docker and shellcheck)
deploy/test/verify.sh
```

## Running locally without hardware

```sh
cp .env.example .env                           # points at the local stack and the dev broker
docker compose -f dev/compose.yml up -d        # Mosquitto; every dev user's password is olvar-dev
supabase start && supabase db reset --local
supabase status -o env | grep SECRET_KEY       # put this sb_secret_... value into SUPABASE_SECRET_KEY in .env
# in .env also set MQTT_PASSWORD=olvar-dev

# terminal 1: the gateway. A dev machine has no systemd NTP flag, so this launcher points the clock at a file
# that says "synced"; plain `python -m olvar_gateway` would hold every reading until a sync that never comes.
set -a; . ./.env; set +a
E2E_SYNC_FLAG=$(mktemp) uv run python tests/e2e/gateway_main.py

# terminal 2: a fake ESP32
uv run python tools/fake_esp32.py --device-id olvar-a1b2c3 --password olvar-dev --interval 2 --speed 60
```

`seed.sql` creates the local owner `dev@olvar.local` (password `olvar-dev-password`) with the plant and the device
`olvar-a1b2c3`.

## Generated types

`supabase/types/database.types.ts` is generated from the migrations and committed; the dashboard syncs a pinned
copy. After changing a migration, regenerate it against a freshly reset local stack:

```sh
supabase db reset --local
supabase gen types --lang typescript --local > supabase/types/database.types.ts
```

CI fails if the committed file differs from a regeneration. CI pins the CLI to 3.1.0 because `gen types` output can
change between releases; when you upgrade the CLI, bump the version in the workflow and regenerate in the same
commit. Without a matching local CLI, `npx supabase@3.1.0 gen types --lang typescript --local` gives the same
output.

## Deploying

CI never deploys. Production deploys are manual (`supabase db push --remote`, `supabase functions deploy chat`).
The step-by-step guide for Supabase and the Raspberry Pi is [docs/DEPLOY.md](docs/DEPLOY.md); daily operations are
in [docs/RUNBOOK.md](docs/RUNBOOK.md).

## Versions and releases

The version lives in `pyproject.toml` and `src/olvar_gateway/__init__.py` (a test keeps them equal); the gateway
reports it in `gateways.version` with every heartbeat. A release is a git tag `v<version>` on `main`, for example
`v0.1.0`, plus a [CHANGELOG.md](CHANGELOG.md) entry. The Pi moves to a tag with `sudo deploy/update.sh v0.1.0`
(see "Updating later" in [docs/DEPLOY.md](docs/DEPLOY.md)).

## License

[MIT](LICENSE)
