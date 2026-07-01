-- Part 2: backfill events + junctions from EO_dives/EO_courses. Preserves the
-- source uuid _id as events.id so the child-FK repoint (M3) lines up. On a fresh
-- local reset the source tables are empty (migrations run before seeds), so this
-- is a no-op there; it carries the real data on the cloud migration. Re-runnable
-- via ON CONFLICT. Cruft columns (Created Date/Owner/google_calendar_event_id/
-- link-*/URL/EO_price_reference) are intentionally omitted.

begin;

insert into public.events (
  id, kind, admin_title, display_title, calendar_title, price, dive_days,
  prereq_cert_id, cancel_date, cancel_policy, fully_booked, capacity,
  full_payment_deadline, cancelled_at, featured_image, prereqs, featured,
  req_dives, start_date, end_date, start_time, course_days, is_private,
  nitrox_required, second_image, gear_rental, notes, divetravel_id,
  course_name, included, schedule, starting_at
)
select
  _id, 'dive', admin_title, display_title, calendar_title, price, dive_days,
  prereq_cert_id, cancel_date, cancel_policy, coalesce(fully_booked, false), capacity,
  full_payment_deadline, cancelled_at, featured_image, prereqs, coalesce(featured, false),
  req_dives::int, start_date, end_date, "time", null::date[], coalesce(is_private, false),
  coalesce(nitrox_required, false), second_image, gear_rental, notes, "DiveTravel_reference",
  null, null, null, null
from public."EO_dives"
on conflict (id) do nothing;

insert into public.events (
  id, kind, admin_title, display_title, calendar_title, price, dive_days,
  prereq_cert_id, cancel_date, cancel_policy, fully_booked, capacity,
  full_payment_deadline, cancelled_at, featured_image, prereqs, featured,
  req_dives, start_date, end_date, start_time, course_days, is_private,
  nitrox_required, second_image, gear_rental, notes, divetravel_id,
  course_name, included, schedule, starting_at
)
select
  _id, 'course', admin_title, display_title, calendar_title, price, dive_days,
  prereq_cert_id, cancel_date, cancel_policy, coalesce(fully_booked, false), capacity,
  full_payment_deadline, cancelled_at, featured_image, prereqs, false,
  -- courses store req_dives as free text ("20 logged dives"); keep only digits.
  nullif(regexp_replace(coalesce(req_dives, ''), '\D', '', 'g'), '')::int,
  null::date, null::date, start_time, course_days, false,
  false, null, null, null, null,
  course_name, included, schedule, starting_at
from public."EO_courses"
on conflict (id) do nothing;

insert into public.event_addons (event_id, addon_id)
  select eo_dive_id,   addon_id from public.eo_dive_addons
  union all
  select eo_course_id, addon_id from public.eo_course_addons
on conflict do nothing;

insert into public.event_rooms (event_id, room_id)
  select eo_dive_id, room_id from public.eo_dive_rooms
on conflict do nothing;

insert into public.event_destinations (event_id, destination_id)
  select eo_dive_id, destination_id from public.eo_dive_destinations
on conflict do nothing;

commit;
