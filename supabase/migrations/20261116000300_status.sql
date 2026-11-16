-- Derived plant status (docs/PLAN.md §5.6, decision D8) and Timeline offline periods (decision D14).
-- Everything here is security invoker: callers see only the plants, devices and readings that RLS lets them see.

-- ---------------------------------------------------------------------------------------------------------------
-- effective_thresholds(plant_id): profile thresholds deep-merged per metric with plants.threshold_overrides.
-- An override replaces only the level keys it names; the other levels of that metric keep the profile values.
-- ---------------------------------------------------------------------------------------------------------------
create function public.effective_thresholds(p_plant_id uuid) returns jsonb
  language sql stable security invoker set search_path = '' as $$
  select coalesce(pg_catalog.jsonb_object_agg(m.metric,
                    coalesce(pr.thresholds -> m.metric, '{}'::jsonb) || coalesce(p.threshold_overrides -> m.metric, '{}'::jsonb)),
                  '{}'::jsonb)
  from public.plants p
  join public.plant_profiles pr on pr.id = p.profile_id
  cross join lateral (select pg_catalog.jsonb_object_keys(pr.thresholds)
                      union
                      select pg_catalog.jsonb_object_keys(p.threshold_overrides)) as m(metric)
  where p.id = p_plant_id
  group by p.id $$;

-- threshold_status(value, bands): < critical_low → critical_low; < low → low; > critical_high → critical_high;
-- > high → high; otherwise ok (values between low and ok_low, or ok_high and high, are ok but never "great").
-- A missing level key never matches. Null value → unknown.
create function public.threshold_status(v double precision, t jsonb) returns text
  language sql immutable parallel safe set search_path = '' as $$
  select case
    when v is null then 'unknown'
    when v < (t ->> 'critical_low')::double precision then 'critical_low'
    when v < (t ->> 'low')::double precision then 'low'
    when v > (t ->> 'critical_high')::double precision then 'critical_high'
    when v > (t ->> 'high')::double precision then 'high'
    else 'ok' end $$;

-- in_middle_half(value, bands): value lies in the middle half of [ok_low, ok_high] (the "great" rule).
create function public.in_middle_half(v double precision, t jsonb) returns boolean
  language sql immutable parallel safe set search_path = '' as $$
  select v between (t ->> 'ok_low')::double precision + ((t ->> 'ok_high')::double precision - (t ->> 'ok_low')::double precision) / 4
               and (t ->> 'ok_high')::double precision - ((t ->> 'ok_high')::double precision - (t ->> 'ok_low')::double precision) / 4 $$;

-- ---------------------------------------------------------------------------------------------------------------
-- plant_status_v: the status pill, one row per plant the caller can see. Rules (thresholds in §2.8):
--   no device or no reading ever → no_data; latest reading > 180 s old or device status 'offline' → offline;
--   temperature / humidity: median of the last 30 min; humidity "high" only if every reading of the last 12 h is
--     above high and those readings cover the 12 h continuously (see "sustained" below);
--   light: daytime (08:00–18:00 in plants.timezone) mean of the last 24 h for the low side; the max 10-min median of
--     the last 24 h for the high side (high side wins when both apply at the same severity);
--   soil: median soil_pct of the last 10 min (same formula as readings_v); unknown while uncalibrated; "high" only if
--     every reading of the last 48 h is above high and those readings cover the 48 h continuously;
--   sustained = first reading within 10 min of the window start, last within 15 min of now, and no gap > 15 min
--     between consecutive readings (an outage gives no evidence for the persistence rules);
--   critical_high (only via overrides for humidity / soil) has no persistence rule;
--   any critical_* → in_trouble; any low/high → needs_attention; all known metrics ok and inside the middle half of
--     their ok band → great; else okay. Unknown metrics never raise severity.
-- Only 'ntp'/'backfilled' readings at or before now() count (a future timestamp never hides an outage).
-- Windows end at now(); computed_at = now().
-- ---------------------------------------------------------------------------------------------------------------
create view public.plant_status_v with (security_invoker = true) as
with base as (
  select p.id as plant_id, d.id as device_id, d.status as device_status, p.timezone,
         (d.soil_dry_raw is not null and d.soil_wet_raw is not null) as soil_calibrated,
         d.soil_dry_raw, d.soil_wet_raw,
         public.effective_thresholds(p.id) as th,
         now() as computed_at
  from public.plants p
  left join public.devices d on d.plant_id = p.id
),
vals as (
  select b.*, lr.latest_reading_at,
         t30.temp_med, t30.hum_med, h12.hum_min, h12.hum_first, h12.hum_last, h12.hum_max_gap,
         l24.light_day_mean, l24.light_max_med,
         s10.soil_med, s48.soil_min, s48.soil_first, s48.soil_last, s48.soil_max_gap
  from base b
  left join lateral (
    select max(r.recorded_at) as latest_reading_at from public.readings r
    where r.device_id = b.device_id and r.clock_source in ('ntp', 'backfilled') and r.recorded_at <= b.computed_at) lr on true
  left join lateral (
    select percentile_cont(0.5) within group (order by r.temperature_c) as temp_med,
           percentile_cont(0.5) within group (order by r.humidity_pct) as hum_med
    from public.readings r
    where r.device_id = b.device_id and r.clock_source in ('ntp', 'backfilled')
      and r.recorded_at > b.computed_at - interval '30 minutes' and r.recorded_at <= b.computed_at) t30 on true
  left join lateral (
    select min(x.humidity_pct) as hum_min, min(x.recorded_at) as hum_first, max(x.recorded_at) as hum_last,
           max(x.gap) as hum_max_gap
    from (select r.humidity_pct, r.recorded_at, r.recorded_at - lag(r.recorded_at) over (order by r.recorded_at) as gap
          from public.readings r
          where r.device_id = b.device_id and r.clock_source in ('ntp', 'backfilled') and r.humidity_pct is not null
            and r.recorded_at > b.computed_at - interval '12 hours' and r.recorded_at <= b.computed_at) x) h12 on true
  left join lateral (
    select avg(q.lux) filter (where q.local_hour between 8 and 17) as light_day_mean,
           (select max(m.med) from (
              select percentile_cont(0.5) within group (order by q2.lux) as med
              from public.readings q2
              where q2.device_id = b.device_id and q2.clock_source in ('ntp', 'backfilled') and q2.lux is not null
                and q2.recorded_at > b.computed_at - interval '24 hours' and q2.recorded_at <= b.computed_at
              group by date_bin('10 minutes', q2.recorded_at, timestamptz '2000-01-01 00:00Z')) m) as light_max_med
    from (select r.lux, extract(hour from r.recorded_at at time zone b.timezone) as local_hour
          from public.readings r
          where r.device_id = b.device_id and r.clock_source in ('ntp', 'backfilled') and r.lux is not null
            and r.recorded_at > b.computed_at - interval '24 hours' and r.recorded_at <= b.computed_at) q) l24 on true
  left join lateral (
    select percentile_cont(0.5) within group (order by public.soil_pct(r.soil_raw, b.soil_dry_raw, b.soil_wet_raw)) as soil_med
    from public.readings r
    where r.device_id = b.device_id and r.clock_source in ('ntp', 'backfilled')
      and r.recorded_at > b.computed_at - interval '10 minutes' and r.recorded_at <= b.computed_at) s10 on true
  left join lateral (
    select min(public.soil_pct(x.soil_raw, b.soil_dry_raw, b.soil_wet_raw)) as soil_min, min(x.recorded_at) as soil_first,
           max(x.recorded_at) as soil_last, max(x.gap) as soil_max_gap
    from (select r.soil_raw, r.recorded_at, r.recorded_at - lag(r.recorded_at) over (order by r.recorded_at) as gap
          from public.readings r
          where r.device_id = b.device_id and r.clock_source in ('ntp', 'backfilled') and r.soil_raw is not null
            and r.recorded_at > b.computed_at - interval '48 hours' and r.recorded_at <= b.computed_at) x) s48 on true
),
st as (
  select v.*,
         public.threshold_status(v.temp_med, v.th -> 'temperature_c') as temperature_status,
         case when public.threshold_status(v.hum_med, v.th -> 'humidity_pct') = 'high'
                   and not (v.hum_min > (v.th #>> '{humidity_pct,high}')::double precision
                            and v.hum_first <= v.computed_at - interval '12 hours' + interval '10 minutes'
                            and v.hum_last >= v.computed_at - interval '15 minutes'
                            and coalesce(v.hum_max_gap, interval '0') <= interval '15 minutes')
              then 'ok'
              else public.threshold_status(v.hum_med, v.th -> 'humidity_pct') end as humidity_status,
         case
           when v.light_max_med > (v.th #>> '{lux,critical_high}')::double precision then 'critical_high'
           when v.light_day_mean < (v.th #>> '{lux,critical_low}')::double precision then 'critical_low'
           when v.light_max_med > (v.th #>> '{lux,high}')::double precision then 'high'
           when v.light_day_mean < (v.th #>> '{lux,low}')::double precision then 'low'
           when v.light_day_mean is not null then 'ok'
           else 'unknown' end as light_status,
         case
           when not coalesce(v.soil_calibrated, false) then 'unknown'
           when public.threshold_status(v.soil_med, v.th -> 'soil_pct') = 'high'
                and not (v.soil_min > (v.th #>> '{soil_pct,high}')::double precision
                         and v.soil_first <= v.computed_at - interval '48 hours' + interval '10 minutes'
                         and v.soil_last >= v.computed_at - interval '15 minutes'
                         and coalesce(v.soil_max_gap, interval '0') <= interval '15 minutes')
             then 'ok'
           else public.threshold_status(v.soil_med, v.th -> 'soil_pct') end as soil_status
  from vals v
),
iss as (
  select s.*,
         array(select i.metric from (values
                 ('soil', s.soil_status, 1), ('temperature', s.temperature_status, 2),
                 ('humidity', s.humidity_status, 3), ('light', s.light_status, 4)) as i(metric, status, ord)
               where i.status not in ('ok', 'unknown')
               order by (i.status like 'critical%') desc, i.ord) as issues,
         (select bool_and(g.great) and count(*) > 0 from (values
            (s.temperature_status, public.in_middle_half(s.temp_med, s.th -> 'temperature_c')),
            (s.humidity_status, public.in_middle_half(s.hum_med, s.th -> 'humidity_pct')),
            (s.light_status, public.in_middle_half(s.light_day_mean, s.th -> 'lux')),
            (s.soil_status, public.in_middle_half(s.soil_med, s.th -> 'soil_pct'))) as g(status, great)
          where g.status <> 'unknown') as all_great
  from st s
),
ov as (
  select i.*,
         case
           when i.device_id is null or i.latest_reading_at is null then 'no_data'
           when i.latest_reading_at < i.computed_at - interval '180 seconds' or i.device_status = 'offline' then 'offline'
           when 'critical_low' in (i.temperature_status, i.humidity_status, i.light_status, i.soil_status)
             or 'critical_high' in (i.temperature_status, i.humidity_status, i.light_status, i.soil_status) then 'in_trouble'
           when cardinality(i.issues) > 0 then 'needs_attention'
           when coalesce(i.all_great, false) then 'great'
           else 'okay' end as overall
  from iss i
)
select o.plant_id, o.device_id, o.latest_reading_at, o.device_status, coalesce(o.soil_calibrated, false) as soil_calibrated,
       o.temperature_status, o.humidity_status, o.light_status, o.soil_status,
       case o.temperature_status when 'critical_low' then 'Too cold' when 'low' then 'A bit cold'
         when 'ok' then 'Just right' when 'high' then 'A bit warm' when 'critical_high' then 'Too hot'
         else 'No data' end as temperature_label,
       case o.humidity_status when 'critical_low' then 'Air too dry' when 'low' then 'Air a bit dry'
         when 'ok' then 'Just right' when 'high' then 'Too humid' when 'critical_high' then 'Too humid'
         else 'No data' end as humidity_label,
       case o.light_status when 'critical_low' then 'Too dark' when 'low' then 'Needs more light'
         when 'ok' then 'Just right' when 'high' then 'Too bright' when 'critical_high' then 'Scorching sun'
         else 'No data' end as light_label,
       case o.soil_status when 'critical_low' then 'Too dry' when 'low' then 'Getting dry'
         when 'ok' then 'Just right' when 'high' then 'Too wet' when 'critical_high' then 'Too wet'
         else case when coalesce(o.soil_calibrated, false) then 'No data' else 'Not calibrated' end end as soil_label,
       o.issues,
       o.overall,
       case o.overall when 'great' then 'Feeling great' when 'okay' then 'Doing okay'
         when 'needs_attention' then 'Needs attention' when 'in_trouble' then 'In trouble'
         when 'offline' then 'Offline' else 'No data yet' end as overall_label,
       case
         when o.overall = 'no_data' then 'Waiting for the first reading'
         when o.overall = 'offline' then 'No recent readings — check the sensor''s power and Wi-Fi'
         when cardinality(o.issues) = 0 then
           case when not coalesce(o.soil_calibrated, false) then 'All good — calibrate the soil sensor to track watering'
                when o.overall = 'great' then 'All good — I''m feeling great'
                else 'Everything is within range' end
         else case o.issues[1] || ':' || case o.issues[1] when 'soil' then o.soil_status
                                                          when 'temperature' then o.temperature_status
                                                          when 'humidity' then o.humidity_status
                                                          else o.light_status end
           when 'soil:critical_low' then 'Soil is very dry — water now'
           when 'soil:low' then 'Soil is getting dry — water soon'
           when 'soil:high' then 'Soil has been soggy for 2 days — hold off watering'
           when 'soil:critical_high' then 'Soil is waterlogged — stop watering and let it drain'
           when 'temperature:critical_low' then 'It''s far too cold — move somewhere warmer now'
           when 'temperature:low' then 'It''s a bit cold — keep away from drafts'
           when 'temperature:high' then 'It''s a bit warm — move somewhere cooler'
           when 'temperature:critical_high' then 'It''s far too hot — move out of the heat now'
           when 'humidity:critical_low' then 'The air is very dry — mist the leaves or use a humidifier'
           when 'humidity:low' then 'The air is a bit dry — leaf tips may brown'
           when 'humidity:high' then 'The air has been very humid for 12 hours — improve airflow'
           when 'humidity:critical_high' then 'The air is far too humid — improve airflow now'
           when 'light:critical_low' then 'Far too dark — move closer to a window'
           when 'light:low' then 'Could use more light — try a brighter spot'
           when 'light:high' then 'Getting direct sun — move out of the sun'
           when 'light:critical_high' then 'Strong direct sun — move now to avoid scorched leaves'
           end
         end as summary,
       o.computed_at
from ov o;

-- ---------------------------------------------------------------------------------------------------------------
-- device_offline_periods: Timeline offline periods from gaps > 180 s between consecutive raw readings (D14).
-- Uses the readings in [p_from, p_to] plus the last one before p_from and the first one after p_to, so gaps that
-- cross the window edges are clipped to it (a gap across midnight appears in both days). A gap yields
-- (prev + 60 s, next); cause is device_restart when boot_id changed across it. The trailing gap from the last
-- reading is ongoing when now() is more than 180 s after that reading; it ends at least(now(), p_to) and is clipped
-- like any other gap, so an outage that began just before p_to still shows in that window. Only 'ntp'/'backfilled' rows. Window ≤ 7 days. Security invoker, so a
-- device the caller cannot see has no readings and returns nothing; so does a window beyond the 90-day retention.
-- ---------------------------------------------------------------------------------------------------------------
create function public.device_offline_periods(p_device_id text, p_from timestamptz, p_to timestamptz)
  returns table (started_at timestamptz, ended_at timestamptz, duration_s integer, cause text, ongoing boolean)
  language plpgsql stable security invoker set search_path = '' as $$
begin
  if p_device_id is null or p_from is null or p_to is null or p_to < p_from then
    raise exception 'invalid window' using errcode = '22023';
  end if;
  if p_to - p_from > interval '7 days' then
    raise exception 'window longer than 7 days' using errcode = '22023';
  end if;
  return query
  with pts as (
    (select r.recorded_at, r.boot_id from public.readings r
     where r.device_id = p_device_id and r.clock_source in ('ntp', 'backfilled') and r.recorded_at < p_from
     order by r.recorded_at desc limit 1)
    union all
    (select r.recorded_at, r.boot_id from public.readings r
     where r.device_id = p_device_id and r.clock_source in ('ntp', 'backfilled')
       and r.recorded_at between p_from and p_to)
    union all
    (select r.recorded_at, r.boot_id from public.readings r
     where r.device_id = p_device_id and r.clock_source in ('ntp', 'backfilled') and r.recorded_at > p_to
     order by r.recorded_at asc limit 1)
  ),
  seq as (
    select p.recorded_at, p.boot_id,
           lag(p.recorded_at) over w as prev_at, lag(p.boot_id) over w as prev_boot,
           lead(p.recorded_at) over w as next_at
    from pts p window w as (order by p.recorded_at)
  ),
  gaps as (
    select s.prev_at + interval '60 seconds' as g_start, s.recorded_at as g_end,
           case when s.boot_id <> s.prev_boot then 'device_restart' else 'no_data' end as g_cause, false as g_ongoing
    from seq s
    where s.prev_at is not null and s.recorded_at - s.prev_at > interval '180 seconds'
    union all
    select s.recorded_at + interval '60 seconds', least(now(), p_to), 'no_data', true
    from seq s
    where s.next_at is null and now() - s.recorded_at > interval '180 seconds'
  )
  select greatest(g.g_start, p_from), least(g.g_end, p_to),
         extract(epoch from least(g.g_end, p_to) - greatest(g.g_start, p_from))::integer,
         g.g_cause, g.g_ongoing
  from gaps g
  where greatest(g.g_start, p_from) < least(g.g_end, p_to)
  order by 1;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- Grants: nothing to anon; the helpers are executable by the roles that read the view (security invoker).
-- ---------------------------------------------------------------------------------------------------------------
revoke all on public.plant_status_v from public, anon, authenticated;
revoke all on function public.effective_thresholds(uuid), public.threshold_status(double precision, jsonb),
  public.in_middle_half(double precision, jsonb), public.device_offline_periods(text, timestamptz, timestamptz)
  from public, anon;
grant select on public.plant_status_v to authenticated, service_role;
grant execute on function public.effective_thresholds(uuid), public.threshold_status(double precision, jsonb),
  public.in_middle_half(double precision, jsonb) to authenticated, service_role;
grant execute on function public.device_offline_periods(text, timestamptz, timestamptz) to authenticated, service_role;
