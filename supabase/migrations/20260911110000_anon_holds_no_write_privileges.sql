-- Close H2 of the 2026-09-11 audit: this schema handed `anon` write privileges
-- on every object it created.
--
-- Two halves, one cause. The squashed baseline captured Supabase's stock
-- default privileges:
--
--   ALTER DEFAULT PRIVILEGES ... GRANT ALL ON FUNCTIONS TO "anon";
--   ALTER DEFAULT PRIVILEGES ... GRANT ALL ON TABLES    TO "anon";
--
-- so every table created since grants `anon` SELECT/INSERT/UPDATE/DELETE, and
-- every function created since grants `anon` EXECUTE, automatically. Probed
-- against both live stacks, creating one table and one function as postgres:
--
--   fundive:       new table -> anon S=t I=t U=t D=t
--   app-fundivers: new table -> anon S=f I=f U=f D=f
--
-- app-fundivers' baseline tightened these; this repo's did not. That single
-- difference is why an identical migration left normalize_profile_values()
-- restricted in one database and callable by the whole internet in the other
-- (H1, closed in 20260911100000).
--
-- Nothing is exploitable through the *table* half today: all 65 tables have RLS
-- enabled, and not one policy in the schema grants `anon` an INSERT, UPDATE or
-- DELETE — checked before writing this, because a blanket revoke would break
-- the logged-out register form if one did. RLS is doing the whole job alone,
-- though, and `rls_auto_enable()` — the event trigger that would catch a table
-- shipped without it — is defined in the baseline but wired to nothing. A
-- forked shop that adds a table and forgets `enable row level security`
-- publishes it, readable and writable, to the internet.
--
-- This matters more here than it would in a private deployment: fundive is what
-- shops fork, so the baseline's defaults become theirs.
--
-- Two changes below.
--
-- 1. Default privileges are set to match app-fundivers exactly, rather than to
--    something merely safer. Drift between the two schemas is what produced H1,
--    so the fix is parity, not a third posture. New tables and functions now
--    grant `anon` nothing it can reach; every migration in this repo already
--    names its grants explicitly, so nothing depends on the old defaults.
--
-- 2. `anon`'s INSERT, UPDATE and DELETE are revoked on the tables that already
--    carry them. SELECT is deliberately left alone — roughly nineteen catalog
--    tables (prices, waivers, payment_methods, shop_contact, terms, ...) are
--    read by the register form before sign-in completes, and their RLS policies
--    are what decides the rows. This revoke cannot change behavior, because
--    every anon write it removes was already being refused by RLS; it restores
--    the second line of defense that RLS has been standing in for.
--
-- Not changed here, and worth its own decision: the defaults leave `anon`
-- holding TRUNCATE, which is exempt from RLS. PostgREST exposes no TRUNCATE
-- verb, so it is unreachable over the API, and app-fundivers grants it too —
-- removing it belongs in a change that moves both repos together.

-- 1. Defaults for objects created from here on.

alter default privileges for role postgres in schema public
  revoke all on functions from anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant references, trigger, truncate, maintain on tables to anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant update on sequences to anon, authenticated, service_role;

-- 2. The tables that already carry the old defaults.

revoke insert, update, delete on all tables in schema public from anon;
