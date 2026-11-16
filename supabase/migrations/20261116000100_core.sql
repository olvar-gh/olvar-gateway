-- Core schema (docs/PLAN.md §5.6): plant profiles, plants, devices, readings, gateways, soil_pct(), readings_v,
-- explicit grants (no automatic Data API exposure since the 2026 default-privileges change), RLS, Realtime.

-- ---------------------------------------------------------------------------------------------------------------
-- Threshold override validation (used by a CHECK on plants.threshold_overrides).
-- Accepts an object of known metrics → object of known level keys → JSON numbers, in non-decreasing order
-- critical_low ≤ low ≤ ok_low ≤ ok_high ≤ high ≤ critical_high (only the keys present are compared).
-- ---------------------------------------------------------------------------------------------------------------
create function public.valid_threshold_overrides(o jsonb) returns boolean
  language plpgsql immutable parallel safe set search_path = '' as $$
declare
  levels constant text[] := array['critical_low', 'low', 'ok_low', 'ok_high', 'high', 'critical_high'];
  metric text;
  bands jsonb;
  lvl text;
  prev numeric;
  cur numeric;
begin
  if o is null then
    return true;                                    -- nullability is enforced by NOT NULL, not here
  end if;
  if pg_catalog.jsonb_typeof(o) <> 'object' then
    return false;
  end if;
  for metric, bands in select e.key, e.value from pg_catalog.jsonb_each(o) as e loop
    if metric not in ('temperature_c', 'humidity_pct', 'lux', 'soil_pct') then
      return false;
    end if;
    if pg_catalog.jsonb_typeof(bands) <> 'object' then
      return false;
    end if;
    if exists (select 1 from pg_catalog.jsonb_object_keys(bands) as k(key) where k.key <> all (levels)) then
      return false;
    end if;
    prev := null;
    foreach lvl in array levels loop
      if bands ? lvl then
        if pg_catalog.jsonb_typeof(bands -> lvl) <> 'number' then
          return false;
        end if;
        cur := (bands ->> lvl)::numeric;
        if prev is not null and cur < prev then
          return false;
        end if;
        prev := cur;
      end if;
    end loop;
  end loop;
  return true;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------------------------
create table public.plant_profiles (
  id text primary key,                          -- 'spathiphyllum'
  common_name text not null,
  scientific_name text not null,
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
  timezone text not null default 'UTC',         -- IANA; validated by trigger plants_validate_timezone (below)
  threshold_overrides jsonb not null default '{}'
    check (public.valid_threshold_overrides(threshold_overrides)),
  created_at timestamptz not null default now()
);
create index plants_owner_idx on public.plants (owner_id);

-- timezone must be a real IANA zone name known to this Postgres (rejects typos like 'Asia/Seol' and POSIX
-- strings like 'UTC+3' that "at time zone" would silently accept). A trigger rather than a CHECK, because
-- pg_timezone_names is not immutable. The dashboard shows error 22023 as "Unknown timezone".
create function public.validate_plant_timezone() returns trigger
  language plpgsql set search_path = '' as $$
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = new.timezone) then
    raise exception 'unknown timezone: %', new.timezone using errcode = '22023';   -- invalid_parameter_value
  end if;
  return new;
end $$;
create trigger plants_validate_timezone before insert or update of timezone on public.plants
  for each row execute function public.validate_plant_timezone();

create table public.devices (
  id text primary key check (id ~ '^[a-z0-9][a-z0-9-]{2,31}$' and id <> 'olvar-gateway'),
  owner_id uuid references auth.users(id) on delete set null,
  plant_id uuid unique references public.plants(id) on delete set null,   -- v1: one device per plant
  fw text,
  status text not null default 'unknown' check (status in ('online', 'offline', 'unknown')),
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
  clock_source text not null default 'ntp' check (clock_source in ('ntp', 'backfilled', 'unsynced')),
  constraint readings_dedup unique (device_id, boot_id, seq)
);
create index readings_device_time_idx on public.readings (device_id, recorded_at desc);
create index readings_received_idx on public.readings (received_at);

create table public.gateways (
  id text primary key,
  owner_id uuid references auth.users(id) on delete set null,
  version text,
  buffer_depth integer,
  last_seen_at timestamptz not null default now()
);
create index gateways_owner_idx on public.gateways (owner_id);

-- ---------------------------------------------------------------------------------------------------------------
-- soil_pct: one formula, used by every view; higher raw = drier. Null until calibrated; clamped to 0–100.
-- ---------------------------------------------------------------------------------------------------------------
create function public.soil_pct(raw numeric, dry_raw integer, wet_raw integer) returns real
  language sql immutable parallel safe set search_path = '' as $$
  select case when raw is null or dry_raw is null or wet_raw is null then null
              else greatest(0, least(100, round(((dry_raw - raw) * 100.0 / (dry_raw - wet_raw))::numeric, 1)))::real end $$;

create view public.readings_v with (security_invoker = true) as
  select r.*, public.soil_pct(r.soil_raw, d.soil_dry_raw, d.soil_wet_raw) as soil_pct
  from public.readings r join public.devices d on d.id = r.device_id;

-- ---------------------------------------------------------------------------------------------------------------
-- Grants. Start from nothing, so a project that still has the old default privileges ends up identical to a new
-- one: anon gets nothing, authenticated gets read + the column-level updates the dashboard needs.
-- ---------------------------------------------------------------------------------------------------------------
revoke all on public.plant_profiles, public.plants, public.devices, public.readings, public.readings_v,
  public.gateways from public, anon, authenticated;
revoke all on function public.valid_threshold_overrides(jsonb), public.soil_pct(numeric, integer, integer) from public, anon;

grant select on public.plant_profiles, public.plants, public.devices, public.readings, public.readings_v, public.gateways to authenticated;
grant update (nickname, location, timezone, threshold_overrides) on public.plants to authenticated;
grant update (soil_dry_raw, soil_wet_raw, soil_calibrated_at) on public.devices to authenticated;
grant select, insert, update, delete on public.plant_profiles, public.plants, public.devices, public.readings, public.gateways to service_role;
grant select on public.readings_v to service_role;
grant usage, select on all sequences in schema public to service_role;
grant execute on function public.soil_pct(numeric, integer, integer) to authenticated, service_role;
-- evaluated by the plants CHECK constraint on writes by these roles
grant execute on function public.valid_threshold_overrides(jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------
-- RLS (enabled on every table). No insert/delete policies: only the backend (service_role) creates rows.
-- ---------------------------------------------------------------------------------------------------------------
alter table public.plant_profiles enable row level security;
alter table public.plants enable row level security;
alter table public.devices enable row level security;
alter table public.readings enable row level security;
alter table public.gateways enable row level security;

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

-- Realtime: readings INSERT (a signal; clients re-read readings_v), devices UPDATE (status, calibration)
alter publication supabase_realtime add table public.readings, public.devices;
