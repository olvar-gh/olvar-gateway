-- Reference data, applied in every environment (docs/PLAN.md §5.6, decision D21).
-- Production gets the profile from `supabase db push --remote`, which never runs seed.sql. Idempotent: re-running
-- this migration or adding a later "update profile" migration never duplicates the row.
-- Later threshold changes ship as NEW migrations (never edit an applied one); per-plant tuning uses
-- plants.threshold_overrides.
--
-- Threshold semantics (evaluated by plant_status_v): value < critical_low → critical_low; < low → low;
-- ok_low..ok_high → ok; > high → high; > critical_high → critical_high. Persistence/aggregation windows
-- (30-min median, daytime light mean, 12 h humidity / 48 h soil "high") live in plant_status_v. Evidence: §2.8.
insert into public.plant_profiles (id, common_name, scientific_name, thresholds, care_notes, sources)
values (
  'spathiphyllum',
  'Peace lily',
  'Spathiphyllum spp.',
  '{
     "temperature_c": {"critical_low": 10, "low": 16, "ok_low": 18, "ok_high": 29, "high": 30, "critical_high": 32},
     "humidity_pct":  {"critical_low": 25, "low": 40, "ok_low": 40, "ok_high": 70, "high": 85},
     "lux":           {"critical_low": 270, "low": 800, "ok_low": 800, "ok_high": 5400, "high": 10800, "critical_high": 27000},
     "soil_pct":      {"critical_low": 20, "low": 35, "ok_low": 35, "ok_high": 85, "high": 90}
   }'::jsonb,
  'Peace lily (Spathiphyllum), a tropical understory plant. '
  || 'Temperature: best 20-29 °C by day and about 5 °C cooler at night; keep above 16 °C. Below 10 °C causes '
  || 'chilling injury and growth stalls after a few days near 11 °C; keep below 32 °C. '
  || 'Humidity: low air humidity causes brown leaf tips; 40-60 % is ideal, above 50 % is welcome, below 25 % is harmful. '
  || 'Light: bright indirect light, no direct sun. Survives from about 270 lux but prefers roughly 800-2,000 lux; '
  || 'more light is needed to flower. Above about 10,800 lux means direct sun indoors, and leaves scorch above about '
  || '27,000 lux. '
  || 'Water: keep the soil evenly moist but never soggy, and let the top slightly dry between waterings. '
  || 'Overwatering causes root rot; drying out causes dramatic wilting, which usually recovers after watering. '
  || 'Soil moisture percentages come from a capacitive probe calibrated in this pot, so they are relative values, '
  || 'not absolute water content.',
  array[
    'https://hgic.clemson.edu/factsheet/peace-lily',
    'https://plants.ces.ncsu.edu/plants/spathiphyllum',
    'https://edis.ifas.ufl.edu/en/publication/EP161',
    'https://ask.ifas.ufl.edu/en/publication/ep477',
    'https://extension.sdstate.edu/peace-lily-houseplant-how',
    'https://fieldreport.caes.uga.edu/wp-content/uploads/2025/08/B-1318_6.pdf',
    'https://uthort.tennessee.edu/wp-content/uploads/sites/228/2023/11/W1128A.pdf',
    'https://extension.missouri.edu/publications/g6510',
    'https://extension.missouri.edu/publications/g6515',
    'https://extension.umd.edu/resource/lighting-indoor-plants',
    'https://smarthomescene.com/diy/diy-capacitive-soil-moisture-sensor-v1-2-with-esphome/',
    'https://esp32.co.uk/capacitive-soil-moisture-sensor-esp32-esphome-home-assistant',
    'https://swiftwand.com/en/soil-moisture-sensor-esp32-calibration-2026-en'
  ]
)
on conflict (id) do update set common_name = excluded.common_name, scientific_name = excluded.scientific_name,
  thresholds = excluded.thresholds, care_notes = excluded.care_notes, sources = excluded.sources;
