# Changelog

All notable changes to olvar-gateway. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and versions follow [Semantic Versioning](https://semver.org/). Each release is a git tag `v<version>`.

## [Unreleased]

## [0.1.0] - 2026-11-20

First public release. One owner, one peace lily, one ESP32 sensor, one Raspberry Pi 3B gateway and a hosted
Supabase project.

### Gateway (Raspberry Pi)

- `olvar-gateway` Python 3.13 service: subscribes to `olvar/v1/<device_id>/telemetry` and `/status` on the local
  Mosquitto, validates every message against the telemetry v1 contract
  ([contracts/telemetry.v1.schema.json](contracts/telemetry.v1.schema.json)) and drops invalid ones with a
  rate-limited log line. Out-of-range sensor values are stored as null.
- Durable SQLite outbox: every valid reading is committed before upload, deduplicated on
  `(device_id, boot_id, seq)`, and survives restarts and Supabase outages (up to 100,000 rows).
- Clock handling: readings that arrive before NTP sync are held and backfilled from the monotonic clock once it
  syncs.
- Uploader to Supabase PostgREST with the secret key: idempotent batches, exponential backoff, and bisection that
  dead-letters only the rows the database rejects.
- Device rows: firmware version, last seen, online/offline status (MQTT last will) and the climate sensor in use.
- Heartbeat to `gateways` every 5 minutes with the gateway version and queue depth.
- `python -m olvar_gateway status` and `--check-config`; JSON log lines for journald.
- Optional telemetry field `climate_sensor` (`sht31` or `dht11`), stored as `devices.climate_sensor`. A message
  without it sets the column to null; unknown values count as absent and never reject a message.

### Deployment

- `deploy/install.sh` for Raspberry Pi OS Lite 64-bit (Trixie): Mosquitto with per-device users and an ACL,
  nftables rule for MQTT from the LAN only, a sandboxed systemd unit, a journald cap, and pinned, hashed
  dependencies.
- `deploy/update.sh <tag>` moves the Pi to a release tag and re-runs the installer.
- `tools/setup_plant.py` creates the plant and the device and gives the gateway to the owner.
- Step-by-step [docs/DEPLOY.md](docs/DEPLOY.md) and [docs/RUNBOOK.md](docs/RUNBOOK.md).

### Supabase

- Schema with explicit grants and owner-only RLS: plant profiles (Spathiphyllum with sourced care thresholds),
  plants, devices with soil calibration, readings, gateways and chat messages.
- `soil_pct` computed at read time from the device calibration, so a recalibration re-expresses all history.
- Hourly and daily rollups and 90-day raw retention via pg_cron.
- `plant_status_v`: the status pill, per-metric labels and a one-line summary from deterministic threshold rules.
- `device_offline_periods()` for the dashboard Timeline.
- `chat` Edge Function: the plant answers in first person with Claude Sonnet 5.5 (`claude-sonnet-5-5`, switchable
  with `ANTHROPIC_MODEL`) from its live status and history, with an atomic per-plant rate limit.
- Generated TypeScript types in `supabase/types/database.types.ts` for the dashboard.

### Development

- Fake ESP32 publisher, a Mosquitto compose file and end-to-end tests against the local Supabase stack.
- CI: ruff, pytest, pgTAP, generated-types check, Deno tests for the chat function and shellcheck.

[Unreleased]: https://github.com/olvar-gh/olvar-gateway/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/olvar-gh/olvar-gateway/releases/tag/v0.1.0
