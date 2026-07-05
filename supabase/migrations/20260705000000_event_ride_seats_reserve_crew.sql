-- ============================================================
-- event_ride_seats — reserve seats for the crew who ride the fleet
-- ============================================================
-- vehicles.passenger_seats now means a vehicle's TOTAL physical seats (the
-- "Physical seats" relabel + removal of driver assignment). The whole crew
-- travels in the fleet: every on-duty staff member rides (one of them drives
-- each van), each taking a seat. So the seats a diver can claim are the
-- physical seats MINUS the crew's seats. Otherwise divers claim seats the
-- logistics planner (which seats staff first) hands to staff, leaving a diver
-- who was already promised a ride unseated.
--
-- Supersedes the baseline event_ride_seats:
--   reserved = greatest(#vehicles, #on-duty staff)
--     — one driver per van as a floor (robust before duties are assigned),
--       rising to the full staff count once staff outnumber the vans.
--   capacity = greatest(0, sum(passenger_seats) - reserved)
-- claimed is unchanged.

begin;

create or replace function public.event_ride_seats(p_event_id uuid)
returns table (capacity int, claimed int)
language sql security definer set search_path = public as $$
  with fleet as (
    select v.passenger_seats
    from (select distinct vehicle_id from public.event_vehicles where event_id = p_event_id) ev
    join public.vehicles v on v.id = ev.vehicle_id
  ),
  crew as (
    select count(distinct assignee_id)::int as staff_count
    from public.duties
    where event_id = p_event_id
  )
  select
    greatest(
      0,
      coalesce((select sum(passenger_seats)::int from fleet), 0)
        - greatest(
            (select count(*)::int from fleet),
            (select staff_count from crew)
          )
    ) as capacity,
    coalesce((
      select count(*)::int
      from public.bookings
      where status <> 'cancelled'
        and (details->>'transportation') = 'true'
        and event_id = p_event_id
    ), 0) as claimed;
$$;

commit;

notify pgrst, 'reload schema';
