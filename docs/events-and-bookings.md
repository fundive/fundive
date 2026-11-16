# Events & bookings

## Event data flow

**One table drives the calendar:** `events`, discriminated by `kind`
(`dive` | `course` | `adventure`). Dives and adventures carry a
`start_date` / `end_date` envelope; courses run on an explicit list of days
([`course_days`](#course-days)). Which shape a kind uses is
a question you ask — `usesDateEnvelope(kind)` / `usesCourseDays(kind)` from
`src/lib/event-kinds.ts` — never a `kind === 'dive'` test. See
[data-model.md](./data-model.md#ask-what-a-kind-does).

Normalization into a uniform `AppEvent` type happens in `src/lib/events.ts`:

- `fetchEventsInRange(fromDate, toDate)` — calendar month views.
- `fetchEventsForBookings(eventIds)` — bookings / payments pages that need to
  show event info alongside a booking row.
- `fetchUpcomingEventDays()` — the dashboard's next-days strip.

Both range queries filter on `DATE_ENVELOPE_KINDS` / `COURSE_DAY_KINDS`
rather than naming kinds, so a new kind joins the right query the moment it
answers `usesDateEnvelope`. Every UI surface reads `AppEvent`, not raw
`events` rows.

### `AppEvent` shape (abbreviated)

```ts
{
  id: string                 // events.id (uuid)
  type: EventKind            // 'dive' | 'course' | 'adventure'
  title: string              // display_title || admin_title || fallback
  calendar_title: string | null   // short label for the calendar grid pill
  start_time: string         // ISO timestamp (shop-local, composed from the row)
  end_time:   string | null
  start_time_hhmm: string | null  // 'HH:mm', null when no time is set
  price:      number | null
  deposit_amount: number | null
  transport_price: number | null
  currency:   string         // locale.currency
  capacity / confirmed_count / fully_booked / cancelled_at / is_private
  is_boat_dive?: boolean     // dive-only flag (independent of is_trip)
  is_trip?:      boolean      // dive / adventure; surfaced under Scheduled Trips
  has_rooms / room_type_ids / has_addons / addon_ids / nitrox_required / dive_days
  gear_included / gear_rental_info
  details?: EventDetails | null   // the calendar modal's descriptive block
}
```

`src/types/database.ts` is the full, commented definition.

### Trip & boat-dive flags

Two independent booleans on a dive event, both default `false`, both toggled in
the admin `EventForm` (dive-only):

- **`is_trip`** — a per-event admin classification marking the dive as a trip.
  This is a deliberate admin choice per event — distinct from the calendar's
  *cosmetic* trip coloring, which is keyword-driven via `business.tripKeywords`
  (see [configuration.md](./configuration.md)). The diver-facing **Scheduled Trips** page
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
(a `date[]`, 1–4 entries — DB CHECK `events_course_has_days`, which also
enforces that a `kind = 'course'` row has them at all; `errorMessage()`
in `src/lib/errors.ts` turns a violation into the course-days message
("A course needs between 1 and 4 days") rather than the generic one). Admins
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
   event is `fully_booked`. On an event that offers non-diver options,
   each person on the booking also picks what they register as (see
   [§ Non-diver options](#non-diver-options)).
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

Whether a gear question is put at all is one admin-set column,
`events.gear_included`, ticked on the event form. Ticked means the diver
is neither asked nor billed for gear: the fee already covers a set (Open
Water, Discover Scuba) or nobody scuba dives (a classroom course, a
non-scuba outing). Nothing infers it — the substring match on course
titles that used to decide this at registration time now survives only
as `suggestsGearIncluded()` in `src/lib/gear.ts`, which pre-ticks the box
on the event form and can be overruled. The edge function re-reads the
column and overwrites the request's gear block, the same way it does the
ride answer, so a crafted body cannot buy gear the event does not sell.

`gear_included` alone does not say whether a set physically goes out.
Two events answer it the same way and want opposite things from the
logistics board: a Discover Scuba bundles a full set that still has to
fit somebody, a hike needs none. `packsAGearSet()` separates them on
`kindInvolvesScuba()` — an event that dives records
`gear: { rent: false, included: true }` and has `FULL_GEAR_SET` packed;
an overland outing records plain `{ rent: false }` and nothing is packed.
Deliberately a question about the kind, not about `dive_days`: that
column is optional, and a course that leaves it null would stop packing
sets for the students who own none.

A packed set is exactly why the size question still has to be put:
nobody chose the items, but the shop still has to pack ones that fit.
`needsShoeSize()` in `src/lib/logistics.ts` answers that for both
register flows, of the à-la-carte selection in one and of the assumed
full set in the other.

The same question is put for each additional diver the lead is booking,
because they are the ones most likely to have no size on file. A shoe
size the lead supplies there is the **only** thing that reaches another
diver's profile — `profile_patch` is otherwise empty for a fanned-out
booking — and it is only asked for when that profile hasn't got one, so
it fills a blank rather than overwriting a value.

### Non-diver options

Someone who comes on a trip without diving — a partner who snorkels, a
friend who rides the boat — registers at their own fee. The shop names
those ways in once at **Manage → Non-diver options**
(`/admin/nondiver-options`, `nondiver_options`): a label, a description, a
price and an optional deposit. The event form's **Non-diver options**
section ticks which of them an event offers (`event_nondiver_options`,
written with the event's other relations by `set_event_relations` /
`create_events_with_relations`).

On an event that offers at least one, step 1 asks each person "Registering
as": **Diver** at the event's price, or one of the options at its own.
Each person on a family booking chooses separately, so a parent can dive
while a child snorkels. The choice replaces two figures and nothing else:

- the **base** — the option's `price` instead of the event's diver price;
- the **deposit** — the option's `deposit_amount`, or none when it has
  none. That person then pays in full even when the rest of the group pays
  deposits.

The rest of the form is unchanged: a non-diver is asked about gear, room,
add-ons and the ride exactly as a diver is, and billed for what they pick.
The one exception is a gear-included event (Discover Scuba, Open Water):
the bundled set is scuba kit, so a non-diver gets none. The form asks no
size for it and records `gear: { rent: false }` rather than
`{ included: true }`, and `create-registration` forces the same, so the
logistics board packs nothing for them.

The booking records the choice as `details.nondiver_option = { id, label }`
and the base charge line reads `Non-diver: <label>`. `create-registration`
checks the option is offered on that event and still active — refusing the
booking (422) otherwise, rather than quietly pricing the person as a diver —
and takes the price, deposit and label from the catalog, never from the
request. The admin event page shows the option on the person's card.

The multi-event cart (`MultiRegisterForm`) offers the same choice on each
cart row whose event offers options, priced and recorded the same way.

An admin editing a booking keeps the option it was made under even after
the event stops offering it (`fetchNondiverOptionsForBooking`): the option
is re-read from the catalog, or, if it was deleted, rebuilt from the
booking's label and frozen base charge. Without that, the form would find no
match and saving would re-price the person as a diver.

### Price composition

```
total = base_price      (the event's diver price, or the person's
                         non-diver option price)
      + gear_cost       (0 when events.gear_included; otherwise
                         à-la-carte only: ∑ per-item × days for the
                         chosen items)
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
[configuration.md](./configuration.md). The surcharge comes off the chosen `payment_methods`
row instead, since it varies per method — see
[payments.md § Payment methods](./payments.md#payment-methods). Gear is
à-la-carte only — there is no full-set package. **Transport** is a per-event
integer on the linked `prices.transport` row, surfaced on `AppEvent` as
`transport_price` (a `surcharge` of 0 means transport is bundled into the base
price rather than added).

**A discount is not in that formula.** The form quotes the undiscounted
price and says so: ticking a discount records a request an admin still has
to approve, and until they do it changes no figure the diver is shown or
the booking stores. See [payments.md § Discounts](./payments.md#discounts).

`buildCharges()` in `src/lib/booking-charges.ts` turns these into an
itemized `ChargeLine[]` that is both shown in the form summary and
snapshotted onto the booking as `details.charges`, so the breakdown is
frozen against later price changes (see
[data-model.md § BookingDetails](./data-model.md#bookingdetails-jsonb-shape)).

### What gets written

The form does **not** write to `bookings` directly. It invokes the
`create-registration` Supabase Edge Function
(`supabase/functions/create-registration/handler.ts`, wired up by
`index.ts`) which atomically:

1. Resolves `event_id` against `events` and rejects an event whose last
   day has passed (`eventHasPassed`; admins and staff bypass it) before
   doing anything expensive.
2. (Guest path only) Creates the auth user with `email_confirm: true`
   so a typo'd address is rejected loudly instead of silently dropped.
3. Updates `profiles` from `profile_patch`.
4. Inserts one row into `public.bookings` (under service-role, so RLS
   doesn't apply at this stage):
   - `user_id`, `status: 'pending'`
   - `event_id` — the single FK to `events`. The request body also
     carries `event_type` (the `kind`), which the function uses for the
     has-it-passed check and to read the right dates for the emailed copy
     (`usesCourseDays(event_type)` picks `course_days` over the envelope)
   - `notes` — free-text field from the form
   - `created_by` — who is doing the registering, taken from the verified
     Bearer token, never from the body. See below.
   - `details` JSONB — see
     [data-model.md § BookingDetails](./data-model.md#bookingdetails-jsonb-shape).
     `total` / `deposit` / `charges` are snapshots, and the function
     **recomputes `total` and `deposit` server-side** from the event's
     linked `prices` row (`computeBookingMoney`) rather than trusting the
     client's figures — they are what `apply_credit_to_booking` and
     `record_group_payment` read, so a crafted request must not be able to
     set its own.
5. Inserts one `booking_discounts` row per discount the diver ticked, each
   at `status: 'requested'`. The amount is never computed here and never
   comes from the request body; `booking_discounts_validate` refuses any id
   the event does not offer or the shop has retired, so a crafted list gets
   the same answer the form would have given — and a refused one does not
   fail a booking that already exists.
6. Builds a registration PDF (`supabase/functions/_shared/pdf.ts`) and
   sends it via Gmail SMTP to the shop (the `shop_contact` email, read
   through `_shared/shop-contact.ts`, falling back to the Gmail account)
   and the diver — unless `suppress_email` is set (group registration; see
   below).
7. Returns `{ booking_id, session? }` — `session` populated on the
   guest path so the SPA can `setSession()` without a second
   round-trip.

If the booking insert fails on the guest path the function rolls back
the just-created auth user so the diver can retry cleanly.

The **admin edit path** (`existingBooking` set) skips the edge
function and updates `bookings.notes` / `bookings.details` directly
under the admin's RLS — no PDF, no account creation.

### Who registered this diver

`bookings.created_by` answers it, and the admin event page shows
**"Added by &lt;name&gt;"** on any registrant whose booking somebody else
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

One exception: a **course continuation** inherits the `created_by` of
the booking it continues. It is the same registration split across two
event rows, so naming the admin who split it would be true of the row
and false about the registration — a diver who signed themselves up for
a course must not read as "Added by &lt;admin&gt;" on the half they
finish it in. The inheritance sits after the `authenticated` branch, so
a diver who forges `continues_booking_id` to borrow somebody else's
origin is still stamped as themselves. (The trigger reads the column
through `to_jsonb`, a leftover from when it predated the column; it
behaves the same.)

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

- **Prerequisite acknowledgment.** Personal details are optional:
  registering costs an email and a password, and nothing rejects a booking
  for a blank name or certification (a shop settles certification at the
  counter). What survives is the acknowledgment. An event whose
  prerequisite (`events.prereq_cert_id` / `req_dives`) the diver does not
  meet on their own profile — they declared themselves uncertified, or
  report fewer logged dives — shows a warning they must acknowledge
  (`details.prereq_acked_at`) before advancing; free-text certification
  levels are not rank-compared. A diver who names a level without a card
  on file must likewise accept the bring-your-card terms
  (`details.cert_card_ack_at`). The server-side rule lives in
  `supabase/functions/_shared/registration-eligibility.ts` (pure
  `eligibilityError`), which `create-registration` runs before inserting,
  returning **HTTP 422** and rolling back if an unacknowledged mismatch
  reaches it. Admin on-behalf-of registrations bypass the gate
  (`target_user_id` set).
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
  (`event_ride_seats` reports the run full — see
  [admin.md § Transport](./admin.md#transport-runs-seats-riders)), they are
  **not** blocked: the ride option stays selectable and the booking records
  `details.ride_waitlisted = true`, a flag the database computes rather than
  trusting the form. A DB trigger notifies admins so they can add a car or
  reshuffle. Seat capacity is the run's seats minus its on-duty staff, who
  take ordinary seats, so the number offered to divers is what's genuinely
  rideable.

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
conflict and the form shows an error. Cancelled rows are excluded, so a
diver who cancelled can register again.

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

## One course, several scheduled courses

A student who starts Open Water on the 10th and finishes it with the
course three weeks later is **one course, two events**. Migration
`20261116110000_course_continuation.sql` adds the two columns that say
so:

| Column | Meaning |
| --- | --- |
| `bookings.continues_booking_id` | The earlier booking this one continues (`ON DELETE SET NULL`). The earlier booking holds the money; the continuation is always zero-cost (`details.total = 0`, one stated zero `adjustment` charge line, `details.course_continuation = true`). `NULL` on a normal booking. |
| `bookings.attend_days` | Which of the event's `course_days` this diver is actually there for. `NULL` — every ordinary booking, and every diver doing the whole course — means **all of them**. An empty array is refused (`bookings_attend_days_non_empty`): a booking that attends no days should be cancelled. |

A continuation is created only by an admin, from the target course's
page (**Continue a course here** → `CourseContinuationModal`), which
calls the `create_course_continuation` RPC. The modal picks the diver,
then which of their other course bookings they started, then the days
they attend here. The RPC is where the rules live, not the form:
admin-only, both events must be courses, the target must not be
cancelled or be the same course, the days must belong to the target
course's `course_days`, the diver must not already be booked on it, and
a continuation cannot itself be continued (a third leg points at the
original booking, so "where is the money?" stays a lookup rather than a
walk). It optionally trims the *original* booking's `attend_days` in the
same call — the days the student actually attended before they
stopped — and carries the original's `gear` over, since the student
wears the same wetsuit on the days they finish. The zero charge line's
label is passed in so it reads in the deployment's language.

On the target course's roster a continuation carries a **Continuing**
badge, and either side of the pair shows "Attending … only" when its
`attend_days` is set.

`attend_days` is what keeps the day-level views honest. The logistics
day board (`fetchDayBoard` in `src/lib/day-board.ts`) filters every
booking through `bookingsOnDay()` (`src/lib/course-continuation.ts`), so
a student booked for the last two days of a course is not counted, or
packed for, on the first two. A `NULL` `attend_days` always answers
"yes, present", which is what keeps every other booking correct.

Capacity is deliberately unchanged: a continuing student occupies a real
seat on the second course and counts toward it like any other
registrant.
