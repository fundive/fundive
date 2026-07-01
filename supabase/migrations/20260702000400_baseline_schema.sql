


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."accept_current_terms"("p_version" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'must be authenticated' using errcode = 'insufficient_privilege';
  end if;
  if p_version is null or p_version < 1 then
    raise exception 'agreed_to_terms_version must be a positive integer'
      using errcode = 'check_violation';
  end if;
  update public.profiles
     set agreed_to_terms_at      = now(),
         agreed_to_terms_version = p_version
   where id = auth.uid();
end;
$$;


ALTER FUNCTION "public"."accept_current_terms"("p_version" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."accept_waitlist_offer"("p_offer_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."accept_waitlist_offer"("p_offer_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_delete_user"("p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'admin only'
      using errcode = 'insufficient_privilege';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'cannot delete your own account'
      using errcode = 'check_violation';
  end if;
  delete from auth.users where id = p_user_id;
end;
$$;


ALTER FUNCTION "public"."admin_delete_user"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_credit_to_booking"("p_booking_id" "uuid", "p_amount" numeric) RETURNS numeric
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_caller    uuid    := auth.uid();
  v_is_admin  boolean := public.is_admin();
  v_booking   public.bookings%rowtype;
  v_owed      numeric;
  v_paid      numeric;
  v_self_cred numeric;
  v_due       numeric;
  v_avail     numeric;
  v_apply     numeric;
  v_deposit   numeric;
  v_remaining numeric;
  v_take      numeric;
  c           record;
begin
  if v_caller is null then
    raise exception 'auth required' using errcode = 'insufficient_privilege';
  end if;

  select * into v_booking from public.bookings where id = p_booking_id;
  if not found then
    raise exception 'booking not found' using errcode = 'no_data_found';
  end if;

  -- A diver may only spend against their own booking; admins, anyone's.
  if v_booking.user_id <> v_caller and not v_is_admin then
    raise exception 'not your booking' using errcode = 'insufficient_privilege';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive' using errcode = 'check_violation';
  end if;

  -- owed = frozen total snapshot + signed amendment ledger.
  v_owed := coalesce((v_booking.details ->> 'total')::numeric, 0)
          + coalesce((select sum(amount) from public.booking_amendments
                      where booking_id = p_booking_id), 0);

  v_paid := coalesce((select sum(amount) from public.payments
                      where booking_id = p_booking_id and status = 'paid'), 0);

  -- Credit already tied to THIS booking is shown as an offset against its
  -- balance everywhere in the UI, so the spendable "balance due" nets it out
  -- and we never re-spend it. The pool we consume is the diver's OTHER open
  -- credit (general credits + credits from other/cancelled bookings).
  v_self_cred := coalesce((select sum(amount) from public.credits
                           where booking_id = p_booking_id
                             and user_id = v_booking.user_id
                             and status = 'open'), 0);

  v_due := v_owed - v_paid - v_self_cred;
  if v_due <= 0 then
    return 0;
  end if;

  v_avail := coalesce((select sum(amount) from public.credits
                       where user_id = v_booking.user_id
                         and status = 'open'
                         and booking_id is distinct from p_booking_id), 0);
  if v_avail <= 0 then
    return 0;
  end if;

  v_apply := least(p_amount, v_due, v_avail);

  -- Consume open credit rows oldest-first. A row fully covered by the
  -- remaining need is settled; the row that straddles the boundary is
  -- settled in full and its unspent part carried forward as a new open row.
  v_remaining := v_apply;
  for c in
    select id, amount, reason, booking_id, currency, created_by
    from public.credits
    where user_id = v_booking.user_id
      and status = 'open'
      and booking_id is distinct from p_booking_id
    order by created_at asc, id asc
  loop
    exit when v_remaining <= 0;
    v_take := least(c.amount, v_remaining);

    update public.credits
    set status       = 'settled',
        settled_at   = now(),
        settled_note = 'Applied ' || c.currency || ' ' || v_take
                       || ' to booking ' || p_booking_id
                       || case when c.amount > v_take
                               then '; ' || c.currency || ' ' || (c.amount - v_take)
                                    || ' carried forward'
                               else '' end
    where id = c.id;

    if c.amount > v_take then
      insert into public.credits (user_id, booking_id, amount, currency, reason, status, created_by)
      values (v_booking.user_id, c.booking_id, c.amount - v_take, c.currency, c.reason, 'open', c.created_by);
    end if;

    v_remaining := v_remaining - v_take;
  end loop;

  insert into public.payments (user_id, booking_id, amount, status, method, note, recorded_by)
  values (
    v_booking.user_id, p_booking_id, v_apply,
    'paid', 'account_credit', 'Applied account credit', v_caller
  );

  -- Crossing the deposit threshold confirms a pending spot, matching
  -- recordPayment()'s promotion rule.
  v_deposit := coalesce((v_booking.details ->> 'deposit')::numeric, 0);
  if v_booking.status = 'pending' and (v_paid + v_apply) >= v_deposit then
    update public.bookings set status = 'confirmed' where id = p_booking_id;
  end if;

  return v_apply;
end;
$$;


ALTER FUNCTION "public"."apply_credit_to_booking"("p_booking_id" "uuid", "p_amount" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."audit_admin_write"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  -- Skip logging for service-role / migrations (auth.uid() is null), for
  -- the diver acting on their own row, and for the trigger's own internal
  -- calls if any (defensive).
  if auth.uid() is null or not public.is_admin() then
    return coalesce(new, old);
  end if;

  insert into public.admin_audit_log (actor_id, action, target_table, target_id, before, after)
  values (
    auth.uid(),
    lower(tg_op),
    tg_table_name,
    coalesce((new).id::text, (old).id::text),
    case when tg_op <> 'INSERT' then to_jsonb(old) end,
    case when tg_op <> 'DELETE' then to_jsonb(new) end
  );

  return coalesce(new, old);
end;
$$;


ALTER FUNCTION "public"."audit_admin_write"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."audit_log_no_mutations"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  raise exception 'admin_audit_log rows are immutable'
    using errcode = 'insufficient_privilege';
end;
$$;


ALTER FUNCTION "public"."audit_log_no_mutations"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."block_self_gear_size_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not public.is_staff_or_admin() then
    if new.fin_size     is distinct from old.fin_size
       or new.bcd_size     is distinct from old.bcd_size
       or new.wetsuit_size is distinct from old.wetsuit_size then
      raise exception 'Gear sizes can only be set by staff or admins'
        using errcode = 'insufficient_privilege';
    end if;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."block_self_gear_size_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."block_self_privileged_profile_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null or public.is_admin() then
    return new;
  end if;
  if new.role           is distinct from old.role
     or new.status        is distinct from old.status
     or new.parent_account is distinct from old.parent_account then
    raise exception
      'role, status, and parent_account are admin-managed'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."block_self_privileged_profile_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bookings_block_diver_detail_edits"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.details is not distinct from old.details then
    return new;
  end if;

  -- auth.uid() is null under service-role / superuser contexts (migrations,
  -- workers, dashboard SQL editor). Those callers are trusted to edit freely.
  if auth.uid() is null then
    return new;
  end if;

  if not public.is_admin() then
    raise exception 'bookings.details is locked after submission; contact staff to change it'
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."bookings_block_diver_detail_edits"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bookings_validate_payer"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_parent uuid;
begin
  if new.payer_id is not null and new.payer_id <> new.user_id then
    select parent_account into v_parent from public.profiles where id = new.user_id;
    if v_parent is null or v_parent <> new.payer_id then
      raise exception 'payer_id must be the diver themselves or their parent account'
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."bookings_validate_payer"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."capacity_suffix"("p_capacity" integer, "p_fully_booked" boolean, "p_confirmed" integer) RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_remaining int;
begin
  if coalesce(p_fully_booked, false) then
    return ' (fully booked -- register for waitlist)';
  end if;
  if p_capacity is null then
    return '';
  end if;
  v_remaining := greatest(0, p_capacity - coalesce(p_confirmed, 0));
  if v_remaining = 0 then return ' (fully booked -- register for waitlist)'; end if;
  if v_remaining = 1 then return ' (1 spot open)'; end if;
  if v_remaining = 2 then return ' (2 spots open)'; end if;
  return '';
end;
$$;


ALTER FUNCTION "public"."capacity_suffix"("p_capacity" integer, "p_fully_booked" boolean, "p_confirmed" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cascade_profile_delete_to_auth_users"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if pg_trigger_depth() > 1 then
    return old;
  end if;
  delete from auth.users where id = old.id;
  return old;
end;
$$;


ALTER FUNCTION "public"."cascade_profile_delete_to_auth_users"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."diver_notes_freeze_identity"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.profile_id is distinct from old.profile_id then
    raise exception 'diver_notes.profile_id is immutable';
  end if;
  if new.created_by is distinct from old.created_by then
    raise exception 'diver_notes.created_by is immutable';
  end if;
  if new.created_at is distinct from old.created_at then
    raise exception 'diver_notes.created_at is immutable';
  end if;
  return new;
end
$$;


ALTER FUNCTION "public"."diver_notes_freeze_identity"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."duties_enforce_assignee_is_admin"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if not exists (
    select 1 from public.profiles
    where id = new.assignee_id and role in ('admin','staff')
  ) then
    raise exception 'duties.assignee_id must reference a profile with role in (admin, staff) (got %)', new.assignee_id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."duties_enforce_assignee_is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."duties_enforce_no_busy_overlap"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  duty_end date := coalesce(new.end_date, new.start_date);
begin
  if exists (
    select 1 from public.staff_availability sa
    where sa.user_id = new.assignee_id
      and sa.start_date <= duty_end
      and sa.end_date   >= new.start_date
  ) then
    raise exception 'duties: assignee % is marked busy during % .. %', new.assignee_id, new.start_date, duty_end
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."duties_enforce_no_busy_overlap"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."eo_event_normalize_display_title"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
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


ALTER FUNCTION "public"."eo_event_normalize_display_title"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."event_confirmed_count_one"("p_event_id" "uuid") RETURNS integer
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select count(*)::int from public.bookings
  where status = 'confirmed' and event_id = p_event_id;
$$;


ALTER FUNCTION "public"."event_confirmed_count_one"("p_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."event_confirmed_counts"("p_event_ids" "uuid"[]) RETURNS TABLE("event_id" "uuid", "n" integer)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select event_id, count(*)::int
  from public.bookings
  where status = 'confirmed' and event_id = any(coalesce(p_event_ids, '{}'::uuid[]))
  group by event_id;
$$;


ALTER FUNCTION "public"."event_confirmed_counts"("p_event_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."event_ride_seats"("p_event_id" "uuid") RETURNS TABLE("capacity" integer, "claimed" integer)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."event_ride_seats"("p_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."express_trip_interest"("p_trip_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_diver  uuid := auth.uid();
  v_status text;
  v_code   text;
begin
  if v_diver is null then
    raise exception 'auth required' using errcode = 'insufficient_privilege';
  end if;

  select status into v_status from public.trips where id = p_trip_id;
  if v_status is null then
    raise exception 'trip not found' using errcode = 'no_data_found';
  end if;
  if v_status <> 'published' then
    raise exception 'trip is not open for interest' using errcode = 'check_violation';
  end if;

  select referral_code into v_code from public.trip_referrals
    where trip_id = p_trip_id and diver_id = v_diver and status <> 'cancelled'
    limit 1;
  if v_code is not null then
    return v_code;
  end if;

  insert into public.trip_referrals (trip_id, diver_id)
    values (p_trip_id, v_diver)
    returning referral_code into v_code;
  return v_code;
end;
$$;


ALTER FUNCTION "public"."express_trip_interest"("p_trip_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."gen_referral_code"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
declare
  alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  code text;
  i int;
begin
  loop
    code := 'FD-';
    for i in 1..6 loop
      code := code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.trip_referrals where referral_code = code);
  end loop;
  return code;
end;
$$;


ALTER FUNCTION "public"."gen_referral_code"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_booking_cancellation"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."handle_booking_cancellation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  consented  bool := new.raw_user_meta_data ? 'agreed_to_terms_at';
  client_ver int  := nullif(new.raw_user_meta_data ->> 'agreed_to_terms_version', '')::int;
begin
  insert into public.profiles (id, email, agreed_to_terms_at, agreed_to_terms_version)
  values (
    new.id,
    new.email,
    case when consented then now() else null end,
    case when consented then coalesce(client_ver, 1) else null end
  );
  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_active_user"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and status = 'active'
  )
$$;


ALTER FUNCTION "public"."is_active_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
$$;


ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_staff_or_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('admin','staff')
  )
$$;


ALTER FUNCTION "public"."is_staff_or_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_orphan_auth_user"("p_user_id" "uuid", "p_email" "text", "p_reason" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.orphan_auth_users (user_id, email, reason)
  values (p_user_id, p_email, p_reason);
end;
$$;


ALTER FUNCTION "public"."log_orphan_auth_user"("p_user_id" "uuid", "p_email" "text", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."maybe_set_application_submitted_at"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.application_submitted_at is null
     and new.name           is not null and length(btrim(new.name))         > 0
     and new.date_of_birth   is not null
     and new.cert_level      is not null and length(btrim(new.cert_level))   > 0
     and new.contact_method  is not null
     and new.contact_id      is not null and length(btrim(new.contact_id))   > 0
  then
    new.application_submitted_at := now();
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."maybe_set_application_submitted_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."my_parent_account"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select parent_account from public.profiles where id = auth.uid()
$$;


ALTER FUNCTION "public"."my_parent_account"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."offer_next_waitlist_spot"("p_event_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."offer_next_waitlist_spot"("p_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."profiles_email_mirror_auth"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  new.email := (select email from auth.users where id = new.id);
  return new;
end;
$$;


ALTER FUNCTION "public"."profiles_email_mirror_auth"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."profiles_enforce_one_level_family"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_grandparent uuid;
begin
  if new.parent_account is not null then
    select parent_account into v_grandparent
    from public.profiles where id = new.parent_account;
    if v_grandparent is not null then
      raise exception 'parent_account must itself be a top-level diver (one-level family trees only)'
        using errcode = 'check_violation';
    end if;
    if exists (select 1 from public.profiles where parent_account = new.id) then
      raise exception 'cannot set parent_account on a diver who already has their own children'
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."profiles_enforce_one_level_family"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."purge_stale_pii"("older_than_months" integer DEFAULT 12) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  cutoff             timestamptz := now() - make_interval(months => older_than_months);
  stale_ids          uuid[];
  profiles_affected  int := 0;
  bookings_affected  int := 0;
begin
  select array_agg(p.id) into stale_ids
  from public.profiles p
  left join lateral (
    select max(created_at) as last_booked
    from public.bookings b where b.user_id = p.id
  ) b on true
  where p.role = 'diver'
    and coalesce(b.last_booked, p.created_at) < cutoff;

  if stale_ids is null or array_length(stale_ids, 1) is null then
    return 0;
  end if;

  update public.profiles
  set id_number               = null,
      medical_notes           = null,
      emergency_contact_name  = null,
      emergency_contact_phone = null,
      cert_card_path          = null,
      nitrox_card_path        = null,
      deep_card_path          = null
  where id = any(stale_ids);
  get diagnostics profiles_affected = row_count;

  update public.bookings
  set notes = null
  where user_id = any(stale_ids)
    and notes is not null;
  get diagnostics bookings_affected = row_count;

  insert into public.admin_audit_log (actor_id, action, target_table, target_id, before, after)
  values (
    null,
    'delete',
    'profiles',
    'pii_purge',
    jsonb_build_object(
      'cutoff',                   cutoff,
      'older_than_months',        older_than_months,
      'profile_ids',              to_jsonb(stale_ids),
      'profiles_scrubbed',        profiles_affected,
      'booking_notes_scrubbed',   bookings_affected
    ),
    null
  );

  return profiles_affected;
end;
$$;


ALTER FUNCTION "public"."purge_stale_pii"("older_than_months" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_group_payment"("p_lead" "uuid", "p_amount" numeric, "p_group_id" "uuid" DEFAULT NULL::"uuid") RETURNS numeric
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_caller    uuid    := auth.uid();
  v_remaining numeric;
  v_applied   numeric := 0;
  v_alloc     jsonb   := '{}'::jsonb;
  v_owed      numeric;
  v_paid      numeric;
  v_due       numeric;
  v_deposit   numeric;
  v_dep_due   numeric;
  v_so_far    numeric;
  v_take      numeric;
  v_method    text;
  b           record;
begin
  if v_caller is null then
    raise exception 'auth required' using errcode = 'insufficient_privilege';
  end if;
  if not public.is_admin() then
    raise exception 'admin only' using errcode = 'insufficient_privilege';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount must be positive' using errcode = 'check_violation';
  end if;

  v_remaining := p_amount;

  -- Pass 1: cover each sibling's outstanding deposit, oldest first.
  for b in
    select id, details from public.bookings
    where payer_id = p_lead and status <> 'cancelled'
      and (p_group_id is null or group_id = p_group_id)
    order by created_at asc, id asc
  loop
    exit when v_remaining <= 0;
    v_paid := coalesce((select sum(amount) from public.payments
                        where booking_id = b.id and status = 'paid'), 0);
    v_owed := coalesce((b.details ->> 'total')::numeric, 0)
            + coalesce((select sum(amount) from public.booking_amendments
                        where booking_id = b.id), 0);
    v_due := v_owed - v_paid;
    if v_due <= 0 then continue; end if;
    v_deposit := coalesce((b.details ->> 'deposit')::numeric, 0);
    v_dep_due := least(greatest(v_deposit - v_paid, 0), v_due);
    if v_dep_due <= 0 then continue; end if;
    v_take := least(v_dep_due, v_remaining);
    v_alloc := jsonb_set(v_alloc, array[b.id::text],
                         to_jsonb(coalesce((v_alloc ->> b.id::text)::numeric, 0) + v_take));
    v_remaining := v_remaining - v_take;
  end loop;

  -- Pass 2: apply the rest against remaining balances, oldest first.
  for b in
    select id, details from public.bookings
    where payer_id = p_lead and status <> 'cancelled'
      and (p_group_id is null or group_id = p_group_id)
    order by created_at asc, id asc
  loop
    exit when v_remaining <= 0;
    v_paid := coalesce((select sum(amount) from public.payments
                        where booking_id = b.id and status = 'paid'), 0);
    v_owed := coalesce((b.details ->> 'total')::numeric, 0)
            + coalesce((select sum(amount) from public.booking_amendments
                        where booking_id = b.id), 0);
    v_so_far := coalesce((v_alloc ->> b.id::text)::numeric, 0);
    v_due := v_owed - v_paid - v_so_far;
    if v_due <= 0 then continue; end if;
    v_take := least(v_due, v_remaining);
    v_alloc := jsonb_set(v_alloc, array[b.id::text],
                         to_jsonb(v_so_far + v_take));
    v_remaining := v_remaining - v_take;
  end loop;

  -- Settle: one payment row per allocated booking; confirm pending spots
  -- whose deposit is now covered.
  for b in
    select id, user_id, status, details from public.bookings
    where payer_id = p_lead and status <> 'cancelled'
      and (p_group_id is null or group_id = p_group_id)
    order by created_at asc, id asc
  loop
    v_take := coalesce((v_alloc ->> b.id::text)::numeric, 0);
    if v_take <= 0 then continue; end if;
    v_method := b.details ->> 'payment_method';

    insert into public.payments (user_id, booking_id, amount, status, method, note, recorded_by)
    values (b.user_id, b.id, v_take, 'paid', v_method, 'Group payment', v_caller);
    v_applied := v_applied + v_take;

    v_paid := coalesce((select sum(amount) from public.payments
                        where booking_id = b.id and status = 'paid'), 0);
    v_deposit := coalesce((b.details ->> 'deposit')::numeric, 0);
    if b.status = 'pending' and v_paid >= v_deposit then
      update public.bookings set status = 'confirmed' where id = b.id;
    end if;
  end loop;

  return v_applied;
end;
$$;


ALTER FUNCTION "public"."record_group_payment"("p_lead" "uuid", "p_amount" numeric, "p_group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_signup_attempt"("p_ip_hash" "bytea") RETURNS TABLE("in_last_60s" integer, "in_last_24h" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.signup_attempts (ip_hash) values (p_ip_hash);
  return query
    select
      count(*) filter (where created_at > now() - interval '60 seconds')::int,
      count(*) filter (where created_at > now() - interval '24 hours')::int
    from public.signup_attempts
    where ip_hash = p_ip_hash;
end;
$$;


ALTER FUNCTION "public"."record_signup_attempt"("p_ip_hash" "bytea") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_event_display_title"("p_event_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."refresh_event_display_title"("p_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_dive_log_number"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if new.dive_number is null then
    perform pg_advisory_xact_lock(hashtext(new.user_id::text));
    select coalesce(max(dive_number), 0) + 1
      into new.dive_number
      from public.dive_logs
      where user_id = new.user_id;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."set_dive_log_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_event_relations"("p_event_id" "uuid", "p_room_ids" "uuid"[] DEFAULT '{}'::"uuid"[], "p_addon_ids" "uuid"[] DEFAULT '{}'::"uuid"[], "p_destination_ids" "text"[] DEFAULT '{}'::"text"[]) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."set_event_relations"("p_event_id" "uuid", "p_room_ids" "uuid"[], "p_addon_ids" "uuid"[], "p_destination_ids" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_waitlisted_when_event_full"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
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


ALTER FUNCTION "public"."set_waitlisted_when_event_full"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sign_waiver"("p_code" "text", "p_version" integer, "p_signed_name" "text", "p_event_id" "uuid" DEFAULT NULL::"uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."sign_waiver"("p_code" "text", "p_version" integer, "p_signed_name" "text", "p_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."staff_availability_enforce_owner_role"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if not exists (
    select 1 from public.profiles
    where id = new.user_id and role in ('admin','staff')
  ) then
    raise exception 'staff_availability.user_id must reference a profile with role in (admin, staff) (got %)', new.user_id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."staff_availability_enforce_owner_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."strip_capacity_suffix"("p_title" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $_$
  select regexp_replace(
    coalesce(p_title, ''),
    '\s*\((?:\d+\s*spots?\s*open|fully booked\s*[-–—]+\s*register for waitlist)\)\s*$',
    '',
    'i'
  );
$_$;


ALTER FUNCTION "public"."strip_capacity_suffix"("p_title" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_profile_email"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update public.profiles set email = new.email where id = new.id;
  return new;
end;
$$;


ALTER FUNCTION "public"."sync_profile_email"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_dive_log_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


ALTER FUNCTION "public"."touch_dive_log_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_staff_availability_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


ALTER FUNCTION "public"."touch_staff_availability_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_bookings_refresh_event_title"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."trg_bookings_refresh_event_title"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trip_referrals_set_code"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if new.referral_code is null or new.referral_code = '' then
    new.referral_code := public.gen_referral_code();
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."trip_referrals_set_code"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_diver_gear_sizes"("diver_id" "uuid", "fin_size" "text", "bcd_size" "text", "wetsuit_size" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not public.is_staff_or_admin() then
    raise exception 'staff or admin required'
      using errcode = 'insufficient_privilege';
  end if;
  update public.profiles
  set fin_size     = nullif(btrim(coalesce(update_diver_gear_sizes.fin_size,     '')), ''),
      bcd_size     = nullif(btrim(coalesce(update_diver_gear_sizes.bcd_size,     '')), ''),
      wetsuit_size = nullif(btrim(coalesce(update_diver_gear_sizes.wetsuit_size, '')), '')
  where id = update_diver_gear_sizes.diver_id;
end;
$$;


ALTER FUNCTION "public"."update_diver_gear_sizes"("diver_id" "uuid", "fin_size" "text", "bcd_size" "text", "wetsuit_size" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."DiveTravel" (
    "_id" "text" NOT NULL,
    "admin_title" "text",
    "included" "text",
    "not_included" "text",
    "transportation" "text",
    "Created Date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "Updated Date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "Owner" "text",
    "slug" "text",
    "event_type" "text",
    "picture" "text",
    "description" "text",
    "tagline" "text",
    "tagline_text" "text",
    "details" "text",
    "prerequisites" "text",
    "itinerary" "text",
    "event_date" "text",
    "price" "text",
    "sort_order" timestamp with time zone,
    "trip_link" "text",
    "planned_trip" boolean,
    "details_document" "text",
    "local_event_link" "text",
    "local" boolean,
    "trip" boolean
);


ALTER TABLE "public"."DiveTravel" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."EO_prices" (
    "admin_title" "text" NOT NULL,
    "price" "text",
    "starting_at" bigint,
    "deposit_amount" bigint,
    "transport" bigint,
    "_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "Created Date" timestamp with time zone,
    "Updated Date" timestamp with time zone,
    "Owner" "text",
    "EO_dives_price" "text"
);


ALTER TABLE "public"."EO_prices" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."EO_rooms" (
    "admin_title" "text",
    "display_title" "text",
    "added_price" bigint,
    "added_price_display" "text",
    "per_night" "text",
    "EO_prices_room_options" "jsonb",
    "_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "Created Date" timestamp with time zone,
    "Updated Date" timestamp with time zone,
    "Owner" "text",
    "EO_dives_room_types" "jsonb",
    "currency" "text"
);


ALTER TABLE "public"."EO_rooms" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."Other_Addons" (
    "admin_title" "text",
    "price" bigint,
    "display_title" "text",
    "currency" "text",
    "EO_dives_other_addons" "text",
    "EO_courses_other_addons" "text",
    "_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "Created Date" timestamp with time zone,
    "Updated Date" timestamp with time zone,
    "Owner" "text"
);


ALTER TABLE "public"."Other_Addons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."TravelDestinations" (
    "_id" "text" NOT NULL,
    "admin_title" "text",
    "slug" "text",
    "tagline" "text",
    "country" "text",
    "divetype" "text",
    "sort_order" integer,
    "latitude" numeric,
    "longitude" numeric,
    "international" boolean,
    "northeast_diving" boolean,
    "location_picture" "text",
    "background_picture" "text",
    "diver_requirements" "text",
    "Created Date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "Updated Date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "Owner" "text"
);


ALTER TABLE "public"."TravelDestinations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."admin_audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "actor_id" "uuid",
    "action" "text" NOT NULL,
    "target_table" "text" NOT NULL,
    "target_id" "text" NOT NULL,
    "before" "jsonb",
    "after" "jsonb",
    CONSTRAINT "admin_audit_log_action_check" CHECK (("action" = ANY (ARRAY['insert'::"text", 'update'::"text", 'delete'::"text"])))
);


ALTER TABLE "public"."admin_audit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."admin_notes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid" NOT NULL,
    "booking_id" "uuid",
    "tag" "text" NOT NULL,
    "content" "text" NOT NULL,
    "resolved" boolean DEFAULT false NOT NULL,
    "resolved_by" "uuid",
    "resolved_at" timestamp with time zone,
    "event_id" "uuid",
    CONSTRAINT "admin_notes_content_check" CHECK ((("char_length"("content") >= 1) AND ("char_length"("content") <= 2000))),
    CONSTRAINT "admin_notes_resolved_consistency" CHECK (((("resolved" = true) AND ("resolved_by" IS NOT NULL) AND ("resolved_at" IS NOT NULL)) OR (("resolved" = false) AND ("resolved_by" IS NULL) AND ("resolved_at" IS NULL)))),
    CONSTRAINT "admin_notes_tag_check" CHECK (("tag" = ANY (ARRAY['urgent'::"text", 'payment'::"text", 'gear'::"text", 'logistics'::"text", 'cert'::"text", 'medical'::"text", 'note'::"text", 'general'::"text"]))),
    CONSTRAINT "admin_notes_target_present" CHECK ((((("event_id" IS NOT NULL))::integer + (("booking_id" IS NOT NULL))::integer) = 1))
);


ALTER TABLE "public"."admin_notes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."booking_amendments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "booking_id" "uuid" NOT NULL,
    "amount" integer NOT NULL,
    "note" "text" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "booking_amendments_amount_check" CHECK (("amount" <> 0)),
    CONSTRAINT "booking_amendments_note_check" CHECK ((("length"("btrim"("note")) > 0) AND ("length"("note") <= 1000)))
);


ALTER TABLE "public"."booking_amendments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bookings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "notes" "text",
    "details" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "refund_requested_at" timestamp with time zone,
    "group_id" "uuid",
    "payer_id" "uuid",
    "event_id" "uuid",
    CONSTRAINT "bookings_details_is_object" CHECK (("jsonb_typeof"("details") = 'object'::"text")),
    CONSTRAINT "bookings_event_present" CHECK (("event_id" IS NOT NULL)),
    CONSTRAINT "bookings_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'confirmed'::"text", 'cancelled'::"text", 'waitlisted'::"text"])))
);


ALTER TABLE "public"."bookings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cancellation_policies" (
    "_id" "text" NOT NULL,
    "title" "text",
    "cancelation_policy" "text",
    "Created Date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "Updated Date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "Owner" "text"
);


ALTER TABLE "public"."cancellation_policies" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cert_levels" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "name_zh" "text",
    "rank" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "organization" "text" NOT NULL,
    "padi_equivalent_id" "uuid",
    CONSTRAINT "cert_levels_rank_positive" CHECK (("rank" > 0))
);


ALTER TABLE "public"."cert_levels" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."credits" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "booking_id" "uuid",
    "amount" numeric(10,2) NOT NULL,
    "currency" "text" DEFAULT 'TWD'::"text" NOT NULL,
    "reason" "text" NOT NULL,
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "created_by" "uuid",
    "settled_at" timestamp with time zone,
    "settled_note" "text",
    CONSTRAINT "credits_amount_check" CHECK (("amount" > (0)::numeric)),
    CONSTRAINT "credits_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'settled'::"text"])))
);


ALTER TABLE "public"."credits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dive_log_export_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "requested_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."dive_log_export_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dive_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "dive_number" integer NOT NULL,
    "dived_on" "date" NOT NULL,
    "site" "text" NOT NULL,
    "dive_type" "text",
    "max_depth_m" numeric(4,1),
    "dive_time_min" integer,
    "visibility_m" numeric(4,1),
    "water_temp_c" numeric(3,1),
    "air_temp_c" numeric(3,1),
    "weather" "text",
    "wave_height_m" numeric(3,1),
    "weight_kg" numeric(3,1),
    "gear_used" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "gas_mix" "text",
    "tank_size_l" numeric(3,1),
    "start_pressure_bar" integer,
    "end_pressure_bar" integer,
    "buddy_name" "text",
    "instructor_name" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "dive_logs_depth_chk" CHECK ((("max_depth_m" IS NULL) OR (("max_depth_m" >= (0)::numeric) AND ("max_depth_m" <= (200)::numeric)))),
    CONSTRAINT "dive_logs_dive_time_chk" CHECK ((("dive_time_min" IS NULL) OR (("dive_time_min" >= 0) AND ("dive_time_min" <= 480)))),
    CONSTRAINT "dive_logs_dive_type_chk" CHECK ((("dive_type" IS NULL) OR ("dive_type" = ANY (ARRAY['shore'::"text", 'boat'::"text", 'training'::"text", 'drift'::"text", 'night'::"text", 'wreck'::"text", 'other'::"text"])))),
    CONSTRAINT "dive_logs_gas_mix_chk" CHECK ((("gas_mix" IS NULL) OR ("gas_mix" = ANY (ARRAY['air'::"text", 'EAN32'::"text", 'EAN36'::"text", 'other'::"text"])))),
    CONSTRAINT "dive_logs_pressure_chk" CHECK (((("start_pressure_bar" IS NULL) OR (("start_pressure_bar" >= 0) AND ("start_pressure_bar" <= 350))) AND (("end_pressure_bar" IS NULL) OR (("end_pressure_bar" >= 0) AND ("end_pressure_bar" <= 350)))))
);


ALTER TABLE "public"."dive_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."diver_notes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "content" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "edited_by" "uuid",
    "edited_at" timestamp with time zone,
    CONSTRAINT "diver_notes_content_check" CHECK ((("char_length"("content") >= 1) AND ("char_length"("content") <= 2000)))
);


ALTER TABLE "public"."diver_notes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."duties" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    "assignee_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "start_date" "date" NOT NULL,
    "end_date" "date",
    "notes" "text",
    "event_id" "uuid",
    CONSTRAINT "duties_date_order" CHECK ((("end_date" IS NULL) OR ("end_date" >= "start_date"))),
    CONSTRAINT "duties_notes_check" CHECK ((("notes" IS NULL) OR (("char_length"("notes") >= 1) AND ("char_length"("notes") <= 2000)))),
    CONSTRAINT "duties_role_check" CHECK (("role" = ANY (ARRAY['instructor'::"text", 'guide'::"text", 'support'::"text"])))
);


ALTER TABLE "public"."duties" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_addons" (
    "event_id" "uuid" NOT NULL,
    "addon_id" "uuid" NOT NULL
);


ALTER TABLE "public"."event_addons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_destinations" (
    "event_id" "uuid" NOT NULL,
    "destination_id" "text" NOT NULL
);


ALTER TABLE "public"."event_destinations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_rooms" (
    "event_id" "uuid" NOT NULL,
    "room_id" "uuid" NOT NULL
);


ALTER TABLE "public"."event_rooms" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_vehicles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    "vehicle_id" "uuid" NOT NULL,
    "event_date" "date" NOT NULL,
    "notes" "text",
    "event_id" "uuid",
    CONSTRAINT "event_vehicles_event_present" CHECK (("event_id" IS NOT NULL)),
    CONSTRAINT "event_vehicles_notes_check" CHECK ((("notes" IS NULL) OR (("char_length"("notes") >= 1) AND ("char_length"("notes") <= 2000))))
);


ALTER TABLE "public"."event_vehicles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_waivers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    "waiver_code" "text" NOT NULL,
    "mode" "text" NOT NULL,
    "event_id" "uuid",
    CONSTRAINT "event_waivers_event_present" CHECK (("event_id" IS NOT NULL)),
    CONSTRAINT "event_waivers_mode_check" CHECK (("mode" = ANY (ARRAY['require'::"text", 'exempt'::"text"]))),
    CONSTRAINT "event_waivers_waiver_code_check" CHECK ((("char_length"("waiver_code") >= 1) AND ("char_length"("waiver_code") <= 100)))
);


ALTER TABLE "public"."event_waivers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "kind" "text" NOT NULL,
    "admin_title" "text",
    "display_title" "text",
    "calendar_title" "text",
    "price" "uuid",
    "dive_days" bigint,
    "prereq_cert_id" "uuid",
    "cancel_date" "date",
    "cancel_policy" "text",
    "fully_booked" boolean DEFAULT false NOT NULL,
    "capacity" integer,
    "full_payment_deadline" "date",
    "cancelled_at" timestamp with time zone,
    "featured_image" "text",
    "prereqs" "text",
    "featured" boolean DEFAULT false NOT NULL,
    "req_dives" integer,
    "start_date" "date",
    "end_date" "date",
    "start_time" time without time zone,
    "course_days" "date"[],
    "is_private" boolean DEFAULT false NOT NULL,
    "nitrox_required" boolean DEFAULT false NOT NULL,
    "second_image" "text",
    "gear_rental" "text",
    "notes" "text",
    "divetravel_id" "text",
    "course_name" "text",
    "included" "text",
    "schedule" "text",
    "starting_at" integer,
    CONSTRAINT "events_capacity_check" CHECK ((("capacity" IS NULL) OR ("capacity" >= 0))),
    CONSTRAINT "events_course_has_days" CHECK ((("kind" <> 'course'::"text") OR (("course_days" IS NOT NULL) AND (("array_length"("course_days", 1) >= 1) AND ("array_length"("course_days", 1) <= 4))))),
    CONSTRAINT "events_dive_has_start" CHECK ((("kind" <> 'dive'::"text") OR ("start_date" IS NOT NULL))),
    CONSTRAINT "events_kind_check" CHECK (("kind" = ANY (ARRAY['dive'::"text", 'course'::"text"])))
);


ALTER TABLE "public"."events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."partner_shops" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text" NOT NULL,
    "country" "text" NOT NULL,
    "location" "text",
    "website" "text",
    "contact_name" "text",
    "contact_email" "text",
    "vouch_notes" "text",
    "logo_url" "text",
    "default_kickback_rate" numeric(5,4) DEFAULT 0.05 NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_by" "uuid",
    CONSTRAINT "partner_shops_default_kickback_rate_check" CHECK ((("default_kickback_rate" >= (0)::numeric) AND ("default_kickback_rate" <= (1)::numeric)))
);


ALTER TABLE "public"."partner_shops" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trip_referrals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "diver_id" "uuid" NOT NULL,
    "referral_code" "text" NOT NULL,
    "status" "text" DEFAULT 'interested'::"text" NOT NULL,
    "booked_amount" numeric(10,2),
    "booked_currency" "text",
    "kickback_rate" numeric(5,4),
    "kickback_amount" numeric(12,2) GENERATED ALWAYS AS ("round"(("booked_amount" * "kickback_rate"), 2)) STORED,
    "kickback_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "received_at" timestamp with time zone,
    "admin_notes" "text",
    CONSTRAINT "trip_referrals_booked_amount_check" CHECK ((("booked_amount" IS NULL) OR ("booked_amount" >= (0)::numeric))),
    CONSTRAINT "trip_referrals_kickback_rate_check" CHECK ((("kickback_rate" IS NULL) OR (("kickback_rate" >= (0)::numeric) AND ("kickback_rate" <= (1)::numeric)))),
    CONSTRAINT "trip_referrals_kickback_status_check" CHECK (("kickback_status" = ANY (ARRAY['pending'::"text", 'invoiced'::"text", 'received'::"text"]))),
    CONSTRAINT "trip_referrals_status_check" CHECK (("status" = ANY (ARRAY['interested'::"text", 'introduced'::"text", 'booked'::"text", 'completed'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."trip_referrals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trips" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "partner_shop_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "destination" "text" NOT NULL,
    "summary" "text",
    "description" "text",
    "start_date" "date",
    "end_date" "date",
    "price" numeric(10,2),
    "currency" "text" DEFAULT 'TWD'::"text" NOT NULL,
    "hero_image_url" "text",
    "highlights" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "booking_url" "text",
    "kickback_rate" numeric(5,4) DEFAULT 0.05 NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "published_at" timestamp with time zone,
    "created_by" "uuid",
    CONSTRAINT "trips_check" CHECK ((("end_date" IS NULL) OR ("start_date" IS NULL) OR ("end_date" >= "start_date"))),
    CONSTRAINT "trips_kickback_rate_check" CHECK ((("kickback_rate" >= (0)::numeric) AND ("kickback_rate" <= (1)::numeric))),
    CONSTRAINT "trips_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'published'::"text", 'archived'::"text"])))
);


ALTER TABLE "public"."trips" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."my_trip_referrals" AS
 SELECT "r"."id",
    "r"."trip_id",
    "r"."referral_code",
    "r"."status",
    "r"."created_at",
    "t"."title" AS "trip_title",
    "t"."destination" AS "trip_destination",
    "ps"."name" AS "partner_name"
   FROM (("public"."trip_referrals" "r"
     JOIN "public"."trips" "t" ON (("t"."id" = "r"."trip_id")))
     JOIN "public"."partner_shops" "ps" ON (("ps"."id" = "t"."partner_shop_id")))
  WHERE ("r"."diver_id" = "auth"."uid"());


ALTER VIEW "public"."my_trip_referrals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text",
    "url" "text",
    "kind" "text" NOT NULL,
    "event_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "read_at" timestamp with time zone
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."orphan_auth_users" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "email" "text",
    "reason" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."orphan_auth_users" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "booking_id" "uuid",
    "amount" numeric(10,2) NOT NULL,
    "currency" "text" DEFAULT 'TWD'::"text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "method" "text",
    "note" "text",
    "recorded_by" "uuid",
    CONSTRAINT "payments_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'paid'::"text", 'refunded'::"text", 'voided'::"text"])))
);


ALTER TABLE "public"."payments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text",
    "nickname" "text",
    "date_of_birth" "date",
    "nationality" "text",
    "id_number" "text",
    "emergency_contact_name" "text",
    "emergency_contact_phone" "text",
    "cert_agency" "text",
    "cert_level" "text",
    "medical_notes" "text",
    "avatar_url" "text",
    "role" "text" DEFAULT 'diver'::"text" NOT NULL,
    "height_cm" numeric,
    "weight_kg" numeric,
    "shoe_size" "text",
    "gender" "text",
    "contact_method" "text",
    "contact_id" "text",
    "nitrox_certified" boolean DEFAULT false NOT NULL,
    "logged_dives" integer DEFAULT 0 NOT NULL,
    "last_dive_date" "date",
    "gear_owned" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "cert_card_path" "text",
    "agreed_to_terms_at" timestamp with time zone,
    "fin_size" "text",
    "bcd_size" "text",
    "wetsuit_size" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "application_submitted_at" timestamp with time zone,
    "parent_account" "uuid",
    "nitrox_card_path" "text",
    "deep_certified" boolean DEFAULT false NOT NULL,
    "deep_card_path" "text",
    "agreed_to_terms_version" integer,
    "email" "text",
    "uncertified" boolean DEFAULT false NOT NULL,
    CONSTRAINT "profiles_contact_method_check" CHECK (("contact_method" = ANY (ARRAY['whatsapp'::"text", 'line'::"text", 'phone'::"text", 'email'::"text"]))),
    CONSTRAINT "profiles_logged_dives_check" CHECK (("logged_dives" >= 0)),
    CONSTRAINT "profiles_role_check" CHECK (("role" = ANY (ARRAY['diver'::"text", 'admin'::"text", 'staff'::"text"]))),
    CONSTRAINT "profiles_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'active'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."push_notifications_sent" (
    "user_id" "uuid" NOT NULL,
    "event_id" "text" NOT NULL,
    "event_type" "text" NOT NULL,
    "kind" "text" NOT NULL,
    "sent_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "push_notifications_sent_event_type_check" CHECK (("event_type" = ANY (ARRAY['dive'::"text", 'course'::"text"]))),
    CONSTRAINT "push_notifications_sent_kind_check" CHECK (("kind" = ANY (ARRAY['event_7d'::"text", 'event_1d'::"text", 'payment_21d'::"text", 'payment_14d'::"text", 'payment_7d'::"text", 'payment_3d'::"text", 'payment_1d'::"text"])))
);


ALTER TABLE "public"."push_notifications_sent" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."push_subscriptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "endpoint" "text" NOT NULL,
    "p256dh" "text" NOT NULL,
    "auth" "text" NOT NULL,
    "user_agent" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_seen_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."push_subscriptions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."signup_attempts" (
    "id" bigint NOT NULL,
    "ip_hash" "bytea" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."signup_attempts" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."signup_attempts_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."signup_attempts_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."signup_attempts_id_seq" OWNED BY "public"."signup_attempts"."id";



CREATE TABLE IF NOT EXISTS "public"."staff_availability" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "start_date" "date" NOT NULL,
    "start_time" time without time zone NOT NULL,
    "end_date" "date" NOT NULL,
    "title" "text" NOT NULL,
    "details" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "staff_availability_date_order" CHECK (("end_date" >= "start_date")),
    CONSTRAINT "staff_availability_details_check" CHECK ((("details" IS NULL) OR ("char_length"("details") <= 2000))),
    CONSTRAINT "staff_availability_title_check" CHECK ((("char_length"("title") >= 1) AND ("char_length"("title") <= 200)))
);


ALTER TABLE "public"."staff_availability" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."staff_availability_view" WITH ("security_invoker"='on') AS
 SELECT "sa"."id",
    "sa"."user_id",
    "sa"."start_date",
    "sa"."start_time",
    "sa"."end_date",
        CASE
            WHEN ("sa"."user_id" = "auth"."uid"()) THEN "sa"."title"
            ELSE NULL::"text"
        END AS "title",
        CASE
            WHEN ("sa"."user_id" = "auth"."uid"()) THEN "sa"."details"
            ELSE NULL::"text"
        END AS "details",
    COALESCE("p"."nickname", "p"."name") AS "owner_display_name",
    "sa"."created_at",
    "sa"."updated_at"
   FROM ("public"."staff_availability" "sa"
     LEFT JOIN "public"."profiles" "p" ON (("p"."id" = "sa"."user_id")));


ALTER VIEW "public"."staff_availability_view" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."trip_board" AS
 SELECT "t"."id",
    "t"."title",
    "t"."destination",
    "t"."summary",
    "t"."description",
    "t"."start_date",
    "t"."end_date",
    "t"."price",
    "t"."currency",
    "t"."hero_image_url",
    "t"."highlights",
    "t"."booking_url",
    "t"."published_at",
    "ps"."id" AS "partner_shop_id",
    "ps"."name" AS "partner_name",
    "ps"."country" AS "partner_country",
    "ps"."location" AS "partner_location",
    "ps"."website" AS "partner_website",
    "ps"."logo_url" AS "partner_logo_url",
    "ps"."vouch_notes" AS "partner_vouch_notes"
   FROM ("public"."trips" "t"
     JOIN "public"."partner_shops" "ps" ON (("ps"."id" = "t"."partner_shop_id")))
  WHERE ("t"."status" = 'published'::"text");


ALTER VIEW "public"."trip_board" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."vehicles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text" NOT NULL,
    "passenger_seats" integer NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_by" "uuid",
    CONSTRAINT "vehicles_passenger_seats_check" CHECK (("passenger_seats" >= 1))
);


ALTER TABLE "public"."vehicles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."waitlist_offers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "booking_id" "uuid" NOT NULL,
    "offered_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '24:00:00'::interval) NOT NULL,
    "notified_at" timestamp with time zone,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    CONSTRAINT "waitlist_offers_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text", 'expired'::"text"])))
);


ALTER TABLE "public"."waitlist_offers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."waiver_signatures" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "diver_id" "uuid" NOT NULL,
    "waiver_code" "text" NOT NULL,
    "waiver_version" integer NOT NULL,
    "signed_name" "text" NOT NULL,
    "signed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "event_id" "uuid",
    CONSTRAINT "waiver_signatures_signed_name_check" CHECK ((("char_length"("signed_name") >= 1) AND ("char_length"("signed_name") <= 200))),
    CONSTRAINT "waiver_signatures_waiver_code_check" CHECK ((("char_length"("waiver_code") >= 1) AND ("char_length"("waiver_code") <= 100))),
    CONSTRAINT "waiver_signatures_waiver_version_check" CHECK (("waiver_version" > 0))
);


ALTER TABLE "public"."waiver_signatures" OWNER TO "postgres";


ALTER TABLE ONLY "public"."signup_attempts" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."signup_attempts_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."DiveTravel"
    ADD CONSTRAINT "DiveTravel_pkey" PRIMARY KEY ("_id");



ALTER TABLE ONLY "public"."EO_prices"
    ADD CONSTRAINT "EO_prices_pkey" PRIMARY KEY ("_id");



ALTER TABLE ONLY "public"."EO_rooms"
    ADD CONSTRAINT "EO_rooms_pkey" PRIMARY KEY ("_id");



ALTER TABLE ONLY "public"."Other_Addons"
    ADD CONSTRAINT "Other_Addons_pkey" PRIMARY KEY ("_id");



ALTER TABLE ONLY "public"."TravelDestinations"
    ADD CONSTRAINT "TravelDestinations_pkey" PRIMARY KEY ("_id");



ALTER TABLE ONLY "public"."admin_audit_log"
    ADD CONSTRAINT "admin_audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."admin_notes"
    ADD CONSTRAINT "admin_notes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."booking_amendments"
    ADD CONSTRAINT "booking_amendments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cancellation_policies"
    ADD CONSTRAINT "cancellation_policies_pkey" PRIMARY KEY ("_id");



ALTER TABLE ONLY "public"."cert_levels"
    ADD CONSTRAINT "cert_levels_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."cert_levels"
    ADD CONSTRAINT "cert_levels_org_rank_unique" UNIQUE ("organization", "rank");



ALTER TABLE ONLY "public"."cert_levels"
    ADD CONSTRAINT "cert_levels_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."credits"
    ADD CONSTRAINT "credits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dive_log_export_requests"
    ADD CONSTRAINT "dive_log_export_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dive_logs"
    ADD CONSTRAINT "dive_logs_dive_number_per_user" UNIQUE ("user_id", "dive_number");



ALTER TABLE ONLY "public"."dive_logs"
    ADD CONSTRAINT "dive_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."diver_notes"
    ADD CONSTRAINT "diver_notes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."duties"
    ADD CONSTRAINT "duties_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_addons"
    ADD CONSTRAINT "event_addons_pkey" PRIMARY KEY ("event_id", "addon_id");



ALTER TABLE ONLY "public"."event_destinations"
    ADD CONSTRAINT "event_destinations_pkey" PRIMARY KEY ("event_id", "destination_id");



ALTER TABLE ONLY "public"."event_rooms"
    ADD CONSTRAINT "event_rooms_pkey" PRIMARY KEY ("event_id", "room_id");



ALTER TABLE ONLY "public"."event_vehicles"
    ADD CONSTRAINT "event_vehicles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_waivers"
    ADD CONSTRAINT "event_waivers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."orphan_auth_users"
    ADD CONSTRAINT "orphan_auth_users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."partner_shops"
    ADD CONSTRAINT "partner_shops_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");



ALTER TABLE "public"."profiles"
    ADD CONSTRAINT "profiles_no_self_parent" CHECK ((("parent_account" IS NULL) OR ("parent_account" <> "id"))) NOT VALID;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."push_notifications_sent"
    ADD CONSTRAINT "push_notifications_sent_pkey" PRIMARY KEY ("user_id", "event_id", "kind");



ALTER TABLE ONLY "public"."push_subscriptions"
    ADD CONSTRAINT "push_subscriptions_endpoint_key" UNIQUE ("endpoint");



ALTER TABLE ONLY "public"."push_subscriptions"
    ADD CONSTRAINT "push_subscriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."signup_attempts"
    ADD CONSTRAINT "signup_attempts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."staff_availability"
    ADD CONSTRAINT "staff_availability_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_referrals"
    ADD CONSTRAINT "trip_referrals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_referrals"
    ADD CONSTRAINT "trip_referrals_referral_code_key" UNIQUE ("referral_code");



ALTER TABLE ONLY "public"."trips"
    ADD CONSTRAINT "trips_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vehicles"
    ADD CONSTRAINT "vehicles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."waitlist_offers"
    ADD CONSTRAINT "waitlist_offers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."waiver_signatures"
    ADD CONSTRAINT "waiver_signatures_pkey" PRIMARY KEY ("id");



CREATE INDEX "admin_audit_log_actor_idx" ON "public"."admin_audit_log" USING "btree" ("actor_id", "created_at" DESC);



CREATE INDEX "admin_audit_log_recent_idx" ON "public"."admin_audit_log" USING "btree" ("created_at" DESC);



CREATE INDEX "admin_audit_log_target_idx" ON "public"."admin_audit_log" USING "btree" ("target_table", "target_id", "created_at" DESC);



CREATE INDEX "admin_notes_booking_idx" ON "public"."admin_notes" USING "btree" ("booking_id") WHERE ("booking_id" IS NOT NULL);



CREATE INDEX "admin_notes_event_idx" ON "public"."admin_notes" USING "btree" ("event_id") WHERE ("event_id" IS NOT NULL);



CREATE INDEX "admin_notes_open_idx" ON "public"."admin_notes" USING "btree" ("created_at" DESC) WHERE ("resolved" = false);



CREATE INDEX "booking_amendments_booking_idx" ON "public"."booking_amendments" USING "btree" ("booking_id", "created_at");



CREATE INDEX "bookings_group_id_idx" ON "public"."bookings" USING "btree" ("group_id") WHERE ("group_id" IS NOT NULL);



CREATE UNIQUE INDEX "bookings_one_active_per_user_idx" ON "public"."bookings" USING "btree" ("user_id", "event_id") WHERE (("event_id" IS NOT NULL) AND ("status" <> 'cancelled'::"text"));



CREATE INDEX "bookings_payer_id_idx" ON "public"."bookings" USING "btree" ("payer_id") WHERE ("payer_id" IS NOT NULL);



CREATE INDEX "credits_open_idx" ON "public"."credits" USING "btree" ("user_id") WHERE ("status" = 'open'::"text");



CREATE INDEX "credits_user_id_idx" ON "public"."credits" USING "btree" ("user_id");



CREATE INDEX "dive_log_export_requests_user_time_idx" ON "public"."dive_log_export_requests" USING "btree" ("user_id", "requested_at" DESC);



CREATE INDEX "dive_logs_user_dived_on_idx" ON "public"."dive_logs" USING "btree" ("user_id", "dived_on" DESC, "dive_number" DESC);



CREATE INDEX "diver_notes_profile_idx" ON "public"."diver_notes" USING "btree" ("profile_id", "created_at" DESC);



CREATE INDEX "duties_assignee_idx" ON "public"."duties" USING "btree" ("assignee_id", "start_date");



CREATE INDEX "duties_date_idx" ON "public"."duties" USING "btree" ("start_date");



CREATE INDEX "duties_event_idx" ON "public"."duties" USING "btree" ("event_id") WHERE ("event_id" IS NOT NULL);



CREATE INDEX "event_vehicles_date_idx" ON "public"."event_vehicles" USING "btree" ("event_date");



CREATE INDEX "event_vehicles_event_idx" ON "public"."event_vehicles" USING "btree" ("event_id") WHERE ("event_id" IS NOT NULL);



CREATE UNIQUE INDEX "event_vehicles_vehicle_date_uniq" ON "public"."event_vehicles" USING "btree" ("vehicle_id", "event_date");



CREATE UNIQUE INDEX "event_waivers_event_code_uniq" ON "public"."event_waivers" USING "btree" ("event_id", "waiver_code") WHERE ("event_id" IS NOT NULL);



CREATE INDEX "events_active_idx" ON "public"."events" USING "btree" ("start_date") WHERE ("cancelled_at" IS NULL);



CREATE INDEX "events_course_days_idx" ON "public"."events" USING "gin" ("course_days");



CREATE INDEX "events_kind_start_idx" ON "public"."events" USING "btree" ("kind", "start_date");



CREATE INDEX "events_price_idx" ON "public"."events" USING "btree" ("price");



CREATE INDEX "notifications_user_created_idx" ON "public"."notifications" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "notifications_user_unread_idx" ON "public"."notifications" USING "btree" ("user_id") WHERE ("read_at" IS NULL);



CREATE INDEX "orphan_auth_users_created_idx" ON "public"."orphan_auth_users" USING "btree" ("created_at" DESC);



CREATE INDEX "profiles_parent_account_idx" ON "public"."profiles" USING "btree" ("parent_account") WHERE ("parent_account" IS NOT NULL);



CREATE INDEX "profiles_pending_submitted_idx" ON "public"."profiles" USING "btree" ("application_submitted_at" DESC) WHERE (("status" = 'pending'::"text") AND ("application_submitted_at" IS NOT NULL));



CREATE INDEX "profiles_status_pending_idx" ON "public"."profiles" USING "btree" ("created_at" DESC) WHERE ("status" = 'pending'::"text");



CREATE INDEX "push_subscriptions_user_id_idx" ON "public"."push_subscriptions" USING "btree" ("user_id");



CREATE INDEX "signup_attempts_created_idx" ON "public"."signup_attempts" USING "btree" ("created_at" DESC);



CREATE INDEX "signup_attempts_ip_recent_idx" ON "public"."signup_attempts" USING "btree" ("ip_hash", "created_at" DESC);



CREATE INDEX "staff_availability_range_idx" ON "public"."staff_availability" USING "btree" ("start_date", "end_date");



CREATE INDEX "staff_availability_user_idx" ON "public"."staff_availability" USING "btree" ("user_id", "start_date");



CREATE INDEX "trip_referrals_diver_idx" ON "public"."trip_referrals" USING "btree" ("diver_id");



CREATE UNIQUE INDEX "trip_referrals_one_live_idx" ON "public"."trip_referrals" USING "btree" ("trip_id", "diver_id") WHERE ("status" <> 'cancelled'::"text");



CREATE INDEX "trip_referrals_trip_idx" ON "public"."trip_referrals" USING "btree" ("trip_id");



CREATE INDEX "trips_partner_idx" ON "public"."trips" USING "btree" ("partner_shop_id");



CREATE INDEX "trips_published_idx" ON "public"."trips" USING "btree" ("status", "start_date") WHERE ("status" = 'published'::"text");



CREATE INDEX "waitlist_offers_booking_idx" ON "public"."waitlist_offers" USING "btree" ("booking_id");



CREATE UNIQUE INDEX "waitlist_offers_one_pending_per_booking_idx" ON "public"."waitlist_offers" USING "btree" ("booking_id") WHERE ("status" = 'pending'::"text");



CREATE INDEX "waitlist_offers_status_expires_idx" ON "public"."waitlist_offers" USING "btree" ("status", "expires_at");



CREATE INDEX "waiver_signatures_diver_code_idx" ON "public"."waiver_signatures" USING "btree" ("diver_id", "waiver_code");



CREATE INDEX "waiver_signatures_event_idx" ON "public"."waiver_signatures" USING "btree" ("event_id") WHERE ("event_id" IS NOT NULL);



CREATE OR REPLACE TRIGGER "admin_audit_log_block_delete" BEFORE DELETE ON "public"."admin_audit_log" FOR EACH ROW EXECUTE FUNCTION "public"."audit_log_no_mutations"();



CREATE OR REPLACE TRIGGER "admin_audit_log_block_update" BEFORE UPDATE ON "public"."admin_audit_log" FOR EACH ROW EXECUTE FUNCTION "public"."audit_log_no_mutations"();



CREATE OR REPLACE TRIGGER "bookings_admin_audit_trg" AFTER INSERT OR DELETE OR UPDATE ON "public"."bookings" FOR EACH ROW EXECUTE FUNCTION "public"."audit_admin_write"();



CREATE OR REPLACE TRIGGER "bookings_detail_lock_trg" BEFORE UPDATE OF "details" ON "public"."bookings" FOR EACH ROW EXECUTE FUNCTION "public"."bookings_block_diver_detail_edits"();



CREATE OR REPLACE TRIGGER "diver_notes_freeze_identity" BEFORE UPDATE ON "public"."diver_notes" FOR EACH ROW EXECUTE FUNCTION "public"."diver_notes_freeze_identity"();



CREATE OR REPLACE TRIGGER "duties_assignee_admin_trg" BEFORE INSERT OR UPDATE OF "assignee_id" ON "public"."duties" FOR EACH ROW EXECUTE FUNCTION "public"."duties_enforce_assignee_is_admin"();



CREATE OR REPLACE TRIGGER "duties_no_busy_overlap_trg" BEFORE INSERT OR UPDATE OF "assignee_id", "start_date", "end_date" ON "public"."duties" FOR EACH ROW EXECUTE FUNCTION "public"."duties_enforce_no_busy_overlap"();



CREATE OR REPLACE TRIGGER "profiles_admin_audit_trg" AFTER INSERT OR DELETE OR UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."audit_admin_write"();



CREATE OR REPLACE TRIGGER "profiles_block_self_gear_size_trg" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."block_self_gear_size_change"();



CREATE OR REPLACE TRIGGER "profiles_block_self_privileged_change_trg" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."block_self_privileged_profile_change"();



CREATE OR REPLACE TRIGGER "profiles_cascade_delete_to_auth_users_trg" AFTER DELETE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."cascade_profile_delete_to_auth_users"();



CREATE OR REPLACE TRIGGER "profiles_email_mirror_auth_trg" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."profiles_email_mirror_auth"();



CREATE OR REPLACE TRIGGER "profiles_maybe_set_submitted_at_trg" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."maybe_set_application_submitted_at"();



CREATE OR REPLACE TRIGGER "staff_availability_owner_role_trg" BEFORE INSERT OR UPDATE OF "user_id" ON "public"."staff_availability" FOR EACH ROW EXECUTE FUNCTION "public"."staff_availability_enforce_owner_role"();



CREATE OR REPLACE TRIGGER "trg_bookings_cancellation_offer_next" AFTER UPDATE OF "status" ON "public"."bookings" FOR EACH ROW EXECUTE FUNCTION "public"."handle_booking_cancellation"();



CREATE OR REPLACE TRIGGER "trg_bookings_refresh_title" AFTER INSERT OR DELETE OR UPDATE ON "public"."bookings" FOR EACH ROW EXECUTE FUNCTION "public"."trg_bookings_refresh_event_title"();



CREATE OR REPLACE TRIGGER "trg_bookings_set_waitlisted_when_full" BEFORE INSERT ON "public"."bookings" FOR EACH ROW EXECUTE FUNCTION "public"."set_waitlisted_when_event_full"();



CREATE OR REPLACE TRIGGER "trg_bookings_validate_payer" BEFORE INSERT OR UPDATE OF "payer_id" ON "public"."bookings" FOR EACH ROW EXECUTE FUNCTION "public"."bookings_validate_payer"();



CREATE OR REPLACE TRIGGER "trg_dive_logs_set_number" BEFORE INSERT ON "public"."dive_logs" FOR EACH ROW EXECUTE FUNCTION "public"."set_dive_log_number"();



CREATE OR REPLACE TRIGGER "trg_dive_logs_touch_updated_at" BEFORE UPDATE ON "public"."dive_logs" FOR EACH ROW EXECUTE FUNCTION "public"."touch_dive_log_updated_at"();



CREATE OR REPLACE TRIGGER "trg_events_normalize_title" BEFORE INSERT OR UPDATE ON "public"."events" FOR EACH ROW EXECUTE FUNCTION "public"."eo_event_normalize_display_title"();



CREATE OR REPLACE TRIGGER "trg_profiles_one_level_family" BEFORE INSERT OR UPDATE OF "parent_account" ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."profiles_enforce_one_level_family"();



CREATE OR REPLACE TRIGGER "trg_staff_availability_touch_updated_at" BEFORE UPDATE ON "public"."staff_availability" FOR EACH ROW EXECUTE FUNCTION "public"."touch_staff_availability_updated_at"();



CREATE OR REPLACE TRIGGER "trg_trip_referrals_set_code" BEFORE INSERT ON "public"."trip_referrals" FOR EACH ROW EXECUTE FUNCTION "public"."trip_referrals_set_code"();



ALTER TABLE ONLY "public"."admin_audit_log"
    ADD CONSTRAINT "admin_audit_log_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."admin_notes"
    ADD CONSTRAINT "admin_notes_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."admin_notes"
    ADD CONSTRAINT "admin_notes_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."admin_notes"
    ADD CONSTRAINT "admin_notes_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."admin_notes"
    ADD CONSTRAINT "admin_notes_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."booking_amendments"
    ADD CONSTRAINT "booking_amendments_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."booking_amendments"
    ADD CONSTRAINT "booking_amendments_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_payer_id_fkey" FOREIGN KEY ("payer_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cert_levels"
    ADD CONSTRAINT "cert_levels_padi_equivalent_id_fkey" FOREIGN KEY ("padi_equivalent_id") REFERENCES "public"."cert_levels"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."credits"
    ADD CONSTRAINT "credits_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."credits"
    ADD CONSTRAINT "credits_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."credits"
    ADD CONSTRAINT "credits_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dive_log_export_requests"
    ADD CONSTRAINT "dive_log_export_requests_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dive_logs"
    ADD CONSTRAINT "dive_logs_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."diver_notes"
    ADD CONSTRAINT "diver_notes_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."diver_notes"
    ADD CONSTRAINT "diver_notes_edited_by_fkey" FOREIGN KEY ("edited_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."diver_notes"
    ADD CONSTRAINT "diver_notes_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."duties"
    ADD CONSTRAINT "duties_assignee_id_fkey" FOREIGN KEY ("assignee_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."duties"
    ADD CONSTRAINT "duties_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."duties"
    ADD CONSTRAINT "duties_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_addons"
    ADD CONSTRAINT "event_addons_addon_id_fkey" FOREIGN KEY ("addon_id") REFERENCES "public"."Other_Addons"("_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_addons"
    ADD CONSTRAINT "event_addons_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_destinations"
    ADD CONSTRAINT "event_destinations_destination_id_fkey" FOREIGN KEY ("destination_id") REFERENCES "public"."TravelDestinations"("_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_destinations"
    ADD CONSTRAINT "event_destinations_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_rooms"
    ADD CONSTRAINT "event_rooms_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_rooms"
    ADD CONSTRAINT "event_rooms_room_id_fkey" FOREIGN KEY ("room_id") REFERENCES "public"."EO_rooms"("_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_vehicles"
    ADD CONSTRAINT "event_vehicles_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."event_vehicles"
    ADD CONSTRAINT "event_vehicles_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_vehicles"
    ADD CONSTRAINT "event_vehicles_vehicle_id_fkey" FOREIGN KEY ("vehicle_id") REFERENCES "public"."vehicles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_waivers"
    ADD CONSTRAINT "event_waivers_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."event_waivers"
    ADD CONSTRAINT "event_waivers_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_cancel_policy_fkey" FOREIGN KEY ("cancel_policy") REFERENCES "public"."cancellation_policies"("_id") ON UPDATE CASCADE;



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_prereq_cert_id_fkey" FOREIGN KEY ("prereq_cert_id") REFERENCES "public"."cert_levels"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_price_fkey" FOREIGN KEY ("price") REFERENCES "public"."EO_prices"("_id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."partner_shops"
    ADD CONSTRAINT "partner_shops_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_parent_account_fkey" FOREIGN KEY ("parent_account") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."push_notifications_sent"
    ADD CONSTRAINT "push_notifications_sent_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."push_subscriptions"
    ADD CONSTRAINT "push_subscriptions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."staff_availability"
    ADD CONSTRAINT "staff_availability_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_referrals"
    ADD CONSTRAINT "trip_referrals_diver_id_fkey" FOREIGN KEY ("diver_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_referrals"
    ADD CONSTRAINT "trip_referrals_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trips"
    ADD CONSTRAINT "trips_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."trips"
    ADD CONSTRAINT "trips_partner_shop_id_fkey" FOREIGN KEY ("partner_shop_id") REFERENCES "public"."partner_shops"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."vehicles"
    ADD CONSTRAINT "vehicles_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."waitlist_offers"
    ADD CONSTRAINT "waitlist_offers_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."waiver_signatures"
    ADD CONSTRAINT "waiver_signatures_diver_id_fkey" FOREIGN KEY ("diver_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."waiver_signatures"
    ADD CONSTRAINT "waiver_signatures_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE "public"."DiveTravel" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "DiveTravel: admin delete" ON "public"."DiveTravel" FOR DELETE TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "DiveTravel: admin insert" ON "public"."DiveTravel" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "DiveTravel: admin update" ON "public"."DiveTravel" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "DiveTravel: public select" ON "public"."DiveTravel" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."EO_prices" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "EO_prices: admin delete" ON "public"."EO_prices" FOR DELETE TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "EO_prices: admin insert" ON "public"."EO_prices" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "EO_prices: admin update" ON "public"."EO_prices" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "EO_prices: public select" ON "public"."EO_prices" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."EO_rooms" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "EO_rooms: admin delete" ON "public"."EO_rooms" FOR DELETE TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "EO_rooms: admin insert" ON "public"."EO_rooms" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "EO_rooms: admin update" ON "public"."EO_rooms" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "EO_rooms: public select" ON "public"."EO_rooms" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."Other_Addons" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "Other_Addons: admin delete" ON "public"."Other_Addons" FOR DELETE TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "Other_Addons: admin insert" ON "public"."Other_Addons" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "Other_Addons: admin update" ON "public"."Other_Addons" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "Other_Addons: public select" ON "public"."Other_Addons" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."TravelDestinations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "TravelDestinations: admin delete" ON "public"."TravelDestinations" FOR DELETE TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "TravelDestinations: admin insert" ON "public"."TravelDestinations" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "TravelDestinations: admin update" ON "public"."TravelDestinations" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "TravelDestinations: public select" ON "public"."TravelDestinations" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."admin_audit_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "admin_audit_log: admin select" ON "public"."admin_audit_log" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



ALTER TABLE "public"."admin_notes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "admin_notes: admin delete" ON "public"."admin_notes" FOR DELETE TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "admin_notes: admin update" ON "public"."admin_notes" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_notes: staff_or_admin insert" ON "public"."admin_notes" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_staff_or_admin"() AND ("created_by" = "auth"."uid"())));



CREATE POLICY "admin_notes: staff_or_admin select" ON "public"."admin_notes" FOR SELECT TO "authenticated" USING ("public"."is_staff_or_admin"());



ALTER TABLE "public"."booking_amendments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "booking_amendments: admin insert" ON "public"."booking_amendments" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_admin"() AND ("created_by" = "auth"."uid"())));



CREATE POLICY "booking_amendments: diver select own" ON "public"."booking_amendments" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."bookings" "b"
  WHERE (("b"."id" = "booking_amendments"."booking_id") AND ("b"."user_id" = "auth"."uid"())))));



CREATE POLICY "booking_amendments: staff_or_admin select" ON "public"."booking_amendments" FOR SELECT TO "authenticated" USING ("public"."is_staff_or_admin"());



ALTER TABLE "public"."bookings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bookings: admin update" ON "public"."bookings" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "bookings: parent insert for children" ON "public"."bookings" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_active_user"() AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."id" = "bookings"."user_id") AND ("p"."parent_account" = "auth"."uid"()))))));



CREATE POLICY "bookings: parent select children" ON "public"."bookings" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."id" = "bookings"."user_id") AND ("p"."parent_account" = "auth"."uid"())))));



CREATE POLICY "bookings: parent update children" ON "public"."bookings" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."id" = "bookings"."user_id") AND ("p"."parent_account" = "auth"."uid"())))));



CREATE POLICY "bookings: self insert" ON "public"."bookings" FOR INSERT TO "authenticated" WITH CHECK ((("auth"."uid"() = "user_id") AND "public"."is_active_user"()));



CREATE POLICY "bookings: self select" ON "public"."bookings" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "bookings: self update" ON "public"."bookings" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "bookings: staff_or_admin select" ON "public"."bookings" FOR SELECT TO "authenticated" USING ("public"."is_staff_or_admin"());



ALTER TABLE "public"."cancellation_policies" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cancellation_policies: admin delete" ON "public"."cancellation_policies" FOR DELETE TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "cancellation_policies: admin insert" ON "public"."cancellation_policies" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "cancellation_policies: admin update" ON "public"."cancellation_policies" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "cancellation_policies: public select" ON "public"."cancellation_policies" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."cert_levels" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cert_levels: admin delete" ON "public"."cert_levels" FOR DELETE TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "cert_levels: admin insert" ON "public"."cert_levels" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "cert_levels: admin update" ON "public"."cert_levels" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "cert_levels: public select" ON "public"."cert_levels" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."credits" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "credits: admin delete" ON "public"."credits" FOR DELETE TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "credits: admin insert" ON "public"."credits" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "credits: admin update" ON "public"."credits" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "credits: diver select own" ON "public"."credits" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "credits: staff_or_admin select" ON "public"."credits" FOR SELECT TO "authenticated" USING ("public"."is_staff_or_admin"());



ALTER TABLE "public"."dive_log_export_requests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "dive_log_export_requests: own select" ON "public"."dive_log_export_requests" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."dive_logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "dive_logs: own delete" ON "public"."dive_logs" FOR DELETE TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "dive_logs: own insert" ON "public"."dive_logs" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "dive_logs: own select" ON "public"."dive_logs" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "dive_logs: own update" ON "public"."dive_logs" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."diver_notes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "diver_notes: admin or self delete" ON "public"."diver_notes" FOR DELETE TO "authenticated" USING (("public"."is_admin"() OR ("created_by" = "auth"."uid"())));



CREATE POLICY "diver_notes: admin or self update" ON "public"."diver_notes" FOR UPDATE TO "authenticated" USING (("public"."is_admin"() OR ("created_by" = "auth"."uid"()))) WITH CHECK (("public"."is_admin"() OR ("created_by" = "auth"."uid"())));



CREATE POLICY "diver_notes: staff_or_admin insert" ON "public"."diver_notes" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_staff_or_admin"() AND ("created_by" = "auth"."uid"())));



CREATE POLICY "diver_notes: staff_or_admin select" ON "public"."diver_notes" FOR SELECT TO "authenticated" USING ("public"."is_staff_or_admin"());



ALTER TABLE "public"."duties" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "duties: admin delete" ON "public"."duties" FOR DELETE TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "duties: admin insert" ON "public"."duties" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "duties: admin select" ON "public"."duties" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "duties: admin update" ON "public"."duties" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "duties: staff select own" ON "public"."duties" FOR SELECT TO "authenticated" USING (("assignee_id" = "auth"."uid"()));



ALTER TABLE "public"."event_addons" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "event_addons admin delete" ON "public"."event_addons" FOR DELETE TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "event_addons admin insert" ON "public"."event_addons" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "event_addons admin update" ON "public"."event_addons" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "event_addons public select" ON "public"."event_addons" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."event_destinations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "event_destinations admin delete" ON "public"."event_destinations" FOR DELETE TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "event_destinations admin insert" ON "public"."event_destinations" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "event_destinations admin update" ON "public"."event_destinations" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "event_destinations public select" ON "public"."event_destinations" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."event_rooms" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "event_rooms admin delete" ON "public"."event_rooms" FOR DELETE TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "event_rooms admin insert" ON "public"."event_rooms" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "event_rooms admin update" ON "public"."event_rooms" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "event_rooms public select" ON "public"."event_rooms" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."event_vehicles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "event_vehicles: admin manage" ON "public"."event_vehicles" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "event_vehicles: staff_or_admin read" ON "public"."event_vehicles" FOR SELECT TO "authenticated" USING ("public"."is_staff_or_admin"());



ALTER TABLE "public"."event_waivers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "event_waivers: admin manage" ON "public"."event_waivers" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "event_waivers: authenticated read" ON "public"."event_waivers" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "events admin delete" ON "public"."events" FOR DELETE TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "events admin insert" ON "public"."events" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "events admin update" ON "public"."events" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "events public select" ON "public"."events" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "notifications: own select" ON "public"."notifications" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "notifications: own update" ON "public"."notifications" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."orphan_auth_users" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."partner_shops" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "partner_shops: admin manage" ON "public"."partner_shops" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "payments: admin insert" ON "public"."payments" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "payments: admin update" ON "public"."payments" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "payments: parent select children" ON "public"."payments" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."id" = "payments"."user_id") AND ("p"."parent_account" = "auth"."uid"())))));



CREATE POLICY "payments: self select" ON "public"."payments" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "payments: staff_or_admin select" ON "public"."payments" FOR SELECT TO "authenticated" USING ("public"."is_staff_or_admin"());



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles: admin update" ON "public"."profiles" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "profiles: child select parent" ON "public"."profiles" FOR SELECT TO "authenticated" USING (("id" = "public"."my_parent_account"()));



CREATE POLICY "profiles: parent select children" ON "public"."profiles" FOR SELECT TO "authenticated" USING (("parent_account" = "auth"."uid"()));



CREATE POLICY "profiles: parent update children" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("parent_account" = "auth"."uid"())) WITH CHECK (("parent_account" = "auth"."uid"()));



CREATE POLICY "profiles: self select" ON "public"."profiles" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "id"));



CREATE POLICY "profiles: self update" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "id")) WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "profiles: staff_or_admin select" ON "public"."profiles" FOR SELECT TO "authenticated" USING ("public"."is_staff_or_admin"());



ALTER TABLE "public"."push_notifications_sent" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "push_subs: user deletes own" ON "public"."push_subscriptions" FOR DELETE TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "push_subs: user reads own" ON "public"."push_subscriptions" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "push_subs: user updates own" ON "public"."push_subscriptions" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."push_subscriptions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."signup_attempts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."staff_availability" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "staff_availability: delete own" ON "public"."staff_availability" FOR DELETE TO "authenticated" USING ((("user_id" = "auth"."uid"()) AND "public"."is_staff_or_admin"()));



CREATE POLICY "staff_availability: insert own" ON "public"."staff_availability" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = "auth"."uid"()) AND "public"."is_staff_or_admin"()));



CREATE POLICY "staff_availability: select own or admin" ON "public"."staff_availability" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) OR "public"."is_admin"()));



CREATE POLICY "staff_availability: update own" ON "public"."staff_availability" FOR UPDATE TO "authenticated" USING ((("user_id" = "auth"."uid"()) AND "public"."is_staff_or_admin"())) WITH CHECK ((("user_id" = "auth"."uid"()) AND "public"."is_staff_or_admin"()));



ALTER TABLE "public"."trip_referrals" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trip_referrals: admin manage" ON "public"."trip_referrals" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



ALTER TABLE "public"."trips" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trips: admin manage" ON "public"."trips" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "user inserts own push sub" ON "public"."push_subscriptions" FOR INSERT TO "authenticated" WITH CHECK ((("auth"."uid"() = "user_id") AND "public"."is_active_user"()));



ALTER TABLE "public"."vehicles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "vehicles: admin manage" ON "public"."vehicles" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "vehicles: staff_or_admin read" ON "public"."vehicles" FOR SELECT TO "authenticated" USING ("public"."is_staff_or_admin"());



ALTER TABLE "public"."waitlist_offers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "waitlist_offers: own select" ON "public"."waitlist_offers" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."bookings" "b"
  WHERE (("b"."id" = "waitlist_offers"."booking_id") AND ("b"."user_id" = "auth"."uid"())))));



ALTER TABLE "public"."waiver_signatures" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "waiver_signatures: admin manage" ON "public"."waiver_signatures" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "waiver_signatures: self read" ON "public"."waiver_signatures" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "diver_id"));



CREATE POLICY "waiver_signatures: staff_or_admin read" ON "public"."waiver_signatures" FOR SELECT TO "authenticated" USING ("public"."is_staff_or_admin"());





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";





GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";































































































































































REVOKE ALL ON FUNCTION "public"."accept_current_terms"("p_version" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."accept_current_terms"("p_version" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."accept_current_terms"("p_version" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."accept_current_terms"("p_version" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."accept_waitlist_offer"("p_offer_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."accept_waitlist_offer"("p_offer_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."accept_waitlist_offer"("p_offer_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."accept_waitlist_offer"("p_offer_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_delete_user"("p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_delete_user"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_delete_user"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_delete_user"("p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."apply_credit_to_booking"("p_booking_id" "uuid", "p_amount" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."apply_credit_to_booking"("p_booking_id" "uuid", "p_amount" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."apply_credit_to_booking"("p_booking_id" "uuid", "p_amount" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_credit_to_booking"("p_booking_id" "uuid", "p_amount" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."audit_admin_write"() TO "anon";
GRANT ALL ON FUNCTION "public"."audit_admin_write"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."audit_admin_write"() TO "service_role";



GRANT ALL ON FUNCTION "public"."audit_log_no_mutations"() TO "anon";
GRANT ALL ON FUNCTION "public"."audit_log_no_mutations"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."audit_log_no_mutations"() TO "service_role";



GRANT ALL ON FUNCTION "public"."block_self_gear_size_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."block_self_gear_size_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."block_self_gear_size_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."block_self_privileged_profile_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."block_self_privileged_profile_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."block_self_privileged_profile_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."bookings_block_diver_detail_edits"() TO "anon";
GRANT ALL ON FUNCTION "public"."bookings_block_diver_detail_edits"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."bookings_block_diver_detail_edits"() TO "service_role";



GRANT ALL ON FUNCTION "public"."bookings_validate_payer"() TO "anon";
GRANT ALL ON FUNCTION "public"."bookings_validate_payer"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."bookings_validate_payer"() TO "service_role";



GRANT ALL ON FUNCTION "public"."capacity_suffix"("p_capacity" integer, "p_fully_booked" boolean, "p_confirmed" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."capacity_suffix"("p_capacity" integer, "p_fully_booked" boolean, "p_confirmed" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."capacity_suffix"("p_capacity" integer, "p_fully_booked" boolean, "p_confirmed" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."cascade_profile_delete_to_auth_users"() TO "anon";
GRANT ALL ON FUNCTION "public"."cascade_profile_delete_to_auth_users"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cascade_profile_delete_to_auth_users"() TO "service_role";



GRANT ALL ON FUNCTION "public"."diver_notes_freeze_identity"() TO "anon";
GRANT ALL ON FUNCTION "public"."diver_notes_freeze_identity"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."diver_notes_freeze_identity"() TO "service_role";



GRANT ALL ON FUNCTION "public"."duties_enforce_assignee_is_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."duties_enforce_assignee_is_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."duties_enforce_assignee_is_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."duties_enforce_no_busy_overlap"() TO "anon";
GRANT ALL ON FUNCTION "public"."duties_enforce_no_busy_overlap"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."duties_enforce_no_busy_overlap"() TO "service_role";



GRANT ALL ON FUNCTION "public"."eo_event_normalize_display_title"() TO "anon";
GRANT ALL ON FUNCTION "public"."eo_event_normalize_display_title"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."eo_event_normalize_display_title"() TO "service_role";



GRANT ALL ON FUNCTION "public"."event_confirmed_count_one"("p_event_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."event_confirmed_count_one"("p_event_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."event_confirmed_count_one"("p_event_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."event_confirmed_counts"("p_event_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."event_confirmed_counts"("p_event_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."event_confirmed_counts"("p_event_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."event_ride_seats"("p_event_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."event_ride_seats"("p_event_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."event_ride_seats"("p_event_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."express_trip_interest"("p_trip_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."express_trip_interest"("p_trip_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."express_trip_interest"("p_trip_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."express_trip_interest"("p_trip_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."gen_referral_code"() TO "anon";
GRANT ALL ON FUNCTION "public"."gen_referral_code"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."gen_referral_code"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_booking_cancellation"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_booking_cancellation"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_booking_cancellation"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_active_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_active_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_active_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_staff_or_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_staff_or_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_staff_or_admin"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."log_orphan_auth_user"("p_user_id" "uuid", "p_email" "text", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."log_orphan_auth_user"("p_user_id" "uuid", "p_email" "text", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."log_orphan_auth_user"("p_user_id" "uuid", "p_email" "text", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_orphan_auth_user"("p_user_id" "uuid", "p_email" "text", "p_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."maybe_set_application_submitted_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."maybe_set_application_submitted_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."maybe_set_application_submitted_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."my_parent_account"() TO "anon";
GRANT ALL ON FUNCTION "public"."my_parent_account"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."my_parent_account"() TO "service_role";



GRANT ALL ON FUNCTION "public"."offer_next_waitlist_spot"("p_event_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."offer_next_waitlist_spot"("p_event_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."offer_next_waitlist_spot"("p_event_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."profiles_email_mirror_auth"() TO "anon";
GRANT ALL ON FUNCTION "public"."profiles_email_mirror_auth"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."profiles_email_mirror_auth"() TO "service_role";



GRANT ALL ON FUNCTION "public"."profiles_enforce_one_level_family"() TO "anon";
GRANT ALL ON FUNCTION "public"."profiles_enforce_one_level_family"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."profiles_enforce_one_level_family"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."purge_stale_pii"("older_than_months" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."purge_stale_pii"("older_than_months" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."purge_stale_pii"("older_than_months" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."purge_stale_pii"("older_than_months" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_group_payment"("p_lead" "uuid", "p_amount" numeric, "p_group_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_group_payment"("p_lead" "uuid", "p_amount" numeric, "p_group_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."record_group_payment"("p_lead" "uuid", "p_amount" numeric, "p_group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_group_payment"("p_lead" "uuid", "p_amount" numeric, "p_group_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_signup_attempt"("p_ip_hash" "bytea") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_signup_attempt"("p_ip_hash" "bytea") TO "anon";
GRANT ALL ON FUNCTION "public"."record_signup_attempt"("p_ip_hash" "bytea") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_signup_attempt"("p_ip_hash" "bytea") TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_event_display_title"("p_event_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_event_display_title"("p_event_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_event_display_title"("p_event_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_dive_log_number"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_dive_log_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_dive_log_number"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_event_relations"("p_event_id" "uuid", "p_room_ids" "uuid"[], "p_addon_ids" "uuid"[], "p_destination_ids" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_event_relations"("p_event_id" "uuid", "p_room_ids" "uuid"[], "p_addon_ids" "uuid"[], "p_destination_ids" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."set_event_relations"("p_event_id" "uuid", "p_room_ids" "uuid"[], "p_addon_ids" "uuid"[], "p_destination_ids" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_event_relations"("p_event_id" "uuid", "p_room_ids" "uuid"[], "p_addon_ids" "uuid"[], "p_destination_ids" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."set_waitlisted_when_event_full"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_waitlisted_when_event_full"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_waitlisted_when_event_full"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."sign_waiver"("p_code" "text", "p_version" integer, "p_signed_name" "text", "p_event_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sign_waiver"("p_code" "text", "p_version" integer, "p_signed_name" "text", "p_event_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."sign_waiver"("p_code" "text", "p_version" integer, "p_signed_name" "text", "p_event_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sign_waiver"("p_code" "text", "p_version" integer, "p_signed_name" "text", "p_event_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."staff_availability_enforce_owner_role"() TO "anon";
GRANT ALL ON FUNCTION "public"."staff_availability_enforce_owner_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."staff_availability_enforce_owner_role"() TO "service_role";



GRANT ALL ON FUNCTION "public"."strip_capacity_suffix"("p_title" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strip_capacity_suffix"("p_title" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strip_capacity_suffix"("p_title" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_profile_email"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_profile_email"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_profile_email"() TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_dive_log_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_dive_log_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_dive_log_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_staff_availability_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_staff_availability_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_staff_availability_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_bookings_refresh_event_title"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_bookings_refresh_event_title"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_bookings_refresh_event_title"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trip_referrals_set_code"() TO "anon";
GRANT ALL ON FUNCTION "public"."trip_referrals_set_code"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trip_referrals_set_code"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_diver_gear_sizes"("diver_id" "uuid", "fin_size" "text", "bcd_size" "text", "wetsuit_size" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_diver_gear_sizes"("diver_id" "uuid", "fin_size" "text", "bcd_size" "text", "wetsuit_size" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_diver_gear_sizes"("diver_id" "uuid", "fin_size" "text", "bcd_size" "text", "wetsuit_size" "text") TO "service_role";


















GRANT ALL ON TABLE "public"."DiveTravel" TO "anon";
GRANT ALL ON TABLE "public"."DiveTravel" TO "authenticated";
GRANT ALL ON TABLE "public"."DiveTravel" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."EO_prices" TO "anon";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,MAINTAIN,UPDATE ON TABLE "public"."EO_prices" TO "authenticated";
GRANT ALL ON TABLE "public"."EO_prices" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."EO_rooms" TO "anon";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,MAINTAIN,UPDATE ON TABLE "public"."EO_rooms" TO "authenticated";
GRANT ALL ON TABLE "public"."EO_rooms" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."Other_Addons" TO "anon";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,MAINTAIN,UPDATE ON TABLE "public"."Other_Addons" TO "authenticated";
GRANT ALL ON TABLE "public"."Other_Addons" TO "service_role";



GRANT ALL ON TABLE "public"."TravelDestinations" TO "anon";
GRANT ALL ON TABLE "public"."TravelDestinations" TO "authenticated";
GRANT ALL ON TABLE "public"."TravelDestinations" TO "service_role";



GRANT ALL ON TABLE "public"."admin_audit_log" TO "anon";
GRANT ALL ON TABLE "public"."admin_audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_audit_log" TO "service_role";



GRANT ALL ON TABLE "public"."admin_notes" TO "anon";
GRANT ALL ON TABLE "public"."admin_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_notes" TO "service_role";



GRANT ALL ON TABLE "public"."booking_amendments" TO "anon";
GRANT ALL ON TABLE "public"."booking_amendments" TO "authenticated";
GRANT ALL ON TABLE "public"."booking_amendments" TO "service_role";



GRANT ALL ON TABLE "public"."bookings" TO "anon";
GRANT ALL ON TABLE "public"."bookings" TO "authenticated";
GRANT ALL ON TABLE "public"."bookings" TO "service_role";



GRANT ALL ON TABLE "public"."cancellation_policies" TO "anon";
GRANT ALL ON TABLE "public"."cancellation_policies" TO "authenticated";
GRANT ALL ON TABLE "public"."cancellation_policies" TO "service_role";



GRANT ALL ON TABLE "public"."cert_levels" TO "anon";
GRANT ALL ON TABLE "public"."cert_levels" TO "authenticated";
GRANT ALL ON TABLE "public"."cert_levels" TO "service_role";



GRANT ALL ON TABLE "public"."credits" TO "anon";
GRANT ALL ON TABLE "public"."credits" TO "authenticated";
GRANT ALL ON TABLE "public"."credits" TO "service_role";



GRANT ALL ON TABLE "public"."dive_log_export_requests" TO "anon";
GRANT ALL ON TABLE "public"."dive_log_export_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."dive_log_export_requests" TO "service_role";



GRANT ALL ON TABLE "public"."dive_logs" TO "anon";
GRANT ALL ON TABLE "public"."dive_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."dive_logs" TO "service_role";



GRANT ALL ON TABLE "public"."diver_notes" TO "anon";
GRANT ALL ON TABLE "public"."diver_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."diver_notes" TO "service_role";



GRANT ALL ON TABLE "public"."duties" TO "anon";
GRANT ALL ON TABLE "public"."duties" TO "authenticated";
GRANT ALL ON TABLE "public"."duties" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."event_addons" TO "anon";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,MAINTAIN,UPDATE ON TABLE "public"."event_addons" TO "authenticated";
GRANT ALL ON TABLE "public"."event_addons" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."event_destinations" TO "anon";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,MAINTAIN,UPDATE ON TABLE "public"."event_destinations" TO "authenticated";
GRANT ALL ON TABLE "public"."event_destinations" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."event_rooms" TO "anon";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,MAINTAIN,UPDATE ON TABLE "public"."event_rooms" TO "authenticated";
GRANT ALL ON TABLE "public"."event_rooms" TO "service_role";



GRANT ALL ON TABLE "public"."event_vehicles" TO "anon";
GRANT ALL ON TABLE "public"."event_vehicles" TO "authenticated";
GRANT ALL ON TABLE "public"."event_vehicles" TO "service_role";



GRANT ALL ON TABLE "public"."event_waivers" TO "anon";
GRANT ALL ON TABLE "public"."event_waivers" TO "authenticated";
GRANT ALL ON TABLE "public"."event_waivers" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."events" TO "anon";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,MAINTAIN,UPDATE ON TABLE "public"."events" TO "authenticated";
GRANT ALL ON TABLE "public"."events" TO "service_role";



GRANT ALL ON TABLE "public"."partner_shops" TO "anon";
GRANT ALL ON TABLE "public"."partner_shops" TO "authenticated";
GRANT ALL ON TABLE "public"."partner_shops" TO "service_role";



GRANT ALL ON TABLE "public"."trip_referrals" TO "anon";
GRANT ALL ON TABLE "public"."trip_referrals" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_referrals" TO "service_role";



GRANT ALL ON TABLE "public"."trips" TO "anon";
GRANT ALL ON TABLE "public"."trips" TO "authenticated";
GRANT ALL ON TABLE "public"."trips" TO "service_role";



GRANT ALL ON TABLE "public"."my_trip_referrals" TO "service_role";
GRANT SELECT ON TABLE "public"."my_trip_referrals" TO "authenticated";



GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT ALL ON TABLE "public"."orphan_auth_users" TO "anon";
GRANT ALL ON TABLE "public"."orphan_auth_users" TO "authenticated";
GRANT ALL ON TABLE "public"."orphan_auth_users" TO "service_role";



GRANT ALL ON TABLE "public"."payments" TO "anon";
GRANT ALL ON TABLE "public"."payments" TO "authenticated";
GRANT ALL ON TABLE "public"."payments" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."push_notifications_sent" TO "anon";
GRANT ALL ON TABLE "public"."push_notifications_sent" TO "authenticated";
GRANT ALL ON TABLE "public"."push_notifications_sent" TO "service_role";



GRANT ALL ON TABLE "public"."push_subscriptions" TO "anon";
GRANT ALL ON TABLE "public"."push_subscriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."push_subscriptions" TO "service_role";



GRANT ALL ON TABLE "public"."signup_attempts" TO "anon";
GRANT ALL ON TABLE "public"."signup_attempts" TO "authenticated";
GRANT ALL ON TABLE "public"."signup_attempts" TO "service_role";



GRANT ALL ON SEQUENCE "public"."signup_attempts_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."signup_attempts_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."signup_attempts_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."staff_availability" TO "anon";
GRANT ALL ON TABLE "public"."staff_availability" TO "authenticated";
GRANT ALL ON TABLE "public"."staff_availability" TO "service_role";



GRANT ALL ON TABLE "public"."staff_availability_view" TO "anon";
GRANT ALL ON TABLE "public"."staff_availability_view" TO "authenticated";
GRANT ALL ON TABLE "public"."staff_availability_view" TO "service_role";



GRANT ALL ON TABLE "public"."trip_board" TO "service_role";
GRANT SELECT ON TABLE "public"."trip_board" TO "authenticated";



GRANT ALL ON TABLE "public"."vehicles" TO "anon";
GRANT ALL ON TABLE "public"."vehicles" TO "authenticated";
GRANT ALL ON TABLE "public"."vehicles" TO "service_role";



GRANT ALL ON TABLE "public"."waitlist_offers" TO "anon";
GRANT ALL ON TABLE "public"."waitlist_offers" TO "authenticated";
GRANT ALL ON TABLE "public"."waitlist_offers" TO "service_role";



GRANT ALL ON TABLE "public"."waiver_signatures" TO "anon";
GRANT ALL ON TABLE "public"."waiver_signatures" TO "authenticated";
GRANT ALL ON TABLE "public"."waiver_signatures" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";
































--
-- Dumped schema changes for auth and storage
--

CREATE OR REPLACE TRIGGER "on_auth_user_created" AFTER INSERT ON "auth"."users" FOR EACH ROW EXECUTE FUNCTION "public"."handle_new_user"();



CREATE OR REPLACE TRIGGER "on_auth_user_email_updated" AFTER UPDATE OF "email" ON "auth"."users" FOR EACH ROW WHEN ((("new"."email")::"text" IS DISTINCT FROM ("old"."email")::"text")) EXECUTE FUNCTION "public"."sync_profile_email"();



CREATE POLICY "cert-cards: admin delete" ON "storage"."objects" FOR DELETE TO "authenticated" USING ((("bucket_id" = 'cert-cards'::"text") AND "public"."is_admin"()));



CREATE POLICY "cert-cards: admin insert" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'cert-cards'::"text") AND "public"."is_admin"()));



CREATE POLICY "cert-cards: admin read" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'cert-cards'::"text") AND "public"."is_admin"()));



CREATE POLICY "cert-cards: admin update" ON "storage"."objects" FOR UPDATE TO "authenticated" USING ((("bucket_id" = 'cert-cards'::"text") AND "public"."is_admin"())) WITH CHECK ((("bucket_id" = 'cert-cards'::"text") AND "public"."is_admin"()));



CREATE POLICY "cert-cards: delete own" ON "storage"."objects" FOR DELETE TO "authenticated" USING ((("bucket_id" = 'cert-cards'::"text") AND (("storage"."foldername"("name"))[1] = ("auth"."uid"())::"text")));



CREATE POLICY "cert-cards: insert own" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'cert-cards'::"text") AND (("storage"."foldername"("name"))[1] = ("auth"."uid"())::"text")));



CREATE POLICY "cert-cards: parent delete children" ON "storage"."objects" FOR DELETE TO "authenticated" USING ((("bucket_id" = 'cert-cards'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE ((("p"."id")::"text" = ("storage"."foldername"("objects"."name"))[1]) AND ("p"."parent_account" = "auth"."uid"()))))));



CREATE POLICY "cert-cards: parent insert children" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'cert-cards'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE ((("p"."id")::"text" = ("storage"."foldername"("objects"."name"))[1]) AND ("p"."parent_account" = "auth"."uid"()))))));



CREATE POLICY "cert-cards: parent select children" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'cert-cards'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE ((("p"."id")::"text" = ("storage"."foldername"("objects"."name"))[1]) AND ("p"."parent_account" = "auth"."uid"()))))));



CREATE POLICY "cert-cards: parent update children" ON "storage"."objects" FOR UPDATE TO "authenticated" USING ((("bucket_id" = 'cert-cards'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE ((("p"."id")::"text" = ("storage"."foldername"("objects"."name"))[1]) AND ("p"."parent_account" = "auth"."uid"()))))));



CREATE POLICY "cert-cards: select own" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'cert-cards'::"text") AND (("storage"."foldername"("name"))[1] = ("auth"."uid"())::"text")));



CREATE POLICY "cert-cards: update own" ON "storage"."objects" FOR UPDATE TO "authenticated" USING ((("bucket_id" = 'cert-cards'::"text") AND (("storage"."foldername"("name"))[1] = ("auth"."uid"())::"text")));



CREATE POLICY "deep-cards: admin delete" ON "storage"."objects" FOR DELETE TO "authenticated" USING ((("bucket_id" = 'deep-cards'::"text") AND "public"."is_admin"()));



CREATE POLICY "deep-cards: admin insert" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'deep-cards'::"text") AND "public"."is_admin"()));



CREATE POLICY "deep-cards: admin read" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'deep-cards'::"text") AND "public"."is_admin"()));



CREATE POLICY "deep-cards: admin update" ON "storage"."objects" FOR UPDATE TO "authenticated" USING ((("bucket_id" = 'deep-cards'::"text") AND "public"."is_admin"())) WITH CHECK ((("bucket_id" = 'deep-cards'::"text") AND "public"."is_admin"()));



CREATE POLICY "deep-cards: delete own" ON "storage"."objects" FOR DELETE TO "authenticated" USING ((("bucket_id" = 'deep-cards'::"text") AND (("storage"."foldername"("name"))[1] = ("auth"."uid"())::"text")));



CREATE POLICY "deep-cards: insert own" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'deep-cards'::"text") AND (("storage"."foldername"("name"))[1] = ("auth"."uid"())::"text")));



CREATE POLICY "deep-cards: parent delete children" ON "storage"."objects" FOR DELETE TO "authenticated" USING ((("bucket_id" = 'deep-cards'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE ((("p"."id")::"text" = ("storage"."foldername"("objects"."name"))[1]) AND ("p"."parent_account" = "auth"."uid"()))))));



CREATE POLICY "deep-cards: parent insert children" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'deep-cards'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE ((("p"."id")::"text" = ("storage"."foldername"("objects"."name"))[1]) AND ("p"."parent_account" = "auth"."uid"()))))));



CREATE POLICY "deep-cards: parent select children" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'deep-cards'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE ((("p"."id")::"text" = ("storage"."foldername"("objects"."name"))[1]) AND ("p"."parent_account" = "auth"."uid"()))))));



CREATE POLICY "deep-cards: parent update children" ON "storage"."objects" FOR UPDATE TO "authenticated" USING ((("bucket_id" = 'deep-cards'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE ((("p"."id")::"text" = ("storage"."foldername"("objects"."name"))[1]) AND ("p"."parent_account" = "auth"."uid"()))))));



CREATE POLICY "deep-cards: select own" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'deep-cards'::"text") AND (("storage"."foldername"("name"))[1] = ("auth"."uid"())::"text")));



CREATE POLICY "deep-cards: update own" ON "storage"."objects" FOR UPDATE TO "authenticated" USING ((("bucket_id" = 'deep-cards'::"text") AND (("storage"."foldername"("name"))[1] = ("auth"."uid"())::"text")));



CREATE POLICY "nitrox-cards: admin delete" ON "storage"."objects" FOR DELETE TO "authenticated" USING ((("bucket_id" = 'nitrox-cards'::"text") AND "public"."is_admin"()));



CREATE POLICY "nitrox-cards: admin insert" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'nitrox-cards'::"text") AND "public"."is_admin"()));



CREATE POLICY "nitrox-cards: admin read" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'nitrox-cards'::"text") AND "public"."is_admin"()));



CREATE POLICY "nitrox-cards: admin update" ON "storage"."objects" FOR UPDATE TO "authenticated" USING ((("bucket_id" = 'nitrox-cards'::"text") AND "public"."is_admin"())) WITH CHECK ((("bucket_id" = 'nitrox-cards'::"text") AND "public"."is_admin"()));



CREATE POLICY "nitrox-cards: delete own" ON "storage"."objects" FOR DELETE TO "authenticated" USING ((("bucket_id" = 'nitrox-cards'::"text") AND (("storage"."foldername"("name"))[1] = ("auth"."uid"())::"text")));



CREATE POLICY "nitrox-cards: insert own" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'nitrox-cards'::"text") AND (("storage"."foldername"("name"))[1] = ("auth"."uid"())::"text")));



CREATE POLICY "nitrox-cards: parent delete children" ON "storage"."objects" FOR DELETE TO "authenticated" USING ((("bucket_id" = 'nitrox-cards'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE ((("p"."id")::"text" = ("storage"."foldername"("objects"."name"))[1]) AND ("p"."parent_account" = "auth"."uid"()))))));



CREATE POLICY "nitrox-cards: parent insert children" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'nitrox-cards'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE ((("p"."id")::"text" = ("storage"."foldername"("objects"."name"))[1]) AND ("p"."parent_account" = "auth"."uid"()))))));



CREATE POLICY "nitrox-cards: parent select children" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'nitrox-cards'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE ((("p"."id")::"text" = ("storage"."foldername"("objects"."name"))[1]) AND ("p"."parent_account" = "auth"."uid"()))))));



CREATE POLICY "nitrox-cards: parent update children" ON "storage"."objects" FOR UPDATE TO "authenticated" USING ((("bucket_id" = 'nitrox-cards'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE ((("p"."id")::"text" = ("storage"."foldername"("objects"."name"))[1]) AND ("p"."parent_account" = "auth"."uid"()))))));



CREATE POLICY "nitrox-cards: select own" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'nitrox-cards'::"text") AND (("storage"."foldername"("name"))[1] = ("auth"."uid"())::"text")));



CREATE POLICY "nitrox-cards: update own" ON "storage"."objects" FOR UPDATE TO "authenticated" USING ((("bucket_id" = 'nitrox-cards'::"text") AND (("storage"."foldername"("name"))[1] = ("auth"."uid"())::"text")));




-- ── Storage buckets ─────────────────────────────────────────────────────────
-- Bucket data rows (cert / nitrox / deep card storage). The schema-only migration
-- squash captured the storage.objects RLS policies (above) but not these DATA
-- rows, so they are re-seeded here.
insert into storage.buckets (id, name, public) values
  ('cert-cards',   'cert-cards',   false),
  ('nitrox-cards', 'nitrox-cards', false),
  ('deep-cards',   'deep-cards',   false)
on conflict (id) do nothing;

-- ── Seeded reference data (cert_levels / cancellation_policies / DiveTravel / TravelDestinations) ──
-- Not captured by the schema-only squash; restored here so the baseline reproduces the full working state.
-- session_replication_role=replica disables FK enforcement during the load so
-- cert_levels' self-referential padi_equivalent_id doesn't need topological order.
set session_replication_role = replica;
INSERT INTO public."DiveTravel" VALUES ('2b8d42fa-0738-4df2-80c1-e682f71c93da', 'Bat Cave', NULL, NULL, NULL, '2019-08-12 11:15:41+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'Fun Diving and BBQ', 'wix:image://v1/b37fef_df5ef3980c1649108968ff48cdb2988c~mv2.jpg/charcoal.jpg#originWidth=800&originHeight=450', '<p class="p1"><span style="font-family:corben,serif">We will be having a Barbecue at Bat Cave on Friday, September 13th.&nbsp; We will also be doing three dives with no extra charge for the third dive, so come on out and celebrate with us!&nbsp;</span></p>', '<p class="p1"><span style="font-family:corben,serif">Come join Fun Divers TW as we celebrate Moon Festival in the traditional way with a Barbecue!&nbsp; We will also be celebrating in the not-so-traditional way with Diving!</span></p>', NULL, '<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Come join Fun Divers Tw as we celebrate Moon Festival in the traditional way with a Barbecue!&nbsp; We will also be celebrating in the not-so-traditional way with Diving!&nbsp;</span></p>
<p class="font_8 p1"><br></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">We will be having a Barbecue at Bat Cave on Friday, September 13th.&nbsp; We will also be doing three dives with no extra charge for the third dive, so come on out and celebrate with us!&nbsp;</span></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">&nbsp;</span></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Cost:</span></p>
<p class="font_8 p1"><br></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">1200NTD for 2 Dives (3rd dive is free!)</span></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">1000NTD for Equipment Rental</span></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">500NTD for BBQ (please let us know if you have any dietary restrictions)</span></p>
<p class="font_8 p1"><br></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Book Early as transportation is limited!&nbsp;</span></p>
<p class="font_8 p1">&nbsp;</p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Hope to see you in the water!</span></p>', 'Divers and Non-Divers Welcome', NULL, NULL, 'See Details', '2019-09-12 16:00:00+00', NULL, false, NULL, '1e1be45b-6ba5-4334-82ef-8331ee24c641', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('54566f97-7287-44f3-b663-8fc718d57610', 'Fun Divers Dive Center', NULL, NULL, NULL, '2019-07-01 06:17:06+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'PADI Nitrox Course', 'wix:image://v1/b37fef_d384c617d2c94d13b56f3264e6f1c314~mv2.jpg/Nitrox%20Tanks.jpg#originWidth=1666&originHeight=1030', '<p class="font_8">The PADI Enriched Air Nitrox&nbsp;Diver course is PADI’s most popular specialty scuba course for several reasons.</p>
<ul class="font_8">
  <li><p class="font_8">Nitrox&nbsp;allows you to dive at deeper depths for longer times</p></li>
  <li><p class="font_8">Nitrox&nbsp;gives you more no decompression time, especially on repetitive scuba dives.</p></li>
  <li><p class="font_8">Nitrox allows for a shorter surface interval between multi-dive days</p></li>
</ul>
<p class="font_8">Nitrox is especially popular for divers who plan to dive while traveling, as some resorts and&nbsp;liveaboards&nbsp;only dive with nitrox and require the certification.</p>
<p class="font_8"><br></p>
<p class="font_8">If staying down longer and getting back in the water sooner sounds appealing, then don’t hesitate to become an enriched air diver.</p>', '<p class="font_8">The PADI&nbsp;Enriched Air Nitrox Course is the&nbsp;most popular PADI specialty course. Scuba diving with EANx gives you extra no decompression time, especially on repetitive scuba dives.</p>', NULL, '<p class="font_8">Become An Enriched Air Nitrox Diver &nbsp;成為高氧潛水員</p>
<p class="font_8"><br></p>
<p class="font_8">With EANx(Nitrox) you can extend your NDL’s and do more dives, more safely!&nbsp;</p>
<p class="font_8"><strong>Price:</strong> &nbsp;</p>
<p class="font_8">Chinese Book: 5,800ntd&nbsp;</p>
<p class="font_8">English Book: 6,000ntd</p>
<p class="font_8"><br></p>
<p class="font_8">Classroom: 2 hours 教室：兩個小時&nbsp;</p>
<p class="font_8">Dives: 2 Nitrox tanks 潛兩支高氧</p>
<p class="font_8"><br></p>
<p class="font_8">Full Basic Set of Equipment Rental 一天裝備租借： $1200</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Book now and get a discount on the Crest CR-4 Dive Computer while taking the course.</strong></p>
<p class="font_8">During Course: 6200ntd (normally 6500ntd)</p>
<p class="font_8"><br></p>
<p class="font_8">For more information about the <a href="https://www.fundiverstw.com/Courses/PADI-Enriched-Air-Specialty-Course"><u>PADI EANx Course Here</u></a>!</p>', 'Open Water Certified', NULL, NULL, 'See Details for price', '2020-05-08 16:00:00+00', NULL, false, NULL, NULL, false, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('62b9b3a4-ed8c-4681-baed-19c39d316972', 'Bat Cave', NULL, NULL, NULL, '2019-07-01 06:38:46+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'Women''s Day Fun Diving Special', 'wix:image://v1/b37fef_50b3da3950ab411a96ed28b0ee4b04bb~mv2.jpg/WDD19_Logo_300dpi_icon_05_RGB.jpg#originWidth=763&originHeight=762', '<p class="p1"><span style="font-family:corben,serif">Fun Divers Tw is celebrating PADI Women&#39;s Day by offering 50% off Diving and Equipment Rental for all women.&nbsp; We are also offering a 20% discount on all gear purchased by women that day!&nbsp; &nbsp;Don&#39;t miss out on this awesome deal!!!</span></p>', '<p class="p1"><span style="font-family:corben,serif">In honor of PADI Women&#39;s Day, Fun Divers Tw is offering Fun Diving and Equipment Rental at 50% off for all women divers!</span></p>', NULL, '<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Fun Divers Tw will be heading out at 8:30 in the morning on July 20th.&nbsp; &nbsp;</span></p>
<p class="font_8 p1">&nbsp;</p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Contact us now to reserve your spot.</span></p>
<p class="font_8 p1">&nbsp;</p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Price:&nbsp; Women:&nbsp; 50% off Diving and Gear rental</span></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">&nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp;&nbsp; &nbsp;20% Gear purchases</span></p>
<p class="font_8 p1">&nbsp;</p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Standard price: Diving 1200ntd</span></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">&nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp;Gear Rental 1000ntd&nbsp;</span></p>
<p class="font_8 p1">&nbsp;</p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Don''t forget to bring your certification card, log book,&nbsp;snacks, towel and sun protection!</span></p>', 'Open to all levels of divers', NULL, NULL, '50% off Diving and Gear Rental', '2019-07-19 16:00:00+00', NULL, false, NULL, '1e1be45b-6ba5-4334-82ef-8331ee24c641', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('6233a861-a6d5-4fae-b8ea-9585e09fad08', 'Panglao', NULL, NULL, NULL, '2025-11-29 04:54:56+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'International Dive Trip', 'wix:image://v1/b37fef_314c4d8b5ff74e39b8d0c56c04c13c8c~mv2.jpg/S__11411536_0.jpg#originWidth=1570&originHeight=1042', NULL, '<p class="font_8">Panglao is a diver’s paradise with a variety of dive sites and an abundance of sea life!</p>', NULL, '<p class="font_8">6D/5N Diving Trip to Panglao, Bohol, Philippines&nbsp;</p>
<p class="font_8"><br></p>
<p class="font_8">2025/12/9-12/14</p>
<p class="font_8">(AOW Certification required for this trip)</p>
<p class="font_8"><br></p>
<p class="font_8">Panglao is a diver’s paradise with a variety of dive sites and an abundance of sea life! &nbsp;Located in the Bohol Province of the Philippines, it is on the list of must-see places for all divers! &nbsp;During the trip, we will do 14 dives, including trips to the islands of Balicasag, Pamilacan, and Napaling, as well as 2 night dives. &nbsp;</p>
<p class="font_8"><br></p>
<p class="font_8">Itinerary (Tentative, subject to dive conditions):</p>
<p class="font_8">12/09: Travel to Panglao</p>
<p class="font_8"><br></p>
<p class="font_8">12/10-12/13</p>
<p class="font_8">Daily itinerary will vary depending on the day’s dive sites. We will do 3 day dives each day and on 2 of the days, we will do a night dive as well. &nbsp;</p>
<p class="font_8">Some of the sites we will visit include:</p>
<p class="font_8">Balicasag Island, Pamilacan Island, and Napaling Reef. &nbsp;</p>
<p class="font_8"><br></p>
<p class="font_8">12/14: Travel back to Taipei</p>
<p class="font_8"><br></p>
<p class="font_8">Trip Price (Per Person):</p>
<p class="font_8">32,900NTD – Shared Room (2 Pax)</p>
<p class="font_8">41,200NTD – Private Room (1 Pax)</p>
<p class="font_8"><br></p>
<p class="font_8">Price Includes:</p>
<p class="font_8">Round trip transportation from Bohol Airport(TAG) to Dive Resort, 5 Nights Room, 14 Boat Dives, Accommodation, Dive Guides, Boat Fees, Outer Island Fees, Diving Tax, Tips, All meals after arrival at the resort.</p>
<p class="font_8"><br></p>
<p class="font_8">Not Included:</p>
<p class="font_8">Plane Tickets, Passport Fees, Corkage, Dive Insurance (DAN insurance recommended for all international dive trips)</p>
<p class="font_8"><br></p>
<p class="font_8">Additional:</p>
<p class="font_8">Full Equipment Rental: $1,800 x 4 (including Computer, SMB, Dive Light)</p>
<p class="font_8">Nitrox Tanks: $400/ea</p>
<p class="font_8"><br></p>
<p class="font_8">Course Discounts:</p>
<p class="font_8">深潛課程 Deep Dive Specialty $5,500 (原價 Normal Price $6,800)</p>
<p class="font_8">高氧課程 Enriched Air Nitrox Specialty $6,200 (原價 Normal Price $7,200)</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer $15,000 deposit to confirm your booking.&nbsp;</p>
<p class="font_8">The remaining balance must be paid by 11/11.</p>
<p class="font_8"><br></p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!</p>
<p class="font_8">中國信託銀行：822</p>
<p class="font_8">帳號：provided by email</p>
<p class="font_8">分行：</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the deposit to:&nbsp;</p>
<p class="font_8">FunDivers</p>
<p class="font_8">CTBC Bank</p>
<p class="font_8">Bank code: 822</p>
<p class="font_8">Account: provided by email</p>
<p class="font_8">Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">＊Remember to Bring:</p>
<p class="font_8">- Certification Card (Advanced required)</p>
<p class="font_8">- Log Book</p>
<p class="font_8">- Passports</p>
<p class="font_8">- Surface Marker Buoy (SMB) – (Required)&nbsp;</p>
<p class="font_8">- Dive Computer (Required)</p>
<p class="font_8">- Reef Hooks (useful but not required)</p>
<p class="font_8"><br></p>
<p class="font_8">臨時取消行程之賠償金額 Cancellation Fee</p>
<p class="font_8">•	60天前取消，行程費用之25% － 25% of Deposit within 60 days of the trip</p>
<p class="font_8">•	30天前取消，行程費用之50% － 50% of Deposit within 30 days of the trip</p>
<p class="font_8">•	21天前取消，不予以退費 － Within 21 days of trip, there will be no refund&nbsp;</p>
<p class="font_8"><br></p>', 'AOW Certification Required', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('6f0d27de-59e9-4563-941b-51c9d1084f40', 'Penghu', NULL, NULL, NULL, '2025-11-25 05:40:15+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'Multi-Day Fun Diving Trip', 'wix:image://v1/b37fef_63da112189aa4c3585f5c9595b4749d8~mv2.jpg/290297154_2210120709138064_5250126471948204383_n.jpg#originWidth=1478&originHeight=1108', NULL, NULL, NULL, '<p class="font_8">跟瘋潛水去澎湖! Dive Penghu with Fun Divers Tw!&nbsp;</p>
<p class="font_8"><br></p>
<p class="font_8">由於澎湖的距離與美景, 它是台灣必潛景點之一! 名額有限, 請盡快報名! Penghu is considered a Must-See dive destination in Taiwan due to its beauty and remoteness! By far, the best diving in all of Taiwan! Space is limited, better book early to secure your spot! &nbsp;</p>
<p class="font_8"><br></p>
<p class="font_8">費用包含 Included:&nbsp;</p>
<p class="font_8">潛水：3日8支船潛(含導潛) 將軍島的餐點住宿上全包 兩人一台機車 三天潛水保險 導潛小費 三天GPS定位信標&nbsp;</p>
<p class="font_8">Dives: 3 Days, 8 Boat Dives (Dive Guides Included) Meals and Accommodation on Jiang Jun Island Shared Motorbike 3 Days of Full Diving Insurance Divemaster Tips (1000ntd/each) 3 Days Locator Beacon Rental &nbsp;</p>
<p class="font_8"><br></p>
<p class="font_8">❋團費不包含Package does not include:&nbsp;</p>
<p class="font_8">三天基本裝備租借 Basic Equipment Rental: $1,200 x 3 days&nbsp;</p>
<p class="font_8">三天全套裝備租借(含電腦錶和浮力棒) Full Equipment Rental: $1,600 x 3 days (includes Dive Computer and SMB)&nbsp;</p>
<p class="font_8">馬公台北來回，原則上以飛機為主(機票約 $4400) Taipei-Magong flights (approximately 4400ntd)&nbsp;</p>
<p class="font_8">潛水裝備超重行李費 (超過10 公斤, $15/公斤) Oversize baggage surcharge for Dive Gear (15ntd/kg over 10kg)&nbsp;</p>
<p class="font_8"><br></p>
<p class="font_8">&nbsp;行程 Approximate Itinerary: &nbsp;</p>
<p class="font_8">Day 1 09:00 乘船到將軍嶼, 安排房間, 享用午餐. Ferry to Jiang Jun Island. Check into rooms and have lunch&nbsp;</p>
<p class="font_8">下午Afternoon: 船潛2支, 2 Boat Dives&nbsp;</p>
<p class="font_8">傍晚Evening: 晚餐 Dinner &nbsp;</p>
<p class="font_8">Days 2&amp;3 &nbsp;南方四島船潛, 每天各3支加2餐. 潛點依當天氣候和海況決定. Daily Itinerary will vary depending on dive conditions and dive locations. There will be 3 Dives both days in Nan Fang Si National Park as well as breakfast and lunch. Dinner on your own</p>
<p class="font_8">Day 4 07:00 搭船回馬公Ferry back to Magong &nbsp;</p>
<p class="font_8"><br></p>
<p class="font_8">＊ 保確您的名額, 請匯入訂金$15,000 Please transfer $15,000 deposit to confirm your booking. 餘款需於04/15付清 The remaining balance must be paid by 04/15. &nbsp;</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶防曬用品、浮力袋(船潛必備) 、電腦錶(船潛必備) 、紀錄書、暈船藥、浴巾，身份證號或居留證號、潛水流鉤 (必備) &nbsp;＊Remember to Bring: - Sun Protection - Certification Card - Log Book - Seasick Pills (if necessary) - Towel - ARC No. or Passport No. / ID Card No. - Surface Marker Buoy (SMB) – (Required for boat dives) - Dive Computer (Required for boat dives) - Reef Hook (Required) &nbsp;</p>
<p class="font_8"><br></p>
<p class="font_8">注意事項Notes: 潛水員必須自行訂購松山-澎湖來回機票. 我們建議先盡快訂購松山到澎湖的航班. 在訂購機票前, 請來電跟我們確認. 在澎湖潛水,有可能遇上強大的海流和有深度的潛點, 是具有挑戰性的. 參加的潛水員需備進階執照及50支氣瓶以上 如有特殊狀況發生(如天災: 颱風, 地震)而滯留, 須追加食宿費用. Divers must book their own flights to Magong from Songshan. We recommend booking the flight as soon as possible. Please get in touch with us before booking the flight.</p>', 'Advanced & EANx Certification Required (Deep Certification Recommended)
Minimum of 50 Logged Dives Required', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('7b1b8d27-eb7d-44ad-8344-d86576a1671c', 'Fun Divers Dive Center', NULL, NULL, NULL, '2019-06-18 05:55:37+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'PADI Open Water Course', 'wix:image://v1/b37fef_454df03ce4384e07bfd5f3d9153b928a~mv2.png/Open%20water.jpg#originWidth=2000&originHeight=1333', '<p class="font_8">The PADI Open Water Course is the first step in your underwater journey!&nbsp; Learn how to use Scuba Diving Equipment, how to handle yourself underwater, and how to fully enjoy your time underwater.&nbsp; Let Fun Divers TW introduce you to the amazing world of Scuba Diving in Taiwan (and the world)! &nbsp;</p>', '<p class="font_8">Start your underwater adventure by getting your PADI Open Water Certification! <strong>Sign up before April 30th to get a discount!</strong></p>', NULL, '<p class="font_8">Do you want to learn to Scuba Dive?! Now is your chance! Fun Divers Tw is starting a PADI Open Water Course on June 6th!</p>
<p class="font_8"><br></p>
<p class="font_8">You can also choose between having class in person or doing PADI e-learning for the academic portion!</p>
<p class="font_8"><br>
<strong>Price</strong> (English Book)：14,400ntd&nbsp;</p>
<p class="font_8">特價(Chinese Book)：14,000ntd</p>
<p class="font_8"><br></p>
<p class="font_8">Price includes books, transportation, and gear rental</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Get a discount if you sign up with a friend!</strong></p>
<p class="font_8"><br></p>
<p class="font_8">今年夏天來成為合格的PADI潛水員吧！<br>
Learn Scuba Diving with Fun Divers Tw!<br>
The Way Diving Should Be Taught<br>
<br>
Fun Divers 課程已完全更新，符合PADI教學課程之規定。為了能夠更安全的享受潛水活動，請跟我們一起學習安全且符合規定的潛水新知吧！<br>
<br>
<strong>6 Jun : 9:00am~5pm (if doing in-person class)</strong><br>
上教室 ，知識複習 ，小考<br>
Do classroom lessons, go over knowledge reviews, and quizzes.<br>
Don''t forget to bring your books</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>7 Jun : 8:30am~4pm<br>
</strong>先上泳池 ，下午回來Fun Divers潛水教室考試<br>
Pool lessons<br>
Bring your swimsuit, towel and a snack</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>13 &amp; 14 Jun : 8:30am-4pm</strong></p>
<p class="font_8">Open Water Dives</p>
<p class="font_8">Bring your swimsuit, towel, snacks, water and logbook</p>
<p class="font_8"><br></p>
<p class="font_8">＊戶外課程將視天氣狀況作調整</p>
<p class="font_8">Find out more information about the <a href="https://www.fundiverstw.com/Courses/PADI-Open-Water-Course"><u>Open Water Course Here</u></a>!</p>', 'Beginning Level Course Open to All', NULL, NULL, '14,400 NTD', '2020-06-05 16:00:00+00', NULL, false, NULL, NULL, false, false) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('7ed20eda-daf2-46a5-90e2-84f63caf6001', 'Fun Divers Dive Center', NULL, NULL, NULL, '2020-07-20 04:19:25+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/fun-divers-dive-center/sep-20%2C-26%2C-27', 'PADI Open Water Course with E-Learning', 'wix:image://v1/b37fef_8dba58f065a9486781cd03ddb65a5cc5~mv2.jpg/2018-06-30%2010.07.26.jpg#originWidth=2000&originHeight=1125', '<p class="font_8">The PADI Open Water Course is the first step in your underwater journey!&nbsp; Learn how to use Scuba Diving Equipment, how to handle yourself underwater, and how to fully enjoy your time underwater.&nbsp; Let Fun Divers TW introduce you to the amazing world of Scuba Diving in Taiwan (and the world)!</p>', '<p class="font_8">Start your underwater adventure by getting your PADI Open Water Certification!</p>', NULL, '<p class="font_8">Do you want to learn to Scuba Dive?! Now is your chance! Fun Divers Tw is starting a PADI Open Water Course on September 20th!&nbsp;</p>
<p class="font_8"><br></p>
<p class="font_8">This course will be a PADI E-Learning Course so the academic portion will all be done on your own and we will meet for the Pool and Ocean sessions. See the schedule below.</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Price</strong> ：14,400ntd</p>
<p class="font_8">Price includes E-Learning, transportation, and gear rental</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Get a discount if you sign up with a friend!</strong></p>
<p class="font_8"><br></p>
<p class="font_8">今年夏天來成為合格的PADI潛水員吧！<br>
Learn Scuba Diving with Fun Divers Tw!<br>
The Way Diving Should Be Taught<br>
<br>
Fun Divers 課程已完全更新，符合PADI教學課程之規定。為了能夠更安全的享受潛水活動，請跟我們一起學習安全且符合規定的潛水新知吧！<br>
<br>
<strong>20 Sep : 8:30am~4pm<br>
</strong>先上泳池 ，下午回來Fun Divers潛水教室考試<br>
Knowledge Check and Pool lessons<br>
Bring your swimsuit, towel and a snack</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>26 &amp; 27 Sep : 8:30am-4pm</strong></p>
<p class="font_8">Open Water Dives</p>
<p class="font_8">Bring your swimsuit, towel, snacks, water and logbook</p>
<p class="font_8"><br></p>
<p class="font_8">＊戶外課程將視天氣狀況作調整</p>
<p class="font_8"><br></p>', 'Beginning Level Course Open to All', NULL, 'Sep 20, 26, 27', '14,400 NTD', '2020-09-19 16:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('418a7178-3e35-4a42-b718-1dc335bcef60', 'Yehliu Boat Diving', NULL, NULL, NULL, '2021-03-26 04:13:49+00', '2026-04-09 08:14:50+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/yehliu-boat-diving/aug-14', 'Local Boat Diving', 'wix:image://v1/b37fef_85f1f222b0bf481c925ebdf59ff1738a~mv2.jpg/blue%20and%20white%20nudi%202.jpg#originWidth=2440&originHeight=1823', '<p class="font_8">Fun Divers Tw is heading out to Yehliu Geo Park to do some boat diving!&nbsp; Come Explore some of the amazing off-shore dive sites with us and see why we love diving there so much.&nbsp; We will be doing 2 boat dives at 2 different sites.&nbsp;</p>', '<p class="font_8">Explore some of the local dive sites not reachable from shore! See wrecks, artificial reefs and natural reefs with abundant sea life!</p>', NULL, '<p class="font_8"><u>費用包含：</u><br>
交通，船潛兩支高氧，潛導，個人指位無線電示標<br>
Included: Transportation, 2 Boat Dives with Nitrox, Dive Guide, Locator Beacon<br>
<br>
<u>團費 Tour Price</u>: $3,200</p>
<p class="font_8"><br></p>
<p class="font_8"><u>課程Courses:</u></p>
<p class="font_8">高氧課程 $5,600 (原價 $6,600) -- Enriched Air Nitrox Specialty $5,600 (Normal $6,600)<br>
<br>
<u>額外費用 Additional:</u><br>
一天基本裝備租借 Basic Equipment Rental: $1200<br>
<br>
潛水錶租借 (必備) Computer Rental <strong>(required):</strong> $300<br>
<br>
浮力袋租借(必備) SMB Rental <strong>(required): </strong>$150<br>
<br>
潛水險 (必要) Diving Insurance <strong>(required):</strong> $400<br>
</p>
<p class="font_8">＊ 請儘早匯入全額，確保您的名額<br>
Please transfer the total As Soon As Possible to confirm your seat.<br>
<br>
匯款帳號如下，匯款完畢,請私訊FunDivers哦!<br>
中國信託銀行：822<br>
帳號：provided by email<br>
分行：</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the payment to:<br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶身份證明, 潛水證, 潛水紀錄本, 防曬用品<br>
＊Remember to Bring:</p>
<p class="font_8">- ARC/ID Card (for Coast Guard)<br>
- Certification Card<br>
- Log Book<br>
- Sun Protection</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>*Dive Location may change due to weather conditions</strong></p>
<p class="font_8"><br></p>
<p class="font_8"><u>Schedule:</u></p>
<p class="font_8"><br></p>
<p class="font_8">06:15 Meet at Fun Divers Tw<br>
06:30 Depart Fun Divers Tw<br>
07:30 Meet at Port<br>
08:00 Boat Departs<br>
12:00 Boat Returns<br>
12:30 Wash Gear/Shower<br>
13:30 Lunch<br>
14:30 Depart for Taipei<br>
15:30 Arrive Fun Divers Tw<br>
&nbsp;<br>
臨時取消行程之賠償金額 Cancellation Fee<br>
• 15天前取消，行程費用之25% － 25% of trip price within 15 days of the trip<br>
• 10天前取消，行程費用之50% － 50% of trip price within 10 days of the trip<br>
• 7天前取消，不予以退費 － Within 7 days of trip price, there will be no refund</p>', 'Advanced and Nitrox Certification Required', NULL, 'Aug 14', '3,200 NTD', '2021-08-13 20:00:00+00', NULL, false, NULL, 'cce2ddd8-cd87-4657-b7e2-3188c07af34a', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('9132a35b-2256-4abf-a7a7-a36342586530', 'Green Island', NULL, NULL, NULL, '2019-01-26 06:38:49+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'Multi-Day Fun Diving Trip', 'wix:image://v1/b37fef_bace0fbdeabd4a928136dfb96f34ef55~mv2.jpg/20151115-IMG_7819.jpg#originWidth=1600&originHeight=1065', '<p class="p1"><span style="font-family:corben,serif">A multi-day trip to Green Island to explore the beautiful waters of the Pacific!&nbsp; We will have time to explore underwater at artificial reefs, coral reefs as well as some of the local wrecks.&nbsp; There is also the option to visit the Zhaori Hot Springs, one of only 3 natural salt water hot springs in the world!</span></p>', '<p class="p1"><span style="font-family:corben,serif">A diving wonderland with a huge variety of sea life.&nbsp; Come explore this gem off the southeast coast of Taiwan with Fun Divers Tw!</span></p>', NULL, '<p class="p1"><span class="wixGuard">​</span></p>', NULL, NULL, NULL, '12,800 NTD', '2019-04-04 16:00:00+00', '6c8ea96c-afb2-4244-9f3e-a2e6cd040788', false, 'wix:document://v1/b37fef_e2efb3ea41f346eeb93bb20c5f682d4c.docx/Green%20Island%20Trip%20Information%20Fun%20Divers.docx', NULL, NULL, true) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('bcafc396-74b5-4c08-90e0-f46e0a426402', 'Greater Xindian Pool', NULL, NULL, NULL, '2023-03-09 03:46:39+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/greater-xindian-pool/apr-15', 'Pool Party and Try Dive', 'wix:image://v1/b37fef_04729138e6214afe9fbce95b513d6875~mv2.jpg/pool%20party%20photo.jpg#originWidth=1883&originHeight=1062', '<p class="font_8">A pool party with try dives to celebrate the start of the 2023 Season. &nbsp;Reconnect with your dive buddies and meet new ones! Bring your friends who are interested in diving and they can try it out! &nbsp;</p>
<p class="font_8"><strong>You also have a chance to win a Crest CR-4 Dive Computer!</strong></p>', '<p class="font_8">Celebrate the start of the 2023 Dive Season with Fun Divers Taiwan! &nbsp;Let''s start the season off with a blast! &nbsp;All attendees have a chance to win a Crest CR-4 Dive Computer as well as other great prizes!</p>', NULL, '<p class="font_8">Fun Divers Taiwan 瘋潛水 is having a Season Opener Pool Party and Try Dive! Reconnect with dive buddies and meet new ones. Bring friends who are interested in learning to dive as well!</p>
<p class="font_8">There will be free try dives during the party!</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Date</strong>: April 15, 2023</p>
<p class="font_8"><strong>Time</strong>: 11:00-17:00</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Entry Fee</strong>: 400NTD</p>
<p class="font_8">Price includes entrance to the pool, 1 free drink, and 1 Raffle ticket</p>
<p class="font_8">Pre-book and pay to get 1 extra free raffle ticket and double your chances of winning! Buy additional tickets: 100 for 1 or 200 for 3</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Raffle Grand Prize is a Crest CR-4 Dive Computer</strong></p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Other prizes include</strong>: Free Day of Diving, Fun Divers T-Shirts, Dive Accessories and more!</p>
<p class="font_8"><br></p>
<p class="font_8">All Attendees also get a 10% discount on fun diving and courses if they sign up by April 30th. &nbsp;(Diving and course can be scheduled for anytime during the 2023 Dive Season)</p>
<p class="font_8"><br></p>', 'none', NULL, 'Apr 15', '400NTD', '2023-04-15 04:00:00+00', NULL, false, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('ce661c4c-874c-43e5-8f63-562c46a7a9cf', 'Fun Divers Dive Center', NULL, NULL, NULL, '2019-05-15 06:52:12+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'PADI Advanced Course', 'wix:image://v1/b37fef_3166e2616932488aad593a8fb4c8f6d8~mv2.jpg/64365829_2620424691314544_71180475215443.jpg#originWidth=1200&originHeight=900', '<p class="p1"><span style="font-family:corben,serif">By taking the<span style="text-decoration:underline"><a href="https://www.fundiverstw.com/Courses/PADI-Advanced-Course"> PADI Advanced Course</a></span>, you will learn more about the underwater world while expanding your diving skills.&nbsp; You will practice your navigation and go deeper.&nbsp; After the course, you will be certified to 30 meters which will open up more dive sites to you around the world.&nbsp; You will also be able to choose 3 specialty dives based on your interests!</span></p>

<p class="p1"><span style="font-family:corben,serif">​</span></p>

<p class="p1"><span style="font-family:corben,serif">Top 10 reasons to&nbsp;take the PADI Advanced Course:</span></p>

<p class="p1"><span style="font-family:corben,serif">1. Increase your knowledge of diving</span></p>

<p class="p1"><span style="font-family:corben,serif">2. Expand the skills you&rsquo;ve learned while supervised</span></p>

<p class="p1"><span style="font-family:corben,serif">3. Dive as deep as 30m and see more</span></p>

<p class="p1"><span style="font-family:corben,serif">4. Gain confidence in yourself</span></p>

<p class="p1"><span style="font-family:corben,serif">5. Be more comfortable in the water</span></p>

<p class="p1"><span style="font-family:corben,serif">6. Be more comfortable with the equipment</span></p>

<p class="p1"><span style="font-family:corben,serif">7. Try 5 different kinds of adventure dives</span></p>

<p class="p1"><span style="font-family:corben,serif">8. More chances to explore different dive sites locally and worldwide</span></p>

<p class="p1"><span style="font-family:corben,serif">9. Higher credentials, less hassle when traveling</span></p>

<p class="p1"><span style="font-family:corben,serif">10. Meet new dive buddies</span></p>', '<p class="font_8 p1"><span style="font-family: corben, serif">The PADI Advanced Open Water Diver Course is a great way to improve your diving skills, get additional diving experience under the supervision of an instructor and increase your knowledge about diving.&nbsp;</span></p>', NULL, '<p class="font_8" style="font-size: 17px"><span style="font-size: 17px"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Come take the next step in your diving adventure and get your PADI Advanced Certification with Fun Divers Tw!</span></span><br>
&nbsp;</p>
<p class="font_8" style="font-size: 17px"><span style="font-size: 17px"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">By taking the PADI Advanced Course, you will learn more about the underwater world while expanding your diving skills. You will practice your navigation and go deeper. After the course, you will be certified to 30 meters which will open up more dive sites to you around the world. You will also be able to choose 3 specialty dives based on your interests! Choose which specialties are right for you!</span></span></p>
<p class="font_8" style="font-size: 17px"><br>
&nbsp;<span style="font-size: 17px"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif"><strong>Course Price (with English Book) </strong></span></span><span style="font-size: 17px"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">：$10,400</span></span></p>
<p class="font_8" style="font-size: 17px"><span style="font-size: 17px"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif"><strong>價錢 (中文教材)</strong></span></span><span style="font-size: 17px"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">：$10,000</span></span><br>
&nbsp;</p>
<p class="font_8" style="font-size: 17px"><span style="font-size: 17px"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif"><strong>Get a discount if you sign up with a friend!</strong></span></span></p>
<p class="font_8" style="font-size: 17px"><br>
&nbsp;<span style="font-size: 17px"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Gear Rental: 1200ntd/Day.</span></span></p>
<p class="font_8"><span style="font-size: 17px"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Additional gear rental charge for some specialties.</span></span></p>
<p class="font_8" style="font-size: 17px"><br>
&nbsp;<span style="font-size: 17px"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Course fees include Books and Transportation.</span></span></p>
<p class="font_8" style="font-size: 17px">&nbsp;</p>
<p class="font_8" style="font-size: 17px"><span style="font-size: 17px"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Learn Scuba Diving with Fun Divers Tw! The Way Diving Should Be Taught!</span></span></p>
<p class="font_8" style="font-size: 17px"><span style="font-size: 17px"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">今年夏天來成為合格的PADI潛水員吧！</span></span></p>', 'PADI Open Water Certification (or other organization equivalent) Required before taking this course', NULL, NULL, '10,400 NTD', '2020-05-15 16:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('cfe5ff09-96a9-47b1-ab6e-20d026ef5a40', 'Happy World Pool', NULL, NULL, NULL, '2019-03-15 00:54:01+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'Free Try Dive', 'wix:image://v1/b37fef_b22c67c4e51440c1929b2292262e7b15~mv2.jpg/20170514-IMG_3567.jpg#originWidth=1600&originHeight=1067', '<p class="p1"><span style="font-family:corben,serif">Are you curious about diving but not sure if it is right for you?&nbsp; Come give Scuba Diving a try in the comfort of a swimming pool and see what it is like to breathe underwater for the first time!&nbsp; You will get to try on the gear, practice breathing under water, and even go for an underwater swim using the Scuba Gear!&nbsp;&nbsp;</span></p>', '<p class="p1"><span style="font-family:corben,serif;">Are you curious about diving but not sure if it is right for you?&nbsp; Come give Scuba Diving a try in the comfort of a swimming pool and see what it is like to breathe underwater for the first time!</span></p>', NULL, '<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">週六(4/20) Fun Divers 特別為大家準備了一場免費的泳池體驗潛水！想知道在水中吐泡泡的感覺嗎？歡迎來大新店游泳池找我們體驗喔！<br />
加拿大國慶日慶祝活動，當天報名PADI潛水課程的朋友，即可獲得免費面鏡及呼吸管一組～<br />
<br />
Want to know what it feels like to breath underwater? Curious about scuba diving but not sure if it is for you?<br />
<br />
Come try Scuba Diving with Fun Divers for FREE, Saturday, April 20th at Happy World.<br />
<br />
We will be in the water from 10am-1pm. Come by and see what you are missing!<br />
<br />
Notes:<br />
<br />
Be sure to bring a swimsuit and swim cap.<br />
The pool entrance fee for those who want to do the try dive is 100ntd but after you try scuba diving, stay and enjoy the pool facilities! There are hot tubs, saunas, children&rsquo;s play area, indoor heated pool, and other facilities to try out.<br />
<br />
前往大新店泳池參加體驗潛水的朋友們～<br />
大新店招待入門票$100(原價$300)<br />
趕快把握機會哦！</span></p>', NULL, NULL, NULL, 'FREE(just pay pool entry fee)', '2019-04-19 16:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('e02ff469-09b8-449b-95e8-95d8c0a373b1', 'Secret Garden', NULL, NULL, NULL, '2019-03-14 04:57:40+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/secret-garden/2024-03-30', 'Local Shore Diving', 'wix:image://v1/b37fef_40a5952412534a118f65ed71551422e4~mv2_d_4026_3008_s_4_2.jpg/Lobster1.jpg#originWidth=4026&originHeight=3008', '<p class="font_8">A lovely dive site full of soft corals and giant groupers.&nbsp; Also a great place to see nudibranchs.</p>', '<p class="font_8">A lovely dive site full of soft coral and giant groupers. Also a great place to see Nudibranchs!</p>', NULL, '<p class="font_8">Fun Divers Tw&nbsp;is heading to Secret Garden to do some fun diving!&nbsp; Come join us for some fun in the sun and under the water!</p>
<p class="font_8">&nbsp;</p>
<p class="font_8">We depart from Fun Divers at 8:30 am and return at 4:30 pm.</p>
<p class="font_8"><br></p>
<p class="font_8">Price: 1500ntd for 2 dives including: tanks, transportation, dive guide, and full coverage local dive insurance.</p>
<p class="font_8">&nbsp;</p>
<p class="font_8">Gear rental is 1500ntd for a full set, including dive computer.</p>
<p class="font_8">&nbsp;</p>
<p class="font_8">RSVP early since there are limited spots available.</p>
<p class="font_8">&nbsp;</p>
<p class="font_8">Be sure to bring sunscreen, snacks, water, and swimsuit.&nbsp;&nbsp;If you have any other questions about courses and other events, please feel free to send us a message!&nbsp;&nbsp;See you in the water!</p>', 'A challenging but beautiful dive site', NULL, '2024-03-30', '1,500 NTD', '2020-05-22 16:00:00+00', NULL, true, NULL, 'cb84ef01-98e5-4b17-b06d-3fc681a0107a', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('eb686139-46ec-4c7c-abe5-5613e6f6731e', 'Long Dong Bay Weekend', '2 Shore Dives, Tanks, Weights, Dive Guide, Transportation from Fun Divers Tw, and Full Coverage Local Dive Insurance', 'Gear Rental, food & drinks are not included', NULL, '2024-03-14 05:16:12+00', '2026-04-09 12:28:35+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/long-dong-bay/2024-03-28', 'Local Shore Diving', 'wix:image://v1/b37fef_dd7896ba82d140999eb8d813d246920b~mv2.jpg/Long%20Dong%20Bay%20bird''s%20eye.jpg#originWidth=600&originHeight=399', NULL, '<p class="font_8">A popular site, whose name translates to "Dragon''s Cave Bay". Explore the underwater ridge and the Squid Farms when in season!</p>', 'A popular site, whose name translates to "Dragon''s Cave Bay". Explore the underwater ridge and the Squid Farms when in season!', NULL, 'Must be a certified diver.', '8:20 - Meet at Fun Divers Tw
8:30 - Depart Fun Divers Tw
9:30 - Arrive at Long Dong Bay
2 Shore Dives
14-15:00 - Depart Long Dong Bay
15-16:00 - Arrive Fun Divers Tw', '2024-03-28', '1,600 NTD', NULL, NULL, true, NULL, '9fe728dc-4ca7-4d90-bad0-6aaf6edb5329', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('eb8ce40c-8ece-477a-aeeb-828dec28a69b', 'Fun Divers Dive Center', NULL, NULL, NULL, '2019-05-15 07:17:24+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'PADI Rescue Course', 'wix:image://v1/b37fef_089babb8c3cf4f7b8c993a574dbbaa0a~mv2.jpg/rescue%20course%20picture.jpg#originWidth=1000&originHeight=667', '<p class="font_8">The PADI Rescue Diver Course prepares you to deal with dive emergencies, minor and major, using a variety of techniques. Through knowledge development and rescue exercises, you learn what to look for and how to respond. During rescue scenarios, you put into practice your knowledge and skills.</p>
<p class="font_8">Topics include:</p>
<ul class="font_8">
  <li><p class="font_8">Self-rescue</p></li>
  <li><p class="font_8">Recognizing and managing stress in other divers</p></li>
  <li><p class="font_8">Emergency management and equipment</p></li>
  <li><p class="font_8">Rescuing panicked divers on the surface and underwater</p></li>
  <li><p class="font_8">Rescuing unresponsive divers on the surface and underwater</p></li>
  <li><p class="font_8">Missing diver procedures&nbsp;</p></li>
</ul>', '<p class="font_8">Learn to manage or prevent problems in or out of the water.&nbsp; Be the dive buddy others can rely on!&nbsp;&nbsp;&nbsp;The PADI Rescue Diver course is a challenging, yet rewarding course that will make you a better diver who is more confident in their abilities!</p>', NULL, '<p class="font_8"><u><strong>PADI Rescue Course with Fun Divers Tw</strong></u></p>
<p class="font_8"><br></p>
<p class="font_8">Are you ready to be the best diver you can be? Come take the PADI Rescue Diver course with Fun Divers Tw!</p>
<p class="font_8"><br></p>
<p class="font_8">In this course you will learn how to prevent emergencies before they happen and deal with emergencies when they do happen. It is a challenging, yet rewarding course that will make you a better diver who is more confident in their abilities!</p>
<p class="font_8"><br></p>
<p class="font_8">To get your PADI Rescue Diver Certification, you must have a current First Aid/CPR Certification. For those who don’t have one, we can schedule you for a PADI Emergency First Responder (EFR) Course in conjunction with the Rescue Diver Course.</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Course price:</strong> &nbsp;</p>
<p class="font_8">Rescue Course: 9,200ntd</p>
<p class="font_8">EFR Course: 5,800ntd</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Get a discount if you sign up with a friend!</strong></p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Gear rental:</strong> 1200ntd/day</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Course Schedule:</strong></p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Jun 6:</strong> Rescue Course Classroom and Pool Session</p>
<p class="font_8"><strong>Jun 7:</strong> Rescue Course Ocean Session at Batcave</p>
<p class="font_8"><br></p>
<p class="font_8">Contact us about scheduling your PADI EFR Course</p>
<p class="font_8"><br></p>
<p class="font_8">See more details about the PADI Rescue Course on our <a href="https://www.fundiverstw.com/Courses/PADI-Rescue-Diver-Course">website</a>!</p>', 'PADI Advanced Certification and 20 Dives Minimum Reqiured', NULL, NULL, '9,200 NTD', '2020-06-05 17:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('f974d3d1-49c0-4d63-a28c-076360781a3c', 'Long Dong Bay Weekday', '2 Shore Dives, Tanks, Weights, Dive Guide, Transportation from Fun Divers Tw, and Full Coverage Local Dive Insurance', 'Gear Rental, food & drinks are not included', NULL, '2026-04-09 12:28:17+00', '2026-04-09 12:28:58+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/long-dong-bay/2024-03-28', 'Local Shore Diving', 'wix:image://v1/b37fef_dd7896ba82d140999eb8d813d246920b~mv2.jpg/Long%20Dong%20Bay%20bird''s%20eye.jpg#originWidth=600&originHeight=399', NULL, '<p class="font_8">A popular site, whose name translates to "Dragon''s Cave Bay". Explore the underwater ridge and the Squid Farms when in season!</p>', 'A popular site, whose name translates to "Dragon''s Cave Bay". Explore the underwater ridge and the Squid Farms when in season!', NULL, 'Must be a certified diver.', '8:50 - Meet at Fun Divers Tw
9:00 - Depart Fun Divers Tw
10:00 - Arrive at Long Dong Bay
2 Shore Dives
14-15:00 - Depart Long Dong Bay
15-16:00 - Arrive Fun Divers Tw', '2024-03-28', '1,600 NTD', NULL, NULL, true, NULL, '9fe728dc-4ca7-4d90-bad0-6aaf6edb5329', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('00055e84-c763-44e8-9efc-929cc5a70d65', 'Yehliu 4BD EANx', 'Transportation(if needed), Local Diving Insurance, 4 Boat Dives, 4 Nitrox Tanks, Dive Guide', 'Gear Rental, Food/Drinks', NULL, '2021-03-26 04:13:32+00', '2026-04-09 08:36:25+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/yehliu-boat-diving/jun-26', 'Local Boat Diving', 'wix:image://v1/b37fef_eb9fd3a1bacc4befbd13f008acbf22b6~mv2_d_2000_1333_s_2.jpg/Boat%20Diving.jpg#originWidth=2000&originHeight=1333', '<p class="font_8">Fun Divers Tw is heading out to Yehliu to do some boat diving!&nbsp; Come Explore some of the amazing off-shore dive sites with us and see why we love diving there so much.&nbsp; We will be doing 2 boat dives at 2 different sites.&nbsp;</p>', '<p class="font_8">Explore some of the local dive sites not reachable from shore! See wrecks, artificial reefs and natural reefs with abundant sea life!</p>', 'Explore some of the local dive sites not reachable from shore! See wrecks, artificial reefs and natural reefs with abundant sea life!', '<p class="font_8"><u>費用包含：</u><br>
交通，船潛兩支高氧，潛導，個人指位無線電示標<br>
Included: Transportation, 2 Boat Dives with Nitrox, Dive Guide, Locator Beacon<br>
<br>
<u>團費 Tour Price</u>: $3,200</p>
<p class="font_8"><br></p>
<p class="font_8"><u>課程Courses:</u></p>
<p class="font_8">高氧課程 $5,600 (原價 $6,600) -- Enriched Air Nitrox Specialty $5,600 (Normal $6,600)<br>
<br>
<u>額外費用 Additional:</u><br>
一天基本裝備租借 Basic Equipment Rental: $1200<br>
<br>
潛水錶租借 (必備) Computer Rental <strong>(required):</strong> $300<br>
<br>
浮力袋租借(必備) SMB Rental <strong>(required): </strong>$150<br>
<br>
潛水險 (必要) Diving Insurance <strong>(required):</strong> $400<br>
</p>
<p class="font_8">＊ 請儘早匯入全額，確保您的名額<br>
Please transfer the total As Soon As Possible to confirm your seat.<br>
<br>
匯款帳號如下，匯款完畢,請私訊FunDivers哦!<br>
中國信託銀行：822<br>
帳號：provided by email<br>
分行：</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the payment to:<br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶身份證明, 潛水證, 潛水紀錄本, 防曬用品<br>
＊Remember to Bring:</p>
<p class="font_8">- ARC/ID Card (for Coast Guard)<br>
- Certification Card<br>
- Log Book<br>
- Sun Protection</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>*Dive Location may change due to weather conditions</strong></p>
<p class="font_8"><br></p>
<p class="font_8"><u>Schedule:</u></p>
<p class="font_8"><br></p>
<p class="font_8">06:15 Meet at Fun Divers Tw<br>
06:30 Depart Fun Divers Tw<br>
07:30 Meet at Port<br>
08:00 Boat Departs<br>
12:00 Boat Returns<br>
12:30 Wash Gear/Shower<br>
13:30 Lunch<br>
14:30 Depart for Taipei<br>
15:30 Arrive Fun Divers Tw<br>
&nbsp;<br>
臨時取消行程之賠償金額 Cancellation Fee<br>
• 15天前取消，行程費用之25% － 25% of trip price within 15 days of the trip<br>
• 10天前取消，行程費用之50% － 50% of trip price within 10 days of the trip<br>
• 7天前取消，不予以退費 － Within 7 days of trip price, there will be no refund</p>', 'AOW & Nitrox Certification Required', '06:15 - Meet at Fun Divers
07:30 - Meet at Port
08:00 - Boat Departs
17:00 - Boat Returns (wash gear at port)
17:30 - Depart for Taipei', 'Jun 26', '3,200 NTD', '2021-06-25 20:00:00+00', NULL, false, NULL, 'cce2ddd8-cd87-4657-b7e2-3188c07af34a', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('01cf0fc7-b7db-4653-bb29-92d6e9274d29', '82.5', NULL, NULL, NULL, '2019-07-25 11:26:05+00', '2026-04-16 13:21:20+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/82.5/2024-03-31', 'Local Shore Diving', 'wix:image://v1/b37fef_e737e654b94f4e6a91e2e5a523e3054f~mv2_d_4026_3008_s_4_2.jpg/nudi%20blue%20and%20yellow%20smaller.jpg#originWidth=4026&originHeight=3008', '<p class="font_8">A beautiful dive site with a wall to dive along.&nbsp; Keep your eyes open for the Pikachu Nudibranch!</p>', '<p class="font_8">A beautiful dive site with a wall to dive along.&nbsp; Keep your eyes open for the Pikachu Nudibranch!</p>', NULL, '<p class="font_8">Come out and explore 82.5 with Fun Divers!</p>
<p class="font_8"><br></p>
<p class="font_8">We will depart Fun Divers Tw at 8:30am so please arrive by 8:15am. If you are meeting at the dive site, we should arrive by 9:15am</p>
<p class="font_8"><br>
RSVP early since there are limited spots available.</p>
<p class="font_8">＊請儘早匯入全額費用以確保您的名額<br>
</p>
<p class="font_8">Please transfer the total amount As Soon As Possible to confirm your seat.<br>
<br>
Please transfer payments to:<br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
<br>
Be sure to bring sun protection, snacks, water, and swimsuit.<br>
<br>
If you have any questions about courses or any other events, please feel free to send us a message!</p>', 'Advanced Certification Required', NULL, '2024-03-31', '1,500NTD', '2019-10-10 16:00:00+00', NULL, true, NULL, '5efcc605-3086-420b-a15c-43694ece1237', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('07785aa1-a9fb-4778-af07-48762b03feaf', 'Lambai Island/Xiao Liuqiu', 'Return Ferry Tickets, 2 Nights Shared Rooms, 2 Breakfasts, 2 Lunches, 1 Dinner, 2 Days Shared Motorbike, 4 Boat Dives, 2 Days Full Coverage Local Diving Insurance.', 'Additional Food, Drinks & Entertainment are NOT included.
Optional Night Dive is NOT included.', 'You can take the HSR and meet us at the hotel in Kaohsiung and then travel to the Ferry Port with us.  
Round Trip Transportation with us is 1300NTD', '2019-01-06 07:46:06+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'Multi-Day Fun Diving Trip', 'wix:image://v1/b37fef_8ea21518788d4905a979167bb7802232~mv2_d_4043_3032_s_4_2.jpg/turtle%20swimming.JPG#originWidth=4043&originHeight=3032', '<p class="font_8">A weekend trip to Lambai Island to enjoy some time away from the city!&nbsp; We will be diving with sea turtles, exploring wrecks, and having BBQ in the evening!&nbsp; Come join us on this wonderful trip and see why divers love Xiao Liuqiu!</p>', '<p class="font_8">A multi-day trip to a&nbsp;beautiful coral Island off the coast of Kaohsiung. Turtles galore!&nbsp; Come explore this gem with Fun Divers Tw!</p>', 'A weekend trip to Lambai Island to enjoy some time away from the city!  We will be diving with sea turtles, exploring wrecks, and having BBQ in the evening!  Come join us on this wonderful trip and see why divers love Xiao Liuqiu!', '<p class="font_8">小琉球 小琉球 Beautiful Lambai</p>
<p class="font_8"><br></p>
<p class="font_8">A weekend trip to Lambai Island to enjoy some time away from the city! We will be diving with sea turtles, exploring wrecks, and having BBQ in the evening! Come join us on this wonderful trip and see why divers love Xiao Liuqiu!</p>
<p class="font_8"><br></p>
<p class="font_8">費用包含：</p>
<p class="font_8">往返東港船票， 兩晚上住宿 ，早餐 x 2，午餐 x 2，晚餐 x 1，機車(兩人一台)，船潛四支，岸潛一支, 潛水險。</p>
<p class="font_8"><br></p>
<p class="font_8">Included:</p>
<p class="font_8">Round Trip Ferry, 2 Nights Shared Rooms, 2 Breakfasts, 2 Lunches, 1 Dinner, 2 Days Shared Motorbike, 4 Boat Dives, 1 Shore Dive, Diving Insurance</p>
<p class="font_8"><br></p>
<p class="font_8">＊額外之餐費與娛樂費用請自理</p>
<p class="font_8">Additional Food, Drinks &amp; Entertainment are NOT included</p>
<p class="font_8"><br></p>
<p class="font_8">團費 Tour Price:</p>
<p class="font_8">背包房 Bunk Room: $11,800</p>
<p class="font_8">雙人房 Basic Double Room: $13,500 (double occupancy) (limited availability)</p>
<p class="font_8">Private room: $15,500</p>
<p class="font_8"><br></p>
<p class="font_8">額外費用Additional:</p>
<p class="font_8">兩天裝備租借 Basic Equipment Rental: $1,200 x 2 days</p>
<p class="font_8">全套裝備租借(含電腦錶和浮力棒) Full Equipment Rental: $1,600 x 2 days</p>
<p class="font_8">(includes Dive Computer and SMB)</p>
<p class="font_8">台北東港來回交通費 Return Transport Taipei-Donggang port: $1,600</p>
<p class="font_8">Transport Kaohsiung-Donggang - $300</p>
<p class="font_8">Optional Night Dive: $1000</p>
<p class="font_8">Light Rental: $200</p>
<p class="font_8"><br></p>
<p class="font_8">課程Courses:</p>
<p class="font_8">高氧課程 Enriched Air Nitrox Specialty $6,400 (原價 Normal Price $7,200)</p>
<p class="font_8">深潛課程 Deep Dive Specialty $5,800 (原價 Normal Price $6,800)</p>
<p class="font_8">進階課程 Advanced Open Water $11,200 (原價 Normal Price $12,500)</p>
<p class="font_8"><br></p>
<p class="font_8">行程 Approximate Itinerary:</p>
<p class="font_8"><br></p>
<p class="font_8">Day 1</p>
<p class="font_8">16:00 離開台北Depart Fun Divers Dive Center (earlier if possible)</p>
<p class="font_8">20:00飯店Hotel Kaohsiung</p>
<p class="font_8"><br></p>
<p class="font_8">Day 2</p>
<p class="font_8">07:00 早餐 Breakfast</p>
<p class="font_8">08:00 出發 Depart</p>
<p class="font_8">09:00 東港漁港 Donggang Dock－小琉球 Liu Qiu Island</p>
<p class="font_8">10:00 安潛一支 1 Shore Dive</p>
<p class="font_8">11:30 中餐 Lunch</p>
<p class="font_8">12:30 船潛兩支 2 Boat Dives</p>
<p class="font_8">18:00 吃到飽烤肉 All you can eat BBQ Dinner</p>
<p class="font_8"><br></p>
<p class="font_8">Day 3</p>
<p class="font_8">07:30 早餐Breakfast</p>
<p class="font_8">08:00 船潛兩支 2 Boat Dives</p>
<p class="font_8">12:30 中餐 Lunch</p>
<p class="font_8">14:00 小琉球 Liu Qiu Island ─ 東港 Donggang</p>
<p class="font_8">14:30 離開東港 Depart from Donggang</p>
<p class="font_8">20:30 抵達台北 Arrive in Taipei</p>
<p class="font_8"><br></p>
<p class="font_8">＊ 請於匯入訂金 $8,000 Please transfer $8,000 deposit to confirm your booking.</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the deposit to:</p>
<p class="font_8">FunDivers CTBC Bank</p>
<p class="font_8">Bank code: 822</p>
<p class="font_8">Account: provided by email</p>
<p class="font_8">Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!</p>
<p class="font_8">中國信託銀⾏：822</p>
<p class="font_8">帳號：provided by email</p>
<p class="font_8">分⾏：</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶 Remember to Bring:</p>
<p class="font_8">- 證照卡 Certification Card</p>
<p class="font_8">- 潛水日誌 Log Book</p>
<p class="font_8">- 電腦表 Dive Computer(required) (rental 300/day)</p>
<p class="font_8">- 浮力棒 (SMB) Surface Marker Buoy(required) (rental 150/day)</p>
<p class="font_8">- 暈船藥 Seasick Pills</p>
<p class="font_8">- 防賽 Sun Protection</p>
<p class="font_8">- 大毛巾Towel</p>
<p class="font_8">- 薄夾克Jacket</p>
<p class="font_8"><br></p>
<p class="font_8">臨時取消行程之賠償金額 Cancellation Fee</p>
<p class="font_8">· 14天前取消，行程費用之25% － 25% of Deposit within 14 days of the trip</p>
<p class="font_8">· 10天前取消，行程費用之50% － 50% of Deposit within 10 days of the trip</p>
<p class="font_8">· 07天前取消，不予以退費 － Within 7 days of trip, no refund</p>', 'Advanced Certification Recommended', 'Day 1
16:00 離開台北Depart Fun Divers Dive Center (earlier if possible)
20:00飯店Hotel Kaohsiung

Day 2
07:00 早餐 Breakfast
08:00 出發 Depart
09:00 東港漁港 Donggang Dock－小琉球 Liu Qiu Island
10:00 安潛一支 1 Shore Dive
11:30 中餐 Lunch
12:30 船潛兩支 2 Boat Dives
18:00 吃到飽烤肉 All you can eat BBQ Dinner

Day 3
07:30 早餐Breakfast
08:00 船潛兩支 2 Boat Dives
12:30 中餐 Lunch
14:00 小琉球 Liu Qiu Island ─ 東港 Donggang
14:30 離開東港 Depart from Donggang
20:30 抵達台北 Arrive in Taipei', NULL, 'Starting at 10,200 NTD', '2020-05-14 16:00:00+00', 'b718703b-b6d6-43ff-b56e-f886ed67d9c5', false, NULL, NULL, NULL, true) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('16292936-767d-465c-b58d-82a81604924f', 'Yehliu Boat Diving', NULL, NULL, NULL, '2020-08-10 07:02:54+00', '2026-04-09 08:14:50+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/yehliu-boat-diving/sep-5', 'Boat Diving', 'wix:image://v1/b37fef_dea5801e2b484d25abdbbcaea90af9a9~mv2.jpg/2020-07-25%2015.24.30.jpg#originWidth=800&originHeight=533', '<p class="font_8">Fun Divers Tw will visit Yehliu Geo Park for some boat diving! &nbsp;Come relax and check out the scenery above and below the water at Yehliu!</p>', '<p class="font_8">Yehliu Geo Park has stunning scenery both above and below the water! &nbsp;Come explore this beautiful place with Fun Divers Tw!</p>', NULL, '<p class="font_8">野柳 Yeliu</p>
<p class="font_8"><br></p>
<p class="font_8">費用包含: 船潛兩支高氧,<br>
Included: 2 Boat Nitrox Dives</p>
<p class="font_8"><br></p>
<p class="font_8">＊餐費用請自理</p>
<p class="font_8">Food and Drinks are NOT included</p>
<p class="font_8"><br></p>
<p class="font_8">團費 Tour Price: &nbsp;$4,000</p>
<p class="font_8">交通費用 Return Transport: $200</p>
<p class="font_8"><br></p>
<p class="font_8">(交通車有8個位子Total of 10 spots reserved)</p>
<p class="font_8"><br></p>
<p class="font_8">額外費用Additional:<br>
 兩天裝備租借Full Equipment Rental: $1,200</p>
<p class="font_8"><br></p>
<p class="font_8">10:30 瘋潛水集合 Meet at Fun Divers Dive Center</p>
<p class="font_8"><br></p>
<p class="font_8">課程Courses:</p>
<p class="font_8">高氧課程 $5,000 (原價 $5,800) -- Enriched Air Nitrox Specialty $5,200 (Normal $6,000)</p>
<p class="font_8">深潛課程$5,000) -- Deep Dive Specialty $5,200 (Normally $6,000)</p>
<p class="font_8"><br></p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!<br>
 中國信託銀行：822<br>
 帳號：provided by email</p>
<p class="font_8">分行：</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the deposit to: <br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶防曬用品,浮力袋(船潛必備)，電腦表，紀錄書， 身份證號或居留證號</p>
<p class="font_8">＊Remember to Bring: Certification Card, Log Book, Dive Computer, Surface Marker Buoy (SMB)</p>
<p class="font_8"><br></p>
<p class="font_8"><u>臨時取消行程之賠償金額 Cancellation Fee</u></p>
<p class="font_8">· 10天前取消，行程費用之25% － 25% of trip price within 10 days of the trip</p>
<p class="font_8">· 7天前取消，行程費用之50% － 50% of trip price within 7 days of the trip</p>
<p class="font_8">· 5天前取消，不予以退費 － Within 5 days of trip price, there will be no refund</p>', 'Advanced and Nitrox Certification Required', NULL, 'Sep 5', '4,000 NTD', '2020-09-04 17:00:00+00', NULL, false, NULL, 'cce2ddd8-cd87-4657-b7e2-3188c07af34a', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('1743a1b4-0d48-409f-a7bf-e8d1c399dc12', 'Lamay Island', 'Return Ferry Tickets, 2 Nights Shared Rooms, 2 Breakfasts, 2 Lunches, 1 Dinner, 2 Days Shared Motorbike, 4 Boat Dives, 2 Days Full Coverage Local Diving Insurance.', NULL, NULL, '2019-08-16 12:24:12+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'Multi-Day Fun Diving Trip', 'wix:image://v1/b37fef_f76afdb6881e495392d867a3b5697132~mv2_d_4608_3456_s_4_2.jpg/turtle%20closeup%20smaller.JPG#originWidth=4608&originHeight=3456', '<p class="font_8 p1"><span style="font-family: corben, serif">A weekend trip to Lamay Island to enjoy some time away from the city!&nbsp; We will be diving with sea turtles, exploring wrecks, and having BBQ in the evening!&nbsp; Come join us on this wonderful trip and see why divers love Xiao Liuqiu!</span></p>', '<p class="font_8 p1"><span style="font-family: corben, serif">A multi-day trip to a&nbsp;beautiful coral Island off the coast of Kaohsiung. Turtles galore!&nbsp; Come explore this gem with Fun Divers Tw!</span></p>', 'A weekend trip to Lambai Island to enjoy some time away from the city!  We will be diving with sea turtles, exploring wrecks, and having BBQ in the evening!  Come join us on this wonderful trip and see why divers love Xiao Liuqiu!', '<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">小琉球 小琉球 Lambai Lambai</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">&nbsp;</span></p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">費用包含：</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">往返東港船票， 兩晚上住宿 ，早餐 x 2，午餐 x 2，晚餐 x 1，機車(兩人一台)，船潛四支， 岸潛一支。</span></p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Included:</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Return Ferry, 2 Nights Shared Rooms, 2 Breakfasts, 2 Lunches, 1 Dinner, 2 Days Shared Motorbike, 4 Boat Dives, 1 Shore Dive.</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">&nbsp;</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">＊額外之餐費與娛樂費用請自理</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Additional Food, Drinks &amp; Entertainment are NOT included</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">&nbsp;</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif"><span style="font-weight:bold">團費 Tour Price:</span><br />
雙人房 Double Room: $10,800 (double occupancy)<br />
背包房Capsule Room: $10,200</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">(交通車有8個位子 Total of 8 spots reserved)</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">歡迎非潛水員參加 Non-Divers are also welcome to join $5,800</span></p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">&nbsp;</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif"><span style="font-weight:bold">額外費用 Additional:</span><br />
兩天裝備租借 Full Equipment Rental: $1,200 x 2<br />
台北東港來回交通費 Return Transport: $1,400</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">&nbsp;</span></p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">課程 Courses:</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">高氧課程 $4,800 (原價 $5,500) -- Enriched Air Nitrox Specialty $5,200 (Normal $6,000)</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">深潛課程 $4,800 (原價 $5,600) -- Deep Dive Specialty $4,800 (Normally $6,000)</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">進階課程 $8,000 (原價 $10,000) -- Advanced Open Water $8,400 (Normally $10,400)</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">初級課程 $10,600 (原價 $13,900) -- Open Water Course $11,000 (Normally $14,400)</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">&nbsp;</span></p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">＊ 請於匯入訂金$8,000 Please transfer $8,000 deposit to confirm your booking.</span></span></p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">餘款需於02/21付清 The remaining balance must be paid by 02/21.</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">&nbsp;</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">匯款帳號如下，匯款完畢,請私訊FunDivers哦!<br />
中國信託銀行：822<br />
帳號：provided by email</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">&nbsp;</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif"><span style="font-weight:bold">Please transfer the deposit to:</span><br />
FunDivers<br />
CTBC Bank<br />
Bank code: 822<br />
Account: provided by email</span><br />
&nbsp;</p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">&nbsp;</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">＊記得攜帶防曬用品,浮力袋(船潛必備)，電腦表，紀錄書， 身份證號或居留證號</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">＊Remember to Bring:</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">- Certification Card</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">- Log Book</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">- ARC No. or Passport No. / ID Card No.</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">- Surface Marker Buoy (SMB) &ndash; (Highly recommended)</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">&nbsp;</span></p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">臨時取消行程之賠償金額 Cancellation Fee</span></span></p>

<ul class="font_7" style="font-family:avenir-lt-w01_35-light1475496,sans-serif">
	<li>
	<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">14天前取消，行程費用之25% － 25% of Deposit within 14 days of the trip</span></p>
	</li>
	<li>
	<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">10天前取消，行程費用之50% － 50% of Deposit within 10 days of the trip</span></p>
	</li>
	<li>
	<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">07天前取消，不予以退費 － Within 7 days of trip, there will be no refund</span></p>
	</li>
</ul>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">&nbsp;</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">&nbsp;</span></p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">行程 Approximate Itinerary:</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">&nbsp;</span></p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Day 1</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">20:00 土城捷運第一出口集合 Meet at Tucheng MRT Station Exit 1<br />
00:00 中央飯店 Centre Hotel Kaohsiung</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">&nbsp;</span></p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Day 2</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">07:30 早餐 Breakfast</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">08:00 出發 Depart</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">09:00 東港漁港 Donggang Dock－小琉球 Liu Qiu Island</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">10:00 安潛一支 1 Shore Dive</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">11:30 中餐 Lunch</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">12:30 船潛兩支 2 Boat Dives</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">18:00 吃到飽烤肉 All you can eat BBQ Dinner</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">&nbsp;</span></p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Day 3</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">07:30 早餐Breakfast</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">08:00 船潛兩支 2 Boat Dives</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">12:30 中餐 Lunch</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">13:30 自由時間 Free Time</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">15:00 小琉球 Liu Qiu Island ─ 東港 Donggang</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">16:00 離開東港 Depart from Donggang</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">21:30 抵達台北 Arrive in Taipei</span></p>', 'Advanced Certification Recommended', NULL, NULL, '10,200 NTD', '2020-02-20 16:00:00+00', 'b718703b-b6d6-43ff-b56e-f886ed67d9c5', false, NULL, NULL, NULL, true) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('185d5385-d581-47ba-a27c-42e63eca4b78', 'East Coast PM 2BD Air', 'Transportation(if needed), Local Diving Insurance, 2 Boat Dives, 2 Tanks, Dive Guide', 'Gear Rental, Food/Drinks', NULL, '2026-04-09 08:18:04+00', '2026-04-09 08:30:39+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/cauliflower-garden/oct-02', 'Boat Diving', 'wix:image://v1/b37fef_519ef15551bd481c824f50e9b6ece493~mv2.jpg/cauliflowers.JPG#originWidth=4000&originHeight=3000', '<p class="font_8">We will be doing 2 boat dives on the East Coast of Taiwan. One will be at Cauliflower Garden, the other at the Power Plant Outflow. &nbsp;Space is limited so book early!</p>', '<p class="font_8">Come explore the East Coast with Fun Divers Tw! &nbsp;We will be trying to find dolphins and exploring two different dive sites!</p>', 'Come explore the East Coast with Fun Divers Tw!  We will be trying to find dolphins and exploring two different dive sites!', '<p class="font_8">Cauliflower Garden and Power Plant Outflow</p>
<p class="font_8"><br></p>
<p class="font_8">Come check out the Beautiful Cauliflower Garden and Power Plant Outflow with Fun Divers Tw!</p>
<p class="font_8"><br></p>
<p class="font_8">費用包含：</p>
<p class="font_8">交通，船潛兩支，潛導，潛水保險</p>
<p class="font_8">Included: Transportation, 2 Boat Dives, Dive Guide, Full Coverage Dive Insurance</p>
<p class="font_8"><br></p>
<p class="font_8">團費 Tour Price: $3,600</p>
<p class="font_8"><br></p>
<p class="font_8">額外費用 Additional:</p>
<p class="font_8"><br></p>
<p class="font_8">一天基本裝備租借 Basic Equipment Rental: $1200<br>
 全套裝備租借(含電腦錶和浮力棒)Full EquipmentRental: $1600 (includes Dive Computer and SMB)</p>
<p class="font_8">潛水錶租借 (必備) Computer Rental (required): $300</p>
<p class="font_8">浮力袋租借(必備) SMB Rental (required): $150</p>
<p class="font_8"><br></p>
<p class="font_8">＊ 請儘早匯入全額，確保您的名額</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the total As Soon As Possible to confirm your seat.</p>
<p class="font_8"><br></p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!</p>
<p class="font_8">中國信託銀行：822</p>
<p class="font_8">帳號：provided by email</p>
<p class="font_8">分行：</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the payment to:</p>
<p class="font_8">FunDivers</p>
<p class="font_8">CTBC Bank Bank code: 822</p>
<p class="font_8">Account: provided by email</p>
<p class="font_8">Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶身份證明, 潛水證, 潛水紀錄本, 防曬用品</p>
<p class="font_8">＊Remember to Bring:</p>
<p class="font_8">- ARC/ID Card (for Coast Guard)</p>
<p class="font_8">- Certification Card</p>
<p class="font_8">- Log Book</p>
<p class="font_8">- Sun Protection</p>
<p class="font_8">- Dive Computer – All divers MUST have<br>
- Surface Marker Buoy (SMB) – All divers MUST have</p>
<p class="font_8"><br></p>
<p class="font_8">*Dive Location may change due to weather conditions</p>
<p class="font_8"><br></p>
<p class="font_8">臨時取消行程之賠償金額 Cancellation Fee</p>
<p class="font_8">• 15天前取消，行程費用之25% － 25% of trip price within 15 days of the trip</p>
<p class="font_8">• 10天前取消，行程費用之50% － 50% of trip price within 10 days of the trip</p>
<p class="font_8">• 7天前取消，不予以退費 － Within 7 days of trip price, there will be no refund</p>', 'AOW Certification Required', '10:50 - Meet at Fun Divers
12:30 - Meet at Port
13:00 - Boat Departs
17:00 - Boat Returns (wash gear at port)
17:30 - Depart for Taipei', 'Oct 02', '3,600 NTD', '2022-10-01 16:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('198ca0da-41ea-4ff2-a12e-d5967a5ca574', 'East Coast AM 2BD Air', 'Transportation(if needed), Local Diving Insurance, 2 Boat Dives, 2 Tanks, Dive Guide', 'Gear Rental, Food/Drinks', NULL, '2026-04-09 08:17:22+00', '2026-04-09 08:30:32+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/cauliflower-garden/oct-02', 'Boat Diving', 'wix:image://v1/b37fef_519ef15551bd481c824f50e9b6ece493~mv2.jpg/cauliflowers.JPG#originWidth=4000&originHeight=3000', '<p class="font_8">We will be doing 2 boat dives on the East Coast of Taiwan. One will be at Cauliflower Garden, the other at the Power Plant Outflow. &nbsp;Space is limited so book early!</p>', '<p class="font_8">Come explore the East Coast with Fun Divers Tw! &nbsp;We will be trying to find dolphins and exploring two different dive sites!</p>', 'Come explore the East Coast with Fun Divers Tw!  We will be trying to find dolphins and exploring two different dive sites!', '<p class="font_8">Cauliflower Garden and Power Plant Outflow</p>
<p class="font_8"><br></p>
<p class="font_8">Come check out the Beautiful Cauliflower Garden and Power Plant Outflow with Fun Divers Tw!</p>
<p class="font_8"><br></p>
<p class="font_8">費用包含：</p>
<p class="font_8">交通，船潛兩支，潛導，潛水保險</p>
<p class="font_8">Included: Transportation, 2 Boat Dives, Dive Guide, Full Coverage Dive Insurance</p>
<p class="font_8"><br></p>
<p class="font_8">團費 Tour Price: $3,600</p>
<p class="font_8"><br></p>
<p class="font_8">額外費用 Additional:</p>
<p class="font_8"><br></p>
<p class="font_8">一天基本裝備租借 Basic Equipment Rental: $1200<br>
 全套裝備租借(含電腦錶和浮力棒)Full EquipmentRental: $1600 (includes Dive Computer and SMB)</p>
<p class="font_8">潛水錶租借 (必備) Computer Rental (required): $300</p>
<p class="font_8">浮力袋租借(必備) SMB Rental (required): $150</p>
<p class="font_8"><br></p>
<p class="font_8">＊ 請儘早匯入全額，確保您的名額</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the total As Soon As Possible to confirm your seat.</p>
<p class="font_8"><br></p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!</p>
<p class="font_8">中國信託銀行：822</p>
<p class="font_8">帳號：provided by email</p>
<p class="font_8">分行：</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the payment to:</p>
<p class="font_8">FunDivers</p>
<p class="font_8">CTBC Bank Bank code: 822</p>
<p class="font_8">Account: provided by email</p>
<p class="font_8">Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶身份證明, 潛水證, 潛水紀錄本, 防曬用品</p>
<p class="font_8">＊Remember to Bring:</p>
<p class="font_8">- ARC/ID Card (for Coast Guard)</p>
<p class="font_8">- Certification Card</p>
<p class="font_8">- Log Book</p>
<p class="font_8">- Sun Protection</p>
<p class="font_8">- Dive Computer – All divers MUST have<br>
- Surface Marker Buoy (SMB) – All divers MUST have</p>
<p class="font_8"><br></p>
<p class="font_8">*Dive Location may change due to weather conditions</p>
<p class="font_8"><br></p>
<p class="font_8">臨時取消行程之賠償金額 Cancellation Fee</p>
<p class="font_8">• 15天前取消，行程費用之25% － 25% of trip price within 15 days of the trip</p>
<p class="font_8">• 10天前取消，行程費用之50% － 50% of trip price within 10 days of the trip</p>
<p class="font_8">• 7天前取消，不予以退費 － Within 7 days of trip price, there will be no refund</p>', 'AOW Certification Required', '05:20 - Meet at Fun Divers
06:30 - Meet at Port
07:00 - Boat Departs
12:00 - Boat Returns (wash gear at port)
12:30 - Depart for Taipei', 'Oct 02', '3,600 NTD', '2022-10-01 16:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('20852f95-21ad-4b64-881e-af7b1cc90eaf', 'Penghu', NULL, NULL, NULL, '2021-01-10 12:59:48+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/penghu/jun-9-12', 'Multi-Day Fun Diving Trip', 'wix:image://v1/b37fef_9e2d13b565044a9fa4520902f6599a17~mv2.jpg/308645903_907275396923498_333093198297937161_n.jpg#originWidth=900&originHeight=600', '<p class="font_8">Fun Divers Tw is heading to the remote islands of Penghu! &nbsp;We will be doing 8 boat dives over 3 days in the amazing Nanfangsidao National Park.&nbsp;Come join us and see why this beautiful place is at the top of divers'' lists in Taiwan!</p>', '<p class="font_8">Penghu is considered a Must-See dive destination in Taiwan due to its beauty and remoteness! Space is limited, so book early to secure your spot!</p>', NULL, '<p class="font_8"><strong>跟瘋潛水去澎湖! Dive Penghu with Fun Divers Tw!</strong></p>
<p class="font_8">由於澎湖的距離與美景, 它是台灣必潛景點之一!<br>
名額有限, 請盡快報名!</p>
<p class="font_8"><br></p>
<p class="font_8">Penghu is considered a Must-See dive destination in Taiwan due to its beauty and remoteness! By far, the best diving in all of Taiwan! Space is limited, better book early to secure your spot!</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>團費Tour Price:</strong></u></p>
<p class="font_8">上下舖 Bunk Room (shared bathroom): 27,200NTD/each 台幣27,200/人<br>
上下套房 Bunk Room (Ensuite): 31,000ntd/each (Double occupancy) &nbsp;台幣31,000/人(兩人一房)</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>費用包含 Included:</strong></u></p>
<p class="font_8">潛水：3日8支船潛(含導潛)<br>
將軍島的餐點住宿上全包<br>
兩人一台機車<br>
三天潛水保險<br>
導潛小費<br>
三天GPS定位信標</p>
<p class="font_8"><br></p>
<p class="font_8">Dives: 3 Days, 8 Boat Dives (Dive Guides Included)<br>
Meals and Accommodation on Jiang Jun Island<br>
Shared Motorbike<br>
3 Days of Full Diving Insurance<br>
Divemaster Tips (1000ntd/each)<br>
3 Days Locator Beacon Rental</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>❋團費不包含Package does not include:</strong></u></p>
<p class="font_8">三天基本裝備租借 Basic Equipment Rental: $1,200 x 3 days<br>
三天全套裝備租借(含電腦錶和浮力棒) Full Equipment Rental: $1,600 x 3 days (includes Dive Computer and SMB)<br>
馬公台北來回，原則上以飛機為主(機票約 $4400)Taipei-Magong flights (approximately 4400ntd)<br>
潛水裝備超重行李費(超過10 公斤, $15/公斤) Oversize baggage surcharge for Dive Gear (15ntd/kg over 10kg)</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>行程 Approximate Itinerary:</strong></u></p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>06/09</strong></u></p>
<p class="font_8"><br></p>
<p class="font_8"><strong>06:00</strong> 松山機場集合Meet at Taipei Songshan Airport</p>
<p class="font_8"><strong>07:00</strong> 松山機場起飛Depart from Songshan Airport</p>
<p class="font_8"><strong>08:00</strong> 抵達馬公機, 搭乘計程車到碼頭Arrive at Magong Airport and Taxi to Port</p>
<p class="font_8"><strong>09:00</strong> 乘船到將軍嶼, 安排房間, 享用午餐. Ferry to Jiang Jun Island. Check into rooms and have lunch</p>
<p class="font_8">下午Afternoon: 船潛2支, 2 Boat Dives</p>
<p class="font_8">傍晚Evening: 晚餐 Dinner</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>06/10 &amp; 06/11</strong></u></p>
<p class="font_8"><br></p>
<p class="font_8">南方四島船潛, 每天各3支加3餐. 潛點依當天氣候和海況決定.<br>
Daily Itinerary will vary depending on dive conditions and dive locations. There will be 3 Dives both days in Nan Fang Si National Park as well as breakfast, lunch and dinner.</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>06/12</strong></u></p>
<p class="font_8"><br></p>
<p class="font_8"><strong>07:00</strong> 搭船回馬公Ferry back to Magong</p>
<p class="font_8"><strong>12:15</strong> 馬公機場起飛Depart Magong Airport</p>
<p class="font_8"><strong>13:10</strong> 抵達台北 Arrive in Taipei</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>＊ 保確您的名額, 請匯入訂金$15,000<br>
Please transfer $15,000 deposit to confirm your booking.</strong></p>
<p class="font_8"><br></p>
<p class="font_8">餘款需於05/20付清 The remaining balance must be paid by 05/20.</p>
<p class="font_8"><br></p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!<br>
中國信託銀行：822<br>
帳號：provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the deposit to:<br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶防曬用品、浮力袋(船潛必備) 、電腦錶(船潛必備) 、紀錄書、暈船藥、浴巾，身份證號或居留證號、潛水流鉤 (必備)</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>＊Remember to Bring:</strong></p>
<p class="font_8">- Sun Protection</p>
<p class="font_8">- Certification Card</p>
<p class="font_8">- Log Book</p>
<p class="font_8">- Seasick Pills (if necessary)</p>
<p class="font_8">- Towel</p>
<p class="font_8">- ARC No. or Passport No. / ID Card No.</p>
<p class="font_8">- Surface Marker Buoy (SMB) – (Required for boat dives)</p>
<p class="font_8">- Dive Computer (Required for boat dives)</p>
<p class="font_8">- Reef Hook (Required)</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>注意事項Notes:</strong></u></p>
<p class="font_8"><strong>- </strong>潛水員必須自行訂購松山-澎湖來回機票. 我們建議先盡快訂購松山到澎湖的航班. 在訂購機票前, 請來電跟我們確認.</p>
<p class="font_8"><strong>- </strong>在澎湖潛水,有可能遇上強大的海流和有深度的潛點, 是具有挑戰性的. 參加的潛水員需備進階執照及50支氣瓶以上</p>
<p class="font_8"><strong>- </strong>如有特殊狀況發生(如天災: 颱風, 地震)而滯留, 須追加食宿費用.</p>
<p class="font_8"><br></p>
<p class="font_8">- <strong>Divers must book their own flights to Magong from Songshan. We recommend booking the flight as soon as possible.</strong> &nbsp;Please get in touch with us before booking the flight.</p>
<p class="font_8">- The dives in Penghu are challenging with possible strong currents and deeper dive sites. All divers must be advanced certified with a minimum of 50 dives.</p>
<p class="font_8">- In the event of an overstay being required due to emergencies (typhoon, earthquake, etc.) the diver will be responsible for any additional charges incurred.</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>臨時取消行程之賠償金額 Cancellation Fee</strong></u></p>
<p class="font_8">60天前取消，行程費用之25% － 25% of Deposit within 60 days of the trip<br>
30天前取消，行程費用之50% － 50% of Deposit within 30 days of the trip<br>
21天前取消，不予以退費 － Within 21 days of trip, there will be no refund</p>', 'Advanced Certified with 50 Dives', NULL, 'Jun 9-12', 'Starting at 27,200 NTD', '2023-06-08 16:00:00+00', '1a7fefc1-dbd4-4ef8-bcc3-aff99e098558', true, NULL, NULL, NULL, true) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('210bd0d7-93e4-4951-bc99-c5f3347089dd', 'Anilao, Philippines', NULL, NULL, NULL, '2022-09-27 07:12:01+00', '2026-04-16 13:21:20+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/anilao%2C-philippines/2023-jan-24-28', 'International Dive Trip', 'wix:image://v1/b37fef_b3ac4c53be1d407d84484f9f16e7c3fc~mv2.jpg/Anilao%20Sunset.jpg#originWidth=1200&originHeight=799', '<p class="font_8">Fun Divers Tw will head to Anilao for 4 days of diving, including 12 boat dives and 2 night dives! &nbsp;Be sure to book early and get your plane tickets while they are still cheap!</p>', '<p class="font_8">Amazing macro and crystal clear waters make Anilao a great destination for divers! &nbsp;</p>', NULL, '<p class="font_8"><strong>Dive Anilao with Fun Divers Tw!</strong></p>
<p class="font_8"><br></p>
<p class="font_8">Borders are open! Let’s go to the Philippines and dive the warm waters of Anilao! Great for macro and good visibility! Book early while flights are cheap!</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>Tour Price:</strong></u></p>
<p class="font_8">Double Room: 29,800NTD/each (double occupancy)<br>
Double Room: 34,500NTD/each (single occupancy)</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>Included:</strong></u></p>
<p class="font_8">Dives: 4 Days, 12 Boat Dives, 2 night dives<br>
Meals and Accommodation in Anilao</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>Package does not include:</strong></u></p>
<p class="font_8">Basic Equipment Rental: $1,200 x 4 days<br>
Full Equipment Rental: $1,600 x 4 days (includes Dive Computer and SMB)</p>
<p class="font_8">Taipei-Manila flights (approximately 10,000ntd)</p>
<p class="font_8">Dive insurance:<br>
(Contact us for recommendation)</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>Approximate Itinerary:</strong></u></p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>01/24</strong></u></p>
<p class="font_8"><strong>01:40</strong>Depart from Taoyuan Airport</p>
<p class="font_8"><strong>04:00</strong>Arrive at Manila Airport and Taxi to Resort</p>
<p class="font_8"><strong>06:00</strong>Arrive at Resort</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>01/24, 27</strong></u></p>
<p class="font_8">Breakfast</p>
<p class="font_8">2 Boat Dives</p>
<p class="font_8">Lunch</p>
<p class="font_8">1 Boat Dives</p>
<p class="font_8">Evening: Dinner</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>01/25, 26</strong></u></p>
<p class="font_8">Diving will follow the same day schedule and may vary depending on dive conditions for the night dives on the 24thand 25th.</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>01/28</strong></u></p>
<p class="font_8"><strong>16:00</strong>Taxi to Manila Airport</p>
<p class="font_8"><strong>23:05</strong> Depart Manila Airport</p>
<p class="font_8"><strong>01:15</strong>Arrive in Taipei</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Please transfer $15,000 deposit to confirm your booking.</strong></p>
<p class="font_8">The remaining balance must be paid by 01/01.</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the deposit to:<br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>＊Remember to Bring:</strong></p>
<p class="font_8">- Sun Protection</p>
<p class="font_8">- Certification Card</p>
<p class="font_8">- Log Book</p>
<p class="font_8">- Seasick Pills (if necessary)</p>
<p class="font_8">- ARC No. or Passport No. / ID Card No.</p>
<p class="font_8">- Surface Marker Buoy (SMB) – (Required for boat dives)</p>
<p class="font_8">- Dive Computer (Required for boat dives)</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>Notes:</strong></u></p>
<p class="font_8">Divers must book their own flights to Manila from Taipei. We recommend booking the flight as soon as possible. Please get in touch with us before booking the flight.</p>
<p class="font_8">In the event of an overstay being required due to emergencies (typhoon, earthquake, etc.) the diver will be responsible for any additional charges incurred.</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>臨時取消行程之賠償金額 Cancellation Fee</strong></u></p>
<p class="font_8">60天前取消，行程費用之25% － 25% of Deposit within 60 days of the trip<br>
30天前取消，行程費用之50% － 50% of Deposit within 30 days of the trip<br>
21天前取消，不予以退費 － Within 21 days of trip, there will be no refund</p>', 'AOW Certification Required', NULL, '2023 Jan 24-28', 'Starting at 29,800ntd', '2023-01-24 04:00:00+00', NULL, false, NULL, NULL, NULL, true) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('2e2034e6-977a-4267-8b8e-07768f458aba', 'Fun Divers Dive Center', NULL, NULL, NULL, '2019-06-18 05:55:39+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/fun-divers-dive-center/sep-9%2C-10%2C-11', 'PADI Open Water Course', 'wix:image://v1/b37fef_b22c67c4e51440c1929b2292262e7b15~mv2.jpg/20170514-IMG_3567.jpg#originWidth=1600&originHeight=1067', '<p class="font_8">The PADI Open Water Course is the first step in your underwater journey!&nbsp; Learn how to use Scuba Diving Equipment, how to handle yourself underwater, and how to fully enjoy your time underwater.&nbsp; Let Fun Divers TW introduce you to the amazing world of Scuba Diving in Taiwan (and the world)!</p>', '<p class="font_8">Start your underwater adventure by getting your PADI Open Water Certification! Fun Divers Tw is starting an Open Water Course and&nbsp;there are still a couple spots available!</p>', NULL, '<p class="font_8">Do you want to learn to Scuba Dive?! Now is your chance! Fun Divers Tw is starting a PADI Open Water Course for July! &nbsp;This course will be a PADI E-Learning Course so the academic portion will all be done on your own and we will meet for the Pool and Ocean sessions. See the schedule below.<br>
 <br>
 <strong>Price</strong> ：14,600ntd</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Get a discount if you sign up with a friend!</strong></p>
<p class="font_8"><br></p>
<p class="font_8">Price includes E-Learning, transportation, and gear rental. Due to Covid concerns, students will need to purchase their own Mask and Snorkel for use during the course. There is a selection to choose from at Fun Divers Tw.<br>
 <br>
 今年夏天來成為合格的PADI潛水員吧！<br>
 Learn Scuba Diving with Fun Divers Tw!<br>
 The Way Diving Should Be Taught<br>
 <br>
 Fun Divers 課程已完全更新，符合PADI教學課程之規定。為了能夠更安全的享受潛水活動，請跟我們一起學習安全且符合規定的潛水新知吧！<br>
 <br>
 <strong>09 Sep: 8:30am-4pm </strong><br>
 先上泳池 ，下午回來Fun Divers潛水教室考試<br>
 Knowledge Check and Pool lessons<br>
 Bring your swimsuit, towel and a snack<br>
 <br>
 <strong>10 &amp; 11 Sep: 8:30am-4pm</strong></p>
<p class="font_8">Open Water Dives</p>
<p class="font_8">Bring your swimsuit, towel, snacks, water and logbook</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer a 5000ntd deposit to confirm your spot in the class. Notify Fun Divers Tw when the transfer is complete.<br>
 <br>
Please transfer payments to: <br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
Branch: provided by email<br>
 <br>
 ＊戶外課程將視天氣狀況作調整</p>
<p class="font_8">Find out more information about the Open Water Course on our <a href="https://www.fundiverstw.com/courses-1/padi-open-water-course">website</a>!</p>', 'None', NULL, 'Sep 9, 10, 11', '14,600 NTD', '2022-09-08 16:00:00+00', NULL, true, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('351fc2b9-8e9f-4d67-8c3f-69b88a4b2691', 'East Coast PM 2BD EANx', 'Transportation(if needed), Local Diving Insurance, 2 Boat Dives, 2 Nitrox Tanks, Dive Guide', 'Gear Rental, Food/Drinks', NULL, '2026-04-09 08:18:00+00', '2026-04-09 08:30:24+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/cauliflower-garden/oct-02', 'Boat Diving', 'wix:image://v1/b37fef_519ef15551bd481c824f50e9b6ece493~mv2.jpg/cauliflowers.JPG#originWidth=4000&originHeight=3000', '<p class="font_8">We will be doing 2 boat dives on the East Coast of Taiwan. One will be at Cauliflower Garden, the other at the Power Plant Outflow. &nbsp;Space is limited so book early!</p>', '<p class="font_8">Come explore the East Coast with Fun Divers Tw! &nbsp;We will be trying to find dolphins and exploring two different dive sites!</p>', 'Come explore the East Coast with Fun Divers Tw!  We will be trying to find dolphins and exploring two different dive sites!', '<p class="font_8">Cauliflower Garden and Power Plant Outflow</p>
<p class="font_8"><br></p>
<p class="font_8">Come check out the Beautiful Cauliflower Garden and Power Plant Outflow with Fun Divers Tw!</p>
<p class="font_8"><br></p>
<p class="font_8">費用包含：</p>
<p class="font_8">交通，船潛兩支，潛導，潛水保險</p>
<p class="font_8">Included: Transportation, 2 Boat Dives, Dive Guide, Full Coverage Dive Insurance</p>
<p class="font_8"><br></p>
<p class="font_8">團費 Tour Price: $3,600</p>
<p class="font_8"><br></p>
<p class="font_8">額外費用 Additional:</p>
<p class="font_8"><br></p>
<p class="font_8">一天基本裝備租借 Basic Equipment Rental: $1200<br>
 全套裝備租借(含電腦錶和浮力棒)Full EquipmentRental: $1600 (includes Dive Computer and SMB)</p>
<p class="font_8">潛水錶租借 (必備) Computer Rental (required): $300</p>
<p class="font_8">浮力袋租借(必備) SMB Rental (required): $150</p>
<p class="font_8"><br></p>
<p class="font_8">＊ 請儘早匯入全額，確保您的名額</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the total As Soon As Possible to confirm your seat.</p>
<p class="font_8"><br></p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!</p>
<p class="font_8">中國信託銀行：822</p>
<p class="font_8">帳號：provided by email</p>
<p class="font_8">分行：</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the payment to:</p>
<p class="font_8">FunDivers</p>
<p class="font_8">CTBC Bank Bank code: 822</p>
<p class="font_8">Account: provided by email</p>
<p class="font_8">Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶身份證明, 潛水證, 潛水紀錄本, 防曬用品</p>
<p class="font_8">＊Remember to Bring:</p>
<p class="font_8">- ARC/ID Card (for Coast Guard)</p>
<p class="font_8">- Certification Card</p>
<p class="font_8">- Log Book</p>
<p class="font_8">- Sun Protection</p>
<p class="font_8">- Dive Computer – All divers MUST have<br>
- Surface Marker Buoy (SMB) – All divers MUST have</p>
<p class="font_8"><br></p>
<p class="font_8">*Dive Location may change due to weather conditions</p>
<p class="font_8"><br></p>
<p class="font_8">臨時取消行程之賠償金額 Cancellation Fee</p>
<p class="font_8">• 15天前取消，行程費用之25% － 25% of trip price within 15 days of the trip</p>
<p class="font_8">• 10天前取消，行程費用之50% － 50% of trip price within 10 days of the trip</p>
<p class="font_8">• 7天前取消，不予以退費 － Within 7 days of trip price, there will be no refund</p>', 'AOW & Nitrox Certification Required', '10:50 - Meet at Fun Divers
12:30 - Meet at Port
13:00 - Boat Departs
17:00 - Boat Returns (wash gear at port)
17:30 - Depart for Taipei', 'Oct 02', '3,600 NTD', '2022-10-01 16:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('357315e2-bef0-4849-b432-569d19849863', 'Lambai Island', 'Return Ferry Tickets, 2 Nights Shared Rooms, 2 Breakfasts, 2 Lunches, 1 Dinner, 2 Days Shared Motorbike, 4 Boat Dives, 2 Days Full Coverage Local Diving Insurance.', NULL, NULL, '2020-12-04 08:31:54+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/lambai-island/mar-10-12', 'Multi-Day Fun Diving Trip', 'wix:image://v1/b37fef_e363b181077c4aaabc4431c0988d85db~mv2.jpg/PC190353.JPG#originWidth=4000&originHeight=3000', '<p class="font_8">A weekend trip to Lambai Island to enjoy some time away from the city!&nbsp; We will be diving with sea turtles, exploring wrecks, and having BBQ in the evening!&nbsp; Come join us on this wonderful trip and see why divers love Xiao Liuqiu!</p>', '<p class="font_8">Visit this&nbsp;beautiful coral Island off the coast of Kaohsiung. Turtles galore!&nbsp; Come explore this gem with Fun Divers Tw!</p>', 'A weekend trip to Lambai Island to enjoy some time away from the city!  We will be diving with sea turtles, exploring wrecks, and having BBQ in the evening!  Come join us on this wonderful trip and see why divers love Xiao Liuqiu!', '<p class="font_8">小琉球 小琉球 Beautiful Lambai</p>
<p class="font_8">A weekend trip to Lambai Island to enjoy some time away from the city! &nbsp;We will be diving with sea turtles, exploring wrecks, and having BBQ in the evening! &nbsp;Come join us on this wonderful trip and see why divers love Xiao Liuqiu!</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>費用包含：</strong></p>
<p class="font_8">往返東港船票， 兩晚上住宿 ，早餐 x 2，午餐 x 2，晚餐 x 1，機車(兩人一台)，船潛四支， 潛水險。</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Included:</strong></p>
<p class="font_8">Return Ferry, 2 Nights Shared Rooms, 2 Breakfasts, 2 Lunches, 1 Dinner, 2 Days Shared Motorbike, 4 Boat Dives, 2 Days Full Diving Insurance.</p>
<p class="font_8">＊額外之餐費與娛樂費用請自理</p>
<p class="font_8">Additional Food, Drinks &amp; Entertainment are NOT included</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>團費 Tour Price:</strong></p>
<p class="font_8">背包房 Bunk Room: $11,800</p>
<p class="font_8">雙人房 Basic Double Room: $13,500 (double occupancy)</p>
<p class="font_8"><br></p>
<p class="font_8">歡迎非潛水員參加 Non-Divers are also welcome to join $6,400 (bunk room)</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>額外費用Additional:</strong></p>
<p class="font_8">兩天裝備租借 Basic Equipment Rental: $1,200 x 2 days</p>
<p class="font_8">全套裝備租借(含電腦錶和浮力棒) Full Equipment Rental: $1,600 x 2 days</p>
<p class="font_8">(includes Dive Computer and SMB)</p>
<p class="font_8">Optional Night Dive: $800</p>
<p class="font_8">Light Rental: $200</p>
<p class="font_8">台北東港來回交通費 Return Transport: $1,400</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>課程Courses:</strong></p>
<p class="font_8">高氧課程 Enriched Air Nitrox Specialty $6,000 (原價 Normal Price $6,800)</p>
<p class="font_8">深潛課程 Deep Dive Specialty $5,200 (原價 Normal Price $6,200)</p>
<p class="font_8">進階課程 Advanced Open Water $11,000 (原價 Normal Price $12,200)<br>
初級課程 Open Water Course $11,600 (Normally $14,600)</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>行程Approximate Itinerary:</strong></u></p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Day 1</strong></p>
<p class="font_8">16:00 離開台北Depart Fun Divers Dive Center (earlier if possible)<br>
20:00飯店Hotel Kaohsiung</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Day 2</strong></p>
<p class="font_8">07:30 早餐 Breakfast</p>
<p class="font_8">08:00 出發 Depart</p>
<p class="font_8">09:00 東港漁港 Donggang Dock－小琉球 Liu Qiu Island</p>
<p class="font_8">10:00 安潛一支 1 Shore Dive</p>
<p class="font_8">11:30 中餐 Lunch</p>
<p class="font_8">12:30 船潛兩支 2 Boat Dives</p>
<p class="font_8">18:00 吃到飽烤肉 All you can eat BBQ Dinner</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Day 3</strong></p>
<p class="font_8">07:30 早餐Breakfast</p>
<p class="font_8">08:00 船潛兩支 2 Boat Dives</p>
<p class="font_8">12:30 中餐 Lunch</p>
<p class="font_8">14:30 小琉球 Liu Qiu Island ─ 東港 Donggang</p>
<p class="font_8">15:30 離開東港 Depart from Donggang</p>
<p class="font_8">21:30 抵達台北 Arrive in Taipei</p>
<p class="font_8"><br></p>
<p class="font_8">＊ 請於匯入訂金 $8,000 Please transfer $8,000 deposit to confirm your booking.</p>
<p class="font_8">餘款需於02/20 付清 The remaining balance must be paid by 02/20.</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Please transfer the deposit to:</strong></p>
<p class="font_8">FunDivers CTBC Bank</p>
<p class="font_8">Bank code: 822</p>
<p class="font_8">Account: provided by email</p>
<p class="font_8">Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!</p>
<p class="font_8">中國信託銀⾏：822</p>
<p class="font_8">帳號：provided by email</p>
<p class="font_8">分⾏：</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>＊記得攜帶 Remember to Bring</strong>:<br>
- 證照卡 Certification Card<br>
- 潛水日誌 Log Book<br>
- 電腦表 Dive Computer(required) (rental 300/day)<br>
- 浮力棒 (SMB) Surface Marker Buoy(required) (rental 150/day)<br>
- 暈船藥 Seasick Pills<br>
- 防賽 Sun Protection</p>
<p class="font_8">- 大毛巾Towel</p>
<p class="font_8">- 薄夾克Jacket</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>臨時取消行程之賠償金額 Cancellation Fee</strong></u></p>
<p class="font_8">· 14天前取消，行程費用之25% － 25% of Deposit within 14 days of the trip</p>
<p class="font_8">· 10天前取消，行程費用之50% － 50% of Deposit within 10 days of the trip</p>
<p class="font_8">· 07天前取消，不予以退費 － Within 7 days of trip, there will be no refund</p>', 'Advanced Certification Recommended', NULL, 'Mar 10-12', 'Starting at 11,800 NTD', '2023-03-09 16:00:00+00', 'b718703b-b6d6-43ff-b56e-f886ed67d9c5', false, NULL, NULL, NULL, true) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('3b66dea5-6f23-42ea-be72-c159a426ebe3', 'Wan An Jian Wreck Diving', NULL, NULL, NULL, '2022-06-17 04:36:40+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/wan-an-jian-wreck-diving/aug-27', 'Boat Diving', 'wix:image://v1/b37fef_cefb9d928f144074ae7a99e0ab13b95f~mv2.jpg/Wan%20An%20Jian%20Wreck.jpg#originWidth=900&originHeight=508', '<p class="font_8">We will be doing 2 boat dives on the massive Wan An Jian Wreck. &nbsp;Space is limited so book early!</p>', '<p class="font_8">Come explore the East Coast with Fun Divers Tw! &nbsp;We will be trying to find dolphins and exploring a wreck!</p>', NULL, '<p class="font_8">Wan An Jian Wreck Dives</p>
<p class="font_8"><br></p>
<p class="font_8">Come check out the massive Wan An Jian Military Wreck with Fun Divers Tw! We will be doing 2 dives on the wreck to explore it fully.</p>
<p class="font_8"><br></p>
<p class="font_8">費用包含：</p>
<p class="font_8">交通，船潛兩支高氧，潛導，潛水保險</p>
<p class="font_8">Included: Transportation, 2 Boat Dives with Nitrox, Dive Guide, Full Coverage Dive Insurance</p>
<p class="font_8"><br></p>
<p class="font_8">團費 Tour Price: $3,600</p>
<p class="font_8"><br></p>
<p class="font_8">額外費用 Additional:</p>
<p class="font_8">一天基本裝備租借 Basic Equipment Rental: $1200<br>
全套裝備租借(含電腦錶和浮力棒)Full EquipmentRental: $1600 (includes Dive Computer and SMB)</p>
<p class="font_8">潛水錶租借 (必備) Computer Rental (required): $300</p>
<p class="font_8">浮力袋租借(必備) SMB Rental (required): $150</p>
<p class="font_8"><br></p>
<p class="font_8">課程Courses:</p>
<p class="font_8">高氧課程 $5,600 (原價$6,600) -- Enriched Air Nitrox Specialty $5,600 (Normal $6,600)</p>
<p class="font_8"><br></p>
<p class="font_8">＊ 請儘早匯入全額，確保您的名額</p>
<p class="font_8">Please transfer the total As Soon As Possible to confirm your seat.</p>
<p class="font_8"><br></p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!</p>
<p class="font_8">中國信託銀行：822</p>
<p class="font_8">帳號：provided by email</p>
<p class="font_8">分行：</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the payment to:</p>
<p class="font_8">FunDivers</p>
<p class="font_8">CTBC Bank Bank code: 822</p>
<p class="font_8">Account: provided by email</p>
<p class="font_8">Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶身份證明, 潛水證, 潛水紀錄本, 防曬用品</p>
<p class="font_8">＊Remember to Bring:</p>
<p class="font_8"><br></p>
<p class="font_8">- ARC/ID Card (for Coast Guard)</p>
<p class="font_8">- Certification Card</p>
<p class="font_8">- Log Book</p>
<p class="font_8">- Sun Protection</p>
<p class="font_8">- Dive Computer – All divers MUST have<br>
- Surface Marker Buoy (SMB) – All divers MUST have</p>
<p class="font_8"><br></p>
<p class="font_8">*Dive Location may change due to weather conditions</p>
<p class="font_8"><br></p>
<p class="font_8">臨時取消行程之賠償金額 Cancellation Fee</p>
<p class="font_8">• 15天前取消，行程費用之25% － 25% of trip price within 15 days of the trip</p>
<p class="font_8">• 10天前取消，行程費用之50% － 50% of trip price within 10 days of the trip</p>
<p class="font_8">• 7天前取消，不予以退費 － Within 7 days of trip price, there will be no refund</p>', 'Advanced Certified', NULL, 'Aug 27', '3,600 NTD', '2022-08-26 16:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('421492ca-ef89-4102-ba6b-01c9d068732e', 'Fun Divers Dive Center', NULL, NULL, NULL, '2019-11-05 08:46:35+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'PADI EFR Course', 'wix:image://v1/b37fef_3970088889d24834a7ab01a1fca962b6~mv2.jpg/EFR_print_05(1).jpg#originWidth=1200&originHeight=900', '<p class="p1"><span style="font-family:corben,serif">In the <span style="text-decoration:underline"><a href="https://www.fundiverstw.com/Courses/PADI-EFR-Course">PADI EFR Course</a></span>, you will learn how to administer basic first aid as well as how to perform CPR properly.&nbsp; You will also be taught how to use an Automated External Defibrillator (AED).&nbsp; The PADI EFR Course is the equivalent of the Red Cross First Aid Certification and is recognized worldwide.</span></p>', '<p class="p1"><span style="font-family:corben,serif">Discover simple to follow steps for emergency care. This course focuses on building confidence in lay rescuers and increasing their willingness to respond when faced with a medical emergency in a non-stressful learning environment.&nbsp; You don&#39;t have to be a diver to take this course.</span></p>', NULL, '<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Do you know what to do if someone is injured or not breathing?&nbsp; Learn how to perform CPR and handle emergency situations confidently!&nbsp; Take the PADI Emergency First Responder (EFR) Course with Fun Divers Tw and learn from a former EMT!</span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">In the PADI EFR Course, you will learn how to administer basic first aid as well as how to perform CPR properly.&nbsp; You will also be taught how to use an Automated External Defibrillator (AED).&nbsp; The PADI EFR Course is the equivalent of the Red Cross First Aid Certification and is recognized worldwide.</span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Course Price:&nbsp; 4800 NTD for the course +1800 for the book</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif"><span class="wixGuard">​</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; Get a discount if you sign up with a friend!</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif"><span class="wixGuard">​</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">4500 NTD/Each for 2</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">4200 NTD/Each for 3</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">4000 NTD/Each for 4+</span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Upcoming Course Schedule:&nbsp;&nbsp; Classes are from 9am &ndash; 3pm</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">November 9th</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">November 23rd</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">December 14th</span></p>

<p class="p1"><br />
<span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Please transfer the total amount to confirm your spot in the class.&nbsp; Notify Fun Divers Tw when the transfer is complete.<br />
<br />
Please transfer payments to:<br />
FunDivers<br />
CTBC Bank<br />
Bank code: 822<br />
Account: provided by email</span></p>', 'Open to all (divers and non-divers welcome)', NULL, NULL, '4,800 NTD', '2019-11-22 18:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('42f2ba4a-0b9f-4ef5-a9f3-e0e6c8e508d5', 'RR + Shore 2B1S', 'Transportation(if needed), Local Diving Insurance, 2 Boat Dives, 1 Shore Dive, 2 Nitrox Tanks, 1 Air Tank, Dive Guide', 'Gear Rental, Food/Drinks', NULL, '2021-03-26 04:13:40+00', '2026-04-09 08:28:44+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/keelung-island-boat-diving/jun-19', 'Local Boat Diving', 'wix:image://v1/b37fef_1410542b4f30466c937394e6e934efb3~mv2.jpg/Moray%20small%20LDB%204.jpg#originWidth=4026&originHeight=3008', '<p class="font_8">Fun Divers Tw is heading out to Rainbow Reef, near Keelung Island to do some boat diving!&nbsp; Come explore some of the amazing off-shore dive sites with us and see why we love boat diving so much.&nbsp; We will be doing 2 boat dives.</p>', '<p class="font_8">Visit Rainbow Reef in the morning and then Batcave in the afternoon. &nbsp;We will do 2 boat dives and 1 shore dive!</p>', 'Visit Rainbow Reef in the morning and then Batcave in the afternoon.  We will do 2 boat dives and 1 shore dive!', '<p class="font_8">Come Boat Diving with Fun Divers as we return to Keelung Island for some Fun in the Sun!</p>
<p class="font_8"><br></p>
<p class="font_8">費用包含：</p>
<p class="font_8">交通，船潛兩支高氧，潛導，潛水保險</p>
<p class="font_8"><br></p>
<p class="font_8">Included: Transportation, 2 Boat Dives with Nitrox, Dive Guide, Full Coverage Dive Insurance</p>
<p class="font_8"><br></p>
<p class="font_8">團費 Tour Price: $3,200</p>
<p class="font_8"><br></p>
<p class="font_8">課程Courses:</p>
<p class="font_8">高氧課程 $5,600 (原價 $6,600) -- Enriched Air Nitrox Specialty $5,600 (Normal $6,600)</p>
<p class="font_8"><br></p>
<p class="font_8">額外費用 Additional:</p>
<p class="font_8">一天基本裝備租借 Basic Equipment Rental: $1200</p>
<p class="font_8">潛水錶租借 (必備) Computer Rental (required): $300</p>
<p class="font_8">浮力袋租借(必備) SMB Rental (required): $150</p>
<p class="font_8"><br></p>
<p class="font_8">＊ 請儘早匯入全額，確保您的名額</p>
<p class="font_8">Please transfer the total As Soon As Possible to confirm your seat.</p>
<p class="font_8"><br></p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!</p>
<p class="font_8">中國信託銀行：822</p>
<p class="font_8">帳號：provided by email</p>
<p class="font_8">分行：</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the payment to:</p>
<p class="font_8">FunDivers</p>
<p class="font_8">CTBC Bank Bank code: 822</p>
<p class="font_8">Account: provided by email</p>
<p class="font_8">Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶身份證明, 潛水證, 潛水紀錄本, 防曬用品 ＊Remember to Bring:</p>
<p class="font_8">- ARC/ID Card (for Coast Guard) - Certification Card - Log Book - Sun Protection</p>
<p class="font_8">*Dive Location may change due to weather conditions</p>
<p class="font_8"><br></p>
<p class="font_8">臨時取消行程之賠償金額 Cancellation Fee</p>
<p class="font_8">• 10天前取消，行程費用之25% － 25% of trip price within 10 days of the trip</p>
<p class="font_8">• 7天前取消，行程費用之50% － 50% of trip price within 7 days of the trip</p>
<p class="font_8">• 5天前取消，不予以退費 － Within 5 days of trip, there will be no refund</p>', 'AOW & Nitrox Certification Required', '06:15 - Meet at Fun Divers
07:30 - Meet at Port
08:00 - Boat Departs
12:00 - Boat Returns 
12:30 - Drive to Batcave
14:30 - Wash Gear
15:00 - Return to Taipei', 'Jun 19', '3,200 NTD', '2022-06-18 20:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('5568aec5-6839-4c55-9d8f-626675b72927', 'Keelung Island Boat Diving', NULL, NULL, NULL, '2022-06-17 03:16:06+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/keelung-island-boat-diving/aug-7', 'Local Boat Diving', 'wix:image://v1/b37fef_83c8811ad4c54cd1ac251c0ca16e0bdf~mv2_d_4026_3008_s_4_2.jpg/Sea%20Fan%20and%20Soft%20Coral.jpg#originWidth=4026&originHeight=3008', '<p class="font_8">Fun Divers Tw is heading out to Rainbow Reef, near Keelung Island to do some boat diving!&nbsp; Come explore some of the amazing off-shore dive sites with us and see why we love boat diving so much.&nbsp; We will be doing 2 boat dives.</p>', '<p class="font_8">Explore some of the local dive sites not reachable from shore! We will explore Rainbow Reef, an underwater pinnacle with abundant sea life!</p>', NULL, '<p class="font_8">Come Boat Diving with Fun Divers as we return to Keelung Island for some Fun in the Sun!</p>
<p class="font_8"><br></p>
<p class="font_8">費用包含：</p>
<p class="font_8">交通，船潛兩支高氧，潛導，潛水保險</p>
<p class="font_8"><br></p>
<p class="font_8">Included: Transportation, 2 Boat Dives with Nitrox, Dive Guide, Full Coverage Dive Insurance</p>
<p class="font_8"><br></p>
<p class="font_8">團費 Tour Price: $3,200</p>
<p class="font_8"><br></p>
<p class="font_8">課程Courses:</p>
<p class="font_8">高氧課程 $5,600 (原價 $6,600) -- Enriched Air Nitrox Specialty $5,600 (Normal $6,600)</p>
<p class="font_8">進階課程 Advanced Open Water $11,000 (原價 Normal Price $12,200)</p>
<p class="font_8"><br></p>
<p class="font_8">額外費用 Additional:</p>
<p class="font_8">一天基本裝備租借 Basic Equipment Rental: $1200</p>
<p class="font_8">全套裝備租借(含電腦錶和浮力棒)Full EquipmentRental: $1600 (includes Dive Computer and SMB)</p>
<p class="font_8">潛水錶租借 (必備) Computer Rental (required): $300</p>
<p class="font_8">浮力袋租借(必備) SMB Rental (required): $150</p>
<p class="font_8"><br></p>
<p class="font_8">＊ 請儘早匯入全額，確保您的名額</p>
<p class="font_8">Please transfer the total As Soon As Possible to confirm your seat.</p>
<p class="font_8"><br></p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!</p>
<p class="font_8">中國信託銀行：822</p>
<p class="font_8">帳號：provided by email</p>
<p class="font_8">分行：</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the payment to:</p>
<p class="font_8">FunDivers</p>
<p class="font_8">CTBC Bank Bank code: 822</p>
<p class="font_8">Account: provided by email</p>
<p class="font_8">Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶身份證明, 潛水證, 潛水紀錄本, 防曬用品 ＊Remember to Bring:</p>
<p class="font_8">- ARC/ID Card (for Coast Guard) - Certification Card - Log Book - Sun Protection</p>
<p class="font_8">*Dive Location may change due to weather conditions</p>
<p class="font_8"><br></p>
<p class="font_8">臨時取消行程之賠償金額 Cancellation Fee</p>
<p class="font_8">• 10天前取消，行程費用之25% － 25% of trip price within 10 days of the trip</p>
<p class="font_8">• 7天前取消，行程費用之50% － 50% of trip price within 7 days of the trip</p>
<p class="font_8">• 5天前取消，不予以退費 － Within 5 days of trip, there will be no refund</p>', 'Advanced and Nitrox Certification Required', NULL, 'Aug 7', '3,200 NTD', '2022-08-06 20:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('5c7687aa-1f95-4124-9eba-50692ed29764', 'Badouzi PM 2 BD EANx', 'Transportation(if needed), Local Diving Insurance, 2 Boat Dives, 2 Nitrox Tanks, Dive Guide', 'Gear Rental, Food/Drinks', NULL, '2019-07-25 11:17:05+00', '2026-04-09 08:35:18+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'Local Boat Diving', 'wix:image://v1/b37fef_6929f50c76a34b16893242611734139e~mv2_d_4000_3000_s_4_2.jpg/david%20entry.JPG#originWidth=4000&originHeight=3000', '<p class="p1"><span style="font-family:corben,serif">Fun Divers Tw is heading out to Badouzi Harbor to do some boat diving!&nbsp; Come Explore some of the amazing off-shore dive sites with us and see why we love diving there so much.&nbsp; We will be doing 2 boat dives at 2 different sites.</span></p>', '<p class="p1"><span style="font-family:corben,serif">Explore some of the local dive sites not reachable from shore! See wrecks, artificial reefs and natural reefs with abundant sea life!</span></p>', 'Explore some of the local dive sites not reachable from shore! See wrecks, artificial reefs and natural reefs with abundant sea life!', '<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">厭倦了岸潛需要背上背下裝備嗎？來參加我們的八斗子船潛行程吧~<br />
Tired of the heavy lifting on shore dives?<br />
Come explore the outer reaches of Badouzi Bay by Boat<br />
<br />
費用包含：<br />
交通，保險 ，船潛兩支， 兩支氣瓶，潛導<br />
Included: Transport, Travel Insurance, 2 Boat Dives, 2 Tanks, Dive Guide<br />
<br />
<span style="font-weight:bold">團費 Tour Price:</span> $3,200<br />
<br />
<span style="font-weight:bold">額外費用 Additional:</span><br />
一天裝備租借 Full Equipment Rental: $1000<br />
<br />
＊請儘早匯入全額費用以確保您的名額<br />
Please transfer the total amount As Soon As Possible to confirm your seat.</span><br />
<br />
<span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Please transfer the deposit to:<br />
FunDivers<br />
CTBC Bank<br />
Bank code: 822<br />
Account: provided by email<br />
<br />
<span style="font-weight:bold">＊記得攜帶防曬用品,浮力袋(船潛必備),電腦表<br />
＊Remember to Bring:</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">-ID Card (or passport)(for Coast Guard)<br />
- Certification Card<br />
- Log Book<br />
- Surface Marker Buoy (SMB) &ndash; All divers MUST have<br />
<br />
臨時取消行程之賠償金額 Cancellation Fee<br />
&bull; 10天前取消，行程費用之25% － 25% of trip price within 10 days of the trip<br />
&bull; 7天前取消，行程費用之50% － 50% of trip price within 7 days of the trip<br />
&bull; 5天前取消，不予以退費 － Within 5 days of trip price, there will be no refund</span></p>', 'AOW & Nitrox Certification Required', '10:45 - Meet at Fun Divers
12:00 - Meet at Port
12:30 - Boat Departs
17:00 - Boat Returns (wash gear at port)
17:30 - Depart for Taipei', NULL, '3,200 NTD', '2019-10-04 20:00:00+00', NULL, false, NULL, 'f6055090-f3af-4b49-b784-c4971a7d2c5a', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('66862864-3e6c-4bd3-a84f-f307502b5cc5', '7 Star/Kenting', '5 Boat Dives (2 Air, 3 Nitrox)
Bunkroom Accommodation (2 nights) + 2 breakfasts + 1 dinner + 2 lunches + full coverage local diving insurance + diving guide fee', 'Additional Food, Drinks & Entertainment are NOT included', 'You can meet us in Kenting, traveling by Train&Bus, or driving yourself.
Round Trip Transportation with Fun Divers Taiwan: 1800ntd', '2026-01-16 07:14:40+00', '2026-04-16 13:21:30+00', '9f20fab4-5faf-4978-94de-a146afe4af9d', NULL, 'Multi-Day Fun Diving Trip', 'wix:image://v1/b37fef_a4be3af87a29488185d944aee75ffda9~mv2.jpg/P2080453-Giant%20Trevally-Similan-Surin%20Islands.jpg#originWidth=3684&originHeight=2078', NULL, '<p class="font_8">Have the chance to see Rays, Trevallies, and Giant Barracudas at Seven Stars Reef!</p>', 'Have the chance to see Rays, Trevallies, and Giant Barracudas at Seven Stars Reef!', '<h6 class="font_6">Trip Overview:</h6>
<p class="font_8">You have a chance to see some big pelagics, such as schools of Jackfish, surrounding you. If you are lucky, you can also encounter large tuna/nurse sharks/whale sharks/hammerhead sharks/manta rays/eagle rays/white tip reef sharks. The water temperature at 7 Stars will likely be 24-26C.</p>
<p class="font_8"><br></p>
<h6 class="font_6">Fun Divers Pickup: &nbsp;(Limited seating)</h6>
<p class="font_8">If you are going to Kenting by yourself, please meet at <a href="https://maps.app.goo.gl/LAaznA8gqUZgcmnu7"><u>M</u></a><u>ario''s Dive Center</u></p>
<p class="font_8"><br></p>
<p class="font_8">* Transportation is at your own expense</p>
<p class="font_8">Boat Return Time on Day 3 approximately 12pm in Kenting</p>
<p class="font_7"><br></p>
<h6 class="font_6">Price:</h6>
<p class="font_8">Bunk room (4~6 people shared room) - 12,900ntd</p>
<p class="font_8">Double bed ensuite (2 people occupancy) - 14,600ntd</p>
<p class="font_8"><br></p>
<h6 class="font_6">Included:</h6>
<p class="font_8">Saturday: 3 boat dives at 7 Stars (3 nitrox tanks)</p>
<p class="font_8">Sunday: 2 boat dives in Kenting (2 Air tanks)</p>
<p class="font_8">Accommodation (2 nights) + 2 breakfasts + 1 dinner + 2 lunches + full coverage diving insurance + diving guide fee</p>
<p class="font_8"><br></p>
<h6 class="font_6">Not included:</h6>
<p class="font_8">Round Trip Transportation with us: 1800ntd</p>
<p class="font_8"><br></p>
<p class="font_8">＊額外之餐費與娛樂費用請自理</p>
<p class="font_8">＊Additional Food, Drinks &amp; Entertainment are NOT included</p>
<p class="font_8"><br></p>
<h6 class="font_6">Payment:</h6>
<p class="font_8">＊ 保確您的名額, 請匯入訂金$8,000</p>
<p class="font_8">Please transfer $8,000 deposit to confirm your booking.</p>
<p class="font_8"><br></p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!</p>
<p class="font_8">中國信託銀行：822</p>
<p class="font_8">帳號：provided by email</p>
<p class="font_8">Please transfer the deposit to:</p>
<p class="font_8">FunDivers</p>
<p class="font_8">CTBC Bank</p>
<p class="font_8">Bank code: 822</p>
<p class="font_8">Account: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶 Remember to Bring:</p>
<p class="font_8">- 證照卡 Certification Card</p>
<p class="font_8">- 潛水日誌 Log Book</p>
<p class="font_8">- 電腦表 Dive Computer</p>
<p class="font_8">- 浮力棒 (SMB) Surface Marker Buoy</p>
<p class="font_8">- 暈船藥 Seasick Pills</p>
<p class="font_8">- 防賽 Sun Protection</p>
<p class="font_8"><br></p>
<p class="font_8">臨時取消行程之賠償金額 Cancellation Fee</p>
<p class="font_8">· 14天前取消，行程費用之25% － 25% of Deposit within 14 days of the trip</p>
<p class="font_8">· 10天前取消，行程費用之50% － 50% of Deposit within 10 days of the trip</p>
<p class="font_8">· 07天前取消，不予以退費 － Within 7 days of trip, there will be no refund</p>', 'Advanced & EANx Certification Required (Deep Certification Recommended)', 'Day 1: Arrive in Kenting
Day 2: 3 Boat dives (Nitrox)
Day 3: am: 2 Boat dives (Air)
pm: Depart', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('66a14d79-02ff-479b-828d-a93065490107', 'Weekend Fun Diving', NULL, NULL, NULL, '2022-07-19 05:27:57+00', '2026-04-09 08:14:50+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/weekend-fun-diving/jul-23%2C-24', 'Local Fun Diving', 'wix:image://v1/b37fef_0386b474d7ad4e5eb46fd69d752935b2~mv2.jpg/P7170243.JPG#originWidth=4000&originHeight=3000', '<p class="font_8">A lovely dive site full of soft corals and giant groupers.&nbsp; Also a great place to see nudibranchs.</p>', '<p class="font_8">A lovely dive site full of soft coral and giant groupers. Also a great place to see Nudibranchs!</p>', NULL, '<p class="font_8">Come out and do some Fun Diving with Fun Divers Tw!</p>
<p class="font_8"><br></p>
<p class="font_8">Notes: We will be leaving Fun Divers at 8:30am each day. Be sure to bring your swimsuit, towel, snacks, sunscreen and logbooks.</p>
<p class="font_8"><br></p>
<p class="font_8">Price includes transportation, 2 tanks, and dive guide and Full Coverage Dive Insurance.</p>
<p class="font_8"><br></p>
<p class="font_8">Basic Equipment Rental is 1200NTD/day</p>
<p class="font_8"><br></p>
<p class="font_8">Schedule:</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Saturday, July 23</strong>: Secret Garden (1500ntd) (Secret Garden is a more challenging dive site so Advanced Certification Required)</p>
<p class="font_8"><strong>Saturday, July 23</strong>: Bat Cave (1400ntd)</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Sunday, July 24</strong>: Canyons (1600ntd) (Canyons is a more challenging dive site so Advanced Certification Required)</p>
<p class="font_8"><br></p>
<p class="font_8">＊請儘早匯入全額費用以確保您的名額 Please transfer the total amount As Soon As Possible to confirm your seat.</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer payments to:</p>
<p class="font_8">FunDivers CTBC Bank</p>
<p class="font_8">Bank code: 822</p>
<p class="font_8">Account: provided by email</p>
<p class="font_8">Space is limited, so book early!</p>', NULL, NULL, 'Jul 23, 24', 'Starting at 1,400', '2022-07-22 17:30:00+00', NULL, false, NULL, 'cb84ef01-98e5-4b17-b06d-3fc681a0107a', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('d94f4b25-c101-4834-980f-7e75722671cb', 'Kenting', NULL, NULL, NULL, '2022-09-07 02:46:29+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/kenting/dec-16-18', 'Multi-Day Fun Diving Trip', 'wix:image://v1/b37fef_0386b474d7ad4e5eb46fd69d752935b2~mv2.jpg/P7170243.JPG#originWidth=4000&originHeight=3000', '<p class="font_8">A trip to Kenting to explore the underwater world at the southern tip of Taiwan.&nbsp; We may also take some time to explore the surrounding area and do some sightseeing.</p>', '<p class="font_8">A great place for diving as well as exploring above the water.&nbsp; We will check out some of the great dive sites there, swim with blue spotted stingrays, turtles and batfish.&nbsp; Then, we will visit some of the beaches and the nightmarket as well!</p>', NULL, '<p class="font_8"><strong>費用包含：</strong><br>
 兩晚, 早餐x 2, 中餐x 2, 晚餐x 1, 船潛x 6, 兩天潛水險<br>
 <strong>Included:</strong><br>
2 Nights Room, 2 Breakfasts, 2 Lunches, 1 Dinner, 6 Boat Dives, 2 Days Full Diving Insurance.<br>
 <br>
 <strong>團費 Tour Price:</strong> <br>
 背包房 Bunk Bed: $12,400<br>
 雙人房 Double Bed: $13,000 (double occupancy)</p>
<p class="font_8">單人房 Single Room: $15,500 <br>
 <br>
 <strong>額外費用Additional Things to Consider:</strong><br>
 全套裝備租借(含電腦錶和浮力棒) Full Equipment Rental: $1600 x 2 days</p>
<p class="font_8">(includes Dive Computer and SMB)</p>
<p class="font_8">台北墾丁來回交通費Return Transport: $1600 <br>
 <br>
 <strong>課程Course Discounts:</strong><br>
 高氧課程 Enriched Air Nitrox Specialty $6,000 (原價 Normal Price $6,600)</p>
<p class="font_8">深潛課程 Deep Dive Specialty $5,200 (原價 Normal Price $6,200)</p>
<p class="font_8">進階課程 Advanced Open Water $11,000 (原價 Normal Price $12,200)</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>＊ 請於匯入訂金$8,000 Please transfer $8,000 deposit to confirm your booking.</strong></p>
<p class="font_8"><strong>餘款需於12/01 付清 The remaining balance must be paid by 12/01.</strong></p>
<p class="font_8"><br></p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!<br>
 中國信託銀行：822<br>
 帳號：provided by email</p>
<p class="font_8">分行：</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the deposit to: <br>
 FunDivers<br>
 CTBC Bank<br>
 Bank code: 822<br>
 Account: provided by email<br>
Branch: provided by email<br>
 <br>
 <br>
 <strong>行程Approximate Itinerary:<br>
 </strong><br>
 <strong>Day 1</strong></p>
<p class="font_8">18:30 Fun Divers Dive Center<br>
00:00 墾丁 Kenting</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Day 2</strong></p>
<p class="font_8">07:00 起床 Wake up <br>
07:30 早餐 Breakfast <br>
08:00 船潛兩支 2 boat dives<br>
12:00 中餐 Lunch <br>
13:00 船潛兩支 2 boat dives<br>
18:00 晚餐 Dinner<br>
 <br>
 <strong>Day 3</strong></p>
<p class="font_8">07:00 起床 Wake up <br>
07:30 早餐 Breakfast <br>
08:00 船潛兩支 2 boat dives<br>
12:00 中餐 Lunch <br>
13:00 打包行李 Pack up<br>
14:00 回台北 Drive back to Taipei<br>
 <br>
 ＊額外之餐費與娛樂費用請自理<br>
 ＊Additional Food, Drinks &amp; Entertainment are NOT included <br>
 <br>
 ＊記得攜帶 Remember to Bring:<br>
- 證照卡 Certification Card<br>
- 潛水日誌 Log Book<br>
- 電腦表 Dive Computer<br>
- 浮力棒 (SMB) Surface Marker Buoy<br>
- 暈船藥 Seasick Pills<br>
- 防賽 Sun Protection<br>
 <br>
 <u>臨時取消行程之賠償金額Cancellation Fee</u></p>
<p class="font_8"><u>· 14天前取消，行程費用之25% － 25% of Deposit within 14 days of the trip</u></p>
<p class="font_8"><u>· 10天前取消，行程費用之50% － 50% of Deposit within 10 days of the trip</u></p>
<p class="font_8"><u>· 07天前取消，不予以退費 － Within 7 days of trip, there will be no refund</u></p>', 'Advanced Certification Recommended', NULL, 'Dec 16-18', 'Starting at 12,400', '2022-12-15 16:00:00+00', '52224a76-927a-4e3e-8c52-2d34afacbdf0', false, NULL, NULL, NULL, true) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('6b55bb0b-afb6-4a2d-a732-54df212103a9', 'Turtle Island 3BD 2Air1EANx', 'Transportation(if needed), Local Diving Insurance, 3 Boat Dives, 1 Nitrox Tank, 2 Air Tanks, Dive Guide', 'Gear Rental, Food/Drinks', NULL, '2021-09-03 06:55:25+00', '2026-04-16 13:21:20+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/turtle-island/jun-17', 'Boat Diving', 'wix:image://v1/9f20fa_4724345e7c8e4eb1b5b2c1ddf3b473e8~mv2.jpg/divers%20and%20hotspring.jpg#originWidth=4008&originHeight=3008', '<p class="font_8">Turtle Island is a volcanic island located to the east of Yilan. &nbsp;It is home to the Milky Way (or Milky Sea) which is actually the result of an Underwater Hot Spring. &nbsp;The hot, sulfurous water mixes with the surrounding seawater and combine to make white, cloudy patterns. &nbsp;</p>
<p class="font_8"><br></p>
<p class="font_8">When diving there, visibility can be very limited but the unique dive environment makes it a worthwhile trip. &nbsp;Dolphins are also often spotted in the area surrounding the island which is a popular spot for dolphin and whale watching tours.</p>', '<p class="font_8">Come dive at an underwater hot spring and keep an eye out for dolphins during the trip!</p>', 'Come dive at an underwater hot spring and keep an eye out for dolphins during the trip!', '<p class="font_8">Come Explore Turtle Island With Fun Divers on our First Boat Diving Trip of the Season!</p>
<p class="font_8"><br></p>
<p class="font_8">We will be doing 3 Dives, including Wan An Jian Military Wreck and a Dive at an Underwater Hot Spring (The Milky Way)! We will also be keeping our eyes out for dolphins around the island!</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>團費 Tour Price: $4,800</strong></p>
<p class="font_8">費用包含：</p>
<p class="font_8">交通，船潛三支，潛導， 潛水險<br>
Included: Transportation, 3 Boat Dives, Dive Guide and Full Coverage Dive Insurance.</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>課程Courses:</strong></p>
<p class="font_8">高氧課程 $6,000 (原價 $6,600) -- Enriched Air Nitrox Specialty $6,000 (Normal $6,600)</p>
<p class="font_8">進階課程 Advanced Open Water $10,400 (原價Normal Price $12,200)</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>額外費用 Additional:</strong></p>
<p class="font_8">一天基本裝備租借 Basic Equipment Rental: $1200</p>
<p class="font_8">全套裝備租借(含電腦錶和浮力棒)Full Equipment Rental: $1600 (includes Dive Computer and SMB)</p>
<p class="font_8">潛水錶租借 (必備) Computer Rental (required):$300</p>
<p class="font_8">浮力袋租借(必備) SMB Rental (required): $150</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Schedule:</strong></p>
<p class="font_8">05:00 Meet at Fun Divers Tw</p>
<p class="font_8">05:15 Depart Fun Divers Tw</p>
<p class="font_8">06:30 Meet at Port</p>
<p class="font_8">07:00 Boat Departs</p>
<p class="font_8">17:00 Boat Returns</p>
<p class="font_8">17:30 Wash Gear</p>
<p class="font_8">19:00 Arrive Fun Divers Tw</p>
<p class="font_8"><br></p>
<p class="font_8">＊ 請儘早匯入全額，確保您的名額 Please transfer the total As Soon As Possible to confirm your seat.</p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦! 中國信託銀行：822 帳號：provided by email 分行：</p>
<p class="font_8"><strong>Please transfer the payment to:</strong></p>
<p class="font_8">FunDivers CTBC Bank</p>
<p class="font_8">Bank code: 822</p>
<p class="font_8">Account: provided by email</p>
<p class="font_8">Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶身份證明, 潛水證, 潛水紀錄本, 防曬用品</p>
<p class="font_8"><strong>＊Remember to Bring:</strong></p>
<p class="font_8">ARC/ID Card (for Coast Guard) - Certification Card - Log Book - Sun Protection - Lunch/snacks - Water</p>
<p class="font_8"><br></p>
<p class="font_8">*Dive Location may change due to weather conditions</p>
<p class="font_8"><br></p>
<p class="font_8">臨時取消行程之賠償金額 Cancellation Fee</p>
<p class="font_8">• 15天前取消，行程費用之25% － 25% of trip price within 15 days of the trip</p>
<p class="font_8">• 10天前取消，行程費用之50% － 50% of trip price within 10 days of the trip</p>
<p class="font_8">• 7天前取消，不予以退費 － Within 7 days of trip price, there will be no refund</p>', 'AOW & Nitrox Certification Required', '05:20 - Meet at Fun Divers
06:30 - Meet at Port
07:00 - Boat Departs
16:00 - Boat Returns (wash gear at port)
16:30 - Depart for Taipei', 'Jun 17', '4,800 NTD', '2023-06-16 16:00:00+00', NULL, true, NULL, 'd2d0329e-88b3-4ea1-9f74-c7099512cffc', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('6df2e318-fc07-48dd-84d0-2e28a18a430a', 'Badouzi AM 2 BD Air', 'Transportation(if needed), Local Diving Insurance, 2 Boat Dives, 2 Tanks, Dive Guide', 'Gear Rental, Food/Drinks', NULL, '2026-04-09 08:11:06+00', '2026-04-09 08:35:18+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'Local Boat Diving', 'wix:image://v1/b37fef_180ce15d03e24b0694ce1100c9bdd345~mv2.jpg/Badouzi%20and%20the%20Boat.jpg#originWidth=800&originHeight=450', '<p class="font_8">Fun Divers Tw is heading out to Badouzi Harbor to do some boat diving!&nbsp; Come Explore some of the amazing off-shore dive sites with us and see why we love diving there so much.&nbsp; We will be doing 2 boat dives at 2 different sites.</p>', '<p class="font_8">Explore some of the local dive sites not reachable from shore! See wrecks, artificial reefs and natural reefs with abundant sea life!</p>', 'Explore some of the local dive sites not reachable from shore! See wrecks, artificial reefs and natural reefs with abundant sea life!', '<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">厭倦了岸潛需要背上背下裝備嗎？來參加我們的八斗子船潛行程吧~<br>
Tired of the heavy lifting on shore dives?<br>
Come explore the outer reaches of Badouzi Bay by Boat<br>
<br>
費用包含：<br>
交通，保險 ，船潛兩支， 兩支氣瓶，潛導<br>
Included: Transportation(if needed), Travel Insurance, 2 Boat Dives, 2 Nitrox Tanks, Dive Guide<br>
</span><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif"><strong>團費 Tour Price:</strong></span><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif"> $3,200<br>
<br>
</span><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif"><strong>額外費用 Additional:</strong></span><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif"><br>
一天裝備租借 Full Equipment Rental: $1000<br>
<br>
＊ 請儘早匯入訂金$2,000 ，餘款9/14前完成匯款即可。<br>
Please transfer a $2,000 deposit As Soon As Possible to confirm your seat.<br>
The remaining balance must be paid on September 14th when we meet.<br>
<br>
Please transfer the deposit to:<br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
<br>
</span><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif"><strong>＊記得攜帶防曬用品,浮力袋(船潛必備),電腦表<br>
＊Remember to Bring:</strong></span></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">-ID Card (for Coast Guard)<br>
- Certification Card<br>
- Log Book<br>
- Surface Marker Buoy (SMB) – All divers MUST have<br>
<br>
臨時取消行程之賠償金額 Cancellation Fee<br>
• 10天前取消，行程費用之25% － 25% of trip price within 10 days of the trip<br>
• 7天前取消，行程費用之50% － 50% of trip price within 7 days of the trip<br>
• 5天前取消，不予以退費 － Within 5 days of trip price, there will be no refund</span></p>', 'AOW Certification Required', '06:15 - Meet at Fun Divers
07:30 - Meet at Port
08:00 - Boat Departs
12:00 - Boat Returns (wash gear at port)
12:30 - Depart for Taipei', NULL, '3,200 NTD', '2019-09-13 20:00:00+00', NULL, false, NULL, 'ce562dca-32d5-4d05-8a82-027a55404703', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('7e143e8f-25bc-4daa-80ba-5d6526372f1f', 'Bat Cave ', NULL, NULL, NULL, '2019-04-23 11:51:39+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'Local Shore Diving', 'wix:image://v1/b37fef_af67f50d528549109e0cbf9d05f73978~mv2_d_4026_3008_s_4_2.jpg/Moray%202%20(2).jpg#originWidth=4026&originHeight=3008', '<p class="p1"><span style="font-family:corben,serif">Come Fun Diving with Fun Divers TW as we head out to Bat Cave, one of our favorite Dive Sites!&nbsp;</span></p>', '<p class="p1"><span style="font-family:corben,serif">Come Fun Diving with Fun Divers TW as we head out to Bat Cave, one of our favorite Dive Sites!</span></p>', NULL, '<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif;">Come out and explore Bat Cave with Fun Divers!&nbsp;</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif;"><span class="wixGuard">​</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif;">Notes:<br />
We will be leaving Fun Divers at 8:30am.&nbsp; Be sure to bring your swimsuit, towel, snacks, sunscreen and logbooks.&nbsp;</span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif;">Price is 1200NTD and includes transportation, 2 tanks, and dive guide.</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif;">Equipment rental is 1000NTD</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif;">&nbsp;</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif;">＊請儘早匯入全額費用以確保您的名額<br />
Please transfer the total amount As Soon As Possible to confirm your seat.<br />
<br />
Please transfer payments to:<br />
FunDivers<br />
CTBC Bank<br />
Bank code: 822<br />
Account: provided by email<br />
<br />
Space is limited, so book early!</span></p>', 'Open to all levels of divers', NULL, NULL, '1,200 NTD', '2019-10-11 16:00:00+00', NULL, false, NULL, '1e1be45b-6ba5-4334-82ef-8331ee24c641', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('8004a94e-7d35-414f-b46e-b2c842f80b45', 'Badouzi PM 2 BD Air', 'Transportation(if needed), Local Diving Insurance, 2 Boat Dives, 2 Tanks, Dive Guide', 'Gear Rental, Food/Drinks', NULL, '2026-04-09 08:11:10+00', '2026-04-09 08:35:18+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'Local Boat Diving', 'wix:image://v1/b37fef_6929f50c76a34b16893242611734139e~mv2_d_4000_3000_s_4_2.jpg/david%20entry.JPG#originWidth=4000&originHeight=3000', '<p class="p1"><span style="font-family:corben,serif">Fun Divers Tw is heading out to Badouzi Harbor to do some boat diving!&nbsp; Come Explore some of the amazing off-shore dive sites with us and see why we love diving there so much.&nbsp; We will be doing 2 boat dives at 2 different sites.</span></p>', '<p class="p1"><span style="font-family:corben,serif">Explore some of the local dive sites not reachable from shore! See wrecks, artificial reefs and natural reefs with abundant sea life!</span></p>', 'Explore some of the local dive sites not reachable from shore! See wrecks, artificial reefs and natural reefs with abundant sea life!', '<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">厭倦了岸潛需要背上背下裝備嗎？來參加我們的八斗子船潛行程吧~<br />
Tired of the heavy lifting on shore dives?<br />
Come explore the outer reaches of Badouzi Bay by Boat<br />
<br />
費用包含：<br />
交通，保險 ，船潛兩支， 兩支氣瓶，潛導<br />
Included: Transport, Travel Insurance, 2 Boat Dives, 2 Tanks, Dive Guide<br />
<br />
<span style="font-weight:bold">團費 Tour Price:</span> $3,200<br />
<br />
<span style="font-weight:bold">額外費用 Additional:</span><br />
一天裝備租借 Full Equipment Rental: $1000<br />
<br />
＊請儘早匯入全額費用以確保您的名額<br />
Please transfer the total amount As Soon As Possible to confirm your seat.</span><br />
<br />
<span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Please transfer the deposit to:<br />
FunDivers<br />
CTBC Bank<br />
Bank code: 822<br />
Account: provided by email<br />
<br />
<span style="font-weight:bold">＊記得攜帶防曬用品,浮力袋(船潛必備),電腦表<br />
＊Remember to Bring:</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">-ID Card (or passport)(for Coast Guard)<br />
- Certification Card<br />
- Log Book<br />
- Surface Marker Buoy (SMB) &ndash; All divers MUST have<br />
<br />
臨時取消行程之賠償金額 Cancellation Fee<br />
&bull; 10天前取消，行程費用之25% － 25% of trip price within 10 days of the trip<br />
&bull; 7天前取消，行程費用之50% － 50% of trip price within 7 days of the trip<br />
&bull; 5天前取消，不予以退費 － Within 5 days of trip price, there will be no refund</span></p>', 'AOW Certification Required', '10:45 - Meet at Fun Divers
12:00 - Meet at Port
12:30 - Boat Departs
17:00 - Boat Returns (wash gear at port)
17:30 - Depart for Taipei', NULL, '3,200 NTD', '2019-10-04 20:00:00+00', NULL, false, NULL, 'f6055090-f3af-4b49-b784-c4971a7d2c5a', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('a4983552-dd75-4838-8961-e3686b84c46b', 'Palau', NULL, NULL, NULL, '2020-01-16 04:51:50+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'International Dive Trip', 'wix:image://v1/b37fef_c4ab01325aaa4c9684e2d65e52a5458d~mv2.jpg/Rock%20Islands,%20Palau.jpg#originWidth=1000&originHeight=584', '<p class="font_8">A 6 day, 5 night trip to Palau with 4 days of diving!&nbsp;&nbsp;Come experience one of the best diving destinations in the world! Explore lush coral reefs, drop-off walls, the Blue Hole, sunken shipwrecks, and snorkeling in the one and only Jellyfish Lake!</p>', '<p class="p1"><span style="font-family:corben,serif;">Have the chance to swim among whale sharks, reef sharks, manta rays, blackfin barracudas, sailfish, bigeye trevally, non-stinging Jellyfish and much more! Book now to secure your spot on this amazing trip!</span></p>', NULL, '<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Dive Palau with Fun Divers Tw! Come experience one of the best diving destinations in the world! Explore lush coral reefs, drop-off walls, the Blue Hole, sunken shipwrecks, and snorkeling in the one and only Jellyfish Lake!</span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Have the chance to swim among whale sharks, reef sharks, manta rays, blackfin barracudas, sailfish, bigeye trevally, non-stinging Jellyfish and much more! Book now to secure your spot on this amazing trip!</span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">費用包含：</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif"><span style="font-weight:bold">Included</span>: Airport Pick-up/Drop-off, 5 Nights Shared Rooms at Palasia Hotel, 5 Buffet Breakfasts, 4 Lunches, Pick-up/Drop-off from Hotel on diving days, 12 Nitrox Dives, Snorkeling at Jellyfish Lake, environmental fees</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif"><span class="wixGuard">​</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">＊額外之餐費與娛樂費用請自理</span></p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Flights are not included, book early to get cheaper flights!</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Additional Food, Drinks &amp; Entertainment are NOT included</span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif"><span style="font-weight:bold">團費 Tour Price:</span><br />
雙人房 Double Room: $46,800ntd (double occupancy)</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif"><span class="wixGuard">​</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif"><span style="font-weight:bold">額外費用 Additional:</span><br />
兩天裝備租借 Full Equipment Rental: $1,200 x 4</span></p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">PADI Enriched Air Nitrox Certification required</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">PADI Enriched Air Nitrox Course 4500 PADI 高氧課程 4200</span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">＊ 請於匯入訂金$20,000 Please transfer $20,000 deposit to confirm your booking.</span></span></p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">餘款需於03/15付清 The remaining balance must be paid by 03/15.</span></span></p>

<p class="p1"><br />
<br />
<span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">匯款帳號如下，匯款完畢,請私訊FunDivers哦!<br />
中國信託銀行：822<br />
帳號：provided by email</span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Please transfer the deposit to:<br />
FunDivers<br />
CTBC Bank<br />
Bank code: 822<br />
Account: provided by email</span><br />
&nbsp;</p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">＊記得攜帶防曬用品,浮力袋(船潛必備)，電腦表，紀錄書， 身份證號或居留證號</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">＊Remember to Bring:</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">- Certification Card</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">- Log Book</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">- ARC No. or Passport No. / ID Card No.</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">- <span style="font-weight:bold">Surface Marker Buoy (SMB) &ndash; (Required)</span></span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">臨時取消行程之賠償金額 Cancellation Fee</span></span></p>

<ul class="font_7" style="font-family:avenir-lt-w01_35-light1475496,sans-serif">
	<li>
	<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">21天前取消，行程費用之25% － 25% of Deposit within 21 days of the trip</span></p>
	</li>
	<li>
	<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">14天前取消，行程費用之50% － 50% of Deposit within 14 days of the trip</span></p>
	</li>
	<li>
	<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">07天前取消，不予以退費 － Within 7 days of trip, there will be no refund</span></p>
	</li>
</ul>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">行程 Approximate Itinerary:</span></span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Apr 3</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">13:15 China Airlines Flight CI28 Taipei (TPE)-Palau (ROR) <span style="font-weight:bold">(not included in price, book separately)</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">18:05 Arrive in Palau and transfer to hotel.</span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Apr 4-7</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Daily Itinerary will vary depending on dive conditions and dive locations. There will be 3 Dives daily as well as a trip to Jellyfish Lake for snorkeling.&nbsp;</span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-weight:bold"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Apr 8</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">19:05 China Airlines Flight CI27 Palau (ROR) &ndash;Taipei (TPE) <span style="font-weight:bold">(not included in price, book separately)</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">22:05 抵達台北 Arrive in Taipei</span></p>', 'Advanced Certification & Nitrox Certification Required (can do certification course during trip)', NULL, NULL, '46,800NTD', '2020-04-02 16:00:00+00', 'b2c76485-d2b5-4be1-a47a-84e109020ed1', false, NULL, NULL, NULL, true) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('cc04b6a1-c340-4c7a-885a-760565db77ef', 'Fun Divers Dive Center', NULL, NULL, NULL, '2019-08-13 10:35:05+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/fun-divers-dive-center/jul-30%2C-31%2C-aug-6', 'PADI Advanced Course', 'wix:image://v1/b37fef_3166e2616932488aad593a8fb4c8f6d8~mv2.jpg/64365829_2620424691314544_71180475215443.jpg#originWidth=1200&originHeight=900', '<p class="font_8">By taking the PADI Advanced Course, you will learn more about the underwater world while expanding your diving skills.&nbsp; You will practice your navigation and go deeper.&nbsp; After the course, you will be certified to 30 meters which will open up more dive sites to you around the world.&nbsp; You will also be able to choose 3 specialty dives based on your interests!</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Top 10 reasons to&nbsp;take the PADI Advanced Course:</strong></p>
<p class="font_8">1. Increase your knowledge of diving</p>
<p class="font_8">2. Expand the skills you’ve learned while supervised</p>
<p class="font_8">3. Dive as deep as 30m and see more</p>
<p class="font_8">4. Gain confidence in yourself</p>
<p class="font_8">5. Be more comfortable in the water</p>
<p class="font_8">6. Be more comfortable with the equipment</p>
<p class="font_8">7. Try 5 different kinds of adventure dives</p>
<p class="font_8">8. More chances to explore different dive sites locally and worldwide</p>
<p class="font_8">9. Higher credentials, less hassle when traveling</p>
<p class="font_8">10. Meet new dive buddies</p>', '<p class="font_8">The PADI Advanced Open Water Diver Course is a great way to improve your diving skills, get additional diving experience under the supervision of an instructor and increase your knowledge about diving.&nbsp;</p>', NULL, '<p class="font_8"><u><strong>PADI Advanced Open Water Course with Fun Divers Tw</strong></u></p>
<p class="font_8"><br></p>
<p class="font_8">Come take the next step and get your PADI Advanced Certification with Fun Divers Tw!</p>
<p class="font_8">By taking the PADI Advanced Course, you will learn more about the underwater world while expanding your diving skills. You will practice your navigation and go deeper. After the course, you will be certified to 30 meters which will open up more dive sites to you around the world.&nbsp;</p>
<p class="font_8"><br></p>
<p class="font_8">The course includes 5 dives, 2 of which are required (deep &amp; navigation) and you will also be able to choose 3 specialty dives based on your interests! Choose which specialties are right for you! See your options on our <a href="https://www.fundiverstw.com/specialties">website</a>!</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Course Price</strong>：$12,200</p>
<p class="font_8">價錢 ：$12,200</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Get a discount if you sign up with a friend!</strong></p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Gear Rental</strong>: 1200ntd/Day.<br>
 <br>
Course fees include PADI E-Learning, SMB, Reel, Transportation and Full Coverage Diving Insurance. &nbsp;Students are required to purchase their own masks and snorkels due to covid concerns.</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Current Course Dives Scheduled:</strong></p>
<p class="font_8"><strong>Jul 30: </strong>2 Dive Day</p>
<p class="font_8"><strong>Jul 31: </strong>2 Dive Day</p>
<p class="font_8"><strong>Aug 06: </strong>3 Dive Day with Night Dive</p>
<p class="font_8"><br></p>
<p class="font_8">If the above dates don’t work for you, contact us and we can work out a schedule for you!</p>
<p class="font_8"><br></p>
<p class="font_8">Transfer 5000ntd Deposit to the account below to secure your spot!</p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!<br>
 中國信託銀行：822<br>
 帳號：provided by email<br>
 分行：</p>
<p class="font_8">Please transfer the deposit to: <br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">Learn Scuba Diving with Fun Divers Tw! The Way Diving Should Be Taught!<br>
 今年夏天來成為合格的PADI潛水員吧！</p>
<p class="font_8">Find out more information about the PADI Advanced Course on our <a href="https://www.fundiverstw.com/Courses/PADI-Advanced-Course">website</a>!</p>', 'PADI Open Water Certification (or other organization equivalent) Required before taking this course', NULL, 'Jul 30, 31, Aug 6', '12,200 NTD', '2022-07-29 16:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('885d42e6-63bf-4064-9355-6e5dbb39f594', 'East Coast Boat Diving', NULL, NULL, NULL, '2021-03-25 10:19:47+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/east-coast-boat-diving/apr-30', 'Boat Diving', 'wix:image://v1/b37fef_6929f50c76a34b16893242611734139e~mv2_d_4000_3000_s_4_2.jpg/david%20entry.JPG#originWidth=4000&originHeight=3000', '<p class="font_8">We will be doing 2 boat dives on the East Coast, trying to find dolphins and exploring a wreck. &nbsp;Space is limited so book early!</p>', '<p class="font_8">Come explore the East Coast with Fun Divers Tw! &nbsp;We will be trying to find dolphins and exploring a wreck!</p>', NULL, '<p class="font_8"><u>費用包含</u>：</p>
<p class="font_8"><br>
交通，船潛兩支，潛導<br>
Included: Transportation, 2 Boat Dives, Dive Guide<br>
<br>
<u>團費 Tour Price</u>: $3,200<br>
<br>
<u>額外費用 Additional:</u><br>
一天基本裝備租借 Basic Equipment Rental: $1200<br>
<br>
潛水錶租借 (必備) Computer Rental <strong>(required):</strong> $300<br>
<br>
浮力袋租借(必備) SMB Rental <strong>(required): </strong>$150</p>
<p class="font_8"><br>
&nbsp;</p>
<p class="font_8">＊ 請儘早匯入全額，確保您的名額<br>
Please transfer the total As Soon As Possible to confirm your seat.<br>
<br>
匯款帳號如下，匯款完畢,請私訊FunDivers哦!<br>
中國信託銀行：822<br>
帳號：provided by email<br>
分行：</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the payment to:<br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶身份證明, 潛水證, 潛水紀錄本, 防曬用品<br>
＊Remember to Bring:</p>
<p class="font_8"><br></p>
<p class="font_8">- ARC/ID Card (for Coast Guard)<br>
- Certification Card<br>
- Log Book<br>
- Sun Protection</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>*Dive Location may change due to weather conditions</strong><br>
&nbsp;</p>
<p class="font_8"><u>Schedule:</u></p>
<p class="font_8"><br></p>
<p class="font_8">06:00 Meet at Fun Divers Tw<br>
06:15 Depart Fun Divers Tw<br>
07:30 Meet at Port<br>
08:00 Boat Departs<br>
12:00 Boat Returns<br>
12:30 Wash Gear/Shower<br>
13:30 Lunch<br>
14:30 Depart for Taipei<br>
15:30 Arrive Fun Divers Tw</p>
<p class="font_8"><br>
臨時取消行程之賠償金額 Cancellation Fee<br>
• 15天前取消，行程費用之25% － 25% of trip price within 15 days of the trip<br>
• 10天前取消，行程費用之50% － 50% of trip price within 10 days of the trip<br>
• 7天前取消，不予以退費 － Within 7 days of trip price, there will be no refund</p>', 'Advanced Certified', NULL, 'Apr 30', '3,200 NTD', '2021-04-29 16:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('886a0221-b657-4060-a623-5a32515017f3', 'Batcave', NULL, NULL, NULL, '2019-08-12 10:41:41+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/batcave/aug-14', 'Local Fun Diving with Night Dive', 'wix:image://v1/b37fef_354e7dc9f79d45fdb32f3df4a632c94f~mv2.jpg/Baby%20Squid%20Close%20ND%20WM.jpg#originWidth=2274&originHeight=1707', '<p class="font_8">Let’s do some Night Diving!&nbsp; Fun Divers Tw is heading out for a 3 dive day with a night dive!&nbsp; Join us for a great night time adventure!</p>', '<p class="font_8">Let’s do some Night Diving!&nbsp; Fun Divers Tw is heading out for a 3 dive day with a night dive!&nbsp; Join us for a great night time adventure!</p>', NULL, '<p class="font_8">Let’s &nbsp;do some Night Diving! &nbsp;Fun Divers Tw is heading to &nbsp;Bat Cave for 2 day dives and a night dive!&nbsp;</p>
<p class="font_8"><br></p>
<p class="font_8">Join us for a great night&nbsp;time adventure!</p>
<p class="font_8"><br></p>
<p class="font_8">Notes:<br>
We will be leaving Fun Divers at 11:00am. &nbsp;Be sure to bring your swimsuit, towel, snacks, sunscreen and logbooks.</p>
<p class="font_8"><br></p>
<p class="font_8">Price is 2200NTD and includes transportation, 3 tanks, full coverage diving insurance, and dive guide.</p>
<p class="font_8"><br></p>
<p class="font_8">Basic Equipment Rental is 1200NTD<br>
Flashlight Rental is 200NTD</p>
<p class="font_8"><br></p>
<p class="font_8">Space is limited, so book early!</p>
<p class="font_8"><br></p>
<p class="font_8">＊請儘早匯入全額費用以確保您的名額<br>
Please transfer the total amount As Soon As Possible to confirm your seat.<br>
<br>
<strong>Please transfer payments to:</strong><br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
<br>
Be sure to bring sun protection, snacks, water, and swimsuit.</p>', 'Advanced Certification Required for Night Dive', NULL, 'Aug 14', '2,200 NTD', '2022-08-13 16:00:00+00', NULL, false, NULL, '1e1be45b-6ba5-4334-82ef-8331ee24c641', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('8b2e190d-0800-4cdd-9947-ea23a6e35f15', 'Fun Divers Dive Center', NULL, NULL, NULL, '2022-05-10 04:32:38+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/fun-divers-dive-center/may-29', 'Buoyancy Specialty Course', 'wix:image://v1/b37fef_6b01226a00034f9d998bf0952daa3a26~mv2.jpg/tina%20and%20tiffany%20and%20the%20wreck.jpg#originWidth=3812&originHeight=2847', '<p class="font_8">The PADI Peak Performance Buoyancy Specialty Course focuses on improving your underwater buoyancy, trim, and swimming efficiency. &nbsp;Divers will do different buoyancy exercises and practice breathing techniques all under the guidance of a PADI Instructor.</p>', '<p class="font_8">Buoyancy is one of the most important skills for a diver to improve. Come work on yours with Fun Divers Tw!</p>', NULL, '<p class="font_8">Fun Divers is running a Buoyancy Specialty Course for divers that want to improve their buoyancy and dive skills. The Course will include a classroom session, 2 dives and buoyancy workshops both in and out of the water.</p>
<p class="font_8"><br></p>
<p class="font_8">We will cover many skills during the Buoyancy Specialty Course, including:</p>
<p class="font_8">· Proper Weighting and Weight Distribution</p>
<p class="font_8">· Achieving Neutral Buoyancy</p>
<p class="font_8">· Proper Trim and Kicking styles</p>
<p class="font_8">· Breathing Techniques and Using Lungs to Control Buoyancy</p>
<p class="font_8"><br></p>
<p class="font_8">Reasons <strong>ALL</strong>divers should work on their buoyancy:</p>
<p class="font_8">· Cause less damage to the environment</p>
<p class="font_8">· Feel more comfortable in the water</p>
<p class="font_8">· Improves your air consumption rate</p>
<p class="font_8">· Makes for longer dives</p>
<p class="font_8">· More relaxed and longer dives mean MORE FUN!</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Cost:</strong> $6200 including transportation, tanks, and classroom session with instructor</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Gear Rental:</strong> $1200 for basic set</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Course Schedule:</strong></p>
<p class="font_8"><br></p>
<p class="font_8"><strong>May 29:</strong> Meet at Fun Divers Tw at 8:30</p>
<p class="font_8">Classroom portion will be done online and will be scheduled for a time that is convenient for everyone.</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Notes:</strong></p>
<p class="font_8"><br></p>
<p class="font_8">Remember to bring your Logbook, sun protection, and a snack.</p>
<p class="font_8">Learn Scuba Diving with Fun Divers Dive Center!<br>
The Way Diving Should Be Taught!<br>
今年夏天來成為合格的PADI潛水員吧！</p>
<p class="font_8">Please transfer the total amount to confirm your spot.<br>
<br>
Please transfer payments to:<br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
<br>
Space is limited, so book early!</p>', 'PADI Open Water Certified', NULL, 'May 29', '6200 NTD', '2022-05-28 16:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('8d21dc75-1f1d-4cb6-9903-6e353dd63ef2', 'East Coast AM 2BD EANx ', 'Transportation(if needed), Local Diving Insurance, 2 Boat Dives, 2 Nitrox Tanks, Dive Guide', 'Gear Rental, Food/Drinks', NULL, '2021-03-26 04:15:07+00', '2026-04-09 08:30:20+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/cauliflower-garden/oct-02', 'Boat Diving', 'wix:image://v1/b37fef_519ef15551bd481c824f50e9b6ece493~mv2.jpg/cauliflowers.JPG#originWidth=4000&originHeight=3000', '<p class="font_8">We will be doing 2 boat dives on the East Coast of Taiwan. One will be at Cauliflower Garden, the other at the Power Plant Outflow. &nbsp;Space is limited so book early!</p>', '<p class="font_8">Come explore the East Coast with Fun Divers Tw! &nbsp;We will be trying to find dolphins and exploring two different dive sites!</p>', 'Come explore the East Coast with Fun Divers Tw!  We will be trying to find dolphins and exploring two different dive sites!', '<p class="font_8">Cauliflower Garden and Power Plant Outflow</p>
<p class="font_8"><br></p>
<p class="font_8">Come check out the Beautiful Cauliflower Garden and Power Plant Outflow with Fun Divers Tw!</p>
<p class="font_8"><br></p>
<p class="font_8">費用包含：</p>
<p class="font_8">交通，船潛兩支，潛導，潛水保險</p>
<p class="font_8">Included: Transportation, 2 Boat Dives, Dive Guide, Full Coverage Dive Insurance</p>
<p class="font_8"><br></p>
<p class="font_8">團費 Tour Price: $3,600</p>
<p class="font_8"><br></p>
<p class="font_8">額外費用 Additional:</p>
<p class="font_8"><br></p>
<p class="font_8">一天基本裝備租借 Basic Equipment Rental: $1200<br>
 全套裝備租借(含電腦錶和浮力棒)Full EquipmentRental: $1600 (includes Dive Computer and SMB)</p>
<p class="font_8">潛水錶租借 (必備) Computer Rental (required): $300</p>
<p class="font_8">浮力袋租借(必備) SMB Rental (required): $150</p>
<p class="font_8"><br></p>
<p class="font_8">＊ 請儘早匯入全額，確保您的名額</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the total As Soon As Possible to confirm your seat.</p>
<p class="font_8"><br></p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!</p>
<p class="font_8">中國信託銀行：822</p>
<p class="font_8">帳號：provided by email</p>
<p class="font_8">分行：</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the payment to:</p>
<p class="font_8">FunDivers</p>
<p class="font_8">CTBC Bank Bank code: 822</p>
<p class="font_8">Account: provided by email</p>
<p class="font_8">Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶身份證明, 潛水證, 潛水紀錄本, 防曬用品</p>
<p class="font_8">＊Remember to Bring:</p>
<p class="font_8">- ARC/ID Card (for Coast Guard)</p>
<p class="font_8">- Certification Card</p>
<p class="font_8">- Log Book</p>
<p class="font_8">- Sun Protection</p>
<p class="font_8">- Dive Computer – All divers MUST have<br>
- Surface Marker Buoy (SMB) – All divers MUST have</p>
<p class="font_8"><br></p>
<p class="font_8">*Dive Location may change due to weather conditions</p>
<p class="font_8"><br></p>
<p class="font_8">臨時取消行程之賠償金額 Cancellation Fee</p>
<p class="font_8">• 15天前取消，行程費用之25% － 25% of trip price within 15 days of the trip</p>
<p class="font_8">• 10天前取消，行程費用之50% － 50% of trip price within 10 days of the trip</p>
<p class="font_8">• 7天前取消，不予以退費 － Within 7 days of trip price, there will be no refund</p>', 'AOW & Nitrox Certification Required', '05:20 - Meet at Fun Divers
06:30 - Meet at Port
07:00 - Boat Departs
12:00 - Boat Returns (wash gear at port)
12:30 - Depart for Taipei', 'Oct 02', '3,600 NTD', '2022-10-01 16:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('e57fe3a2-d9ae-4902-ae4b-3e58f4d248fb', 'Fun Divers Dive Center', NULL, NULL, NULL, '2021-04-06 03:39:31+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/fun-divers-dive-center/sep-17%2C-24%2C-25', 'PADI Open Water Course', 'wix:image://v1/b37fef_db627ed59e1844f7bdaadb1bf73e674c~mv2_d_4000_3000_s_4_2.jpg/brian%20swimming.JPG#originWidth=4000&originHeight=3000', '<p class="font_8">The PADI Open Water Course is the first step in your underwater journey!&nbsp; Learn how to use Scuba Diving Equipment, how to handle yourself underwater, and how to fully enjoy your time underwater.&nbsp; Let Fun Divers TW introduce you to the amazing world of Scuba Diving in Taiwan (and the world)! &nbsp;</p>', '<p class="font_8">Start your underwater adventure by getting your PADI Open Water Certification!&nbsp;</p>', NULL, '<p class="font_8">Do you want to learn to Scuba Dive?! Now is the last chance to do it in the North! Fun Divers Tw is starting a course on September 17th! &nbsp;This course will be a PADI E-Learning Course so the academic portion will all be done on your own and we will meet for the Pool and Ocean sessions. See the schedule below.<br>
 <br>
 <strong>Price</strong> ：14,600ntd</p>
<p class="font_8"><strong>Get a discount if you sign up with a friend!</strong></p>
<p class="font_8"><br></p>
<p class="font_8">Price includes E-Learning, transportation, and gear rental. Due to Covid concerns, students will need to purchase their own Mask and Snorkel for use during the course. There is a selection to choose from at Fun Divers Tw.<br>
 <br>
 今年夏天來成為合格的PADI潛水員吧！<br>
 Learn Scuba Diving with Fun Divers Tw!<br>
 The Way Diving Should Be Taught<br>
 <br>
 Fun Divers 課程已完全更新，符合PADI教學課程之規定。為了能夠更安全的享受潛水活動，請跟我們一起學習安全且符合規定的潛水新知吧！<br>
 <br>
 <strong>17 Sep: 8:30am-4pm </strong><br>
 先上泳池 ，下午回來Fun Divers潛水教室考試<br>
 Knowledge Check and Pool lessons<br>
 Bring your swimsuit, towel and a snack<br>
 <br>
 <strong>24 &amp; 25 Sep: 8:30am-4pm</strong></p>
<p class="font_8">Open Water Dives</p>
<p class="font_8">Bring your swimsuit, towel, snacks, water and logbook</p>
<p class="font_8">Please transfer a 5000ntd deposit to confirm your spot in the class. Notify Fun Divers Tw when the transfer is complete.<br>
 <br>
Please transfer payments to: <br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
Branch: provided by email<br>
 <br>
 ＊戶外課程將視天氣狀況作調整</p>
<p class="font_8">Find out more information about the Open Water Course on our <a href="https://www.fundiverstw.com/courses-1/padi-open-water-course">website</a>!</p>', 'Beginning Level Course Open to All', NULL, 'Sep 17, 24, 25', '14,600 NTD', '2022-09-16 16:00:00+00', NULL, false, NULL, NULL, true, false) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('8dba1d70-eb07-4a00-81ce-e4543d7f6fc8', 'Batcave', NULL, NULL, NULL, '2022-06-28 05:38:53+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/batcave/jul-3', 'Local Fun Diving with Night Dive', 'wix:image://v1/b37fef_9df8db23977e4acf8eafeae8dadeab7c~mv2.jpg/Decorator%20Crab%20BC.jpg#originWidth=3200&originHeight=2402', '<p class="font_8">Let’s do some Night Diving!&nbsp; Fun Divers Tw is heading out for a 3 dive day with a night dive!&nbsp; Join us for a great night time adventure!</p>', '<p class="font_8">Let’s do some Night Diving!&nbsp; Fun Divers Tw is heading out for a 3 dive day with a night dive!&nbsp; Join us for a great night time adventure!</p>', NULL, '<p class="font_8">Let’s &nbsp;do some Night Diving! &nbsp;Fun Divers Tw is heading to &nbsp;Bat Cave for 2 day dives and a night dive!&nbsp;</p>
<p class="font_8"><br></p>
<p class="font_8">Join us for a great night&nbsp;time adventure!</p>
<p class="font_8"><br></p>
<p class="font_8">Notes:<br>
We will be leaving Fun Divers at 11:00am. &nbsp;Be sure to bring your swimsuit, towel, snacks, sunscreen and logbooks.</p>
<p class="font_8"><br></p>
<p class="font_8">Price is 2200NTD and includes transportation, 3 tanks, full coverage diving insurance, and dive guide.</p>
<p class="font_8"><br></p>
<p class="font_8">Basic Equipment Rental is 1200NTD<br>
Flashlight Rental is 200NTD</p>
<p class="font_8"><br></p>
<p class="font_8">Space is limited, so book early!</p>
<p class="font_8"><br></p>
<p class="font_8">＊請儘早匯入全額費用以確保您的名額<br>
Please transfer the total amount As Soon As Possible to confirm your seat.<br>
<br>
<strong>Please transfer payments to:</strong><br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
<br>
Be sure to bring sun protection, snacks, water, and swimsuit.</p>', 'Advanced Certification Required for Night Dive', NULL, 'Jul 3', '2,200 NTD', '2022-07-02 16:00:00+00', NULL, false, NULL, '1e1be45b-6ba5-4334-82ef-8331ee24c641', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('942cc2dc-05f8-4dc3-b524-5ecaab2608ee', 'Fun Divers Dive Center', NULL, NULL, NULL, '2019-11-05 08:46:39+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'PADI EFR Course', 'wix:image://v1/b37fef_3970088889d24834a7ab01a1fca962b6~mv2.jpg/EFR_print_05(1).jpg#originWidth=1200&originHeight=900', '<p class="p1"><span style="font-family:corben,serif">In the <span style="text-decoration:underline"><a href="https://www.fundiverstw.com/Courses/PADI-EFR-Course">PADI EFR Course</a></span>, you will learn how to administer basic first aid as well as how to perform CPR properly.&nbsp; You will also be taught how to use an Automated External Defibrillator (AED).&nbsp; The PADI EFR Course is the equivalent of the Red Cross First Aid Certification and is recognized worldwide.</span></p>', '<p class="p1"><span style="font-family:corben,serif">Discover simple to follow steps for emergency care. This course focuses on building confidence in lay rescuers and increasing their willingness to respond when faced with a medical emergency in a non-stressful learning environment.&nbsp; You don&#39;t have to be a diver to take this course.</span></p>', NULL, '<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Do you know what to do if someone is injured or not breathing?&nbsp; Learn how to perform CPR and handle emergency situations confidently!&nbsp; Take the PADI Emergency First Responder (EFR) Course with Fun Divers Tw and learn from a former EMT!</span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">In the PADI EFR Course, you will learn how to administer basic first aid as well as how to perform CPR properly.&nbsp; You will also be taught how to use an Automated External Defibrillator (AED).&nbsp; The PADI EFR Course is the equivalent of the Red Cross First Aid Certification and is recognized worldwide.</span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Course Price:&nbsp; 4800 NTD for the course +1800 for the book</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif"><span class="wixGuard">​</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; Get a discount if you sign up with a friend!</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif"><span class="wixGuard">​</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">4500 NTD/Each for 2</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">4200 NTD/Each for 3</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">4000 NTD/Each for 4+</span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Upcoming Course Schedule:&nbsp;&nbsp; Classes are from 9am &ndash; 3pm</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">November 9th</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">November 23rd</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">December 14th</span></p>

<p class="p1"><br />
<span style="font-family:avenir-lt-w01_35-light1475496,sans-serif">Please transfer the total amount to confirm your spot in the class.&nbsp; Notify Fun Divers Tw when the transfer is complete.<br />
<br />
Please transfer payments to:<br />
FunDivers<br />
CTBC Bank<br />
Bank code: 822<br />
Account: provided by email</span></p>', 'Open to all (divers and non-divers welcome)', NULL, NULL, '4,800 NTD', '2019-12-13 18:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('95a6523f-199d-4219-be47-362480f408c4', 'Lambai Island', NULL, NULL, NULL, '2019-04-23 05:39:19+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/lambai-island/feb-5%2C-17-19', 'PADI Open Water Course', 'wix:image://v1/b37fef_acebd23599bd4c18993a88832bb22d04~mv2.jpg/polly%20turtle%207.JPG#originWidth=4000&originHeight=3000', '<p class="font_8">The PADI Open Water Course is the first step in your underwater journey!&nbsp; Learn how to use Scuba Diving Equipment, how to handle yourself underwater, and how to fully enjoy your time underwater.&nbsp; Let Fun Divers TW introduce you to the amazing world of Scuba Diving in Taiwan (and the world)!</p>', '<p class="font_8">Come learn to dive with the Turtles of Lambai! &nbsp;Fun Divers Tw is starting a PADI Open Water Course in February and will do the Classroom and Pool portion in Taipei on Feb 5th and the Ocean portion on Lambai Island on Feb 17-19!</p>', NULL, '<p class="font_8"><u>小琉球 小琉球 Beautiful Lambai</u></p>
<p class="font_8"><br></p>
<p class="font_8">A weekend trip to Lambai Island to enjoy some time away from the city learning to dive! &nbsp;We will be diving with sea turtles, and getting our PADI Open Water Certification!</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>費用包含：</strong></p>
<p class="font_8">往返東港船票， 兩晚上住宿 ，早餐 x 2，午餐 x 2，晚餐 x 1，機車(兩人一台)，課程潛水四支， 潛水險。</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Included:</strong></p>
<p class="font_8">Round Trip Ferry, 2 Nights Shared Rooms, 2 Breakfasts, 2 Lunches, 1 Dinner, 2 Days Shared Motorbike, 4 Course Dives, 2 Days Full Diving Insurance.</p>
<p class="font_8"><br></p>
<p class="font_8">＊額外之餐費與娛樂費用請自理</p>
<p class="font_8">Additional Food, Drinks &amp; Entertainment are NOT included</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>團費 Tour Price:</strong></p>
<p class="font_8">背包房 Bunk Room: $11,800</p>
<p class="font_8">雙人房 Basic Double Room: $13,500 (double occupancy)</p>
<p class="font_8"><br></p>
<p class="font_8">歡迎非潛水員參加 Non-Divers are also welcome to join $6,400 (bunk room)</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>額外費用Additional:</strong></p>
<p class="font_8">兩天裝備租借 Basic Equipment Rental: $1,200 x 2 days (included with Open Water Course)</p>
<p class="font_8">全套裝備租借(含電腦錶和浮力棒) Full Equipment Rental: $1,600 x 2 days</p>
<p class="font_8">(includes Dive Computer and SMB)</p>
<p class="font_8">台北東港來回交通費 Return Transport: $1,400</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>課程Courses:</strong></p>
<p class="font_8">初級課程 Open Water Course $11,600 (Normally $14,600)</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>行程Approximate Itinerary:</strong></p>
<p class="font_8"><br></p>
<p class="font_8"><strong>05 Feb: 8:30am-4pm </strong><br>
 先上泳池 ，下午回來Fun Divers潛水教室考試<br>
 Knowledge Check and Pool lessons<br>
 Bring your swimsuit, towel and a snack</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>17 Feb</strong></p>
<p class="font_8">16:00 離開台北Depart Fun Divers Dive Center (earlier if possible) <br>
20:00飯店Hotel Kaohsiung</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>18 Feb</strong></p>
<p class="font_8">07:30 早餐 Breakfast</p>
<p class="font_8">08:00 出發 Depart</p>
<p class="font_8">09:00 東港漁港 Donggang Dock－小琉球 Liu Qiu Island</p>
<p class="font_8">10:00 岸潛一支 1 Shore Dive</p>
<p class="font_8">11:30 中餐 Lunch</p>
<p class="font_8">12:30 岸潛一兩支 1 or 2 Shore Dives</p>
<p class="font_8">18:00 吃到飽烤肉 All you can eat BBQ Dinner</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>19 Feb</strong></p>
<p class="font_8">07:30 早餐Breakfast</p>
<p class="font_8">08:00 岸潛一兩支 1 or 2 Shore Dives</p>
<p class="font_8">12:30 中餐 Lunch</p>
<p class="font_8">14:30 小琉球 Liu Qiu Island ─ 東港 Donggang</p>
<p class="font_8">15:30 離開東港 Depart from Donggang</p>
<p class="font_8">21:30 抵達台北 Arrive in Taipei</p>
<p class="font_8"><br></p>
<p class="font_8">＊ 請於匯入訂金 $11,000 Please transfer $11,000 deposit to confirm your booking.</p>
<p class="font_8">餘款需於02/05 付清 The remaining balance must be paid by 02/05.</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Please transfer the deposit to:</strong></p>
<p class="font_8">FunDivers CTBC Bank</p>
<p class="font_8">Bank code: 822</p>
<p class="font_8">Account: provided by email</p>
<p class="font_8">Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!</p>
<p class="font_8">中國信託銀⾏：822</p>
<p class="font_8">帳號：provided by email</p>
<p class="font_8">分⾏：</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶 Remember to Bring:<br>
- 證照卡 Certification Card<br>
- 潛水日誌 Log Book<br>
- 電腦表 Dive Computer(required if doing boat dives) (rental 300/day)<br>
- 浮力棒 (SMB) Surface Marker Buoy(required if doing boat dives) (rental 150/day)<br>
- 暈船藥 Seasick Pills<br>
- 防賽 Sun Protection</p>
<p class="font_8">- 大毛巾Towel</p>
<p class="font_8">- 薄夾克Jacket</p>
<p class="font_8"><br></p>
<p class="font_8"><u><strong>臨時取消行程之賠償金額 Cancellation Fee</strong></u></p>
<p class="font_8">· 14天前取消，行程費用之25% － 25% of Deposit within 14 days of the trip</p>
<p class="font_8">· 10天前取消，行程費用之50% － 50% of Deposit within 10 days of the trip</p>
<p class="font_8">· 07天前取消，不予以退費 － Within 7 days of trip, there will be no refund</p>', 'Beginning Level Course Open to All', NULL, 'Feb 5, 17-19', 'See Details', '2023-02-04 16:00:00+00', 'b718703b-b6d6-43ff-b56e-f886ed67d9c5', false, NULL, NULL, false, true) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('9ba12b94-6749-4e8e-8ce7-795310c18f17', 'North Coast Boat Diving', NULL, NULL, NULL, '2021-03-26 04:14:14+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/north-coast-boat-diving/aug-22', 'Local Boat Diving', 'wix:image://v1/b37fef_af67f50d528549109e0cbf9d05f73978~mv2_d_4026_3008_s_4_2.jpg/Moray%202%20(2).jpg#originWidth=4026&originHeight=3008', '<p class="font_8">Fun Divers Tw is heading out to the North Coast to do some boat diving around Keelung!&nbsp; Come Explore some of the amazing off-shore dive sites with us and see why we love diving there so much.&nbsp; We will be doing 2 boat dives at 2 different sites.&nbsp;</p>', '<p class="font_8">Explore some of the local dive sites not reachable from shore! See wrecks, artificial reefs and natural reefs with abundant sea life!</p>', NULL, '<p class="font_8"><u>費用包含：</u><br>
交通，船潛兩支高氧，潛導，個人指位無線電示標<br>
Included: Transportation, 2 Boat Dives with Nitrox, Dive Guide, Locator Beacon<br>
<br>
<u>團費 Tour Price</u>: $3,200</p>
<p class="font_8"><br></p>
<p class="font_8"><u>課程Courses:</u></p>
<p class="font_8">高氧課程 $5,600 (原價 $6,600) -- Enriched Air Nitrox Specialty $5,600 (Normal $6,600)<br>
<br>
<u>額外費用 Additional:</u><br>
一天基本裝備租借 Basic Equipment Rental: $1200<br>
<br>
潛水錶租借 (必備) Computer Rental <strong>(required):</strong> $300<br>
<br>
浮力袋租借(必備) SMB Rental <strong>(required): </strong>$150<br>
<br>
潛水險 (必要) Diving Insurance <strong>(required):</strong> $400<br>
</p>
<p class="font_8">＊ 請儘早匯入全額，確保您的名額<br>
Please transfer the total As Soon As Possible to confirm your seat.<br>
<br>
匯款帳號如下，匯款完畢,請私訊FunDivers哦!<br>
中國信託銀行：822<br>
帳號：provided by email<br>
分行：</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the payment to:<br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶身份證明, 潛水證, 潛水紀錄本, 防曬用品<br>
＊Remember to Bring:</p>
<p class="font_8">- ARC/ID Card (for Coast Guard)<br>
- Certification Card<br>
- Log Book<br>
- Sun Protection</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>*Dive Location may change due to weather conditions</strong></p>
<p class="font_8"><br></p>
<p class="font_8"><u>Schedule:</u></p>
<p class="font_8"><br></p>
<p class="font_8">06:15 Meet at Fun Divers Tw<br>
06:30 Depart Fun Divers Tw<br>
07:30 Meet at Port<br>
08:00 Boat Departs<br>
12:00 Boat Returns<br>
12:30 Wash Gear/Shower<br>
13:30 Lunch<br>
14:30 Depart for Taipei<br>
15:30 Arrive Fun Divers Tw<br>
&nbsp;<br>
臨時取消行程之賠償金額 Cancellation Fee<br>
• 15天前取消，行程費用之25% － 25% of trip price within 15 days of the trip<br>
• 10天前取消，行程費用之50% － 50% of trip price within 10 days of the trip<br>
• 7天前取消，不予以退費 － Within 7 days of trip price, there will be no refund</p>', 'Advanced and Nitrox Certification Required', NULL, 'Aug 22', '3,200 NTD', '2021-08-21 20:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('a324e698-b857-41e7-ab6b-8d03d31b04b1', 'Long Dong Bay', NULL, NULL, NULL, '2020-08-10 09:16:26+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/long-dong-bay/jul-31', 'Local Fun Diving', 'wix:image://v1/b37fef_546a01d581dc41dbaaf20a0543c8b6c4~mv2.jpg/Peacock%20mantis%20shrimp.jpg#originWidth=4008&originHeight=3008', '<p class="font_8">We will be exploring Long Dong Bay and enjoying the beautiful scenery above and below the water!</p>', '<p class="font_8">Come check out the beauty of Long Dong Bay with Fun Divers Tw!</p>', NULL, '<p class="font_8">Come out and explore Long Dong Bay with Fun Divers Tw!</p>
<p class="font_8"><br></p>
<p class="font_8">Notes:<br>
We will be leaving Fun Divers at 8:30 am. Be sure to bring your swimsuit, towel, snacks, sunscreen and logbooks.</p>
<p class="font_8"><br></p>
<p class="font_8">Price is 1600NTD and includes transportation, 2 tanks, Full Coverage Dive Insurance and dive guide.</p>
<p class="font_8"><br></p>
<p class="font_8">Equipment rental is 1200NTD</p>
<p class="font_8"><br></p>
<p class="font_8">＊請儘早匯入全額費用以確保您的名額<br>
Please transfer the total amount As Soon As Possible to confirm your seat.<br>
<br>
Please transfer payments to:<br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
<br>
Space is limited, so book early!</p>', NULL, NULL, 'Jul 31', '1,600ntd', '2022-07-30 16:00:00+00', NULL, false, NULL, 'b7f7246e-3607-4c4d-b228-b1ee852c758c', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('d6919b8b-afd3-43e1-a45c-d6ee5c7c331a', 'Badouzi AM 2 BD EANx', 'Transportation(if needed), Local Diving Insurance, 2 Boat Dives, 2 Nitrox Tanks, Dive Guide', 'Gear Rental, Food/Drinks', NULL, '2019-05-15 07:33:10+00', '2026-04-09 08:35:18+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'Local Boat Diving', 'wix:image://v1/b37fef_180ce15d03e24b0694ce1100c9bdd345~mv2.jpg/Badouzi%20and%20the%20Boat.jpg#originWidth=800&originHeight=450', '<p class="font_8">Fun Divers Tw is heading out to Badouzi Harbor to do some boat diving!&nbsp; Come Explore some of the amazing off-shore dive sites with us and see why we love diving there so much.&nbsp; We will be doing 2 boat dives at 2 different sites.</p>', '<p class="font_8">Explore some of the local dive sites not reachable from shore! See wrecks, artificial reefs and natural reefs with abundant sea life!</p>', 'Explore some of the local dive sites not reachable from shore! See wrecks, artificial reefs and natural reefs with abundant sea life!', '<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">厭倦了岸潛需要背上背下裝備嗎？來參加我們的八斗子船潛行程吧~<br>
Tired of the heavy lifting on shore dives?<br>
Come explore the outer reaches of Badouzi Bay by Boat<br>
<br>
費用包含：<br>
交通，保險 ，船潛兩支， 兩支氣瓶，潛導<br>
Included: Transportation(if needed), Travel Insurance, 2 Boat Dives, 2 Nitrox Tanks, Dive Guide<br>
</span><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif"><strong>團費 Tour Price:</strong></span><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif"> $3,200<br>
<br>
</span><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif"><strong>額外費用 Additional:</strong></span><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif"><br>
一天裝備租借 Full Equipment Rental: $1000<br>
<br>
＊ 請儘早匯入訂金$2,000 ，餘款9/14前完成匯款即可。<br>
Please transfer a $2,000 deposit As Soon As Possible to confirm your seat.<br>
The remaining balance must be paid on September 14th when we meet.<br>
<br>
Please transfer the deposit to:<br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
<br>
</span><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif"><strong>＊記得攜帶防曬用品,浮力袋(船潛必備),電腦表<br>
＊Remember to Bring:</strong></span></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">-ID Card (for Coast Guard)<br>
- Certification Card<br>
- Log Book<br>
- Surface Marker Buoy (SMB) – All divers MUST have<br>
<br>
臨時取消行程之賠償金額 Cancellation Fee<br>
• 10天前取消，行程費用之25% － 25% of trip price within 10 days of the trip<br>
• 7天前取消，行程費用之50% － 50% of trip price within 7 days of the trip<br>
• 5天前取消，不予以退費 － Within 5 days of trip price, there will be no refund</span></p>', 'AOW & Nitrox Certification Required', '06:15 - Meet at Fun Divers
07:30 - Meet at Port
08:00 - Boat Departs
12:00 - Boat Returns (wash gear at port)
12:30 - Depart for Taipei', NULL, '3,200 NTD', '2019-09-13 20:00:00+00', NULL, false, NULL, 'ce562dca-32d5-4d05-8a82-027a55404703', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('a52867fc-f12a-4827-a00c-cea83108fcd7', 'Fun Divers Dive Center', NULL, NULL, NULL, '2022-12-29 06:37:35+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/fun-divers-dive-center/feb-11-or-12', 'Gear Maintenance Course', 'wix:image://v1/b37fef_b1f8b06b7c2e494996f5690e33bd7319~mv2.jpg/Gear%20Course%20Picture_edited.jpg#originWidth=1108&originHeight=1477', '<p class="font_8"><strong>Why ALL divers should take this course:</strong></p>
<p class="font_8"><br></p>
<p class="font_8">· Gain an understanding of how the gear works</p>
<p class="font_8">· Have more trust in your gear</p>
<p class="font_8">· Be able to diagnose and deal with most problems on the spot</p>
<p class="font_8">· Be more self-reliant</p>', '<p class="font_8">Learn how to check and maintain your own gear with Fun Divers Tw!</p>', NULL, '<p class="font_8">Fun Divers is running a Gear Maintenance Course for divers that want to learn how to check and maintain their own gear.</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Topics include:</strong></p>
<p class="font_8"><br></p>
<p class="font_8">· Checking and Adjusting Regulator Air Flow</p>
<p class="font_8">· Troubleshooting Common Problems with Gear</p>
<p class="font_8">· Proper Cleaning and Lubricating Techniques</p>
<p class="font_8">· Showing and Explaining Internal and External Parts of Regulators and BCDs</p>
<p class="font_8">(this is <strong>NOT</strong> a certification course, we will <strong>NOT</strong> be servicing internal parts of regs)</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Why ALL divers should take this course:</strong></p>
<p class="font_8"><br></p>
<p class="font_8">· Gain an understanding of how the gear works</p>
<p class="font_8">· Have more trust in your gear</p>
<p class="font_8">· Be able to diagnose and deal with most problems on the spot</p>
<p class="font_8">· Be more self-reliant</p>
<p class="font_8"><br></p>
<p class="font_8">Cost: $2800 for workshop with instructor</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Notes:</strong></p>
<p class="font_8"><br></p>
<p class="font_8">Bring your own BCD and Regulators if you have them! If you don’t, you can work with our gear!</p>
<p class="font_8"><br></p>
<p class="font_8">Learn Scuba Diving with Fun Divers Dive Center!<br>
Taipei’s Number 1 Foreigner Run, PADI Dive Shop<br>
 今年夏天來成為合格的PADI潛水員吧！</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Please transfer the deposit to:</strong></p>
<p class="font_8">FunDivers CTBC Bank</p>
<p class="font_8">Bank code: 822</p>
<p class="font_8">Account: provided by email</p>
<p class="font_8">Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!</p>
<p class="font_8">中國信託銀⾏：822</p>
<p class="font_8">帳號：provided by email</p>
<p class="font_8">分⾏：</p>', 'Open To All ', NULL, 'Feb 11 or 12', '2800NTD', '2023-02-11 04:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('a9edd94c-31ae-48f2-87ff-759dc73852a2', 'Bat Cave', NULL, NULL, NULL, '2021-08-31 07:03:01+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/bat-cave/jul-16', 'Local Fun Diving', 'wix:image://v1/b37fef_affd0515ef5a4deb86ecebc31453de1a~mv2.jpg/PA173739.JPG#originWidth=4000&originHeight=3000', '<p class="font_8">Fun Divers will be heading out to Batcave to do some fun diving. &nbsp;Explore the rock formations and search for nudibranchs and cuttlefish at one of our favorite sites!</p>', '<p class="font_8">Explore the rock formations and search for nudibranchs at Batcave!</p>', NULL, '<p class="font_8">Come out and explore Bat Cave with Fun Divers Tw!</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Notes:</strong><br>
 We will be leaving Fun Divers at 8:30am. Be sure to bring your swimsuit, towel, snacks, sunscreen and logbooks.</p>
<p class="font_8"><br></p>
<p class="font_8">Price is 1400NTD and includes transportation, Full Coverage Dive Insurance, 2 tanks, and dive guide.</p>
<p class="font_8"><br></p>
<p class="font_8">Equipment rental is 1200NTD</p>
<p class="font_8"><br></p>
<p class="font_8">＊請儘早匯入全額費用以確保您的名額<br>
Please transfer the total amount As Soon As Possible to confirm your seat. <br>
 <br>
Please transfer payments to: <br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
 <br>
 Space is limited, so book early!</p>', 'Open Water Certified (or higher)', NULL, 'Jul 16', '1400 NTD', '2022-07-15 16:00:00+00', NULL, false, NULL, '1e1be45b-6ba5-4334-82ef-8331ee24c641', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('adf69494-429f-4321-a585-38788d7f2e64', 'Bat Cave', NULL, NULL, NULL, '2019-03-14 04:21:55+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/bat-cave/2024-03-29', 'Ocean & Beach Cleanup', 'wix:image://v1/b37fef_168aec18fa5646b2bf5f451480d6b857~mv2_d_4026_3008_s_4_2.jpg/P7212378.jpg#originWidth=4026&originHeight=3008', '<p class="font_8 p1"><span style="font-family: corben, serif">Come with Fun Divers Tw as we do our part to clean the ocean and beaches. &nbsp; Fun Divers Tw is heading to Bat Cave to do an Ocean and Beach Clean-up.&nbsp; Scuba Divers and Non-divers alike are welcome to join and help us make our Earth a cleaner place!</span></p>', '<p class="p1"><span style="font-family:corben,serif">Come with Fun Divers Tw as we do our part to clean the ocean and beaches.</span></p>', NULL, '<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Be an ambassador, do your part, come help us remove trash from the ocean that brings us so much joy!<br>
<br>
Limited transportation available, so if you need a ride to the dive site, book early!<br>
<br>
When:<br>
Meet at Fun Divers at 8:45<br>
<br>
Cost:<br>
Diving - 1000ntd (includes transportation, dive guide and tanks)<br>
Equipment rental - 50% off (Full set is normally 1000ntd)</span></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">&nbsp;</span></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">RSVP early since there are limited spots available.</span></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">＊請儘早匯入全額費用以確保您的名額<br>
Please transfer the total amount As Soon As Possible to confirm your seat.<br>
<br>
Please transfer payments to:<br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
<br>
Be sure to bring sunscreen, snacks, water, and swimsuit.<br>
<br>
If you have any other questions or for courses and other events, please feel free to send us a message!<br>
<br>
See you in the water!</span></p>', 'Divers and Non-Divers welcome!', NULL, '2024-03-29', '1,400 NTD ', '2019-10-18 16:00:00+00', NULL, true, NULL, '1e1be45b-6ba5-4334-82ef-8331ee24c641', true, NULL) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('b70672ce-cb8c-4ce2-81b1-31f219f6b204', 'Kenting', NULL, NULL, NULL, '2021-09-24 05:48:35+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/kenting/sep-23-25', 'Multi-Day Fun Diving Trip', 'wix:image://v1/b37fef_c311277ae1824a88a42d551d763f5120~mv2_d_4608_2592_s_4_2.jpg/Kenting%20Jan%202019A%20(77).JPG#originWidth=4608&originHeight=2592', '<p class="font_8">A trip to Kenting to explore the underwater world at the southern tip of Taiwan.&nbsp; We may also take some time to explore the surrounding area and do some sightseeing.</p>', '<p class="font_8">A great place for diving as well as exploring above the water.&nbsp; We will check out some of the great dive sites there, swim with blue spotted stingrays, turtles and batfish.&nbsp; Then, we will visit some of the beaches and the nightmarket as well!</p>', NULL, '<p class="font_8"><strong>費用包含：</strong><br>
兩晚, 早餐x 2, 中餐x 2, 晚餐x 1, 船潛x 6, 兩天潛水險<br>
<strong>Included:</strong><br>
2 Nights Room, 2 Breakfasts, 2 Lunches, 1 Dinner, 6 Boat Dives, 2 Days Full Diving Insurance.<br>
<br>
<strong>團費 Tour Price:</strong><br>
背包房 Bunk Bed: $12,400<br>
雙人房 Double Bed: $13,000 (double occupancy)</p>
<p class="font_8">單人房 Single Room: $15,500<br>
<br>
<strong>額外費用Additional Things to Consider:</strong><br>
全套裝備租借(含電腦錶和浮力棒) Full Equipment Rental: $1600 x 2 days</p>
<p class="font_8">(includes Dive Computer and SMB)</p>
<p class="font_8">台北墾丁來回交通費Return Transport: $1600<br>
<br>
<strong>課程Course Discounts:</strong><br>
高氧課程 Enriched Air Nitrox Specialty $6,000 (原價 Normal Price $6,600)</p>
<p class="font_8">深潛課程 Deep Dive Specialty $5,200 (原價 Normal Price $6,200)</p>
<p class="font_8">進階課程 Advanced Open Water $11,000 (原價 Normal Price $12,200)</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>＊ 請於匯入訂金$8,000 Please transfer $8,000 deposit to confirm your booking.</strong></p>
<p class="font_8"><strong>餘款需於09/10 付清 The remaining balance must be paid by 09/10.</strong></p>
<p class="font_8"><br></p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!<br>
中國信託銀行：822<br>
帳號：provided by email</p>
<p class="font_8">分行：</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the deposit to:<br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
Branch: provided by email<br>
<br>
<br>
<strong>行程Approximate Itinerary:<br>
</strong><br>
<strong>Day 1</strong></p>
<p class="font_8">18:30 Fun Divers Dive Center<br>
00:00 墾丁 Kenting</p>
<p class="font_8"><br></p>
<p class="font_8"><strong>Day 2</strong></p>
<p class="font_8">07:00 起床 Wake up<br>
07:30 早餐 Breakfast<br>
08:00 船潛兩支 2 boat dives<br>
12:00 中餐 Lunch<br>
13:00 船潛兩支 2 boat dives<br>
18:00 晚餐 Dinner<br>
<br>
<strong>Day 3</strong></p>
<p class="font_8">07:00 起床 Wake up<br>
07:30 早餐 Breakfast<br>
08:00 船潛兩支 2 boat dives<br>
12:00 中餐 Lunch<br>
13:00 打包行李 Pack up<br>
14:00 回台北 Drive back to Taipei<br>
<br>
＊額外之餐費與娛樂費用請自理<br>
＊Additional Food, Drinks &amp; Entertainment are NOT included<br>
<br>
＊記得攜帶 Remember to Bring:<br>
- 證照卡 Certification Card<br>
- 潛水日誌 Log Book<br>
- 電腦表 Dive Computer<br>
- 浮力棒 (SMB) Surface Marker Buoy<br>
- 暈船藥 Seasick Pills<br>
- 防賽 Sun Protection<br>
<br>
<u>臨時取消行程之賠償金額Cancellation Fee</u></p>
<p class="font_8"><u>· 14天前取消，行程費用之25% － 25% of Deposit within 14 days of the trip</u></p>
<p class="font_8"><u>· 10天前取消，行程費用之50% － 50% of Deposit within 10 days of the trip</u></p>
<p class="font_8"><u>· 07天前取消，不予以退費 － Within 7 days of trip, there will be no refund</u></p>', 'Advanced Certification Recommended', NULL, 'Sep 23-25', 'Starting at 12,400', '2022-09-22 16:00:00+00', '52224a76-927a-4e3e-8c52-2d34afacbdf0', false, NULL, NULL, NULL, true) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('c9c1c467-bdca-4388-89d7-1a1f1eae96f5', 'Kenting', NULL, NULL, NULL, '2019-10-29 14:59:06+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'Multi-Day Fun Diving Trip', 'wix:image://v1/b37fef_c311277ae1824a88a42d551d763f5120~mv2_d_4608_2592_s_4_2.jpg/Kenting%20Jan%202019A%20(77).JPG#originWidth=4608&originHeight=2592', '<p><span style="color:#414141"><span style="font-style:normal"><span style="font-weight:400"><span style="font-size:17px"><span style="font-family:corben,serif">A trip to Kenting to explore the underwater world at the southern tip of Taiwan.&nbsp; We will also take some time to explore the surrounding area and do some sightseeing.</span></span></span></span></span></p>', '<p><span style="color:#414141"><span style="font-style:normal"><span style="font-weight:400"><span style="font-size:17px"><span style="font-family:corben,serif">A great place for diving as well as exploring above the water.&nbsp; We will check out some of the great dive sites there, swim with blue spotted stingrays, turtles and batfish.&nbsp; Then, we will visit some of the beaches and the nightmarket as well!</span></span></span></span></span></p>', NULL, '<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">費用包含：<br>
早餐x 2, 中餐x 2, 晚餐x 1, 船潛x 4, 住宿兩晚<br>
Included:<br>
2 Nights Shared Room, 2 Breakfasts, 2 Lunches, 1 Dinner, 4 Boat Dives.<br>
<br>
團費 Tour Price:<br>
背包房 Capsule Bed $9,800<br>
雙人房 Double Bed $11,500<br>
Non- Diver $5,800</span></p>
<p class="font_8 p1">&nbsp;</p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">額外費用 Additional Things to Consider:<br>
兩天全套裝備租借 Full Equipment Rental: $2000<br>
台北墾丁來回交通費 Return Transport: $1600<br>
<br>
課程 Course Discounts:<br>
<br>
高氧課程 $4,700 (原價 $5,500) -- Enriched Air Nitrox Specialty $5,200 (Normal $6,000)</span></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">深潛課程 $4,500 (原價 $5,500) -- Deep Dive Specialty $5,000 (Normally $6,000)</span></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">進階課程 $8,000 (原價 $9,900) -- Advanced Open Water $8,500 (Normally $10,400)</span></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">初級課程 $10,500 (原價 $13,900) -- Open Water Course $11,000 (Normally $14,400)</span></p>
<p class="font_8 p1"><br></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">＊ 請於匯入訂金$8,000 Please transfer $8,000 deposit to confirm your booking.</span></p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">餘款需於12/6付清 The remaining balance must be paid by December 6th.</span></p>
<p class="font_8 p1">&nbsp;</p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">匯款帳號如下，匯款完畢,請私訊FunDivers哦!<br>
中國信託銀行：822<br>
帳號：provided by email</span></p>
<p class="font_8 p1">&nbsp;</p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Please transfer the deposit to:<br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email</span></p>
<p class="font_8 p1">&nbsp;</p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">行程 Approximate Itinerary:</span></p>
<p class="font_8 p1">&nbsp;</p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Dec 6th (Fri)<br>
18:30 Fun Divers Dive Center<br>
00:00 墾丁 Kenting</span></p>
<p class="font_8 p1">&nbsp;</p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Dec 7th (Sat)<br>
07:00 起床 Wake up<br>
07:30 早餐 Breakfast<br>
08:00 船潛兩支 2 boat dives<br>
12:00 中餐 Lunch<br>
13:00 自由時間 Free time (Go to Kenting Street, Beach…)<br>
18:00 晚餐 Dinner</span></p>
<p class="font_8 p1">&nbsp;</p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">Dec 8th (Sun)<br>
07:00 起床 Wake up<br>
07:30 早餐 Breakfast<br>
08:00 船潛兩支 2 boat dives<br>
12:00 中餐 Lunch<br>
13:00 打包行李 Pack up<br>
14:00 回台北 Drive back to Taipei</span></p>
<p class="font_8 p1">&nbsp;</p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">＊額外之餐費與娛樂費用請自理<br>
＊Additional Food, Drinks &amp; Entertainment are NOT included</span></p>
<p class="font_8 p1">&nbsp;</p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">＊記得攜帶 Remember to Bring:<br>
- 證照卡 Certification Card<br>
- 潛水日誌 Log Book<br>
- 身份證(供海巡做身份驗證) ARC / ID Card for the coast guard<br>
- 浮力棒 (SMB) Surface Marker Buoy (Highly Suggested)<br>
- 浴巾 Towel<br>
- 防賽 Sun Protection</span></p>
<p class="font_8 p1">&nbsp;</p>
<p class="font_8 p1"><span style="font-family: avenir-lt-w01_35-light1475496, sans-serif">臨時取消行程之賠償金額 Cancellation Fee<br>
• 14天前取消，行程費用之25% － 25% of trip price within 14 days of the trip<br>
• 10天前取消，行程費用之50% － 50% of trip price within 10 days of the trip<br>
• 7天前取消，不予以退費 － Within 7 days of trip price, there will be no refund</span></p>', 'Advanced Certification Recommended', NULL, NULL, '9,800 NTD', '2019-12-05 16:00:00+00', '52224a76-927a-4e3e-8c52-2d34afacbdf0', false, NULL, NULL, NULL, true) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('e60cef1a-6f94-40e7-a480-9b1f1ce38004', 'Orchid Island', NULL, NULL, NULL, '2020-05-25 00:53:04+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', '/DiveTravel/orchid-island/may-05-08', 'Multi-Day Dive Trip', 'wix:image://v1/b37fef_4a6d3d96a1994fe08f5730a938a4c88d~mv2.jpg/320547905_1220142575584864_5730544204671620220_n.jpg#originWidth=1224&originHeight=816', '<p class="font_8">A dive trip to explore the crystal clear waters of Orchid Island. &nbsp;We will be exploring amazing wrecks, reefs and pinnacles! &nbsp;We will also explore this remote island above the water as well!</p>', '<p class="font_8">Come dive the crystal clear waters of Orchid Island and see why this is rated one of the best spots for diving in Taiwan!</p>', NULL, '<p class="font_8">2023 May 05-08 Orchid</p>
<p class="font_8"><u><strong>蘭嶼 Orchid Island</strong></u></p>
<p class="font_8"><br></p>
<p class="font_8">Come see the spectacular Orchid Island and enjoy the clear water and amazing sea life!</p>
<p class="font_8"><br></p>
<p class="font_8">費用包含：</p>
<p class="font_8">來回船票， 三晚上住宿 ，早餐 x 3，午餐 x 2，晚餐 x 2，機車(兩人一台)，船潛六支，兩天潛水保險。</p>
<p class="font_8"><br></p>
<p class="font_8">Included:</p>
<p class="font_8">Return Ferry, 3 Nights Shared Rooms , 3 Breakfasts, 2 Lunches, 2 Dinners, 3 Days Shared Motorbike, 6 Boat Dives, 2 Days Full Coverage Diving Insurance</p>
<p class="font_8"><br></p>
<p class="font_8">＊額外之餐費與娛樂費用請自理</p>
<p class="font_8">Additional Food, Drinks &amp; Entertainment are NOT included</p>
<p class="font_8"><br></p>
<p class="font_8">團費 Tour Price:</p>
<p class="font_8">四人通舖房Shared Quad Room: $25,500 (4 people in room)</p>
<p class="font_8">雙人房 Double Room: $27,400 (double occupancy)</p>
<p class="font_8">(交通車有16個位子 Total of 16 spots reserved)</p>
<p class="font_8"><br></p>
<p class="font_8">額外費用 Additional:</p>
<p class="font_8">基本裝備租借 Basic Equipment Rental: $1,200 x 2 days</p>
<p class="font_8">全套裝備租借(含電腦錶和浮力棒)Full EquipmentRental: $1600 x 2 days (includes Dive Computer and SMB)</p>
<p class="font_8">台北墾丁來回交通費 Taipei/Kenting Return Transport: $1,600</p>
<p class="font_8"><br></p>
<p class="font_8">課程 Courses:</p>
<p class="font_8">高氧課程 Enriched Air Nitrox Specialty $6,000 (原價 Normal Price $6,600)</p>
<p class="font_8">深潛課程 Deep Dive Specialty $5,200 (原價 Normal Price $6,200)</p>
<p class="font_8">進階課程 Advanced Open Water $11,000 (原價 Normal Price $12,200)</p>
<p class="font_8"><br></p>
<p class="font_8">行程Approximate Itinerary:</p>
<p class="font_8"><br></p>
<p class="font_8">May 5th</p>
<p class="font_8">(As early as possible): 瘋潛水集合 Meet at Fun Divers Dive Center<br>
Evening: 抵達墾丁Arrive in Kenting</p>
<p class="font_8"><br></p>
<p class="font_8">May 6th</p>
<p class="font_8">06:00 早餐 Breakfast</p>
<p class="font_8">06:45 出發 Depart</p>
<p class="font_8">07:30 後壁湖漁港 Houbihu Dock－蘭嶼 Orchid Island</p>
<p class="font_8">09:30 自由時間 Free Time</p>
<p class="font_8">11:30 中餐 Lunch</p>
<p class="font_8">12:30 船潛兩支 2 Boat Dives</p>
<p class="font_8">18:00 晚餐 Dinner</p>
<p class="font_8"><br></p>
<p class="font_8">May 7th</p>
<p class="font_8">07:30 早餐Breakfast</p>
<p class="font_8">08:00 船潛兩支 2 Boat Dives</p>
<p class="font_8">12:00 中餐 Lunch</p>
<p class="font_8">13:00 船潛兩支 2 Boat Dives</p>
<p class="font_8">18:00 晚餐 Dinner</p>
<p class="font_8"><br></p>
<p class="font_8">May 8th</p>
<p class="font_8">07:30 早餐Breakfast</p>
<p class="font_8">09:30 蘭嶼 Orchid Island ─ 後壁湖漁港 Houbihu Dock</p>
<p class="font_8">12:00 離開墾丁 Depart from Kenting</p>
<p class="font_8">19:00 抵達台北 Arrive in Taipei</p>
<p class="font_8"><br></p>
<p class="font_8">＊ 請於匯入訂金$15,000 Please transfer $15,000 deposit to confirm your booking.</p>
<p class="font_8">餘款需於04/25付清 The remaining balance must be paid by 04/25.</p>
<p class="font_8"><br></p>
<p class="font_8">匯款帳號如下，匯款完畢,請私訊FunDivers哦!<br>
 中國信託銀行：822<br>
 帳號：provided by email<br>
 分行：</p>
<p class="font_8"><br></p>
<p class="font_8">Please transfer the deposit to: <br>
FunDivers<br>
CTBC Bank<br>
Bank code: 822<br>
Account: provided by email<br>
Branch: provided by email</p>
<p class="font_8"><br></p>
<p class="font_8">＊記得攜帶Remember to Bring:<br>
- 證照卡 Certification Card<br>
- 潛水日誌 Log Book<br>
- 電腦表 Dive Computer(required) (rental 300/day)<br>
- 浮力棒 (SMB) Surface Marker Buoy(required) (rental 150/day)<br>
- 暈船藥 Seasick Pills<br>
- 防賽 Sun Protection</p>
<p class="font_8">- 大毛巾Towel</p>
<p class="font_8">- 薄夾克Jacket</p>
<p class="font_8"><br></p>
<p class="font_8"><u>臨時取消行程之賠償金額Cancellation Fee</u></p>
<p class="font_8">· 28天前取消，行程費用之25% － 25% of Deposit within 28 days of the trip</p>
<p class="font_8">· 14天前取消，行程費用之50% － 50% of Deposit within 14 days of the trip</p>
<p class="font_8">· 10天前取消，不予以退費 － Within 10 days of trip, there will be no refund</p>', 'Advanced Diver (can do course during trip)', NULL, 'May 05-08', 'Starting at 25,500 NTD', '2023-05-04 16:00:00+00', 'b8d64fe7-d7c2-487a-b4a0-9899d014bb9b', false, 'wix:document://v1/ugd/b37fef_a2ab1951e88b49b085805bff32b3d0dd.docx/Orchid%20Island%20May%202023.docx', NULL, NULL, true) ON CONFLICT DO NOTHING;
INSERT INTO public."DiveTravel" VALUES ('fc241464-c7ff-44d0-8439-6f3b8ea4c350', 'Fun Divers Dive Center', NULL, NULL, NULL, '2019-05-15 07:25:54+00', '2026-04-09 08:14:51+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572', NULL, 'PADI EFR Course', 'wix:image://v1/b37fef_3970088889d24834a7ab01a1fca962b6~mv2.jpg/EFR_print_05(1).jpg#originWidth=1200&originHeight=900', '<p class="p1"><span style="font-family:corben,serif">In the <span style="text-decoration:underline"><a href="https://www.fundiverstw.com/Courses/PADI-EFR-Course">PADI EFR Course</a></span>, you will learn how to administer basic first aid as well as how to perform CPR properly.&nbsp; You will also be taught how to use an Automated External Defibrillator (AED).&nbsp; The PADI EFR Course is the equivalent of the Red Cross First Aid Certification and is recognized worldwide.</span></p>', '<p class="p1"><span style="font-family:corben,serif">Discover simple to follow steps for emergency care. This course focuses on building confidence in lay rescuers and increasing their willingness to respond when faced with a medical emergency in a non-stressful learning environment.&nbsp; You don&#39;t have to be a diver to take this course.</span></p>', NULL, '<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif;">Do you know what to do if someone is injured or not breathing?&nbsp; Learn how to perform CPR and handle emergency situations confidently!&nbsp; Take the PADI Emergency First Responder (EFR) Course with Fun Divers Tw!</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif;"><span class="wixGuard">​</span></span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif;">In the PADI EFR Course, you will learn how to administer basic first aid as well as how to perform CPR properly.&nbsp; You will also be taught how to use an Automated External Defibrillator (AED).&nbsp; The PADI EFR Course is the equivalent of the Red Cross First Aid Certification and is recognized worldwide.&nbsp;</span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif;">Course Price:&nbsp; 5800 NTD</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif;">&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; Get a discount if you sign up with a friend!</span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif;">Upcoming Course Schedule:&nbsp;&nbsp;</span></p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif;">December 29th, 12-4 pm</span></p>

<p class="p1">&nbsp;</p>

<p class="p1"><span style="font-family:avenir-lt-w01_35-light1475496,sans-serif;">See more details about the PADI EFR Course on our <a href="https://www.fundiverstw.com/Courses/PADI-EFR-Course">website</a>!</span></p>

<p class="p1"><br />
<span style="font-family:avenir-lt-w01_35-light1475496,sans-serif;">Please transfer the total amount to confirm your spot in the class.&nbsp; Notify Fun Divers Tw when the transfer is complete.<br />
<br />
Please transfer payments to:<br />
FunDivers<br />
CTBC Bank<br />
Bank code: 822<br />
Account: provided by email</span><br />
&nbsp;</p>', 'Open to all (divers and non-divers welcome)', NULL, NULL, '5,800 NTD', '2019-12-28 18:00:00+00', NULL, false, NULL, NULL, true, NULL) ON CONFLICT DO NOTHING;


--
-- Data for Name: TravelDestinations; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public."TravelDestinations" VALUES ('b718703b-b6d6-43ff-b56e-f886ed67d9c5', 'Lambai Island', '/traveldestinations/lambai-island', 'Xiao Liuqiu/Lambai is a large Coral Island. Due to its nesting beach, it is home to hundreds of green sea turtles that both snorkelers and Divers can enjoy.', 'Taiwan', NULL, 1, 22.34, 120.44, NULL, NULL, 'wix:image://v1/b37fef_1bd8b45dfdd84c2092af24957897caf6~mv2.jpg/P7010807_edited.jpg#originWidth=845&originHeight=1062', 'wix:image://v1/b37fef_0dbc54b500c1469ebddb0aa25bb616a2~mv2.jpg/P1010338_edited.jpg#originWidth=1883&originHeight=576', 'Open water diver (Advanced certification and SMB are recommended for all boat diving)', '2019-01-26 09:05:58+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('52224a76-927a-4e3e-8c52-2d34afacbdf0', 'Kenting', '/traveldestinations/kenting', 'Kenting has been a top dive destination in Taiwan for decades. It is best known for its myriad of corals that are plastered atop the reef.', 'Taiwan', NULL, 2, 21.9, 120.7, NULL, NULL, 'wix:image://v1/b37fef_87e95d0417b44597b86897cf2825a07f~mv2.jpg/nudi%20purple%20orange%20white_edited.jpg#originWidth=1167&originHeight=1428', 'wix:image://v1/b37fef_d942279a944e4400b470554326dfebd0~mv2.jpg/PA030126_edited.jpg#originWidth=1882&originHeight=797', 'Open water diver (Advanced certification and SMB are recommended for all boat diving)', '2019-01-26 09:05:58+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('6c8ea96c-afb2-4244-9f3e-a2e6cd040788', 'Green Island', '/traveldestinations/green-island', 'Green Island is located off the coast of Taitung, on the southeast coast of Taiwan. It is a favorite dive destination for many locals. Renowned for its impressive visibility, which can reach up to 30-40m, it is ideal for photography enthusiasts.', 'Taiwan', NULL, 3, 22.67620740507185, 121.47133243884599, NULL, NULL, 'wix:image://v1/b37fef_60f0aee8faef48e7bd0853c51f83f84a~mv2.jpg/dennis%20and%20mailbox.jpg#originWidth=4008&originHeight=3008', 'wix:image://v1/b37fef_53e97ce36e174ccf9fcc03bfed72c939~mv2.jpg/P1300147_edited.jpg#originWidth=1883&originHeight=632', 'Open water diver (Advanced certification and SMB are recommended for all boat diving)', '2019-01-27 14:56:34+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('b2c76485-d2b5-4be1-a47a-84e109020ed1', 'Palau', '/traveldestinations/palau', 'Palau is an archipelago located in Micronesia, in the western Pacific Ocean. It is a world-class diving experience that draws divers from all over the globe. It is a top ten destination and a must-see for all avid divers.', 'Palau', NULL, 4, NULL, NULL, true, NULL, 'wix:image://v1/b37fef_9298b088838f4473a34fb0404021de71~mv2.jpg/FD%20Plane.jpg#originWidth=1883&originHeight=1062', 'wix:image://v1/b37fef_7844696823294ad6851a97028f1694b5~mv2.jpg/gray%20reef%20shark%20Palau.jpg#originWidth=1024&originHeight=768', 'Open water diver (Advanced certification and SMB are recommended for all boat diving)', '2020-01-16 04:14:55+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('1a7fefc1-dbd4-4ef8-bcc3-aff99e098558', 'Penghu', '/traveldestinations/penghu', 'Of all the dive locations in Taiwan, Penghu has the most fish in numbers, size, and diversity! If you have the experience and time, it’s a definite must-see!', 'Taiwan', NULL, 5, 23.25, 119.5, NULL, NULL, 'wix:image://v1/b37fef_c3c0324de5bb47b49843a8f63551b4e7~mv2.jpg/Penghu%20Hearts%20enhanced.jpg#originWidth=1734&originHeight=1301', 'wix:image://v1/b37fef_140ba06f950d4da6b30f5775b9b7649d~mv2.jpg/P1010595_edited.jpg#originWidth=1883&originHeight=823', 'Advanced diver with 50 dives experience and able to use a DSMB.', '2021-01-10 12:42:18+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('b8d64fe7-d7c2-487a-b4a0-9899d014bb9b', 'Orchid Island', '/traveldestinations/orchid-island', 'Orchid Island is best known for the Badai Wreck, a Korean lumber-carrying vessel that starts at 26m and descends to 40m deep.', 'Taiwan', NULL, 6, 22.02, 121.6, NULL, NULL, 'wix:image://v1/b37fef_51df0bc6686a40829cad1eb790acb3cf~mv2.jpg/Orchid%20Island%20Boats.jpg#originWidth=1024&originHeight=685', 'wix:image://v1/b37fef_d207e4580aa545bcbe41dd581620272e~mv2.jpg/P5070145.jpg#originWidth=1883&originHeight=1062', 'Open water diver (Advanced and Deep certification and SMB are recommended for all boat diving)', '2021-02-07 11:07:16+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('641708ec-f466-4225-9160-5ba10051432b', 'Tubbataha', '/traveldestinations/tubbataha', NULL, 'The Philippines', NULL, 7, NULL, NULL, true, NULL, NULL, NULL, 'Open water diver (Advanced certification and SMB are recommended for all boat diving)', '2025-02-11 03:04:08+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('c766531e-7560-4cff-917f-f51c8ce472a0', 'Anilao', '/traveldestinations/anilao', 'Just a few hours from Manila, in the Batangas Province, lies Anilao. Anilao has long been considered one of the best diving spots in the Philippines, attracting both beginners and experienced divers. The proximity to Manila is one of the reasons Anilao has become such a popular destination for both local and international divers.', 'The Philippines', NULL, 8, NULL, NULL, true, NULL, 'wix:image://v1/b37fef_75d44200c3b74bdf862662f4d9bb41c3~mv2.jpg/20230124_080229-Longtail%20Boat-Anilao.jpg#originWidth=3964&originHeight=2230', 'wix:image://v1/b37fef_910b82e1e0914504b8ae73cfd1ce8bf4~mv2.jpg/P1251018-Peacock%20Mantis%20Shrimp-Anilao.jpg#originWidth=3638&originHeight=2046', 'Open water diver (Advanced certification and SMB are recommended for all boat diving)', '2025-02-11 03:04:08+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('057b98dc-6d82-40ac-be20-c49e81387ddc', 'Puerto Galera', '/traveldestinations/puerto-galera', 'Puerto Galera is a top dive destination in the Mindoro Province of the Philippines.  It offers exciting nightlife and restaurants serving Western or Filipino cuisine. ', 'The Philippines', NULL, 9, NULL, NULL, true, NULL, 'wix:image://v1/b37fef_b44cd4fc93024ca686aedca9e5fda4b9~mv2.jpg/S__39518252_0.jpg#originWidth=4032&originHeight=3024', 'wix:image://v1/b37fef_2de7ba238022402a87425187c6ef1375~mv2.jpg/S__39518251_0.jpg#originWidth=4032&originHeight=3024', 'Advanced Open Water Certification is recommended and Deep Specialty is required to reach some of the deeper sites.', '2025-06-12 03:34:48+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('7fac8c9e-03c8-4ae0-9ac9-94f14747785a', 'Panglao, Bohol', '/traveldestinations/panglao%2C-bohol', 'Panglao is a diver’s paradise with a variety of dive sites and an abundance of sea life!  Located in the Bohol Province of the Philippines, it is on the list of must-see places for all divers!', 'The Philippines', NULL, 10, NULL, NULL, true, NULL, 'wix:image://v1/b37fef_88e3586799e14af8946b2672f6384617~mv2.jpg/S__11411539_0.jpg#originWidth=1570&originHeight=1042', 'wix:image://v1/b37fef_314c4d8b5ff74e39b8d0c56c04c13c8c~mv2.jpg/S__11411536_0.jpg#originWidth=1570&originHeight=1042', 'AOW Certification recommended so you can visit some of the deeper sites. However, there several sites that are accessible to OW certified divers.', '2025-06-12 04:06:56+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('f2ed912b-71f5-4b24-9122-eb00f6a206ae', 'Bat Cave', '/traveldestinations/bat-cave', 'Bat Cave is an excellent site suitable for all experience levels!', 'Taiwan', 'Shore Diving', 11, 25.14, 121.82, NULL, true, 'wix:image://v1/b37fef_f6fcbc5a749741af99c3fef4b8ea7a9d~mv2.jpg/P1010167.jpg#originWidth=1883&originHeight=1062', 'wix:image://v1/b37fef_5262bdc1e0354c11ab24215c34437958~mv2.jpg/P1010330.jpg#originWidth=1883&originHeight=1062', 'All levels of divers', '2025-11-29 10:37:37+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('9cbfd600-7a90-470b-b9c9-93d5efbc3bff', 'Long Dong Bay', '/traveldestinations/long-dong-bay', 'Long Dong Bay has a walk-in ramp that makes it easy for entering and exiting when the conditions are calm. Perfect for beginners and advanced Divers alike.', 'Taiwan', 'Shore Diving', 12, 25.13, 121.93, NULL, true, 'wix:image://v1/b37fef_e2975ca5e18b4669a1f480a8c20ba872~mv2.jpg/P9230208.jpg#originWidth=3464&originHeight=1954', 'wix:image://v1/b37fef_cb6c989d93ac4f2b95577206e0cdb327~mv2.jpg/P9230200.jpg#originWidth=3404&originHeight=1920', 'All levels', '2025-11-29 10:37:37+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('2e0578b9-0572-4d6a-b682-2de69fb4b9a4', 'Secret Garden', '/traveldestinations/secret-garden', 'Secret Garden is a favorite among local divers. With its garden of sea fans, whip, and soft coral. It is truly a must-see site on the Northeast Coast of Taiwan.', 'Taiwan', 'Shore Diving', 13, 25.22, 121.71, NULL, true, 'wix:image://v1/b37fef_1d51bc48dbe64b13974e2e42cc5a0eb0~mv2.jpg/P1010753.jpg#originWidth=1883&originHeight=1062', 'wix:image://v1/b37fef_2c00441033924be09fcc690fa29da304~mv2.jpg/P1010765.jpg#originWidth=1732&originHeight=1155', 'Advanced Certified with shore diving experience', '2025-11-29 10:37:37+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('70c3b0f3-3f03-4349-8dc1-04e362653493', 'Canyons', '/traveldestinations/canyons', 'An interesting site with beatiful slopes, walls, and boulders to explore. ', 'Taiwan', 'Shore Diving', 14, 25.13, 121.91, NULL, true, 'wix:image://v1/b37fef_d9cab6f1c752479098c35ed5d6901280~mv2.jpg/P7190077.jpg#originWidth=4000&originHeight=3000', 'wix:image://v1/b37fef_6057832d6802444c880400ac473e1a9a~mv2.jpg/P8250154.jpg#originWidth=4000&originHeight=3000', 'Advanced Open Water Divers with shore diving experience', '2025-11-29 10:37:37+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('8bc71962-9638-4a30-91a8-817c672ca48b', '82.5', '/traveldestinations/82.5', 'The wall here at 82.5 always has interesting creatures and rock formations to observe.', 'Taiwan', 'Shore Diving', 15, 25.13, 121.9, NULL, true, 'wix:image://v1/b37fef_845ffda9d96b4f24bf1083f369cd850c~mv2.jpg/P1010109.jpg#originWidth=1331&originHeight=751', 'wix:image://v1/b37fef_199df5c07e5f49dda4509a5b73e3e24b~mv2.jpg/P1020651.jpg#originWidth=1732&originHeight=1155', 'Advanced Open Water Divers with shore diving experience', '2025-11-29 10:37:37+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('b2627255-fb70-4193-a686-bc251f0d6340', 'Rainbow Reef', '/traveldestinations/rainbow-reef', 'Located next to Keelung Island, it’s just a 20-minute boat ride from the dock. Rainbow Reef is a spectacular site with 2 pinnacles covered in colorful whip corals.', 'Taiwan', 'Boat Diving', 16, 25.24, 121.69, NULL, true, 'wix:image://v1/b37fef_8b2bae6712a644cfa0464e7420bc3597~mv2.jpg/PA090566.jpg#originWidth=1883&originHeight=1062', 'wix:image://v1/b37fef_1f0c63e9ebd843848753b23ca95f585d~mv2.jpg/P7040241.jpg#originWidth=1331&originHeight=751', 'Advanced Open Water Divers with Enriched Air Nitrox', '2025-11-29 10:37:37+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('adf55491-0aaa-49bd-bf0a-8affba1a0ce0', 'Wan An Jian Navy Wreck', '/traveldestinations/wan-an-jian-navy-wreck', 'Wan An Jian is a massive navy wreck covered in life and surrounded by schools of fish located off the east coast of Taiwan.', 'Taiwan', 'Boat Diving', 17, 24.89, 121.92, NULL, true, 'wix:image://v1/b37fef_e6233d5e9ab746e88cc2054e58642ec5~mv2.jpg/P1010153.jpg#originWidth=1731&originHeight=1154', 'wix:image://v1/b37fef_21175648b3544e82b83b61f178570722~mv2.jpg/Wan%20An%20Jian%202.jpg#originWidth=1883&originHeight=1059', 'Advanced Open Water Divers with Enriched Air Nitrox (Deep Certification Recommended)', '2025-11-29 10:37:37+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('8e938f1a-6a40-442b-97e7-bfbb624e04cf', 'Badouzi Bay: Crystal Temple Wall', '/traveldestinations/badouzi-bay%3A-crystal-temple-wall', 'A 100m stretch of wall starting at 15m down to 30m.', 'Taiwan', 'Boat Diving', 18, 25.19, 121.77, NULL, true, 'wix:image://v1/b37fef_1d060fa54c0a447ebfedc5d6c34f78fc~mv2.jpg/P6260401.jpg#originWidth=1154&originHeight=866', 'wix:image://v1/b37fef_47ae5c5d39cb4212a3a21532c4311514~mv2.jpg/PA058129.jpg#originWidth=4026&originHeight=3008', 'Advanced Open Water Divers with Enriched Air Nitrox', '2025-11-29 10:37:37+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('7476fcb5-6a32-4c66-9c8b-46c0af2af201', 'Iron House 2', '/traveldestinations/iron-house-2', 'Iron House 2 has 2 metal frame structures side by side shaped like square building blocks teeming with life.', 'Taiwan', 'Boat Diving', 19, 25.14, 120.81, NULL, true, 'wix:image://v1/b37fef_60ddb1f8b0a54547a9ce4b45f18c2715~mv2.png/P9280361_edited.png#originWidth=1883&originHeight=562', 'wix:image://v1/b37fef_ee093b88a6734769bb0bbc0a9f49b50f~mv2.jpg/P1010326.jpg#originWidth=1883&originHeight=1062', 'Advanced Open Water Divers with Enriched Air Nitrox (Deep Certification Recommended)', '2025-11-29 10:37:37+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('71077d4f-2d3a-4696-9207-761b81522965', 'Badouzi Bay: Shipwrecks', '/traveldestinations/badouzi-bay%3A-shipwrecks', 'With many shipwrecks sparsely placed in the vicinity of Badouzi Bay, scuba divers have a fantastic opportunity to explore these fishing vessels that have now become artificial reefs.', 'Taiwan', 'Boat Diving', 20, 25.2, 121.74, NULL, true, 'wix:image://v1/b37fef_48516a4e92fa43398e849382d8ae002e~mv2.jpg/Eric%20and%20Cabin.jpg#originWidth=4026&originHeight=3008', 'wix:image://v1/b37fef_fb9cfa8d2dfb4a3baf613ed377271a57~mv2.jpg/Moray%20Closeup.jpg#originWidth=4026&originHeight=3008', 'Advanced Open Water Divers with Enriched Air Nitrox', '2025-11-29 10:37:37+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('5df240ae-05e0-48f3-8772-84cb63c90fc0', 'Cathedral', '/traveldestinations/cathedral', 'The Cathedral is a unique dive site suitable for all levels of Divers and is always full of surprises!', 'Taiwan', 'Boat Diving', 21, 25.06, 121.96, NULL, true, 'wix:image://v1/b37fef_757bf97dabf14263bb215a8b4f7848f8~mv2.jpg/P9280413.jpg#originWidth=1883&originHeight=1062', 'wix:image://v1/b37fef_cf65c102ff75412c9d9e33ef05bcaa72~mv2.jpg/P1010233.jpg#originWidth=1883&originHeight=1062', 'All levels', '2025-11-29 10:37:37+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('2f20780e-0a57-41c3-b941-275e1d2a1d7e', 'Turtle Island', '/traveldestinations/turtle-island', 'Turtle Island is known to Divers for the site called Milky Way, an underwater hot spring. If you get this rare opportunity to dive there, you must try it!', 'Taiwan', 'Boat Diving', 22, 24.84, 121.97, NULL, true, 'wix:image://v1/b37fef_08800163ce0a42eb9cecfbf26133c457~mv2.jpg/PA040357.jpg#originWidth=1882&originHeight=1061', 'wix:image://v1/b37fef_5107772b73ce4473bb57a6b54e2a418d~mv2.jpg/P1010193.jpg#originWidth=1883&originHeight=1062', 'Open Water Divers', '2025-11-29 10:37:37+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('1a4af779-9afb-4d91-87a2-9fbd97d3d2ca', 'Badouzi Bay: Iron House / Iron Reef', '/traveldestinations/badouzi-bay%3A-iron-house-%2F-iron-reef', 'These are artificial reefs made of steel shaped like the framework of houses. Within its confines, reside an array of fish using them as protection from predators such as the amberjacks.', 'Taiwan', 'Boat Diving', 23, 25.19, 121.73, NULL, true, 'wix:image://v1/b37fef_2017559b29b447eea2e1fb906ace863f~mv2.jpg/P6151306.jpg#originWidth=4026&originHeight=3008', 'wix:image://v1/b37fef_c7dfe12c9d3e407b858a980ca15ba8bf~mv2.jpg/Iron%20House%202.jpg#originWidth=2100&originHeight=1400', 'Advanced Open Water Divers with Enriched Air Nitrox', '2025-11-29 10:37:37+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public."TravelDestinations" VALUES ('170af4c1-98ec-4b7a-8a89-fd367343f13f', 'Cauliflower Garden', '/traveldestinations/cauliflower-garden', 'Cauliflower Garden is a charming wall dive with lovely little, colorful, soft corals shaped like cauliflower.', 'Taiwan', 'Boat Diving', 24, 24.92, 121.92, NULL, true, 'wix:image://v1/b37fef_ff042e91927d4e8695e4cbd811fdc2a5~mv2.jpg/P9280363.jpg#originWidth=1883&originHeight=1062', 'wix:image://v1/b37fef_8e1e8049bc504c54ad2835b86630c42c~mv2.jpg/P1010213.jpg#originWidth=1732&originHeight=1155', 'Advanced Open Water Divers with Enriched Air Nitrox', '2025-11-29 10:37:37+00', '2026-04-30 00:27:37+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;


--
-- Data for Name: cancellation_policies; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.cancellation_policies VALUES ('1b76813a-c57c-4c1c-ae87-45a6ed389e47', 'Local Multi-day Trip', 'If diver cancels by the date above, they can get a full refund (minus transfer/bank/PayPal fees) of any payment made above the deposit amount. The deposit, however, is non-refundable. If the trip is canceled by Fun Divers Taiwan for any reason, the diver can choose to reschedule or get a full refund (minus transfer/bank/PayPal fees).', '2026-03-25 07:49:16+00', '2026-03-25 07:59:06+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public.cancellation_policies VALUES ('465f1e26-17d5-4784-b9bd-2c5dd8a36560', 'International Trip', 'If diver cancels by the date above, they can get a full refund (minus transfer/bank/PayPal fees) of any payment made above the deposit amount. The deposit, however, is non-refundable. If the trip is canceled by Fun Divers Taiwan for any reason, and can''t be rescheduled, then the diver can get a full refund (minus transfer/bank/PayPal fees).', '2026-03-25 07:55:28+00', '2026-03-25 07:58:25+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public.cancellation_policies VALUES ('652b34df-4cb7-48ab-91dc-41ae9e2d1f29', 'Local Day Trip', 'If diver cancels by the date above, they can get a full refund (minus transfer/bank/PayPal fees). If the dives are canceled by Fun Divers Taiwan for any reason, the diver can choose to reschedule or get a full refund (minus transfer/bank/PayPal fees).', '2026-03-25 07:49:08+00', '2026-03-25 07:57:48+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public.cancellation_policies VALUES ('7409de8f-dbfd-403d-9db8-3c84721c7717', 'Course without Elearning', 'If student cancels by the date above, they can get a full refund (minus transfer/bank/PayPal fees). If the course is canceled by Fun Divers Taiwan for any reason, the diver can choose to reschedule or get a full refund (minus transfer/bank/PayPal fees).', '2026-03-25 08:07:37+00', '2026-03-25 08:11:26+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;
INSERT INTO public.cancellation_policies VALUES ('8ed8bb2a-abf8-482c-8a34-bf532232b5ce', 'Course with Elearning', 'If diver cancels by the date above, they can get a full refund (minus transfer/bank/PayPal fees) of any payment made above the deposit amount. The deposit, however, is non-refundable. If the course is fully or partially canceled by Fun Divers Taiwan for any reason, and can''t be rescheduled, then the diver can use the PADI E-learning at any PADI shop around the world.  If any course dives were finished, student will also receive a PADI Referral Form which can also be used at any PADI Shop around the world.', '2026-03-25 08:03:44+00', '2026-03-25 08:07:36+00', 'b37fefa3-09b1-4e00-a824-f6b884e43572') ON CONFLICT DO NOTHING;


--
-- Data for Name: cert_levels; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.cert_levels VALUES ('abfe1ba8-e2f7-460a-8246-2cb62120d268', 'instructor', 'Instructor', '教練', 5, '2026-07-01 14:35:02.936225+00', '2026-07-01 14:35:02.936225+00', 'PADI', 'abfe1ba8-e2f7-460a-8246-2cb62120d268') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('095097a8-4053-4d8c-9456-1e1ce4468c04', 'sdi_open_water', 'Open Water Scuba Diver', NULL, 1, '2026-07-01 14:35:03.337304+00', '2026-07-01 14:35:03.337304+00', 'SDI', 'f7596e96-4af7-4e5c-acf5-d26a86b99ce0') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('fbe4375f-9456-4253-8939-f65872ed463a', 'sdi_advanced_adventure', 'Advanced Adventure Diver', NULL, 2, '2026-07-01 14:35:03.337304+00', '2026-07-01 14:35:03.337304+00', 'SDI', 'ca722bec-c490-4034-addc-6d96a1acc523') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('7d752397-6b20-4f29-b8de-05971150e29a', 'sdi_rescue', 'Rescue Diver', NULL, 3, '2026-07-01 14:35:03.337304+00', '2026-07-01 14:35:03.337304+00', 'SDI', '64cbdd3a-11e9-4713-b1f7-651b8b465c62') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('7cb57d57-69fb-41dc-a0f0-d213bb60d91a', 'sdi_master_scuba_diver', 'Master Scuba Diver', NULL, 4, '2026-07-01 14:35:03.337304+00', '2026-07-01 14:35:03.337304+00', 'SDI', '64cbdd3a-11e9-4713-b1f7-651b8b465c62') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('64cbdd3a-11e9-4713-b1f7-651b8b465c62', 'rescue', 'Rescue', '救援潛水員', 3, '2026-07-01 14:35:02.936225+00', '2026-07-01 14:35:02.936225+00', 'PADI', '64cbdd3a-11e9-4713-b1f7-651b8b465c62') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('73c4d9c0-a84a-4d17-a5f6-c7c14f4a91d2', 'sdi_divemaster', 'Divemaster', NULL, 5, '2026-07-01 14:35:03.337304+00', '2026-07-01 14:35:03.337304+00', 'SDI', '2996514c-459a-4265-8244-2642c18c800f') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('fa2ec01e-2cb8-42a7-8073-a517164311f3', 'bsac_ocean_diver', 'Ocean Diver / Club Diver', NULL, 1, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'BSAC', 'f7596e96-4af7-4e5c-acf5-d26a86b99ce0') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('9415a94e-33f2-43d0-b4b6-ee94fe83ddae', 'bsac_sport_diver', 'Sport Diver', NULL, 2, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'BSAC', 'f7596e96-4af7-4e5c-acf5-d26a86b99ce0') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('23996804-2873-4087-8d56-0f9a7ec3141c', 'bsac_sport_diver_20', 'Sport Diver (20+ logged dives)', NULL, 3, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'BSAC', 'ca722bec-c490-4034-addc-6d96a1acc523') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('a71b4f74-0d99-4f65-b64d-09ec48ed1946', 'bsac_dive_leader', 'Dive Leader', NULL, 4, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'BSAC', '64cbdd3a-11e9-4713-b1f7-651b8b465c62') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('6dc33257-90f7-4813-b562-6987e624d1e8', 'bsac_advanced_diver', 'Advanced Diver', NULL, 5, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'BSAC', '2996514c-459a-4265-8244-2642c18c800f') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('1c9dc834-8fd1-4434-9555-a8507e1cc6d6', 'cmas_1_star_diver', '1-Star Diver', NULL, 1, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'CMAS', 'f7596e96-4af7-4e5c-acf5-d26a86b99ce0') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('43c155fa-3848-4aa7-b5f5-4c767efa94f6', 'cmas_2_star_diver', '2-Star Diver (Night & Navigation)', NULL, 2, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'CMAS', '64cbdd3a-11e9-4713-b1f7-651b8b465c62') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('e2399423-af20-4c86-be75-2f0bf349c4cc', 'cmas_3_star_diver', '3-Star Diver', NULL, 3, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'CMAS', '2996514c-459a-4265-8244-2642c18c800f') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('fc6911ee-d1b5-4b35-98a6-4942617ae07f', 'ssi_open_water', 'Open Water Diver', NULL, 1, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'SSI', 'f7596e96-4af7-4e5c-acf5-d26a86b99ce0') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('7c021e5e-8b2f-413d-b3e6-2c00b9fd06e6', 'ssi_advanced_open_water', 'Advanced Open Water Diver', NULL, 2, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'SSI', 'ca722bec-c490-4034-addc-6d96a1acc523') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('eada7d72-b328-4e18-af6c-b78620cbfe3a', 'ssi_stress_rescue', 'Stress & Rescue Techniques', NULL, 3, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'SSI', '64cbdd3a-11e9-4713-b1f7-651b8b465c62') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('6b66520b-117f-4ffe-83a6-d0f968d6b372', 'ssi_master_diver', 'Master Diver', NULL, 4, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'SSI', '64cbdd3a-11e9-4713-b1f7-651b8b465c62') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('ea2f622e-ccc7-4f32-81a4-be9fbe86493e', 'ssi_dive_con', 'Dive Con', NULL, 5, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'SSI', '2996514c-459a-4265-8244-2642c18c800f') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('4d05a46b-fca9-4ffa-a5c3-71bb707d7b23', 'naui_scuba_diver', 'Scuba Diver', NULL, 1, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'NAUI', 'f7596e96-4af7-4e5c-acf5-d26a86b99ce0') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('c5882f9f-bdb4-46fa-9222-d948fe0b9098', 'naui_advanced_scuba_diver', 'Advanced Scuba Diver', NULL, 2, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'NAUI', 'ca722bec-c490-4034-addc-6d96a1acc523') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('0d7273eb-502f-4388-9cfb-ae7f37e3fa0b', 'naui_master_scuba_diver', 'Master Scuba Diver', NULL, 3, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'NAUI', '64cbdd3a-11e9-4713-b1f7-651b8b465c62') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('1d4451d5-8944-429e-af3d-cc621d91e1aa', 'naui_divemaster', 'Divemaster', NULL, 4, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'NAUI', '2996514c-459a-4265-8244-2642c18c800f') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('0049a377-ccc8-4200-b9d5-1ddea6e34902', 'saa_club_diver', 'Club Diver', NULL, 1, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'SAA', 'f7596e96-4af7-4e5c-acf5-d26a86b99ce0') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('de1556c2-2839-4a3e-a835-cfb7dbcd1cc1', 'saa_club_diver_20_deep_nav', 'Club Diver (20+ dives, Deep & Navigation)', NULL, 2, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'SAA', 'ca722bec-c490-4034-addc-6d96a1acc523') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('83187ae2-7513-4e21-821f-e0aee9f75828', 'saa_dive_leader_20', 'Dive Leader (20+ dives)', NULL, 3, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'SAA', 'ca722bec-c490-4034-addc-6d96a1acc523') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('e6a4d496-3f4a-4d69-a22f-613f25297d37', 'saa_dive_leader_rescue', 'Dive Leader (with Diver Rescue)', NULL, 4, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'SAA', '64cbdd3a-11e9-4713-b1f7-651b8b465c62') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('a9774cdd-fe52-4341-aadc-fd26504e0b04', 'saa_dive_supervisor_rescue', 'Dive Supervisor (with Diver Rescue)', NULL, 5, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'SAA', '2996514c-459a-4265-8244-2642c18c800f') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('a686c5c6-32e2-4c03-a579-8ee0a98b4cca', 'bsac_club_instructor', 'Club Instructor', NULL, 6, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'BSAC', 'abfe1ba8-e2f7-460a-8246-2cb62120d268') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('cd1347cc-8d58-4be8-8ac3-50875c76f1e5', 'bsac_open_water_instructor', 'Open Water Instructor', NULL, 7, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'BSAC', 'abfe1ba8-e2f7-460a-8246-2cb62120d268') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('5c70d4a1-33c3-4bff-9da9-cce86df9e087', 'bsac_advanced_instructor', 'Advanced Instructor', NULL, 8, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'BSAC', 'abfe1ba8-e2f7-460a-8246-2cb62120d268') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('fc44ad28-78d0-4bd5-8944-fd18c313ac5b', 'cmas_1_star_instructor', '1-Star Instructor', NULL, 4, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'CMAS', 'abfe1ba8-e2f7-460a-8246-2cb62120d268') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('9d416630-a934-4046-9163-c1e700073cfb', 'cmas_2_star_instructor', '2-Star Instructor', NULL, 5, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'CMAS', 'abfe1ba8-e2f7-460a-8246-2cb62120d268') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('3fd25a16-0f95-439f-93de-88bfc9369a5e', 'ssi_dive_con_instructor', 'Open Water / Dive Con Instructor', NULL, 6, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'SSI', 'abfe1ba8-e2f7-460a-8246-2cb62120d268') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('fc0a38d1-0766-4012-9f94-d66887e1e569', 'naui_scuba_instructor', 'Scuba Instructor', NULL, 5, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'NAUI', 'abfe1ba8-e2f7-460a-8246-2cb62120d268') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('623dbb38-53a7-4766-afef-11001d1508e0', 'saa_assistant_club_instructor_rescue', 'Assistant / Club Instructor (with Diver Rescue)', NULL, 6, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'SAA', 'abfe1ba8-e2f7-460a-8246-2cb62120d268') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('2de12b79-c344-43d8-aaa1-0cb71d51f9eb', 'saa_regional_instructor', 'Regional Instructor', NULL, 7, '2026-07-01 14:35:03.088776+00', '2026-07-01 14:35:03.088776+00', 'SAA', 'abfe1ba8-e2f7-460a-8246-2cb62120d268') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('a5b84874-13fb-4893-bf34-b59f6228cf4a', 'sdi_assistant_instructor', 'Assistant Instructor', NULL, 6, '2026-07-01 14:35:03.337304+00', '2026-07-01 14:35:03.337304+00', 'SDI', '2996514c-459a-4265-8244-2642c18c800f') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('9dc0dd34-9429-4600-9f17-c6c8e7d4ff6a', 'sdi_instructor', 'Open Water Scuba Diver Instructor', NULL, 7, '2026-07-01 14:35:03.337304+00', '2026-07-01 14:35:03.337304+00', 'SDI', 'abfe1ba8-e2f7-460a-8246-2cb62120d268') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('819b2e1c-e3d6-4760-b946-f196b3ea72c1', 'tdi_nitrox', 'Nitrox Diver', NULL, 1, '2026-07-01 14:35:03.337304+00', '2026-07-01 14:35:03.337304+00', 'TDI', 'f7596e96-4af7-4e5c-acf5-d26a86b99ce0') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('5505ef1f-335e-4286-bba0-ae2355e79e9e', 'tdi_intro_to_tech', 'Intro to Tech', NULL, 2, '2026-07-01 14:35:03.337304+00', '2026-07-01 14:35:03.337304+00', 'TDI', 'ca722bec-c490-4034-addc-6d96a1acc523') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('f7596e96-4af7-4e5c-acf5-d26a86b99ce0', 'open_water', 'OW', '開放水域', 1, '2026-07-01 14:35:02.936225+00', '2026-07-01 14:35:02.936225+00', 'PADI', 'f7596e96-4af7-4e5c-acf5-d26a86b99ce0') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('d6dfa0ea-244d-4174-81d0-b000f9decfbb', 'tdi_advanced_nitrox', 'Advanced Nitrox Diver', NULL, 3, '2026-07-01 14:35:03.337304+00', '2026-07-01 14:35:03.337304+00', 'TDI', 'ca722bec-c490-4034-addc-6d96a1acc523') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('49748ff7-e98e-4224-a0b4-d58012afe1ea', 'tdi_decompression', 'Decompression Procedures Diver', NULL, 4, '2026-07-01 14:35:03.337304+00', '2026-07-01 14:35:03.337304+00', 'TDI', '64cbdd3a-11e9-4713-b1f7-651b8b465c62') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('851aa07b-f83b-49a6-8b8f-6e8abc24f956', 'tdi_helitrox', 'Helitrox Diver', NULL, 5, '2026-07-01 14:35:03.337304+00', '2026-07-01 14:35:03.337304+00', 'TDI', '64cbdd3a-11e9-4713-b1f7-651b8b465c62') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('45f16504-3fd7-4371-9d62-ed1903b53466', 'tdi_extended_range', 'Extended Range Diver', NULL, 6, '2026-07-01 14:35:03.337304+00', '2026-07-01 14:35:03.337304+00', 'TDI', '64cbdd3a-11e9-4713-b1f7-651b8b465c62') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('a4a7002b-de33-4bf3-9287-bf11b1427624', 'tdi_trimix', 'Trimix Diver', NULL, 7, '2026-07-01 14:35:03.337304+00', '2026-07-01 14:35:03.337304+00', 'TDI', '2996514c-459a-4265-8244-2642c18c800f') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('ac46292a-6f03-4582-8f90-c6766eb4469e', 'tdi_advanced_trimix', 'Advanced Trimix Diver', NULL, 8, '2026-07-01 14:35:03.337304+00', '2026-07-01 14:35:03.337304+00', 'TDI', '2996514c-459a-4265-8244-2642c18c800f') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('ca722bec-c490-4034-addc-6d96a1acc523', 'advanced_open_water', 'AOW', '進階開放水域', 2, '2026-07-01 14:35:02.936225+00', '2026-07-01 14:35:02.936225+00', 'PADI', 'ca722bec-c490-4034-addc-6d96a1acc523') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('2996514c-459a-4265-8244-2642c18c800f', 'divemaster', 'DM', '潛水長', 4, '2026-07-01 14:35:02.936225+00', '2026-07-01 14:35:02.936225+00', 'PADI', '2996514c-459a-4265-8244-2642c18c800f') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('eecf0d82-c143-4c0d-bc20-435da79b1b42', 'msdt', 'MSDT', NULL, 6, '2026-07-01 14:35:03.361878+00', '2026-07-01 14:35:03.361878+00', 'PADI', 'eecf0d82-c143-4c0d-bc20-435da79b1b42') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('57d8c248-d60d-4346-b83a-af9974006875', 'idc_staff', 'IDC Staff', NULL, 7, '2026-07-01 14:35:03.361878+00', '2026-07-01 14:35:03.361878+00', 'PADI', '57d8c248-d60d-4346-b83a-af9974006875') ON CONFLICT DO NOTHING;
INSERT INTO public.cert_levels VALUES ('e514c92f-da13-4f75-93b3-7a3f58b98ee5', 'course_director', 'Course Director', NULL, 8, '2026-07-01 14:35:03.361878+00', '2026-07-01 14:35:03.361878+00', 'PADI', 'e514c92f-da13-4f75-93b3-7a3f58b98ee5') ON CONFLICT DO NOTHING;


--
-- PostgreSQL database dump complete
--



set session_replication_role = origin;
