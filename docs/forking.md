# Forking FunDive for your shop

FunDive is built to be cloned and run per dive shop. A working fork is three
changes: your **config**, your **branding assets**, and your **infrastructure
credentials**. Nothing about your shop should live in application source — if you
find yourself editing `src/`, that's a signal it should be a config field or an
upstream feature instead.

This guide walks each piece. For the full deploy mechanics see
[deployment.md](./deployment.md); for the platform-vs-deployment philosophy see
[architecture.md](./architecture.md).

## 1. `fundive.config.ts` — your shop's data

The root [`fundive.config.ts`](https://github.com/fundive/fundive/blob/main/fundive.config.ts) is **pure data** (no
imports, no React, no `import.meta.env`) read by the app, the service worker,
`vite.config.ts`, and the Deno edge functions. Its shape is checked against
`SiteConfig` ([`src/config/site.ts`](https://github.com/fundive/fundive/blob/main/src/config/site.ts)) at build time.
[`fundive.config.example.ts`](https://github.com/fundive/fundive/blob/main/fundive.config.example.ts) is a blank template —
copy it over and replace every value.

Walking the fields:

| Field | What to set |
| --- | --- |
| `configVersion` | Leave as-is; only bump when the CHANGELOG says to. |
| `app.name` / `shortName` | Full shop name and a short label (used for the PWA short name and staff-facing copy). |
| `app.description` / `logoAlt` | PWA description and logo alt text. |
| `app.supportEmail` | Where registration mail and support requests go. |
| `contact.*` | Phone, address, Google Maps URL, LINE / WhatsApp links, PayPal link. Leave a link empty to hide it. |
| `urls.site` / `app` / `radio` | Your marketing site, the app origin (also the share-link origin), and (optional) radio stream. No trailing slashes. |
| `locale.timezone` | IANA zone, e.g. `Asia/Taipei` or `America/Los_Angeles`. |
| `locale.currency` / `currencyLabel` | ISO code and the label shown in the UI. |
| `locale.language` | The one language the app renders in: `'en'`, `'zh-TW'` or `'ja'`. See [i18n.md](./i18n.md). |
| `locale.units` | Which side of the height/weight toggle a diver sees first: `'metric'` or `'imperial'`. Storage is always metric; each diver can flip it per browser. Not derived from `language` — a shop can render in English from a metric country. |
| `theme.themeColor` / `backgroundColor` | **PWA manifest** colors (browser chrome + splash). See the note below about the in-app brand palette. |
| `theme.design` | Visual design variant: `'light'` (default — light cards on navy) or `'dark'` (dark ocean glass). See the note below. Omit for `light`. |
| `assets.*` | Paths to your branding files under `public/` — see §2. |
| `features.radio` / `push` / `broadcast` | Toggle optional features off if you don't run them. |
| `business.gearItems` / `gearPrices` | Your rental gear list and per-item prices. See the note below on renaming items and on stocking one item in several styles. |
| `business.paymentDeadlineFallbackDays` | Fallback full-payment deadline when an event sets none. Per-method payment surcharges are not config — they live on the `payment_methods` rows an admin edits at `/admin/payment-methods`. |
| `business.tripKeywords` | Case-insensitive regex fragments that classify a dive as a "trip" by title. Empty = never. |
| `business.eventDurationHours` | How long a single-day event runs, for the "Add to Google Calendar" link. Optional — omit for 8. |
| `weatherRegion` | Lat/long + label for the admin weather baseline. |

> **Event sharing.** The in-app "share this event" button needs no toggle: it
> copies `<urls.app>/register/<event id>`, the app's own public registration
> page. That route sits outside the auth gate, so whoever the link reaches sees
> the event and can sign up. Set `urls.app` correctly and sharing works.

> **Add to Google Calendar.** Also needs no toggle and no Google account of
> your own: the button is a plain link to Google's event-template screen, which
> the diver saves into *their* calendar. There is no OAuth, no API key and no
> subscription feed, so nothing syncs back — an event you reschedule later does
> not update the copy a diver already saved.

> **Gear catalog.** `business.gearItems` is the one list behind three surfaces:
> the profile's "Gear I own" checklist, the à-la-carte rental checklist at
> registration, and the logistics packing totals.
>
> **`gearPrices` decides what you rent.** Its keys are the subset of `gearItems`
> that appears in the rental checklist, each with its daily price. An item left
> out is *owned-only*: a diver can still record that they own one, and you never
> offer it. There is no second list to keep in sync — and a price for an item the
> catalog doesn't list is rejected by the config schema, because it otherwise
> fails silently, as an item nobody is ever offered.
>
> ```ts
> gearItems:  [..., 'Boots (rubber sole)', 'Boots (felt sole)', ...]
> gearPrices: { ..., 'Boots (felt sole)': 3, ... }   // rubber is owned-only
> ```
>
> Owned-only items stay first-class everywhere else: they count on the packing
> board if an older booking names one, and they resolve to the same sizing
> column. When any of the catalog is owned-only, the rental checklist says so,
> so a diver reads the short list as your whole rack rather than a broken form.
>
> Items are stored **by label**, in `profiles.gear_owned` and in
> `bookings.details.gear.items`. Renaming an entry on a shop that already has
> data therefore orphans those rows: the checklist silently drops the diver's
> choice and the packing board leaves the item off. Ship a forward migration
> that rewrites the old label alongside the config change — the same applies when
> an item stops being rentable, since bookings can still be carrying it — and
> leave `details.charges` alone, that being a frozen receipt of what the diver was
> charged, under the label they were shown at the time.
>
> **One item, several styles.** An item you stock in more than one style is
> listed once per style, with the style in trailing parentheses:
>
> ```ts
> gearItems: [..., 'Boots (rubber sole)', 'Boots (felt sole)', ...]
> ```
>
> The app reads a shared base name as **one slot on the diver**. Boots are the
> case this exists for — felt soles grip algae-covered rock on a shore entry,
> rubber is for boats, sand and walking, so a shop needs to know which pair to
> pack — but the rule is general (`'Wetsuit (3mm)'` / `'Wetsuit (5mm)'` behaves
> the same). What follows from a slot: the rental checklist starts with **one**
> style ticked — the first style you actually rent — so nobody is defaulted into
> paying for two pairs of boots; ticking one style unticks the others, reading
> alternatives from the whole catalog so a style you have since stopped renting is
> cleared even though no box is drawn for it any more; a diver who owns *any*
> style of an item rents none of them by default, though they can still tick a
> style they own another of; and course-bundled gear packs one of every rented
> slot rather than the raw catalog. The **profile** checklist has no exclusivity —
> owning both a felt and a rubber pair is a fact, not a conflict — and it shows
> one checkbox per slot ("Boots") with a styles dropdown beside it, so a diver
> ticks the item and then says which styles they own, one or several. Ticking the
> item records nothing on its own: which style they own is the question being
> asked, and guessing it would put the wrong pair on the packing board. Packing keeps
> the styles apart (separate racks), while sizing still resolves through
> `gearSizeSource`, so both are packed by shoe size.

> **Brand color palette.** `theme.*` in the config only sets the PWA manifest
> theme/background colors. The in-app brand palette (`brand-*`, `surface-*`,
> `accent`) is defined as Tailwind `@theme` tokens in
> [`src/index.css`](https://github.com/fundive/fundive/blob/main/src/index.css) — edit those tokens to recolor the app.
> Status colors (emerald/amber/danger-red) and the categorical event-type
> rainbow intentionally stay on the raw palette; leave them.

> **Design variant (`theme.design`).** Two complete looks ship in the box,
> selected by one config value:
> - `'light'` (default) — the light look: white cards floating
>   on a navy page, red accent hairline, rising-bubbles dashboard.
> - `'dark'` — a dark ocean look: frosted-glass panels on a deep
>   ocean-night gradient, reef-teal / mauve neon accents, monospace metadata,
>   squircle rounding, and an animated water-caustics dashboard background.
>
> `src/main.tsx` stamps the choice as `data-theme` on `<html>`. The palette,
> radius, fonts, and body background for each variant live in
> [`src/index.css`](https://github.com/fundive/fundive/blob/main/src/index.css)
> (the `@theme` block is `light`; `:root[data-theme="dark"]` overrides it); the
> per-surface class differences (white card vs glass, dark vs light ink) are
> chosen in [`src/styles/tokens.ts`](https://github.com/fundive/fundive/blob/main/src/styles/tokens.ts).
> To recolor a variant, edit those tokens — you don't need to touch components.

## 2. Branding assets in `public/`

A straight clone renders the reference shop's marks until you replace these. The
paths are whatever you set under `assets` in `fundive.config.ts`; the defaults
are:

| Config key | Default path | What it is |
| --- | --- | --- |
| `assets.logo` | `public/imgs/fd_logo.png` | Header / app logo |
| `assets.favicon` | `public/favicon.png` | Browser tab icon (see also `public/favicon.svg`) |
| `assets.icon192` | `public/icons/icon-192.png` | PWA icon (192×192) |
| `assets.icon512` | `public/icons/icon-512.png` | PWA icon (512×512) |
| `assets.appleTouchIcon` | `public/apple-touch-icon.png` | iOS home-screen icon |
| `assets.broadcast` | `public/imgs/broadcast.png` | Admin broadcast illustration |

Swap the files in place (keeping the paths) or point the config keys at new
paths. Also replace any social / OG preview image you reference so link previews
show your brand, not FunDivers TW.

## 3. Terms of Use & privacy — written in the app, not in code

Your Terms of Use live in the database, not in a source file. Sign in as an
admin and go to **Manage → Terms of Use**.

- The editor starts empty. **Load starter template** fills it with a
  fill-in-the-blanks draft, with your shop name and contact email already
  interpolated from `fundive.config.ts`. Every clause you must decide for
  yourself is marked `TODO` — replace all of them, and delete the disclaimer
  block at the top before publishing.
- The body is **Markdown**: headings, lists, bold, italic, code and `http(s)`
  links. Raw HTML is never rendered, so a stray `<script>` shows up as literal
  text rather than running.
- Tick **material change** when the substance changes. That bumps the version
  and every diver is asked to accept again on their next visit. Leave it
  unticked for a typo, so nobody is interrupted.

A fresh install shows an empty Terms page until you write one — deliberately,
so you never ship someone else's legal text. A lawyer pass is recommended
before going live.

## 4. Infrastructure credentials — `.env.local`

Credentials are per-account, not app data, so they never go in
`fundive.config.ts`. Copy [`.env.example`](https://github.com/fundive/fundive/blob/main/.env.example) to `.env.local` and
fill it in:

```sh
cp .env.example .env.local
```

Required for the app to boot / build: `VITE_SUPABASE_URL`,
`VITE_SUPABASE_ANON_KEY`, `VITE_TURNSTILE_SITE_KEY` (the build fails loudly
without these). Push, Supabase-migration, Cloudflare, push-worker, and
edge-function values are grouped and commented in the same file.
[deployment.md § Environment variables](./deployment.md#environment-variables)
maps each value to its final destination.

Worker names are infrastructure too, but they live in the two `wrangler.toml`
files ([`wrangler.toml`](https://github.com/fundive/fundive/blob/main/wrangler.toml) → `fundive-app`,
[`workers/push/wrangler.toml`](https://github.com/fundive/fundive/blob/main/workers/push/wrangler.toml) → `fundive-push`),
not in the config. Rename them there if you want a shop-specific worker name, and
set the push worker's non-secret `[vars]` (`VAPID_SUBJECT`, `ALLOWED_ORIGINS`,
`TIMEZONE`, `CURRENCY`) to your own values.

## 5. From fork to deploy

Once your config, assets, and `.env.local` are in place:

```sh
make start    # boot the local Supabase stack (Docker)
make dev      # verify your branding locally
make test     # unit + integration + security
```

Then point at your own backend and ship:

1. Create a Supabase project and apply the baseline migration: `make push`
   (needs `SUPABASE_PROJECT_REF` / `SUPABASE_DB_PASSWORD` in `.env.local`; run
   `make link` once first). `make verify` confirms the cloud schema matches.
2. Deploy the two Cloudflare Workers with `make deploy` (reads `CLOUDFLARE_*` +
   `VITE_*` from `.env.local`; no `wrangler login` needed).
3. Set the push-worker secrets (`wrangler secret put`) and edge-function secrets
   (`supabase secrets set`) — see [deployment.md](./deployment.md).

Steps 1 and 2 also exist as manual GitHub Actions in your fork — **Push
Supabase migrations** and **Deploy** — once you have put the same values in
Settings → Secrets → Actions. Useful when more than one person ships, or when
you would rather not keep production credentials on a laptop. See
[deployment.md § Deploying from GitHub Actions](./deployment.md#deploying-from-github-actions).

Because FunDive runs as a network service under the AGPL, keep a visible link to
your source from the deployed app (see the [README](https://github.com/fundive/fundive/blob/main/README.md#license)).
