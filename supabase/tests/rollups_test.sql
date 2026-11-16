-- pgTAP: rollups & retention (T2). Self-contained fixtures inside one transaction, rolled back at the end.
-- now() is fixed for the whole transaction, so fixtures set received_at explicitly to land in (or outside) the
-- refresh window (processed_until - 10 min, now() - 2 min].
begin;
create extension if not exists pgtap with schema extensions;
create extension if not exists dblink with schema extensions;
select plan(69);

-- ---------------------------------------------------------------------------------------------------------------
-- Fixtures (as postgres)
-- ---------------------------------------------------------------------------------------------------------------
create temp table fx as
  select date_trunc('day', now() - interval '2 days', 'UTC') as t0;   -- a UTC midnight two days ago

insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000', '11111111-1111-4111-8111-111111111111', 'authenticated', 'authenticated', 'a@test.local'),
  ('00000000-0000-0000-0000-000000000000', '22222222-2222-4222-8222-222222222222', 'authenticated', 'authenticated', 'b@test.local');

insert into public.plants (id, owner_id, profile_id, timezone) values
  ('aaaaaaaa-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'spathiphyllum', 'UTC'),
  ('aaaaaaaa-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'spathiphyllum', 'Asia/Kolkata'),
  ('aaaaaaaa-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', 'spathiphyllum', 'UTC'),
  ('aaaaaaaa-0000-4000-8000-000000000004', '11111111-1111-4111-8111-111111111111', 'spathiphyllum', 'Pacific/Kiritimati'),
  ('aaaaaaaa-0000-4000-8000-000000000005', '11111111-1111-4111-8111-111111111111', 'spathiphyllum', 'Asia/Kolkata');

insert into public.devices (id, owner_id, plant_id, soil_dry_raw, soil_wet_raw) values
  ('rt-null', '11111111-1111-4111-8111-111111111111', 'aaaaaaaa-0000-4000-8000-000000000001', 3000, 1000),
  ('rt-kol',  '11111111-1111-4111-8111-111111111111', 'aaaaaaaa-0000-4000-8000-000000000002', null, null),
  ('rt-tz',   '11111111-1111-4111-8111-111111111111', 'aaaaaaaa-0000-4000-8000-000000000003', null, null),
  ('rt-tz2',  '11111111-1111-4111-8111-111111111111', 'aaaaaaaa-0000-4000-8000-000000000004', null, null),
  ('rt-ret',  '11111111-1111-4111-8111-111111111111', 'aaaaaaaa-0000-4000-8000-000000000005', null, null),
  ('rt-cu',   '11111111-1111-4111-8111-111111111111', null, null, null);

-- rt-null, hour A = t0+10h: 60 readings, only the first has a temperature (20), soil raw half 0 / half 3000.
--          hour B = t0+11h: 60 readings at 30 °C, soil null.
insert into public.readings (device_id, recorded_at, received_at, boot_id, seq, uptime_ms, temperature_c, humidity_pct, soil_raw)
select 'rt-null', fx.t0 + interval '10 hours' + i * interval '1 minute', now() - interval '1 hour', 'aaaa0001', i, i * 60000,
       case when i = 0 then 20 end, 50, case when i < 30 then 0 else 3000 end
from fx, generate_series(0, 59) i;
insert into public.readings (device_id, recorded_at, received_at, boot_id, seq, uptime_ms, temperature_c, lux)
select 'rt-null', fx.t0 + interval '11 hours' + i * interval '1 minute', now() - interval '1 hour', 'aaaa0001', 60 + i, (60 + i) * 60000,
       30, 100
from fx, generate_series(0, 59) i;

-- rt-kol (Asia/Kolkata, +05:30): 18:29Z is 23:59 local on t0's date, 18:31Z is 00:01 local on the next date
insert into public.readings (device_id, recorded_at, received_at, boot_id, seq, uptime_ms, temperature_c)
select 'rt-kol', fx.t0 + interval '18 hours 29 minutes', now() - interval '1 hour', 'bbbb0001', 0, 0, 10 from fx
union all
select 'rt-kol', fx.t0 + interval '18 hours 31 minutes', now() - interval '1 hour', 'bbbb0001', 1, 120000, 20 from fx;

-- rt-cu: one reading per hour for the last 71 hours, each received 30 s after it was recorded; plus one reading
-- received 4 days ago, before the watermark (must not be picked up).
insert into public.readings (device_id, recorded_at, received_at, boot_id, seq, uptime_ms, temperature_c)
select 'rt-cu', date_trunc('hour', now(), 'UTC') - k * interval '1 hour',
       date_trunc('hour', now(), 'UTC') - k * interval '1 hour' + interval '30 seconds', 'cccc0001', k, k, 21
from generate_series(1, 71) k;
insert into public.readings (device_id, recorded_at, received_at, boot_id, seq, uptime_ms, temperature_c)
values ('rt-cu', now() - interval '4 days', now() - interval '4 days', 'cccc0002', 0, 0, 21);

-- rt-tz (UTC → Asia/Seoul) and rt-tz2 (+14 → -12): every 6 h, fixed August dates
insert into public.readings (device_id, recorded_at, received_at, boot_id, seq, uptime_ms, temperature_c)
select d, '2026-08-15 00:00Z'::timestamptz + k * interval '6 hours', now() - interval '1 hour', 'dddd0001', k, k, 20 + k % 4
from unnest(array['rt-tz', 'rt-tz2']) d, generate_series(0, 23) k;

-- ---------------------------------------------------------------------------------------------------------------
-- Structure
-- ---------------------------------------------------------------------------------------------------------------
select ok((select bool_and(relrowsecurity) from pg_class
           where oid in ('public.readings_hourly'::regclass, 'public.readings_daily'::regclass,
                         'public.rollup_state'::regclass, 'public.rollup_seals'::regclass)),
          'RLS is enabled on every rollup table');
select ok((select bool_and('security_invoker=true' = any (reloptions)) from pg_class
           where oid in ('public.readings_hourly_v'::regclass, 'public.readings_daily_v'::regclass)),
          'rollup views are security_invoker');
select results_eq($$select jobname, schedule, command from cron.job
                    where jobname in ('olvar-rollups', 'olvar-retention') order by jobname$$,
                  $$values ('olvar-retention'::text, '30 3 * * *'::text, 'select public.apply_retention()'::text),
                           ('olvar-rollups', '5 * * * *', 'select public.refresh_rollups()')$$,
                  'cron jobs are registered');

-- ---------------------------------------------------------------------------------------------------------------
-- Catch-up: the watermark is 3 days back; one run fills every missed bucket
-- ---------------------------------------------------------------------------------------------------------------
update public.rollup_state set processed_until = now() - interval '3 days';
select lives_ok($$select public.refresh_rollups()$$, 'refresh_rollups runs');

select is((select processed_until from public.rollup_state), now() - interval '2 minutes',
          'watermark advances to now() - 2 min');
select is((select count(*)::int from public.readings_hourly where device_id = 'rt-cu'
           and bucket >= now() - interval '3 days'), 71, 'catch-up: every missed hourly bucket is filled');
select is((select count(*)::int from public.readings_hourly where device_id = 'rt-cu'
           and bucket < now() - interval '3 days'), 0, 'rows received before the watermark are not reprocessed');
select is((select sum(n)::int from public.readings_daily where device_id = 'rt-cu'), 71,
          'catch-up: daily rows cover every missed reading');

-- ---------------------------------------------------------------------------------------------------------------
-- Null sensors: per-metric _n, exact daily mean
-- ---------------------------------------------------------------------------------------------------------------
select results_eq($$select n, temperature_c_n, temperature_c_avg, humidity_pct_n, lux_n, soil_raw_n
                    from public.readings_hourly h, fx where device_id = 'rt-null' and bucket = fx.t0 + interval '10 hours'$$,
                  $$values (60, 1, 20::real, 60, 0, 60)$$, 'hour A: n=60 but temperature_c_n=1');
select results_eq($$select n, temperature_c_n, temperature_c_avg, humidity_pct_n, lux_n, soil_raw_n
                    from public.readings_hourly h, fx where device_id = 'rt-null' and bucket = fx.t0 + interval '11 hours'$$,
                  $$values (60, 60, 30::real, 0, 60, 0)$$, 'hour B: per-metric counts');
select results_eq($$select n, temperature_c_n, round(temperature_c_avg::numeric, 2), temperature_c_min, temperature_c_max
                    from public.readings_daily, fx where device_id = 'rt-null' and bucket = fx.t0::date$$,
                  $$values (120, 61, 29.84, 20::real, 30::real)$$,
                  'daily mean is weighted by temperature_c_n: (20 + 60*30) / 61 = 29.84');
select is((select lux_avg from public.readings_hourly h, fx where device_id = 'rt-null' and bucket = fx.t0 + interval '10 hours'),
          null, 'a metric with no samples has a null average');

-- ---------------------------------------------------------------------------------------------------------------
-- Soil: distribution, inverted min/max, clamping, recalibration
-- ---------------------------------------------------------------------------------------------------------------
select results_eq($$select soil_raw_values, soil_raw_counts, soil_raw_min, soil_raw_max
                    from public.readings_hourly h, fx where device_id = 'rt-null' and bucket = fx.t0 + interval '10 hours'$$,
                  $$values ('{0,3000}'::smallint[], '{30,30}'::integer[], 0::smallint, 3000::smallint)$$,
                  'soil_raw distribution is stored as value -> count');
select results_eq($$select soil_pct_avg, soil_pct_min, soil_pct_max
                    from public.readings_hourly_v h, fx where device_id = 'rt-null' and bucket = fx.t0 + interval '10 hours'$$,
                  $$values (50::real, 0::real, 100::real)$$,
                  'dry=3000 wet=1000, raw {0,3000}: soil_pct_avg 50 %, min from raw max (0 %), max from raw min (100 %)');
select is((select round(soil_pct_avg::numeric, 3) from public.readings_hourly_v h, fx
           where device_id = 'rt-null' and bucket = fx.t0 + interval '10 hours'),
          (select round(avg(soil_pct)::numeric, 3) from public.readings_v, fx
           where device_id = 'rt-null' and recorded_at >= fx.t0 + interval '10 hours' and recorded_at < fx.t0 + interval '11 hours'),
          'hourly soil_pct_avg equals the mean of readings_v.soil_pct');
select is((select soil_pct_avg from public.readings_daily_v, fx where device_id = 'rt-null' and bucket = fx.t0::date),
          50::real, 'daily view computes soil_pct_avg the same way');

update public.devices set soil_dry_raw = 3500, soil_wet_raw = 1500 where id = 'rt-null';
select is((select round(soil_pct_avg::numeric, 3) from public.readings_hourly_v h, fx
           where device_id = 'rt-null' and bucket = fx.t0 + interval '10 hours'),
          (select round(avg(soil_pct)::numeric, 3) from public.readings_v, fx
           where device_id = 'rt-null' and recorded_at >= fx.t0 + interval '10 hours' and recorded_at < fx.t0 + interval '11 hours'),
          'after a recalibration the view still equals the mean of readings_v.soil_pct');
select is((select soil_pct_avg from public.readings_hourly_v h, fx
           where device_id = 'rt-null' and bucket = fx.t0 + interval '10 hours'),
          62.5::real, 'recalibrated (dry=3500 wet=1500): per-sample clamping gives (100 + 25) / 2');
select isnt((select public.soil_pct(soil_raw_avg::numeric, 3500, 1500) from public.readings_hourly h, fx
             where device_id = 'rt-null' and bucket = fx.t0 + interval '10 hours'),
            62.5::real, 'soil_pct(soil_raw_avg) would be wrong, which is why the views use the distribution');
select is((select soil_pct_avg from public.readings_hourly_v where device_id = 'rt-kol' limit 1), null,
          'soil_pct_avg is null for an uncalibrated device');

-- ---------------------------------------------------------------------------------------------------------------
-- Local dates: +05:30
-- ---------------------------------------------------------------------------------------------------------------
select results_eq($$select bucket - fx.t0::date, n, temperature_c_avg from public.readings_daily, fx
                    where device_id = 'rt-kol' order by bucket$$,
                  $$values (0, 1, 10::real), (1, 1, 20::real)$$,
                  'Asia/Kolkata: 18:29Z and 18:31Z fall on different local dates');
select is((select count(*)::int from public.readings_hourly h, fx where device_id = 'rt-kol' and bucket = fx.t0 + interval '18 hours'),
          1, 'both readings share one UTC hourly bucket');

-- ---------------------------------------------------------------------------------------------------------------
-- Idempotency and late rows
-- ---------------------------------------------------------------------------------------------------------------
create temp table snap_h as select * from public.readings_hourly;
create temp table snap_d as select * from public.readings_daily;
select lives_ok($$select public.refresh_rollups()$$, 'second run');
select is_empty($$(select * from public.readings_hourly except select * from snap_h)
                  union all (select * from snap_h except select * from public.readings_hourly)$$,
                'refresh_rollups is idempotent (hourly)');
select is_empty($$(select * from public.readings_daily except select * from snap_d)
                  union all (select * from snap_d except select * from public.readings_daily)$$,
                'refresh_rollups is idempotent (daily)');

-- a reading recorded two days ago arrives now (received inside the next window)
update public.rollup_state set processed_until = now() - interval '30 minutes';
insert into public.readings (device_id, recorded_at, received_at, boot_id, seq, uptime_ms, temperature_c)
select 'rt-null', fx.t0 + interval '11 hours 30 minutes 30 seconds', now() - interval '10 minutes', 'aaaa0002', 0, 0, 91
from fx;
select lives_ok($$select public.refresh_rollups()$$, 'run after a late row');
select results_eq($$select n, temperature_c_n, temperature_c_max from public.readings_hourly h, fx
                    where device_id = 'rt-null' and bucket = fx.t0 + interval '11 hours'$$,
                  $$values (61, 61, 91::real)$$, 'a late row updates its old hourly bucket');
select results_eq($$select n, temperature_c_n from public.readings_daily, fx where device_id = 'rt-null' and bucket = fx.t0::date$$,
                  $$values (121, 62)$$, 'a late row updates its old daily bucket');

-- ---------------------------------------------------------------------------------------------------------------
-- Concurrency: while this session holds the rollup lock, a second session's refresh_rollups() exits immediately
-- ---------------------------------------------------------------------------------------------------------------
select pg_advisory_xact_lock(727001);
-- dblink needs password auth (loopback is trust in the local stack), so connect back via the server's own address
select extensions.dblink_connect('other', format('host=%s port=%s dbname=%s user=postgres password=postgres',
  coalesce(host(inet_server_addr()), 'localhost'), coalesce(inet_server_port(), 5432), current_database()));
select extensions.dblink_exec('other', 'begin');
create temp table other_before as
  select * from extensions.dblink('other', 'select processed_until from public.rollup_state') as t(p timestamptz);
select lives_ok($$select * from extensions.dblink('other', 'select public.refresh_rollups()::text') as t(x text)$$,
                'a concurrent refresh_rollups() returns without waiting');
select is((select p from extensions.dblink('other', 'select processed_until from public.rollup_state') as t(p timestamptz)),
          (select p from other_before), 'the concurrent run exits on the advisory lock without advancing the watermark');
select extensions.dblink_exec('other', 'rollback');
select extensions.dblink_disconnect('other');

-- ---------------------------------------------------------------------------------------------------------------
-- Timezone change after a seal: UTC → Asia/Seoul with sealed_before = 2026-08-18 00:00Z
-- (the seal is set up by hand here, exactly as apply_retention() would leave it for that cut)
-- ---------------------------------------------------------------------------------------------------------------
insert into public.rollup_seals (device_id, sealed_before) values ('rt-tz', '2026-08-18 00:00Z');
update public.readings_hourly set sealed = true where device_id = 'rt-tz' and bucket < '2026-08-18 00:00Z';
update public.readings_daily set sealed = true where device_id = 'rt-tz' and bucket < '2026-08-18';
delete from public.readings where device_id = 'rt-tz' and recorded_at < '2026-08-18 00:00Z';
create temp table tz_sealed as select * from public.readings_daily where device_id = 'rt-tz' and sealed;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);
select lives_ok($$update public.plants set timezone = 'Asia/Seoul' where id = 'aaaaaaaa-0000-4000-8000-000000000003'$$,
                'the owner can switch UTC → Asia/Seoul after a seal');
reset role;

select set_eq($$select * from public.readings_daily where device_id = 'rt-tz' and sealed$$,
              $$select * from tz_sealed$$, 'sealed UTC days (incl. 2026-08-17) are unchanged');
select is((select count(*)::int from public.readings_daily where device_id = 'rt-tz' and bucket = '2026-08-18'), 0,
          'no 2026-08-18 row is written (KST 08-18 starts before the seal)');
select results_eq($$select bucket, n, sealed from public.readings_daily where device_id = 'rt-tz' and not sealed order by bucket$$,
                  $$values ('2026-08-19'::date, 4, false), ('2026-08-20', 4, false), ('2026-08-21', 1, false)$$,
                  'daily rows are rebuilt in KST from 2026-08-19 on');

-- +14:00 → -12:00: sealed +14 days would collide with the first -12 dates after the seal
insert into public.rollup_seals (device_id, sealed_before)
  values ('rt-tz2', date_trunc('hour', '2026-08-18'::timestamp at time zone 'Pacific/Kiritimati', 'UTC'));
update public.readings_hourly set sealed = true where device_id = 'rt-tz2' and bucket < '2026-08-17 10:00Z';
update public.readings_daily set sealed = true where device_id = 'rt-tz2'
  and (bucket::timestamp at time zone 'Pacific/Kiritimati') < '2026-08-17 10:00Z';
delete from public.readings where device_id = 'rt-tz2' and recorded_at < '2026-08-17 10:00Z';
create temp table tz2_sealed as select * from public.readings_daily where device_id = 'rt-tz2' and sealed;
select lives_ok($$update public.plants set timezone = 'Etc/GMT+12' where id = 'aaaaaaaa-0000-4000-8000-000000000004'$$,
                'a switch from +14:00 to -12:00 succeeds');
select set_eq($$select * from public.readings_daily where device_id = 'rt-tz2' and sealed$$,
              $$select * from tz2_sealed$$, '+14 → -12: sealed rows are unchanged');
select ok((select min(bucket) from public.readings_daily where device_id = 'rt-tz2' and not sealed)
          > (select max(bucket) from tz2_sealed), '+14 → -12: rebuilt rows start after the last sealed date');

-- ---------------------------------------------------------------------------------------------------------------
-- Retention + late arrival (rt-ret, Asia/Kolkata +05:30)
-- local day D = local today - 91 straddles the cut: cut = floor_hour(local midnight of D+1) = midnight - 30 min.
-- Temperatures {10 before the cut, 30 after the cut but still on D}. Both are received just now, so the regular
-- watermark (now() - 2 min) has NOT summarised them: retention must still include them before sealing/deleting.
-- ---------------------------------------------------------------------------------------------------------------
create temp table rx as
  select m - interval '30 minutes' as cut, m as midnight, (m at time zone 'Asia/Kolkata')::date - 1 as d
  from (select ((now() at time zone 'Asia/Kolkata')::date - 90)::timestamp at time zone 'Asia/Kolkata' as m) s;
insert into public.readings (device_id, recorded_at, boot_id, seq, uptime_ms, temperature_c)   -- received_at = now()
select 'rt-ret', rx.midnight - interval '5 hours', 'eeee0001', 0, 0, 10 from rx
union all
select 'rt-ret', rx.cut + interval '10 minutes', 'eeee0001', 1, 1, 30 from rx;

select lives_ok($$select public.apply_retention()$$, 'apply_retention runs');
select is((select sealed_before from public.rollup_seals where device_id = 'rt-ret'), (select cut from rx),
          '+05:30: sealed_before = local midnight of (today - 90) floored to the UTC hour');
select is((select extract(minute from sealed_before)::int + extract(second from sealed_before)::int
           from public.rollup_seals where device_id = 'rt-ret'), 0, 'sealed_before is hour-aligned');
select results_eq($$select n, temperature_c_avg, sealed from public.readings_daily, rx where device_id = 'rt-ret' and bucket = rx.d$$,
                  $$values (2, 20::real, true)$$,
                  'recently received rows were summarised before the straddling day was sealed (mean 20)');
select results_eq($$select n, temperature_c_avg, sealed from public.readings_hourly, rx
                    where device_id = 'rt-ret' and bucket = date_trunc('hour', rx.midnight - interval '5 hours', 'UTC')$$,
                  $$values (1, 10::real, true)$$, 'the deleted reading''s hourly bucket was summarised and sealed');
select results_eq($$select temperature_c from public.readings where device_id = 'rt-ret' order by recorded_at$$,
                  $$values (30::real)$$, 'raw rows before sealed_before are deleted; the one after the cut stays');
select is((select count(*)::int from public.readings where recorded_at < (select min(sealed_before) from public.rollup_seals)
           and device_id in (select device_id from public.rollup_seals)), 0, 'no device keeps raw rows before its seal');
select is((select count(*)::int from public.readings_hourly h join public.rollup_seals s using (device_id)
           where h.bucket < s.sealed_before and not h.sealed), 0, 'every hourly bucket before the seal is sealed');

-- late arrival into the sealed day (before the cut), received inside the next refresh window
update public.rollup_state set processed_until = now() - interval '20 minutes';
insert into public.readings (device_id, recorded_at, received_at, boot_id, seq, uptime_ms, temperature_c)
select 'rt-ret', rx.midnight - interval '4 hours', now() - interval '5 minutes', 'eeee0002', 0, 0, 30 from rx;
select lives_ok($$select public.refresh_rollups()$$, 'refresh after a late arrival into a sealed day');
select results_eq($$select n, temperature_c_avg from public.readings_daily, rx where device_id = 'rt-ret' and bucket = rx.d$$,
                  $$values (2, 20::real)$$, 'the sealed daily mean stays 20');
select is((select late_rows_ignored from public.rollup_seals where device_id = 'rt-ret'), 1::bigint,
          'the late row is counted in late_rows_ignored');
select is((select count(*)::int from public.readings_hourly h, rx where device_id = 'rt-ret'
           and bucket = date_trunc('hour', rx.midnight - interval '4 hours', 'UTC')), 0,
          'no hourly bucket is created before the seal');

select lives_ok($$select public.apply_retention()$$, 'next retention run');
select is((select count(*)::int from public.readings where device_id = 'rt-ret' and seq = 0 and boot_id = 'eeee0002'), 0,
          'the next retention run deletes the late row');
select is((select late_rows_ignored from public.rollup_seals where device_id = 'rt-ret'), 1::bigint,
          'the late row is not counted twice');
select results_eq($$select n, temperature_c_avg, sealed from public.readings_daily, rx where device_id = 'rt-ret' and bucket = rx.d$$,
                  $$values (2, 20::real, true)$$, 'the sealed day is still 20 after the next retention run');

-- rebuild_rollups skips sealed buckets without raising, and recomputes the unsealed ones
update public.readings_hourly set n = 999 where device_id = 'rt-ret' and bucket = (select cut from rx);
select lives_ok($$select public.rebuild_rollups('rt-ret', (select cut from rx) - interval '2 days', (select cut from rx) + interval '2 hours')$$,
                'rebuild_rollups over a range crossing the seal does not raise');
select is((select n from public.readings_hourly, rx where device_id = 'rt-ret' and bucket = rx.cut), 1,
          'rebuild_rollups recomputes the unsealed bucket at the cut');
select results_eq($$select n, temperature_c_avg, sealed from public.readings_daily, rx where device_id = 'rt-ret' and bucket = rx.d$$,
                  $$values (2, 20::real, true)$$, 'rebuild_rollups leaves the sealed day alone');

-- sealed_before never moves backwards
update public.rollup_seals set sealed_before = sealed_before + interval '1 day' where device_id = 'rt-ret';
select lives_ok($$select public.apply_retention()$$, 'retention with a seal ahead of the cut');
select is((select sealed_before from public.rollup_seals where device_id = 'rt-ret'), (select cut from rx) + interval '1 day',
          'sealed_before never moves backwards');

-- ---------------------------------------------------------------------------------------------------------------
-- Grants and RLS
-- ---------------------------------------------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);
select ok((select count(*) from public.readings_hourly_v where device_id = 'rt-null') > 0, 'owner reads hourly rollups');
select ok((select count(*) from public.readings_daily_v where device_id = 'rt-null') > 0, 'owner reads daily rollups');
select throws_ok($$select public.refresh_rollups()$$, '42501', null, 'authenticated cannot run refresh_rollups');
select throws_ok($$select public.apply_retention()$$, '42501', null, 'authenticated cannot run apply_retention');
select throws_ok($$select public.rebuild_rollups('rt-null', now() - interval '1 day', now())$$, '42501', null,
                 'authenticated cannot run rebuild_rollups');
select throws_ok($$select * from public.rollup_seals$$, '42501', null, 'authenticated cannot read rollup_seals');
select throws_ok($$delete from public.readings_hourly$$, '42501', null, 'authenticated cannot write rollups');

select set_config('request.jwt.claims', '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}', true);
select is((select count(*)::int from public.readings_hourly_v where device_id like 'rt-%'), 0, 'other user sees no hourly rows');
select is((select count(*)::int from public.readings_daily where device_id like 'rt-%'), 0, 'other user sees no daily rows');
reset role;

set local role anon;
select throws_ok($$select * from public.readings_hourly_v$$, '42501', null, 'anon cannot read rollup views');
select throws_ok($$select * from public.readings_daily$$, '42501', null, 'anon cannot read rollup tables');
reset role;

select * from finish();
rollback;
