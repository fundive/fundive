-- Security: this repo's squashed baseline handed EXECUTE on every function to
-- `anon`, and the 2026-07-20 hardening pass only clawed back two of them
-- (offer_next_waitlist_spot, refresh_event_display_title). Seven more remained
-- reachable by an unauthenticated caller, because the anon key ships in the
-- public SPA bundle and PostgREST exposes every granted function at
-- /rest/v1/rpc/<name>.
--
-- Six of the seven do gate themselves internally (is_admin(), an auth.uid()
-- comparison), so anon reached them only to be refused. purge_stale_pii did
-- not gate at all:
--
--   POST /rest/v1/rpc/purge_stale_pii  {"older_than_months": 0}
--
-- sets the cutoff to now(), which matches every diver row, and being SECURITY
-- DEFINER it bypasses RLS. One unauthenticated request nulls id_number,
-- medical_notes, emergency_contact_name, emergency_contact_phone and all three
-- cert-card paths across the whole diver base, plus every booking note.
-- Unrecoverable without a backup restore.
--
-- The shop deployment never had this exposure: its baseline revoked
-- purge_stale_pii from PUBLIC. These grants restore parity with it exactly --
-- verified function-by-function against that database, not assumed.
--
-- Keeping `authenticated` on the four diver/admin-facing RPCs matters: they are
-- called from the SPA with a real session, and their internal guards are what
-- authorize them. Revoking PUBLIC also strips service_role, so the two called
-- by edge functions with the service-role client (record_signup_attempt and
-- log_orphan_auth_user, both in create-registration) get it granted back
-- explicitly.

-- Unauthenticated mass-PII destruction. Maintenance only; no client calls it.
revoke all on function public.purge_stale_pii(integer) from public, anon, authenticated;
grant execute on function public.purge_stale_pii(integer) to service_role;

-- Signup rate-limit ledger. Only create-registration writes it, over the
-- service role, with a server-derived IP hash. Left open to anon, a caller
-- could pick a victim's IP hash and spend their signup budget for them.
revoke all on function public.record_signup_attempt(bytea) from public, anon, authenticated;
grant execute on function public.record_signup_attempt(bytea) to service_role;

-- Internal bookkeeping for auth users left behind by a failed registration.
revoke all on function public.log_orphan_auth_user(uuid, text, text) from public, anon, authenticated;
grant execute on function public.log_orphan_auth_user(uuid, text, text) to service_role;

-- Session-backed RPCs: guarded internally, but anon has no business reaching
-- the guard in the first place.
revoke all on function public.admin_delete_user(uuid) from public, anon;
grant execute on function public.admin_delete_user(uuid) to authenticated;

revoke all on function public.record_group_payment(uuid, numeric, uuid) from public, anon;
grant execute on function public.record_group_payment(uuid, numeric, uuid) to authenticated;

revoke all on function public.apply_credit_to_booking(uuid, numeric) from public, anon;
grant execute on function public.apply_credit_to_booking(uuid, numeric) to authenticated;

revoke all on function public.accept_waitlist_offer(uuid) from public, anon;
grant execute on function public.accept_waitlist_offer(uuid) to authenticated;
