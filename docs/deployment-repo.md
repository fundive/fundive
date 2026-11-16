# The deployment repository

A **deployment repo** is the small repository a dive shop actually owns. It holds
the shop's config, its secrets, and its branding — and no platform source. The
platform (this repo) is a dependency, driven through the `fundive` CLI.

This is the model [architecture.md](./architecture.md) describes. Read this page
first: parts of it are not finished, and the gaps are listed below rather than
glossed over. If you want a shop running **today**, use
[forking.md](./forking.md), which is fully supported.

## What it contains

```
my-dive-shop/
  package.json               # depends on the platform, pinned to a release tag
  fundive.config.ts          # identity, theme, locale, feature toggles
  public/                    # your logo, icons, favicon; laid over the platform's
  wrangler.toml              # optional: your SPA worker's name and domain
  workers/push/wrangler.toml # optional: your push worker's name, vars and crons
  .env                       # infra credentials  — GITIGNORED
  .env.example               # documents the required vars (committed)
  .gitignore                 # ignores .env, node_modules and dist
```

Nothing else. If you find yourself adding a `src/`, that is a signal the change
belongs in the platform as a config field or an upstream feature.

Start from [`fundive.config.example.ts`](https://github.com/fundive/fundive/blob/main/fundive.config.example.ts):

```sh
cp node_modules/fundive/fundive.config.example.ts fundive.config.ts
```

It is a filled-in template with every value replaced by a placeholder. The shape
is checked against `SiteConfig` at build time, and `configVersion` must match the
platform's `CONFIG_CONTRACT_VERSION` — a stale config fails the build with a
message naming the field, rather than misbehaving at runtime.

### Branding assets

The app serves the platform's `public/` with yours laid over it: a file at the
same path in your `public/` wins, anything you leave out falls back to the
platform's. Point `assets.*` in the config at your files. The two are merged
into `node_modules/.cache/fundive/public` when the dev server or build starts,
so a file you add while `fundive dev` runs needs a restart.

### Worker names and domains

`fundive deploy` uses your `wrangler.toml` if you have one, otherwise the
platform's (worker `fundive-app`, no custom domain). Yours names the worker and
its route and points `main` into the platform:

```toml
name = "my-shop-app"
main = "node_modules/fundive/src/worker.ts"
compatibility_date = "2026-04-01"

[[routes]]
pattern = "app.myshop.com"
custom_domain = true

[assets]
directory = "./dist"
binding = "ASSETS"
not_found_handling = "single-page-application"
```

`fundive deploy push` does the same with `workers/push/wrangler.toml` (`main =
"../../node_modules/fundive/workers/push/src/index.ts"`), which is where your
push worker's name, `[vars]` and crons live. Keep a worker's name once it is
live: a renamed push worker is a second worker, and both run the crons.

## Depending on the platform

Pin a **release tag**, never a branch. A tag makes the deployment reproducible
and makes upgrades a deliberate act:

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

Upgrading is editing that one line, then `npm install`, `npx fundive db push`,
`npx fundive deploy`.

## The CLI

Every command runs from the deployment's directory, so the deployment's
`fundive.config.ts` and `.env` are the ones used (the process environment wins
over the file, for CI).

| Command | What it does |
| --- | --- |
| `fundive dev` | dev server against a local Supabase stack |
| `fundive build` | production build, with your branding baked in |
| `fundive preview` | serve the production build locally |
| `fundive deploy` | deploy the SPA worker to your Cloudflare |
| `fundive deploy push` | deploy the push-notification cron worker |
| `fundive db push` | apply the platform's migrations to your Supabase |
| `fundive db adopt …` | adopt a database built from another repo (dry run unless `--apply`) |
| `fundive functions deploy` | deploy the edge functions to your Supabase |
| `fundive version` | print the platform version |

`fundive db push` and `db adopt` connect with `SUPABASE_DB_URL`, or build the
URL from `SUPABASE_POOLER_HOST`, `SUPABASE_PROJECT_REF` and
`SUPABASE_DB_PASSWORD`.

`fundive functions deploy` also serializes your `fundive.config.ts` into the
`FUNDIVE_CONFIG` Supabase secret. The edge functions read it through
`supabase/functions/_shared/config.ts`, so your shop's name, currency and
**language** are the ones used in emails and the registration PDF — not the
platform's defaults. Deploy functions only through this command; a plain
`supabase functions deploy` leaves the secret as it was.

The vite, wrangler and supabase CLIs the platform drives are its runtime
dependencies, so `npm install` in the deployment is all the tooling it needs.
Verified by installing a packed tarball with `npm install --omit=dev` into a
bare directory and running `fundive dev` from it.

The push worker's secrets (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`,
`VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `ADMIN_TRIGGER_SECRET`) are set once
with `npx wrangler secret put <NAME> --config workers/push/wrangler.toml`.

## Secrets

Credentials are per-account, not app data, so they never appear in
`fundive.config.ts`. They live in the deployment's `.env` — see
[deployment.md](./deployment.md#environment-variables) for the full list — and in
your CI's secret store. The build **fails** if a required `VITE_*` var is
missing, rather than shipping an app whose Supabase client cannot initialise.

## Adopting a database that already exists

If your Supabase project was built from a different repo — an older fork, say —
its migration registry will not match the platform's. Do not re-run migrations.
See [Adopting an existing Supabase project](./deployment.md#adopting-an-existing-supabase-project).
