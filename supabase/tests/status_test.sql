-- pgTAP: status view + offline periods (T3). Self-contained fixtures inside one transaction, rolled back at the end.
-- now() is fixed for the whole transaction, so every fixture is placed relative to it.
begin;
create extension if not exists pgtap with schema extensions;
set local timezone = 'UTC';
select plan(68);

-- ---------------------------------------------------------------------------------------------------------------
-- Fixtures (as postgres): owner A with one plant per status scenario, owner B with one plant.
-- ---------------------------------------------------------------------------------------------------------------
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000', '11111111-1111-4111-8111-111111111111', 'authenticated', 'authenticated', 'a@test.local'),
  ('00000000-0000-0000-0000-000000000000', '22222222-2222-4222-8222-222222222222', 'authenticated', 'authenticated', 'b@test.local');

-- One row per scenario. Readings every 5 min for the last 49 h, the newest at now() - shift. Lux is day_lux during
-- 08–18 UTC and night_lux otherwise. Calibration dry=3000 / wet=1000, so soil_raw 1800 = 60 %, 2400 = 30 %, 1100 = 95 %.
create temp table fx (name text, tz text, has_device bool, has_readings bool, dev_status text, calibrated bool,
                      shift interval, temp real, hum real, day_lux real, night_lux real, soil smallint, overrides jsonb);
insert into fx values
  ('great',        'UTC',               true,  true,  'online',  true,  '0s',   23, 55, 3000, 0, 1800, '{}'),
  ('okay',         'UTC',               true,  true,  'online',  true,  '0s',   28, 55, 3000, 0, 1800, '{}'),
  ('uncal',        'UTC',               true,  true,  'online',  false, '0s',   23, 55, 3000, 0, 1800, '{}'),
  ('soil-low',     'UTC',               true,  true,  'online',  true,  '0s',   23, 55, 3000, 0, 2400, '{}'),
  ('cold',         'UTC',               true,  true,  'online',  true,  '0s',    8, 55, 3000, 0, 2400, '{}'),
  ('dark-tz',      'Pacific/Kiritimati', true, true,  'online',  true,  '0s',   23, 55, 3000, 0, 1800, '{}'),
  ('dim',          'UTC',               true,  true,  'online',  true,  '0s',   23, 55,  500, 0, 1800, '{}'),
  ('sun',          'UTC',               true,  true,  'online',  true,  '0s',   23, 55, 3000, 0, 1800, '{}'),
  ('humid-12h',    'UTC',               true,  true,  'online',  true,  '0s',   23, 90, 3000, 0, 1800, '{}'),
  ('humid-short',  'UTC',               true,  true,  'online',  true,  '0s',   23, 55, 3000, 0, 1800, '{}'),
  ('soggy',        'UTC',               true,  true,  'online',  true,  '0s',   23, 55, 3000, 0, 1100, '{}'),
  ('soggy-short',  'UTC',               true,  true,  'online',  true,  '0s',   23, 55, 3000, 0, 1800, '{}'),
  ('override',     'UTC',               true,  true,  'online',  true,  '0s',   23, 55, 3000, 0, 1800,
                   '{"temperature_c": {"low": 24, "ok_low": 24}}'),
  ('offline-old',  'UTC',               true,  true,  'online',  true,  '181s', 23, 55, 3000, 0, 1800, '{}'),
  ('fresh-180',    'UTC',               true,  true,  'online',  true,  '180s', 23, 55, 3000, 0, 1800, '{}'),
  ('lwt',          'UTC',               true,  true,  'offline', true,  '0s',   23, 55, 3000, 0, 1800, '{}'),
  ('nodata',       'UTC',               true,  false, 'unknown', true,  '0s',   null, null, null, null, null, '{}'),
  ('nodev',        'UTC',               false, false, null,      false, '0s',   null, null, null, null, null, '{}'),
  -- readings for these are inserted by hand below
  ('hum-sparse',   'UTC',               true,  false, 'online',  true,  '0s',   null, null, null, null, null, '{}'),
  ('soil-sparse',  'UTC',               true,  false, 'online',  true,  '0s',   null, null, null, null, null, '{}'),
  ('future',       'UTC',               true,  false, 'online',  true,  '0s',   null, null, null, null, null, '{}'),
  ('hum-crit',     'UTC',               true,  false, 'online',  true,  '0s',   null, null, null, null, null,
                   '{"humidity_pct": {"critical_high": 95}}'),
  ('soil-crit',    'UTC',               true,  false, 'online',  true,  '0s',   null, null, null, null, null,
                   '{"soil_pct": {"critical_high": 99}}');

insert into public.plants (owner_id, profile_id, nickname, timezone, threshold_overrides)
select '11111111-1111-4111-8111-111111111111', 'spathiphyllum', f.name, f.tz, f.overrides from fx f;

insert into public.devices (id, owner_id, plant_id, status, soil_dry_raw, soil_wet_raw)
select 'st-' || f.name, '11111111-1111-4111-8111-111111111111', p.id, f.dev_status,
       case when f.calibrated then 3000 end, case when f.calibrated then 1000 end
from fx f join public.plants p on p.nickname = f.name
where f.has_device;

insert into public.readings (device_id, recorded_at, boot_id, seq, uptime_ms, temperature_c, humidity_pct, lux, soil_raw)
select 'st-' || f.name, t.ts, 'cafe0001', 588 - g.k, (588 - g.k) * 300000::bigint, f.temp, f.hum,
       case when extract(hour from t.ts at time zone 'UTC') between 8 and 17 then f.day_lux else f.night_lux end, f.soil
from fx f
cross join generate_series(0, 588) as g(k)
cross join lateral (select now() - f.shift - g.k * interval '5 minutes' as ts) t
where f.has_readings;

-- humid-short: very humid only for the last 6 h (not sustained for 12 h)
update public.readings set humidity_pct = 90 where device_id = 'st-humid-short' and recorded_at > now() - interval '6 hours';
-- soggy-short: soggy only for the last 24 h (not sustained for 48 h)
update public.readings set soil_raw = 1100 where device_id = 'st-soggy-short' and recorded_at > now() - interval '24 hours';
-- sun: one 10-min bucket 3 h ago at 12,000 lx (above high, below critical_high)
update public.readings set lux = 12000
where device_id = 'st-sun'
  and date_bin('10 minutes', recorded_at, timestamptz '2000-01-01 00:00Z')
    = date_bin('10 minutes', now() - interval '3 hours', timestamptz '2000-01-01 00:00Z');
-- offline-old: a fresh but unsynced reading does not count as a reading
insert into public.readings (device_id, recorded_at, boot_id, seq, uptime_ms, clock_source)
values ('st-offline-old', now(), 'cafe0002', 0, 0, 'unsynced');

-- sparse: only two very-high samples at the edges of the 12 h / 48 h window (an outage in between) are no evidence
-- of a sustained high; future: a reading timestamped tomorrow must not hide that the newest real one is 5 min old;
-- *-crit: critical_high exists only through overrides and has no persistence rule
insert into public.readings (device_id, recorded_at, boot_id, seq, uptime_ms, temperature_c, humidity_pct, soil_raw) values
  ('st-hum-sparse',  now() - interval '11 hours 55 minutes', 'cafe0001', 0, 0, 23, 90, 1800),
  ('st-hum-sparse',  now(),                                  'cafe0001', 1, 1, 23, 90, 1800),
  ('st-soil-sparse', now() - interval '47 hours 55 minutes', 'cafe0001', 0, 0, 23, 55, 1100),
  ('st-soil-sparse', now(),                                  'cafe0001', 1, 1, 23, 55, 1100),
  ('st-future',      now() - interval '5 minutes',           'cafe0001', 0, 0, 23, 55, 1800),
  ('st-future',      now() + interval '1 day',               'cafe0001', 1, 1, 23, 55, 1800),
  ('st-hum-crit',    now(),                                  'cafe0001', 0, 0, 23, 96, 1800),
  ('st-soil-crit',   now(),                                  'cafe0001', 0, 0, 23, 55, 1000);

-- owner B
insert into public.plants (id, owner_id, profile_id, nickname)
values ('bbbbbbbb-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222', 'spathiphyllum', 'b-plant');
insert into public.devices (id, owner_id, plant_id, status)
values ('st-b', '22222222-2222-4222-8222-222222222222', 'bbbbbbbb-0000-4000-8000-000000000001', 'online');
insert into public.readings (device_id, recorded_at, boot_id, seq, uptime_ms, temperature_c)
values ('st-b', now(), 'bbbb0001', 0, 0, 23);

-- ---------------------------------------------------------------------------------------------------------------
-- Offline-period fixtures: device gaps-a (owner A, no plant). M = yesterday 00:00 UTC.
--   boot b1: every 60 s from M-3h to M-10m, minus M-2h30m..M-2h29m (a 180 s gap: not offline) and
--            M-2h20m..M-2h18m (a 240 s gap → offline M-2h20m..M-2h17m);
--   boot b1: every 60 s from M+20m to M+2h (gap across midnight: M-9m..M+20m);
--   boot b2: every 60 s from M+2h10m to now-30m (restart gap M+2h1m..M+2h10m), then nothing (ongoing gap).
-- ---------------------------------------------------------------------------------------------------------------
create temp table m as select date_trunc('day', now()) - interval '1 day' as m;

insert into public.devices (id, owner_id, status) values ('gaps-a', '11111111-1111-4111-8111-111111111111', 'online'),
  ('gaps-b', '11111111-1111-4111-8111-111111111111', 'online');
-- gaps-b: silent for the last 7 min (an ongoing outage)
insert into public.readings (device_id, recorded_at, boot_id, seq, uptime_ms)
values ('gaps-b', now() - interval '7 minutes', 'b3b3b3b3', 0, 0);
-- gaps-future: silent for 10 min, plus a reading wrongly dated tomorrow that must not close the outage
insert into public.devices (id, owner_id, status) values ('gaps-future', '11111111-1111-4111-8111-111111111111', 'online');
insert into public.readings (device_id, recorded_at, boot_id, seq, uptime_ms) values
  ('gaps-future', now() - interval '10 minutes', 'b4b4b4b4', 0, 0),
  ('gaps-future', now() + interval '1 day',      'b4b4b4b4', 1, 1);

insert into public.readings (device_id, recorded_at, boot_id, seq, uptime_ms)
select 'gaps-a', ts, boot, row_number() over (partition by boot order by ts) - 1, 0
from (
  select ts, 'b1b1b1b1' as boot
  from m, generate_series(m.m - interval '3 hours', m.m - interval '10 minutes', interval '1 minute') ts
  where ts not between m.m - interval '150 minutes' and m.m - interval '149 minutes'
    and ts not between m.m - interval '140 minutes' and m.m - interval '138 minutes'
  union all
  select ts, 'b1b1b1b1' from m, generate_series(m.m + interval '20 minutes', m.m + interval '2 hours', interval '1 minute') ts
  union all
  select ts, 'b2b2b2b2' from m, generate_series(m.m + interval '130 minutes', now() - interval '30 minutes', interval '1 minute') ts
) s;
-- seq must keep b1 unique across both b1 segments (row_number above already spans them); unsynced rows are ignored
insert into public.readings (device_id, recorded_at, boot_id, seq, uptime_ms, clock_source)
select 'gaps-a', m.m - interval '139 minutes', 'c0c0c0c0', 0, 0, 'unsynced' from m;

create temp table ids as select p.id from public.plants p where p.nickname = 'great';
grant select on fx, m, ids to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------
-- Structure and grants
-- ---------------------------------------------------------------------------------------------------------------
select ok((select 'security_invoker=true' = any (reloptions) from pg_class where oid = 'public.plant_status_v'::regclass),
          'plant_status_v is security_invoker');
select ok(not has_table_privilege('anon', 'public.plant_status_v', 'select'), 'anon cannot select plant_status_v');
select ok(not has_function_privilege('anon', 'public.device_offline_periods(text, timestamptz, timestamptz)', 'execute'),
          'anon cannot execute device_offline_periods');
select ok(has_function_privilege('authenticated', 'public.effective_thresholds(uuid)', 'execute'),
          'authenticated can execute effective_thresholds');

-- ---------------------------------------------------------------------------------------------------------------
-- As owner A
-- ---------------------------------------------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);

-- effective_thresholds: per-metric deep merge
select is((select public.effective_thresholds(p.id) from public.plants p where p.nickname = 'great'),
          (select thresholds from public.plant_profiles where id = 'spathiphyllum'),
          'effective_thresholds without overrides equals the profile');
select is((select public.effective_thresholds(p.id) -> 'temperature_c' from public.plants p where p.nickname = 'override'),
          '{"critical_low": 10, "low": 24, "ok_low": 24, "ok_high": 29, "high": 30, "critical_high": 32}'::jsonb,
          'effective_thresholds overrides only the named levels of a metric');
select is((select public.effective_thresholds(p.id) - 'temperature_c' from public.plants p where p.nickname = 'override'),
          (select thresholds - 'temperature_c' from public.plant_profiles where id = 'spathiphyllum'),
          'effective_thresholds leaves other metrics untouched');

-- Status matrix: overall | temperature | humidity | light | soil | issues
create temp table expected_status (name text, expected text);
insert into expected_status values
  ('great',       'great|ok|ok|ok|ok|{}'),
  ('okay',        'okay|ok|ok|ok|ok|{}'),
  ('uncal',       'great|ok|ok|ok|unknown|{}'),
  ('soil-low',    'needs_attention|ok|ok|ok|low|{soil}'),
  ('cold',        'in_trouble|critical_low|ok|ok|low|{temperature,soil}'),
  ('dark-tz',     'in_trouble|ok|ok|critical_low|ok|{light}'),
  ('dim',         'needs_attention|ok|ok|low|ok|{light}'),
  ('sun',         'needs_attention|ok|ok|high|ok|{light}'),
  ('humid-12h',   'needs_attention|ok|high|ok|ok|{humidity}'),
  ('humid-short', 'okay|ok|ok|ok|ok|{}'),
  ('soggy',       'needs_attention|ok|ok|ok|high|{soil}'),
  ('soggy-short', 'okay|ok|ok|ok|ok|{}'),
  ('override',    'needs_attention|low|ok|ok|ok|{temperature}'),
  ('offline-old', 'offline|ok|ok|ok|ok|{}'),
  ('fresh-180',   'great|ok|ok|ok|ok|{}'),
  ('lwt',         'offline|ok|ok|ok|ok|{}'),
  ('nodata',      'no_data|unknown|unknown|unknown|unknown|{}'),
  ('nodev',       'no_data|unknown|unknown|unknown|unknown|{}'),
  ('hum-sparse',  'okay|ok|ok|unknown|ok|{}'),
  ('soil-sparse', 'okay|ok|ok|unknown|ok|{}'),
  ('future',      'offline|ok|ok|unknown|ok|{}'),
  ('hum-crit',    'in_trouble|ok|critical_high|unknown|ok|{humidity}'),
  ('soil-crit',   'in_trouble|ok|ok|unknown|critical_high|{soil}');
grant select on expected_status to authenticated;

select is(concat_ws('|', s.overall, s.temperature_status, s.humidity_status, s.light_status, s.soil_status, s.issues::text),
          e.expected, 'status: ' || e.name)
from expected_status e
join public.plants p on p.nickname = e.name
left join public.plant_status_v s on s.plant_id = p.id
order by e.name;

-- Labels and summary: overall_label | temperature | humidity | light | soil labels | summary
create temp table expected_text (name text, expected text);
insert into expected_text values
  ('great',     'Feeling great|Just right|Just right|Just right|Just right|All good — I''m feeling great'),
  ('okay',      'Doing okay|Just right|Just right|Just right|Just right|Everything is within range'),
  ('uncal',     'Feeling great|Just right|Just right|Just right|Not calibrated|All good — calibrate the soil sensor to track watering'),
  ('soil-low',  'Needs attention|Just right|Just right|Just right|Getting dry|Soil is getting dry — water soon'),
  ('cold',      'In trouble|Too cold|Just right|Just right|Getting dry|It''s far too cold — move somewhere warmer now'),
  ('dark-tz',   'In trouble|Just right|Just right|Too dark|Just right|Far too dark — move closer to a window'),
  ('sun',       'Needs attention|Just right|Just right|Too bright|Just right|Getting direct sun — move out of the sun'),
  ('humid-12h', 'Needs attention|Just right|Too humid|Just right|Just right|The air has been very humid for 12 hours — improve airflow'),
  ('soggy',     'Needs attention|Just right|Just right|Just right|Too wet|Soil has been soggy for 2 days — hold off watering'),
  ('override',  'Needs attention|A bit cold|Just right|Just right|Just right|It''s a bit cold — keep away from drafts'),
  ('lwt',       'Offline|Just right|Just right|Just right|Just right|No recent readings — check the sensor''s power and Wi-Fi'),
  ('nodata',    'No data yet|No data|No data|No data|No data|Waiting for the first reading'),
  ('hum-crit',  'In trouble|Just right|Too humid|No data|Just right|The air is far too humid — improve airflow now'),
  ('soil-crit', 'In trouble|Just right|Just right|No data|Too wet|Soil is waterlogged — stop watering and let it drain');
grant select on expected_text to authenticated;

select is(concat_ws('|', s.overall_label, s.temperature_label, s.humidity_label, s.light_label, s.soil_label, s.summary),
          e.expected, 'labels: ' || e.name)
from expected_text e
join public.plants p on p.nickname = e.name
join public.plant_status_v s on s.plant_id = p.id
order by e.name;

select is((select count(*)::int from public.plant_status_v), 23, 'owner sees one status row per own plant');
select ok((select bool_and(computed_at = now()) from public.plant_status_v), 'computed_at is now()');
select is((select latest_reading_at from public.plant_status_v s join public.plants p on p.id = s.plant_id
           where p.nickname = 'offline-old'),
          now() - interval '181 seconds', 'latest_reading_at ignores unsynced readings');
select is((select (soil_calibrated, device_id)::text from public.plant_status_v s join public.plants p on p.id = s.plant_id
           where p.nickname = 'nodev'), '(f,)', 'a plant without a device has soil_calibrated false and no device_id');

-- device_offline_periods
select results_eq(
  $$select started_at, ended_at, duration_s, cause, ongoing
    from m, public.device_offline_periods('gaps-a', m.m - interval '1 day', m.m)$$,
  $$select m.m - interval '140 minutes', m.m - interval '137 minutes', 180, 'no_data', false from m
    union all
    select m.m - interval '9 minutes', m.m, 540, 'no_data', false from m$$,
  'only gaps > 180 s count (a 180 s gap and unsynced rows are ignored); a gap across midnight is clipped at the end');
select results_eq(
  $$select started_at, ended_at, duration_s, cause, ongoing
    from m, public.device_offline_periods('gaps-a', m.m, m.m + interval '3 hours')$$,
  $$select m.m, m.m + interval '20 minutes', 1200, 'no_data', false from m
    union all
    select m.m + interval '121 minutes', m.m + interval '130 minutes', 540, 'device_restart', false from m$$,
  'the midnight gap also appears clipped in the next day; a boot_id change is device_restart');
select results_eq(
  $$select started_at, ended_at, duration_s, cause, ongoing
    from m, public.device_offline_periods('gaps-a', m.m - interval '139 minutes', m.m - interval '60 minutes')$$,
  $$select m.m - interval '139 minutes', m.m - interval '137 minutes', 120, 'no_data', false from m$$,
  'a gap crossing the window start is clipped to it');
select results_eq(
  $$select started_at, ended_at, duration_s, cause, ongoing
    from public.device_offline_periods('gaps-a', now() - interval '2 hours', now() + interval '1 hour')$$,
  $$select max(recorded_at) + interval '60 seconds', now(),
           extract(epoch from now() - max(recorded_at) - interval '60 seconds')::integer, 'no_data', true
    from public.readings where device_id = 'gaps-a' and clock_source = 'ntp'$$,
  'an open trailing gap is ongoing and ends at now()');
select results_eq(
  $$select started_at, ended_at, duration_s, cause, ongoing
    from public.device_offline_periods('gaps-b', now() - interval '1 hour', now() - interval '5 minutes')$$,
  $$values (now() - interval '6 minutes', now() - interval '5 minutes', 60, 'no_data', true)$$,
  'an ongoing outage that began < 180 s before p_to is still clipped into that window');
select results_eq(
  $$select started_at, ended_at, duration_s, cause, ongoing
    from public.device_offline_periods('gaps-future', now() - interval '1 hour', now() + interval '2 hours')$$,
  $$values (now() - interval '9 minutes', now(), 540, 'no_data', true)$$,
  'a future-dated reading neither closes an ongoing outage nor extends it past now()');
select results_eq(
  $$select started_at, ended_at, duration_s, cause, ongoing
    from public.device_offline_periods('gaps-future', now() - interval '1 hour', now())$$,
  $$values (now() - interval '9 minutes', now(), 540, 'no_data', true)$$,
  'a future-dated reading does not close an outage in a window ending at now()');
select is((select count(*)::int from m, public.device_offline_periods('gaps-a', m.m - interval '150 minutes',
                                                                     m.m - interval '145 minutes')),
          0, 'a window with readings and no gap > 180 s returns nothing');
select is((select count(*)::int from public.device_offline_periods('gaps-a', now() - interval '100 days',
                                                                   now() - interval '95 days')),
          0, 'a window beyond the retained readings returns nothing');
select lives_ok($$select * from public.device_offline_periods('gaps-a', now() - interval '7 days', now())$$,
                'a 7-day window is allowed');
select throws_ok($$select * from public.device_offline_periods('gaps-a', now() - interval '7 days 1 second', now())$$,
                 '22023', null, 'a window longer than 7 days raises 22023');
select throws_ok($$select * from public.device_offline_periods('gaps-a', now(), now() - interval '1 hour')$$,
                 '22023', null, 'a reversed window raises 22023');
select is((select count(*)::int from public.device_offline_periods('st-b', now() - interval '1 day', now())),
          0, 'owner A gets nothing for owner B''s device');

-- ---------------------------------------------------------------------------------------------------------------
-- As owner B: RLS hides A's plants and A's device
-- ---------------------------------------------------------------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}', true);
select is((select array_agg(plant_id)::text from public.plant_status_v), '{bbbbbbbb-0000-4000-8000-000000000001}',
          'owner B sees only their own plant status');
select is((select count(*)::int from m, public.device_offline_periods('gaps-a', m.m - interval '1 day', m.m)),
          0, 'owner B gets nothing for owner A''s device');
select is((select public.effective_thresholds(ids.id) from ids), null,
          'owner B cannot read effective thresholds of A''s plant');
select is((select public.effective_thresholds('aaaaaaaa-0000-4000-8000-00000000ffff'::uuid)), null,
          'effective_thresholds of an unknown plant is null');

-- ---------------------------------------------------------------------------------------------------------------
-- As anon: nothing
-- ---------------------------------------------------------------------------------------------------------------
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok($$select * from public.plant_status_v$$, '42501', null, 'anon cannot read plant_status_v');
select throws_ok($$select * from public.device_offline_periods('gaps-a', now() - interval '1 day', now())$$, '42501', null,
                 'anon cannot call device_offline_periods');

-- ---------------------------------------------------------------------------------------------------------------
-- As service_role: sees every plant
-- ---------------------------------------------------------------------------------------------------------------
reset role;
set local role service_role;
select is((select count(*)::int from public.plant_status_v), (select count(*)::int from public.plants),
          'service_role sees every plant');
reset role;

select * from finish();
rollback;
