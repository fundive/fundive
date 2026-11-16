# Deployment

A shop runs FunDive from its own **deployment repository**: a small repo that
holds the shop's config, branding and infrastructure names, and installs the
platform as a pinned dependency. Every deploy is a `npx fundive` command run in
that repo, from a laptop or from the repo's GitHub Actions. The free tiers of
Supabase and Cloudflare cover a small shop.

New to this? The [self-hosting walkthrough](./self-hosting.md) goes from nothing
to a live app step by step. This page is the reference behind it.

Three things get deployed, plus the database schema:

1. **The app** — a Cloudflare Worker serving the built SPA.
2. **The push worker** — a second Cloudflare Worker running the reminder
   crons. Optional; see [push-notifications.md](./push-notifications.md).
3. **The edge functions** — Supabase functions for registration, emails and
   PDFs.
4. **The schema** — the platform's migrations, applied to your database.

## The deployment repository

`npx github:fundive/fundive init my-shop` creates it, pinned to the platform
commit it was run from:

```
my-shop/
  package.json                # "fundive": "github:fundive/fundive#<commit or tag>"
  fundive.config.ts           # identity, URLs, locale, design, gear: configuration.md
  public/                     # your logo, icons and photos, laid over the platform's
  wrangler.toml               # the app worker's name and your custom domain
  workers/push/wrangler.toml  # the push worker's name, [vars] and crons
  .github/workflows/          # manual Deploy and Push migrations buttons
  .env.example                # every credential, documented (committed)
  .env.local                  # your credentials (gitignored)
  .gitignore
  README.md
```

Nothing else belongs in it. If you find yourself adding a `src/`, the change is
a config field or a platform feature: see
[configuration.md § Changing the platform itself](./configuration.md#changing-the-platform-itself).

The platform's own `public/` (icons, fonts, placeholder logo) is served with
yours laid over it: a file at the same path in yours wins. The two are merged
into `node_modules/.cache/fundive/public` when a build or the dev server starts.

## The `fundive` CLI

Run every command from the deployment repository. Each reads `.env.local` (and
`.env`); a variable already set in the environment wins, which is how the GitHub
Actions workflows pass their secrets.

| Command | What it does |
| --- | --- |
| `npx fundive build` | production build into `dist/`, with your config and branding baked in |
| `npx fundive preview` | serve that build locally |
| `npx fundive dev` | dev server against whatever Supabase `.env.local` names |
| `npx fundive deploy` | deploy the app worker, using your `wrangler.toml` |
| `npx fundive deploy push` | deploy the push worker, using your `workers/push/wrangler.toml` |
| `npx fundive functions deploy` | set the `FUNDIVE_CONFIG` secret from `fundive.config.ts`, then deploy every edge function |
| `npx fundive db push [--dry-run]` | apply the platform's migrations to your database |
| `npx fundive db verify` | list migrations: the platform's beside your database's |
| `npx fundive db backup` | dump your database's roles, schema and data into `backups/` |
| `npx fundive db adopt …` | adopt a database built from another repo ([below](#adopting-an-existing-supabase-project)) |
| `npx fundive init <dir>` | create a deployment repository |
| `npx fundive version` | print the platform version |

The `db` commands connect with `SUPABASE_DB_URL` if set, otherwise with the
pooler host, project ref and password from `.env.local`; no `supabase link` is
needed. vite, wrangler and the Supabase CLI are the platform's dependencies, so
`npm install` is all the tooling a deployment needs.

## Environment variables

`.env.example` lists every value; copy it to `.env.local` and fill it in. Each
value ends up in one of three places, and putting one in the wrong place is the
most common deploy mistake:

| Value | `.env.local` (and the Actions secrets) | Push-worker secret (`wrangler secret put`) | Edge-function secret (`supabase secrets set`) |
| --- | :-: | :-: | :-: |
| `VITE_SUPABASE_URL`         | yes |     |     |
| `VITE_SUPABASE_ANON_KEY`    | yes |     |     |
| `VITE_TURNSTILE_SITE_KEY`   | yes |     |     |
| `VITE_VAPID_PUBLIC_KEY` *(optional; push toggle)* | yes |     |     |
| `VITE_PUSH_WORKER_URL` *(optional)* | yes |     |     |
| `SUPABASE_PROJECT_REF`      | yes |     |     |
| `SUPABASE_DB_PASSWORD`      | yes |     |     |
| `SUPABASE_POOLER_HOST`      | yes |     |     |
| `SUPABASE_ACCESS_TOKEN`     | yes |     |     |
| `CLOUDFLARE_API_TOKEN`      | yes |     |     |
| `CLOUDFLARE_ACCOUNT_ID`     | yes |     |     |
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` |     | yes |     |
| `VAPID_PUBLIC_KEY` *(same value as `VITE_VAPID_PUBLIC_KEY`)* |     | yes |     |
| `VAPID_PRIVATE_KEY`         |     | yes |     |
| `ADMIN_TRIGGER_SECRET` / `BROADCAST_WEBHOOK_URL` *(optional)* |     | yes |     |
| `GMAIL_USER` / `GMAIL_APP_PASSWORD` |     |     | yes |
| `TURNSTILE_SECRET`          |     |     | yes |

Where to find them:

| Value | Where |
| --- | --- |
| `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` | Supabase → Project Settings → API (Project URL, `anon` `public` key) |
| `SUPABASE_PROJECT_REF` | Supabase → Project Settings → General (Reference ID) |
| `SUPABASE_DB_PASSWORD` | the password you set when creating the project |
| `SUPABASE_POOLER_HOST` | Supabase → **Connect** (top of the project page) → the Session pooler connection string; its host part, e.g. `aws-0-ap-east-1.pooler.supabase.com` |
| `SUPABASE_ACCESS_TOKEN` | Supabase → account menu → Access Tokens |
| `VITE_TURNSTILE_SITE_KEY`, `TURNSTILE_SECRET` | Cloudflare → Turnstile → your widget |
| `CLOUDFLARE_API_TOKEN` | Cloudflare → My Profile → API Tokens → "Edit Cloudflare Workers" template |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare → Workers & Pages, right-hand side |

The `VITE_*` values are baked into the bundle at build time, so a build carries
whatever `.env.local` held. The build refuses a localhost Supabase URL and
Cloudflare's always-pass test captcha key rather than ship an app that cannot
work.

`VAPID_SUBJECT`, `ALLOWED_ORIGINS`, `TIMEZONE` and `CURRENCY` are non-secret
push-worker settings in `workers/push/wrangler.toml [vars]`.

## The app worker

```sh
npx fundive build
npx fundive deploy
```

Your `wrangler.toml` names the worker and points it into the platform:

```toml
name = "fundive-app"
main = "node_modules/fundive/src/worker.ts"
compatibility_date = "2026-04-01"

# [[routes]]
# pattern = "app.myshop.com"
# custom_domain = true

[assets]
directory = "./dist"
binding = "ASSETS"
not_found_handling = "single-page-application"
```

The worker serves the built assets and falls back to `index.html` so
client-side routes survive a reload. It has no secrets of its own. Choose the
name before the first deploy and keep it: a renamed worker is a second worker,
and the domain stays bound to the first.

## The push worker

```sh
npx fundive deploy push
```

`workers/push/wrangler.toml` names it, sets the crons, and holds its
non-secret `[vars]`; its secrets are set once and survive every deploy:

```sh
npx wrangler secret put VAPID_PRIVATE_KEY --config workers/push/wrangler.toml
```

The full list and the VAPID key setup are in
[push-notifications.md](./push-notifications.md). Never run two push workers
for one shop: both would run the crons and every reminder would go out twice.

## The edge functions

```sh
npx fundive functions deploy
npx supabase secrets set --project-ref <your-project-ref> \
  GMAIL_USER=<shop-gmail-account> \
  GMAIL_APP_PASSWORD=<app-password> \
  TURNSTILE_SECRET=<turnstile-secret-key>
```

`functions deploy` serializes your `fundive.config.ts` into the
`FUNDIVE_CONFIG` Supabase secret, then deploys every function from the
platform. The functions read shop config only through that secret (the seam is
`supabase/functions/_shared/config.ts`), so your shop name, currency, language
and app URL are the ones in emails and on the registration PDF. Always deploy
functions this way: a bare `supabase functions deploy` leaves the secret as it
was, and without it the functions use the platform's placeholder shop.

The secrets set with `supabase secrets set` are set once and survive deploys:

| Secret | What it is |
| --- | --- |
| `GMAIL_USER` | Gmail account that sends the mail |
| `GMAIL_APP_PASSWORD` | Gmail [app password](https://support.google.com/accounts/answer/185833), not the account password |
| `TURNSTILE_SECRET` | Cloudflare Turnstile secret key, paired with `VITE_TURNSTILE_SITE_KEY`. `create-registration` and `create-account` return 500 without it rather than accept an unverifiable token |

`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` and `SUPABASE_ANON_KEY` are injected
by the edge runtime.

## The schema

The platform's migrations live in the platform, and `db push` applies the ones
your database lacks:

```sh
npx fundive db verify            # what the platform has, what your database has
npx fundive db push --dry-run    # what a push would apply
npx fundive db backup            # a rollback point
npx fundive db push
```

Migrations are forward-only. Push the schema before deploying code that needs
it: an upgrade's new column must exist before the app that reads it goes out.

## GitHub Actions

The deployment repository ships two **manual** workflows (Actions → pick one →
Run workflow). Nothing deploys because a commit landed.

| Workflow | Does | Inputs |
| --- | --- | --- |
| **Deploy** | `fundive build` + `fundive deploy`, `fundive deploy push`, `fundive functions deploy` | `target`: all / spa / push-worker / edge-functions |
| **Push migrations** | `fundive db verify`, then `fundive db push` | `dry_run`, **on by default** |

They are separate buttons on purpose: schema first, looked at, then the code
that expects it. Both run only from `main` and declare `environment:
production`, so reviewers or wait timers set in Settings → Environments apply.

Repository secrets (Settings → Secrets and variables → Actions), the same
values as `.env.local`:

| Secret | Used by |
| --- | --- |
| `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | Deploy (spa, push-worker) |
| `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `VITE_TURNSTILE_SITE_KEY` | Deploy (spa); the build fails without them |
| `VITE_VAPID_PUBLIC_KEY`, `VITE_PUSH_WORKER_URL` | Deploy (spa); optional |
| `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF` | Deploy (edge-functions) |
| `SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD`, `SUPABASE_POOLER_HOST` | Push migrations |

Runtime secrets (the VAPID private key, the service-role key, Gmail, Turnstile)
stay on Cloudflare and Supabase; the workflows deploy code and never touch them.

## Upgrading

`package.json` pins the platform to a commit or a release tag. To upgrade:

1. Move the pin (`"fundive": "github:fundive/fundive#<new commit or tag>"`),
   then `npm install` and commit `package.json` and `package-lock.json`.
2. `npx fundive build` — a config whose shape changed fails here, naming the
   field to update.
3. `npx fundive db push --dry-run`, then `npx fundive db push`.
4. `npx fundive functions deploy`, `npx fundive deploy push`,
   `npx fundive deploy` (or the Deploy workflow with `all`).

## Rollback

- **App or push worker:** `npx wrangler deployments list` shows history and
  `npx wrangler rollback <deployment-id>` reverts (add
  `--config workers/push/wrangler.toml` for the push worker). Or move the pin
  back and deploy again.
- **Edge functions:** move the pin back and `npx fundive functions deploy`.
- **Schema:** there is no down-migration. A schema problem is fixed by a
  forward migration in the platform; a disaster is a restore from
  `npx fundive db backup` or Supabase's backups (dashboard → Database →
  Backups).

## Adopting an existing Supabase project

If your database was built from a *different* repo — a shop's own copy of the
app before it moved to a deployment repo — the schema may already be right
while the migration registry (`supabase_migrations.schema_migrations`) lists
that repo's files, and `db push` refuses:

```
Remote migration versions not found in local migrations directory.
```

Fix the registry, not the schema:

```sh
npx fundive db backup                                           # always, first
npx fundive db adopt --baseline <version>                       # dry run
npx fundive db adopt --baseline <version> --apply
npx fundive db push                                             # applies only what's new
```

`<version>` is the platform's squashed baseline, the first file in its
`supabase/migrations/`. Adoption:

1. marks every version your database has and the platform does not as
   `reverted` (their objects stay in the database, untouched);
2. marks the baseline `applied` **without running it**;
3. with `--applied-through <version>`, also marks every other platform version
   up to that one as applied without running it — for a database that already
   has those changes under different version numbers. Make that claim only
   after diffing your schema against the platform's at that version;
4. leaves the rest for `db push`.

It edits the registry only, never your schema or data. Rehearse it against a
restored backup first by pointing `SUPABASE_DB_URL` at the restored copy.

Objects that only the old repo's migrations created stay behind, working but
untracked. Review them and, if you no longer want them, remove them with a
forward migration.
