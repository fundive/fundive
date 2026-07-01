-- Make the junction tables the single source of truth for an event's rooms,
-- add-ons, and destinations.
--
-- History: EO_dives/EO_courses carried the relations as denormalized CSV/JSON
-- string columns (room_types, other_addons, destination_reference), and AFTER
-- triggers parsed those strings into the eo_dive_rooms / eo_dive_addons /
-- eo_course_addons / eo_dive_destinations junction tables, which the app reads.
-- That dual representation could drift. The app now writes the junctions
-- directly (via the set_event_relations RPC), so the string write-buffer + its
-- triggers + parsers are removed here. The junctions already hold the data
-- (backfilled by 20260422220000 / 20260430040000 / 20260505000000), so no data
-- migration is needed.
--
-- has_rooms / hasotheraddons were derived flags mirrored from the strings; the
-- read layer now derives them from junction membership. fully_booked STAYS — it
-- is a manual admin override, not derivable.

begin;

-- Triggers first (they depend on the sync functions and the string columns).
drop trigger if exists sync_eo_dive_rooms_trg        on public."EO_dives";
drop trigger if exists sync_eo_dive_addons_trg       on public."EO_dives";
drop trigger if exists sync_eo_dive_destinations_trg on public."EO_dives";
drop trigger if exists sync_eo_course_addons_trg     on public."EO_courses";

drop function if exists public.sync_eo_dive_rooms();
drop function if exists public.sync_eo_dive_addons();
drop function if exists public.sync_eo_dive_destinations();
drop function if exists public.sync_eo_course_addons();

-- Parsers now have no dependents.
drop function if exists public.parse_addon_ids(text);
drop function if exists public.parse_room_ids(text);

alter table public."EO_dives"
  drop column if exists room_types,
  drop column if exists other_addons,
  drop column if exists destination_reference,
  drop column if exists has_rooms,
  drop column if exists hasotheraddons;

alter table public."EO_courses"
  drop column if exists other_addons;

notify pgrst, 'reload schema';

commit;
