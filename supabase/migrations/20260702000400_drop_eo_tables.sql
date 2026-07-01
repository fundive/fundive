-- Part 5: drop the old two-table schema. All child FKs were repointed to
-- events(id) in M3 and the data copied in M2, so nothing references these
-- anymore. Junctions first (they FK the event tables), then the tables.

begin;

drop table if exists public.eo_dive_addons;
drop table if exists public.eo_course_addons;
drop table if exists public.eo_dive_rooms;
drop table if exists public.eo_dive_destinations;

drop table if exists public."EO_dives";
drop table if exists public."EO_courses";

notify pgrst, 'reload schema';
commit;
