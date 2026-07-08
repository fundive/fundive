# FunDive platform — docs

Start with [architecture.md](./architecture.md) — the platform-vs-deployment
model, the config surface, and the upgrade contract. The rest cover one slice of
the platform each; read the one closest to the change you're making before you
dive into source.

| Doc | What it covers |
| --- | --- |
| [self-hosting.md](./self-hosting.md)                   | Non-technical step-by-step: fork → Supabase → Cloudflare → live app, first admin, go-live checklist |
| [architecture.md](./architecture.md)                   | Platform-as-dependency model, `defineConfig` + `.env` surface, the `fundive` CLI, runtime boundaries, versioning contract |
| [forking.md](./forking.md)                             | Forking for a new shop: `fundive.config.ts` fields, branding assets in `public/`, `terms.tsx`, env vars, fork-to-deploy |
| [data-model.md](./data-model.md)                       | Every table, the unified `events` model, catalog reference tables |
| [authentication.md](./authentication.md)               | Sign-up trigger, `useAuth`, role gating, `ProtectedRoute` / `AdminRoute` |
| [events-and-bookings.md](./events-and-bookings.md)     | Calendar rendering, register-form wizard, `bookings.details` JSONB shape |
| [payments.md](./payments.md)                           | Deposit vs balance semantics, payments ledger, refund flow |
| [admin.md](./admin.md)                                 | Admin routes, event memos, user search, role-view toggle |
| [packages.md](./packages.md)                           | Partner-shop registration network: product tiers, add-on/room estimate, recommendation email, kickback ledger |
| [trusted-partners.md](./trusted-partners.md)           | Vouched partner-shop directory + server-relayed diver→partner messaging (email privacy) |
| [push-notifications.md](./push-notifications.md)       | Web Push: VAPID, service worker, Cloudflare cron sender, `/admin-broadcast`, `/notify-duty`, CORS |
| [testing.md](./testing.md)                             | Unit vs integration conventions, `mockQueryBuilder`, test layout |
| [deployment.md](./deployment.md)                       | Env vars (which secret lives where), Cloudflare deploy, Supabase push / verify, edge functions |

## Conventions called out across docs

- **Migrations are immutable once released.** A migration in a published tag is a
  public contract — add a forward migration, never edit an applied one. See
  [architecture.md](./architecture.md#versioning--the-upgrade-contract) and
  [data-model.md](./data-model.md#migrations).
- **Config over source edits.** Shop-specific values live in
  `fundive.config.ts`, `.env.local`, and the branding assets under `public/` —
  never hardcoded in `src/`. See [forking.md](./forking.md) and
  [architecture.md](./architecture.md#the-customization-boundary).
- **No i18n.** The platform is English-only.
- **Unified `events` table.** Dives and courses are one `events` table with a
  `kind` discriminator; bookings/duties/admin_notes/vehicles/waivers reference it
  by a single `event_id → events(id)`.

## Commands

Run these from the repo root; they read your `.env.local`. See the
[Makefile](https://github.com/fundive/fundive/blob/main/Makefile) for the full list.

```sh
make start     # boot the local Supabase stack (Docker)
make dev       # dev server against the local stack
make test      # unit + integration + security suites
make push      # apply migrations to your linked Supabase project
make verify    # confirm your cloud schema matches the migrations
make deploy    # deploy both Cloudflare Workers (SPA + push cron)
```

Deployment normally runs through GitHub Actions
(`.github/workflows/deploy.yml`); `make deploy` is the local equivalent. See
[deployment.md](./deployment.md).

> An experimental `fundive` CLI (`npx fundive …`, wired via `package.json`
> `bin`) mirrors these commands for the future "thin deployment repo" model
> described in [architecture.md](./architecture.md). It's a skeleton today — the
> `make` targets above are the supported path.
