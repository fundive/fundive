-- ============================================================
-- events.is_boat_dive / is_trip — two independent dive flags
-- ============================================================
-- A dive can be a boat dive, a trip (shown under Scheduled Trips), both, or
-- neither — the two are independent booleans, not a single category. Admins set
-- them per event in the event form. Courses leave them false.
--
-- No keyword backfill here: classification is a deliberate admin choice, and any
-- title-heuristic (for calendar coloring) is config-driven via
-- business.tripKeywords, not baked into the schema.

begin;

alter table public.events
  add column if not exists is_boat_dive boolean not null default false,
  add column if not exists is_trip      boolean not null default false;

commit;

notify pgrst, 'reload schema';
