# Deployment

Three things get deployed:

1. **The SPA** — Cloudflare Worker hosting the built `dist/` assets.
2. **The push cron** — separate Cloudflare Worker in `workers/push/`
   running the daily reminder job. See
   [push-notifications.md](./push-notifications.md) for that one.
3. **Supabase Edge Functions** under `supabase/functions/` — on-demand
   server code (PDF emailer, etc.), deployed via `supabase functions
   deploy`.

Database changes deploy via `supabase db push` — a separate workflow
described below.

## Environment variables

The single source of truth for what to fill in is
[`.env.example`](https://github.com/fundive/fundive/blob/main/.env.example) — copy it to `.env.local` (the file every
`make`/`npm` script reads) and fill in the values. From there, each value has a
final destination. Putting one in the wrong place is the most common deploy
footgun, so the table below maps each value to where it ultimately lives.

| Value | `.env.local` (local dev + build + deploy) | Push-worker secret (`wrangler secret put`) | Edge-function secret (`supabase secrets set`) |
| --- | :-: | :-: | :-: |
| `VITE_SUPABASE_URL`         | yes |     |     |
| `VITE_SUPABASE_ANON_KEY`    | yes |     |     |
| `VITE_TURNSTILE_SITE_KEY`   | yes |     |     |
| `VITE_VAPID_PUBLIC_KEY` *(optional; push toggle)* | yes |     |     |
| `VITE_PUSH_WORKER_URL` *(optional)* | yes |     |     |
| `SUPABASE_PROJECT_REF`      | yes |     |     |
| `SUPABASE_DB_PASSWORD`      | yes |     |     |
| `SUPABASE_ACCESS_TOKEN`     | yes |     |     |
| `SUPABASE_POOLER_HOST`      | yes |     |     |
| `CLOUDFLARE_API_TOKEN`      | yes (`make deploy`) |     |     |
| `CLOUDFLARE_ACCOUNT_ID`     | yes (`make deploy`) |     |     |
| `VAPID_PUBLIC_KEY` *(push worker — same value as `VITE_VAPID_PUBLIC_KEY`, without the `VITE_` prefix)* |     | yes |     |
| `VAPID_PRIVATE_KEY`         |     | yes |     |
| `SUPABASE_SERVICE_ROLE_KEY` *(push worker)* |     | yes |     |
| `ADMIN_TRIGGER_SECRET` / `BROADCAST_WEBHOOK_URL` *(optional)* |     | yes |     |
| `GMAIL_USER` / `GMAIL_APP_PASSWORD` |     |     | yes |
| `TURNSTILE_SECRET`          |     |     | yes |

`VAPID_SUBJECT`, `ALLOWED_ORIGINS`, `TIMEZONE`, and `CURRENCY` are **non-secret**
push-worker config and live in `workers/push/wrangler.toml [vars]`, not in any
env file.

### `.env.local` — local dev, build, and deploy

Read by Vite (`make dev`), by the `make` targets that talk to your linked
Supabase project, and by `make deploy` (which wraps every wrangler/supabase call
in `dotenv -e .env.local`). It carries every value in `.env.example`; the
sections below explain which of those get *redistributed* to a secret store at
deploy time.

| Var | Where used | Notes |
| --- | --- | --- |
| `VITE_SUPABASE_URL`        | `src/lib/supabase.ts` | Cloud project URL; local is `http://127.0.0.1:64321` |
| `VITE_SUPABASE_ANON_KEY`   | `src/lib/supabase.ts` | Public; ships to the browser |
| `VITE_TURNSTILE_SITE_KEY`  | Turnstile widget      | **Required** — the build fails without it |
| `VITE_VAPID_PUBLIC_KEY`    | `src/lib/push.ts`     | Push toggle is hidden if unset |
| `SUPABASE_PROJECT_REF`     | `make link`, `make push` | e.g. `abcdefghij` |
| `SUPABASE_DB_PASSWORD`     | `make push`, `make pull` | DB password for migrations |
| `SUPABASE_ACCESS_TOKEN`    | Supabase CLI auth     | Personal access token |
| `SUPABASE_POOLER_HOST`     | `make verify` (`scripts/verify-sync.sh`) | e.g. `aws-0-ap-east-1.pooler.supabase.com` |
| `CLOUDFLARE_API_TOKEN`     | `make deploy` (wrangler) | Only needed for local deploys |
| `CLOUDFLARE_ACCOUNT_ID`    | `make deploy` (wrangler) | Only needed for local deploys |

> The build inlines `VITE_*` at build time, so `make deploy` produces a bundle
> pointing at whatever `.env.local` holds — make sure those are your **cloud**
> values (not a local `127.0.0.1` stack) before deploying.

### Cloudflare push-worker secrets

Set via `wrangler secret put` from inside `workers/push/`; they never appear in
env files at deploy time. See
[push-notifications.md § Configure the worker](./push-notifications.md#4-configure-the-worker)
for the full list. The SPA Worker (`fundive-app`) has no Worker-level secrets —
all of its config is baked into the bundle at build time via `VITE_*`.

### Supabase Edge Function secrets

Set via `supabase secrets set --project-ref "$SUPABASE_PROJECT_REF" …`.
`create-registration` uses `GMAIL_USER`, `GMAIL_APP_PASSWORD`, and
`TURNSTILE_SECRET`. See [§ Supabase Edge Functions](#supabase-edge-functions).


## Workers

Two Cloudflare Workers are deployed separately:

| Worker | Config | Make target |
| --- | --- | --- |
| `fundive-app`   | `./wrangler.toml`              | `make deploy-app` |
| `fundive-push`  | `./workers/push/wrangler.toml` | `make deploy-push` |

`make deploy` runs both worker deploys in sequence from your machine, reading
the `CLOUDFLARE_*` creds and `VITE_*` build vars from `.env.local` — no
`wrangler login`, no GitHub Actions. Use `make deploy-app` or `make deploy-push`
to ship only one. Each target first checks the Cloudflare creds are present and
fails fast with a clear message if not.

> An experimental `fundive` CLI (`npx fundive deploy`) also exists for the future
> thin-deployment model in [architecture.md](./architecture.md). It's a skeleton
> (SPA only) — prefer `make deploy`.

### `fundive-app` (SPA)

`make deploy-app` first checks the Cloudflare creds are present, then:

```sh
npm run build                                       # tsc -b && vite build (VITE_* from .env.local)
. ./.env.local && npx wrangler deploy                # CLOUDFLARE_API_TOKEN/ACCOUNT_ID authenticate wrangler
```

`wrangler.toml` at the repo root:

```toml
name = "fundive-app"
main = "src/worker.ts"
compatibility_date = "2026-04-01"

[assets]
directory = "./dist"
binding = "ASSETS"
not_found_handling = "single-page-application"
```

`src/worker.ts` serves the built assets and falls back to `index.html` for
unknown paths so client-side routes don't 404 on reload. Auth is the
`CLOUDFLARE_API_TOKEN` from `.env.local` — no `wrangler login` needed.

### `fundive-push` (cron sender)

`make deploy-push` runs `wrangler deploy` from `workers/push/` (config:
`workers/push/wrangler.toml`, `main = "src/index.ts"`), sourcing the same
`.env.local` creds so it authenticates non-interactively. The target installs
deps on first run. The worker's own runtime secrets are set separately via
`wrangler secret put` — see
[push-notifications.md § Configure the worker](./push-notifications.md#4-configure-the-worker).

## Supabase Edge Functions

Each directory under `supabase/functions/` is one deployable function
(Deno 2 runtime). Shared code lives under `supabase/functions/_shared/`
and is imported relatively. `make deploy-functions` runs `supabase
functions deploy` (no name → ships every function in the directory)
against the linked project.

### Shop config in the functions

Edge functions read shop config through one seam, `_shared/config.ts`. It
returns the deployment's config when the `FUNDIVE_CONFIG` secret is set
(the resolved `fundive.config.ts`, serialized to JSON), and otherwise
falls back to the platform default — so local `functions serve` and the
vitest handler tests work unchanged. This is the Deno-side counterpart of
the frontend's build-time `virtual:fundive-config`: the browser bundle bakes
config in at build, the edge runtime reads it from env at deploy.

`npx fundive functions deploy` wires this up from a deployment repo: it
resolves the deployment's config, `supabase secrets set FUNDIVE_CONFIG=<json>`,
then `supabase functions deploy --workdir <platform>` (so Supabase finds the
platform's functions even though the deployment repo has none of its own).
Running `make deploy-functions` from inside the platform repo still works and
uses the platform default (no `FUNDIVE_CONFIG` set).

### `create-registration`

Single atomic endpoint behind the registration form (`RegisterFormBody`).
Either the body has `email` + `password` (guest flow → creates the
account with `email_confirm: true`, bypassing the click-to-confirm
gate) or the caller's Bearer JWT identifies an authed user. Either
way, the function then UPDATEs the profile, INSERTs the booking,
builds a PDF (via `_shared/pdf.ts`), and emails it via Gmail SMTP to
both the shop (`siteConfig.app.supportEmail`) and the diver. Returns `{ booking_id, session }`; `session` is
populated only on the guest path so the client can `setSession`
immediately. If the booking insert fails on the guest path the
just-created auth user is deleted to keep retries clean.

Required secrets (`supabase secrets set --project-ref "$SUPABASE_PROJECT_REF" …`):

| Secret | What it is |
| --- | --- |
| `GMAIL_USER`          | Gmail account that sends the mail |
| `GMAIL_APP_PASSWORD`  | Gmail [app password](https://support.google.com/accounts/answer/185833) — not the normal password |

`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, and `SUPABASE_ANON_KEY` are
auto-injected by the edge runtime.

Deploy:

```sh
make deploy-functions      # ships every function under supabase/functions/
supabase secrets set --project-ref "$SUPABASE_PROJECT_REF" \
  GMAIL_USER=<shop-gmail-account> \
  GMAIL_APP_PASSWORD=<app-password>
```

Local testing:

```sh
supabase functions serve create-registration --env-file .env.local
# ...then in another shell, curl with a registration body.
```

## Supabase schema workflow

Migrations are **forward-only**. Flow for a schema change:

```sh
# 1. Write a new migration file under supabase/migrations/
#    Name format: YYYYMMDDHHMMSS_<slug>.sql

# 2. Apply locally and test
make reset              # or `make diff` to preview drift, then `make reset`
make test               # integration suite exercises the new schema

# 3. Push to cloud
make push               # applies to the linked project

# 4. Verify the cloud matches
make verify             # schema migration list + row-count parity check
```

`scripts/verify-sync.sh` does a two-step check:

1. `supabase migration list --linked` — confirms local + cloud agree on
   applied migrations.
2. Row-count parity per table across `public` + `auth` schemas — catches
   missing or extra data rows.

### Linking a fresh checkout

```sh
make link     # runs `supabase link --project-ref "$SUPABASE_PROJECT_REF"`
make pull     # generates a baseline migration from cloud (one-time if cloud drifted)
```

### Pulling data down for local dev

```sh
make dump-data    # writes cloud data into supabase/seed.sql
make reset        # rebuilds local from migrations + seed
```

## Release checklist

Small feature or bug fix:

1. Run `make test` locally — unit + integration.
2. If the change touches the schema: `make reset` first, then
   `make test`, then `make push` after review.
3. `make deploy` — ships both workers (SPA + push cron). Use
   `make deploy-app` or `make deploy-push` if you're touching only one.
4. `make verify` — confirm cloud schema + row counts match local
   expectations post-deploy.

## Rollback

- **Frontend:** `wrangler deployments list` shows history;
  `wrangler rollback <deployment-id>` reverts the SPA.
- **Push worker:** same flow inside `workers/push/`.
- **DB:** there is no automatic down-migration — write a **forward**
  migration that undoes the change, then `make push`. Do not edit or
  delete an applied migration file. Recovery from truly bad migrations
  is a restore from Supabase's point-in-time backup (dashboard →
  Database → Backups).
