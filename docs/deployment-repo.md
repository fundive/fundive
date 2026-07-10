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
  package.json          # depends on the platform, pinned to a release tag
  fundive.config.ts     # identity, contact, theme, locale, feature toggles
  .env                  # infra credentials  — GITIGNORED
  .env.example          # documents the required vars (committed)
  .gitignore            # ignores .env and build output
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
`fundive.config.ts` and `.env` are the ones used. The platform's `vite.config.ts`
resolves `virtual:fundive-config` from `process.cwd()`.

| Command | What it does |
| --- | --- |
| `fundive dev` | dev server against a local Supabase stack |
| `fundive build` | production build, with your branding baked in |
| `fundive preview` | serve the production build locally |
| `fundive deploy` | deploy the SPA worker to your Cloudflare |
| `fundive db push` | apply the platform's migrations to your Supabase |
| `fundive db verify` | confirm your schema matches the pinned platform version |
| `fundive functions deploy` | deploy the edge functions to your Supabase |
| `fundive version` | print the platform version |

`fundive functions deploy` also serialises your `fundive.config.ts` into the
`FUNDIVE_CONFIG` Supabase secret. The edge functions read it through
`supabase/functions/_shared/config.ts`, so your shop's name, currency and
**language** are the ones used in emails and the registration PDF — not the
platform's defaults.

## Status: what works today

The command surface exists and works **when run from a clone of the platform
repo**. Installed as a dependency, most of it does not yet, because the tools the
CLI shells out to are the platform's `devDependencies` and a consumer install
does not get them.

Verified against a packed tarball installed with `npm install --omit=dev`:

| Command | From a platform clone | From a deployment repo |
| --- | --- | --- |
| `fundive version` | works | works |
| `fundive build` | works — bakes in the deployment's config | **fails**: `spawn vite ENOENT` |
| `fundive dev` / `preview` / `deploy` | works | **fails**: `spawn vite` / `spawn wrangler ENOENT` |
| `fundive db push` / `db verify` | works | **fails**: `spawn supabase ENOENT` |
| `fundive functions deploy` | works | **fails**: needs `esbuild`, absent |

### What has to change first

1. **`vite`, `wrangler`, `supabase` and `esbuild` must move to
   `dependencies`.** They are runtime requirements of the CLI, not development
   tools of the platform. `esbuild` is not currently declared at all — it is
   imported by `cli/load-site-config.mjs` and resolves only via `vite`'s
   transitive tree.
2. **The package needs a `files` allowlist.** The tarball currently ships
   `docs/`, `tests/`, `dist/`, `.claude/`, and the platform's *own*
   `fundive.config.ts` — so a deployment installs FunDive's development shop
   config alongside its own.
3. **`private: true` must go**, or the platform must be consumed by git URL only
   (which is the current plan — `private` blocks registry publishing, not
   `github:` installs).
4. **Branding assets are not yet overridable.** `assets.*` in the config are
   paths like `/imgs/fd_logo.png`, resolved against the *platform's* `public/`.
   A deployment cannot yet supply its own logo or icons; `architecture.md`'s
   `brand/` and `catalog/` directories are not implemented anywhere.
5. **`fundive deploy` deploys only the SPA worker.** The push-notification worker
   (`workers/push/wrangler.toml`) is a separate deploy.

Until then, a shop should [fork the platform](./forking.md) and run `make deploy`
from the fork. Same config seam, same edge-function config injection; the only
difference is that the shop's repo contains the platform source, so upgrades are
a merge rather than a version bump.

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
