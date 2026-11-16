-- pgTAP: late_rows_ignored stays exact for rows received inside the 2-minute watermark lag around apply_retention().
-- now() is fixed for the whole transaction; "an hour later" is simulated by moving received_at and the watermark
-- back by one hour.
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000', '33333333-3333-4333-8333-333333333333', 'authenticated', 'authenticated', 'lag@test.local');
insert into public.plants (id, owner_id, profile_id, timezone) values
  ('aaaaaaaa-0000-4000-8000-0000000000c1', '33333333-3333-4333-8333-333333333333', 'spathiphyllum', 'Asia/Kolkata');
insert into public.devices (id, owner_id, plant_id) values
  ('ll-dev', '33333333-3333-4333-8333-333333333333', 'aaaaaaaa-0000-4000-8000-0000000000c1');

-- +05:30: cut = floor_hour(local midnight of today - 90) = midnight - 30 min, so local day d straddles the cut
create temp table lx as
  select m - interval '30 minutes' as cut, m as midnight, (m at time zone 'Asia/Kolkata')::date - 1 as d
  from (select ((now() at time zone 'Asia/Kolkata')::date - 90)::timestamp at time zone 'Asia/Kolkata' as m) s;

create function pg_temp.an_hour_later() returns void language sql as $$
  update public.readings set received_at = received_at - interval '1 hour' where device_id = 'll-dev';
  update public.rollup_state set processed_until = processed_until - interval '1 hour';
$$;

-- First retention: no seal yet. Both rows arrive inside the lag window; 30 is on day d after the cut.
update public.rollup_state set processed_until = now() - interval '30 minutes';
insert into public.readings (device_id, recorded_at, received_at, boot_id, seq, uptime_ms, temperature_c)
select 'll-dev', lx.midnight - interval '5 hours', now() - interval '1 minute', 'ffff0001', 0, 0, 10 from lx
union all
select 'll-dev', lx.cut + interval '10 minutes', now() - interval '1 minute', 'ffff0001', 1, 1, 30 from lx;

select lives_ok($$select public.apply_retention()$$, 'first retention run');
select results_eq($$select n, temperature_c_avg, sealed from public.readings_daily, lx where device_id = 'll-dev' and bucket = lx.d$$,
                  $$values (2, 20::real, true)$$, 'both lag-window rows are summarised into the sealed day');
select is((select late_rows_ignored from public.rollup_seals where device_id = 'll-dev'), 0::bigint,
          'nothing is late on the first retention run');

select pg_temp.an_hour_later();
select lives_ok($$select public.refresh_rollups()$$, 'refresh an hour later');
select is((select late_rows_ignored from public.rollup_seals where device_id = 'll-dev'), 0::bigint,
          'a row summarised by retention is not counted as late by the next refresh');
select is((select count(*)::int from public.rollup_late_checked c
           join public.readings r on r.id = c.reading_id where r.device_id = 'll-dev'), 0,
          'refresh clears checked ids once the watermark has passed them');

-- Second retention: the day is sealed. Late rows arrive inside the lag window: one before sealed_before (retention
-- deletes it in this same run) and one on the straddling day after the cut (kept).
insert into public.readings (device_id, recorded_at, received_at, boot_id, seq, uptime_ms, temperature_c)
select 'll-dev', lx.midnight - interval '4 hours', now() - interval '1 minute', 'ffff0002', 0, 0, 99 from lx
union all
select 'll-dev', lx.cut + interval '20 minutes', now() - interval '1 minute', 'ffff0002', 1, 1, 99 from lx;

select lives_ok($$select public.apply_retention()$$, 'second retention run');
select is((select count(*)::int from public.readings where device_id = 'll-dev' and boot_id = 'ffff0002' and seq = 0), 0,
          'the late row before sealed_before is deleted');
select is((select late_rows_ignored from public.rollup_seals where device_id = 'll-dev'), 2::bigint,
          'late rows in the lag window are counted before retention deletes them');
select results_eq($$select n, temperature_c_avg from public.readings_daily, lx where device_id = 'll-dev' and bucket = lx.d$$,
                  $$values (2, 20::real)$$, 'the sealed day is unchanged');

-- A late row committed after retention whose received_at falls in that run's lag window (its upload transaction
-- started earlier) was not seen by retention, so the next refresh must still count it.
insert into public.readings (device_id, recorded_at, received_at, boot_id, seq, uptime_ms, temperature_c)
select 'll-dev', lx.cut + interval '25 minutes', now() - interval '1 minute', 'ffff0003', 0, 0, 99 from lx;

select pg_temp.an_hour_later();
select lives_ok($$select public.refresh_rollups()$$, 'refresh an hour after the second retention');
select is((select late_rows_ignored from public.rollup_seals where device_id = 'll-dev'), 3::bigint,
          'the kept late row is not counted twice, and the row retention never saw is counted once');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"33333333-3333-4333-8333-333333333333","role":"authenticated"}', true);
select throws_ok($$select * from public.rollup_late_checked$$, '42501', null, 'authenticated cannot read rollup_late_checked');
select throws_ok($$select public.rollup_count_late(now(), now())$$, '42501', null,
                 'authenticated cannot run rollup_count_late');
reset role;

select * from finish();
rollback;
