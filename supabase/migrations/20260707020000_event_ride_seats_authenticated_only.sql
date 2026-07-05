-- event_ride_seats returns aggregate ride-seat tallies (capacity/claimed) for an
-- event. The squashed baseline granted EXECUTE to `anon` as well as
-- `authenticated`, exposing seat counts to unauthenticated callers. Restrict it
-- to authenticated only — the registration form reads it as a signed-in diver,
-- and a guest (anon) registrant's fetch fails open (the client catch leaves the
-- ride option available; the server-side gate + ride-waitlist handle a full
-- fleet). Mirrors the app-fundivers intent (authenticated-only).

begin;

-- Functions carry a default EXECUTE grant to PUBLIC that anon inherits, so the
-- explicit anon grant isn't the whole story — revoke PUBLIC (and anon) then
-- re-grant only the intended roles.
revoke execute on function public.event_ride_seats(uuid) from public, anon;
grant  execute on function public.event_ride_seats(uuid) to authenticated, service_role;

commit;

notify pgrst, 'reload schema';
