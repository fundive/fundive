-- ============================================================
-- event_vehicles → event-level many-to-many (drop the date grain)
-- ============================================================
-- The baseline modelled allocation per DATE and made a vehicle exclusive to one
-- event per day (unique vehicle_id, event_date). The shop wants the opposite: a
-- vehicle is a reusable resource assigned to an EVENT as a whole and may serve
-- any number of events (even overlapping ones). So drop the date grain and
-- dedupe to one row per (event_id, vehicle). Divers still ride via
-- bookings.details.transportation; a ride is only offered when the diver's event
-- has an assigned car with a free seat — the event_ride_seats RPC already tallies
-- per event, so no change there.
--
-- Mirrors app-fundivers 20260702000000_event_vehicles_event_level.sql, adapted:
-- this table is already event_id-based (the app-fundivers original still had the
-- eo_dive_id/eo_course_id XOR shape at that point), so a single plain unique
-- index suffices instead of the two partial ones.

begin;

-- Collapse the old per-date rows: a multi-day event that had the same vehicle on
-- several days becomes a single (event, vehicle) allocation. Keep the lowest
-- ctid of each duplicate group.
delete from public.event_vehicles a
using public.event_vehicles b
where a.ctid > b.ctid
  and a.vehicle_id = b.vehicle_id
  and a.event_id   = b.event_id;

-- Dropping event_date also drops the indexes that reference it
-- (event_vehicles_vehicle_date_uniq, event_vehicles_date_idx).
alter table public.event_vehicles drop column event_date;

-- One allocation per (event, vehicle). event_id is already NOT NULL
-- (event_vehicles_event_present), so a plain unique index is enough.
create unique index if not exists event_vehicles_event_vehicle_uniq
  on public.event_vehicles (event_id, vehicle_id);

commit;

notify pgrst, 'reload schema';
