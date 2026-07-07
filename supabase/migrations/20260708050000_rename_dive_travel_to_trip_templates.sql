-- Rename the `dive_travel` reference table to `trip_templates` end to end.
--
-- `dive_travel` grew from a Bubble "DiveTravel" transport-blurb table into the
-- reusable set of trip copy a dive links to (included / not_included /
-- transportation / itinerary / prerequisites / links). `trip_templates` says
-- what it is: a template of trip detail a dive event references via
-- events.trip_template_id. It also frees the "travel" word, which collided with
-- `travel_destinations` (the dive-location catalog) and Scheduled Trips.
--
-- Clean rename with no back-compat shim. The pre-existing `DiveTravel_pkey`
-- constraint name is intentionally left untouched (an internal name, not part of
-- the external contract).

begin;

-- ── 1. table ─────────────────────────────────────────────────────────────────
alter table public.dive_travel rename to trip_templates;

-- ── 2. RLS policies ──────────────────────────────────────────────────────────
alter policy "dive_travel: public select" on public.trip_templates rename to "trip_templates: public select";
alter policy "dive_travel: admin insert"  on public.trip_templates rename to "trip_templates: admin insert";
alter policy "dive_travel: admin update"  on public.trip_templates rename to "trip_templates: admin update";
alter policy "dive_travel: admin delete"  on public.trip_templates rename to "trip_templates: admin delete";

-- ── 3. events FK column + constraint ─────────────────────────────────────────
alter table public.events rename column divetravel_id to trip_template_id;
alter table public.events rename constraint events_divetravel_id_fkey to events_trip_template_id_fkey;

commit;

notify pgrst, 'reload schema';
