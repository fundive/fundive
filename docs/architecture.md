# Architecture

This document defines how FunDive is structured for self-hosting: the split
between the **platform** (this repository) and a **deployment** (each operator's
own repository), what is configurable, and what is not.

> Status: this describes the target architecture. The codebase is still being
> generalized from its field-test deployment at
> [Fun Divers Taiwan](https://www.fundiverstw.com) (a shop that helped test the
> app — see [About](./about.md)), so parts of this
> are a plan, not yet shipped. See
> [Status & roadmap](#status--roadmap).

## Philosophy: one platform, many thin deployments

FunDive is **open-source, self-hosted**. There is exactly one authoritative
codebase — this repository. Each dive center that runs FunDive does **not** fork
or copy the code. Instead they create a small **deployment repository** that
holds only *their* configuration — branding, infrastructure credentials, and
catalog data — and depends on a pinned version of the platform.

```
            ┌─────────────────────────────┐
            │   fundive/fundive (this)    │   the platform
            │   app + workers + migrations│   one authoritative codebase
            │   + the `fundive` CLI       │   versioned with semver tags
            └──────────────┬──────────────┘
                           │  depends on (pinned version)
        ┌──────────────────┼──────────────────┐
        ▼                  ▼                  ▼
 ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
 │ shop-a/site │    │ shop-b/site │    │ shop-c/site │   deployment repos
 │ config      │    │ config      │    │ config      │   only config + assets
 │ public/     │    │ public/     │    │ public/     │   never platform code
 └─────────────┘    └─────────────┘    └─────────────┘
```

The payoff: **upgrading is a one-line version bump.** A deployer changes the
pinned platform version, re-applies migrations, and redeploys — they never merge
code or resolve conflicts. Protecting that property is the primary constraint on
every design decision below.

## The deployment repository

A deployer's repo is small and contains no platform source.
`npx github:fundive/fundive init my-shop` creates it from the platform's
`template/`:

```
my-dive-shop/
  package.json                # depends on the platform, pinned to a commit or tag
  fundive.config.ts           # identity, URLs, locale, design, feature toggles, gear
  public/                     # logo, icons, photos — laid over the platform's public/
  wrangler.toml               # the app worker's name and domain
  workers/push/wrangler.toml  # the push worker's name, vars and crons
  .github/workflows/          # manual Deploy and Push-migrations buttons
  .env.example                # documents the credentials (committed)
  .env.local                  # the credentials themselves — GITIGNORED
```

### Consuming the platform (git dependency)

Deployments pin the platform as a **git dependency** — no npm registry
involved:

```jsonc
// package.json
{
  "name": "my-dive-shop",
  "private": true,
  "dependencies": {
    "fundive": "github:fundive/fundive#<commit or tag>"
  }
}
```

The toolchain the platform drives (vite, wrangler, the Supabase CLI) is among
its runtime dependencies, so `npm install` is the whole setup. The platform
exposes a CLI through its `bin` entry, and the deployment drives everything
through it:

```sh
npx fundive build             # production build with their config and branding baked in
npx fundive deploy            # the app worker, named by their wrangler.toml
npx fundive deploy push       # the push worker, named by their workers/push/wrangler.toml
npx fundive functions deploy  # the edge functions, with their config as FUNDIVE_CONFIG
npx fundive db push           # the platform's migrations, into THEIR Supabase
```

Pinning a commit or tag — not a branch — makes a deployment reproducible and
upgrades deliberate: move the pin, `npm install`, `db push`, deploy.
[deployment.md](./deployment.md) is the full reference.

## Configuration surface

Everything a deployer can change lives in their deployment repository: their
`.env.local`, their `fundive.config.ts`, their `public/` files, and their two
`wrangler.toml` files.

| Concern | Where | Example |
| --- | --- | --- |
| App identity | `fundive.config.ts` | shop name, tagline, URLs |
| Design | `fundive.config.ts` | light or dark, PWA colors |
| Branding assets | `public/` | logo, favicon, app icons, event photos |
| Feature toggles | `fundive.config.ts` | push, broadcast, radio |
| Supabase | `.env.local` | project ref, URL, anon key, DB password, access token |
| Cloudflare | `.env.local` + `wrangler.toml` | account id and API token; worker names and custom domain |
| Web Push | `wrangler secret put` + `workers/push/wrangler.toml` | VAPID keys; subject, origins, timezone |
| Email | `supabase secrets set` | Gmail account + app password for registration mail |
| Contact details, Terms, catalog | the admin UI | email, phone, Terms of Use, dive sites, courses, prices, rooms |

### `fundive.config.ts` (abridged)

```ts
import { defineConfig } from 'fundive/config'

export const siteConfig = defineConfig({
  configVersion: 13,
  identity: { shopName: 'Acme Divers', shortName: 'Acme', tagline: '', /* … */ },
  urls: { site: 'https://www.acmedivers.example', app: 'https://app.acmedivers.example' },
  locale: { timezone: 'America/Los_Angeles', currency: 'USD', language: 'en', units: 'imperial' },
  theme: { themeColor: '#0ea5e9', backgroundColor: '#0f172a', design: 'light' },
  features: { radio: false, push: true, broadcast: true },
  // assets, business (gear, prices, boat manifest), weatherRegion …
})
```

Every field: [configuration.md](./configuration.md).

Branding is resolved at **build time**: the platform's Vite build reads the
deployment's config through a virtual module, lays the deployment's `public/`
over its own, and bakes the result into the bundle. (Vite inlines env and assets at build time,
so each deployer builds their own bundle in their own CI — there is no shared prebuilt artifact, and secrets
never leave the deployment's environment.)

## The customization boundary

This is the most important line to hold, because it's what keeps upgrades cheap.

- **Deployment repo (no fork):** name, logo, design, which optional features
  are on, infrastructure names and credentials. Covered above. Catalog data
  (events, prices, dive sites) is entered in the running app.
- **Contribute upstream:** new features, layout changes, copy changes, new
  fields, bug fixes. These belong in this repository so every deployer benefits
  and so they survive upgrades. Open a PR (see
  [CONTRIBUTING.md](https://github.com/fundive/fundive/blob/main/CONTRIBUTING.md)).
- **Fork (last resort):** deeply divergent behavior a deployer won't upstream.
  This forfeits the one-line upgrade path and is explicitly *not* the intended
  model — prefer contributing upstream.

If you find yourself wanting to edit platform source to change how your
deployment behaves, that's a signal the need should become either a **config
option** or an **upstream feature** — file an issue.

## Runtime architecture

A running FunDive deployment executes code in four places. The platform ships all
of it; the deployment supplies only credentials and branding.

```
┌───────────── Browser (installable PWA) ──────────────┐
│ React SPA  ←→  Service Worker (precache + Web Push)   │
└───┬────────────────┬───────────────────┬─────────────┘
    │ supabase-js     │ fetch (admin)     │ Web Push endpoint
    ▼                 ▼                   ▲
┌────────────────────────┐   ┌────────────────────────────────┐
│ Supabase (operator's)  │   │ Cloudflare Worker: push/cron   │
│ Postgres + PostgREST   │ ← │ daily reminders + admin notify  │
│ Auth + RLS + Edge Fns  │   │ uses service-role key + VAPID   │
└────────────────────────┘   └────────────────────────────────┘
            ▲
            │ static assets
┌────────────────────────┐
│ Cloudflare Worker: SPA │  serves the built bundle (assets-only)
└────────────────────────┘
```

1. **Browser (SPA + service worker).** All diver-facing features. Auth uses the
   user's access token; PostgREST + Row-Level Security enforce row access.
2. **Cloudflare Worker — SPA.** Serves the built static assets. No custom server.
3. **Cloudflare Worker — push/cron.** Scheduled reminder fan-out and admin
   notification endpoints. Uses the Supabase service-role key (bypasses RLS) and
   the VAPID private key.
4. **Supabase Edge Function — registration.** Public endpoint backing the no-auth
   registration form: creates the account, inserts the booking, and emails a PDF.

**No custom application server.** The SPA talks to PostgREST directly, and
**authorization lives in RLS policies** shipped as migrations. Those policies are
the source of truth for who can read or write what.

## Data and catalog ownership

The platform owns the **database schema** (tables, constraints, RLS policies,
triggers) and ships it as forward-only migrations. It does **not** own any
deployer's data.

- A deployer's **catalog** — dive sites, courses, prices, rooms, add-ons — lives
  in *their* Supabase project. They populate it through the admin UI.
- Operational data (users, bookings, payments) is likewise theirs alone.

This is also the data-residency story: each operator's customer data lives only
in infrastructure they control and pay for.

## Versioning & the upgrade contract

The platform follows [semantic versioning](https://semver.org), surfaced as git
tags and GitHub releases. Deployments pin a tag.

- **Migrations are immutable once released.** A migration in a published tag is a
  public contract — never edit it. Schema changes ship as *new* forward
  migrations.
- **Breaking schema or config changes require a major version bump** and an entry
  in upgrade notes describing the manual steps, if any.
- **Upgrade flow for a deployer:** bump the pinned tag → `npm install` →
  `npx fundive db push` → `npx fundive deploy` → `npx fundive db verify`.

Pre-1.0 (current), anything may change between minor versions; treat every
upgrade as potentially breaking until 1.0.

## Security

- **Secrets never live in a repository.** Deploy credentials live in the
  deployment's gitignored `.env.local` and its CI secret store; runtime secrets
  (VAPID private key, service-role key, Gmail app password) live on Cloudflare
  and Supabase. The platform and the template ship only `.example` files
  documenting them.
- **The service-role key is used only server-side** (the push worker and edge
  function), never in the browser bundle.
- **Authorization is enforced in the database** via RLS, not in client code.

## Status & roadmap

Current state:

- ✅ Platform repo established: license, governance, versioning.
- ✅ **Config seam** — `fundive.config.ts` with the `defineConfig({ app, theme,
  features, … })` contract (`fundive/config`), the `.env.example` contract, and
  build-time injection via `virtual:fundive-config` (the `fundive/vite` plugin).
- ✅ **`fundive` CLI** — `init / dev / build / preview / deploy [push] /
  functions deploy / db push|verify|backup|adopt`, wired through `package.json`
  `bin`, installable as a dependency (verified from a packed tarball with
  `npm install --omit=dev`).
- ✅ **Application ported** from the first deployment, already config-driven, with
  a secrets/branding scrub at the boundary. All ~1,140 unit tests pass against a
  neutral default config.
- ✅ **Consumer-root build** — `vite.config` serves the platform's `index.html`/`src`
  while taking env and `dist` from the deployment's cwd and laying its `public/`
  over the platform's, so a separate deployment repo builds its own branded
  bundle via the platform CLI. FunDivers TW runs this way.
- ✅ **Edge-function config injection** — the Supabase functions read a deployment's
  config at deploy time via the `FUNDIVE_CONFIG` secret (the Deno-side counterpart of
  the frontend's build-time `virtual:fundive-config`). See `docs/deployment.md`.
- ⏳ **Generalize the catalog model.** The event catalog has been cleaned up and made
  robust (junctions are the source of truth; no external sync). The remaining piece is the
  larger clean-schema rebuild (unified `events` table, `EO_*`→clean renames) — post-1.0.
