# FunDive

**Free, open-source, self-hostable software for running a scuba dive center.**

Bookings, courses, payments, dive logs, ride/fleet logistics, and staff
operations — in one progressive web app you host yourself. Every comparable
product is paid, closed-source SaaS. FunDive is AGPL-licensed: you own the code
and your customers' data, with no per-seat fee.

> FunDive was built for and first deployed by [FunDivers TW](https://fundivers.tw),
> a dive shop in Taipei, Taiwan. This repository is the open-source platform
> behind it, being prepared for general self-hosting.

> **Status: v0.1.0 — first public release.** This is the initial fork-and-deploy
> release: clone it, point it at your own Supabase + Cloudflare, brand it, and run
> it. It's pre-1.0, so anything may change between minor versions — treat every
> upgrade as potentially breaking until 1.0. Issues and PRs welcome — see
> [Contributing](#contributing).

> 🏝️ **Run a dive shop and want your own copy?** No coding required — follow the
> **[step-by-step self-hosting walkthrough](docs/self-hosting.md)** to launch a
> live booking app for free in an afternoon.

## Features

- **Booking & scheduling** — a diver-facing calendar of dives and courses with a
  multi-step registration wizard; admins create and manage events.
- **Payments tracking** — deposit-vs-balance ledger per booking, with refund
  handling. (Manual/offline payment today; online card payments are on the
  roadmap.)
- **Ride & seat logistics** — coordinate who's riding in which car to the dive
  site, a capability the commercial tools don't offer.
- **Family / group lead-payer billing** — one person can book and pay for a
  whole family or group.
- **Roles & staff ops** — diver, staff, and admin roles; staff duty lists, event
  memos, user management, and a catalog editor (prices, rooms, add-ons, travel).
- **Web push notifications** — booking reminders and admin broadcasts via a
  daily scheduled job, delivered through a service worker.
- **Installable PWA** — mobile-first, works offline-ish, installs to the home
  screen.

## Why FunDive

| | FunDive | Typical commercial SaaS |
| --- | :--: | :--: |
| Open source & self-hostable | ✓ | ✗ |
| You own the code and data | ✓ | ✗ |
| Per-seat / monthly fee | none | $25–210/mo |
| Ride / seat logistics | ✓ | ✗ |
| Family lead-payer billing | ✓ | rare |
| Online card payments | roadmap | ✓ |
| POS / rental inventory | roadmap | ✓ |

FunDive is the only free, open-source, self-hostable option in its space. The
paid field still leads on online card payments and POS/rental inventory — areas
where FunDive is catching up. See [`docs/`](docs/) for the full comparison and
architecture notes (in the deployment repo).

## Tech stack

- **Frontend:** React 19 + TypeScript, built with Vite. Routing via
  React Router, forms via React Hook Form + Zod, styling via Tailwind CSS.
- **PWA:** `vite-plugin-pwa` (injectManifest) with a custom service worker for
  precaching and Web Push.
- **Backend / database:** [Supabase](https://supabase.com) — Postgres, Auth, and
  Row-Level Security. The SPA talks to PostgREST directly; authorization lives in
  RLS policies. No custom app server.
- **Edge / jobs:** [Cloudflare Workers](https://workers.cloudflare.com) — one
  worker serves the SPA assets, another runs the daily reminder cron and admin
  notification endpoints. A Supabase Edge Function handles atomic public
  registration (account + booking + emailed PDF).
- **Testing:** Vitest, with unit tests (mocked Supabase) and integration tests
  that run against a live local Supabase stack.

## Getting started

You need [Node.js](https://nodejs.org) LTS and [Docker](https://www.docker.com).
Nothing else — no accounts, no cloud services, no cost. The Supabase CLI ships as
a dev dependency, so `npm install` provides it.

```sh
git clone https://github.com/fundive/fundive.git
cd fundive
npm install
cp .env.example .env.local   # ships working local values — nothing to fill in
make start                   # boot the Supabase stack in Docker (first run: a few minutes)
make dev                     # Vite against that stack
```

Open the URL Vite prints and sign in as **`admin@admin.admin`** / **`adminadmin`**
— one of three seeded accounts (diver, admin, staff) that the login page offers
as one-click buttons in dev builds. That's the whole app: create events, manage
divers, take bookings.

```sh
make test     # typecheck + lint + every test suite (integration needs the stack up)
make reset    # wipe the local database back to migrations + seed data
```

**[docs/development.md](docs/development.md)** covers the same ground with the
detail: what each seeded account is for, where local email lands, running the
edge functions, and what to do when something won't start.

The local values in `.env.example` are deliberately not deployable — the
production build refuses a bundle pointing at `127.0.0.1` or carrying
Cloudflare's always-pass test captcha key. Going live means replacing them; see
[`docs/deployment.md`](docs/deployment.md).

## Make it yours

FunDive is built to be forked per shop. Two things make a clone *yours*:

1. **Edit [`fundive.config.ts`](fundive.config.ts)** — shop name, contact info,
   URLs, timezone, currency, theme colors, feature toggles, and gear list. It's
   pure data read by the app, the service worker, the build, and the edge
   functions. (`fundive.config.example.ts` is a blank template.)
2. **Replace the branding assets in [`public/`](public/)** — logo, favicons, app
   icons, and social/OG image. A straight clone otherwise renders the reference
   shop's marks. The asset paths are listed under `assets` in `fundive.config.ts`.

See [`docs/forking.md`](docs/forking.md) for the field-by-field walkthrough.

## Self-hosting: launch your shop's app

New to this and not a developer? **[docs/self-hosting.md](docs/self-hosting.md)**
is a step-by-step walkthrough that takes you from nothing to a live booking app —
mostly creating accounts and clicking buttons, with a couple of copy-paste
commands. The free tiers of GitHub, Supabase, and Cloudflare cover a small shop,
so you can launch for **$0**. The developer-oriented reference below and in
[`docs/deployment.md`](docs/deployment.md) covers the same ground in less detail.

Closing the shop, or moving on? **[docs/shutdown.md](docs/shutdown.md)** is the
same walkthrough in reverse — settle what is outstanding, take your records out
as spreadsheets, and switch the services and accounts off in an order that
leaves nothing stranded.

## Deployment

FunDive deploys to Cloudflare Workers (an SPA worker + a push-cron worker) with a
Supabase project as the backend. First, point the app at **your own** Supabase
project — apply the baseline migration with `make push` — and your own Cloudflare
account.

Deploy both workers from your machine with `make deploy`, which builds and ships
them using the `CLOUDFLARE_*` + `VITE_*` values in `.env.local` (no
`wrangler login` needed). See
[`docs/deployment.md`](docs/deployment.md) for the required environment variables
and the full flow.

## Documentation

In-depth docs live under [`docs/`](docs/) and read as a browsable site at
**[fundive.github.io/fundive](https://fundive.github.io/fundive/)**. New here?
Start with the [self-hosting walkthrough](docs/self-hosting.md). Building on the
platform? Start with [architecture.md](docs/architecture.md) — the **platform
vs. deployment** model — then the per-topic docs: data model, authentication,
events & bookings, payments, admin, trip board, trusted partners, push
notifications, testing, and deployment. The [docs index](docs/README.md) lists
them all.

## Contributing

Contributions are welcome — anyone can fork the project and open a pull request.
`main` is protected: every change goes through a reviewed PR, and commits must be
signed off under the [Developer Certificate of Origin](https://developercertificate.org/)
(`git commit -s`). See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

Copyright (C) 2026 FunDive contributors

FunDive is free software, licensed under the **GNU Affero General Public License,
version 3 or later** (`AGPL-3.0-or-later`). You are free to use, study, share,
and modify it; any derivative — including a modified version offered to users
over a network — must also be released under the AGPL. See [LICENSE](LICENSE).

Because FunDive runs as a network service, AGPL §13 requires that **anyone who
runs a modified version and lets users interact with it over a network must
offer those users the corresponding source code.** Keep a visible link to the
source from your deployment.

SPDX-License-Identifier: `AGPL-3.0-or-later`
