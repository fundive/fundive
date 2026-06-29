# FunDive

**Free, open-source, self-hostable software for running a scuba dive center.**

Bookings, courses, payments, dive logs, ride/fleet logistics, and staff
operations — in one progressive web app you host yourself. Every comparable
product is paid, closed-source SaaS. FunDive is AGPL-licensed: you own the code
and your customers' data, with no per-seat fee.

> FunDive was built for and first deployed by [FunDivers TW](https://fundivers.tw),
> a dive shop in Taipei, Taiwan. This repository is the open-source platform
> behind it, being prepared for general self-hosting.

> **Status: v0.0.1 — in active development. ⚠️ Not ready for production use.**
> The platform is still being generalized from its first deployment. Expect
> incomplete features, rough edges, and breaking changes; do not rely on it to
> run a real business yet. Issues and PRs welcome — see
> [Contributing](#contributing).

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

> These steps reflect the platform's architecture. Because the public code is
> still being generalized, exact commands may change — check back as the
> repository fills out, and open an issue if something doesn't work.

**Prerequisites**

- [Node.js](https://nodejs.org) (LTS) and npm
- [Docker](https://www.docker.com) (for the local Supabase stack)
- [Supabase CLI](https://supabase.com/docs/guides/cli)
- A [Cloudflare](https://cloudflare.com) account (for deployment)

**Local development**

```sh
git clone https://github.com/fundive/fundive.git
cd fundive
npm install

cp .env.local.example .env.local   # then fill in the values

npm run db:start    # boot the local Supabase stack (Docker)
npm run dev         # start Vite against the local stack
```

**Testing**

```sh
npm run test:all    # unit + integration (integration needs the local stack up)
```

**Deployment**

FunDive deploys to Cloudflare Workers (SPA + push worker) with a Supabase
project as the backend. See [`docs/deployment.md`](docs/deployment.md) for the
required environment variables and the full deploy flow.

## Documentation

In-depth docs live under [`docs/`](docs/): architecture, data model,
authentication, bookings, payments, admin, push notifications, testing, and
deployment.

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
