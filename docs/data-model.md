# Data model

## Table map

```
auth.users (Supabase)
    │ 1-1 via handle_new_user() trigger
    ↓
public.profiles ─────────── one row per diver / staff / admin
    │
    │ 1-many             ┌── EO_dives        (Bubble-imported catalog)
    │                    │── EO_courses
    ↓                    │── prices          (linked by events.price)
public.bookings ──── eo_dive_id XOR eo_course_id (text FK)
    │                    │── rooms           (room types — linked via
    │ 1-many             │                    event_rooms junction)
    ↓                    │── addons          (linked via
public.payments          │                    event_addons junction)
    (staff ledger)       │
                         │── cancellation_policies
                         │── trip_templates   (reusable trip copy)
                         └── cert_levels

public.event_memos ────── eo_dive_id XOR eo_course_id  (admin flags)
public.admin_notes ────── per-profile staff notes
public.admin_audit_log ── append-only changelog of admin mutations
public.duties ─────────── staff/admin assignments per event
public.dive_sites ─────── public catalog rendered on /map
public.push_subscriptions / push_notifications_sent  (cron infra)
```

## App-owned tables

| Table | Key columns | Notes |
| --- | --- | --- |
| `profiles` | `id` (= `auth.users.id`), `role` | `role in ('diver','staff','admin')`. Row auto-created by `handle_new_user()` on signup. Personal + cert + sizing + emergency contact + gear-owned + gear sizes + `agreed_to_terms_at`. |
| `bookings` | `id`, `user_id`, `event_id`, `status`, `details` (jsonb), `refund_requested_at` | `event_id` NOT NULL → `events(id)` (ON DELETE CASCADE). `details` shape enforced app-side by `BookingDetails` in `src/types/database.ts`. Unique per (user, event). After insert, most columns are immutable for divers — a trigger in the baseline schema makes a diver's booking tamper-resistant by design. |
| `payments` | `id`, `user_id`, `booking_id`, `amount`, `status`, `method`, `recorded_by` | Ledger entries, staff-inserted. `status in ('pending','paid','refunded')`. |
| `event_memos` | `id`, `event_id`, `tag`, `content`, `resolved_*` | XOR FK to dive/course. Tags: `urgent` / `payment` / `gear` / `logistics` / `cert` / `medical` / `note`. Resolution flags come as a trio (all null or all set, DB-enforced). |
| `diver_notes` | `id`, `profile_id`, `created_by`, `content`, `edited_*` | Per-diver standing facts (allergies, accommodations) — staff/admin can read+insert under their own attribution; admin or own-author can update/delete. `profile_id`/`created_by`/`created_at` frozen by trigger so RLS can't be sidestepped. |
| `admin_notes` | `id`, `profile_id`, `created_by`, `content` | Free-text staff notes attached to a diver's profile. Read/insert open to staff+admin (insert requires `created_by = auth.uid()`); update/delete admin-only. |
| `admin_audit_log` | `id`, `actor_id`, `action`, `target_table`, `target_id`, `before`, `after` | Append-only audit trail for admin mutations. Insert via DB triggers; reads admin-only. |
| `duties` | `id`, `assignee_id`, `role`, `start_date`, `end_date`, `event_id` | Staff-or-admin shift assignments. Trigger enforces `assignee_id` references a profile with role in (admin, staff). |
| `vehicles` | `id`, `name`, `passenger_seats`, `active` | Transport-fleet catalog. `passenger_seats` is the car's **total physical seats**; `event_ride_seats()` reserves the crew's seats (one per vehicle, rising to the on-duty staff count) so divers are offered only what's genuinely rideable. There is no driver-assignment concept — divers and staff compete for physical seats. Staff+admin read, admin write. |
| `event_vehicles` | `id`, `vehicle_id`, `event_date`, `event_id` | Which car is allocated to which event on which date. `event_id` NOT NULL → `events`; **unique `(vehicle_id, event_date)`** makes a car exclusive per day (the availability rule). One row per date for multi-day events. Staff+admin read, admin write. Assigned on the logistics day view. |
| `dive_sites` | `id`, `name`, `lat`, `lng`, `dive_type` | Public catalog rendered on `/map`; readable by all authenticated users. |
| `waiver_signatures` | `id`, `diver_id`, `waiver_code`, `waiver_version`, `signed_name`, `signed_at`, `event_id` | Append-only e-signature records. The waiver **catalog + global rules** live in code (`src/config/waivers.ts`), not the DB — these rows only record who signed what, when. Annual waivers leave `event_id` null; per-event waivers set it. Writes go through the `sign_waiver()` RPC (diver reads own; staff+admin read all). |
| `event_waivers` | `id`, `event_id`, `waiver_code`, `mode` | Per-event override of a waiver's global rule: `mode` `require` adds it, `exempt` drops it for one event. `event_id` NOT NULL → `events`; one override per `(event_id, waiver_code)`. Read by any authenticated user (the registration form needs it); admin write. Edited on the admin Edit-event form. |
| `cert_levels` | `id`, `agency`, `name`, `prereq_cert_id` | Reference data for the certification picker. Self-referential prerequisite chain. |
| `cancellation_policies` | `id`, `title`, `cancellation_policy` | Bubble-imported reference data linked from `events` rows via `cancel_policy`. |
| `trip_templates` | catalog | Reusable "what's included" / not-included / transportation / itinerary / prerequisites copy an event links to via `events.trip_template_id`; surfaces in the booking form. Renamed from `dive_travel` (`20260708050000`). |
| `scheduled_trips` | `id`, `title`, `destination`, `status`, `price`, `addon_ids`, `room_type_ids` | The shop's own curated, dated trips shown on the diver Scheduled Trips tab. Admin-managed base table (admin-only RLS); divers read published rows via `list_scheduled_trips()`. Carries `addon_ids`/`room_type_ids` (into the shop `addons`/`rooms` catalog) so divers register self-contained for a cost estimate — same flow as `packages`, minus tiers/partner. Distinct from `packages` (open-ended travel abroad) and the `events.is_trip` flag. See [packages.md](./packages.md). |
| `scheduled_trip_registrations` | `id`, `scheduled_trip_id`, `diver_id`, `estimated_cost`, `details`, `status` | One row per diver-registration for a scheduled trip; frozen estimate snapshot in `details`. No kickback (the shop's own trip). Admin-only base table; divers create via the `register-scheduled-trip` edge fn and read their own via `list_my_scheduled_trip_registrations()`. Partial unique index keeps one live registration per diver per trip. |
| `event_rooms` / `event_addons` / `event_destinations` | junctions | FK junctions linking rooms / add-ons / destinations to `events` by `event_id`. Reconciled by the `set_event_relations` RPC (the single write path). |
| `push_subscriptions` | `endpoint` (unique), `user_id`, `p256dh`, `auth` | One row per device. Diver owns their rows (RLS). |
| `push_notifications_sent` | `(user_id, event_id, kind)` composite PK | Idempotency ledger for the push cron. Service-role-only. |
| `trusted_partners` | `id`, `name`, `country`, `location`, `website`, `contact_name`, `contact_email`, `vouch_notes`, `logo_url`, `default_kickback_rate`, `active`, `created_by` | Unified registry of vouched partner dive shops — powers **both** the diver Trusted Partners directory and the shops that host **Packages** (unified from the old thin `trusted_partners` + richer `partner_shops` by `20260708080000`). **Admin-only RLS on every verb** — divers never see `contact_email`; they read `id` / `name` / `region` (= `coalesce(location, country)`) / `blurb` (= `vouch_notes`) / `website` for active, reachable rows through the `list_trusted_partners()` RPC, and message a partner via the `contact-trusted-partner` edge function (which resolves `contact_email` server-side). `packages.trusted_partner_id` FK-references it. See [trusted-partners.md](./trusted-partners.md) and [packages.md](./packages.md). |

## `events` table + catalog reference tables

Dives and courses are ONE table, `public.events`, discriminated by
`kind ('dive' | 'course')` (migrations `20260702000000`–`20260702000400`
collapsed the old Bubble `EO_dives` / `EO_courses` pair). Bookings, duties,
admin_notes, event_vehicles, and waiver rows all reference it by a single
`event_id → events(id)` (no more `eo_dive_id` / `eo_course_id` XOR).

| `events` columns | Notes |
| --- | --- |
| `id` (uuid), `kind`, `admin_title`, `display_title`, `calendar_title` | shared identity |
| `price` → `prices`, `cancel_policy` → `cancellation_policies`, `prereq_cert_id` → `cert_levels`, `trip_template_id` → `trip_templates` | catalog links |
| `capacity`, `fully_booked`, `full_payment_deadline`, `cancel_date`, `cancelled_at`, `dive_days`, `prereqs`, `req_dives`, `featured_image` | shared |
| **dive-only:** `start_date`, `end_date`, `start_time`, `featured`, `is_private`, `nitrox_required`, `gear_rental`, `notes`, `second_image`, `is_trip`, `is_boat_dive` | scalar date envelope; `is_trip`/`is_boat_dive` are independent `boolean not null default false` flags (see [events-and-bookings.md](./events-and-bookings.md)) |
| **course-only:** `course_days` (`date[]`, max 4 — the days a course runs on; see [events-and-bookings.md](./events-and-bookings.md#course_days)), `course_name`, `included`, `schedule`, `starting_at` | discrete session days (no envelope) |

**Temporal model:** dives use the scalar `start_date`/`end_date`/`start_time`
envelope; courses use `course_days[]`. This asymmetry is genuine domain logic —
`src/lib/events.ts` (`courseToEvents` / `groupConsecutive`) explodes a course's
day-array into calendar segments, while a dive is one segment.

The **reference tables** (`prices`, `rooms`, `addons`, `trip_templates`,
`cancellation_policies`, `travel_destinations`) were renamed from their Bubble
originals and cleaned (migration `20260703000000`): each now has a uuid `id`
primary key and the import-cruft columns were dropped — read-mostly catalog
data, admin-editable. (`dive_travel` was later renamed to `trip_templates`, and
`travel_destinations` lost its unused `latitude` / `longitude` /
`northeast_diving` columns — see the migration history below.)
Rooms/add-ons/destinations link to events through the junctions `event_rooms`,
`event_addons`, `event_destinations` (each `(event_id, <ref>_id)`), reconciled
by the `set_event_relations` RPC. All dates are **Asia/Taipei local** (no DST).

Normalization into the uniform `AppEvent` shape lives in `src/lib/events.ts`.
Use that everywhere in the UI rather than reading raw `events` rows.

## Row-Level Security

RLS is **on** for every `public.*` table. The important patterns:

- **Two SECURITY DEFINER helpers do the role checks** so policies
  don't recurse into `profiles` RLS:
  - `public.is_admin()` — caller's profile has `role = 'admin'`
  - `public.is_staff_or_admin()` — caller's profile has `role in
    ('admin','staff')`
- **Diver-owned rows** (`bookings`, `payments`, `push_subscriptions`):
  users can read/insert/update/delete rows where `auth.uid() = user_id`.
- **Staff+admin read** on `profiles`, `bookings`, `payments`,
  `event_memos`, `admin_notes` — broadened from admin-only by the
  `staff_role` migration. Writes on those tables stay admin-only
  except `admin_notes` (staff can insert their own).
- **`bookings` is largely immutable** for divers post-insert: the
  trigger `bookings_diver_immutable` (in
  `20260423130000_core_rls_and_booking_immutability.sql`) blocks
  diver writes to most columns. Diver can flip `status` to
  `'cancelled'` and stamp `refund_requested_at`; admins can mutate
  anything via the `is_admin()` policy.
- **Service-role bypasses RLS.** The push cron + the
  `create-registration` edge function both use the service-role key
  for this reason — they need to write under multiple users' identities.
- **Tables with no user-facing policies** (`push_notifications_sent`,
  `admin_audit_log`) are service-role-only or admin-only — RLS is on
  but no `for select` to authenticated, so anon/diver reads return
  zero rows.

## Migrations

Forward-only. **Never edit a migration that has been `make push`'d.**
Applied migrations are locked — the registry in `supabase_migrations`
will refuse the push if a checksum changed.

To evolve a table, write a new migration that does `alter table …` or
adds a column / constraint / policy. File naming is
`YYYYMMDDHHMMSS_<slug>.sql`.

### Migration history

fundive ships a **single squashed baseline**,
`20260703000000_baseline_schema.sql`, that captures the entire schema — the
unified `events` model, every app-owned table above, all RLS policies and
triggers, and the SECURITY DEFINER RPCs (`event_ride_seats`, `sign_waiver`,
`event_confirmed_counts`, `set_event_relations`, …). It collapsed the long
per-feature migration lineage the platform grew in early development, so a fresh
database is one baseline apply, not a replay of history.

Everything after the baseline is a **forward** migration (the `ls
supabase/migrations/` order is the source of truth):

- `20260705000000_event_ride_seats_reserve_crew.sql` — redefines
  `event_ride_seats()` so capacity reserves the crew's seats:
  `Σ passenger_seats − greatest(#assigned vehicles, #on-duty staff)`. One seat per
  vehicle is held as a floor, rising to the full on-duty staff count when staff
  outnumber the cars, so the seats offered to divers are what's genuinely
  rideable.
- `20260706000000_trusted_partners.sql` — the `trusted_partners` table, its
  admin-only RLS, and the `list_trusted_partners()` RPC (email-free projection).
  See [trusted-partners.md](./trusted-partners.md).
- `20260707000000_dive_trip_boat_flags.sql` — adds `is_trip` and `is_boat_dive`
  (both `boolean not null default false`) to `events`. No keyword backfill — an
  admin ticks them per event. See [events-and-bookings.md](./events-and-bookings.md).
- `20260707010000_notify_admins_ride_waitlist.sql` — trigger that notifies admins
  when a booking lands on the ride waitlist (`details.ride_waitlisted = true`).
- `20260707020000_event_ride_seats_authenticated_only.sql` — revokes the default
  `PUBLIC`/`anon` EXECUTE on `event_ride_seats()` and re-grants only
  `authenticated` + `service_role`, so aggregate seat counts aren't exposed to
  unauthenticated callers (a guest's fetch fails open).
- `20260708020000_trip_board_definer_functions.sql` — replaces the Packages
  diver-facing views with `list_package_board()` / `list_my_package_referrals()`
  SECURITY DEFINER functions (email-free, kickback-free projections).
- `20260708030000_rename_trip_board_to_packages.sql` — renames the "Trip Board"
  feature to Packages end to end: tables `trips` → `packages`, `trip_referrals`
  → `package_referrals`; RPCs `list_trip_board` → `list_package_board`,
  `list_my_trip_referrals` → `list_my_package_referrals`, `express_trip_interest`
  → `express_package_interest`; plus indexes, policies, and the set-code trigger.
  See [packages.md](./packages.md).
- `20260708040000_scheduled_trips.sql` — the `scheduled_trips` table (the shop's
  own dated, in-app-bookable trips), its admin-only RLS, and the
  `list_scheduled_trips()` SECURITY DEFINER function (published rows, carrying
  the linked event's kind so the diver card can build a register link).
- `20260708050000_rename_dive_travel_to_trip_templates.sql` — renames the
  `dive_travel` reference table to `trip_templates` and `events.divetravel_id`
  to `events.trip_template_id`.
- `20260708060000_drop_travel_destinations_coords.sql` — drops the unused
  `latitude` / `longitude` columns from `travel_destinations`.
- `20260708070000_drop_travel_destinations_northeast_diving.sql` — drops the
  unused `northeast_diving` column from `travel_destinations`.
- `20260708080000_unify_partner_tables.sql` — merges the thin `trusted_partners`
  directory into the richer `partner_shops` registry and renames the result back
  to `trusted_partners` (the superset). Repoints `packages.partner_shop_id` →
  `packages.trusted_partner_id`, rebuilds the `list_trusted_partners()` and
  Packages definer functions against the unified table. See
  [trusted-partners.md](./trusted-partners.md) and [packages.md](./packages.md).

## `BookingDetails` JSONB shape

Defined in `src/types/database.ts` — that file is the source of truth.
DB only enforces `jsonb_typeof(details) = 'object'`. Current shape:

```ts
interface BookingDetails {
  gear?: {
    rent: boolean
    included?: boolean              // event bundles gear (e.g. OW course)
    mode?: 'a-la-carte'             // gear is rented à-la-carte only
    items?: string[]                // chosen gear items
    assistance_note?: string        // diver picked "ask a human"; their note
                                    //   (when set, rent is false)
    size_overrides?: { height_cm?, weight_kg?, shoe_size? }
  }
  room?: { option_id?: string | null; notes?: string | null }
  add_ons?: string[]                // addons.id list
  transportation?: boolean
  payment_method?: 'bank_transfer' | 'credit_card' | 'cash'
  pay_deposit_only?: boolean        // deposit-only-at-registration flag
  nitrox_course_addon?: boolean
  charges?: ChargeLine[]            // itemized snapshot — see below
  total?: number                    // final-charge snapshot
  deposit?: number                  // prices.deposit_amount snapshot
  cancellation_policy_acked_at?: string  // gate for submit when policy attached
}
```

**Design note:** `total`, `deposit`, and `charges` are snapshotted into
the booking so later catalog price changes don't retroactively alter what
the diver owes — the lesson from removing the full-gear-set package, which
had silently rewritten paid divers' amounts because every surface
*recomputed* the breakdown from current prices.
`cancellation_policy_acked_at` is preserved across edits — admin
edits to `notes`/`details` don't reset the diver's prior ack.

**`charges` (`ChargeLine[]`)** — the itemized breakdown behind `total`
(base, per-item gear, room, each add-on, transport, nitrox course, card
surcharge), each `{ kind, label, amount }`. Built once by `buildCharges()`
in `src/lib/booking-charges.ts` at registration and rendered from the
snapshot everywhere: the PDF/email, the diver's Bookings/Payments pages,
and the admin event + per-diver views (via the shared `<ChargeBreakdown>`
and `BookingPaymentsBlock`). Bookings created before this field existed
have no snapshot; `resolveCharges()` reconstructs their lines from the
stored selections using *current* catalog prices (so the figures can
drift) — it never mutates stored rows.
