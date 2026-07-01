-- Part 3: repoint every child FK from the eo_dive_id XOR eo_course_id pair onto
-- a single event_id -> events(id). Preserves ON DELETE CASCADE. Rewrites the XOR
-- CHECKs and the partial-unique indexes. Transactional — the referential core.
-- Dropping the old columns auto-drops their FKs, XOR CHECKs, and partial indexes.

begin;

-- bookings: XOR = 1  ->  event_id NOT NULL
alter table public.bookings add column if not exists event_id uuid;
update public.bookings set event_id = coalesce(eo_dive_id, eo_course_id) where event_id is null;
alter table public.bookings
  add constraint bookings_event_id_fkey foreign key (event_id) references public.events(id) on delete cascade,
  add constraint bookings_event_present check (event_id is not null);
create unique index if not exists bookings_one_active_per_user_idx
  on public.bookings (user_id, event_id) where event_id is not null and status <> 'cancelled';
alter table public.bookings drop column eo_dive_id, drop column eo_course_id;

-- admin_notes: 3-way XOR (dive/course/booking) -> 2-way (event_id/booking_id)
alter table public.admin_notes add column if not exists event_id uuid;
update public.admin_notes set event_id = coalesce(eo_dive_id, eo_course_id) where event_id is null;
alter table public.admin_notes
  add constraint admin_notes_event_id_fkey foreign key (event_id) references public.events(id) on delete cascade,
  add constraint admin_notes_target_present check ((event_id is not null)::int + (booking_id is not null)::int = 1);
create index if not exists admin_notes_event_idx on public.admin_notes (event_id) where event_id is not null;
alter table public.admin_notes drop column eo_dive_id, drop column eo_course_id;

-- duties: permissive (no XOR — a duty may reference no event)
alter table public.duties add column if not exists event_id uuid;
update public.duties set event_id = coalesce(eo_dive_id, eo_course_id) where event_id is null;
alter table public.duties
  add constraint duties_event_id_fkey foreign key (event_id) references public.events(id) on delete cascade;
create index if not exists duties_event_idx on public.duties (event_id) where event_id is not null;
alter table public.duties drop column eo_dive_id, drop column eo_course_id;

-- event_vehicles: XOR = 1  ->  event_id NOT NULL  (unique (vehicle_id,event_date) unaffected)
alter table public.event_vehicles add column if not exists event_id uuid;
update public.event_vehicles set event_id = coalesce(eo_dive_id, eo_course_id) where event_id is null;
alter table public.event_vehicles
  add constraint event_vehicles_event_id_fkey foreign key (event_id) references public.events(id) on delete cascade,
  add constraint event_vehicles_event_present check (event_id is not null);
create index if not exists event_vehicles_event_idx on public.event_vehicles (event_id) where event_id is not null;
alter table public.event_vehicles drop column eo_dive_id, drop column eo_course_id;

-- waiver_signatures: at-most-one (annual waivers have neither) -> event_id nullable
alter table public.waiver_signatures add column if not exists event_id uuid;
update public.waiver_signatures set event_id = coalesce(eo_dive_id, eo_course_id) where event_id is null;
alter table public.waiver_signatures
  add constraint waiver_signatures_event_id_fkey foreign key (event_id) references public.events(id) on delete cascade;
create index if not exists waiver_signatures_event_idx on public.waiver_signatures (event_id) where event_id is not null;
alter table public.waiver_signatures drop column eo_dive_id, drop column eo_course_id;

-- event_waivers: XOR = 1  ->  event_id NOT NULL; per-(event,waiver_code) unique
alter table public.event_waivers add column if not exists event_id uuid;
update public.event_waivers set event_id = coalesce(eo_dive_id, eo_course_id) where event_id is null;
alter table public.event_waivers
  add constraint event_waivers_event_id_fkey foreign key (event_id) references public.events(id) on delete cascade,
  add constraint event_waivers_event_present check (event_id is not null);
create unique index if not exists event_waivers_event_code_uniq
  on public.event_waivers (event_id, waiver_code) where event_id is not null;
alter table public.event_waivers drop column eo_dive_id, drop column eo_course_id;

notify pgrst, 'reload schema';
commit;
