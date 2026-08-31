# Events & bookings

## Event data flow

One `events` table drives everything shown on the calendar, discriminated by
`kind`:

- `kind = 'dive'` — single-session dives (scalar `start_date`/`end_date`/`start_time`).
- `kind = 'course'` — courses that run on an explicit list of days
  (`course_days`; see [#course_days](#course_days)).

Normalization into a uniform `AppEvent` type happens in `src/lib/events.ts`:

- `fetchEventsInRange(fromDate, toDate)` — calendar month views.
- `fetchEventsForBookings(eventIds)` — bookings / payments pages that need to
  show event info alongside a booking row.

Every UI surface reads `AppEvent`, not raw `events` rows.

### `AppEvent` shape (abbreviated)

```ts
{
  id: string                 // events.id (uuid)
  type: 'dive' | 'course'    // mirrors events.kind
  title: string              // display_title || admin_title || fallback
  start_time: string         // ISO timestamp (shop-tz-local, from the date/time columns)
  end_time:   string | null
  price:      number | null
  deposit_amount: number | null
  currency:   string         // from siteConfig.locale.currency
  is_boat_dive?: boolean     // dive-only flag (independent of is_trip)
  is_trip?:      boolean      // dive-only; surfaced under Scheduled Trips
  has_rooms / room_type_ids / has_addons / addon_ids / gear_rental_info / nitrox_required / dive_days
}
```

### Trip & boat-dive flags

Two independent booleans on a dive event, both default `false`, both toggled in
the admin `EventForm` (dive-only):

- **`is_trip`** — a per-event admin classification marking the dive as a trip.
  This is a deliberate admin choice per event — distinct from the calendar's
  *cosmetic* trip coloring, which is keyword-driven via `business.tripKeywords`
  (see [forking.md](./forking.md)). The diver-facing **Scheduled Trips** page
  (`src/pages/ScheduledTripsPage.tsx`) is now backed by its own admin-curated
  `scheduled_trips` table (via `list_scheduled_trips()`), **not** derived from
  this flag — see [data-model.md](./data-model.md). Also distinct from
  **Packages** ([packages.md](./packages.md)), which curates open-ended partner
  travel packages abroad with no fixed date.
- **`is_boat_dive`** — marks the dive as a boat dive (vs shore). Informational
  today; independent of `is_trip` (a trip may or may not be a boat dive).

Both are plain columns on `events` (`is_trip`, `is_boat_dive boolean not null
default false`) — see [data-model.md](./data-model.md). Neither is backfilled by
keyword; a fresh event starts `false` until an admin ticks it.

## Calendar rendering

`CalendarPage` (`src/pages/CalendarPage.tsx`) shows a month grid plus a
"This month" list below. The rendering has two quirks:

1. **Overscan.** It fetches events for `visible_month ± 7 days` so
   multi-day bars entering or leaving the month don't get truncated.

2. **Track-stacking** (`src/lib/calendar-layout.ts`):
   - Events are sorted ascending by `start_time`; longer events get
     lower tracks.
     - For each event, `assignTracks()` picks the lowest `track` index
     with no overlap against already-placed events.
   - Each cell caps at 3 visible tracks; overflow renders as `+N more`.
   - A bar that spans a week boundary is split: the left half ends at
     Sunday with `isEnd=true`, and a new segment starts Monday with
     `isStart=true` and `showTitle=true`. That way the title re-renders
     per visual row.

3. **Today marker.** Today's cell wears a `rose-900/30` background and
   a red day number.

### `course_days`

A course runs on an explicit list of dates: `events.course_days`
(a `date[]`, max 4 — DB CHECK `events_course_has_days`). Admins
enter each day in the event form. `courseToEvents()` in
`src/lib/events.ts` sorts + dedupes the list, groups **consecutive**
calendar days into one continuous segment, and emits one `AppEvent`
per run — exactly how a multi-day dive's `start_date..end_date` range
renders. Non-adjacent days emit separate pills.

| `course_days` | Segments emitted |
| --- | --- |
| `{05-10}` | `[05-10]` (single-day pill) |
| `{05-10, 05-11, 05-12}` | `[05-10 .. 05-12]` (one continuous bar) |
| `{05-10, 05-12}` | `[05-10]` + `[05-12]` |
| `{05-09, 05-10, 05-16}` | `[05-09 .. 05-10]` + `[05-16]` |

`start_date` / `end_date` are kept as the min/max **envelope** of
`course_days` so range fetches (`fetchEventsInRange` overlaps on the
envelope) and per-booking span lookups (`fetchEventsForBookings`) cover
every day the course exists on. Every segment shares the course `_id`,
so clicking any of them opens the same booking target.

## Register flow

Clicking an event in the calendar opens `RegisterForm`
(`src/components/register/RegisterForm.tsx`) — a four-step modal:

1. **Event info** — confirm title, dates, base price. Disabled if the
   event is `fully_booked`.
2. **About you** — name, date of birth, nationality, gender, height,
   weight, contact, certification. Every one of them optional (see
   below).
3. **Extras** — gear, room, add-ons, transport, nitrox course.
4. **Payment** — payment method + notes, final price summary.

### What the form insists on

Not personal details. Name, date of birth, nationality, gender, contact
handle, certification and gear sizes are all asked for and none of them
block the booking — the shop chases what it still needs later, and
`src/lib/profile-completeness.ts` says what that is. Four things do gate:

- **An account.** A guest supplies an email, a password (8+) and the
  terms checkbox, and solves the Turnstile captcha.
- **Evidence for a claim.** Naming a cert level, or ticking nitrox /
  deep, demands the card photo — or, for the main cert, the "I'll bring
  the physical card" acknowledgment. Claiming nothing demands nothing.
- **The booking's own decisions.** Whether a ride is needed, and whether
  gear is rented — the shop can't reserve a seat or pack a set on a
  blank. The ride question is skipped whole on an event whose
  `has_transport` is false (a dry course held at the shop): a question
  that was never put can't be left unanswered, and nothing gates on it.
- **Acknowledgments.** Event prerequisites the diver doesn't meet, and
  the cancellation policy.

`supabase/functions/_shared/registration-eligibility.ts` is the
server-side mirror, so a crafted request is held to the same short list.
The on-behalf-of paths (admin, parent) relax the first three further
still.

### Gear sizes

Height and weight are asked of every diver on step 2, whatever the event
— they are what `src/lib/gear-sizing.ts` matches a wetsuit and a BCD
against on the logistics board, and the diver who needs the fit is often
the one who never sees a rental question. Shoe size is narrower: it is
asked only when something goes on a foot, and only when the profile
hasn't already got one.

A gear-included course — Discover Scuba / Try Dive, Open Water, anything
`isGearIncludedCourse` recognizes — is a diver who owns nothing, so the
form assumes the full set (`FULL_GEAR_SET`) rather than asking, and the
booking records `gear: { rent: false, included: true }`. That assumption
is exactly why the size question still has to be put: nobody chose the
items, but the shop still has to pack ones that fit. `needsShoeSize()`
in `src/lib/logistics.ts` answers the question for both register flows,
of the à-la-carte selection in one and of the assumed full set in the
other.

The same question is put for each additional diver the lead is booking,
because they are the ones most likely to have no size on file. A shoe
size the lead supplies there is the **only** thing that reaches another
diver's profile — `profile_patch` is otherwise empty for a fanned-out
booking — and it is only asked for when that profile hasn't got one, so
it fills a blank rather than overwriting a value.

### Price composition

```
total = base_price
      + gear_cost       (0 if included; otherwise à-la-carte only:
                         ∑ per-item × days for the chosen items)
      + room_cost       (selected rooms.added_price)
      + addons_cost     (∑ addons.price for selected ids)
      + transport_cost  (event.transport_price if surcharge>0 and ticked;
                         else 0 — surcharge=0 means transport is bundled
                         and we render "Included with base price")
      + nitrox_course   (business.nitroxCourseFee if required-and-not-certified and ticked)
      + surcharge       (subtotal × the chosen payment method's surcharge_percent;
                         0 for a method that carries none)
```

Gear prices come from `business.gearPrices` in `fundive.config.ts`; the nitrox
fee is `business.nitroxCourseFee`, read through `NITROX_COURSE_FEE` in
`src/lib/booking-charges.ts` (shared by both register forms and the display-time
recompute). Both are shop-config fields, not literals — see
[forking.md](./forking.md). The surcharge comes off the chosen `payment_methods`
row instead, since it varies per method — see
[payments.md § Payment methods](./payments.md#payment-methods). Gear is
à-la-carte only — there is no full-set package. **Transport** is a per-event
integer on the linked `prices.transport` row, surfaced on `AppEvent` as
`transport_price` (a `surcharge` of 0 means transport is bundled into the base
price rather than added).

`buildCharges()` in `src/lib/booking-charges.ts` turns these into an
itemized `ChargeLine[]` that is both shown in the form summary and
snapshotted onto the booking as `details.charges`, so the breakdown is
frozen against later price changes (see
[data-model.md § BookingDetails](./data-model.md#bookingdetails-jsonb-shape)).

### What gets written

The form does **not** write to `bookings` directly. It invokes the
`create-registration` Supabase Edge Function
(`supabase/functions/create-registration/index.ts`) which atomically:

1. (Guest path only) Creates the auth user with `email_confirm: true`
   so a typo'd address is rejected loudly instead of silently dropped.
2. Updates `profiles` from `profile_patch`.
3. Inserts one row into `public.bookings` (under service-role, so RLS
   doesn't apply at this stage):
   - `user_id`, `status: 'pending'`
   - `event_id` → `events(id)`
   - `notes` — free-text field from the form
   - `created_by` — who is doing the registering, taken from the verified
     Bearer token, never from the body. See below.
   - `details` JSONB — see
     [data-model.md § BookingDetails](./data-model.md#bookingdetails-jsonb-shape)
     (`total`, `deposit`, and the itemized `charges` are snapshots).
4. Builds a registration PDF (`supabase/functions/_shared/pdf.ts`) and
   sends it via Gmail SMTP to the shop (`siteConfig.app.supportEmail`) and
   the diver — unless `suppress_email` is set (group registration; see below).
5. Returns `{ booking_id, session? }` — `session` populated on the
   guest path so the SPA can `setSession()` without a second
   round-trip.

If the booking insert fails on the guest path the function rolls back
the just-created auth user so the diver can retry cleanly.

The **admin edit path** (`existingBooking` set) skips the edge
function and updates `bookings.notes` / `bookings.details` directly
under the admin's RLS — no PDF, no account creation.

### Who registered this diver

`bookings.created_by` answers it, and the admin event page shows
**"Added by <name>"** on any registrant whose booking somebody else
made. No badge means they signed themselves up — the ordinary case, and
the silence is what makes the badge worth scanning for.

It is stamped, never accepted from a caller, for the same reason
`cancelled_by` is: a value a diver can write is a value a diver can
dispute. `trg_bookings_stamp_created_by` gives the three insert paths
three different answers, because only one of them runs as the person
doing it:

| Path | What is recorded |
| --- | --- |
| `authenticated` (PostgREST) | Forced to `auth.uid()`, ignoring anything sent |
| SECURITY DEFINER RPC | Falls back to `auth.uid()` — the JWT claim survives even though `current_user` is the owner |
| service_role (the edge function) | The value supplied, already resolved from a verified Bearer token |

The trigger carries one exception ahead of all three, inert until
FunDive takes the course-continuation feature: a booking that continues
another inherits that booking's `created_by` rather than naming the
admin who split it, because the two rows are one registration. It reads
`continues_booking_id` through `to_jsonb` precisely so it costs nothing
on a `bookings` table that has no such column.

An UPDATE never moves it: who made a booking is a fact about the past.
Deleting a profile sets it null (`ON DELETE SET NULL`) rather than
pinning the booking in place.

Reading it: `created_by = user_id` is "registered themselves". **Null is
not the same as self** — it means nobody can be named, which covers the
guest path (no account existed until the request that made the booking)
and every booking predating the column. Both render as no badge, so the
distinction only matters if you query it directly.

Note that PostgREST admits only two on-behalf inserts — self, and a
parent registering a child. An admin cannot reach `bookings` directly at
all, which is why Add diver goes through `create-registration`.

### Registration resilience & eligibility

Public registration is the app's highest-stakes flow (money + a new account over
a possibly-flaky phone connection), so it's hardened on four axes. All four are
**belt-and-suspenders**: enforced in the form for good UX and re-checked
server-side so nothing slips through.

- **Certification-declaration gate.** A diver must either name a certification
  level or explicitly tick **"I'm not certified yet"** before advancing — the
  cert-card *photo* is deferrable behind an acknowledgment, but the declaration
  isn't. Boat/deep events with a prerequisite (`events.prereq_cert_id` /
  `req_dives`) show a warning the diver must acknowledge. The shared rules live in
  `supabase/functions/_shared/registration-eligibility.ts` (pure `eligibilityError`),
  used both by the form's step-gating and by `create-registration`, which returns
  **HTTP 422** and rolls back if an ineligible diver reaches the server. Admin
  on-behalf-of registrations bypass the gate (`target_user_id` set). This is the
  path that previously let an under-documented diver book a boat dive.
- **Resume drafts.** `RegisterForm` autosaves its state to `localStorage` via
  `src/lib/registration-draft.ts` (key prefix `fd_reg_draft_v1`, keyed on
  event + user, 14-day expiry, debounced, skips the first render so it never
  clobbers a restore). If the diver drops off mid-registration, a **"Continue
  where you left off"** banner offers to reapply the draft; it's cleared on a
  successful submit.
- **Submit-retry + lost-response recovery.** The edge call goes through
  `invokeWithRetry` (`src/lib/edge-invoke.ts`), which retries **only** transient
  no-response errors (`FunctionsFetchError`/`FunctionsRelayError`) — never HTTP
  errors, so the dedupe guard below isn't hammered. If the *response* is lost
  after the booking was actually created, `fetchOwnBooking(userId, event)` looks
  the booking up by `event_id` and treats the duplicate as success instead of
  showing a spurious error.
- **Ride waitlist.** When a diver requests transport but no ride seat is free
  (`event_ride_seats` reports the fleet full — see
  [data-model.md](./data-model.md)), they are **not** blocked: the ride option
  stays selectable and the booking records `details.ride_waitlisted = true`. A
  DB trigger notifies admins so they can add a car or reshuffle. Seat capacity
  reserves the crew's seats (one per vehicle, rising to the full on-duty staff
  count), so the number offered to divers is what's genuinely rideable.

### Group registrations — one consolidated PDF

When a parent registers several divers together (the single-event
family picker in `RegisterForm`, or the multi-event cart in
`MultiRegisterForm`), every booking still goes through its own
`create-registration` call and shares a `group_id`. The difference is
email: each grouped call passes `suppress_email: true`, so
`create-registration` creates the booking but sends **no** per-diver
PDF. Once all the bookings land, the client calls
`send-group-summary` once with the shared `group_id`.

`send-group-summary`
(`supabase/functions/send-group-summary/handler.ts`) authorizes the
caller (must be a booked diver or the group's `payer_id`), reads every
booking in the group, and builds **one** consolidated PDF
(`buildGroupPdfBase64` in `_shared/pdf.ts`): a left column of field
labels plus one column per diver, two divers to a page, with a
group-total band summing every booking's `details.total`. It emails
that single PDF to the shop and the lead — N divers, one email each
way, instead of N separate PDFs. Solo registrations (one booking) are
unchanged: they still get the per-diver `buildPdfBase64` PDF.

The sibling bookings are not copies of each other. Everything that is a
property of the *trip* — room, add-ons, ride, payment method, the
acknowledgments — carries over from the lead's form unchanged, but the
gear question is asked once per diver, and the money follows it. Each
additional diver's question starts on the answer their own profile
implies (`needsRental` / `defaultRentalItems` over their `gear_owned`),
because a parent who owns a full kit is no evidence that their child
does; the lead can change any of it before confirming.

This is why the **cost summary** on `RegisterForm`'s payment step sums
the bookings rather than multiplying one of them. It still calls the
lead's figure a *per-diver* price when every booking really does come to
the same amount; when they differ it names each diver and their own
total above the group line.

The partial-unique index `bookings_one_active_per_user_idx`
(`(user_id, event_id) WHERE event_id IS NOT NULL AND status <> 'cancelled'`)
prevents a diver from double-booking the same event — Supabase returns a
conflict and the form shows an error.

## BookingsPage — the diver's view

`src/pages/BookingsPage.tsx` renders the diver's own bookings as
expandable cards, grouped into **Upcoming** and **Past / Cancelled**.
Each card shows:

- Title + start date + status badge
- Total, deposit (with ✓ or "due"), paid-so-far
- Breakdown (gear, room, add-ons, notes)

**Available actions per booking:**

- **Cancel booking** — only if `status === 'pending'` and
  `paidSum < deposit`. Sets `status = 'cancelled'`.
- **Request refund** — only if `paidSum >= deposit` and
  `refund_requested_at IS NULL`. Stamps the timestamp; the admin
  approves / denies in
  [admin.md § Event detail](./admin.md#event-detail).

## Non-obvious rules

- Bookings are **never deleted** by the app — status becomes
  `cancelled` instead. This preserves the payments ledger.
- Payment `method` on the booking is the diver's declared preference;
  the actual `payments.method` may differ (recorded by staff).
- `BookingDetails.deposit` can be missing or 0 when the event carries
  no `deposit_amount`. In that case `PaymentsPage` shows no
  "Deposit due" line for that booking.
