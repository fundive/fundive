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
| `urls.site` / `app` / `radio` | Your marketing site, the app origin, and (optional) radio stream. No trailing slashes. |
| `locale.timezone` | IANA zone, e.g. `Asia/Taipei` or `America/Los_Angeles`. |
| `locale.currency` / `currencyLabel` | ISO code and the label shown in the UI. |
| `theme.themeColor` / `backgroundColor` | **PWA manifest** colors (browser chrome + splash). See the note below about the in-app brand palette. |
| `assets.*` | Paths to your branding files under `public/` — see §2. |
| `features.radio` / `push` / `broadcast` | Toggle optional features off if you don't run them. |
| `business.gearItems` / `gearPrices` | Your rental gear list and per-item prices. |
| `business.paymentDeadlineFallbackDays` / `cardSurchargePercent` | Payment defaults. |
| `business.tripKeywords` | Case-insensitive regex fragments that classify a dive as a "trip" by title. Empty = never. |
| `weatherRegion` | Lat/long + label for the admin weather baseline. |

> **Brand color palette.** `theme.*` in the config only sets the PWA manifest
> theme/background colors. The in-app brand palette (`brand-*`, `surface-*`,
> `accent`) is defined as Tailwind `@theme` tokens in
> [`src/index.css`](https://github.com/fundive/fundive/blob/main/src/index.css) — edit those tokens to recolor the app.
> Status colors (emerald/amber/danger-red) and the categorical event-type
> rainbow intentionally stay on the raw palette; leave them.

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

## 3. Terms of Use & privacy — `src/config/terms.tsx`

[`src/config/terms.tsx`](https://github.com/fundive/fundive/blob/main/src/config/terms.tsx) is a shop-specific seam:
rewrite its copy to match your own legal posture. It reads `app.name`,
`app.shortName`, and `app.supportEmail` from your config, so those interpolate
automatically. The page chrome and the versioned re-acceptance flow live in core
and don't change per shop — but bump `CURRENT_TERMS_VERSION`
([`src/lib/terms-version.ts`](https://github.com/fundive/fundive/blob/main/src/lib/terms-version.ts)) whenever you change
the wording materially, so every diver is re-prompted to accept. A lawyer pass is
recommended before going live.

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
2. Deploy the two Cloudflare Workers. The **recommended** path is the GitHub
   Actions workflow (`.github/workflows/deploy.yml`) sourcing `CLOUDFLARE_*` +
   `VITE_*` from repo secrets; `make deploy` is the local equivalent.
3. Set the push-worker secrets (`wrangler secret put`) and edge-function secrets
   (`supabase secrets set`) — see [deployment.md](./deployment.md).

Because FunDive runs as a network service under the AGPL, keep a visible link to
your source from the deployed app (see the [README](https://github.com/fundive/fundive/blob/main/README.md#license)).
