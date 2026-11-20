-- pgTAP: core schema (T1). Self-contained fixtures inside one transaction, rolled back at the end, so it does not
-- depend on seed.sql (except that the profile must exist after migrations alone).
begin;
create extension if not exists pgtap with schema extensions;
select plan(84);

-- ---------------------------------------------------------------------------------------------------------------
-- Fixtures (as postgres): owner A with a plant, an uncalibrated device, a gateway and readings; user B with nothing.
-- ---------------------------------------------------------------------------------------------------------------
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000', '11111111-1111-4111-8111-111111111111', 'authenticated', 'authenticated', 'a@test.local'),
  ('00000000-0000-0000-0000-000000000000', '22222222-2222-4222-8222-222222222222', 'authenticated', 'authenticated', 'b@test.local');

insert into public.plants (id, owner_id, profile_id, nickname, timezone)
values ('aaaaaaaa-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'spathiphyllum', 'Test lily', 'UTC');

insert into public.devices (id, owner_id, plant_id)
values ('test-dev-a', '11111111-1111-4111-8111-111111111111', 'aaaaaaaa-0000-4000-8000-000000000001');

insert into public.gateways (id, owner_id) values ('test-gw-a', '11111111-1111-4111-8111-111111111111');

insert into public.readings (device_id, recorded_at, boot_id, seq, uptime_ms, soil_raw) values
  ('test-dev-a', '2026-11-16 00:00Z', 'aaaa0001', 0, 0, 1000),
  ('test-dev-a', '2026-11-16 00:01Z', 'aaaa0001', 1, 60000, 2000),
  ('test-dev-a', '2026-11-16 00:02Z', 'aaaa0001', 2, 120000, 2250),
  ('test-dev-a', '2026-11-16 00:03Z', 'aaaa0001', 3, 180000, 3000),
  ('test-dev-a', '2026-11-16 00:04Z', 'aaaa0001', 4, 240000, 4000),
  ('test-dev-a', '2026-11-16 00:05Z', 'aaaa0001', 5, 300000, null);

-- ---------------------------------------------------------------------------------------------------------------
-- Structure
-- ---------------------------------------------------------------------------------------------------------------
select ok((select bool_and(relrowsecurity) from pg_class
           where oid in ('public.plant_profiles'::regclass, 'public.plants'::regclass, 'public.devices'::regclass,
                         'public.readings'::regclass, 'public.gateways'::regclass)),
          'RLS is enabled on every core table');
select ok((select 'security_invoker=true' = any (reloptions) from pg_class where oid = 'public.readings_v'::regclass),
          'readings_v is security_invoker');
select is((select count(*)::int from pg_publication_tables
           where pubname = 'supabase_realtime' and schemaname = 'public' and tablename in ('readings', 'devices')),
          2, 'readings and devices are in the supabase_realtime publication');
select col_is_unique('public', 'readings', array['device_id', 'boot_id', 'seq'], 'readings dedup key is unique');

-- ---------------------------------------------------------------------------------------------------------------
-- Spathiphyllum profile: created by migration, idempotent
-- ---------------------------------------------------------------------------------------------------------------
select is((select count(*)::int from public.plant_profiles where id = 'spathiphyllum'), 1,
          'spathiphyllum profile exists after migrations');
select ok((select public.valid_threshold_overrides(thresholds)
                  and thresholds ?& array['temperature_c', 'humidity_pct', 'lux', 'soil_pct']
           from public.plant_profiles where id = 'spathiphyllum'),
          'profile thresholds cover all four metrics in ascending order');
select is((select (thresholds #>> '{soil_pct,low}')::numeric from public.plant_profiles where id = 'spathiphyllum'),
          35::numeric, 'profile soil low threshold matches §2.8');
select is((select cardinality(sources) from public.plant_profiles where id = 'spathiphyllum'), 13,
          'profile cites sources [45]-[57]');
select ok(exists (select 1 from supabase_migrations.schema_migrations where version = '20261116000150'),
          'profile migration is recorded');
select is((select common_name from public.plant_profiles where id = 'spathiphyllum'), 'Spathiphyllum',
          'the species is shown as Spathiphyllum after all migrations (20261120000100)');
select ok((select care_notes like 'Spathiphyllum (common name peace lily), %' and strpos(care_notes, U&'\2014') = 0
           from public.plant_profiles where id = 'spathiphyllum'),
          'care notes call the plant Spathiphyllum and contain no em dash');
update public.plant_profiles set common_name = 'changed' where id = 'spathiphyllum';
select lives_ok($$
  do $do$
  declare s text;
  begin
    for s in select unnest(statements) from supabase_migrations.schema_migrations where version = '20261116000150'
    loop
      execute s;
    end loop;
  end $do$ $$, 're-applying the profile migration succeeds');
select is((select count(*)::int from public.plant_profiles where id = 'spathiphyllum'), 1,
          're-applying the profile migration leaves one row');
select is((select common_name from public.plant_profiles where id = 'spathiphyllum'), 'Peace lily',
          're-applying the profile migration restores its values');

-- ---------------------------------------------------------------------------------------------------------------
-- Constraints (as postgres)
-- ---------------------------------------------------------------------------------------------------------------
select throws_ok($$insert into public.devices (id) values ('olvar-gateway')$$, '23514', null,
                 'device id olvar-gateway is reserved');
select throws_ok($$insert into public.devices (id) values ('AB')$$, '23514', null, 'malformed device id is rejected');
select throws_ok($$update public.devices set soil_dry_raw = 1000, soil_wet_raw = 3000 where id = 'test-dev-a'$$,
                 '23514', null, 'reversed calibration is rejected');
select throws_ok($$update public.devices set soil_dry_raw = 2100, soil_wet_raw = 2000 where id = 'test-dev-a'$$,
                 '23514', null, 'calibration closer than 100 counts is rejected');
select throws_ok($$update public.devices set soil_dry_raw = 3000 where id = 'test-dev-a'$$,
                 '23514', null, 'half a calibration pair is rejected');
select throws_ok($$insert into public.readings (device_id, recorded_at, boot_id, seq, uptime_ms)
                   values ('test-dev-a', now(), 'aaaa0001', 1, 1)$$,
                 '23505', null, 'duplicate (device_id, boot_id, seq) is rejected');
insert into public.readings (device_id, recorded_at, boot_id, seq, uptime_ms)
values ('test-dev-a', now(), 'aaaa0001', 1, 1)
on conflict (device_id, boot_id, seq) do nothing;
select is((select count(*)::int from public.readings where device_id = 'test-dev-a' and boot_id = 'aaaa0001' and seq = 1),
          1, 'upsert with on conflict do nothing keeps one row');
select throws_ok($$insert into public.readings (device_id, recorded_at, boot_id, seq, uptime_ms)
                   values ('test-dev-a', now(), 'NOTHEX!!', 0, 0)$$, '23514', null, 'malformed boot_id is rejected');
select throws_ok($$insert into public.readings (device_id, recorded_at, boot_id, seq, uptime_ms, soil_raw)
                   values ('test-dev-a', now(), 'aaaa0002', 0, 0, 4096)$$, '23514', null, 'soil_raw > 4095 is rejected');

-- ---------------------------------------------------------------------------------------------------------------
-- soil_pct(): null when uncalibrated, clamped, follows recalibration retroactively
-- ---------------------------------------------------------------------------------------------------------------
select is(public.soil_pct(2000, null, null), null::real, 'soil_pct is null without calibration');
select is(public.soil_pct(null, 3000, 1000), null::real, 'soil_pct is null for a failed read');
select is(public.soil_pct(2000, 3000, 1000), 50::real, 'soil_pct midpoint is 50');
select is(public.soil_pct(4000, 3000, 1000), 0::real, 'soil_pct clamps drier than dry to 0');
select is(public.soil_pct(500, 3000, 1000), 100::real, 'soil_pct clamps wetter than wet to 100');
select is((select count(*)::int from public.readings_v where device_id = 'test-dev-a' and soil_pct is not null), 0,
          'readings_v soil_pct is null while the device is uncalibrated');
update public.devices set soil_dry_raw = 3000, soil_wet_raw = 1000 where id = 'test-dev-a';
select results_eq(
  $$select soil_pct from public.readings_v where device_id = 'test-dev-a' order by seq$$,
  $$values (100::real), (50::real), (37.5::real), (0::real), (0::real), (null::real)$$,
  'readings_v computes soil_pct with the calibration');
update public.devices set soil_dry_raw = 2500, soil_wet_raw = 1500 where id = 'test-dev-a';
select results_eq(
  $$select soil_pct from public.readings_v where device_id = 'test-dev-a' order by seq$$,
  $$values (100::real), (50::real), (25::real), (0::real), (0::real), (null::real)$$,
  'recalibration re-expresses past readings');

-- Gateway owner (as service_role, like the Pi): the heartbeat upsert names only its own columns, so it neither
-- changes nor clears owner_id; setup_plant.py's claim (id, owner_id) sets it and keeps the heartbeat columns.
set local role service_role;
insert into public.gateways (id, version, buffer_depth, last_seen_at) values ('test-gw-a', '0.2.0', 3, now())
on conflict (id) do update set version = excluded.version, buffer_depth = excluded.buffer_depth,
  last_seen_at = excluded.last_seen_at;
select is((select owner_id from public.gateways where id = 'test-gw-a'), '11111111-1111-4111-8111-111111111111'::uuid,
          'gateway heartbeat upsert keeps the owner');
insert into public.gateways (id, version, buffer_depth, last_seen_at) values ('test-gw-new', '0.2.0', 0, now())
on conflict (id) do update set version = excluded.version, buffer_depth = excluded.buffer_depth,
  last_seen_at = excluded.last_seen_at;
insert into public.gateways (id, owner_id) values ('test-gw-new', '22222222-2222-4222-8222-222222222222')
on conflict (id) do update set owner_id = excluded.owner_id;
select results_eq($$select owner_id, version, buffer_depth from public.gateways where id = 'test-gw-new'$$,
                  $$values ('22222222-2222-4222-8222-222222222222'::uuid, '0.2.0'::text, 0)$$,
                  'claiming an unowned gateway sets the owner and keeps the heartbeat columns');
delete from public.gateways where id = 'test-gw-new';
reset role;

-- ---------------------------------------------------------------------------------------------------------------
-- Owner A (authenticated)
-- ---------------------------------------------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);

select is((select count(*)::int from public.plants), 1, 'owner sees their plant');
select is((select count(*)::int from public.devices), 1, 'owner sees their device');
select is((select count(*)::int from public.readings), 6, 'owner sees their readings');
select is((select count(*)::int from public.readings_v), 6, 'owner sees their readings_v rows');
select is((select count(*)::int from public.gateways), 1, 'owner sees their gateway');
select ok((select count(*) from public.plant_profiles) >= 1, 'owner can read plant profiles');

select lives_ok($$update public.devices set soil_dry_raw = 2800, soil_wet_raw = 1200, soil_calibrated_at = now()
                  where id = 'test-dev-a'$$, 'owner can update the calibration columns');
select results_eq($$select soil_dry_raw, soil_wet_raw from public.devices where id = 'test-dev-a'$$,
                  $$values (2800, 1200)$$, 'calibration update is stored');
select throws_ok($$update public.devices set fw = 'x' where id = 'test-dev-a'$$, '42501', null,
                 'owner cannot update devices.fw');
select throws_ok($$update public.devices set status = 'offline' where id = 'test-dev-a'$$, '42501', null,
                 'owner cannot update devices.status');
select throws_ok($$update public.devices set owner_id = '22222222-2222-4222-8222-222222222222' where id = 'test-dev-a'$$,
                 '42501', null, 'owner cannot reassign devices.owner_id');
select throws_ok($$update public.devices set plant_id = null where id = 'test-dev-a'$$, '42501', null,
                 'owner cannot update devices.plant_id');
select throws_ok($$update public.devices set soil_dry_raw = 1000, soil_wet_raw = 3000 where id = 'test-dev-a'$$,
                 '23514', null, 'owner cannot store a reversed calibration');

select lives_ok($$update public.plants set nickname = 'Lilly', location = 'Kitchen', timezone = 'Europe/Berlin',
                    threshold_overrides = '{"soil_pct": {"low": 30, "ok_low": 30}}'
                  where id = 'aaaaaaaa-0000-4000-8000-000000000001'$$,
                'owner can update nickname, location, timezone and threshold_overrides');
select results_eq($$select nickname, location, timezone, threshold_overrides from public.plants$$,
                  $$values ('Lilly', 'Kitchen', 'Europe/Berlin', '{"soil_pct": {"low": 30, "ok_low": 30}}'::jsonb)$$,
                  'plant update is stored');
select throws_ok($$update public.plants set owner_id = '22222222-2222-4222-8222-222222222222'$$, '42501', null,
                 'owner cannot update plants.owner_id');
select throws_ok($$update public.plants set profile_id = 'spathiphyllum'$$, '42501', null,
                 'owner cannot update plants.profile_id');
select throws_ok($$update public.plants set location = repeat('x', 61)$$, '23514', null,
                 'location longer than 60 chars is rejected');
select throws_ok($$insert into public.plants (owner_id, profile_id)
                   values ('11111111-1111-4111-8111-111111111111', 'spathiphyllum')$$, '42501', null,
                 'owner cannot insert plants');
select throws_ok($$insert into public.readings (device_id, recorded_at, boot_id, seq, uptime_ms)
                   values ('test-dev-a', now(), 'aaaa0009', 0, 0)$$, '42501', null, 'owner cannot insert readings');
select throws_ok($$delete from public.readings$$, '42501', null, 'owner cannot delete readings');
select throws_ok($$update public.plant_profiles set common_name = 'x'$$, '42501', null,
                 'owner cannot modify plant profiles');

-- malformed threshold overrides
select throws_ok($$update public.plants set threshold_overrides = '{"co2": {"low": 1}}'$$, '23514', null,
                 'unknown metric in overrides is rejected');
select throws_ok($$update public.plants set threshold_overrides = '{"lux": {"min": 1}}'$$, '23514', null,
                 'unknown level key in overrides is rejected');
select throws_ok($$update public.plants set threshold_overrides = '{"lux": {"low": "800"}}'$$, '23514', null,
                 'non-numeric override is rejected');
select throws_ok($$update public.plants set threshold_overrides = '{"lux": {"low": 900, "ok_low": 800}}'$$, '23514', null,
                 'descending overrides are rejected');
select throws_ok($$update public.plants set threshold_overrides = '[]'$$, '23514', null,
                 'non-object overrides are rejected');
select throws_ok($$update public.plants set threshold_overrides = '{"lux": 5}'$$, '23514', null,
                 'non-object metric overrides are rejected');
select throws_ok($$update public.plants set threshold_overrides = null$$, '23502', null, 'null overrides are rejected');

-- timezone validation
select throws_ok($$update public.plants set timezone = 'Asia/Seol'$$, '22023', null, 'typo timezone is rejected');
select throws_ok($$update public.plants set timezone = 'UTC+3'$$, '22023', null, 'POSIX offset timezone is rejected');
select throws_ok($$update public.plants set timezone = ''$$, '22023', null, 'empty timezone is rejected');
select is((select timezone from public.plants), 'Europe/Berlin', 'rejected timezone updates leave the row unchanged');
select lives_ok($$update public.plants set timezone = 'Asia/Seoul'$$, 'valid IANA timezone is accepted');
select is((select timezone from public.plants), 'Asia/Seoul', 'valid timezone is stored');

-- ---------------------------------------------------------------------------------------------------------------
-- User B (authenticated, owns nothing)
-- ---------------------------------------------------------------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}', true);

select is((select count(*)::int from public.plants), 0, 'other user sees no plants');
select is((select count(*)::int from public.devices), 0, 'other user sees no devices');
select is((select count(*)::int from public.readings), 0, 'other user sees no readings');
select is((select count(*)::int from public.readings_v), 0, 'other user sees no readings_v rows');
select is((select count(*)::int from public.gateways), 0, 'other user sees no gateways');
update public.plants set nickname = 'Hacked' where id = 'aaaaaaaa-0000-4000-8000-000000000001';
update public.devices set soil_dry_raw = 4000, soil_wet_raw = 100 where id = 'test-dev-a';

-- ---------------------------------------------------------------------------------------------------------------
-- anon: nothing granted
-- ---------------------------------------------------------------------------------------------------------------
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok($$select * from public.plant_profiles$$, '42501', null, 'anon cannot read plant_profiles');
select throws_ok($$select * from public.plants$$, '42501', null, 'anon cannot read plants');
select throws_ok($$select * from public.devices$$, '42501', null, 'anon cannot read devices');
select throws_ok($$select * from public.readings$$, '42501', null, 'anon cannot read readings');
select throws_ok($$select * from public.readings_v$$, '42501', null, 'anon cannot read readings_v');
select throws_ok($$select * from public.gateways$$, '42501', null, 'anon cannot read gateways');

-- ---------------------------------------------------------------------------------------------------------------
-- service_role (backend / gateway)
-- ---------------------------------------------------------------------------------------------------------------
reset role;
set local role service_role;
select lives_ok($$insert into public.readings (device_id, recorded_at, boot_id, seq, uptime_ms, temperature_c)
                  values ('test-dev-a', now(), 'aaaa0003', 0, 0, null)
                  on conflict (device_id, boot_id, seq) do nothing$$, 'service_role can upsert readings');
select lives_ok($$update public.devices set status = 'online', last_seen_at = now() where id = 'test-dev-a'$$,
                'service_role can update device status');
select ok((select count(*) from public.plants) >= 1, 'service_role reads all plants');

-- ---------------------------------------------------------------------------------------------------------------
-- other user's writes changed nothing
-- ---------------------------------------------------------------------------------------------------------------
reset role;
select is((select nickname from public.plants where id = 'aaaaaaaa-0000-4000-8000-000000000001'), 'Lilly',
          'other user cannot rename the owner''s plant');
select results_eq($$select soil_dry_raw, soil_wet_raw from public.devices where id = 'test-dev-a'$$,
                  $$values (2800, 1200)$$, 'other user cannot recalibrate the owner''s device');

select * from finish();
rollback;
