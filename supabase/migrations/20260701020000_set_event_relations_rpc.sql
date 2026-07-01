-- Transactional replacement for the old string-column write-buffer + sync
-- triggers: the admin app calls this to reconcile an event's junction rows in
-- one round-trip. delete-then-insert matches exactly what the dropped triggers
-- did, but the desired relation set now arrives explicitly from the form.
--
-- SECURITY INVOKER so the existing is_admin() RLS policies on the junction
-- tables (20260501000000 / 20260429220000 / 20260505000000) still gate every
-- write — no elevated privilege here. A bad id fails the junction FK and rolls
-- the whole call back, which is the intended all-or-nothing behavior.
--
-- Column types (verified against the live schema): eo_dive_id / eo_course_id /
-- room_id / addon_id are uuid; destination_id is text.

begin;

create or replace function public.set_event_relations(
  p_event_type      text,
  p_event_id        uuid,
  p_room_ids        uuid[] default '{}',
  p_addon_ids       uuid[] default '{}',
  p_destination_ids text[] default '{}'
) returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if p_event_type = 'dive' then
    delete from public.eo_dive_rooms where eo_dive_id = p_event_id;
    insert into public.eo_dive_rooms (eo_dive_id, room_id)
      select p_event_id, unnest(p_room_ids) on conflict do nothing;

    delete from public.eo_dive_addons where eo_dive_id = p_event_id;
    insert into public.eo_dive_addons (eo_dive_id, addon_id)
      select p_event_id, unnest(p_addon_ids) on conflict do nothing;

    delete from public.eo_dive_destinations where eo_dive_id = p_event_id;
    insert into public.eo_dive_destinations (eo_dive_id, destination_id)
      select p_event_id, unnest(p_destination_ids) on conflict do nothing;

  elsif p_event_type = 'course' then
    delete from public.eo_course_addons where eo_course_id = p_event_id;
    insert into public.eo_course_addons (eo_course_id, addon_id)
      select p_event_id, unnest(p_addon_ids) on conflict do nothing;

  else
    raise exception 'set_event_relations: unknown event type %', p_event_type;
  end if;
end;
$$;

revoke all on function public.set_event_relations(text, uuid, uuid[], uuid[], text[]) from public;
grant execute on function public.set_event_relations(text, uuid, uuid[], uuid[], text[]) to authenticated;

notify pgrst, 'reload schema';

commit;
