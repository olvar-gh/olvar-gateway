# olvar-gateway — Project plan

Scope of this repo: the Raspberry Pi gateway service (MQTT → validate → durable buffer → Supabase), the Mosquitto
broker configuration, the Pi deployment, **and** everything that lives in Supabase (schema, migrations, RLS, cron
jobs, the avatar Edge Function, generated types). Firmware and dashboard have their own plans; this document
states which parts of the shared contract it relies on and where it proposes changes.

Research date: 2026-11-16. Numbers in brackets like [3] point to the sources list in §2.11.

---

## 1. Summary

- **Runtime:** Python 3.13 (the version that ships with Raspberry Pi OS Trixie) running as a **systemd** service on
  **Raspberry Pi OS Lite 64-bit (Trixie)**. Libraries: `paho-mqtt` 2.x, `httpx`, `pydantic` 2. The service does not use
  `supabase-py`: it calls PostgREST directly with the **secret key** (`sb_secret_…`) sent in the `apikey` header.
- **Broker:** Mosquitto 2.x from apt, listening on the LAN at 1883. Anonymous access is off, each device has its
  own username and password (**username = device_id**), and an ACL file means a device can only publish to its own
  topics.
- **Durability:** every valid message first goes into a **SQLite outbox** (WAL mode, `synchronous=FULL`). An uploader
  then sends it to Supabase as an idempotent upsert keyed on `(device_id, boot_id, seq)`. Retries back off
  exponentially, and malformed or rejected rows go to a dead-letter table.
- **Volume:** one device at 60 s is 1,440 rows a day, about 0.3 MB/day with indexes (estimate). That is roughly
  115 MB a year, so the 500 MB Free-plan database holds it comfortably. pg_cron jobs build **hourly** and **daily
  rollups** for the charts, and raw rows are deleted after **90 days** (open question Q3).
- **Supabase:** only the **publishable/secret** keys are used, because the legacy `anon`/`service_role` keys are
  deprecated by the end of 2026 [8]. Every migration contains **explicit GRANTs**, because new tables are no longer
  exposed to the Data API automatically [11]. RLS is single-owner: the dashboard **requires sign-in**, public
  sign-ups are disabled, and rows are visible only to `devices.owner_id` / `plants.owner_id`.
- **Avatar:** a **Supabase Edge Function `avatar-tick`, triggered every 15 min by pg_cron**, not the Pi. A
  deterministic rules engine (using the peace-lily thresholds in §2.8) decides `mood` and `expression`. DeepSeek
  `deepseek-flash` (non-thinking mode, JSON output) only writes the first-person `message` and the `advice` text.
  The model is called only when the plant's state changes or the last message is more than 3 h old. Worst case is
  about **$2.4/month**; the typical cost is well under $0.50/month (§2.7).
- **"Avatar" in practice:** DeepSeek is a text model. The avatar is a set of pre-drawn expression sprites in the
  dashboard, chosen by the `expression` enum, plus an LLM-written speech bubble and advice cards.
- **Testing without hardware:** a fake ESP32 publisher (`tools/fake_esp32.py`), a local Mosquitto in Docker,
  `supabase start` for the full local stack, pgTAP tests for RLS and rollups, `deno test` with a DeepSeek stub, and
  pytest for the gateway.

---

## 2. Research findings (with sources)

### 2.1 Raspberry Pi 3B and OS
- The current Raspberry Pi OS is a port of **Debian 13 "Trixie"** with kernel 6.18 (release of 6 Oct 2026). The **64-bit
  image lists the Pi 3B as compatible**, and a "Legacy" Bookworm image still exists [1].
- Lite (no desktop) is the edition meant for headless servers [2]. Trixie ships **Python 3.13**, and system Python is
  "externally managed", so packages have to go into a venv [3][2].
- The 64-bit OS uses more RAM. Phoronix measured **196 MB versus 103 MB** at idle [4], and one Pi 3B user reported about
  20% more memory for the same workload [5]. On a headless 1 GB Pi with two small services this is acceptable, and
  64-bit gets standard `aarch64` manylinux wheels from PyPI (`pydantic-core`, for example).
- The Pi has **no RTC**. `systemd-timesyncd` saves the clock to disk and creates **`/run/systemd/timesync/synchronized`**
  after each successful NTP sync [6]. Without a network at boot, the clock is wrong (it is restored from the last
  saved time) [7]. The gateway has to detect this before it stamps any time (§5.4).
- SD-card writes: Raspberry Pi's own resilience whitepaper recommends reducing writes and capping journald, for example
  with a `journald.conf.d` drop-in [24]. SQLite in WAL mode with `synchronous=NORMAL` can roll back the last
  transaction on power loss. `FULL` is durable [25]. At one write per minute, `FULL` costs nothing that matters.

### 2.2 Mosquitto
- Since Mosquitto 2.0 authentication has to be configured explicitly, and `allow_anonymous` defaults to `false` once a
  listener is defined [12][13].
- `password_file` is managed with `mosquitto_passwd` (argon2id hashes by default) [14]. In `acl_file`,
  `pattern write olvar/v1/%u/...` replaces `%u` with the username [13]. When an ACL file is set, anything it does not
  allow is denied [15].
- The Debian package's main config already enables persistence and includes `conf.d/*.conf`. Settings such as
  `persistence_location` must not be repeated in `conf.d`, or Mosquitto refuses to start [15].
- Without TLS, MQTT credentials travel in clear text [15]. This is an accepted risk on a home LAN (§3, Q6).
- Firmware note: the common Arduino `PubSubClient` library **can only publish QoS 0** [26]. To get QoS 1 the firmware
  needs ESP-IDF `esp-mqtt` or another client.

### 2.3 Python libraries
- `paho-mqtt` 2.2.0 (Nov 2026). The 2.x line **requires `CallbackAPIVersion.VERSION2`** in the constructor, and the
  callback signatures changed from 1.x [16][17].
- `supabase` (supabase-py) 2.34.1 needs Python ≥ 3.11 [18]. It brings auth, realtime and storage clients the gateway does
  not need, so the gateway uses `httpx` against PostgREST directly.
- PostgREST bulk upsert: `POST /rest/v1/readings?on_conflict=device_id,boot_id,seq` with
  `Prefer: resolution=ignore-duplicates` sends one INSERT … ON CONFLICT DO NOTHING per batch [19]. The Python client
  exposes the same thing as `ignore_duplicates`/`on_conflict` [20].

### 2.4 Supabase keys, grants, RLS, Realtime
- There are four key types. **Publishable** (`sb_publishable_…`) is safe to ship in an app and runs as
  `anon`/`authenticated` under RLS. **Secret** (`sb_secret_…`) is for backends only and bypasses RLS.
  **`anon`/`service_role` are legacy and deprecated by the end of 2026** [8][9]. You can create several named secret
  keys and rotate them independently [9][10].
- Secret keys return **HTTP 401 when used from a browser** (matched on User-Agent) [9]. Supabase's examples send them
  in the **`apikey` header** [21].
- **Breaking change:** new tables in `public` are **not exposed to the Data API by default**. This became the default
  for new projects from 30 May 2026 and is being applied to existing projects from 30 Oct 2026. You need explicit
  `GRANT … TO anon/authenticated/service_role`, and a missing grant returns `42501` [11]. The grants apply to
  `service_role` too [11].
- RLS performance: name the role in the `to` clause, wrap `auth.uid()` as `(select auth.uid())`, index the columns
  policies filter on, and avoid joins in policies by using `col in (select …)` [22][23].
- Realtime `postgres_changes`: the table must be in the `supabase_realtime` publication, and RLS decides which
  INSERT/UPDATE events a subscriber receives. DELETE events are not filtered by RLS [27][28].
- Free plan: 500 MB database (read-only at 95% of the fixed 2 GB disk), **paused after 7 days of low activity**, no
  backups, 500k Edge Function invocations, 2M Realtime messages, 200 concurrent Realtime connections, and unlimited API
  requests [29][30][31].
- Edge Functions: 150 s wall clock on Free, 2 s CPU per request, 256 MB memory [32]. They are scheduled with
  **pg_cron + pg_net**, with the URL and secret key stored in **Vault**. A function called with a secret key needs
  `verify_jwt = false` and `withSupabase({ auth: 'secret' })` from `npm:@supabase/server@1` [21][33].
  `SUPABASE_URL` and `SUPABASE_SECRET_KEYS` are injected automatically [34].
- The `timescaledb` extension is **deprecated on Postgres 17**, so the plan uses plain tables, pg_cron and rollup
  tables instead of hypertables [35].
- Local development: `supabase start` (Docker, about 7 GB RAM recommended), `supabase db reset` (applies migrations and
  seed), `supabase test db` (pgTAP), `supabase gen types --lang typescript`, and
  `supabase functions serve --env-file` [36][37].

### 2.5 DeepSeek API (verified 2026-11-16)
- **The model id is exactly `deepseek-flash`.** It currently serves **DeepSeek-V4.1-Flash-1017** (upgraded on 17 Oct 2026,
  "pricing unchanged"). The legacy names `deepseek-v4-flash` and `deepseek-v4-flash-vision-exp` still work but are routed
  to the same model. The other model is `deepseek-v4-pro` [38][39][40].
- Base URL `https://api.deepseek.com` (OpenAI format). An Anthropic-format endpoint is at `/anthropic` [39][40].
- **Pricing per 1M tokens for `deepseek-flash`:** input cache hit $0.003 off-peak / $0.006 peak; input cache miss
  $0.15 / $0.30; output $0.60 / $1.20. **Peak** is 01:00–04:00 and 06:00–10:00 UTC on weekdays, and every other hour is
  billed at half price [39].
- **Thinking mode is ON by default.** Disable it with `{"thinking": {"type": "disabled"}}`. In thinking mode
  `temperature` is ignored [41].
- **JSON Output:** set `response_format: {type: "json_object"}`, include the word "json" and an example in the prompt,
  and set `max_tokens`. **The content can come back blank (only spaces)** even with `finish_reason=stop`, so you have to
  retry or fall back [42][43].
- Rate limits are concurrency-based: 2,500 concurrent requests for flash, and **HTTP 429** above that [44]. That limit is
  irrelevant at this project's load.
- DeepSeek lists **Vision as image *input*** and has no image generation [39]. So "avatar" means text plus
  dashboard-side art (§3).

### 2.6 Volume and Free-plan budget (estimates; verify after 1 week with `pg_total_relation_size`)
| Item | Per day | Per year | Free limit |
|---|---|---|---|
| Raw readings (1 device × 60 s) | 1,440 rows ≈ 0.3 MB incl. 3 indexes | ≈ 115 MB | 500 MB DB |
| Raw kept 90 days | — | ≈ 28 MB steady state | |
| Hourly rollups | 24 rows | ≈ 2 MB | |
| PostgREST requests (1 upsert/msg + heartbeat) | ≈ 1,700 | — | unlimited [29] |
| Realtime messages (2 open dashboards) | ≈ 3,000 | ≈ 90k/month | 2M/month [30] |
| Edge Function invocations (cron 15 min) | 96 | ≈ 2.9k/month | 500k/month |

Row-size basis: about 24 B tuple header, about 100 B of columns, a 4 B item pointer, and three b-tree entries. Treat
the numbers as ±50%.

### 2.7 DeepSeek cost estimate
- One call is about 1,100 input tokens (≈ 800 of them a static, cacheable system prompt and ≈ 300 the plant data)
  plus at most 250 output tokens.
- **Worst case:** 96 calls a day, no cache hits, all at peak prices. That is 3.2M input tokens × $0.30 + 0.72M output
  tokens × $1.20, about **$1.82/month**. Allowing ±30% for longer prompts, budget **≤ $2.40/month**.
- **Expected:** the model is called only when the state changes or after 3 h, so about 15–25 calls a day, most of
  them off-peak and with cache hits on the system prompt. That comes to **about $0.10–0.40/month**. DeepSeek is
  prepaid, so a $2 top-up covers months.

### 2.8 Peace lily (Spathiphyllum) care thresholds
The sources are university extension services. 1 fc = 10.764 lux.

| Variable | Evidence | Proposed thresholds used by the rules engine |
|---|---|---|
| Temperature | Days 68–85 °F (20–29.4 °C), nights about 10 °F cooler; avoid < 60 °F (15.6 °C) [45][46]. 40–60 °F slows growth; damage after extended periods < 40 °F [46]. Chilling injury from 45 °F (7.2 °C) in some cultivars; growth delayed after 5 days at 52 °F (11.1 °C); keep ≤ 90 °F (32.2 °C) [47]. Preferred 75–85 °F, growth reduced ≤ 50 °F [48]. | critical_low < 10 °C · low < 16 °C · ok 18–29 °C · high > 30 °C · critical_high > 32 °C (evaluated on the 30-min median) |
| Humidity | Brown tips from low humidity [46][49]. Indoor RH < 20% is low, 40–50% medium, > 50% high [50]. Tropical houseplants do best > 50% [51]. 40–60% is best for most plants and hard to reach indoors [52]. | critical_low < 25% · low < 40% · ok 40–70% · high > 85% sustained 12 h (fungal-risk heuristic, low confidence) |
| Light | Bright indirect light, no direct sun [45][48]. Low-light plants need at least 25 fc (≈ 270 lx), and 75–200 fc (≈ 800–2,150 lx) is preferred [50][51]. Peace lily *adapts* to low light but **needs medium light (250–1,000 fc) to flower** [53]. Over 1,000 fc (≈ 10.8 klx) means direct indoor sun [54]. Leaf burn above 2,500 fc (≈ 27 klx) even in production [47]. | Evaluated on the **daytime mean** (08:00–18:00 local, last 24 h), not on single readings: critical_low < 270 lx · low < 800 lx · ok 800–5,400 lx · high if any 10-min median > 10,800 lx · critical_high > 27,000 lx |
| Soil moisture | "Keep moist but not soggy, allow to dry slightly between waterings"; overwatering causes root rot; wilting when too dry [45][49][48]. No extension source gives a sensor percentage. Capacitive probe readings are **relative and vary by unit and soil**, so each probe must be calibrated [55][56][57]. | Heuristic on calibrated `soil_pct`: critical_low < 20 · low < 35 · ok 35–85 · high > 90 for 48 h. **Tune per plant** (Q5) |

The thresholds are stored as data (`plant_profiles.thresholds`, with per-plant `threshold_overrides`), so tuning them
needs no deploy.

### 2.9 Capacitive soil sensor (affects `soil_pct` meaning)
- Output voltage falls as moisture rises, at roughly 2.3–3.0 V dry and 1.0–1.5 V wet depending on the unit. The ESP32
  ADC needs 11/12 dB attenuation to read the full range [55][57].
- Air-versus-water calibration is a functional check. A better calibration uses the real pot: record the reading when
  the soil is "dry enough to water" and again after a thorough watering has drained [56].

### 2.10 Deployment
- A systemd unit with `EnvironmentFile=`, `Restart=on-failure` and sandboxing (`ProtectSystem=strict`,
  `ReadWritePaths`, `NoNewPrivileges`) is the standard way to run a Python app in a venv without Docker [58].

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
21. Scheduling Edge Functions — https://supabase.com/docs/guides/functions/schedule-functions
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
33. Securing Edge Functions (service-to-service) — https://supabase.com/docs/guides/functions/auth
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
| D1 | **Raspberry Pi OS Lite 64-bit (Trixie)** | It is the officially supported image for the 3B, has no desktop RAM cost, and gets standard aarch64 wheels [1][2] | 32-bit (saves RAM, but fewer prebuilt wheels, and nothing here is RAM-bound); Legacy Bookworm (older; only for compatibility needs) |
| D2 | **Python 3.13 + paho-mqtt 2 + httpx + pydantic 2** | The system interpreter is already on the Pi; the code is readable for a student or novice project; pytest makes testing easy; about 40 MB RSS | **Go**: about 10 MB and a static binary, but less approachable and validation is more manual. **Node**: heavier (~60 MB) and gains nothing here. **supabase-py**: pulls in unused realtime, auth and storage dependencies |
| D3 | **Threaded paho (loop_start) + an uploader thread**, not asyncio | Two simple threads with a SQLite queue between them; paho handles reconnects | aiomqtt/asyncio: fine, but adds concepts for no gain at 1 msg/min |
| D4 | **systemd + apt Mosquitto**, no Docker on the Pi | Docker adds RAM, SD writes and image pulls on a 1 GB/SD-card machine; there are only two services | Docker Compose (it is used on the **dev machine** for Mosquitto instead) |
| D5 | **SQLite outbox, upload by idempotent upsert** | Survives restarts and power loss; "at-least-once" delivery plus a DB unique key gives exactly one row per reading | Upload straight from the callback (loses data offline); a file-based queue (no atomic ack) |
| D6 | **Gateway stamps `recorded_at`, but only from an NTP-synced clock** (§5.4) | The ESP32 has no clock, and the Pi has no RTC [6][7] | Trusting the Pi clock at all times (wrong timestamps after an offline boot) |
| D7 | **Avatar job = Supabase Edge Function + pg_cron (every 15 min)** | It keeps working while the Pi is down (it can show "offline"); the DeepSeek key lives in Supabase secrets, not on an SD card; it is testable with `supabase functions serve`; the Pi stays lean | Running it in the Pi service: one less component, but it couples the LLM to the Pi's uptime and puts another secret on the Pi |
| D8 | **Rules decide the state; the LLM writes only the words** | Deterministic, testable, and still works when DeepSeek fails or returns blank JSON [42]; prevents the model from inventing the plant's state | LLM decides the mood (non-deterministic, hard to test) |
| D9 | **`deepseek-flash`, thinking disabled, JSON mode, max_tokens 400** | Cheapest model; reasoning tokens are billed as output and add nothing to a 2-sentence message [39][41] | `deepseek-v4-pro` (4× the price, no benefit here) |
| D10 | **Avatar = sprite set chosen by `expression` + LLM speech bubble** | DeepSeek does not generate images [39] | Generating images (needs another provider; costly) |
| D11 | **Dashboard requires sign-in; single owner via `owner_id`; sign-ups disabled** | Plant data is low-sensitivity, but a public read policy (`using (true)`) exposes it to anyone with the URL [22]; owner scoping costs little | Public read-only dashboard (Q1); anonymous sign-ins |
| D12 | **Plain tables + pg_cron rollups**, no TimescaleDB | timescaledb is deprecated on PG17 [35] | Hypertables/continuous aggregates; materialized views (a full refresh rescans everything) |
| D13 | **Plain MQTT on the LAN (1883) + passwords + ACL + firewall restricted to the LAN subnet** | ESP32 TLS means certificate pinning and rotation work for a home LAN; accepted risk [15] | TLS on 8883 (documented as a later hardening step, Q6) |
| D14 | **`postgres_changes` for Realtime** | It is enough at 1 insert/min, and RLS is applied automatically [27] | Broadcast from DB triggers (scales better, but adds triggers and channel authorization) |
| D15 | **Lock files: `uv` on dev, `uv export` → hashed `requirements.txt` → `pip` in a venv on the Pi** | No extra tool needed on the Pi; reproducible installs | Installing uv on the Pi (fine, but unnecessary) |

---

## 4. Contract changes

These are changes to the provisional cross-repo contract. Clarifications that do not change behaviour are marked
*(clarification)*.

**C1 — Add `boot_id` to the telemetry payload (firmware).**
`"boot_id": string`, 8 lowercase hex characters, generated randomly once per boot (e.g. `esp_random()`).
*Why:* `seq` and `uptime_ms` restart from 0 after every reboot, so `(device_id, seq)` cannot be used for
deduplication. `(device_id, boot_id, seq)` is unique across reboots and is the database's unique key. It makes MQTT
QoS 1 redelivery and gateway retries harmless.

**C2 — Sensor fields are nullable (firmware).** `temperature_c`, `humidity_pct`, `lux`, `soil_raw` and `soil_pct` may be
`null` when that sensor's read fails. `NaN` and `Infinity` are forbidden because they are invalid JSON.
*Why:* one failed I²C sensor should not drop the other readings. The gateway also sets a field to null when it is
outside its physical range and logs the event.

**C3 — `readings` gets more columns (dashboard: types).** The table is now
`readings(id, device_id, recorded_at, received_at, boot_id, seq, uptime_ms, temperature_c, humidity_pct, lux,
soil_raw, soil_pct, clock_source)` with `unique(device_id, boot_id, seq)`. Firmware version moves to `devices.fw`.
New tables: `plant_profiles`, `plants`, `devices`, `readings_hourly`, `readings_daily`, `gateways` (§5.6).
*Why:* deduplication, auditing of clock quality, and chart performance.

**C4 — Device identity and MQTT auth (firmware) *(clarification)*.** The MQTT **username equals `device_id`**
(`^[a-z0-9][a-z0-9-]{2,31}$`), each device has its own password, and the client id equals `device_id`. The ACL allows a
device to write **only** `olvar/v1/<its username>/telemetry` and `/status`. The gateway rejects any message where the
payload `device_id` differs from the topic segment. `olvar-gateway` is reserved as a device id.

**C5 — QoS and status semantics (firmware) *(clarification)*.** Telemetry is published with **QoS 1, not retained**.
Status is published retained with QoS 1 as the plain strings `online` (right after connecting) and `offline` (as the
last will). Firmware should use a client that supports QoS 1 publishing (ESP-IDF `esp-mqtt`; `PubSubClient` is QoS 0
only [26]). The gateway accepts QoS 0, but loses messages while it restarts.

**C6 — Max payload 1 KiB, UTF-8 JSON object, unknown keys ignored (firmware) *(clarification)*.** This lets firmware add
fields without breaking the gateway.

**C7 — Avatar location and shape (dashboard).** The avatar job is an **Edge Function `avatar-tick` scheduled by
pg_cron**, as decided in D7. The `avatar_states` row is
`{id, plant_id, created_at, based_on_reading_at, mood, expression, message, advice[], metric_status{}, source, model,
prompt_version, state_signature}` (§5.6). `expression` is an enum the dashboard maps to its own sprites:
`happy | content | thirsty | soggy | cold | hot | gloomy | sunburnt | dry_air | sleepy | offline`.
`mood` is one of `thriving | ok | needs_attention | in_trouble | offline`.

**C8 — Dashboard auth and reads (dashboard).** The dashboard **signs in** (Supabase Auth, email+password or OTP, with a
single owner account created by hand). All reads go through RLS by owner; nothing is granted to `anon`. Charts read
`readings` for windows up to 48 h, `readings_hourly` up to 90 days, and `readings_daily` beyond that. Realtime
subscriptions are on `readings` (INSERT, filter `device_id=eq.<id>`), `avatar_states` (INSERT, filter
`plant_id=eq.<id>`) and `devices` (UPDATE, for online/offline).

**C9 — Generated types location (dashboard).** `supabase/types/database.types.ts` is committed in **olvar-gateway**, is
regenerated in CI on every migration change, and the dashboard copies or fetches it at a pinned commit.

**C10 — Secret key header (gateway-internal) *(clarification)*.** The gateway sends `apikey: sb_secret_…` and does not
send it as `Authorization: Bearer` [9][21]. It uses a dedicated named secret key, `gateway`, so that key can be rotated
without touching the Edge Function's `default` key.

Example v1 telemetry (also stored in `contracts/examples/valid-full.json`):
```json
{"device_id":"lily-01","boot_id":"3fa9c2e1","seq":42,"uptime_ms":2520113,
 "temperature_c":23.4,"humidity_pct":48.2,"lux":1520.0,"soil_raw":2214,"soil_pct":61.5,"fw":"0.1.0"}
```

---

## 5. Architecture and folder layout

### 5.1 Data flow
```
ESP32 ──MQTT QoS1──▶ Mosquitto (Pi :1883, auth+ACL)
                         │  olvar/v1/<id>/telemetry, /status (retained, LWT)
                         ▼
                 olvar-gateway (Pi, systemd)
   validate (pydantic) → stamp time (if NTP-synced) → SQLite outbox (WAL, FULL)
                         │ uploader thread: batch ≤500, upsert ignore-duplicates, backoff
                         ▼
            Supabase PostgREST (secret key) ──▶ Postgres
                                               ├─ readings ─┐ pg_cron :05 → readings_hourly/daily
                                               ├─ devices   │ pg_cron 03:30 UTC → delete raw > 90 d
                                               └─ avatar_states ◀─ Edge Fn avatar-tick ◀─ pg_cron */15
                                                      │                └─▶ DeepSeek deepseek-flash
                                Realtime (postgres_changes, RLS) ──▶ Expo dashboard (publishable key + login)
```

### 5.2 Repository layout
```
olvar-gateway/
├── README.md
├── docs/PLAN.md · docs/DEPLOY.md · docs/RUNBOOK.md
├── pyproject.toml · uv.lock · requirements.txt (uv export, hashed)
├── contracts/
│   ├── telemetry.v1.schema.json          # JSON Schema for the payload (shared with firmware)
│   └── examples/{valid-*.json,invalid-*.json}
├── src/olvar_gateway/
│   ├── __main__.py      # python -m olvar_gateway
│   ├── config.py        # env → Settings (frozen dataclass)
│   ├── models.py        # Telemetry (pydantic), ReadingRow, parse_message()
│   ├── clock.py         # NTP-sync detection, monotonic backfill
│   ├── buffer.py        # Outbox (SQLite)
│   ├── uploader.py      # SupabaseWriter (httpx) + Uploader loop
│   ├── mqtt_client.py   # paho wrapper, subscriptions, status handling
│   ├── service.py       # wiring, threads, heartbeat, signals
│   └── log.py           # JSON-lines logging to stdout
├── tests/               # pytest unit + tests/e2e (docker mosquitto + supabase local)
├── tools/
│   ├── fake_esp32.py    # simulated device(s)
│   └── provision_device.py  # create MQTT user + devices row + owner/plant link
├── dev/compose.yml      # mosquitto for local dev, using deploy/mosquitto/*
├── deploy/
│   ├── mosquitto/olvar.conf · acl
│   ├── systemd/olvar-gateway.service
│   ├── journald/olvar.conf
│   ├── gateway.env.example
│   └── install.sh · update.sh
├── supabase/
│   ├── config.toml
│   ├── migrations/
│   │   ├── 20261116000100_core.sql       # tables, grants, RLS, publication
│   │   ├── 20261116000200_rollups.sql    # rollup tables, refresh fn, cron jobs, retention
│   │   └── 20261116000300_avatar.sql     # avatar_states, cron → avatar-tick
│   ├── seed.sql                          # spathiphyllum profile, local owner, device, sample data
│   ├── tests/*.sql                       # pgTAP
│   ├── functions/avatar-tick/{index.ts,rules.ts,prompt.ts,deepseek.ts,schema.ts,*_test.ts}
│   └── types/database.types.ts           # generated
└── .github/workflows/ci.yml
```

### 5.3 Gateway internals (interfaces fixed so tasks can be built in parallel)
```python
# models.py
class InvalidMessage(Exception): reason: str
@dataclass(frozen=True)
class ReadingRow:            # == readings columns minus id/received_at
    device_id: str; boot_id: str; seq: int; uptime_ms: int
    recorded_at: datetime | None          # None until clock is trustworthy
    temperature_c: float | None; humidity_pct: float | None; lux: float | None
    soil_raw: int | None; soil_pct: float | None
    clock_source: Literal["ntp", "backfilled", "unsynced"]
def parse_message(topic: str, payload: bytes) -> Telemetry          # raises InvalidMessage
def to_row(t: Telemetry, now: Stamp) -> ReadingRow

# clock.py
@dataclass(frozen=True)
class Stamp: wall: datetime | None; mono_ns: int; pi_boot_id: str; synced: bool
class Clock: def now() -> Stamp; def backfill(mono_ns: int, pi_boot_id: str) -> datetime | None

# buffer.py
class Outbox:
    def __init__(self, path: Path, max_rows: int = 100_000)
    def put(self, row: ReadingRow, stamp: Stamp) -> bool      # False if duplicate key already queued
    def ready(self, limit: int) -> list[tuple[int, ReadingRow]]  # only rows with recorded_at set
    def ack(self, ids: list[int]) -> None
    def dead_letter(self, ids: list[int], reason: str) -> None
    def resolve_unsynced(self, clock: Clock) -> int           # fill recorded_at after NTP sync
    def depth(self) -> int

# uploader.py
class SupabaseWriter:
    def __init__(self, url: str, secret_key: str, client: httpx.Client)
    def upsert_readings(self, rows) -> UploadResult   # ok | retryable | permanent(per-row reasons)
    def upsert_device(self, device_id, *, status=None, fw=None, last_seen_at=None) -> UploadResult
    def heartbeat(self, gateway_id, version, buffer_depth) -> UploadResult
```

### 5.4 Key behaviours
- **Validation:** the message must be a JSON object of at most 1 KiB, `device_id` must match the topic segment and the
  id regex, `boot_id` must be 8 hex characters, and `seq`/`uptime_ms` must be ≥ 0. Physical ranges: temperature
  −40…125 °C (SHT31), humidity 0…100, lux 0…120,000, soil_raw 0…4095 (12-bit ADC), soil_pct 0…100. Out-of-range
  fields become null and increment a counter. Invalid messages are logged with a rate limit (one log per device per
  minute plus a counter).
- **Time:** `synced` means `/run/systemd/timesync/synchronized` exists [6] and `wall` is later than the build date.
  While unsynced, a row is stored with `mono_ns` and the Pi's `/proc/sys/kernel/random/boot_id`, and
  `recorded_at = NULL`. Once synced, `resolve_unsynced` sets `recorded_at = wall_now − (mono_now − mono_ns)` for rows
  from the same Pi boot (`clock_source='backfilled'`). Rows from an earlier Pi boot that never synced are uploaded with
  the best-effort wall time and `clock_source='unsynced'`, and charts may hide them.
- **Outbox:** SQLite in WAL mode with `synchronous=FULL` and `busy_timeout=5000`, one connection per thread, at
  `/var/lib/olvar-gateway/outbox.db`. There is a unique index on `(device_id, boot_id, seq)`, so a QoS 1 duplicate is
  ignored locally. At `max_rows` the oldest rows are dropped with an ERROR log (100k rows is about 70 days of one
  device).
- **Uploader:** an event triggers it after each `put`, plus a 5 s tick. It sends `ready(500)` →
  `POST /rest/v1/readings?on_conflict=device_id,boot_id,seq` with
  `Prefer: resolution=ignore-duplicates,return=minimal` [19]. 2xx means ack. Network errors, 5xx and 429 mean back off
  exponentially with jitter (1 s → 5 min cap). For a 4xx (e.g. FK or check violation) it retries each row on its own
  to isolate the bad one; the bad row is dead-lettered and the rest are acked. Before a device's first reading it
  upserts the `devices` row (id, fw, last_seen_at) with merge-duplicates. Only payload columns are updated, so
  `owner_id` and `plant_id` are left alone.
- **MQTT:** client id `olvar-gateway`, MQTT 5, `clean_start=False`, session expiry 1 day, subscribed to
  `olvar/v1/+/telemetry` (QoS 1) and `olvar/v1/+/status` (QoS 1). Mosquitto then queues QoS 1 messages while the
  gateway restarts (default queue of 1,000 messages ≈ 16 h for one device). Status messages update
  `devices.status`, `status_changed_at` and `last_seen_at`.
- **Heartbeat:** every 5 min the gateway upserts `gateways(id, version, buffer_depth, last_seen_at)`. This shows "Pi
  offline" on the dashboard and keeps the Free project active (it pauses after 7 days of low activity [29]).
- **Logging:** JSON lines to stdout, which journald stores; a journald drop-in caps it at `SystemMaxUse=50M` [24]. There
  is no file logging.
- **Shutdown:** on SIGTERM it stops MQTT, flushes the uploader for up to 10 s and closes SQLite.

### 5.5 Mosquitto config (deploy/mosquitto)
```conf
# /etc/mosquitto/conf.d/olvar.conf   (persistence is already enabled in the Debian main file — don't repeat it)
listener 1883 0.0.0.0
allow_anonymous false
password_file /etc/mosquitto/passwd
acl_file /etc/mosquitto/acl
```
```conf
# /etc/mosquitto/acl
# every device: username == device_id, may only write its own topics (incl. its LWT)
pattern write olvar/v1/%u/telemetry
pattern write olvar/v1/%u/status
user olvar-gateway
topic read olvar/v1/+/telemetry
topic read olvar/v1/+/status
```
The files belong to `mosquitto:mosquitto` with mode 0600 [15]. A firewall (nftables) allows 1883 only from the LAN
subnet. The Pi is reached by a DHCP reservation and, as a fallback, mDNS `olvar-gw.local`.

### 5.6 Supabase schema (complete proposal: `20261116000100_core.sql` and the two following migrations)
```sql
-- ===== core =====
create table public.plant_profiles (
  id              text primary key,                 -- 'spathiphyllum'
  common_name     text not null,
  scientific_name text not null,
  thresholds      jsonb not null,                   -- {temperature_c:{critical_low,low,ok_low,ok_high,high,critical_high}, humidity_pct:{…}, lux:{…}, soil_pct:{…}}
  sources         text[] not null default '{}',
  updated_at      timestamptz not null default now()
);

create table public.plants (
  id                  uuid primary key default gen_random_uuid(),
  owner_id            uuid not null references auth.users(id) on delete cascade,
  profile_id          text not null references public.plant_profiles(id),
  nickname            text not null default 'Lily' check (char_length(nickname) between 1 and 40),
  timezone            text not null default 'UTC',  -- IANA, used for day/night + daily buckets
  locale              text not null default 'en',   -- avatar message language
  threshold_overrides jsonb not null default '{}',
  created_at          timestamptz not null default now()
);
create index plants_owner_idx on public.plants (owner_id);

create table public.devices (
  id                text primary key check (id ~ '^[a-z0-9][a-z0-9-]{2,31}$' and id <> 'olvar-gateway'),
  owner_id          uuid references auth.users(id) on delete set null,
  plant_id          uuid references public.plants(id) on delete set null,
  fw                text,
  status            text not null default 'unknown' check (status in ('online','offline','unknown')),
  status_changed_at timestamptz,
  last_seen_at      timestamptz,
  created_at        timestamptz not null default now()
);
create index devices_owner_idx on public.devices (owner_id);

create table public.readings (
  id            bigint generated always as identity primary key,
  device_id     text not null references public.devices(id) on delete cascade,
  recorded_at   timestamptz not null,
  received_at   timestamptz not null default now(),
  boot_id       text not null check (boot_id ~ '^[0-9a-f]{8}$'),
  seq           integer not null check (seq >= 0),
  uptime_ms     bigint not null check (uptime_ms >= 0),
  temperature_c real check (temperature_c between -40 and 125),
  humidity_pct  real check (humidity_pct between 0 and 100),
  lux           real check (lux between 0 and 120000),
  soil_raw      integer check (soil_raw between 0 and 4095),
  soil_pct      real check (soil_pct between 0 and 100),
  clock_source  text not null default 'ntp' check (clock_source in ('ntp','backfilled','unsynced')),
  constraint readings_dedup unique (device_id, boot_id, seq)
);
create index readings_device_time_idx on public.readings (device_id, recorded_at desc);
create index readings_received_idx    on public.readings (received_at);

create table public.gateways (
  id           text primary key,
  owner_id     uuid references auth.users(id) on delete set null,
  version      text,
  buffer_depth integer,
  last_seen_at timestamptz not null default now()
);

-- grants (explicit: required since the 2026 default-privileges change [11])
grant select                         on public.plant_profiles, public.devices, public.readings, public.gateways to authenticated;
grant select                         on public.plants to authenticated;
grant update (nickname, timezone, locale, threshold_overrides) on public.plants to authenticated;
grant select, insert, update, delete on public.plant_profiles, public.plants, public.devices, public.readings, public.gateways to service_role;
grant usage, select on all sequences in schema public to service_role;

-- RLS
alter table public.plant_profiles enable row level security;
alter table public.plants         enable row level security;
alter table public.devices        enable row level security;
alter table public.readings       enable row level security;
alter table public.gateways       enable row level security;

create policy profiles_read  on public.plant_profiles for select to authenticated using (true);
create policy plants_read    on public.plants  for select to authenticated using (owner_id = (select auth.uid()));
create policy plants_update  on public.plants  for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy devices_read   on public.devices for select to authenticated using (owner_id = (select auth.uid()));
create policy gateways_read  on public.gateways for select to authenticated using (owner_id = (select auth.uid()));
create policy readings_read  on public.readings for select to authenticated
  using (device_id in (select d.id from public.devices d where d.owner_id = (select auth.uid())));

alter publication supabase_realtime add table public.readings, public.devices;

-- ===== rollups (20261116000200_rollups.sql) =====
create extension if not exists pg_cron;

create table public.readings_hourly (
  device_id text not null references public.devices(id) on delete cascade,
  bucket    timestamptz not null,                   -- UTC hour start
  n         integer not null,
  temperature_c_avg real, temperature_c_min real, temperature_c_max real,
  humidity_pct_avg  real, humidity_pct_min  real, humidity_pct_max  real,
  lux_avg real, lux_min real, lux_max real,
  soil_pct_avg real, soil_pct_min real, soil_pct_max real,
  primary key (device_id, bucket)
);
-- readings_daily: identical columns to readings_hourly except `bucket date`
-- (= local calendar date in the plant's timezone, UTC if the device has no plant); primary key (device_id, bucket).

-- refresh_rollups(since): recompute every (device, hour) touched by rows RECEIVED since `since`,
-- so late rows flushed from the Pi buffer are folded in. Daily = weighted from hourly (sum(avg*n)/sum(n)).
create function public.refresh_rollups(since timestamptz) returns void
  language plpgsql security definer set search_path = '' as $$ … $$;
revoke execute on function public.refresh_rollups(timestamptz) from public, anon, authenticated;

select cron.schedule('olvar-rollups',   '5 * * * *',  $$select public.refresh_rollups(now() - interval '2 hours')$$);
select cron.schedule('olvar-retention', '30 3 * * *', $$delete from public.readings where recorded_at < now() - interval '90 days'$$);
-- grants + RLS on rollup tables mirror readings (select to authenticated via devices.owner_id; all to service_role)

-- ===== avatar (20261116000300_avatar.sql) =====
create extension if not exists pg_net;

create table public.avatar_states (
  id                  bigint generated always as identity primary key,
  plant_id            uuid not null references public.plants(id) on delete cascade,
  created_at          timestamptz not null default now(),
  based_on_reading_at timestamptz,
  mood       text not null check (mood in ('thriving','ok','needs_attention','in_trouble','offline')),
  expression text not null check (expression in ('happy','content','thirsty','soggy','cold','hot','gloomy','sunburnt','dry_air','sleepy','offline')),
  message    text not null check (char_length(message) between 1 and 280),
  advice     jsonb not null default '[]',   -- [{metric:'soil_pct'|'temperature_c'|'humidity_pct'|'lux', priority:'now'|'soon'|'fyi', text:string}] ≤3
  metric_status jsonb not null,              -- {"temperature_c":"ok","soil_pct":"low",…}  values: critical_low|low|ok|high|critical_high|unknown
  source     text not null check (source in ('llm','rules')),
  model      text,
  prompt_version  text not null,
  state_signature text not null,
  tokens_in  integer, tokens_out integer
);
create index avatar_states_plant_time_idx on public.avatar_states (plant_id, created_at desc);
grant select on public.avatar_states to authenticated;
grant select, insert on public.avatar_states to service_role;
alter table public.avatar_states enable row level security;
create policy avatar_read on public.avatar_states for select to authenticated
  using (plant_id in (select p.id from public.plants p where p.owner_id = (select auth.uid())));
alter publication supabase_realtime add table public.avatar_states;

-- cron → Edge Function; URL + key come from Vault (set by hand, never in migrations) [21]
select cron.schedule('olvar-avatar-tick', '*/15 * * * *', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/avatar-tick',
    headers := jsonb_build_object('Content-Type','application/json',
               'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'avatar_cron_key')),
    body := '{}'::jsonb, timeout_milliseconds := 30000) $$);
```

### 5.7 Avatar Edge Function `avatar-tick` (Deno/TypeScript)
1. Authenticate with `withSupabase({ auth: 'secret' })` and `verify_jwt = false` [33].
2. For each plant that has a device, load the last reading and 24 h of readings plus `readings_hourly`, then merge
   `plant_profiles.thresholds` with `threshold_overrides`.
3. Run **`rules.ts`** (pure functions, unit-tested):
   - Compute a status for each metric with the windows from §2.8. Light uses daytime only, in `plants.timezone`.
   - Detect a **watering event**: `soil_pct` rises by 15 or more within 30 min.
   - Staleness: no reading in the last 15 min means `offline`.
   - Mood priority is offline > any critical (`in_trouble`) > any low/high (`needs_attention`) > all ok
     (`thriving` if every metric is mid-range, otherwise `ok`).
   - Expression comes from the worst metric (soil low → `thirsty`, soil high → `soggy`, temperature low → `cold`,
     light high → `sunburnt`, light low → `gloomy`, humidity low → `dry_air`). It is `sleepy` at night when all is ok.
   - `state_signature` = hash(mood, expression, sorted metric_status).
4. If the signature is unchanged and the last `source='llm'` row is less than 3 h old, skip. If it is unchanged and
   younger than 3 h for a rules row, skip as well.
5. Otherwise call DeepSeek: `POST https://api.deepseek.com/chat/completions` with `model:"deepseek-flash"`,
   `thinking:{type:"disabled"}`, `response_format:{type:"json_object"}`, `max_tokens:400` and `temperature:0.8`
   (temperature is honoured only in non-thinking mode [41]). The timeout is 20 s. A blank or invalid JSON response is
   retried once [42], and after that it falls back to templates in `rules.ts` (`source='rules'`).
6. Validate the output with a schema (`message` ≤ 280 chars, ≤ 3 advice items whose `metric` must be in the
   problematic set). Insert an `avatar_states` row.

**Prompt (version `v1`)**. The system prompt is static so the prefix can be cached:
> You are {nickname}, a peace lily (Spathiphyllum) living in a pot. You speak in first person, warm and a little
> playful, in {locale}. You are given JSON with your sensor data, a per-metric status computed by rules, and the issues
> to address. Never contradict the given status, never invent measurements, never recommend chemicals or fertiliser
> doses. Output **json** only, exactly this shape: `{"message": "...", "advice": [{"metric": "...", "priority":
> "now|soon|fyi", "text": "..."}]}`. message: at most 2 sentences, ≤ 200 characters. advice: one item per given issue
> (max 3), each ≤ 100 characters, concrete (e.g., "Water until it drains, then empty the saucer."). If there are no
> issues, advice is []. Example: {…one full example…}

The user message is JSON: `{now_local, time_of_day, mood, expression, metrics:{temperature_c:{value, status,
min_24h, max_24h}, …}, issues:[…], last_watered_hours_ago, offline:false}`. `nickname` and `locale` are the only
per-plant values in the system prompt, so the cached prefix is stable for each plant.

---

## 6. Task breakdown (each task owns disjoint files; parallel workers)

Shared prerequisites: the interfaces in §5.3, the schema in §5.6 and the contract in §4 are fixed by this plan. Each
task adds its own tests and must pass `uv run pytest`, `supabase test db` and `deno test` as relevant.

| ID | Owner files | Depends on | Acceptance criteria | Verify (no hardware) |
|---|---|---|---|---|
| **T1 Supabase core schema** | `supabase/config.toml`, `supabase/migrations/20261116000100_core.sql`, `supabase/seed.sql`, `supabase/tests/core_rls_test.sql` | — | Tables, grants, RLS and publication exactly as in §5.6. The seed creates the spathiphyllum profile with §2.8 thresholds and sources, a local owner user, a plant, device `lily-01` and 48 h of synthetic readings. pgTAP proves: the owner sees their rows; a second user sees 0; anon gets `42501`/0 rows; service_role can insert; the dedup unique key rejects a duplicate | `supabase start && supabase db reset && supabase test db` |
| **T2 Rollups & retention** | `supabase/migrations/20261116000200_rollups.sql`, `supabase/tests/rollups_test.sql` | T1 DDL (fixed in plan) | `refresh_rollups` is idempotent. Late rows (old `recorded_at`, new `received_at`) update their old bucket. Daily values are weighted by `n` and bucketed in the plant's timezone. Retention deletes only rows older than 90 days. Cron jobs are registered | pgTAP with inserted fixtures; `select * from cron.job` |
| **T3 Avatar Edge Function** | `supabase/functions/avatar-tick/**`, `supabase/migrations/20261116000300_avatar.sql`, `supabase/tests/avatar_rls_test.sql` | T1 | `rules.ts` is a pure function with table-driven tests for every expression, night, offline and watering detection. A DeepSeek client with a `DEEPSEEK_BASE_URL` override; the stub covers success, blank content, invalid JSON, 429 and timeout, and every failure produces a `rules` row. The skip logic is tested. Thinking is disabled in the request body (asserted) | `deno test supabase/functions/avatar-tick`; `supabase functions serve --env-file supabase/functions/.env.local` + `curl -H "apikey: <local secret>"` against seeded data inserts a row |
| **T4 Payload contract & models** | `contracts/**`, `src/olvar_gateway/models.py`, `tests/test_models.py` | — | The JSON Schema and the pydantic model agree, checked by tests over every `contracts/examples/*` file. Topic/device_id mismatch is rejected, as are NaN, oversized payloads and a bad boot_id. Out-of-range fields become null. `to_row` maps correctly | `uv run pytest tests/test_models.py` |
| **T5 Clock, outbox, uploader** | `src/olvar_gateway/{clock,buffer,uploader}.py`, `tests/test_clock.py`, `tests/test_buffer.py`, `tests/test_uploader.py` | §5.3 interfaces | The outbox survives a process kill (killed in a subprocess, then reopened). Duplicate put is a no-op. The cap drops the oldest rows. Unsynced rows are held and then backfilled. The uploader handles 2xx, 5xx and network errors with backoff, isolates the bad row on a 4xx, and sends the `apikey` and `Prefer` headers and `on_conflict` exactly as in §5.4 | pytest with a fake clock and `httpx.MockTransport`; optional `-m supabase` test against `supabase start` |
| **T6 MQTT + service wiring** | `src/olvar_gateway/{mqtt_client,service,config,log,__main__}.py`, `pyproject.toml`, `uv.lock`, `requirements.txt`, `tests/test_service.py` | T4, T5 interfaces | Settings come from env, with a clear error naming any missing variable. Subscriptions use MQTT 5 with a persistent session. Status updates reach devices. The heartbeat runs every 5 min. SIGTERM flushes. Logs are JSON lines | pytest with fake writer/outbox; `python -m olvar_gateway --check-config` |
| **T7 Fake device + E2E** | `tools/fake_esp32.py`, `dev/compose.yml`, `tests/e2e/**` | T6 runnable | `fake_esp32.py --device lily-01 --interval 2 --speedup 60` simulates a day/night lux curve, soil drying and watering, a reboot (new boot_id, seq reset), QoS 1 duplicates, garbage payloads, a sensor null and an LWT on SIGKILL. E2E scenarios: (a) the happy path inserts N rows, (b) Supabase down for 2 min leaves no loss and no duplicates after recovery, (c) a gateway restart mid-stream loses nothing, (d) a spoofed device_id is rejected, (e) LWT sets devices.status=offline | `docker compose -f dev/compose.yml up -d && supabase start && uv run pytest -m e2e` |
| **T8 Pi deployment** | `deploy/**`, `tools/provision_device.py`, `docs/DEPLOY.md`, `docs/RUNBOOK.md` | T6 | `install.sh` is idempotent: apt `mosquitto mosquitto-clients python3-venv sqlite3`, user `olvar`, venv in `/opt/olvar-gateway`, `/etc/olvar-gateway/gateway.env` (0640 root:olvar), the unit with `StateDirectory=olvar-gateway` and sandboxing, the journald cap, the nftables rule for 1883. `update.sh` checks out a tag, installs pinned dependencies and restarts. `provision_device.py` adds the MQTT user and the devices row with owner and plant | Run in a Debian Trixie arm64 container or VM (`docker run --platform linux/arm64 debian:trixie`, with systemd checked by `systemd-analyze verify`); `shellcheck` |
| **T9 CI + types** | `.github/workflows/ci.yml`, `supabase/types/database.types.ts`, `README.md` | T1–T3 | CI jobs: ruff + pytest; `supabase start`, `db reset`, `test db`; `deno test`; type generation that fails the build if the committed types differ | GitHub Actions green on the PR |

Hardware is needed only for: the real ESP32 publish path (QoS 1 and the LWT through the real Wi-Fi stack), the real
NTP-less boot on the Pi (unplug WAN, reboot, check `clock_source='backfilled'`), and calibration of `soil_pct`.

---

## 7. Things the user must do by hand

1. **Supabase:** create an account and a Free project. Pick the region nearest you, choose a strong database password,
   and keep "Automatically expose new tables" **off**, which is the default now. Copy the project URL and the
   publishable key, and **create a named secret key `gateway`**, plus `avatar_cron` for pg_cron [10].
2. **Supabase CLI** on your dev machine, with **Docker Desktop or OrbStack** (allow about 7 GB of RAM) [36]. Then run
   `supabase login`, `supabase link --project-ref …`, `supabase db push`, `supabase functions deploy avatar-tick`.
3. **Vault secrets** in the SQL editor (never put these in git):
   `select vault.create_secret('https://<ref>.supabase.co','project_url'); select vault.create_secret('<sb_secret avatar_cron>','avatar_cron_key');` [21]
4. **Auth:** create your owner user in the Dashboard (Authentication → Users), **disable sign-ups**, then run
   `tools/provision_device.py` so your device and plant rows get your `owner_id`.
5. **DeepSeek:** create an account at platform.deepseek.com, **top up** (it is prepaid; $2 is plenty), create an API key,
   and run `supabase secrets set DEEPSEEK_API_KEY=…` [34][40].
6. **Raspberry Pi:** flash **Raspberry Pi OS Lite (64-bit)** with Raspberry Pi Imager. Set the hostname `olvar-gw`, your
   user, SSH and Wi-Fi or Ethernet (Ethernet is preferred). Give the Pi a **DHCP reservation** on your router. Use a
   good-brand SD card and a reliable PSU [24].
7. On the Pi: `git clone` the repo, then `sudo deploy/install.sh`, then fill in `/etc/olvar-gateway/gateway.env`
   (SUPABASE_URL, SUPABASE_SECRET_KEY=gateway key, MQTT password). Run
   `sudo mosquitto_passwd /etc/mosquitto/passwd lily-01`, which prompts for the ESP32's password, and the same for
   `olvar-gateway`.
8. **Firmware side:** put the broker host, port, username and password in the ESP32 config.
   **Calibrate the soil probe** in your actual pot: record the raw value when the plant "needs water" (top 2–3 cm dry)
   and again after a full watering has drained [56].
9. Place the BH1750 at leaf height facing the window, and keep the SHT31 out of direct sun and away from the pot's
   evaporating surface.

---

## 8. Risks and open questions

**Open questions for the user**
- **Q1** Should the dashboard require a login (the plan's default), or should anyone with the link see a read-only
  view?
- **Q2** What language should the avatar speak (`plants.locale`: Korean, English, …), and which timezone should be used
  for day/night and daily charts?
- **Q3** Is keeping raw 60 s data for 90 days OK? Hourly data is kept for about 2 years and daily data forever.
- **Q4** Is sending plant readings to DeepSeek (a China-based provider) acceptable? The data is low-sensitivity and has
  no personal identifiers apart from the plant nickname.
- **Q5** The soil thresholds (20/35/85/90%) are heuristics. Will you watch the plant for 1–2 weeks and adjust
  `threshold_overrides`? The dashboard could offer a "the plant is drooping now" button that records the dry point.
- **Q6** Is plaintext MQTT on your home LAN acceptable? TLS on 8883 is a documented later step.
- **Q7** Do you want off-site backups? The Free plan has none [29]. One option is a weekly `supabase db dump` from your
  laptop.

**Risks**
- **Free-project pause:** a project with no traffic for 7 days is paused [29]. The gateway's heartbeat prevents this
  while the Pi is online. If the Pi is off for over a week, you have to restore the project from the dashboard.
- **Pi clock:** with no RTC, a boot without internet gives wrong time [7]. This is mitigated by the backfill logic
  (§5.4). A €3 DS3231 RTC module would remove the risk.
- **SD-card corruption on power loss:** use a good card, `synchronous=FULL` for the outbox and capped journald [24][25].
  A small UPS HAT is optional.
- **Supabase platform changes:** legacy keys are being removed by the end of 2026 [8], and default grants are gone
  [11]. The plan uses only the new keys and explicit grants. A table without a grant fails loudly with `42501`.
- **DeepSeek:** thinking mode is on by default and would burn output tokens if it were not disabled [41]. JSON mode can
  return blank content [42], which is handled by retry and rules fallback. DeepSeek changes models and prices often
  (V4.1-Flash-1017 arrived on 17 Oct 2026 [38]), so the model id is configurable (`DEEPSEEK_MODEL`).
- **Firmware QoS:** if the firmware uses PubSubClient (QoS 0 only [26]), messages published while the gateway restarts
  are lost. That is about one reading per restart, which is acceptable but worth knowing.
- **Light semantics:** BH1750 measures illuminance in lux, which is weighted for the human eye, not PAR. The thresholds
  are approximate guidance from extension services that also use foot-candles [50][54].
- **Local Supabase from pg_cron:** inside the local Docker stack the Edge Function URL in Vault must point at the
  function from the DB container (e.g. `http://host.docker.internal:54321`). The T3 implementer must verify this.
