# Data model

## Table map

```
auth.users (Supabase)
    │ 1-1 via handle_new_user() trigger
    ↓
public.profiles ─────────── one row per diver / staff / admin
    │
    │ 1-many             ┌── events          (ONE table: dives, courses,
    │                    │                    adventures — see `kind`)
    ↓                    │── prices          (linked by events.price)
public.bookings ──── event_id → events(id)
    │                    │── rooms           (via the event_rooms junction)
    │ 1-many             │── addons          (via the event_addons junction)
    ↓                    │── travel_destinations
public.payments          │                   (via the event_destinations junction)
    (staff ledger)       │── cancellation_policies
    │                    │── trip_templates  (reusable trip copy)
    │ 1-many             └── cert_levels
    ↓
public.credits ────────── money the shop owes a diver (see payments.md)
public.booking_discounts  one diver asking for one discount on one booking;
                          approving writes a booking_amendments row
                          (discounts ── event_discounts ── the event's offer)
public.nondiver_options ─ snorkeler / boat passenger: own price + deposit
                          (offered per event via event_nondiver_options;
                          the choice lives in bookings.details)

public.admin_notes ────── event_id XOR booking_id  (operational memos)
public.diver_notes ────── per-diver standing facts (allergies, accommodations)
public.admin_audit_log ── append-only changelog of admin mutations
public.duties ─────────── staff/admin assignments per event
public.dive_sites ─────── the shop's places (events.site_id, the almanac)
public.push_subscriptions / push_notifications_sent  (cron infra)
```

Every child of an event — `bookings`, `duties`, `event_waivers`,
`event_vehicles`, `event_ride_groups`, `event_discounts`,
`event_nondiver_options`, `notifications` —
points at it with a plain `event_id`. There is no `eo_dive_id` / `eo_course_id`
XOR anywhere in the schema — the only XOR left is `admin_notes`, which pins a
memo to either an event or a booking.

## App-owned tables

| Table | Key columns | Notes |
| --- | --- | --- |
| `profiles` | `id` (= `auth.users.id`), `role` | `role in ('diver','staff','admin')`. Row auto-created by `handle_new_user()` on signup. Personal + cert + sizing + emergency contact + gear-owned + gear sizes + `agreed_to_terms_at`. |
| `bookings` | `id`, `user_id`, `event_id`, `status`, `details` (jsonb), `refund_requested_at`, `group_id`, `payer_id`, `created_by`, `continues_booking_id`, `attend_days` | `event_id` is NOT NULL (`20261116120000`) → `events(id)` (ON DELETE CASCADE). `details` shape enforced app-side by `BookingDetails` in `src/types/database.ts`. One live booking per (user, event): the partial unique index `bookings_one_active_per_user_idx` skips cancelled rows. Divers cannot change a booking's details, move it to another event, or set any status but `cancelled` after insert — see [Row-Level Security](#row-level-security). `continues_booking_id` / `attend_days` carry a course finished across two scheduled courses (see [events-and-bookings.md](./events-and-bookings.md#one-course-several-scheduled-courses)). |
| `payments` | `id`, `user_id`, `booking_id`, `amount`, `status`, `method`, `recorded_by` | Ledger entries, staff-inserted. `status in ('pending','paid','refunded')`. |
| `diver_notes` | `id`, `profile_id`, `created_by`, `content`, `edited_*` | Per-diver standing facts (allergies, accommodations) — staff/admin can read+insert under their own attribution; admin or own-author can update/delete. `profile_id`/`created_by`/`created_at` frozen by trigger so RLS can't be sidestepped. |
| `admin_notes` | `id`, `event_id` \| `booking_id`, `created_by`, `tag`, `content`, `resolved_*` | The operational memo table — a note pinned to one event **or** one booking (CHECK `admin_notes_target_present`: exactly one, the last XOR in the schema). Tags: `urgent` / `payment` / `gear` / `logistics` / `cert` / `medical` / `note` / `general`. Resolution flags come as a trio (all null or all set, DB-enforced). Read/insert open to staff+admin (insert requires `created_by = auth.uid()`); update/delete admin-only. See [admin.md](./admin.md#event-memos-admin-notes). |
| `admin_audit_log` | `id`, `actor_id`, `action`, `target_table`, `target_id`, `before`, `after` | Append-only audit trail for admin mutations. Insert via DB triggers; reads admin-only. |
| `duties` | `id`, `assignee_id`, `role`, `start_date`, `end_date`, `event_id` | Staff-or-admin shift assignments; `role in ('instructor','guide','support')`. Trigger enforces `assignee_id` references a profile with role in (admin, staff). The roster is also what [staff revenue](./admin.md#revenue-by-staff) is attributed from. |
| `vehicles` | `id`, `name`, `passenger_seats`, `active` | Transport-fleet catalog. `passenger_seats` is the car's **total physical seats**, and every one of them is rideable: there is no driver-assignment concept, so divers and on-duty staff compete for the same seats and `event_ride_seats()` simply subtracts the staff. Staff+admin read, admin write. |
| `event_vehicles` | `id`, `vehicle_id`, `event_id`, `notes` | Which car is allocated to which event, of any kind; `event_id` NOT NULL. A car may serve any number of events, at most once each (unique `(event_id, vehicle_id)`). Staff+admin read, admin write. Assigned on the logistics day view, the event's Transportation tab and the create/edit event forms. |
| `event_ride_groups` | `(ride_day, event_id)` PK, `group_id` | Which of a day's events **travel together** — the events sharing a `group_id` form one "run" and pool their cars, divers and staff; an event with no row rides alone. `group_id` has no parent table: the group is the set of rows. Staff read, admin write, set by the Shared transport picker on `/admin/logistics`. See [admin.md](./admin.md#transport-runs-seats-riders). |
| `packed_pieces` | `(pack_day, booking_id, item)` PK, `packed_by`, `packed_at` | The logistics board's shared pack list: a row per piece on the van, so every crew phone reads the same ticks (Realtime-published). A tick inserts, an untick deletes. Staff+admin read, insert (stamped `packed_by = auth.uid()`) and delete; divers and anon nothing. Cascades with its booking. See [admin.md](./admin.md#gear-the-pack-checklist). |
| `waivers` | `id`, `code`, `version`, `title`, `body` \| `pdf_path`, `language`, `cadence`, `applies_to`, `active` | The shop's own waiver catalog (`20260709120000`) — text forms or uploaded PDFs in the `waiver-pdfs` bucket (exactly one of `body` / `pdf_path` set). `code` + `version` are what `waiver_signatures` and `event_waivers` reference. Admin-authored at `/admin/waivers`; the repo ships no waiver content. `src/config/waivers.ts` holds only the domain types and the row mapper. |
| `waiver_signatures` | `id`, `diver_id`, `waiver_code`, `waiver_version`, `signed_name`, `signed_at`, `event_id`, `signed_title` / `signed_body` / `signed_pdf_path`, `content_sha256` | Append-only e-signature records; each snapshots the exact waiver content it signed, with a SHA-256, so a later edit can't rewrite history (`20260711200000`). Annual waivers leave `event_id` null; per-event waivers set it. Writes go through the `sign_waiver()` RPC (server-stamps `signed_at` / `diver_id`), or `admin_record_paper_waiver()` for one signed on paper in person. Diver reads own; staff+admin read all. |
| `event_waivers` | `id`, `event_id`, `waiver_code`, `mode` | Per-event override of a waiver's default rule: `mode` `require` adds it, `exempt` drops it for one event. `event_id` NOT NULL → `events`; one override per `(event_id, waiver_code)`. Read by any authenticated user (the registration form needs it); admin write. Edited on the admin Edit-event form. |
| `cert_levels` | `id`, `code`, `name`, `rank`, `organization`, `padi_equivalent_id` | Reference data for the certification picker. Events point at one via `events.prereq_cert_id`, and the admin form offers **PADI levels only** — prereqs are encoded as PADI ranks, with `padi_equivalent_id` mapping an agency-specific level onto its PADI peer. The mapping canonicalizes divers' free-text levels for the dashboard (`src/lib/cert-level.ts`) and the cert-equivalence chart; registration eligibility does not rank-compare levels. |
| `cancellation_policies` | `id`, `title`, `cancellation_policy`, `language`, `active`, `deposit_refundable` | Linked from `events.cancel_policy`; the text a diver acknowledges at registration. `deposit_refundable = false` withholds the deposit from an automatic cancellation credit (see [payments.md](./payments.md)). Admin-managed at `/admin/cancellation-policies`. |
| `shop_contact` | `singleton`, `email`, `phone`, `address`, `maps_url`, `updated_at/_by` | The shop's own contact details. **Exactly one row** (`check (singleton)`), shipped EMPTY by 20260905120000 — a shop's address is not something core can guess, and a placeholder would be a wrong address printed on a real registration. Publicly readable (the pages that print the shop's email include ones a diver reaches before approval, and the terms-acceptance page, which runs from an emailed link with no session) and admin-updatable; no insert or delete policy exists, so the row cannot be removed. Empty strings mean "not published yet" and every surface handles that; a malformed email or map URL is refused by a check constraint. Read by the app through `ShopContactProvider`, and per request by the edge functions that mail the shop (`_shared/shop-contact.ts`). Admin-managed at `/admin/contact`. |
| `contact_channels` | `id`, `kind`, `label`, `url`, `sort_order`, `active` | The ways a diver can reach the shop, in the order the Contact tab lists them. Ships empty: which services a shop is on is exactly what this table exists to stop core from deciding. `kind` is a closed vocabulary (`line`, `whatsapp`, `telegram`, `messenger`, `instagram`, `wechat`, `signal`, `phone`, `sms`, `other`) pinned to `CONTACT_CHANNEL_KINDS` — each carries a glyph and brand color that live in code, because shop-authored markup rendered into the page is an XSS hole; `other` takes any link with a neutral glyph. `url` holds an https link for a chat service and a **bare phone number** for `phone` / `sms` (a check constraint enforces which), and `channelHref` adds the `tel:` / `sms:` scheme. A null `label` uses the deployment's own translated wording for that service. Publicly readable, admin-written. |
| `payment_methods` | `id`, `key`, `label`, `surcharge_percent`, `bank_name`, `bank_code`, `account_number`, `account_holder`, `swift_bic`, `pay_url`, `notes`, `collects_invoice_email`, `shows_shop_contact`, `sort_order`, `active` | How divers can pay. `key` is the stable value `bookings.details.payment_method` records, so a method can be renamed or repriced without orphaning a booking; everything else is what the register form and the emailed PDF print. Publicly readable (the register form renders before sign-in), admin-written. Admin-managed at `/admin/payment-methods`; see [payments.md § Payment methods](./payments.md#payment-methods). |
| `trip_templates` | `id`, `admin_title`, `included`, `not_included`, `transportation`, `itinerary`, `prerequisites` | Reusable "what's included" / not-included / transportation / itinerary / prerequisites copy an event links to via `events.trip_template_id`; surfaces in the event-detail modal and the booking form. |
| `travel_destinations` | `id`, `admin_title`, `country`, `divetype`, `international`, … | Destination catalog. Events are tagged with these via the `event_destinations` junction (event-form picker); `divetype` drives the calendar's local-versus-trip coloring. Admin-managed at `/admin/destinations`. |
| `scheduled_trips` | `id`, `title`, `destination`, `status`, `price`, `addon_ids`, `room_type_ids` | The shop's own curated, dated trips shown on the diver Scheduled Trips tab. Admin-managed base table (admin-only RLS); divers read published rows via `list_scheduled_trips()`. Carries `addon_ids`/`room_type_ids` (into the shop `addons`/`rooms` catalog) so divers register self-contained for a cost estimate — same flow as `packages`, minus tiers/partner. Distinct from `packages` (open-ended travel abroad) and the `events.is_trip` flag. See [packages.md](./packages.md). |
| `scheduled_trip_registrations` | `id`, `scheduled_trip_id`, `diver_id`, `estimated_cost`, `details`, `status` | One row per diver-registration for a scheduled trip; frozen estimate snapshot in `details`. No kickback (the shop's own trip). Admin-only base table; divers create via the `register-scheduled-trip` edge fn and read their own via `list_my_scheduled_trip_registrations()`. Partial unique index keeps one live registration per diver per trip. |
| `event_rooms` / `event_addons` / `event_destinations` / `event_discounts` / `event_nondiver_options` | junctions | FK junctions linking rooms / add-ons / destinations / offered discounts to `events` by `event_id`. Reconciled by the `set_event_relations` RPC (the single write path). |
| `discounts` | `id`, `label`, `description`, `kind`, `value`, `active`, `sort_order` | The shop's discount catalog — `kind` is `percent` (1–100) or `fixed` (a flat amount). Publicly readable so the register form can render the offer before sign-in; admin-written. See [payments.md § Discounts](./payments.md#discounts). |
| `nondiver_options` | `id`, `label`, `description`, `price`, `deposit_amount`, `active`, `sort_order` | Ways to join an event without diving (snorkeler, boat passenger), each at its own price and optional deposit. Publicly readable so the register form can render them before sign-in; admin-written. Offered per event via `event_nondiver_options`. See [events-and-bookings.md § Non-diver options](./events-and-bookings.md#non-diver-options). |
| `booking_discounts` | `id`, `booking_id`, `discount_id`, `status`, `amount`, `amendment_id`, `requested_*`, `decided_*` | One diver asking for one discount on one booking. **No write policy at all** — every write goes through `request_booking_discount` / `decide_booking_discount`, so no client can mint an approval. An approval stamps the `amount` and the negative `booking_amendments` row that is the actual money; `discount_id` is `ON DELETE RESTRICT` so a granted discount outlives the shop's decision to stop offering it. |
| `push_subscriptions` | `endpoint` (unique), `user_id`, `p256dh`, `auth` | One row per device. Diver owns their rows (RLS). |
| `push_notifications_sent` | `(user_id, event_id, kind)` composite PK | Idempotency ledger for the push cron. Service-role-only. |
| `trusted_partners` | `id`, `name`, `country`, `location`, `website`, `contact_name`, `contact_email`, `vouch_notes`, `logo_url`, `default_kickback_rate`, `active`, `created_by` | Unified registry of vouched partner dive shops — powers **both** the diver Trusted Partners directory and the shops that host **Packages** (the old thin `trusted_partners` directory and the richer `partner_shops` registry, unified before the squashed baseline). **Admin-only RLS on every verb** — divers never see `contact_email`; they read `id` / `name` / `region` (= `coalesce(location, country)`) / `blurb` (= `vouch_notes`) / `website` for active, reachable rows through the `list_trusted_partners()` RPC, and message a partner via the `contact-trusted-partner` edge function (which resolves `contact_email` server-side). `packages.trusted_partner_id` FK-references it. See [trusted-partners.md](./trusted-partners.md) and [packages.md](./packages.md). |

## Other app-owned tables

Documented in their own docs rather than above:

| Table | Covered by |
| --- | --- |
| `credits` | [payments.md](./payments.md) |
| `booking_amendments` | [payments.md](./payments.md) — admin adjustments to what a booking owes; append-only, so the client never mutates one |
| `packages`, `package_tiers`, `package_registrations` | [packages.md](./packages.md) |
| `notifications` | [push-notifications.md](./push-notifications.md) |
| `taxa`, `taxon_names`, `almanac_sightings` | [wildlife-taxa.md](./wildlife-taxa.md) |
| `dive_site_maps`, `dive_site_features`, `dive_site_soundings`, `dive_site_contributions`, `dive_site_entries` | [dive-site-maps.md](./dive-site-maps.md) |
| `shop_profile` | [i18n.md](./i18n.md#currency-and-language-reach-the-app-through-the-build) |

Not written up at length anywhere: `terms` / `terms_consent_tokens` (the
shop-authored Terms of Use singleton and its one-time acceptance links),
`dive_logs` / `dive_log_export_requests` (the diver logbook and its PDF
export), `waitlist_offers` (the cron's timed offer of a freed spot),
`staff_availability` (busy windows the duty picker reads),
`gear_models` / `gear_model_sizes` (the shop's sizing charts),
`event_series` (recurrence batches), `profile_value_normalizations`, and
the abuse ledgers `signup_attempts` / `user_action_attempts` /
`orphan_auth_users`.

## `events` table + catalog reference tables

Dives, courses and adventures are ONE table, `public.events`, discriminated
by `kind` (the Bubble-era `EO_dives` / `EO_courses` pair was collapsed into it
before the squashed baseline; `adventure` arrived in `20260720000000`).
Bookings, duties, admin_notes, event_vehicles, and waiver rows all reference
it by a single `event_id → events(id)` (no more `eo_dive_id` / `eo_course_id`
XOR).

| `events` columns | Notes |
| --- | --- |
| `id` (uuid), `kind`, `admin_title`, `display_title`, `calendar_title` | shared identity. `kind in ('dive','course','adventure')` — the DB's `events_kind_check` |
| `price` → `prices`, `cancel_policy` → `cancellation_policies`, `prereq_cert_id` → `cert_levels`, `trip_template_id` → `trip_templates` | catalog links |
| `capacity`, `fully_booked`, `full_payment_deadline`, `cancel_date`, `cancelled_at`, `dive_days`, `prereqs`, `req_dives`, `featured_image` | shared |
| `has_transport` (NOT NULL, default true) | shared. False when the shop drives nobody to this event — a dry course held at the shop. The register forms then put no ride question and fetch no seat tally, and `create-registration` forces `details.transportation` false. Set in the vehicle section of the admin event form; see [admin.md](./admin.md#transport-runs-seats-riders). Every payload to `create_events_with_relations` must carry it: `jsonb_populate_record` leaves an absent key NULL rather than falling back to the default |
| `involves_scuba` (NOT NULL, default true) | shared. False when nobody who registers scuba dives — an EFR/CPR class, an equipment course, a BBQ. It means "no scuba", not "nobody gets wet": non-divers may still snorkel or swim. Named `enters_water` until 20261022100000. The Logistics board then lists those registrants as **non-divers** rather than divers, which is the split the shop's insurer asks for; see [admin.md](./admin.md#divers-and-non-divers). Ask it through `eventInvolvesScuba()` (`src/lib/participants.ts`), never raw: an adventure answers no by kind whatever the column says. Set on the admin event form, and carried in every `create_events_with_relations` payload for the same NOT NULL reason as `has_transport` (20260925100000, renamed 20261022100000) |
| **date-envelope kinds:** `start_date`, `end_date`, `start_time` | dives and adventures carry a scalar start/end envelope |
| **dive-only:** `nitrox_required`, `is_boat_dive` | the genuinely diving-specific flags |
| **dive-only (form-gated):** `is_trip`, `notes`, `featured`, `is_private` | `is_trip`/`is_boat_dive` are independent `boolean not null default false` flags (see [events-and-bookings.md](./events-and-bookings.md)). The columns sit on every envelope kind; the admin form offers them on dives, under `hasDiveFlags` |
| **non-course kinds:** `gear_rental` | free text describing the rental terms. It does not decide whether gear is offered — `gear_included` does |
| `gear_included` (NOT NULL, default false) | shared. True when the event puts no gear question and bills no gear: the fee covers a set, or nobody scuba dives. `create-registration` re-reads it and overwrites `details.gear`, the same way it forces `details.transportation`. Whether a set is physically packed is `packsAGearSet()` — this flag **and** `kindInvolvesScuba(kind)`, so an overland outing that bundles "gear" packs none. Replaced a substring match on course titles (20260911120000), which now only pre-ticks the box on the admin form |
| **course kinds:** `course_days` (`date[]`, 1–4 entries — the days a course runs on; see [events-and-bookings.md](./events-and-bookings.md#course-days)), `course_name`, `included`, `schedule` | discrete session days, no envelope |

`series_id` groups the batch of occurrences a recurrence rule generated
(`event_series`); each occurrence is otherwise fully independent.

**Temporal model:** date-envelope kinds use the scalar
`start_date`/`end_date`/`start_time` envelope; course kinds use
`course_days[]`. This asymmetry is genuine domain logic —
`src/lib/events.ts` (`courseToEvents` / `groupConsecutive`) explodes a course's
day-array into calendar segments, while a dive is one segment.

### Ask what a kind *does*

**Never branch on `kind === 'dive'`.** The vocabulary and the questions
live in `src/lib/event-kinds.ts` — `usesDateEnvelope`, `usesCourseDays`,
`heldAtShop`, `isInstructorLed`, `hasDiveFlags`, `kindInvolvesScuba`,
`hasTerrainConditions`, `recordsSiteConditions`, plus the
`DATE_ENVELOPE_KINDS` / `COURSE_DAY_KINDS` / `SITE_CONDITION_KINDS` value
lists that queries filter on. That file is deliberately import-free so the
Deno edge functions and the push worker share it, and `src/types/database.ts`
carries a compile-time guard pinning it to the DB's `events_kind_check`.

A `kind === 'dive' ? … : …` ternary silently means "course" in its else
branch, so a new kind inherits course behavior with no compile error and
often no visible symptom — an event that is simply never fetched.

Adding a kind touches separate DB vocabularies that no FK keeps in step:
`events_kind_check`, `push_notifications_sent_event_type_check` (no FK to
`events`, so a miss only shows up as rejected push rows), `waivers.applies_to`,
and the `kind` check on `dive_sites` (asserted against `SITE_CONDITION_KINDS`
in `src/lib/dive-sites.test.ts`).

The **reference tables** (`prices`, `rooms`, `addons`, `trip_templates`,
`cancellation_policies`, `travel_destinations`) were renamed from their Bubble
originals (`EO_prices`, `EO_rooms`, `Other_Addons`, `DiveTravel`, …) and
cleaned before the squashed baseline: each has a uuid `id` primary key —
read-mostly catalog data, admin-editable. The last imported page fields nothing
read went in `20261029120000`.
Rooms/add-ons/destinations link to events through the junctions `event_rooms`,
`event_addons`, `event_destinations` (each `(event_id, <ref>_id)`), reconciled
by the `set_event_relations` RPC. All dates are interpreted as **shop-local**
(`locale.timezone`).

Normalization into the uniform `AppEvent` shape lives in `src/lib/events.ts` —
`fetchEventsInRange`, `fetchEventsForBookings`, `fetchUpcomingEventDays`. Use
`AppEvent` everywhere in the UI rather than reading raw `events` rows.

## `dive_sites` — the shop's places

One row per place, and the reason "Bat Cave" means the same thing everywhere:
`events.site_id` says where an event goes, and `almanac_records.site_id` says
what it was like there.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | uuid PK | |
| `name` | text | The English name, and what every surface falls back to. Unique per kind, case-insensitively — `(kind, lower(name))` — so casing cannot mint a second Bat Cave |
| `name_zh_tw` / `name_ja` | text | The same place in the other catalog languages, optional |
| `kind` | text | `dive` / `adventure`: the events vocabulary narrowed to the kinds that answer `recordsSiteConditions`. A course runs from the shop and has no site of its own. The almanac's dive/adventure toggle filters on this |
| `region` | text | Optional grouping shown beside the name, e.g. "Longdong" |
| `notes` | text | Entry, parking, hazards — staff-facing |
| `latitude` / `longitude` | numeric(9,6) | Optional, but both or neither |
| `verified` | boolean | Staff have confirmed the place and its spelling. False on anything a diver added until someone checks it |
| `created_by` | uuid → `auth.users` | Who added it |
| `active` | boolean | `false` retires a site: its history stays, but it stops being offered |

Any authenticated user reads it (the almanac's submission form is a diver
surface). Since `20260827300000` a diver can add a place too, through
`create_dive_site()` rather than an INSERT policy, so `verified` and
`created_by` are never the author's claim: the row is live at once and
unverified. `find_similar_dive_sites()` matches the typed name against every
name in every language, plus the `dive_site_aliases` table (other spellings a
place answers to, never displayed), and the form offers what it found before
writing. Admins curate at `/admin/dive-sites`, where `verify_dive_site()` and
`merge_dive_sites()` handle what still slips through.

## `almanac_records` — crowdsourced environmental observations

Divers submit environmental and weather observations for the places the shop
goes; staff/admin rule on each one. A record is a **site on a date**, drawn
from the `dive_sites` catalog above, and the almanac reads them back by
calendar date — a day is the unit, and every site observed that day shares a
bucket. Only approved records reach the crowd, on `/almanac` — the page also lists a
diver every entry they have filed, on its own **Your entries** tab, and shows
staff the review queue.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | uuid PK | |
| `created_at` / `updated_at` | timestamptz | |
| `diver_id` | uuid → `auth.users` | The submitting diver |
| `site_id` | uuid → `dive_sites(id)` | The place observed. `ON DELETE RESTRICT` — a site carrying observations is retired (`active = false`), not deleted |
| `obs_date` | date | The date of the observation |
| `air_temp_c` | numeric(4,1) | Optional |
| `water_temp_c` | numeric(4,1) | Optional |
| `visibility_m` | numeric(4,1) | Optional |
| `current_strength` | text | `calm` / `light` / `moderate` / `strong` / `very_strong` |
| `wave_height_m` | numeric(3,1) | Optional |
| `wave_period_s` | numeric(3,1) | Optional |
| `weather` | text | `clear` / `partly_cloudy` / `cloudy` / `overcast` / `rain` / `thunderstorm` / `windy` / `fog` / `typhoon` |
| `coral_health` | text | `excellent` / `good` / `fair` / `poor` / `bleaching` |
| `elevation_m` | numeric(5,0) | Adventure-specific |
| `route_condition` | text | `dry` / `wet` / `muddy` / `icy` / `snow` / `rockfall` |
| `summit_visible` | boolean | Adventure-specific |
| `status` | text | `pending` / `approved` / `rejected` |
| `approved_by` | uuid → `auth.users` | Staff/admin who approved |
| `approved_at` | timestamptz | |
| `staff_notes` | text | Optional moderation notes |

Unique constraint: `(site_id, obs_date, diver_id)` — one observation per
(diver, site, date).

`authenticated` is granted **SELECT only**. Every write goes through a
`SECURITY DEFINER` RPC, so the moderation state machine can't be driven from
the client — a diver has no way to mint an already-approved record:

- `submit_almanac_record(...)` — files the caller's observation for a
  site and date, always as `pending`. Fields are assigned outright rather than
  coalesced (the form posts the whole record, so a cleared field clears), the
  date may not be in the future, and a record staff have already ruled on
  cannot be revised.
- `withdraw_almanac_record(record_id)` — deletes a **pending** record of the
  **caller's own**, and nothing else: `security definer` runs past RLS, so the
  function checks both itself, and answers "no such record" and "not yours"
  identically so ids cannot be probed. How a diver takes back an observation
  filed against the wrong site or day, which an edit cannot fix — site and date
  are what identify the record. A reviewed one stays: it is part of what the
  crowd has been shown, and a reading its author could delete afterwards would
  make every published figure provisional.
- `moderate_almanac_record(record_id, status, staff_notes)` — staff/admin
  only; stamps `approved_by` / `approved_at`. `status` must be `approved` or
  `rejected`.
- `almanac_records_in_range(from, to)` — the approved records for a window of
  calendar days, each with its site name and the submitter's name. A date
  range rather than a list of ids, because the page reads the almanac by day.
- `almanac_pending_records()` — the staff review queue; raises for anyone
  else.

Reads of the table itself are governed by RLS: a diver sees their own rows
(any status) plus every approved row; staff and admin see all of them. The
**Your entries** tab reads whole rows for exactly that reason: an edit is
seeded from the record, and since `submit_almanac_record` writes every column,
a form filled from half a record would blank the other half on save.

### What was seen is not on this row

Wildlife used to be a `text[]` on this table, filled from one comma-separated
box, which made `turtle`, `Turtle`, `green turtle` and `ウミガメ` four different
animals in every tally. It is now `almanac_sightings` — one row per animal,
pointing at a `taxa` row keyed on its **scientific name**, with every
language's word for it in `taxon_names`. `submit_almanac_record` takes
`p_taxon_ids uuid[]`, and the read RPCs return `wildlife_taxa uuid[]` plus
`wildlife_unmatched text[]` (the pre-catalog free text staff have yet to map).
A record naming a taxon a diver proposed and nobody has ruled on cannot be
approved. See [wildlife-taxa.md](./wildlife-taxa.md).

## `coral_surveys` / `coral_survey_colonies` — crowdsourced coral monitoring

A CoralWatch Coral Health Chart survey, and the measurement that
`almanac_records.coral_health` is not. That column is one ordinal judgment per
site-date-diver; it carries no colony count, no depth, no water temperature at
the moment of observation, and no reference standard a second observer could
reproduce. Both surfaces stay: a diver filing conditions still says how the
coral looked, and a diver doing a survey records colonies.

A survey is a header plus its colony rows. See
[coral-surveys.md](./coral-surveys.md) for the instrument, the arithmetic and
the reasoning.

| `coral_surveys` column | Type | Notes |
| --- | --- | --- |
| `id` | uuid PK | |
| `created_at` / `updated_at` | timestamptz | |
| `diver_id` | uuid → `auth.users` | The surveying diver |
| `site_id` | uuid → `dive_sites(id)` | `ON DELETE RESTRICT`, as for the almanac |
| `surveyed_on` | date | Unique with `site_id` and `diver_id` — a second submission is a revision |
| `surveyed_at` | time | Chart matching is done by eye under ambient light, so time of day is not comparable across a day |
| `depth_m` / `water_temp_c` | numeric(4,1) | Optional; 0–100 m, −2–40 °C |
| `survey_method` | text | `random` / `transect` / `quadrat`, default `random` |
| `transect_length_m` | numeric(5,1) | Only meaningful for a transect |
| `notes` | text | Optional |
| `status`, `approved_by`, `approved_at`, `staff_notes` | | Moderation, exactly as the almanac |

| `coral_survey_colonies` column | Type | Notes |
| --- | --- | --- |
| `survey_id` | uuid → `coral_surveys(id)` | `ON DELETE CASCADE` |
| `ordinal` | integer | Position in the survey, 1–100 |
| `coral_type` | text | `branching` / `boulder` / `plate` / `soft` |
| `lightest_hue` / `darkest_hue` | text | Chart columns `B` / `C` / `D` / `E` |
| `lightest_level` / `darkest_level` | integer | Chart rows 1–6; 1 is bleached, 6 fully pigmented. `darkest_level >= lightest_level` is a check constraint — the chart is read palest first, so the reverse is a transposed pair |
| `diameter_cm` | numeric(5,1) | Optional |

Writes are RPC-only: `authenticated` holds SELECT and nothing else.
`submit_coral_survey()` files or revises (replacing the colony list wholesale),
`moderate_coral_survey()` rules, `coral_surveys_in_range()` reads approved
surveys with their colonies aggregated in, and `coral_pending_surveys()` is the
staff queue.


## Row-Level Security

RLS is **on** for every `public.*` table. The important patterns:

- **Two SECURITY DEFINER helpers do the role checks** so policies
  don't recurse into `profiles` RLS:
  - `public.is_admin()` — caller's profile has `role = 'admin'`
  - `public.is_staff_or_admin()` — caller's profile has `role in
    ('admin','staff')`
- **Diver-owned rows:** a diver reads, inserts and updates their own
  `bookings` (`auth.uid() = user_id`; a parent account may do the same for
  its children), reads their own `payments`, and owns their
  `push_subscriptions`. Payments are admin-inserted.
- **Staff+admin read** on `profiles`, `bookings`, `payments`,
  `admin_notes`, `diver_notes`. Writes on those tables stay admin-only
  except `admin_notes` / `diver_notes` (staff can insert their own).
- **`bookings` is largely immutable** for divers post-insert. RLS gates
  the row, two triggers gate the columns:
  `bookings_detail_lock_trg` (`bookings_block_diver_detail_edits`, in the
  baseline) refuses a non-admin change to `details`, and
  `trg_bookings_guard_diver_status` (`20260713010000`, revised since)
  lets a diver create a booking only as `pending` / `waitlisted`, change
  its status only to `cancelled`, and never move it to another event or
  touch the cancellation-settlement columns. Admins can mutate anything
  via the `is_admin()` policy.
- **Service-role bypasses RLS.** The push cron + the
  `create-registration` edge function both use the service-role key
  for this reason — they need to write under multiple users' identities.
- **Tables with no user-facing policies** (`push_notifications_sent`,
  `admin_audit_log`) are service-role-only or admin-only — RLS is on
  but no `for select` to authenticated, so anon/diver reads return
  zero rows.

## Migrations

Forward-only. **Never edit a migration that has been released.**
Applied migrations are locked — the registry in `supabase_migrations`
will refuse the push if a checksum changed.

To evolve a table, write a new migration that does `alter table …` or
adds a column / constraint / policy. File naming is
`YYYYMMDDHHMMSS_<slug>.sql`.

### Migration history

`ls supabase/migrations/` is the source of truth; this list is a map of it.

The lineage starts with a **single squashed baseline**,
`20260708090000_squashed_baseline.sql`, which captures the whole schema as of
the unified-`events` rebuild: the `events` model, the catalog tables, every
RLS policy and trigger, the SECURITY DEFINER RPCs (`event_ride_seats`,
`sign_waiver`, `apply_credit_to_booking`, `set_event_relations`, …) and the
migration-seeded reference data (`cert_levels`, storage buckets). A fresh
database is one baseline apply, not a replay of the per-feature history the
platform grew in early development.

Everything after it is a forward migration:

- **Travel.** `20260708200000_packages_registration` turns Packages into a
  partner-shop registration flow with price tiers (dropping the old
  `package_referrals` referral codes); `20260708210000_scheduled_trip_registration`
  lets a diver register for a scheduled trip directly. See
  [packages.md](./packages.md).
- **Shop-authored legal text.** `20260709120000_shop_authored_waivers` moves the
  waiver catalog out of code into `waivers` plus the `waiver-pdfs` bucket and
  gives cancellation policies CRUD metadata; `20260710120000_shop_authored_terms`
  does the same for the Terms of Use; `20260711200000_waiver_signature_content_snapshot`
  binds each signature to the exact content signed; `20260731000000_waiver_in_person`
  adds `admin_record_paper_waiver()`; `20260803000000_terms_consent_by_email`
  adds one-time acceptance links for divers who never sign in.
- **Booking integrity.** `20260713000000_block_credit_on_cancelled_booking`
  and `20260713010000_guard_diver_booking_status` stop credit flowing into a
  cancelled booking and stop a diver setting their own status;
  `20260720030000` / `20260720040000` stop the waitlist offering spots on a
  cancelled event and expire offers already stranded there;
  `20260824060000_booking_created_by` records who put a diver on an event;
  `20260827100000_event_cancel_cancels_its_bookings` makes a shop-side
  cancellation cancel the registrations on it.
- **Event kinds and event shape.** `20260720000000_add_adventure_event_kind`
  (the third kind, and the worked example of the vocabularies a kind
  touches); `20260804000000_event_series` (recurrence);
  `20260805000000_create_events_atomically` (`create_events_with_relations()`,
  so an event and its junction rows land in one transaction);
  `20260806000000` / `20260810000000` drop the dead `starting_at` and
  `second_image` columns; `20260813000000_restrict_private_events_to_participants`;
  `20260821000000_events_has_transport`; `20260911120000_event_gear_included`;
  `20260925100000_event_enters_water`, renamed to `involves_scuba` by
  `20261022100000`.
- **Money.** `20260720010000`, `20260720020000`, `20260720050000`,
  `20260720060000` and `20260729000000` let a parent read and spend for a
  child, net refunds out of "paid", clamp a deposit to what is owed and net a
  booking's own credit out of a group payment; `20260723000000`,
  `20260823000000`–`20260823040000` and `20260824050000` return a cancelled
  booking's money as credit to whoever paid it, record where each credit
  came from, reclaim it on restore, and let an admin record that the shop
  keeps it; `20260824000000_payment_reference`,
  `20260824010000_credit_settled_by` and `20260824020000_booking_cancelled_stamp`
  attribute every money movement; `20260824030000_account_charges` and
  `20260901000000_account_refunds` add signed account rows;
  `20260824040000_nonrefundable_deposit` adds `deposit_refundable`;
  `20260827400000_audit_the_money_tables` audits `payments` and `credits`;
  `20260831130000_shop_authored_payment_methods` and
  `20260912100000_event_discounts` add the shop's payment methods and
  discounts. See [payments.md](./payments.md).
- **Transport.** `20260724000000_ride_groups_shared_transport` adds
  `event_ride_groups` and measures `event_ride_seats()` across the whole run;
  `20260724010000_server_side_ride_waitlist` computes
  `details.ride_waitlisted` in the database. See
  [admin.md](./admin.md#transport-runs-seats-riders).
- **Dive logs.** `20260726000000`, `20260730000000`, `20260801000000` and
  `20260809000000`: a pinned trigger `search_path`, a title and arbitrary
  dive numbers, one companion column, and wetsuit thickness.
- **Staff and accounts.** `20260802000000_admin_manages_staff_availability`;
  `20260811000000` adds `profiles.compensated` and `20260812000000` drops it
  again (who is paid is inferred from the roster);
  `20260814000000_cap_child_accounts_per_parent`;
  `20260815000000_shared_user_action_rate_limit`;
  `20260831120000_signup_active_by_default` (signup is no longer an
  application); `20260910100000_normalize_profile_cert_and_nationality`;
  `20260923100000_drop_profile_nickname`.
- **Crowdsourced observations.** `20260818000000_almanac_records` and
  `20260820000000_almanac_by_dive_site` (observations filed against a
  `dive_sites` place rather than an event); `20260822000000_coral_surveys`;
  `20260827200000` / `20260905100000` (trash, then trash bands);
  `20260827300000_crowdsourced_dive_sites`; `20260905110000_almanac_withdraw`;
  `20260827500000_dive_site_maps`, `20260827600000_site_maps_admin_only` and
  `20260828000000_dive_site_entries` (see [dive-site-maps.md](./dive-site-maps.md));
  `20260909100000`–`20260909140000` (the wildlife taxon catalog, its seed,
  the free-text backfill, three catalog additions, and multi-name proposals —
  see [wildlife-taxa.md](./wildlife-taxa.md)).
- **Shop identity.** `20260905120000_shop_authored_contact` (`shop_contact`,
  `contact_channels`); `20260910200000_shop_profile`.
- **Logistics.** `20260928100000_packed_pieces` (the shared pack list);
  `20261021100000_nondiver_options`.
- **Catalog cleanup.** `20260827000000_list_every_viewable_trusted_partner`;
  `20261029110000_image_refs_to_local_paths` and
  `20261029120000_drop_legacy_catalog_columns` (the last imported website
  fields).
- **Backups.** `20260905000000_backup_table_inventory` names the tables the
  CSV backup exports.
- **Grants.** `20260720070000`, `20260808000000`, `20260911100000` and
  `20260911110000` take EXECUTE on privileged functions, and every write
  privilege, away from `anon`; `20261116130000_lock_down_adopted_grants`
  reapplies those revokes and default privileges idempotently, for a
  database adopted with `--applied-through` that recorded the earlier files
  without running them (a no-op on a fresh install).
- **Course continuation.** `20261116110000_course_continuation` adds
  `bookings.continues_booking_id` and `attend_days` plus the
  `create_course_continuation()` RPC that owns the rules (see
  [events-and-bookings.md](./events-and-bookings.md#one-course-several-scheduled-courses));
  `20261116120000_event_id_not_null` declares `event_id` NOT NULL on
  `bookings`, `event_vehicles` and `event_waivers`, which their
  `*_event_present` checks already enforced. Both are idempotent so an
  adopted database runs them as no-ops.

## `BookingDetails` JSONB shape

Defined in `src/types/database.ts` — that file is the source of truth.
DB only enforces `jsonb_typeof(details) = 'object'`. Current shape:

```ts
interface BookingDetails {
  gear?: {
    rent: boolean
    included?: boolean              // event bundles gear (e.g. OW course)
    items?: string[]                // chosen gear items (à-la-carte is the
                                    //   only way gear is rented)
    assistance_note?: string        // diver picked "ask a human"; their note
                                    //   (when set, rent is false)
                                    // no sizes here: what fits a diver lives
                                    //   on their profile, which is what the
                                    //   pack list and the fit lookup read
  }
  room?: { option_id?: string | null; notes?: string | null }
  add_ons?: string[]                // addons.id list
  nondiver_option?: { id: string; label: string }
                                    // set when this person registered as a
                                    //   non-diver; label snapshotted from the
                                    //   catalog by create-registration.
                                    //   Absent = a diver
  discount_requests?: string[]      // discounts.id list, IN-FLIGHT ONLY: the
                                    //   register form sends it,
                                    //   create-registration turns each into a
                                    //   booking_discounts row and strips the
                                    //   key. Never present on a stored booking
  transportation?: boolean
  ride_waitlisted?: boolean         // computed by a DB trigger, never trusted
                                    //   from the client (see admin.md)
  payment_method?: string           // payment_methods.key the diver chose
  credit_card_invoice_email?: string // billing address for an emailed invoice
  pay_deposit_only?: boolean        // deposit-only-at-registration flag
  nitrox_course_addon?: boolean
  total?: number                    // final-charge snapshot
  deposit?: number                  // prices.deposit_amount snapshot
  credit_applied?: number           // account credit elected at checkout,
                                    //   for the PDF; never rewrites total
  charges?: ChargeLine[]            // itemized snapshot — see below
  cancellation_policy_acked_at?: string  // gate for submit when policy attached
  cert_card_ack_at?: string         // cert-card photo deferred, terms accepted
  prereq_acked_at?: string          // unmet prerequisite acknowledged
}
```

A course continuation's details are written by `create_course_continuation()`,
not the register form: the source booking's `gear`, `total` and `deposit` of
0, one zero `adjustment` charge line, and a `course_continuation: true` marker
the type does not declare (the app reads `continues_booking_id` instead).

`discount_requests` is the one key that never survives the write. A discount
is worth nothing until an admin approves it, so letting the frozen details
carry it would give the booking a second, unapproved account of what it owes —
see [payments.md § Discounts](./payments.md#discounts).

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
