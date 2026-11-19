# olvar-gateway

Raspberry Pi gateway (ESP32 telemetry over MQTT → SQLite outbox → Supabase) and everything that lives in
Supabase: migrations, RLS, cron jobs, `plant_status_v`, the `chat` Edge Function and the generated TypeScript
types. The design and the cross-repo contract are in [docs/PLAN.md](docs/PLAN.md).

## Requirements

- [uv](https://docs.astral.sh/uv/) (Python 3.13)
- Supabase CLI **3.1.0** and Docker (for the local stack)
- Deno 2.x (for the `chat` function tests)

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
```

## Generated types

`supabase/types/database.types.ts` is generated from the migrations and committed; the dashboard syncs a pinned
copy. After changing a migration, regenerate it against a freshly reset local stack:

```sh
supabase db reset --local
supabase gen types --lang typescript --local > supabase/types/database.types.ts
```

CI fails if the committed file differs from a regeneration. CI pins the CLI to 3.1.0 because `gen types` output can
change between releases; when you upgrade the CLI, bump the version in the workflow and regenerate in the same
commit.

## Deploying

CI never deploys. Production deploys are manual (`supabase db push --remote`, `supabase functions deploy chat`).
The step-by-step guide for Supabase and the Raspberry Pi is [docs/DEPLOY.md](docs/DEPLOY.md); daily operations are
in [docs/RUNBOOK.md](docs/RUNBOOK.md).

## License

[MIT](LICENSE)
