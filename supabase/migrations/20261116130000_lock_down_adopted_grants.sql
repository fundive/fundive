-- Brings the grants of a database adopted from another repo to the state a
-- fresh install has. A no-op on a fresh install; on an adopted one it is the
-- only migration in this range that actually runs.
--
-- Why it is needed: adoption (scripts/adopt-existing-deployment.sh
-- --applied-through) records 20260808000000, 20260911100000 and 20260911110000
-- as applied without running them, because the deployment already has their
-- schema. It does not necessarily have their GRANTS. FunDivers production was
-- built from app-fundivers, whose baseline declares locked default privileges,
-- but the cloud project never received them: it kept Supabase's stock defaults
-- (EXECUTE, and table INSERT/UPDATE/DELETE, for anon on everything new in
-- public). Every function created after its baseline was therefore callable by
-- anon over PostgREST, among them purge_stale_pii (no authorization check:
-- scrubs ID numbers, medical notes and emergency contacts for every diver idle
-- past a cutoff the caller picks) and normalize_profile_values.
--
-- Every statement below is idempotent and matches what the earlier migrations
-- leave on a fresh install, at today's function signatures.

revoke all on function public.purge_stale_pii(integer) from public, anon, authenticated;
grant execute on function public.purge_stale_pii(integer) to service_role;

revoke all on function public.normalize_profile_values() from public, anon, authenticated;
grant execute on function public.normalize_profile_values() to service_role;

revoke all on function public.record_signup_attempt(bytea) from public, anon, authenticated;
grant execute on function public.record_signup_attempt(bytea) to service_role;

revoke all on function public.log_orphan_auth_user(uuid, text, text) from public, anon, authenticated;
grant execute on function public.log_orphan_auth_user(uuid, text, text) to service_role;

revoke all on function public.admin_delete_user(uuid) from public, anon;
grant execute on function public.admin_delete_user(uuid) to authenticated;

revoke all on function public.record_group_payment(uuid, numeric, text, uuid) from public, anon;
grant execute on function public.record_group_payment(uuid, numeric, text, uuid) to authenticated;

revoke all on function public.apply_credit_to_booking(uuid, numeric) from public, anon;
grant execute on function public.apply_credit_to_booking(uuid, numeric) to authenticated;

revoke all on function public.accept_waitlist_offer(uuid) from public, anon;
grant execute on function public.accept_waitlist_offer(uuid) to authenticated;

revoke all on function public.create_course_continuation(uuid, uuid, date[], date[], text) from public, anon;
grant execute on function public.create_course_continuation(uuid, uuid, date[], date[], text) to authenticated;

alter default privileges for role postgres in schema public
  revoke all on functions from public, anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant references, trigger, truncate, maintain on tables to anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant update on sequences to anon, authenticated, service_role;

revoke insert, update, delete on all tables in schema public from anon;
