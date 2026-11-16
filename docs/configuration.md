# Making it your shop

A shop runs FunDive from its own small **deployment repository**, created with
`npx github:fundive/fundive init my-shop` (see the
[self-hosting walkthrough](./self-hosting.md)). It holds three things that are
yours: your **config**, your **branding assets**, and your **infrastructure
credentials and names**. There is no application source in it — if a change you
want needs `src/`, it is a new config field or an upstream feature, not
something to patch locally.

This guide walks each piece. For deploying see [deployment.md](./deployment.md);
for the platform-vs-deployment design see [architecture.md](./architecture.md).

## 1. `fundive.config.ts` — your shop's data

Your deployment's `fundive.config.ts` starts as a copy of
[`fundive.config.example.ts`](https://github.com/fundive/fundive/blob/main/fundive.config.example.ts),
every value a placeholder. It is **data only** — apart from the
`defineConfig` import that types it, no imports, no React, no
`import.meta.env` — and it is read by the app build, the service worker and
(as the `FUNDIVE_CONFIG` secret that `npx fundive functions deploy` sets) the
edge functions. Its shape is checked against `SiteConfig`
([`src/config/site.ts`](https://github.com/fundive/fundive/blob/main/src/config/site.ts))
at build time, so a mistake fails the build with the field's name rather than
misbehaving later.

Walking the fields:

| Field | What to set |
| --- | --- |
| `configVersion` | Leave as-is. A platform upgrade that changes the config's shape bumps it, and the build then tells you which field to update. |
| `identity.shopName` / `shortName` | Full shop name and a short label (used for the PWA short name and staff-facing copy). |
| `identity.appName` | The app's own name, shown beside the shop's. |
| `identity.tagline` | Printed in italics on the registration PDF. Blank omits it. No CJK: the PDF font has none. |
| `identity.description` / `logoAlt` | PWA description and logo alt text. |
| `urls.site` / `app` / `radio` | Your marketing site, the app origin (also the share-link origin), and (optional) radio stream. No trailing slashes. |
| `urls.eventPage` | Optional. A page per event on your own website, with `{id}` where the event id goes (`https://www.myshop.com/events/{id}`). Set it and the share button and calendar link point there instead of the app. |
| `locale.timezone` | IANA zone, e.g. `Asia/Taipei` or `America/Los_Angeles`. |
| `locale.currency` | The currency label shown with every price, e.g. `USD` or `NTD`. |
| `locale.language` | The one language the app renders in: `'en'`, `'zh-TW'` or `'ja'`. See [i18n.md](./i18n.md). |
| `locale.units` | Which side of the height/weight toggle a diver sees first: `'metric'` or `'imperial'`. Storage is always metric; each diver can flip it per browser. Not derived from `language` — a shop can render in English from a metric country. |
| `theme.themeColor` / `backgroundColor` | **PWA manifest** colors (browser chrome + splash). See the note below about the in-app brand palette. |
| `theme.design` | Visual design variant: `'light'` (default — light cards on navy) or `'dark'` (dark ocean glass). See the note below. Omit for `light`. |
| `assets.*` | Paths to your branding files under `public/` — see §2. |
| `features.radio` / `push` / `broadcast` | Toggle optional features off if you don't run them. Push needs the push worker ([push-notifications.md](./push-notifications.md)). |
| `business.gearItems` / `gearPrices` | Your rental gear list and per-item prices. See the note below on renaming items and on stocking one item in several styles. |
| `business.paymentDeadlineFallbackDays` | Fallback full-payment deadline when an event sets none. Per-method payment surcharges are not config — they live on the `payment_methods` rows an admin edits at `/admin/payment-methods`. |
| `business.nitroxCourseFee` | The price of the nitrox course a diver can add at registration. |
| `business.tripKeywords` | Case-insensitive regex fragments that classify a dive as a "trip" by title. Empty = never. |
| `business.boatManifest` | Boat name, registration and note lines that pre-fill the admin boat-manifest export. Printed verbatim, never translated. Blank is fine. |
| `business.eventDurationHours` | How long a single-day event runs, for the "Add to Google Calendar" link. Optional — omit for 8. |
| `weatherRegion` | Lat/long + label for the admin weather baseline. |

> **Contact details are not here.** Your email, phone, address, map link and
> the chat buttons on the Contact tab are **admin-edited rows**, not config:
> set them at Manage → Contact once the app is running. They were config fields
> until 20260905120000, and an email address that needs a developer, a build
> and a deploy to change is not a setting. A fresh install ships them empty —
> the Contact tab says so, and every surface that would print an address simply
> omits it — so filling them in is part of first-run setup. See
> [deployment.md](./deployment.md) and
> [data-model.md](./data-model.md#shop_contact).

> **Event sharing.** The in-app "share this event" button needs no toggle: it
> copies `<urls.app>/register/<event id>`, the app's own public registration
> page. That route sits outside the auth gate, so whoever the link reaches sees
> the event and can sign up. Set `urls.app` correctly and sharing works. If
> your website has its own page per event, set `urls.eventPage` and the link
> goes there instead.

> **Add to Google Calendar.** Also needs no toggle and no Google account of
> your own: the button is a plain link to Google's event-template screen, which
> the diver saves into *their* calendar. There is no OAuth, no API key and no
> subscription feed, so nothing syncs back — an event you reschedule later does
> not update the copy a diver already saved.

> **Gear catalog.** `business.gearItems` is the one list behind three surfaces:
> the profile's "Gear I own" checklist, the à-la-carte rental checklist at
> registration, and the logistics pack checklist.
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

> **Brand color palette.** `theme.*` in the config sets the PWA manifest
> theme/background colors and picks the design variant below. The in-app
> palette itself (`brand-*`, `surface-*`, `accent`) belongs to the platform, as
> Tailwind `@theme` tokens in
> [`src/index.css`](https://github.com/fundive/fundive/blob/main/src/index.css),
> so a deployment chooses between the two designs rather than recoloring one.
> A palette of your own is a platform change: propose it upstream.

> **Design variant (`theme.design`).** Two complete looks ship in the box,
> selected by one config value:
> - `'light'` (default) — the light look: white cards floating
>   on a navy page, red accent hairline, rising-bubbles dashboard.
> - `'dark'` — a dark ocean look: frosted-glass panels on a deep
>   ocean-night gradient, reef-teal / mauve neon accents, monospace metadata
>   and squircle rounding.
>
> `src/main.tsx` stamps the choice as `data-theme` on `<html>`. The palette,
> radius, fonts, and body background for each variant live in
> [`src/index.css`](https://github.com/fundive/fundive/blob/main/src/index.css)
> (the `@theme` block is `light`; `:root[data-theme="dark"]` overrides it); the
> per-surface class differences (white card vs glass, dark vs light ink) are
> chosen in [`src/styles/tokens.ts`](https://github.com/fundive/fundive/blob/main/src/styles/tokens.ts).
> Both are part of the platform; a deployment picks one with `theme.design`.

## 2. Branding assets in `public/`

Your deployment's `public/` is laid over the platform's: a file at the same
path in yours wins, and anything you leave out falls back to the platform's
placeholder. Until you add your own, the app shows FunDive's marks. The paths
are whatever you set under `assets` in `fundive.config.ts`; the defaults are:

| Config key | Default path | What it is |
| --- | --- | --- |
| `assets.logo` | `public/imgs/fd_logo.png` | Header / app logo |
| *(not in config)* | `public/favicon.svg` | Vector tab icon for browsers that prefer it |
| `assets.favicon` | `public/favicon.png` | Browser tab icon |
| `assets.icon192` | `public/icons/icon-192.png` | PWA icon (192×192) |
| `assets.icon512` | `public/icons/icon-512.png` | PWA icon (512×512) |
| `assets.appleTouchIcon` | `public/apple-touch-icon.png` | iOS home-screen icon |
| `assets.broadcast` | `public/imgs/broadcast.png` | Admin broadcast illustration |

> **The logo is the one asset a shop can change without a developer.** Upload it
> in **Manage → Shop Profile** and it takes effect immediately, in the app and on
> the registration PDF, overriding `assets.logo`. The rest of the table — the
> favicon and the PWA icons — is baked in at build time and still has to be
> swapped here.

Put your files at those paths in your `public/`, or point the config keys at
other paths. Event photos go there too (for example `public/imgs/media/`), and
an event's photo field takes that path. The merge happens when the build or
dev server starts, so a file added while `npx fundive dev` runs needs a
restart.

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

## 4. Infrastructure — `.env.local` and the two `wrangler.toml` files

Credentials are per-account, not app data, so they never go in
`fundive.config.ts`. Your deployment's `.env.example` lists them; copy it to
`.env.local` (gitignored) and fill it in:

```sh
cp .env.example .env.local
```

Every `npx fundive` command reads it. Required for a build:
`VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `VITE_TURNSTILE_SITE_KEY` (the
build fails loudly without them, or with a localhost URL or Cloudflare's test
captcha key). [deployment.md § Environment variables](./deployment.md#environment-variables)
maps each value to where it ends up.

Worker names are infrastructure too, and they live in your deployment's two
wrangler files, not in the config: `wrangler.toml` names the app's worker
(`fundive-app` until you change it) and holds your custom domain, and
`workers/push/wrangler.toml` names the push worker (`fundive-push`) and holds
its non-secret `[vars]` (`VAPID_SUBJECT`, `ALLOWED_ORIGINS`, `TIMEZONE`,
`CURRENCY`). Choose the names before the first deploy and keep them after: a
renamed worker is a new, second worker.

## 5. Deploying

The [self-hosting walkthrough](./self-hosting.md) takes a new shop from here to
a live app; [deployment.md](./deployment.md) is the reference for every command,
secret and workflow.

Because FunDive runs as a network service under the AGPL, keep a visible link to
your source from the deployed app (see the [README](https://github.com/fundive/fundive/blob/main/README.md#license)).

## Changing the platform itself

A fix or feature every shop could use belongs in FunDive: fork
[fundive/fundive](https://github.com/fundive/fundive), make the change there
(see [development.md](./development.md)) and open a pull request. Your
deployment picks it up by moving the commit or tag `package.json` pins.
