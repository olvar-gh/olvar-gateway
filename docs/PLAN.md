# olvar-gateway — Project plan (v1, final contract)

Scope of this repo:
- the Raspberry Pi gateway service (MQTT → validate → durable buffer → Supabase);
- the Mosquitto broker configuration;
- the Pi deployment;
- everything that lives in Supabase: schema, migrations, RLS, cron jobs, the derived plant status, the `chat` Edge
  Function, and the generated TypeScript types.

Firmware and dashboard have their own plans. §4 records the final cross-repo contract as the user decided it on
2026-11-16. Where this plan differed from that contract, the contract wins.

Research date: 2026-11-16. Numbers in brackets like [3] point to the sources list in §2.11.

---

## 1. Summary

- **v1 product:**
  - Sign-in with a single owner and owner-only RLS.
  - Screens: Home, Sensors, Timeline, Chat, Soil calibration, Settings/Account.
  - One plant and one device, created by a setup script.
  - Multi-plant support, pairing, notifications, care log, export, OTA and the other non-v1 items are out of scope.
    The schema contains only what v1 needs.
- **Runtime:** Python 3.13 (the version that ships with Raspberry Pi OS Trixie) runs as a **systemd** service on
  **Raspberry Pi OS Lite 64-bit (Trixie)**. Libraries: `paho-mqtt` 2.x, `httpx` and `pydantic` 2. The service does not
  use `supabase-py`; it calls PostgREST directly with a **secret key** (`sb_secret_…`) in the `apikey` header.
- **Broker:** Mosquitto 2.x from apt, unencrypted on the LAN on port 1883.
  - Anonymous access is off.
  - Each device has its own username and password, and the username is the `device_id`.
  - An ACL means a device can publish only to its own topics.
- **Durability:** every valid message first goes into a **SQLite outbox**. An uploader then sends it to Supabase as
  an idempotent upsert keyed on `(device_id, boot_id, seq)`. The ESP32 drops readings while the broker is
  unreachable; the Pi keeps buffering while Supabase is unreachable.
- **Soil calibration is stored in the database.** The Soil calibration screen writes `devices.soil_dry_raw` and
  `soil_wet_raw`. The database computes **`soil_pct` at read time** with a single SQL function, exposed through
  views. Recalibrating therefore re-expresses the whole history with the new calibration, and nothing is rewritten.
  Until the device is calibrated, `soil_pct` is null.
- **Status pill:** "Feeling great" and the other labels come from **deterministic threshold rules in one place**, the
  SQL view `plant_status_v`. The dashboard and the chat function both read it. No LLM is involved.
- **Chat with your plant:**
  - The Supabase Edge Function **`chat`** is called by the signed-in owner.
  - It stores the user's message through an **atomic quota check** (`chat_admit`), so concurrent requests cannot
    exceed the limits.
  - It gives DeepSeek **`deepseek-flash`** (thinking off) a context of plant profile, thresholds, `plant_status_v`,
    the latest reading, 24 h and 7 d summaries, and the last 20 messages.
  - It stores the reply and returns it. The plant answers in first person, in the language of the user's message.
  - The DeepSeek key exists only in Edge Function secrets.
  - Cost is about **$0.002 per message** at peak price.
- **Data volume and retention:** 1,440 readings a day is about 0.3 MB/day. Raw readings are kept for **90 days**.
  **Hourly and daily summaries** are built by pg_cron, which resumes from a persisted watermark and keeps
  per-metric sample counts.
- **Timeline offline periods** come from `device_offline_periods()`, which finds gaps of more than 180 s between raw
  readings. They are available for any day within the 90-day retention.
- **Keys:** only the new publishable and secret keys are used. Grants are explicit in every migration. There are no
  off-site backups.
- **Testing without hardware:**
  - a fake ESP32 publisher;
  - Mosquitto in Docker;
  - `supabase start` for the full local stack;
  - pgTAP for RLS, the status rules and rollups;
  - `deno test` with a DeepSeek stub;
  - pytest for the gateway.

---

## 2. Research findings (with sources)

### 2.1 Raspberry Pi 3B and OS
- Raspberry Pi OS is now based on **Debian 13 "Trixie"** with kernel 6.18 (release of 6 Oct 2026). The **64-bit image
  lists the Pi 3B as compatible**. A "Legacy" Bookworm image still exists [1].
- The Lite edition, with no desktop, is intended for headless servers [2].
- Trixie ships **Python 3.13**. System Python is "externally managed", so the service uses a venv [3][2].
- The 64-bit OS uses more RAM: Phoronix measured 196 MB versus 103 MB at idle [4], and a Pi 3B user reported about 20%
  more [5]. That is fine on a headless 1 GB Pi, and 64-bit gets standard aarch64 wheels from PyPI.
- **The Pi has no RTC.**
  - `systemd-timesyncd` saves the clock to disk and touches **`/run/systemd/timesync/synchronized`** after each
    successful sync [6].
  - If the Pi boots without a network, the clock is wrong: it is restored from the last saved time [7].
  - The gateway therefore must not stamp time until the clock is synced (§5.4).
- **SD-card writes:** reduce writes and cap journald with a drop-in config [24]. In WAL mode,
  `synchronous=NORMAL` can lose the last transaction on power loss; `FULL` is durable [25].

### 2.2 Mosquitto
- Since 2.0, authentication must be configured explicitly. `allow_anonymous` defaults to false once a listener is
  defined [12][13].
- `mosquitto_passwd` manages the password file, with argon2id by default [14].
- The ACL `pattern` rules substitute `%u` with the username [13]. With an ACL file set, anything not allowed is
  denied [15].
- The Debian main config already enables persistence and includes `conf.d`. Repeating settings such as
  `persistence_location` there stops the broker from starting [15].
- Without TLS, credentials travel in clear text [15]. The user accepts this on the home LAN.
- The common Arduino `PubSubClient` can only publish QoS 0 [26]. The contract requires QoS 1, so firmware needs
  `esp-mqtt` or an equivalent client.

### 2.3 Python libraries
- `paho-mqtt` 2.2.0 requires `CallbackAPIVersion.VERSION2`, and its callback signatures differ from 1.x [16][17].
- `supabase-py` 2.34.1 pulls in auth, realtime and storage clients the gateway does not need [18].
- PostgREST supports bulk upsert with `?on_conflict=…` and `Prefer: resolution=ignore-duplicates`, which runs as a
  single INSERT … ON CONFLICT DO NOTHING [19][20].

### 2.4 Supabase keys, grants, RLS, Realtime, Edge Functions
- **Key types:**
  - The **publishable** key (`sb_publishable_…`) runs as `anon`/`authenticated` under RLS.
  - A **secret** key (`sb_secret_…`) bypasses RLS and is for backends only.
  - The legacy **`anon`/`service_role` keys are deprecated by the end of 2026** [8][9].
  - You can create **named secret keys** and rotate each one independently [9][10].
  - Secret keys return 401 when called from a browser [9]. The examples send them in the `apikey` header [21].
- **New tables in `public` are not exposed to the Data API automatically.** This has been the default for new projects
  since 30 May 2026 and is applied to existing projects from 30 Oct 2026. Every role needs an explicit `GRANT`,
  `service_role` included. A missing grant returns error `42501` [11].
- **RLS performance:**
  - name the role in each policy (`to authenticated`);
  - wrap the user id as `(select auth.uid())`;
  - index the columns policies filter on;
  - write `col in (select …)` rather than joins [22][23].
- **Realtime `postgres_changes`:**
  - It delivers row changes from **tables** that are in the `supabase_realtime` publication [27].
  - RLS decides which INSERT and UPDATE events a subscriber receives [28].
  - Clients therefore treat a `readings` INSERT event as a signal and re-read the computed row from the view (§5.6).
- **Free-plan limits:**
  - 500 MB database;
  - the project **pauses after 7 days of low activity**;
  - no backups;
  - 500k Edge Function invocations;
  - 2M Realtime messages;
  - 200 concurrent Realtime connections;
  - unlimited API requests [29][30][31].
- **Edge Function limits:** 150 s wall clock on the Free plan, **2 s CPU per request**, and 256 MB of memory [32].
  Waiting on DeepSeek's response is async I/O and does not count toward the CPU limit.
- **Edge Function authentication** [33]:
  - Functions can require a **user JWT**, which is the default behaviour (`verify_jwt`).
  - The `@supabase/server` `withSupabase` wrapper provides per-request clients.
  - `SUPABASE_URL` and `SUPABASE_SECRET_KEYS` are injected into the function environment [34].
  - Other secrets are set with `supabase secrets set` and, for local development, `supabase/functions/.env` [34].
- **No TimescaleDB:** the `timescaledb` extension is deprecated on Postgres 17 [35]. The plan uses plain tables,
  pg_cron and rollup tables instead.
- **Local development tooling** [36][37]:
  - `supabase start` runs the local stack in Docker and needs about 7 GB of RAM;
  - `supabase db reset` re-applies migrations and seed data;
  - `supabase test db` runs pgTAP tests;
  - `supabase gen types --lang typescript` generates the types;
  - `supabase functions serve --env-file` runs Edge Functions locally.

### 2.5 DeepSeek API (verified 2026-11-16)
- **The model id is exactly `deepseek-flash`.**
  - It currently serves DeepSeek-V4.1-Flash-1017 [38][39][40].
  - The legacy names `deepseek-v4-flash` and `deepseek-v4-flash-vision-exp` are routed to it.
  - The other model is `deepseek-v4-pro`.
- The base URL is `https://api.deepseek.com` (OpenAI-compatible format) [40].
- **`deepseek-flash` prices per 1M tokens:**

  | | Off-peak | Peak |
  |---|---|---|
  | Input, cache hit | $0.003 | $0.006 |
  | Input, cache miss | $0.15 | $0.30 |
  | Output | $0.60 | $1.20 |

  Peak hours are 01:00–04:00 and 06:00–10:00 UTC on weekdays. All other hours are billed at half price [39].
- **Thinking mode is on by default.** Disable it with `{"thinking": {"type": "disabled"}}`. In thinking mode,
  `temperature` is ignored [41].
- JSON Output mode exists but can return blank content [42][43]. Chat replies are plain text, so `chat` does not use
  JSON mode.
- Rate limiting is by concurrency: 2,500 concurrent requests for flash, then **HTTP 429** [44].

### 2.6 Volume and Free-plan budget (estimates; check after 1 week with `pg_total_relation_size`)
| Item | Per day | Per year | Free limit |
|---|---|---|---|
| Raw readings (1 device × 60 s) | 1,440 rows ≈ 0.3 MB incl. indexes | ≈ 110 MB (90-day steady state ≈ 27 MB) | 500 MB DB |
| Hourly + daily rollups | 25 rows | ≈ 2 MB | |
| PostgREST writes (1/reading + heartbeat) | ≈ 1,700 | — | unlimited [29] |
| Realtime messages (2 open clients) | ≈ 3,000 | ≈ 90k/month | 2M/month [30] |
| `chat` invocations | user-driven, capped at 200/day (§5.7) | — | 500k/month |

### 2.7 DeepSeek cost per chat message
- **Tokens per call:**
  - a static system prompt of about 700 tokens (a cacheable prefix);
  - plant context of about 1,200 tokens;
  - history of the last 20 messages, about 1,600 tokens;
  - the user's message;
  - total about **3,600 input tokens**, plus at most **350 output tokens**.
- **Worst case at peak with no cache hits:**
  3,600 × $0.30/M + 350 × $1.20/M ≈ **$0.0015 per message**.
- **Monthly estimates:**
  - At 30 messages a day, about **$1.4/month** at worst. Off-peak hours and cache hits make it less.
  - At the hard cap of 200 admitted messages a day, at most about **$9/month**. If every message also used its one
    retry (400 calls a day), at most about **$18/month**.

### 2.8 Peace lily (Spathiphyllum) care thresholds
Sources are university extension services. 1 fc = 10.764 lux.

| Variable | Evidence | Thresholds used by `plant_status_v` |
|---|---|---|
| Temperature | Days 68–85 °F (20–29.4 °C) and nights about 10 °F cooler; avoid < 60 °F (15.6 °C) [45][46]. 40–60 °F slows growth, and long periods < 40 °F cause damage [46]. Some cultivars show chilling injury from 45 °F (7.2 °C), and growth is delayed after 5 days at 52 °F (11.1 °C). Keep ≤ 90 °F (32.2 °C) [47]. Preferred 75–85 °F, with growth reduced at ≤ 50 °F [48]. | critical_low < 10 °C · low < 16 °C · ok 18–29 °C · high > 30 °C · critical_high > 32 °C. Uses the median of the last 30 min |
| Humidity | Low humidity causes brown leaf tips [46][49]. Indoor RH < 20% is low, 40–50% medium, > 50% high [50]. Tropical houseplants prefer > 50% [51]. 40–60% is best and hard to reach indoors [52]. | critical_low < 25% · low < 40% · ok 40–70% · high > 85% sustained for 12 h (low confidence) |
| Light | Bright indirect light, no direct sun [45][48]. Low-light plants need at least 25 fc (≈ 270 lx); 75–200 fc (≈ 800–2,150 lx) is preferred [50][51]. Medium light (250–1,000 fc) is needed **to flower** [53]. More than 1,000 fc (≈ 10.8 klx) means direct indoor sun [54]. Leaves burn above 2,500 fc (≈ 27 klx) [47]. | Uses the **daytime mean** (08:00–18:00 in `plants.timezone`, last 24 h): critical_low < 270 lx · low < 800 lx · ok 800–5,400 lx. Uses the max 10-min median: high > 10,800 lx · critical_high > 27,000 lx |
| Soil moisture | "Keep moist, not soggy; let it dry slightly between waterings." Overwatering causes root rot; too dry causes wilting [45][48][49]. Capacitive readings are relative and vary by unit and soil, so each probe needs its own calibration [55][56][57]. | Applied to calibrated `soil_pct`: critical_low < 20 · low < 35 · ok 35–85 · high > 90 for 48 h. These are heuristics, editable through `plants.threshold_overrides`. Status is `unknown` until the device is calibrated |

### 2.9 Capacitive soil sensor
- Output voltage **falls as moisture rises** (roughly 2.3–3.0 V dry and 1.0–1.5 V wet). The ESP32 needs 11/12 dB
  attenuation to read that range [55][57]. This matches contract item C ("higher = drier").
- Calibrating in air and in a glass of water is only a functional check. A better calibration uses the real pot:
  record the reading when the soil is "dry enough to water", and again after a full watering has drained [56].

### 2.10 Deployment
- systemd with `EnvironmentFile=`, restart on failure and sandboxing is the standard way to run a Python app from a
  venv without Docker [58].

### 2.11 Sources
1. Raspberry Pi OS downloads — https://www.raspberrypi.org/software/operating-systems
2. Raspberry Pi OS documentation — https://www.raspberrypi.com/documentation/computers/os.html
3. Trixie announcement and comments (Python 3.13) — https://www.raspberrypi.com/news/trixie-the-new-version-of-raspberry-pi-os
4. 32 vs 64-bit RAM (cites Phoronix) — https://techexplorations.com/guides/rpi/begin/rpi-os-32bit-vs-64bit
5. Pi 3B 32/64-bit discussion — https://groups.io/g/direwolf/topic/what_os_is_better_in_a_pi_3b/118524620
6. systemd-timesyncd man page — https://www.freedesktop.org/software/systemd/man/latest/systemd-timesyncd.service.html
7. Raspberry Pi forum, fake-hwclock behaviour — https://forums.raspberrypi.com/viewtopic.php?t=256726
8. Supabase API keys — https://supabase.com/docs/guides/getting-started/api-keys
9. Migrating to publishable/secret keys — https://supabase.com/docs/guides/getting-started/migrating-to-new-api-keys
10. Supabase changelog, API keys — https://supabase.com/changelog/29260-upcoming-changes-to-supabase-api-keys
11. Breaking change: tables not auto-exposed — https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically
12. Mosquitto authentication methods — https://mosquitto.org/documentation/authentication-methods
13. mosquitto.conf(5) (Debian testing) — https://manpages.debian.org/testing/mosquitto/mosquitto.conf.5.en.html
14. mosquitto_passwd(1) — https://manpages.debian.org/unstable/mosquitto/mosquitto_passwd.1.en.html
15. Mosquitto advanced configuration (conf.d, ACL, persistence) — https://cubepath.com/docs/home-automation-and-iot/mosquitto-mqtt-broker-advanced-configuration
16. paho-mqtt on PyPI — https://pypi.org/project/paho-mqtt/2.2.0/
17. paho-mqtt 2.x migration notes — https://testmqtt.com/learn/mqtt-python
18. supabase on PyPI — https://pypi.org/project/supabase
19. PostgREST tables/views (bulk insert, upsert) — https://docs.postgrest.org/en/latest/references/api/tables_views.html
20. Supabase Python upsert — https://supabase.com/docs/reference/python/upsert
21. Scheduling Edge Functions (apikey header usage) — https://supabase.com/docs/guides/functions/schedule-functions
22. Supabase RLS — https://supabase.com/docs/guides/database/postgres/row-level-security
23. RLS performance — https://supabase.com/docs/guides/database/postgres/row-level-security-performance
24. Raspberry Pi whitepaper "Making a more resilient file system" — https://pip-assets.raspberrypi.com/categories/685-app-notes-guides-whitepapers/documents/RP-003610-WP-3-Making%20a%20more%20resilient%20file%20system.pdf
25. SQLite PRAGMA synchronous — https://www.sqlite.org/pragma.html
26. PubSubClient README (QoS 0 publish only) — https://github.com/knolleary/pubsubclient
27. Realtime Postgres Changes — https://supabase.com/docs/guides/realtime/postgres-changes
28. Realtime troubleshooting (RLS gates delivery) — https://supabase.com/docs/guides/troubleshooting/realtime-messages-not-arriving
29. Supabase pricing — https://supabase.com/pricing
30. Realtime limits — https://supabase.com/docs/guides/realtime/limits
31. Free-plan disk and read-only behaviour (summarising Supabase docs) — https://fastero.com/blog/supabase-pricing
32. Edge Function limits — https://supabase.com/docs/guides/functions/limits
33. Securing Edge Functions — https://supabase.com/docs/guides/functions/auth
34. Edge Function secrets/env — https://supabase.com/docs/guides/functions/secrets
35. timescaledb deprecation — https://supabase.com/docs/guides/database/extensions/timescaledb
36. Supabase CLI reference — https://supabase.com/docs/reference/cli/introduction
37. Local development workflow — https://supabase.com/docs/guides/local-development/cli-workflows
38. DeepSeek change log — https://api-docs.deepseek.com/updates
39. DeepSeek Models & Pricing — https://api-docs.deepseek.com/quick_start/pricing
40. DeepSeek first API call — https://api-docs.deepseek.com/
41. DeepSeek Thinking Mode — https://api-docs.deepseek.com/guides/thinking_mode
42. DeepSeek JSON Output — https://api-docs.deepseek.com/guides/json_mode
43. DeepSeek Chat Completions API — https://api-docs.deepseek.com/api/create-chat-completion
44. DeepSeek Rate Limit — https://api-docs.deepseek.com/quick_start/rate_limit
45. Clemson HGIC, Peace Lily — https://hgic.clemson.edu/factsheet/peace-lily
46. NC State Extension Plant Toolbox, Spathiphyllum — https://plants.ces.ncsu.edu/plants/spathiphyllum
47. UF/IFAS EP161, Commercial production of interiorscape Spathiphyllum — https://edis.ifas.ufl.edu/en/publication/EP161
48. UF/IFAS EP477, Florida Foliage House Plant Care: Spathiphyllum — https://ask.ifas.ufl.edu/en/publication/ep477
49. SDSU Extension, Peace Lily — https://extension.sdstate.edu/peace-lily-houseplant-how
50. UGA Extension B1318, Growing Indoor Plants with Success — https://fieldreport.caes.uga.edu/wp-content/uploads/2025/08/B-1318_6.pdf
51. UT Extension W1128A, Selecting Indoor Plants — https://uthort.tennessee.edu/wp-content/uploads/sites/228/2023/11/W1128A.pdf
52. MU Extension G6510, Caring for Houseplants — https://extension.missouri.edu/publications/g6510
53. MU Extension G6515, Lighting Indoor Houseplants — https://extension.missouri.edu/publications/g6515
54. UMD Extension, Lighting for Indoor Plants — https://extension.umd.edu/resource/lighting-indoor-plants
55. SmartHomeScene, capacitive v1.2 + ESP32 calibration — https://smarthomescene.com/diy/diy-capacitive-soil-moisture-sensor-v1-2-with-esphome/
56. esp32.co.uk, calibrate in real soil — https://esp32.co.uk/capacitive-soil-moisture-sensor-esp32-esphome-home-assistant
57. Calibration guide (relative %, unit variance) — https://swiftwand.com/en/soil-moisture-sensor-esp32-calibration-2026-en
58. Python app as a systemd service — https://johnthecomputerman.co.uk/kc/ls/how-to-run-a-python-app-as-a-service-without-docker-venv-systemd.html

---

## 3. Decisions and alternatives rejected

| # | Decision | Why | Rejected alternatives |
|---|---|---|---|
| D1 | **Raspberry Pi OS Lite 64-bit (Trixie)** | Officially supported on the 3B; no desktop RAM cost; standard aarch64 wheels [1][2] | 32-bit (fewer prebuilt wheels); Legacy Bookworm |
| D2 | **Python 3.13 + paho-mqtt 2 + httpx + pydantic 2** | The interpreter is already on the Pi; readable code; easy to test; about 40 MB RSS | Go (lower memory but less approachable); Node (heavier); supabase-py (unneeded dependencies) |
| D3 | **Threaded paho (`loop_start`) + one uploader thread** | Two simple threads with a SQLite queue between them; paho handles reconnects | asyncio/aiomqtt (extra concepts, no gain at 1 msg/min) |
| D4 | **systemd + Mosquitto from apt, no Docker on the Pi** | Saves RAM and SD writes on a 1 GB / SD-card machine | Docker Compose on the Pi (used on the dev machine only) |
| D5 | **SQLite outbox + idempotent upsert** | Survives restarts and power loss. At-least-once delivery plus a unique key gives one row per reading | Uploading from the MQTT callback (loses data when offline) |
| D6 | **Gateway stamps `recorded_at`, but only from an NTP-synced clock** (§5.4) | The ESP32 has no clock and the Pi has no RTC [6][7] | Always trusting the Pi clock |
| D7 | **`soil_pct` is computed in the database at read time** by `public.soil_pct(raw, dry, wet)` and exposed through `security_invoker` views. Only `soil_raw` is stored | One formula in one place. Recalibration takes effect immediately, including history and rollups, without rewriting rows. Before calibration the value is null | **Gateway computes on insert**: the gateway would need the calibration, and recalibrating would leave stale values or need a mass UPDATE that floods Realtime. **Trigger plus stored column**: same recalibration problem. **Per-calibration history applied by `recorded_at`**: more correct if the probe moves, but out of v1 scope (see R6) |
| D8 | **Status pill = SQL view `plant_status_v`** (deterministic, no LLM) | Every client and the chat function read the same values. Testable with pgTAP | Client-side rules (clients could disagree); LLM-generated mood (contract A forbids it) |
| D9 | **Chat = Edge Function `chat`**, non-streaming, `deepseek-flash` with thinking disabled, plain text output | The key stays server-side. A reply of ≤ 350 tokens arrives in a few seconds | Streaming (possible later); calling DeepSeek from the client (would expose the key); JSON mode (blank-output risk [42], not needed) |
| D10 | **Language follows the user's message** (instruction in the system prompt) | Contract A; no locale setting needed | A per-plant locale column |
| D11 | **Plain tables + pg_cron rollups** | timescaledb is deprecated on PG17 [35] | Hypertables; materialized views |
| D12 | **Realtime INSERT on `readings` acts as a signal; clients re-read from `readings_v`** | Realtime streams tables, not views [27], and `soil_pct` exists only in the views. This costs one small query per minute | Storing `soil_pct` (rejected in D7); client-side `soil_pct` math (two places) |
| D13 | **Lock files:** `uv` on the dev machine, `uv export` → hashed `requirements.txt` → `pip` in a venv on the Pi | No extra tool needed on the Pi | Installing uv on the Pi |
| D14 | **Timeline offline periods = `device_offline_periods()` over raw-reading gaps > 180 s**, queried per selected day | Raw readings are the ground truth for "no data". A gap catches every cause: ESP32 offline, Wi-Fi down, broker or Pi down, gateway crash. A `boot_id` change across the gap labels it `device_restart`. No extra write path; ≈1,440 indexed rows per day | **Persisted `device_events` table from the status topic/LWT:** misses outages where the Pi or gateway itself is down, duplicates information already in `readings`, and needs another writer. **Hourly summaries:** too coarse, and empty hours have no row |
| D15 | **Rollups resume from a persisted watermark** (`rollup_state.processed_until`) and recompute touched buckets from raw; **daily is computed from raw**; **per-metric `_n` counts** | A job outage of any length is caught up on the next run. Daily values are exact for any timezone. Intermittent null sensors are weighted correctly. Retention never deletes raw rows that are not yet rolled up | A fixed 2 h lookback (outages longer than that leave permanent gaps); daily weighted from hourly by total `n` (wrong when sensors return null) |
| D16 | **Uploader classifies failures**: only SQLSTATE class 22/23 rows are dead-lettered; auth, permission and config errors keep the queue | A revoked key or missing grant must not dead-letter the whole valid backlog | Row-by-row retry on any 4xx |
| D17 | **Chat quota enforced by `chat_admit()`**: one transaction with a per-plant row lock, both limits checked, then insert | A count-then-insert done in separate steps lets concurrent requests exceed the cost cap | Counting in the Edge Function; in-memory limiter (Edge Functions are stateless and distributed) |

---

## 4. Contract changes (final contract, decided 2026-11-16)

These items replace the provisional contract. My first plan proposed `avatar_states`, an `expression` enum, a
periodic `avatar-tick` job, a firmware-side `soil_pct` and a per-plant locale. **All of these are dropped.**

**Telemetry.** Topic `olvar/v1/<device_id>/telemetry`, QoS 1, not retained. The payload is a UTF-8 JSON object of at
most 1 KiB:
```json
{"device_id":"olvar-a1b2c3","boot_id":"3fa9c2e1","seq":42,"uptime_ms":2520113,
 "temperature_c":23.4,"humidity_pct":48.2,"lux":1520.0,"soil_raw":2214,"rssi_dbm":-61,"fw":"0.1.0"}
```

| Field | Rule |
|---|---|
| `device_id` | Defaults to `"olvar-"` + the last 6 hex characters of the MAC, in lowercase. The gateway accepts `^[a-z0-9][a-z0-9-]{2,31}$` and requires it to equal the topic segment. `olvar-gateway` is reserved |
| `boot_id` | 8 random lowercase hex characters, generated once per boot |
| `seq` | Restarts at 0 on each boot. `(device_id, boot_id, seq)` identifies a reading for deduplication |
| `uptime_ms` | Integer ≥ 0 |
| `temperature_c`, `humidity_pct`, `lux` | Number, or `null` when that sensor's read failed. **NaN is never sent** |
| `soil_raw` | The averaged 12-bit ADC count (0–4095); **higher means drier**. `null` on failure |
| `rssi_dbm` | Optional integer |
| `fw` | String |

Further telemetry rules:
- The **firmware does not send `soil_pct`** and has no calibration logic.
- The gateway **ignores unknown fields**.
- The ESP32 **drops readings while the broker is unreachable**.
- The interval is **60 s**.

**Status.** Topic `olvar/v1/<device_id>/status`, retained, QoS 1. The payload is the plain string `online`, published
on connect, or `offline`, sent as the last will.

**MQTT auth.** Traffic is unencrypted on the LAN. Each device logs in with its own username and password, where the
username and client id equal the `device_id`. The ACL lets a device write only its own two topics.

**Soil calibration.** It is stored in the database as `devices.soil_dry_raw` and `devices.soil_wet_raw`, together
with `soil_calibrated_at`.
- The dashboard's Soil calibration screen writes these values from live `soil_raw`.
- RLS lets the owner update only these three columns.
- A check enforces `soil_dry_raw > soil_wet_raw + 100`.
- `soil_pct` is computed server-side, in the database, at read time. It is null until the device is calibrated.
- **After recalibration, every past reading and summary is re-expressed with the new calibration.** Rows are never
  rewritten; see D7 and R6.

**Status pill.** The pill comes from the view `public.plant_status_v`, one row per plant. The dashboard contains no
threshold logic.
- `overall`: one of `great | okay | needs_attention | in_trouble | offline | no_data`, plus `overall_label` (English
  text such as "Feeling great").
- Per-metric `<metric>_status`: one of `critical_low | low | ok | high | critical_high | unknown`, plus
  `<metric>_label` (e.g. "Too dry"), for temperature, humidity, light and soil.
- `summary`: a deterministic one-line text such as "Soil is getting dry — water soon".
- `computed_at`, `latest_reading_at`, `issues` and `soil_calibrated`.
- **Offline** means no reading for more than **180 s**, or a retained `offline` status. The dashboard uses the same
  180 s rule only to age its cached row between refetches.

**Chat.** The Edge Function `chat`:
- Request: `POST /functions/v1/chat` with the user's JWT and body `{"plant_id": uuid, "message": string ≤ 1000}`.
- Response: `{"reply": {chat_messages row}}`.
- The reply row carries `based_on_reading_at`: the time of the reading the answer was based on.
- Rate limits: 10 user messages per 5 min and 200 per rolling 24 h per plant. They are enforced **atomically** in the
  database (§5.6 `chat_admit`). Over the limit the function returns 429 with `retry_after`.
- Messages are stored in `chat_messages`, a single conversation per plant. The dashboard lists them from that table
  and subscribes to its INSERTs.

**Timeline offline periods.** The SQL function `public.device_offline_periods(p_device_id, p_from, p_to)` returns
`(started_at, ended_at, duration_s, cause, ongoing)`, where `cause` is `device_restart` or `no_data`.
- It is computed from gaps of **more than 180 s between consecutive raw readings** (decision D14).
- It is therefore available for any selected day **within the 90-day raw retention**.
- Beyond 90 days the Timeline shows no offline periods.

**Dashboard reads** go through RLS and require a signed-in session; nothing is granted to `anon`.
- `readings_v` for windows ≤ 48 h, `readings_hourly_v` for ≤ 90 d, and `readings_daily_v` beyond that.
- `plant_status_v`, `device_offline_periods()`, `devices` (calibration columns are writable), and `chat_messages`.
- `plants`: the dashboard may update `nickname`, `location`, `timezone` and `threshold_overrides`. The overrides are
  validated by a check constraint.
- Realtime publication: `readings` (INSERT, used as a signal), `devices` (UPDATE), `chat_messages` (INSERT).

**Types.** `supabase/types/database.types.ts` is generated and committed in olvar-gateway. The dashboard syncs a
pinned copy.

**Other final items:**
- Only the new publishable and secret keys are used.
- Raw readings are kept 90 days, with hourly and daily summaries.
- No off-site backups.
- Firmware is updated over USB only.
- The hardware is a Pi 3B, connected over Wi-Fi/MQTT, with 60 s updates. Where Figma says "Pi 4", "USB serial" or
  "10 s", the app follows the real hardware.

---

## 5. Architecture and folder layout

### 5.1 Data flow
```
ESP32 ──MQTT QoS1──▶ Mosquitto (Pi :1883, user/pass + ACL)
                       olvar/v1/<id>/telemetry · /status (retained, LWT)
                         ▼
                 olvar-gateway (Pi, systemd)
   validate → stamp time (if NTP-synced) → SQLite outbox → uploader (batch ≤500, upsert ignore-dup, backoff)
                         ▼  PostgREST, secret key "gateway"
   Postgres: readings · devices(calibration) · plants · plant_profiles · readings_hourly/daily · chat_messages · gateways
     views:  readings_v / readings_hourly_v / readings_daily_v (soil_pct)   plant_status_v (pill)
     pg_cron: :05 hourly → refresh_rollups (watermark) · 03:30 UTC → delete rolled-up raw > 90 d
     fns:    device_offline_periods() (Timeline) · chat_admit() (atomic quota)
                         ▲                                   ▲
   Expo dashboard (publishable key + owner login) ──POST──▶ Edge Fn `chat` ──▶ DeepSeek deepseek-flash
          └── Realtime: readings INSERT (signal), devices UPDATE, chat_messages INSERT
```

### 5.2 Repository layout
```
olvar-gateway/
├── README.md · docs/{PLAN,DEPLOY,RUNBOOK}.md
├── pyproject.toml · uv.lock · requirements.txt (uv export, hashed)
├── contracts/telemetry.v1.schema.json · contracts/examples/{valid-*,invalid-*}.json
├── src/olvar_gateway/{__main__,config,models,clock,buffer,uploader,mqtt_client,service,log}.py
├── tests/ (unit) · tests/e2e/
├── tools/fake_esp32.py · tools/setup_plant.py
├── dev/compose.yml                     # mosquitto for local dev, using deploy/mosquitto/*
├── deploy/mosquitto/{olvar.conf,acl} · deploy/systemd/olvar-gateway.service · deploy/journald/olvar.conf
│   deploy/gateway.env.example · deploy/install.sh · deploy/update.sh
├── supabase/
│   ├── config.toml · seed.sql
│   ├── migrations/
│   │   ├── 20261116000100_core.sql      # profiles, plants, devices, readings, gateways, soil_pct(), readings_v, grants, RLS
│   │   ├── 20261116000200_rollups.sql   # hourly/daily tables + views, refresh_rollups, cron, retention
│   │   ├── 20261116000300_status.sql    # thresholds merge fn + plant_status_v
│   │   └── 20261116000400_chat.sql      # chat_messages, grants, RLS, publication
│   ├── tests/{core,rollups,status,chat}_test.sql   # pgTAP
│   ├── functions/chat/{index.ts,context.ts,prompt.ts,deepseek.ts,*_test.ts}
│   └── types/database.types.ts
└── .github/workflows/ci.yml
```

### 5.3 Gateway internals (interfaces fixed so tasks can be built in parallel)
```python
# models.py
class InvalidMessage(Exception): reason: str
@dataclass(frozen=True)
class ReadingRow:                       # == readings columns minus id/received_at
    device_id: str; boot_id: str; seq: int; uptime_ms: int
    recorded_at: datetime | None        # None until clock is trustworthy
    temperature_c: float | None; humidity_pct: float | None; lux: float | None
    soil_raw: int | None; rssi_dbm: int | None
    clock_source: Literal["ntp", "backfilled", "unsynced"]
def parse_message(topic: str, payload: bytes) -> Telemetry          # raises InvalidMessage
def to_row(t: Telemetry, stamp: Stamp) -> ReadingRow

# clock.py
@dataclass(frozen=True)
class Stamp: wall: datetime | None; mono_ns: int; pi_boot_id: str; synced: bool
class Clock: def now() -> Stamp; def backfill(mono_ns: int, pi_boot_id: str) -> datetime | None

# buffer.py
class Outbox:
    def __init__(self, path: Path, max_rows: int = 100_000)
    def put(self, row: ReadingRow, stamp: Stamp) -> bool          # False if (device_id, boot_id, seq) already queued
    def ready(self, limit: int) -> list[tuple[int, ReadingRow]]   # only rows with recorded_at set
    def ack(self, ids: list[int]) -> None
    def dead_letter(self, ids: list[int], reason: str) -> None
    def resolve_unsynced(self, clock: Clock) -> int
    def depth(self) -> int

# uploader.py
class SupabaseWriter:
    def __init__(self, url: str, secret_key: str, client: httpx.Client)
    def upsert_readings(self, rows) -> UploadResult    # ok | retryable | permanent(per-row reasons)
    def upsert_device(self, device_id, *, status=None, fw=None, last_seen_at=None) -> UploadResult
    def heartbeat(self, gateway_id, version, buffer_depth) -> UploadResult
```

### 5.4 Gateway behaviour
- **Validation:**
  - The payload must be a JSON object of at most 1 KiB, and unknown keys are ignored.
  - `device_id` must match both the topic segment and the id regex.
  - `boot_id` must be 8 hex characters, and `seq` and `uptime_ms` must be ≥ 0.
  - Physical ranges: temperature −40…125 °C, humidity 0…100, lux 0…120,000, soil_raw 0…4095, rssi_dbm −120…0.
  - An out-of-range field becomes `null` and increments a counter.
  - Invalid messages are logged at most once per device per minute.
- **Time:**
  - "Synced" means the file `/run/systemd/timesync/synchronized` exists [6].
  - While unsynced, rows are stored with `mono_ns` and the Pi's boot id, and `recorded_at` stays NULL.
  - After the clock syncs, rows from the same Pi boot get `recorded_at = wall − (mono_now − mono_ns)` and
    `clock_source='backfilled'`.
  - Rows from an earlier Pi boot that never synced are uploaded with their best-effort time and
    `clock_source='unsynced'`.
- **Outbox:**
  - SQLite with `journal_mode=WAL`, `synchronous=FULL` and `busy_timeout=5000`, at
    `/var/lib/olvar-gateway/outbox.db`.
  - A unique index on `(device_id, boot_id, seq)`.
  - It holds at most 100k rows, about 70 days for one device. Above that, the oldest rows are dropped with an ERROR log.
- **Uploader:**
  - It runs on each new row and on a 5 s tick.
  - Request: `POST /rest/v1/readings?on_conflict=device_id,boot_id,seq` with
    `Prefer: resolution=ignore-duplicates,return=minimal` and the `apikey` header [19][21].
  - Network errors, 5xx and 429 responses trigger exponential backoff with jitter, from 1 s up to 5 min.
  - **Failures are classified before anything is dead-lettered.** Only *row-specific* data errors are isolated:
    PostgreSQL SQLSTATE class **22** (data exception) or **23** (integrity, e.g. `23502`, `23503`, `23514`), as
    reported in the PostgREST error body `code`.
    - The batch is bisected until the offending rows are found.
    - Only those rows go to the dead-letter table; the rest are acknowledged.
  - **Request-wide failures never dead-letter.** These are:
    - 401 or 403, including `42501` permission denied (revoked or rotated key, missing grant);
    - 404, or any `PGRST*` code (missing table, schema cache);
    - any other unclassified 4xx.

    For these, the whole batch **stays queued** and the uploader backs off (capped at 5 min). It logs one ERROR
    each time the error class changes, and `olvar-gateway status` shows `last_error` and the queue depth. Delivery
    resumes by itself once the credentials or grants are fixed.
  - Device rows are upserted with only `{id, fw, last_seen_at}`, so the calibration and owner columns are never touched.
- **MQTT:**
  - Client id `olvar-gateway`, MQTT 5, `clean_start=False`, session expiry of one day.
  - Subscriptions at QoS 1: `olvar/v1/+/telemetry` and `olvar/v1/+/status`.
  - Status messages update `devices.status`, `status_changed_at` and `last_seen_at`.
- **Heartbeat:**
  - Every 5 min it upserts `gateways(id, version, buffer_depth, last_seen_at)`.
  - This also keeps the Free project from pausing for inactivity [29].
- **Logging:** JSON lines on stdout, captured by journald and capped at 50 MB [24].
- **Shutdown:** on SIGTERM it stops MQTT, flushes for up to 10 s and closes SQLite.

### 5.5 Mosquitto config (deploy/mosquitto)
```conf
# /etc/mosquitto/conf.d/olvar.conf  (persistence already enabled by the Debian main file)
listener 1883 0.0.0.0
allow_anonymous false
password_file /etc/mosquitto/passwd
acl_file /etc/mosquitto/acl
```
```conf
# /etc/mosquitto/acl  — username == device_id
pattern write olvar/v1/%u/telemetry
pattern write olvar/v1/%u/status
user olvar-gateway
topic read olvar/v1/+/telemetry
topic read olvar/v1/+/status
```
The files are owned by `mosquitto:mosquitto` with mode 0600 [15]. nftables allows port 1883 only from the LAN subnet.
The Pi is reached through a DHCP reservation, with mDNS `olvar-gw.local` as a fallback.

### 5.6 Supabase schema (v1 only)
```sql
-- ===== 20261116000100_core.sql =====
create table public.plant_profiles (
  id text primary key,                          -- 'spathiphyllum'
  common_name text not null, scientific_name text not null,
  thresholds jsonb not null,                    -- {temperature_c:{critical_low,low,ok_low,ok_high,high,critical_high}, humidity_pct:{…}, lux:{…}, soil_pct:{…}}
  care_notes text not null,                     -- short evidence-based care summary fed to chat (§2.8)
  sources text[] not null default '{}'
);

create table public.plants (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  profile_id text not null references public.plant_profiles(id),
  nickname text not null default 'Lily' check (char_length(nickname) between 1 and 40),
  location text check (char_length(location) <= 60),   -- free text, e.g. "Living room window"
  timezone text not null default 'UTC',         -- IANA; set by setup script, editable in Settings
  threshold_overrides jsonb not null default '{}'
    check (public.valid_threshold_overrides(threshold_overrides)),  -- known metrics/keys, numbers, ascending order
  created_at timestamptz not null default now()
);
create index plants_owner_idx on public.plants (owner_id);

create table public.devices (
  id text primary key check (id ~ '^[a-z0-9][a-z0-9-]{2,31}$' and id <> 'olvar-gateway'),
  owner_id uuid references auth.users(id) on delete set null,
  plant_id uuid unique references public.plants(id) on delete set null,   -- v1: one device per plant
  fw text,
  status text not null default 'unknown' check (status in ('online','offline','unknown')),
  status_changed_at timestamptz,
  last_seen_at timestamptz,
  soil_dry_raw integer check (soil_dry_raw between 0 and 4095),
  soil_wet_raw integer check (soil_wet_raw between 0 and 4095),
  soil_calibrated_at timestamptz,
  created_at timestamptz not null default now(),
  constraint soil_cal_pair check ((soil_dry_raw is null) = (soil_wet_raw is null)),
  constraint soil_cal_order check (soil_dry_raw is null or soil_dry_raw > soil_wet_raw + 100)
);
create index devices_owner_idx on public.devices (owner_id);

create table public.readings (
  id bigint generated always as identity primary key,
  device_id text not null references public.devices(id) on delete cascade,
  recorded_at timestamptz not null,
  received_at timestamptz not null default now(),
  boot_id text not null check (boot_id ~ '^[0-9a-f]{8}$'),
  seq integer not null check (seq >= 0),
  uptime_ms bigint not null check (uptime_ms >= 0),
  temperature_c real check (temperature_c between -40 and 125),
  humidity_pct real check (humidity_pct between 0 and 100),
  lux real check (lux between 0 and 120000),
  soil_raw smallint check (soil_raw between 0 and 4095),
  rssi_dbm smallint check (rssi_dbm between -120 and 0),
  clock_source text not null default 'ntp' check (clock_source in ('ntp','backfilled','unsynced')),
  constraint readings_dedup unique (device_id, boot_id, seq)
);
create index readings_device_time_idx on public.readings (device_id, recorded_at desc);
create index readings_received_idx on public.readings (received_at);

create table public.gateways (
  id text primary key, owner_id uuid references auth.users(id) on delete set null,
  version text, buffer_depth integer, last_seen_at timestamptz not null default now()
);

-- one formula, used by every view; higher raw = drier
create function public.soil_pct(raw numeric, dry_raw integer, wet_raw integer) returns real
  language sql immutable parallel safe set search_path = '' as $$
  select case when raw is null or dry_raw is null or wet_raw is null then null
              else greatest(0, least(100, round(((dry_raw - raw) * 100.0 / (dry_raw - wet_raw))::numeric, 1)))::real end $$;

create view public.readings_v with (security_invoker = true) as
  select r.*, public.soil_pct(r.soil_raw, d.soil_dry_raw, d.soil_wet_raw) as soil_pct
  from public.readings r join public.devices d on d.id = r.device_id;

-- grants (explicit, required since the 2026 default-privileges change [11])
grant select on public.plant_profiles, public.plants, public.devices, public.readings, public.readings_v, public.gateways to authenticated;
grant update (nickname, location, timezone, threshold_overrides) on public.plants to authenticated;
grant update (soil_dry_raw, soil_wet_raw, soil_calibrated_at) on public.devices to authenticated;
grant select, insert, update, delete on public.plant_profiles, public.plants, public.devices, public.readings, public.gateways to service_role;
grant select on public.readings_v to service_role;
grant usage, select on all sequences in schema public to service_role;
grant execute on function public.soil_pct(numeric, integer, integer) to authenticated, service_role;

-- RLS (enabled on every table)
create policy profiles_read on public.plant_profiles for select to authenticated using (true);
create policy plants_read   on public.plants  for select to authenticated using (owner_id = (select auth.uid()));
create policy plants_update on public.plants  for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy devices_read  on public.devices for select to authenticated using (owner_id = (select auth.uid()));
create policy devices_calibrate on public.devices for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy gateways_read on public.gateways for select to authenticated using (owner_id = (select auth.uid()));
create policy readings_read on public.readings for select to authenticated
  using (device_id in (select d.id from public.devices d where d.owner_id = (select auth.uid())));
alter publication supabase_realtime add table public.readings, public.devices;

-- ===== 20261116000200_rollups.sql =====
create extension if not exists pg_cron;
create table public.readings_hourly (
  device_id text not null references public.devices(id) on delete cascade,
  bucket timestamptz not null,                                  -- UTC hour
  n integer not null,                                           -- readings in the bucket (coverage)
  -- per-metric non-null sample counts: SQL aggregates skip nulls, so each metric is weighted by its own n
  temperature_c_n integer not null, temperature_c_avg real, temperature_c_min real, temperature_c_max real,
  humidity_pct_n  integer not null, humidity_pct_avg real,  humidity_pct_min real,  humidity_pct_max real,
  lux_n           integer not null, lux_avg real, lux_min real, lux_max real,
  soil_raw_n      integer not null, soil_raw_avg real, soil_raw_min smallint, soil_raw_max smallint,
  primary key (device_id, bucket)
);
-- readings_daily: same columns, `bucket date` = local date in plants.timezone (UTC if no plant).
-- Daily rows are computed DIRECTLY FROM RAW readings of that local date (raw exists for 90 d, so every late row can
-- still be folded in). That is exact for any timezone offset (incl. :30/:45). Combining hourly rows elsewhere must
-- use sum(<m>_avg * <m>_n) / nullif(sum(<m>_n), 0), never the total n.
-- readings_hourly_v / readings_daily_v (security_invoker): add soil_pct_avg = soil_pct(soil_raw_avg),
--   soil_pct_min = soil_pct(soil_raw_max), soil_pct_max = soil_pct(soil_raw_min)   (inverted: higher raw = drier)

-- persisted watermark: the job resumes from where it last succeeded, however long it was down
create table public.rollup_state (
  id boolean primary key default true check (id),              -- single row
  processed_until timestamptz not null default '-infinity'
);
create function public.refresh_rollups() returns void
  language plpgsql security definer set search_path = '' as $$ … $$;
  -- 1. pg_try_advisory_xact_lock(<const>) → return if another run holds it (overlapping cron runs)
  -- 2. lo := processed_until - interval '10 minutes'  (overlap; recompute is idempotent)
  --    hi := now() - interval '2 minutes'           (lag: received_at = insert txn start, upload txns are short)
  -- 3. touched := distinct (device_id, hour) and (device_id, local date) of readings with received_at in (lo, hi]
  -- 4. recompute those hourly + daily buckets from raw (upsert on PK)
  -- 5. update rollup_state set processed_until = hi    -- same transaction: all-or-nothing
create function public.rebuild_rollups(p_from timestamptz, p_to timestamptz) returns void …  -- manual repair
revoke execute on function public.refresh_rollups(), public.rebuild_rollups(timestamptz, timestamptz)
  from public, anon, authenticated;
select cron.schedule('olvar-rollups', '5 * * * *', $$select public.refresh_rollups()$$);
-- retention never deletes rows that are not yet rolled up (if the job is down for > 90 d, raw rows are kept)
select cron.schedule('olvar-retention', '30 3 * * *', $$
  delete from public.readings
  where recorded_at < now() - interval '90 days'
    and received_at <= (select processed_until from public.rollup_state) $$);
-- grants/RLS mirror readings (select to authenticated via devices.owner_id; all to service_role);
-- rollup_state: no grants to anon/authenticated

-- ===== 20261116000300_status.sql =====
-- effective_thresholds(plant_id) = profile.thresholds deep-merged per metric with plants.threshold_overrides
-- plant_status_v (security_invoker), one row per plant the caller can see:
--   plant_id, device_id, latest_reading_at, device_status, soil_calibrated boolean,
--   temperature_status, humidity_status, light_status, soil_status   -- critical_low|low|ok|high|critical_high|unknown
--   temperature_label, humidity_label, light_label, soil_label       -- English, e.g. 'Just right', 'Too dry'
--   issues text[]                                                    -- metric keys, worst first
--   overall text  -- great | okay | needs_attention | in_trouble | offline | no_data
--   overall_label text  -- 'Feeling great' | 'Doing okay' | 'Needs attention' | 'In trouble' | 'Offline' | 'No data yet'
--   summary text        -- one deterministic line from the worst issue, e.g. 'Soil is getting dry — water soon'
--   computed_at timestamptz  -- now() at query time
-- Rules (thresholds in §2.8):
--   no reading ever → no_data;  latest reading > 180 s old or device_status = 'offline' → offline
--   temperature/humidity: median of last 30 min; humidity "high" only if > high for 12 h
--   light: daytime (08–18 local) mean over 24 h for low side; max 10-min median for high side
--   soil: latest 10-min median of soil_pct via readings_v; unknown if uncalibrated; "high" only if > high for 48 h
--   any critical_* → in_trouble; any low/high → needs_attention; all ok and every value in the middle half of its
--   ok band → great; else okay. unknown metrics never raise severity.
grant select on public.plant_status_v to authenticated, service_role;

-- Timeline offline periods, derived from raw-reading gaps (D14); security invoker → RLS on readings applies
create function public.device_offline_periods(p_device_id text, p_from timestamptz, p_to timestamptz)
  returns table (started_at timestamptz, ended_at timestamptz, duration_s integer,
                 cause text,          -- 'device_restart' (boot_id changed across the gap) | 'no_data'
                 ongoing boolean)     -- true for a gap still open at now()
  language sql stable security invoker set search_path = '' as $$ … $$;
  -- readings in [p_from, p_to] plus the last reading before p_from and the first after p_to (clips gaps that
  -- cross the window edges); lag(recorded_at) over (order by recorded_at); a gap > 180 s yields
  -- (prev.recorded_at + 60 s, next.recorded_at); the trailing gap to least(now(), p_to) is ongoing.
  -- Only 'ntp'/'backfilled' rows are used. Uses readings_device_time_idx; one day ≈ 1,440 rows.
  -- p_to - p_from is capped at 7 days (raises otherwise). Beyond the 90-day retention it returns nothing.
grant execute on function public.device_offline_periods(text, timestamptz, timestamptz) to authenticated, service_role;

-- ===== 20261116000400_chat.sql =====
create table public.chat_messages (
  id bigint generated always as identity primary key,
  plant_id uuid not null references public.plants(id) on delete cascade,
  role text not null check (role in ('user','plant')),
  content text not null check (char_length(content) between 1 and 2000),
  created_at timestamptz not null default now(),
  based_on_reading_at timestamptz,                            -- 'plant' rows: recorded_at of the latest reading used
  model text, tokens_in integer, tokens_out integer,          -- set on 'plant' rows
  error text                                                  -- set when the plant reply is a fallback
);
create index chat_messages_plant_time_idx on public.chat_messages (plant_id, created_at desc);
grant select on public.chat_messages to authenticated;
grant select, insert on public.chat_messages to service_role;
alter table public.chat_messages enable row level security;
create policy chat_read on public.chat_messages for select to authenticated
  using (plant_id in (select p.id from public.plants p where p.owner_id = (select auth.uid())));
alter publication supabase_realtime add table public.chat_messages;
-- inserts happen only inside the `chat` function (service role), so clients cannot forge 'plant' messages

-- atomic admission: one transaction serializes per plant, checks both quotas, inserts the user's message
create function public.chat_admit(p_owner_id uuid, p_plant_id uuid, p_content text)
  returns public.chat_messages
  language plpgsql security definer set search_path = '' as $$ … $$;
  -- 1. select 1 from public.plants where id = p_plant_id and owner_id = p_owner_id for update
  --    (row lock: concurrent calls for the same plant queue here; not found → raise 'P0002' plant_not_found)
  -- 2. count role='user' rows for the plant in the last 5 min and the last 24 h
  -- 3. over 10 / 200 → raise exception using errcode = 'P0429', detail = retry_after seconds
  -- 4. insert the 'user' row and return it — all in the same transaction as the lock
revoke execute on function public.chat_admit(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.chat_admit(uuid, uuid, text) to service_role;
```

### 5.7 Edge Function `chat` (Deno/TypeScript)
1. **Auth:** require the caller's JWT (`verify_jwt` stays on) [33]. Read the plant through a user-scoped client;
   RLS then proves ownership, and a non-owner gets 404.
2. **Input:** `message` is trimmed and must be 1–1000 characters.
3. **Admit and store atomically.**
   - Call `rpc('chat_admit', {p_owner_id: <sub from the verified JWT>, p_plant_id, p_content})` with the admin
     client. One database transaction locks the plant row, checks **10 per 5 min** and **200 per rolling 24 h**, and
     inserts the user's row.
   - Concurrent requests therefore cannot both pass at 199/200, so the cost cap holds.
   - Error mapping: `P0429` returns HTTP 429 with `retry_after`; `P0002` returns 404.
   - Each admitted message makes at most 2 DeepSeek calls (1 retry), so the worst case is 400 calls a day.
4. **Build the context:**
   - plant nickname and profile `care_notes`;
   - the effective thresholds;
   - the `plant_status_v` row;
   - the latest `readings_v` row;
   - 24 h of hourly data from `readings_hourly_v`, condensed to min/avg/max per 6 h;
   - 7 d of daily data from `readings_daily_v`;
   - the current local time in `plants.timezone`;
   - the last 20 `chat_messages` as alternating user/assistant turns.
5. **Call DeepSeek:**
   - `POST https://api.deepseek.com/chat/completions` with `model:"deepseek-flash"`,
     `thinking:{type:"disabled"}`, `max_tokens:350` and `temperature:0.7` [41][43].
   - Timeout of 25 s; one retry on 429, 5xx or an empty reply.
   - `DEEPSEEK_MODEL` and `DEEPSEEK_BASE_URL` can be overridden through env (the base URL is used for the test
     stub).
6. **Store the reply** with `role='plant'`, `based_on_reading_at` (the `recorded_at` of the latest reading in the
   context), the model name and the token usage, then return it.
   - If DeepSeek fails, store and return a short deterministic fallback built from `plant_status_v`, with `error` set,
     so the conversation never hangs.

**System prompt (static prefix, so it can be cached):**
> You are {nickname}, a peace lily (Spathiphyllum) in a pot, chatting with the person who looks after you.
> Speak in first person as the plant, warm and a little playful, in 1–4 short sentences.
> **Always reply in the same language as the person's latest message.**
> Your feelings must match the STATUS and MEASUREMENTS given below. Never invent readings; if a value is null or
> unknown, say you can't sense it right now.
> For care questions, give concrete advice based on the CARE NOTES and THRESHOLDS. Never recommend chemicals or
> fertilizer doses.
> If soil is "unknown" because the probe is not calibrated, suggest the Soil calibration screen.
> Stay in character, and politely steer off-topic requests back to plant care.

The dynamic context block (status, measurements, summaries, local time) is added as a second system message, after
the static prefix and before the history.

---

## 6. Task breakdown (each task owns disjoint files; parallel workers)

The interfaces in §5.3, the schema in §5.6 and the contract in §4 are fixed by this plan. Every task adds its own
tests. Depending on what it touches, it must pass `uv run pytest`, `supabase test db` and/or `deno test`.

| ID | Owner files | Depends on | Acceptance criteria | Verify (no hardware) |
|---|---|---|---|---|
| **T1 Core schema** | `supabase/config.toml`, `migrations/20261116000100_core.sql`, `supabase/seed.sql`, `supabase/tests/core_test.sql` | — | **Schema:** tables, `soil_pct()`, `readings_v`, grants, RLS and publication exactly as in §5.6. **Seed:** the spathiphyllum profile (thresholds and care notes from §2.8, plus sources), a local owner, a plant (tz `Asia/Seoul` for local only, overridable), device `olvar-a1b2c3` with calibration, and 48 h of synthetic readings. **pgTAP:** the owner sees rows and a second user sees none; anon gets nothing; the owner can update only the calibration columns, plus `nickname`, `location`, `timezone` and `threshold_overrides` on plants; malformed overrides are rejected; reversed or too-close calibration is rejected; the dedup key works; `soil_pct` is null when uncalibrated, clamps to 0–100, and follows a recalibration retroactively | `supabase start && supabase db reset && supabase test db` |
| **T2 Rollups & retention** | `migrations/20261116000200_rollups.sql`, `supabase/tests/rollups_test.sql` | T1 DDL | `refresh_rollups` is idempotent. A late row updates its old bucket. **Catch-up:** with `processed_until` set 3 days back, one run fills every missed bucket. Concurrent runs: the second exits on the advisory lock. **Null sensors:** a fixture with one valid temperature in hour A and 60 in hour B gives the exact daily mean (≈29.84 °C in the review example), and per-metric `_n` is correct. Daily values use the local date, including a +05:30 timezone. The views compute inverted soil min/max. Retention deletes only rows > 90 d that are at or below the watermark. Cron jobs are registered | pgTAP fixtures; `select * from cron.job` |
| **T3 Status view + offline periods** | `migrations/20261116000300_status.sql`, `supabase/tests/status_test.sql` | T1 DDL | `effective_thresholds` merges overrides per metric. `plant_status_v` gives the right status, labels and summary for every rule in §5.6, including `no_data`, `offline` (> 180 s), uncalibrated soil, day/night light in the plant timezone, and the 12 h and 48 h "high" persistence rules. `device_offline_periods` returns: gaps > 180 s only; gaps clipped at the window edges; a gap spanning midnight in both days' results; `device_restart` when `boot_id` changes; `ongoing` for an open trailing gap; nothing for another owner's device (RLS); an error for a window > 7 days | Table-driven pgTAP with fixed `now()` via fixtures |
| **T4 Chat function** | `supabase/functions/chat/**`, `migrations/20261116000400_chat.sql`, `supabase/tests/chat_test.sql` | T1, T3 (reads views) | Ownership is enforced and a non-owner gets 404. Rate limits return 429. **pgTAP concurrency test:** two sessions call `chat_admit` at 199/200 and exactly one succeeds (row lock), and the same holds for the 5-min window. `based_on_reading_at` is set on plant rows. The context builder is a pure function (unit-tested). The request body has `thinking.type="disabled"` and `model="deepseek-flash"`. The stub covers success, empty reply, 429, 5xx and timeout → fallback row with `error`. Both rows are stored, and RLS hides chats from other users | `deno test supabase/functions/chat`; `supabase functions serve --env-file supabase/functions/.env.local` + `curl` with a seeded user's JWT |
| **T5 Payload contract & models** | `contracts/**`, `src/olvar_gateway/models.py`, `tests/test_models.py` | — | The JSON Schema matches §4 (no `soil_pct`, optional `rssi_dbm`, unknown keys allowed). The pydantic model agrees on all examples. Rejects a topic/id mismatch, NaN, > 1 KiB and a bad `boot_id`. Out-of-range values become null | `uv run pytest tests/test_models.py` |
| **T6 Clock, outbox, uploader** | `src/olvar_gateway/{clock,buffer,uploader}.py`, `tests/test_{clock,buffer,uploader}.py` | §5.3 | The outbox survives a kill. A duplicate put is a no-op. The cap drops the oldest rows. Unsynced rows are held and then backfilled. The uploader handles 2xx, 5xx and network errors. **Classification:** a 401/403/`42501`/404/`PGRST*` response leaves every row queued with `last_error` set, and delivery resumes once the mock is fixed; a batch with one `23514` row dead-letters only that row (bisection). It sends the headers and `on_conflict` exactly as in §5.4. Device upserts never send calibration columns | pytest with a fake clock and `httpx.MockTransport`; optional `-m supabase` against the local stack |
| **T7 MQTT + service wiring** | `src/olvar_gateway/{mqtt_client,service,config,log,__main__}.py`, `pyproject.toml`, `uv.lock`, `requirements.txt`, `tests/test_service.py` | T5, T6 interfaces | Env config with clear errors. MQTT 5 persistent session. Status updates reach devices. Heartbeat every 5 min. SIGTERM flushes. Logs are JSON lines. `python -m olvar_gateway status` prints the queue depth, dead-letter count and `last_error` | pytest with fakes; `python -m olvar_gateway --check-config` |
| **T8 Fake device + E2E** | `tools/fake_esp32.py`, `dev/compose.yml`, `tests/e2e/**` | T7 | The fake device simulates a day/night lux curve, soil_raw drying and a watering jump (higher = drier), a reboot (new boot_id, seq reset), QoS 1 duplicates, garbage payloads, null sensors, `rssi_dbm`, and the LWT on SIGKILL. **E2E:** the happy path inserts N rows; Supabase down for 2 min loses nothing and creates no duplicates; a gateway restart loses nothing; a spoofed id is rejected; the LWT makes the device offline and `plant_status_v.overall = offline` | `docker compose -f dev/compose.yml up -d && supabase start && uv run pytest -m e2e` |
| **T9 Pi deployment & setup** | `deploy/**`, `tools/setup_plant.py`, `docs/DEPLOY.md`, `docs/RUNBOOK.md` | T7 | `install.sh` is idempotent: apt packages, `olvar` user, venv, env file 0640, unit with `StateDirectory` and sandboxing, journald cap, nftables. `update.sh` checks out a tag, installs pinned dependencies and restarts. `setup_plant.py` creates the one plant and device (owner email → owner_id, timezone) and prints the `mosquitto_passwd` command | Debian Trixie arm64 container (`systemd-analyze verify`, `shellcheck`) |
| **T10 CI + types** | `.github/workflows/ci.yml`, `supabase/types/database.types.ts`, `README.md` | T1–T4 | Jobs: ruff + pytest; supabase start, db reset and test db; deno test; type generation, which fails the build if the committed file differs | GitHub Actions green |

Only these need the real hardware:
- the ESP32's real QoS 1 and last-will behaviour over Wi-Fi;
- an offline boot of the Pi (check `clock_source='backfilled'`);
- probe calibration in the real pot, using the dashboard screen.

---

## 7. Things the user must do by hand

1. **Supabase project:**
   - Create a Free project and keep "Automatically expose new tables" **off**.
   - Copy the project URL and the publishable key.
   - Create a **named secret key `gateway`** for the Pi [10].
2. **Supabase CLI** on your dev machine, with Docker Desktop or OrbStack (about 7 GB of RAM) [36]. Run, in order:
   - `supabase login`
   - `supabase link --project-ref …`
   - `supabase db push`
   - `supabase functions deploy chat`
3. **Auth:**
   - Create the owner user (Authentication → Users).
   - **Disable sign-ups.**
   - Run `tools/setup_plant.py --owner-email … --device-id olvar-xxxxxx --timezone Area/City`. Take the device id
     from the ESP32 serial log.
4. **DeepSeek:**
   - Create an account at platform.deepseek.com and top up (prepaid).
   - Create an API key.
   - Run `supabase secrets set DEEPSEEK_API_KEY=…` [34][40].
5. **Raspberry Pi:**
   - Flash **Raspberry Pi OS Lite (64-bit)** with Raspberry Pi Imager: hostname `olvar-gw`, user, SSH, Wi-Fi or
     Ethernet.
   - Add a DHCP reservation on your router.
   - Use a good SD card and a good power supply [24].
6. **On the Pi:**
   - `git clone` the repo.
   - Run `sudo deploy/install.sh`.
   - Fill in `/etc/olvar-gateway/gateway.env`.
   - Run `sudo mosquitto_passwd /etc/mosquitto/passwd olvar-xxxxxx` and `… olvar-gateway`.
7. **ESP32:** enter the Wi-Fi details, broker host, username and password in the firmware config, then flash over USB.
8. **Soil calibration:** in the dashboard's Soil calibration screen,
   - capture the dry value when the plant needs water (top 2–3 cm of soil dry);
   - capture the wet value after a full watering has drained [56].
9. **Sensor placement:**
   - BH1750 at leaf height, facing the window.
   - SHT31 out of direct sun and away from the wet soil surface.

---

## 8. Risks and open questions

**Open questions:** none block v1. The user's 2026-11-16 decisions answered all earlier questions (login, language,
retention, DeepSeek use, MQTT encryption, backups).

**Risks:**
- **R1 Free-project pause.** A Free project pauses after 7 days of low activity [29]. The gateway heartbeat prevents
  this while the Pi is online. If the Pi is off for more than a week, restore the project from the Supabase
  dashboard.
- **R2 Pi clock.** The Pi has no RTC [7]. The backfill logic in §5.4 mitigates this. An optional DS3231 RTC module
  would remove the risk.
- **R3 SD-card corruption.** Mitigated by a good SD card, `synchronous=FULL` and a journald size cap [24][25].
  **There are no backups by decision**, so a lost Supabase project means lost history.
- **R4 Supabase platform changes.** Legacy API keys are being removed [8], and new tables no longer get default
  grants [11]. The plan uses only the new keys and explicit grants.
- **R5 DeepSeek.**
  - Thinking is on by default and must be disabled [41].
  - Models and prices change often [38], so `DEEPSEEK_MODEL` is configurable.
  - The daily cap of 200 admitted messages is enforced atomically. It bounds the cost at about $9/month, or $18/month
    if every call is retried.
- **R6 Retroactive recalibration.** Soil history is re-expressed with the current calibration. If the probe is moved
  to a different depth or pot, older `soil_pct` values change meaning. Storing a history of calibrations is the
  upgrade path after v1.
- **R7 Soil thresholds.** The 20/35/85/90% values are heuristics, because no extension source gives sensor
  percentages. They can be tuned through `plants.threshold_overrides` without a deploy.
- **R11 Offline history horizon.** Offline periods are derived from raw readings, so the Timeline cannot show them
  for days older than 90 days. If that is ever needed, persist the gaps from `refresh_rollups` into a small table
  before retention runs.
- **R8 Light.** The BH1750 measures illuminance in lux, not PAR. The thresholds are approximate conversions from
  extension guidance written in foot-candles [50][54].
- **R9 Firmware QoS.** QoS 1 publishing needs `esp-mqtt` or an equivalent client; `PubSubClient` only publishes
  QoS 0 [26].
- **R10 Local dev quirk.** The Edge Function must reach the DeepSeek stub from inside Docker. For local tests, set
  `DEEPSEEK_BASE_URL=http://host.docker.internal:<port>`.
