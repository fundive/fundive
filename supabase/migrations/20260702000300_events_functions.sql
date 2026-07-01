-- Part 4: rewrite every trigger/RPC that branched on the two tables / the
-- eo_dive_id|eo_course_id pair to a single event_id + events.kind. Signature
-- changes require dropping the old function first (Postgres overloads).
-- strip_capacity_suffix() / capacity_suffix() are unchanged.

begin;

-- Old normalize triggers live on EO_dives/EO_courses (dropped in M5); remove now
-- so the rewritten function body can't be reached through them.
drop trigger if exists trg_eo_dives_normalize_title   on public."EO_dives";
drop trigger if exists trg_eo_courses_normalize_title on public."EO_courses";

-- Drop old signatures (new ones take a single event_id).
drop function if exists public.event_confirmed_counts(uuid[], uuid[]);
drop function if exists public.event_confirmed_count_one(text, uuid);
drop function if exists public.offer_next_waitlist_spot(uuid, text);
drop function if exists public.event_ride_seats(uuid, uuid);
drop function if exists public.refresh_event_display_title(text, uuid);
drop function if exists public.set_event_relations(text, uuid, uuid[], uuid[], text[]);

-- ── confirmed-count helpers ────────────────────────────────────────────────
create function public.event_confirmed_counts(p_event_ids uuid[])
returns table(event_id uuid, n integer)
language sql security definer set search_path to 'public'
as $$
  select event_id, count(*)::int
  from public.bookings
  where status = 'confirmed' and event_id = any(coalesce(p_event_ids, '{}'::uuid[]))
  group by event_id;
$$;

create function public.event_confirmed_count_one(p_event_id uuid)
returns integer
language sql stable security definer set search_path to 'public'
as $$
  select count(*)::int from public.bookings
  where status = 'confirmed' and event_id = p_event_id;
$$;

-- ── display-title capacity suffix (now one trigger on events) ───────────────
create or replace function public.eo_event_normalize_display_title()
returns trigger language plpgsql
as $$
declare
  v_base      text;
  v_confirmed int;
begin
  v_base := public.strip_capacity_suffix(new.display_title);
  v_confirmed := public.event_confirmed_count_one(new.id);
  new.display_title := v_base || public.capacity_suffix(
    new.capacity, coalesce(new.fully_booked, false), v_confirmed
  );
  return new;
end;
$$;

create trigger trg_events_normalize_title
  before insert or update on public.events
  for each row execute function public.eo_event_normalize_display_title();

create function public.refresh_event_display_title(p_event_id uuid)
returns void language plpgsql security definer set search_path to 'public'
as $$
declare
  v_current   text;
  v_capacity  int;
  v_fully     boolean;
  v_confirmed int;
  v_new_title text;
begin
  if p_event_id is null then return; end if;
  select display_title, capacity, coalesce(fully_booked, false)
    into v_current, v_capacity, v_fully
  from public.events where id = p_event_id;
  if v_current is null and v_capacity is null and not v_fully then return; end if;
  v_confirmed := public.event_confirmed_count_one(p_event_id);
  v_new_title := public.strip_capacity_suffix(coalesce(v_current, ''))
              || public.capacity_suffix(v_capacity, v_fully, v_confirmed);
  update public.events set display_title = v_new_title
   where id = p_event_id and display_title is distinct from v_new_title;
end;
$$;

create or replace function public.trg_bookings_refresh_event_title()
returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  if TG_OP = 'INSERT' then
    if new.event_id is not null then perform public.refresh_event_display_title(new.event_id); end if;
  elsif TG_OP = 'UPDATE' then
    if new.status is distinct from old.status then
      if coalesce(new.event_id, old.event_id) is not null then
        perform public.refresh_event_display_title(coalesce(new.event_id, old.event_id));
      end if;
    end if;
  elsif TG_OP = 'DELETE' then
    if old.event_id is not null then perform public.refresh_event_display_title(old.event_id); end if;
  end if;
  return null;
end;
$$;

-- ── capacity gate / waitlist ────────────────────────────────────────────────
create or replace function public.set_waitlisted_when_event_full()
returns trigger language plpgsql
as $$
declare
  v_full      boolean := false;
  v_capacity  int;
  v_confirmed int;
begin
  if new.status = 'pending' and new.event_id is not null then
    select coalesce(fully_booked, false), capacity into v_full, v_capacity
      from public.events where id = new.event_id;
    if not v_full and v_capacity is not null then
      select count(*)::int into v_confirmed
        from public.bookings where status = 'confirmed' and event_id = new.event_id;
      if v_confirmed >= v_capacity then v_full := true; end if;
    end if;
    if v_full then new.status := 'waitlisted'; end if;
  end if;
  return new;
end;
$$;

create function public.offer_next_waitlist_spot(p_event_id uuid)
returns uuid language plpgsql security definer set search_path to 'public'
as $$
declare
  v_booking_id uuid;
  v_offer_id   uuid;
begin
  select b.id into v_booking_id
  from public.bookings b
  where b.status = 'waitlisted' and b.event_id = p_event_id
    and not exists (select 1 from public.waitlist_offers o where o.booking_id = b.id and o.status = 'pending')
  order by b.created_at asc
  limit 1;
  if v_booking_id is null then return null; end if;
  insert into public.waitlist_offers (booking_id) values (v_booking_id)
    on conflict (booking_id) where status = 'pending' do nothing
  returning id into v_offer_id;
  return v_offer_id;
end;
$$;

create or replace function public.handle_booking_cancellation()
returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    update public.waitlist_offers set status = 'expired'
     where booking_id = new.id and status = 'pending';
    if old.status in ('pending', 'confirmed') and new.event_id is not null then
      perform public.offer_next_waitlist_spot(new.event_id);
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.accept_waitlist_offer(p_offer_id uuid)
returns void language plpgsql security definer set search_path to 'public'
as $$
declare
  v_booking_id uuid;
  v_user_id    uuid;
  v_status     text;
  v_expires_at timestamptz;
  v_event_id   uuid;
  v_capacity   int;
  v_taken      int;
begin
  select o.booking_id, b.user_id, o.status, o.expires_at, b.event_id
    into v_booking_id, v_user_id, v_status, v_expires_at, v_event_id
  from public.waitlist_offers o
  join public.bookings b on b.id = o.booking_id
  where o.id = p_offer_id;

  if v_booking_id is null then raise exception 'offer not found'; end if;
  if v_user_id is distinct from auth.uid() then raise exception 'forbidden' using errcode = '42501'; end if;
  if v_status <> 'pending' then raise exception 'offer is no longer pending (status=%)', v_status; end if;
  if v_expires_at < now() then raise exception 'offer has expired'; end if;

  if v_event_id is not null then
    select capacity into v_capacity from public.events where id = v_event_id;
    select count(*) into v_taken from public.bookings
      where event_id = v_event_id and status in ('pending', 'confirmed');
  end if;
  if v_capacity is not null and v_taken >= v_capacity then
    raise exception 'event is at capacity (% of %); offer cannot be accepted', v_taken, v_capacity
      using errcode = 'check_violation';
  end if;

  update public.waitlist_offers set status = 'accepted' where id = p_offer_id;
  update public.bookings        set status = 'pending'  where id = v_booking_id;
end;
$$;

-- ── ride seats ─────────────────────────────────────────────────────────────
create function public.event_ride_seats(p_event_id uuid)
returns table(capacity integer, claimed integer)
language sql security definer set search_path to 'public'
as $$
  select
    coalesce((
      select sum(v.passenger_seats)::int
      from (select distinct vehicle_id from public.event_vehicles where event_id = p_event_id) ev
      join public.vehicles v on v.id = ev.vehicle_id
    ), 0),
    coalesce((
      select count(*)::int from public.bookings
      where status <> 'cancelled' and (details->>'transportation') = 'true' and event_id = p_event_id
    ), 0);
$$;

-- ── relation reconciliation (junctions are events-centric now) ──────────────
create function public.set_event_relations(
  p_event_id        uuid,
  p_room_ids        uuid[] default '{}',
  p_addon_ids       uuid[] default '{}',
  p_destination_ids text[] default '{}'
) returns void
language plpgsql security invoker set search_path = public
as $$
begin
  delete from public.event_rooms where event_id = p_event_id;
  insert into public.event_rooms (event_id, room_id)
    select p_event_id, unnest(p_room_ids) on conflict do nothing;

  delete from public.event_addons where event_id = p_event_id;
  insert into public.event_addons (event_id, addon_id)
    select p_event_id, unnest(p_addon_ids) on conflict do nothing;

  delete from public.event_destinations where event_id = p_event_id;
  insert into public.event_destinations (event_id, destination_id)
    select p_event_id, unnest(p_destination_ids) on conflict do nothing;
end;
$$;
revoke all on function public.set_event_relations(uuid, uuid[], uuid[], text[]) from public;
grant execute on function public.set_event_relations(uuid, uuid[], uuid[], text[]) to authenticated;

-- ── sign_waiver: p_dive_id/p_course_id -> single p_event_id ────────────────
drop function if exists public.sign_waiver(text, int, text, uuid, uuid);
create function public.sign_waiver(
  p_code        text,
  p_version     int,
  p_signed_name text,
  p_event_id    uuid default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare new_id uuid;
begin
  if auth.uid() is null then raise exception 'must be authenticated' using errcode = 'insufficient_privilege'; end if;
  if p_code is null or char_length(p_code) = 0 then raise exception 'waiver code is required' using errcode = 'check_violation'; end if;
  if p_version is null or p_version < 1 then raise exception 'waiver version must be a positive integer' using errcode = 'check_violation'; end if;
  if p_signed_name is null or char_length(btrim(p_signed_name)) = 0 then raise exception 'signed name is required' using errcode = 'check_violation'; end if;

  insert into public.waiver_signatures
    (diver_id, waiver_code, waiver_version, signed_name, signed_at, event_id)
  values
    (auth.uid(), p_code, p_version, btrim(p_signed_name), now(), p_event_id)
  returning id into new_id;
  return new_id;
end;
$$;
revoke all on function public.sign_waiver(text, int, text, uuid) from public;
grant execute on function public.sign_waiver(text, int, text, uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
