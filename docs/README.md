# FunDive platform — docs

Start with [architecture.md](./architecture.md) — the platform-vs-deployment
model, the config surface, and the upgrade contract. The rest cover one slice of
the platform each; read the one closest to the change you're making before you
dive into source.

| Doc | What it covers |
| --- | --- |
| [architecture.md](./architecture.md)                   | Platform-as-dependency model, `defineConfig` + `.env` surface, the `fundive` CLI, runtime boundaries, versioning contract |
| [data-model.md](./data-model.md)                       | Every table, the `EO_*` Bubble-import convention, XOR FK pattern |
| [authentication.md](./authentication.md)               | Sign-up trigger, `useAuth`, role gating, `ProtectedRoute` / `AdminRoute` |
| [events-and-bookings.md](./events-and-bookings.md)     | Calendar rendering, register-form wizard, `bookings.details` JSONB shape |
| [payments.md](./payments.md)                           | Deposit vs balance semantics, payments ledger, refund flow |
| [admin.md](./admin.md)                                 | Admin routes, event memos, user search, role-view toggle |
| [trip-board.md](./trip-board.md)                       | Partner referral network: curated trips abroad, referral codes, kickback ledger |
| [push-notifications.md](./push-notifications.md)       | Web Push: VAPID, service worker, Cloudflare cron sender, `/admin-broadcast`, `/notify-duty`, CORS |
| [testing.md](./testing.md)                             | Unit vs integration conventions, `mockQueryBuilder`, test layout |
| [deployment.md](./deployment.md)                       | Env vars (which secret lives where), Cloudflare deploy, Supabase push / verify, edge functions |

## Conventions called out across docs

- **Migrations are immutable once released.** A migration in a published tag is a
  public contract — add a forward migration, never edit an applied one. See
  [architecture.md](./architecture.md#versioning--the-upgrade-contract) and
  [data-model.md](./data-model.md#migrations).
- **Config over forking.** Shop-specific values live in a deployment's
  `fundive.config.ts` / `.env` / `brand/`, never in platform source. See
  [architecture.md](./architecture.md#the-customization-boundary).
- **No i18n.** The platform is English-only.
- **XOR FKs** appear in `bookings` and `event_memos`: exactly one of
  `eo_dive_id` / `eo_course_id` is set. Don't "fix" one side.

## Commands (via the `fundive` CLI, run from a deployment repo)

```sh
npx fundive dev            # dev server against a local Supabase stack
npx fundive build          # production build with your branding baked in
npx fundive deploy         # deploy the SPA worker to your Cloudflare
npx fundive db push        # apply the platform migrations to your Supabase
npx fundive db verify      # confirm your schema matches the pinned version
npx fundive functions deploy
```
