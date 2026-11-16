-- Rollups & retention (docs/PLAN.md §5.6, D11, D15, D18, D19): hourly/daily summary tables + soil-% views,
-- a watermark-driven refresh_rollups(), apply_retention() (catch up, seal, delete raw older than 90 days),
-- manual repair functions, the timezone-change rebuild trigger and the pg_cron schedule.
--
-- All rollup writers serialise on one transaction-level advisory lock (key 727001):
--   refresh_rollups()            try-lock: an overlapping cron run simply exits
--   apply_retention(), rebuild_rollups(), rebuild_daily_for_timezone()   wait for the lock

create extension if not exists pg_cron with schema pg_catalog;

-- ---------------------------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------------------------
create table public.readings_hourly (
  device_id text not null references public.devices(id) on delete cascade,
  bucket timestamptz not null,                                  -- UTC hour
  n integer not null,                                           -- readings in the bucket (coverage)
  -- per-metric non-null sample counts: SQL aggregates skip nulls, so each metric is weighted by its own n
  temperature_c_n integer not null, temperature_c_avg real, temperature_c_min real, temperature_c_max real,
  humidity_pct_n  integer not null, humidity_pct_avg real,  humidity_pct_min real,  humidity_pct_max real,
  lux_n           integer not null, lux_avg real, lux_min real, lux_max real,
  soil_raw_n      integer not null, soil_raw_avg real, soil_raw_min smallint, soil_raw_max smallint,
  -- exact soil_raw distribution (distinct value → count), so soil % can be averaged AFTER per-sample clamping
  -- under the CURRENT calibration
  soil_raw_values smallint[] not null default '{}',             -- distinct soil_raw values, ascending
  soil_raw_counts integer[]  not null default '{}',             -- same length; sum = soil_raw_n
  sealed boolean not null default false,                         -- true once raw rows may be gone; never recomputed
  primary key (device_id, bucket),
  check (cardinality(soil_raw_values) = cardinality(soil_raw_counts))
);

-- Same columns; bucket = local date in plants.timezone (UTC if the device has no plant). Unsealed daily rows are
-- computed DIRECTLY FROM RAW readings of that local date (exact for any offset, incl. :30/:45). Combining hourly
-- rows elsewhere must use sum(<m>_avg * <m>_n) / nullif(sum(<m>_n), 0), never the total n.
create table public.readings_daily (
  device_id text not null references public.devices(id) on delete cascade,
  bucket date not null,
  n integer not null,
  temperature_c_n integer not null, temperature_c_avg real, temperature_c_min real, temperature_c_max real,
  humidity_pct_n  integer not null, humidity_pct_avg real,  humidity_pct_min real,  humidity_pct_max real,
  lux_n           integer not null, lux_avg real, lux_min real, lux_max real,
  soil_raw_n      integer not null, soil_raw_avg real, soil_raw_min smallint, soil_raw_max smallint,
  soil_raw_values smallint[] not null default '{}',
  soil_raw_counts integer[]  not null default '{}',
  sealed boolean not null default false,
  primary key (device_id, bucket),
  check (cardinality(soil_raw_values) = cardinality(soil_raw_counts))
);

-- persisted watermark: the job resumes from where it last succeeded, however long it was down
create table public.rollup_state (
  id boolean primary key default true check (id),              -- single row
  processed_until timestamptz not null default '-infinity'
);
insert into public.rollup_state (id) values (true);

-- archival boundary per device: raw rows before sealed_before may be deleted. Sealing is also recorded on the rollup
-- row (`sealed = true`), set by apply_retention() for every bucket that starts before the cut in the timezone in
-- force at that moment. Sealed rows are never updated or deleted by any rollup function.
create table public.rollup_seals (
  device_id text primary key references public.devices(id) on delete cascade,
  sealed_before timestamptz not null,                            -- hour-aligned; never moves backwards
  late_rows_ignored bigint not null default 0                    -- late arrivals that fell into sealed buckets
);

-- ---------------------------------------------------------------------------------------------------------------
-- Soil % of a bucket, exactly equal to the mean of the per-reading readings_v.soil_pct values
-- ---------------------------------------------------------------------------------------------------------------
create function public.soil_pct_avg(vals smallint[], cnts integer[], dry_raw integer, wet_raw integer) returns real
  language sql immutable parallel safe set search_path = '' as $$
  select (sum(public.soil_pct(v, dry_raw, wet_raw)::double precision * c) / nullif(sum(c), 0))::real
  from unnest(vals, cnts) as t(v, c) $$;

-- soil_pct_min = soil_pct(soil_raw_max), soil_pct_max = soil_pct(soil_raw_min): higher raw = drier, and clamping is
-- monotone, so the inverted extremes are exact.
create view public.readings_hourly_v with (security_invoker = true) as
  select h.*,
         public.soil_pct_avg(h.soil_raw_values, h.soil_raw_counts, d.soil_dry_raw, d.soil_wet_raw) as soil_pct_avg,
         public.soil_pct(h.soil_raw_max, d.soil_dry_raw, d.soil_wet_raw) as soil_pct_min,
         public.soil_pct(h.soil_raw_min, d.soil_dry_raw, d.soil_wet_raw) as soil_pct_max
  from public.readings_hourly h join public.devices d on d.id = h.device_id;

create view public.readings_daily_v with (security_invoker = true) as
  select h.*,
         public.soil_pct_avg(h.soil_raw_values, h.soil_raw_counts, d.soil_dry_raw, d.soil_wet_raw) as soil_pct_avg,
         public.soil_pct(h.soil_raw_max, d.soil_dry_raw, d.soil_wet_raw) as soil_pct_min,
         public.soil_pct(h.soil_raw_min, d.soil_dry_raw, d.soil_wet_raw) as soil_pct_max
  from public.readings_daily h join public.devices d on d.id = h.device_id;

-- ---------------------------------------------------------------------------------------------------------------
-- Internal helpers (owner only; called from the security definer entry points below)
-- ---------------------------------------------------------------------------------------------------------------

-- Summaries of raw readings for the half-open ranges [start, end) of each (device, start, end) key. Keys with no
-- raw rows produce no output row.
create function public.rollup_aggregate(p_device_ids text[], p_starts timestamptz[], p_ends timestamptz[])
  returns table (device_id text, bucket_start timestamptz, n integer,
                 temperature_c_n integer, temperature_c_avg real, temperature_c_min real, temperature_c_max real,
                 humidity_pct_n integer, humidity_pct_avg real, humidity_pct_min real, humidity_pct_max real,
                 lux_n integer, lux_avg real, lux_min real, lux_max real,
                 soil_raw_n integer, soil_raw_avg real, soil_raw_min smallint, soil_raw_max smallint,
                 soil_raw_values smallint[], soil_raw_counts integer[])
  language sql stable set search_path = '' as $$
  with k as (
    select distinct t.dev, t.s, t.e from unnest(p_device_ids, p_starts, p_ends) as t(dev, s, e)
  ), dist as (
    select k.dev, k.s, r.soil_raw as v, count(*)::integer as c
    from k join public.readings r on r.device_id = k.dev and r.recorded_at >= k.s and r.recorded_at < k.e
    where r.soil_raw is not null
    group by k.dev, k.s, r.soil_raw
  ), soil as (
    select dist.dev, dist.s, array_agg(dist.v order by dist.v) as vals, array_agg(dist.c order by dist.v) as cnts
    from dist group by dist.dev, dist.s
  )
  select k.dev, k.s, count(*)::integer,
         count(r.temperature_c)::integer, avg(r.temperature_c)::real, min(r.temperature_c), max(r.temperature_c),
         count(r.humidity_pct)::integer, avg(r.humidity_pct)::real, min(r.humidity_pct), max(r.humidity_pct),
         count(r.lux)::integer, avg(r.lux)::real, min(r.lux), max(r.lux),
         count(r.soil_raw)::integer, avg(r.soil_raw)::real, min(r.soil_raw), max(r.soil_raw),
         coalesce(soil.vals, '{}'), coalesce(soil.cnts, '{}')
  from k
  join public.readings r on r.device_id = k.dev and r.recorded_at >= k.s and r.recorded_at < k.e
  left join soil on soil.dev = k.dev and soil.s = k.s
  group by k.dev, k.s, soil.vals, soil.cnts $$;

-- Recompute the given hourly buckets from raw. Buckets that are sealed, or start before the device's
-- sealed_before, are skipped (a sealed summary is never replaced by one built from partially deleted raw rows).
-- Returns the number of distinct keys skipped.
create function public.rollup_write_hourly(p_device_ids text[], p_buckets timestamptz[]) returns integer
  language plpgsql set search_path = '' as $$
declare
  v_total integer;
  v_dev text[];
  v_s timestamptz[];
  v_e timestamptz[];
begin
  select count(*)::integer,
         coalesce(array_agg(k.dev) filter (where k.ok), '{}'),
         coalesce(array_agg(k.b) filter (where k.ok), '{}'),
         coalesce(array_agg(k.b + interval '1 hour') filter (where k.ok), '{}')
    into v_total, v_dev, v_s, v_e
  from (
    select t.dev, t.b,
           t.b >= coalesce(s.sealed_before, '-infinity') and not coalesce(h.sealed, false) as ok
    from (select distinct u.dev, u.b from unnest(p_device_ids, p_buckets) as u(dev, b)) t
    left join public.rollup_seals s on s.device_id = t.dev
    left join public.readings_hourly h on h.device_id = t.dev and h.bucket = t.b
  ) k;

  delete from public.readings_hourly h using unnest(v_dev, v_s) as k(dev, b)
  where h.device_id = k.dev and h.bucket = k.b and not h.sealed;

  insert into public.readings_hourly (device_id, bucket, n,
    temperature_c_n, temperature_c_avg, temperature_c_min, temperature_c_max,
    humidity_pct_n, humidity_pct_avg, humidity_pct_min, humidity_pct_max,
    lux_n, lux_avg, lux_min, lux_max,
    soil_raw_n, soil_raw_avg, soil_raw_min, soil_raw_max, soil_raw_values, soil_raw_counts)
  select a.* from public.rollup_aggregate(v_dev, v_s, v_e) a;

  return v_total - cardinality(v_dev);
end $$;

-- Recompute the given daily buckets (local dates in each device's current plant timezone) from raw. Same skip
-- rule as hourly, with the local midnight compared against sealed_before. Returns the number of keys skipped.
create function public.rollup_write_daily(p_device_ids text[], p_days date[]) returns integer
  language plpgsql set search_path = '' as $$
declare
  v_total integer;
  v_dev text[];
  v_day date[];
  v_s timestamptz[];
  v_e timestamptz[];
begin
  select count(*)::integer,
         coalesce(array_agg(k.dev) filter (where k.ok), '{}'),
         coalesce(array_agg(k.day) filter (where k.ok), '{}'),
         coalesce(array_agg(k.s) filter (where k.ok), '{}'),
         coalesce(array_agg(k.e) filter (where k.ok), '{}')
    into v_total, v_dev, v_day, v_s, v_e
  from (
    select t.dev, t.day, w.s, w.e,
           w.s >= coalesce(s.sealed_before, '-infinity') and not coalesce(dd.sealed, false) as ok
    from (select distinct u.dev, u.day from unnest(p_device_ids, p_days) as u(dev, day)) t
    left join public.devices d on d.id = t.dev
    left join public.plants p on p.id = d.plant_id
    cross join lateral (
      select t.day::timestamp at time zone coalesce(p.timezone, 'UTC') as s,
             (t.day + 1)::timestamp at time zone coalesce(p.timezone, 'UTC') as e
    ) w
    left join public.rollup_seals s on s.device_id = t.dev
    left join public.readings_daily dd on dd.device_id = t.dev and dd.bucket = t.day
  ) k;

  delete from public.readings_daily dd using unnest(v_dev, v_day) as k(dev, day)
  where dd.device_id = k.dev and dd.bucket = k.day and not dd.sealed;

  insert into public.readings_daily (device_id, bucket, n,
    temperature_c_n, temperature_c_avg, temperature_c_min, temperature_c_max,
    humidity_pct_n, humidity_pct_avg, humidity_pct_min, humidity_pct_max,
    lux_n, lux_avg, lux_min, lux_max,
    soil_raw_n, soil_raw_avg, soil_raw_min, soil_raw_max, soil_raw_values, soil_raw_counts)
  select k.dev, k.day, a.n,
         a.temperature_c_n, a.temperature_c_avg, a.temperature_c_min, a.temperature_c_max,
         a.humidity_pct_n, a.humidity_pct_avg, a.humidity_pct_min, a.humidity_pct_max,
         a.lux_n, a.lux_avg, a.lux_min, a.lux_max,
         a.soil_raw_n, a.soil_raw_avg, a.soil_raw_min, a.soil_raw_max, a.soil_raw_values, a.soil_raw_counts
  from unnest(v_dev, v_day, v_s) as k(dev, day, s)
  join public.rollup_aggregate(v_dev, v_s, v_e) a on a.device_id = k.dev and a.bucket_start = k.s;

  return v_total - cardinality(v_dev);
end $$;

-- The watermark step shared by refresh_rollups() and apply_retention(). Caller holds the advisory lock.
create function public.rollup_catch_up() returns void
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

  -- Late arrivals into sealed buckets are dropped and counted. Only rows new since the last run are counted, so the
  -- overlap window never counts a row twice.
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
    where r.received_at > v_prev and r.received_at <= v_hi
      and (x.hour < s2.sealed_before
           or (x.day::timestamp at time zone coalesce(p.timezone, 'UTC')) < s2.sealed_before
           or exists (select 1 from public.readings_hourly h
                      where h.device_id = r.device_id and h.bucket = x.hour and h.sealed)
           or exists (select 1 from public.readings_daily dd
                      where dd.device_id = r.device_id and dd.bucket = x.day and dd.sealed))
    group by r.device_id
  ) l
  where s.device_id = l.device_id;

  -- touched hourly buckets
  select coalesce(array_agg(t.device_id), '{}'), coalesce(array_agg(t.hour), '{}') into v_dev, v_hours
  from (select distinct r.device_id, date_trunc('hour', r.recorded_at, 'UTC') as hour
        from public.readings r where r.received_at > v_lo and r.received_at <= v_hi) t;
  perform public.rollup_write_hourly(v_dev, v_hours);

  -- touched local days
  select coalesce(array_agg(t.device_id), '{}'), coalesce(array_agg(t.day), '{}') into v_dev, v_days
  from (select distinct r.device_id, (r.recorded_at at time zone coalesce(p.timezone, 'UTC'))::date as day
        from public.readings r
        join public.devices d on d.id = r.device_id
        left join public.plants p on p.id = d.plant_id
        where r.received_at > v_lo and r.received_at <= v_hi) t;
  perform public.rollup_write_daily(v_dev, v_days);

  update public.rollup_state set processed_until = greatest(v_prev, v_hi) where id;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------------------------------------------

-- Hourly cron job. All-or-nothing: the recompute and the watermark advance commit together.
create function public.refresh_rollups() returns void
  language plpgsql security definer set search_path = '' as $$
begin
  if not pg_catalog.pg_try_advisory_xact_lock(727001) then
    raise notice 'refresh_rollups: another rollup run holds the lock; exiting';
    return;
  end if;
  perform public.rollup_catch_up();
end $$;

-- Daily cron job, one transaction:
-- 1. lock readings against concurrent inserts (SHARE ROW EXCLUSIVE: waits for in-flight uploads to commit, blocks
--    new ones until we commit), so every statement below sees the same raw rows and nothing can be deleted
--    without having been summarised;
-- 2. normal watermark catch-up;
-- 3. recompute, straight from raw and regardless of received_at, every unsealed bucket that is about to be sealed
--    (the watermark's 2-minute lag would otherwise miss rows received just now);
-- 4. advance rollup_seals.sealed_before (never backwards), mark buckets sealed, delete raw rows before it.
-- cut = local midnight (plant tz, UTC if none) of (local today - 90 days), floored to the UTC hour, so no hourly
-- bucket straddles it; a local day straddling it starts before it and is therefore sealed too.
create function public.apply_retention() returns void
  language plpgsql security definer set search_path = '' as $$
declare
  v_dev text[];
  v_hours timestamptz[];
  v_days date[];
begin
  perform pg_catalog.pg_advisory_xact_lock(727001);
  perform pg_catalog.set_config('lock_timeout', '60s', true);
  lock table public.readings in share row exclusive mode;

  perform public.rollup_catch_up();

  create temporary table rollup_cuts on commit drop as
  select d.id as device_id, x.tz, s.sealed_before as old_sealed_before,
         date_trunc('hour', ((now() at time zone x.tz)::date - 90)::timestamp at time zone x.tz, 'UTC') as cut
  from public.devices d
  left join public.plants p on p.id = d.plant_id
  cross join lateral (select coalesce(p.timezone, 'UTC') as tz) x
  left join public.rollup_seals s on s.device_id = d.id;

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

-- Manual repair: recompute every hourly bucket and local day overlapping [p_from, p_to) from raw. Sealed buckets and
-- buckets starting before sealed_before are skipped and reported in a NOTICE, never raised.
create function public.rebuild_rollups(p_device_id text, p_from timestamptz, p_to timestamptz) returns void
  language plpgsql security definer set search_path = '' as $$
declare
  v_tz text;
  v_hours timestamptz[];
  v_days date[];
  v_skipped_h integer;
  v_skipped_d integer;
begin
  if p_to <= p_from then
    return;
  end if;
  perform pg_catalog.pg_advisory_xact_lock(727001);

  select coalesce(p.timezone, 'UTC') into v_tz
  from public.devices d left join public.plants p on p.id = d.plant_id where d.id = p_device_id;
  v_tz := coalesce(v_tz, 'UTC');

  select array_agg(g) into v_hours
  from generate_series(date_trunc('hour', p_from, 'UTC'), p_to - interval '1 microsecond', interval '1 hour') g;
  select array_agg(g::date) into v_days
  from generate_series((p_from at time zone v_tz)::date::timestamp,
                       ((p_to - interval '1 microsecond') at time zone v_tz)::date::timestamp, interval '1 day') g;

  v_skipped_h := public.rollup_write_hourly(array_fill(p_device_id, array[cardinality(v_hours)]), v_hours);
  v_skipped_d := public.rollup_write_daily(array_fill(p_device_id, array[cardinality(v_days)]), v_days);
  if v_skipped_h + v_skipped_d > 0 then
    raise notice 'rebuild_rollups: skipped % sealed hourly and % sealed daily bucket(s)', v_skipped_h, v_skipped_d;
  end if;
end $$;

-- Rebuild a device's daily rows after its plant's timezone changed. Sealed rows (incl. the old-timezone boundary
-- day) are preserved untouched; unsealed rows are rebuilt from raw for new-timezone local dates >= d0, the first
-- local date whose midnight is >= sealed_before and after every sealed daily row. The boundary period between
-- sealed_before and d0's midnight (< 24 h) gets no daily row; its hourly rows still cover it.
create function public.rebuild_daily_for_timezone(p_device_id text) returns void
  language plpgsql security definer set search_path = '' as $$
declare
  v_tz text;
  v_sb timestamptz;
  v_d0 date := '-infinity';
  v_days date[];
begin
  perform pg_catalog.pg_advisory_xact_lock(727001);

  select coalesce(p.timezone, 'UTC') into v_tz
  from public.devices d left join public.plants p on p.id = d.plant_id where d.id = p_device_id;
  v_tz := coalesce(v_tz, 'UTC');
  select s.sealed_before into v_sb from public.rollup_seals s where s.device_id = p_device_id;

  if v_sb is not null then
    v_d0 := (v_sb at time zone v_tz)::date;
    if (v_d0::timestamp at time zone v_tz) < v_sb then
      v_d0 := v_d0 + 1;
    end if;
    v_d0 := greatest(v_d0, (select max(dd.bucket) + 1 from public.readings_daily dd
                            where dd.device_id = p_device_id and dd.sealed));
  end if;

  delete from public.readings_daily dd where dd.device_id = p_device_id and not dd.sealed;

  select coalesce(array_agg(t.day), '{}') into v_days
  from (select distinct (r.recorded_at at time zone v_tz)::date as day
        from public.readings r
        where r.device_id = p_device_id and r.recorded_at >= coalesce(v_sb, '-infinity')) t
  where t.day >= v_d0;
  perform public.rollup_write_daily(array_fill(p_device_id, array[cardinality(v_days)]), v_days);
end $$;

create function public.plants_timezone_rebuild_daily() returns trigger
  language plpgsql security definer set search_path = '' as $$
declare
  v_dev text;
begin
  if new.timezone is distinct from old.timezone then
    for v_dev in select d.id from public.devices d where d.plant_id = new.id loop
      perform public.rebuild_daily_for_timezone(v_dev);
    end loop;
  end if;
  return null;
end $$;
-- AFTER the core BEFORE trigger plants_validate_timezone, so only valid zones get here
create trigger plants_timezone_rebuild_daily after update of timezone on public.plants
  for each row execute function public.plants_timezone_rebuild_daily();

-- ---------------------------------------------------------------------------------------------------------------
-- Grants (explicit, as in core) and RLS
-- ---------------------------------------------------------------------------------------------------------------
revoke all on public.readings_hourly, public.readings_daily, public.readings_hourly_v, public.readings_daily_v,
  public.rollup_state, public.rollup_seals from public, anon, authenticated;
revoke all on function
  public.rollup_aggregate(text[], timestamptz[], timestamptz[]),
  public.rollup_write_hourly(text[], timestamptz[]),
  public.rollup_write_daily(text[], date[]),
  public.rollup_catch_up(),
  public.refresh_rollups(),
  public.apply_retention(),
  public.rebuild_rollups(text, timestamptz, timestamptz),
  public.rebuild_daily_for_timezone(text),
  public.plants_timezone_rebuild_daily()
  from public, anon, authenticated;
revoke all on function public.soil_pct_avg(smallint[], integer[], integer, integer) from public, anon;

grant select on public.readings_hourly, public.readings_daily, public.readings_hourly_v, public.readings_daily_v
  to authenticated;
grant select, insert, update, delete on public.readings_hourly, public.readings_daily to service_role;
grant select on public.readings_hourly_v, public.readings_daily_v, public.rollup_state, public.rollup_seals
  to service_role;
grant execute on function public.soil_pct_avg(smallint[], integer[], integer, integer) to authenticated, service_role;

alter table public.readings_hourly enable row level security;
alter table public.readings_daily enable row level security;
alter table public.rollup_state enable row level security;
alter table public.rollup_seals enable row level security;

create policy readings_hourly_read on public.readings_hourly for select to authenticated
  using (device_id in (select d.id from public.devices d where d.owner_id = (select auth.uid())));
create policy readings_daily_read on public.readings_daily for select to authenticated
  using (device_id in (select d.id from public.devices d where d.owner_id = (select auth.uid())));

-- ---------------------------------------------------------------------------------------------------------------
-- Schedule (cron.schedule upserts by job name, so re-running is safe)
-- Late-arrival policy: a reading whose bucket is already sealed (recorded > ~90 d ago) is inserted, is ignored by
-- rollups (counted in late_rows_ignored), and is deleted by the next retention run. The gateway also dead-letters
-- outbox rows whose recorded_at is older than 89 days ("beyond_retention") instead of uploading them.
-- ---------------------------------------------------------------------------------------------------------------
select cron.schedule('olvar-rollups',   '5 * * * *',  $$select public.refresh_rollups()$$);
select cron.schedule('olvar-retention', '30 3 * * *', $$select public.apply_retention()$$);
