-- pgTAP: devices.climate_sensor (20261120000200). Self-contained fixtures inside one transaction, rolled back at the end.
begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000', '11111111-1111-4111-8111-111111111111', 'authenticated', 'authenticated', 'a@test.local'),
  ('00000000-0000-0000-0000-000000000000', '22222222-2222-4222-8222-222222222222', 'authenticated', 'authenticated', 'b@test.local');
insert into public.devices (id, owner_id) values ('test-dev-a', '11111111-1111-4111-8111-111111111111');

-- ---------------------------------------------------------------------------------------------------------------
-- Structure
-- ---------------------------------------------------------------------------------------------------------------
select has_column('public', 'devices', 'climate_sensor', 'devices has climate_sensor');
select col_type_is('public', 'devices', 'climate_sensor', 'text', 'climate_sensor is text');
select col_is_null('public', 'devices', 'climate_sensor', 'climate_sensor is nullable');
select col_hasnt_default('public', 'devices', 'climate_sensor', 'climate_sensor has no default');
select is((select climate_sensor from public.devices where id = 'test-dev-a'), null, 'a new device starts with null');

-- ---------------------------------------------------------------------------------------------------------------
-- Gateway (service_role): the PostgREST upsert it sends, and the check constraint
-- ---------------------------------------------------------------------------------------------------------------
set local role service_role;
select lives_ok($$insert into public.devices (id, climate_sensor) values ('test-dev-a', 'sht31')
                  on conflict (id) do update set climate_sensor = excluded.climate_sensor$$,
                'service_role stores sht31');
select lives_ok($$update public.devices set climate_sensor = 'dht11' where id = 'test-dev-a'$$, 'service_role stores dht11');
select is((select climate_sensor from public.devices where id = 'test-dev-a'), 'dht11', 'latest value wins');
select throws_ok($$update public.devices set climate_sensor = 'bme280' where id = 'test-dev-a'$$, '23514', null,
                 'unknown sensor names are rejected by the check');
select throws_ok($$update public.devices set climate_sensor = 'SHT31' where id = 'test-dev-a'$$, '23514', null,
                 'the check is case-sensitive (the gateway lowercases)');
select lives_ok($$update public.devices set climate_sensor = null where id = 'test-dev-a'$$,
                'service_role clears it (message without the field)');
update public.devices set climate_sensor = 'sht31' where id = 'test-dev-a';
reset role;

-- ---------------------------------------------------------------------------------------------------------------
-- Owner A: reads it, cannot write it
-- ---------------------------------------------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);
select is((select climate_sensor from public.devices where id = 'test-dev-a'), 'sht31', 'owner reads climate_sensor');
select throws_ok($$update public.devices set climate_sensor = 'dht11' where id = 'test-dev-a'$$, '42501', null,
                 'owner cannot update climate_sensor');
reset role;

-- ---------------------------------------------------------------------------------------------------------------
-- Other user B and anon: see nothing
-- ---------------------------------------------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}', true);
select is((select count(*)::int from public.devices where climate_sensor is not null), 0,
          'other user does not see the owner''s climate_sensor');
select throws_ok($$update public.devices set climate_sensor = null where id = 'test-dev-a'$$, '42501', null,
                 'other user cannot update climate_sensor');
reset role;

set local role anon;
select throws_ok($$select climate_sensor from public.devices$$, '42501', null, 'anon cannot read climate_sensor');
reset role;

select is((select climate_sensor from public.devices where id = 'test-dev-a'), 'sht31', 'nobody but the gateway changed it');

select * from finish();
rollback;
