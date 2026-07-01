-- Remove the Wix coupling so the platform is operator-agnostic.
--
-- The FunDivers deployment mirrored every catalog write to its Wix marketing
-- site via 8 `wix_sync_*` triggers + the vault-backed `public.wix_sync_notify()`
-- helper (installed by 20260430153210, recreated by 20260603030000). No other
-- shop is on Wix, and a fork would POST its catalog to fundiverstw.com (a leak),
-- so the whole push side is dropped here. Wix→Supabase sync (if a shop ever
-- wants it) belongs in a deployment, not the platform core.
--
-- Migrations are immutable, so this is a forward drop, not an edit of the
-- originals. The Vault `wix_sync_token` secret and the pg_net extension are left
-- in place: both are inert once nothing references them, and dropping the
-- extension risks unknown dependents.

begin;

drop trigger if exists wix_sync_dive_travel           on public."DiveTravel";
drop trigger if exists wix_sync_eo_courses            on public."EO_courses";
drop trigger if exists wix_sync_eo_dives              on public."EO_dives";
drop trigger if exists wix_sync_eo_prices             on public."EO_prices";
drop trigger if exists wix_sync_eo_rooms              on public."EO_rooms";
drop trigger if exists wix_sync_other_addons          on public."Other_Addons";
drop trigger if exists wix_sync_cancellation_policies on public.cancellation_policies;
drop trigger if exists wix_sync_cert_levels           on public.cert_levels;

drop function if exists public.wix_sync_notify();

-- `dive_sites` backed the Taiwan dive-site map, which was removed from the app.
-- Nothing reads it (no `.from('dive_sites')`, no FK targets it); dropping it also
-- removes the `wix_slug` columns (20260614000000 / 20260614010000).
drop table if exists public.dive_sites;

notify pgrst, 'reload schema';

commit;
