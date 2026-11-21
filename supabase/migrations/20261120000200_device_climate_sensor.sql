-- devices.climate_sensor: which temperature/humidity sensor the firmware is currently reading, from the optional
-- telemetry field "climate_sensor" (docs/PLAN.md §4). The gateway writes the latest value on every telemetry
-- message; a message without the field (no sensor detected, or older firmware) sets it to null. Unknown values never
-- reach the database: the gateway treats them as absent.
--
-- Access is unchanged: owners read it through the existing table-level select grant and the owner-only devices_read
-- policy (both cover every column); it is not in the authenticated column-level update grant, so only the gateway
-- (service_role) writes it. devices is already in the supabase_realtime publication, so UPDATEs carry the column.
alter table public.devices
  add column climate_sensor text constraint devices_climate_sensor_check check (climate_sensor in ('sht31', 'dht11'));

comment on column public.devices.climate_sensor is
  'Temperature/humidity sensor the firmware currently reads: sht31 or dht11; null when none was detected or unknown.';
