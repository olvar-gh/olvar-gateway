-- LOCAL / TEST DATA ONLY. Applied by `supabase db reset` against the local stack; never pushed to production
-- (`db push --remote` does not run seed files). The spathiphyllum profile is NOT created here: it comes from
-- migration 20261116000150_profile_spathiphyllum.sql in every environment.
--
-- Local owner:  dev@olvar.local / olvar-dev-password   (local stack only)
-- Plant:        'Lily', timezone Asia/Seoul. Override before `supabase db reset` with
--               `alter database postgres set olvar.seed_timezone = 'Europe/Berlin';` (any IANA name).
-- Device:       olvar-a1b2c3, calibrated dry=2900 / wet=1300, 48 h of 60 s synthetic readings ending now.

do $$
declare
  v_owner constant uuid := '00000000-0000-4000-8000-0000000000a1';
  v_plant constant uuid := '00000000-0000-4000-8000-0000000000b1';
  v_tz text := coalesce(nullif(current_setting('olvar.seed_timezone', true), ''), 'Asia/Seoul');
begin
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated', 'dev@olvar.local',
          extensions.crypt('olvar-dev-password', extensions.gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '');

  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (v_owner::text, v_owner,
          jsonb_build_object('sub', v_owner::text, 'email', 'dev@olvar.local', 'email_verified', true),
          'email', now(), now(), now());

  insert into public.plants (id, owner_id, profile_id, nickname, location, timezone)
  values (v_plant, v_owner, 'spathiphyllum', 'Lily', 'Living room window', v_tz);

  insert into public.devices (id, owner_id, plant_id, fw, status, status_changed_at, last_seen_at,
                              soil_dry_raw, soil_wet_raw, soil_calibrated_at)
  values ('olvar-a1b2c3', v_owner, v_plant, '0.1.0', 'online', now() - interval '24 hours', now(),
          2900, 1300, now() - interval '3 days');

  insert into public.gateways (id, owner_id, version, buffer_depth, last_seen_at)
  values ('olvar-gw', v_owner, '0.1.0', 0, now());

  -- 48 h of readings, one per minute. Boot '3fa9c2e1' for the first 24 h, then a reboot to 'b7d04e5a'
  -- (seq restarts at 0). Diurnal temperature/light in the plant's local time; soil dries (raw rises) and gets
  -- watered 30 h ago; every 97th reading has a failed temperature/humidity read (null).
  insert into public.readings (device_id, recorded_at, received_at, boot_id, seq, uptime_ms,
                               temperature_c, humidity_pct, lux, soil_raw, rssi_dbm, clock_source)
  select 'olvar-a1b2c3', t.ts, t.ts + interval '1 second', t.boot_id,
         t.seq, t.seq::bigint * 60000 + 4000,
         case when t.i % 97 = 0 then null else round((22 + 3 * sin(t.phase))::numeric, 1) end,
         case when t.i % 97 = 0 then null else round((52 - 6 * sin(t.phase))::numeric, 1) end,
         case when t.local_h between 6 and 20 then round((1800 * sin(pi() * (t.local_h - 6) / 14))::numeric, 1)
              else 0 end,
         case when t.ts < now() - interval '30 hours'
              then 2300 + (extract(epoch from t.ts - (now() - interval '48 hours')) / 3600 * 15)::int
              else 1450 + (extract(epoch from t.ts - (now() - interval '30 hours')) / 3600 * 25)::int end,
         -60 - (t.i % 7),
         'ntp'
  from (
    select g.i, g.ts,
           case when g.ts < now() - interval '24 hours' then '3fa9c2e1' else 'b7d04e5a' end as boot_id,
           (row_number() over (partition by g.ts < now() - interval '24 hours' order by g.ts) - 1)::int as seq,
           extract(hour from g.ts at time zone v_tz) + extract(minute from g.ts at time zone v_tz) / 60.0 as local_h,
           2 * pi() * (extract(hour from g.ts at time zone v_tz) - 9) / 24 as phase
    from (select i, date_trunc('minute', now()) - (2879 - i) * interval '1 minute' as ts
          from generate_series(0, 2879) as i) as g
  ) as t;
end $$;
