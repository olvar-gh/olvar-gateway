-- late_rows_ignored around a retention run (fix to 20261116000200_rollups.sql).
--
-- Rows received within the 2-minute watermark lag when apply_retention() runs were miscounted:
--   * a late row recorded into an already sealed bucket before sealed_before was deleted by retention before any
--     refresh counted it (undercount);
--   * a row that retention summarised into a bucket it then sealed (the local day straddling the cut) was later
--     counted as late by the next refresh, because its received_at was still ahead of the watermark (overcount).
-- apply_retention() now classifies every visible row received after the watermark against the seal state as it was
-- before this run, and records those row ids so the next refresh does not classify them again. A row committed
-- after retention with an older received_at (its upload transaction started before ours) is not recorded, so the
-- next refresh still counts it.

create table public.rollup_late_checked (
  reading_id bigint primary key
);

create function public.rollup_count_late(p_after timestamptz, p_until timestamptz) returns void
  language sql set search_path = '' as $$
  update public.rollup_seals s set late_rows_ignored = s.late_rows_ignored + l.cnt
  from (
    select r.device_id, count(*) as cnt
    from public.readings r
    join public.rollup_seals s2 on s2.device_id = r.device_id
    join public.devices d on d.id = r.device_id
    left join public.plants p on p.id = d.plant_id
    cross join lateral (
      select date_trunc('hour', r.recorded_at, 'UTC') as hour,
             (r.recorded_at at time zone coalesce(p.timezone, 'UTC'))::date as day
    ) x
    where r.received_at > p_after and r.received_at <= p_until
      and not exists (select 1 from public.rollup_late_checked c where c.reading_id = r.id)
      and (x.hour < s2.sealed_before
           or (x.day::timestamp at time zone coalesce(p.timezone, 'UTC')) < s2.sealed_before
           or exists (select 1 from public.readings_hourly h
                      where h.device_id = r.device_id and h.bucket = x.hour and h.sealed)
           or exists (select 1 from public.readings_daily dd
                      where dd.device_id = r.device_id and dd.bucket = x.day and dd.sealed))
    group by r.device_id
  ) l
  where s.device_id = l.device_id $$;

create or replace function public.rollup_catch_up() returns void
  language plpgsql set search_path = '' as $$
declare
  v_prev timestamptz;
  v_lo timestamptz;
  v_hi timestamptz := now() - interval '2 minutes';   -- lag: received_at = insert txn start, upload txns are short
  v_dev text[];
  v_hours timestamptz[];
  v_days date[];
begin
  select processed_until into v_prev from public.rollup_state where id for update;
  v_lo := v_prev - interval '10 minutes';              -- overlap; recompute is idempotent

  -- counting starts at v_prev, not v_lo, so the overlap never counts a row twice
  perform public.rollup_count_late(v_prev, v_hi);
  delete from public.rollup_late_checked c
  where not exists (select 1 from public.readings r where r.id = c.reading_id and r.received_at > v_hi);

  select coalesce(array_agg(t.device_id), '{}'), coalesce(array_agg(t.hour), '{}') into v_dev, v_hours
  from (select distinct r.device_id, date_trunc('hour', r.recorded_at, 'UTC') as hour
        from public.readings r where r.received_at > v_lo and r.received_at <= v_hi) t;
  perform public.rollup_write_hourly(v_dev, v_hours);

  select coalesce(array_agg(t.device_id), '{}'), coalesce(array_agg(t.day), '{}') into v_dev, v_days
  from (select distinct r.device_id, (r.recorded_at at time zone coalesce(p.timezone, 'UTC'))::date as day
        from public.readings r
        join public.devices d on d.id = r.device_id
        left join public.plants p on p.id = d.plant_id
        where r.received_at > v_lo and r.received_at <= v_hi) t;
  perform public.rollup_write_daily(v_dev, v_days);

  update public.rollup_state set processed_until = greatest(v_prev, v_hi) where id;
end $$;

-- Unchanged from 20261116000200 except the lag-window step after rollup_catch_up(). It must run before any bucket
-- is sealed or raw row deleted, so rows are classified against the seals that existed when they arrived.
create or replace function public.apply_retention() returns void
  language plpgsql security definer set search_path = '' as $$
declare
  v_until timestamptz;
  v_dev text[];
  v_hours timestamptz[];
  v_days date[];
begin
  perform pg_catalog.pg_advisory_xact_lock(727001);
  perform pg_catalog.set_config('lock_timeout', '60s', true);
  -- waits for in-flight uploads and blocks new ones, so every statement below sees the same raw rows
  lock table public.readings in share row exclusive mode;

  perform public.rollup_catch_up();

  select processed_until into v_until from public.rollup_state where id;
  perform public.rollup_count_late(v_until, 'infinity');
  insert into public.rollup_late_checked (reading_id)
  select r.id from public.readings r where r.received_at > v_until
  on conflict do nothing;

  create temporary table rollup_cuts on commit drop as
  select d.id as device_id, x.tz, s.sealed_before as old_sealed_before,
         date_trunc('hour', ((now() at time zone x.tz)::date - 90)::timestamp at time zone x.tz, 'UTC') as cut
  from public.devices d
  left join public.plants p on p.id = d.plant_id
  cross join lateral (select coalesce(p.timezone, 'UTC') as tz) x
  left join public.rollup_seals s on s.device_id = d.id;

  -- recomputed straight from raw regardless of received_at: the watermark lag would miss rows received just now
  select coalesce(array_agg(t.device_id), '{}'), coalesce(array_agg(t.hour), '{}') into v_dev, v_hours
  from (select distinct r.device_id, date_trunc('hour', r.recorded_at, 'UTC') as hour
        from pg_temp.rollup_cuts c
        join public.readings r on r.device_id = c.device_id
        where r.recorded_at < c.cut and r.recorded_at >= coalesce(c.old_sealed_before, '-infinity')) t;
  perform public.rollup_write_hourly(v_dev, v_hours);

  select coalesce(array_agg(t.device_id), '{}'), coalesce(array_agg(t.day), '{}') into v_dev, v_days
  from (select distinct r.device_id, (r.recorded_at at time zone c.tz)::date as day, c.tz, c.cut
        from pg_temp.rollup_cuts c
        join public.readings r on r.device_id = c.device_id
        where r.recorded_at < c.cut + interval '26 hours'
          and r.recorded_at >= coalesce(c.old_sealed_before, '-infinity') - interval '26 hours') t
  where (t.day::timestamp at time zone t.tz) < t.cut;
  perform public.rollup_write_daily(v_dev, v_days);

  insert into public.rollup_seals (device_id, sealed_before)
  select c.device_id, c.cut from pg_temp.rollup_cuts c
  on conflict (device_id) do update
    set sealed_before = greatest(public.rollup_seals.sealed_before, excluded.sealed_before);

  update public.readings_hourly h set sealed = true
  from public.rollup_seals s
  where s.device_id = h.device_id and h.bucket < s.sealed_before and not h.sealed;

  update public.readings_daily dd set sealed = true
  from public.rollup_seals s
  join public.devices d on d.id = s.device_id
  left join public.plants p on p.id = d.plant_id
  where s.device_id = dd.device_id and not dd.sealed
    and (dd.bucket::timestamp at time zone coalesce(p.timezone, 'UTC')) < s.sealed_before;

  delete from public.readings r using public.rollup_seals s
  where r.device_id = s.device_id and r.recorded_at < s.sealed_before;

  drop table pg_temp.rollup_cuts;
end $$;

revoke all on public.rollup_late_checked from public, anon, authenticated;
revoke all on function public.rollup_count_late(timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.rollup_catch_up(), public.apply_retention() from public, anon, authenticated;
alter table public.rollup_late_checked enable row level security;
