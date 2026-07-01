-- Unify EO_dives + EO_courses into ONE events table (kind discriminator).
-- Part 1: create events + its junctions + RLS/grants. Backfill is M2
-- (20260702000100), child-FK repoint M3, functions/triggers M4, drop of the
-- old tables M5. See docs/data-model.md.
--
-- Temporal model: dives use the scalar envelope (start_date/end_date/start_time);
-- courses use course_days[] (discrete sessions, no envelope). Both live on the
-- one table, nullable per kind — the date-model asymmetry is genuine domain
-- logic, not storage.

begin;

create table if not exists public.events (
  id                     uuid primary key default gen_random_uuid(),
  kind                   text not null check (kind in ('dive','course')),

  -- shared
  admin_title            text,
  display_title          text,
  calendar_title         text,
  price                  uuid    references public."EO_prices"(_id) on delete set null,
  dive_days              bigint,
  prereq_cert_id         uuid    references public.cert_levels(id) on delete set null,
  cancel_date            date,
  cancel_policy          text    references public.cancellation_policies(_id) on update cascade,
  fully_booked           boolean not null default false,   -- manual admin override
  capacity               integer check (capacity is null or capacity >= 0),
  full_payment_deadline  date,
  cancelled_at           timestamptz,
  featured_image         text,
  prereqs                text,
  featured               boolean not null default false,
  req_dives              integer,                          -- reconciled: bigint(dive)/text(course) -> int

  -- temporal
  start_date             date,        -- dive envelope
  end_date               date,        -- dive envelope
  start_time             time,        -- both (dive 'time' renamed to start_time)
  course_days            date[],      -- course discrete sessions

  -- dive-only
  is_private             boolean not null default false,
  nitrox_required        boolean not null default false,
  second_image           text,
  gear_rental            text,
  notes                  text,
  divetravel_id          text,        -- rename of DiveTravel_reference (FK not enforced)

  -- course-only
  course_name            text,
  included               text,
  schedule               text,
  starting_at            integer,

  constraint events_dive_has_start  check (kind <> 'dive'   or start_date is not null),
  constraint events_course_has_days check (kind <> 'course' or (course_days is not null and array_length(course_days, 1) between 1 and 4))
);

create index if not exists events_kind_start_idx  on public.events (kind, start_date);
create index if not exists events_course_days_idx on public.events using gin (course_days);
create index if not exists events_price_idx        on public.events (price);
create index if not exists events_active_idx       on public.events (start_date) where cancelled_at is null;

-- Junctions (events-centric). event_addons merges eo_dive_addons + eo_course_addons.
create table if not exists public.event_addons (
  event_id uuid not null references public.events(id) on delete cascade,
  addon_id uuid not null references public."Other_Addons"(_id) on delete cascade,
  primary key (event_id, addon_id)
);
create table if not exists public.event_rooms (
  event_id uuid not null references public.events(id) on delete cascade,
  room_id  uuid not null references public."EO_rooms"(_id) on delete cascade,
  primary key (event_id, room_id)
);
create table if not exists public.event_destinations (
  event_id       uuid not null references public.events(id) on delete cascade,
  destination_id text not null references public."TravelDestinations"(_id) on delete cascade,
  primary key (event_id, destination_id)
);

-- RLS: public read + is_admin() write (mirrors the old EO_* + junction policies).
alter table public.events             enable row level security;
alter table public.event_addons       enable row level security;
alter table public.event_rooms        enable row level security;
alter table public.event_destinations enable row level security;

create policy "events public select" on public.events for select to anon, authenticated using (true);
create policy "events admin insert"  on public.events for insert to authenticated with check (public.is_admin());
create policy "events admin update"  on public.events for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "events admin delete"  on public.events for delete to authenticated using (public.is_admin());

do $$
declare t text;
begin
  foreach t in array array['event_addons','event_rooms','event_destinations'] loop
    execute format('create policy %I on public.%I for select to anon, authenticated using (true)', t||' public select', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.is_admin())', t||' admin insert', t);
    execute format('create policy %I on public.%I for update to authenticated using (public.is_admin()) with check (public.is_admin())', t||' admin update', t);
    execute format('create policy %I on public.%I for delete to authenticated using (public.is_admin())', t||' admin delete', t);
  end loop;
end$$;

-- Grant lockdown (mirror 20260603060000): anon keeps SELECT only; authenticated
-- writes are gated by the is_admin() policies above.
revoke insert, update, delete, truncate
  on public.events, public.event_addons, public.event_rooms, public.event_destinations
  from anon, authenticated;
grant select
  on public.events, public.event_addons, public.event_rooms, public.event_destinations
  to anon, authenticated;
grant insert, update, delete
  on public.events, public.event_addons, public.event_rooms, public.event_destinations
  to authenticated;

notify pgrst, 'reload schema';
commit;
