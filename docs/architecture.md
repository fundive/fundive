# Architecture

This document defines how FunDive is structured for self-hosting: the split
between the **platform** (this repository) and a **deployment** (each operator's
own repository), what is configurable, and what is not.

> Status: this describes the target architecture. The codebase is still being
> generalized from its first deployment ([FunDivers TW](https://fundivers.tw)),
> so parts of this are a plan, not yet shipped. See
> [Status & roadmap](#status--roadmap).

## Philosophy: one platform, many thin deployments

FunDive is **open-core, self-hosted**. There is exactly one authoritative
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
 │ .env        │    │ .env        │    │ .env        │   only config + assets
 │ brand/      │    │ brand/      │    │ brand/      │   never platform code
 └─────────────┘    └─────────────┘    └─────────────┘
```

The payoff: **upgrading is a one-line version bump.** A deployer changes the
pinned platform version, re-applies migrations, and redeploys — they never merge
code or resolve conflicts. Protecting that property is the primary constraint on
every design decision below.

## The deployment repository

A deployer's repo is small and contains no platform source. It looks like:

```
my-dive-shop/
  package.json          # depends on the platform (see below)
  .env                  # infra credentials + secrets  — GITIGNORED
  .env.example          # documents required vars (committed)
  fundive.config.ts     # branding, theme, feature toggles
  brand/                # logo.svg, favicon.ico, hero images, …
  catalog/              # optional: seed data for dive sites / courses / prices
  .github/workflows/    # CI that runs the platform CLI with their secrets
  .gitignore            # ignores .env and build output
```

### Consuming the platform (git dependency)

Deployments pin the platform as a **git dependency** on a release tag — no npm
registry involved:

```jsonc
// package.json
{
  "name": "my-dive-shop",
  "private": true,
  "dependencies": {
    "fundive": "github:fundive/fundive#v0.1.0"
  }
}
```

`npm install` fetches the tagged source and runs the platform's `prepare` step to
build it locally. The platform exposes a CLI via its `bin` entry, so the
deployment drives everything through it:

```sh
npx fundive dev         # local dev server against a local Supabase stack
npx fundive db push     # apply the platform's migrations to THEIR Supabase
npx fundive build       # production build with their branding baked in
npx fundive deploy      # deploy SPA worker + push worker to THEIR Cloudflare
npx fundive db verify   # confirm their DB schema matches the pinned version
```

Pinning to a tag (`#v0.1.0`) — not a branch — is required: it makes a deployment
reproducible and upgrades deliberate. Upgrading means editing that one line to
`#v0.2.0`, running `npm install`, then `db push` and `deploy`.

## Configuration surface

Everything a deployer can change without forking lives in three places: their
`.env`, their `fundive.config.ts`, and their `brand/` + `catalog/` directories.

| Concern | Where | Example |
| --- | --- | --- |
| App identity | `fundive.config.ts` | name, tagline, support email |
| Theme | `fundive.config.ts` | brand colors, light/dark defaults |
| Branding assets | `brand/` | `logo.svg`, `favicon.ico`, hero images |
| Feature toggles | `fundive.config.ts` | enable/disable ride logistics, trip board, … |
| Supabase | `.env` | project ref, URL, anon key, service-role key, DB password |
| Cloudflare | `.env` | account id, worker names, custom domain, API token |
| Web Push | `.env` | VAPID public/private keys |
| Email | `.env` | SMTP host/user/pass for registration mail |
| Catalog data | `catalog/` (or admin UI) | their dive sites, courses, prices, rooms |

### `fundive.config.ts` (illustrative shape)

```ts
import { defineConfig } from "fundive/config";

export default defineConfig({
  app: {
    name: "Acme Divers",
    tagline: "Diving the east coast since 2009",
    supportEmail: "hello@acmedivers.example",
  },
  theme: {
    colors: { primary: "#0a6", accent: "#fc3" },
  },
  features: {
    rideLogistics: true,
    tripBoard: false,
    familyLeadPayer: true,
  },
});
```

Branding is resolved at **build time**: the platform's Vite build reads the
deployment's config and `brand/` directory through a virtual module / path alias
pointing at the deployment's working directory, and bakes the result into the
bundle. (Vite inlines env and assets at build time, so each deployer builds their
own bundle in their own CI — there is no shared prebuilt artifact, and secrets
never leave the deployment's environment.)

## The customization boundary

This is the most important line to hold, because it's what keeps upgrades cheap.

- **Config (no fork):** name, logo, colors, which optional features are on,
  infrastructure credentials, and your own catalog data. Covered above.
- **Contribute upstream:** new features, layout changes, copy changes, new
  fields, bug fixes. These belong in this repository so every deployer benefits
  and so they survive upgrades. Open a PR (see
  [CONTRIBUTING.md](../CONTRIBUTING.md)).
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
  in *their* Supabase project. They populate it through the admin UI or by
  committing a seed under `catalog/` in their deployment repo.
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

- **Secrets never live in this repository.** All credentials (Supabase keys, VAPID
  private key, Cloudflare token, SMTP password) live in the deployment's `.env`
  and CI secret store, which is `.gitignore`d. The platform ships only `.example`
  files documenting the variables.
- **The service-role key is used only server-side** (the push worker and edge
  function), never in the browser bundle.
- **Authorization is enforced in the database** via RLS, not in client code.

## Status & roadmap

This architecture is the target. Current state:

- ✅ Platform repo established: license, governance, versioning.
- ✅ **Config seam** — `fundive.config.ts` with the `defineConfig({ app, theme,
  features, … })` contract (`fundive/config`), the `.env.example` contract, and
  build-time injection via `virtual:fundive-config` (the `fundive/vite` plugin).
- ✅ **`fundive` CLI skeleton** — `dev / build / preview / deploy / db push|verify
  / functions deploy`, wired through `package.json` `bin`.
- ✅ **Application ported** from the first deployment, already config-driven, with
  a secrets/branding scrub at the boundary. All ~1,140 unit tests pass against a
  neutral default config.
- ⏳ **Consumer-root build** — serve the platform's `index.html`/`src` while
  reading the deployment's `public/` `brand/`. Works today from the platform repo;
  the deployment-as-separate-repo path is the next refinement.
- ⏳ **Generalize the catalog model.** The first deployment's catalog tables are
  legacy Bubble imports specific to that shop; the platform needs a clean,
  operator-agnostic catalog schema. This is the largest remaining piece of work.
