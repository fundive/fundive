-- Shop-authored waivers + cancellation-policy CRUD metadata + a waiver-PDF bucket.
--
-- Moves the waiver catalog out of code into a `waivers` table so each shop
-- authors their own — free-form text OR an uploaded PDF, in whatever language
-- they need — and attaches them to events. The stable key stays `code` (+
-- integer `version`), so event_waivers, waiver_signatures and the sign_waiver()
-- RPC are untouched; only the catalog source moves from config to the DB.
--
-- This is the platform template: it ships with NO predefined waiver or
-- cancellation-policy content. Each deployment's admins create their own from
-- Manage → Waivers / Cancellation policies. Cancellation policies gain a
-- language label + active flag so they get the same admin CRUD. A private
-- `waiver-pdfs` bucket holds shop-uploaded PDF templates (admins write; any
-- authenticated diver reads to view + e-sign).

-- ── 1. waivers table ────────────────────────────────────────────────────────
create table public.waivers (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles(id) on delete set null,
  -- Stable identifier stored on signatures/overrides — never reused for a
  -- different waiver. Matches waiver_signatures.waiver_code / event_waivers.waiver_code.
  code text not null unique,
  title text not null,
  -- Free-form label for the shop's own organisation (e.g. 'en', 'zh-TW', '日本語').
  -- Not tied to the app's locale.language; the shop attaches the right waiver
  -- to each event by hand.
  language text,
  -- Exactly one of body / pdf_path is set (enforced below). pdf_path points into
  -- the waiver-pdfs storage bucket.
  body text,
  pdf_path text,
  cadence text not null default 'annual',
  -- Bumped when the content changes, to force everyone to re-sign (mirrors the
  -- old config `version`).
  version integer not null default 1,
  -- Default auto-scope, still overridable per-event via event_waivers.
  applies_to text not null default 'none',
  -- When applies_to touches courses, restrict to these courseColor() buckets.
  course_colors text[],
  active boolean not null default true,
  constraint waivers_cadence_check check (cadence = any (array['annual'::text, 'per_event'::text])),
  constraint waivers_applies_to_check check (applies_to = any (array['dives'::text, 'courses'::text, 'all'::text, 'none'::text])),
  constraint waivers_version_check check (version >= 1),
  constraint waivers_code_len_check check (char_length(code) >= 1 and char_length(code) <= 100),
  constraint waivers_title_len_check check (char_length(btrim(title)) >= 1),
  -- Exactly one content source: a text body OR an uploaded PDF, never both/neither.
  constraint waivers_content_present check (
    (body is not null and char_length(btrim(body)) > 0 and pdf_path is null)
    or (pdf_path is not null and char_length(btrim(pdf_path)) > 0 and body is null)
  )
);
create index waivers_active_idx on public.waivers using btree (active) where (active);
alter table public.waivers enable row level security;
-- Diver-readable reference data (mirrors cert_levels / cancellation_policies);
-- admin-only writes.
create policy "waivers: public select" on public.waivers
  for select to authenticated, anon using (true);
create policy "waivers: admin insert" on public.waivers
  for insert to authenticated with check (public.is_admin());
create policy "waivers: admin update" on public.waivers
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "waivers: admin delete" on public.waivers
  for delete to authenticated using (public.is_admin());

-- No seed rows: the template ships empty; admins author every waiver.

-- ── 2. cancellation_policies: CRUD metadata ─────────────────────────────────
-- The table pre-dates admin CRUD (id had no default; no language/active). Give
-- id a default so the admin form can insert without minting a client-side uuid,
-- and add the same free-form language label + active flag as waivers.
alter table public.cancellation_policies
  alter column id set default gen_random_uuid();
alter table public.cancellation_policies
  add column if not exists language text,
  add column if not exists active boolean not null default true;

-- ── 3. waiver-pdfs storage bucket ───────────────────────────────────────────
-- Private bucket for shop-uploaded PDF waiver templates. Admins manage the
-- files; any authenticated diver reads them (to view + e-sign). Unlike the
-- per-owner cert-cards buckets, these are shared shop templates, so read is not
-- folder-scoped.
insert into storage.buckets (id, name, public)
  values ('waiver-pdfs', 'waiver-pdfs', false)
  on conflict (id) do nothing;
create policy "waiver-pdfs: admin insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'waiver-pdfs' and public.is_admin());
create policy "waiver-pdfs: admin update" on storage.objects
  for update to authenticated
  using (bucket_id = 'waiver-pdfs' and public.is_admin())
  with check (bucket_id = 'waiver-pdfs' and public.is_admin());
create policy "waiver-pdfs: admin delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'waiver-pdfs' and public.is_admin());
create policy "waiver-pdfs: authenticated read" on storage.objects
  for select to authenticated
  using (bucket_id = 'waiver-pdfs');
