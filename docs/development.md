# Local development — from clone to a working app

Everything here runs on your machine: a Supabase stack in Docker, Vite, and a
database seeded with test divers you can sign in as. Nothing is created in the
cloud and nothing costs money.

If you are a shop owner wanting a **live** app rather than a development copy,
you want [self-hosting.md](./self-hosting.md) instead — it is the same journey
with hosted services, written for someone who does not code.

**Prerequisites**

- [Node.js](https://nodejs.org) LTS and npm
- [Docker](https://www.docker.com), running

The Supabase CLI ships as a dev dependency, so `npm install` provides it. Don't
install it globally — a global CLI on a different version is the usual cause of
a stack that boots but won't migrate.

## 1. Clone and install

```sh
git clone https://github.com/fundive/fundive.git
cd fundive
npm install
```

## 2. Point the app at the local stack

```sh
cp .env.example .env.local
```

There is nothing to fill in. Every deployment value in that file is a
placeholder none of the local commands read, and the three the app actually
needs come already set to local values:

```sh
VITE_SUPABASE_URL=http://127.0.0.1:64421
VITE_SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0
VITE_TURNSTILE_SITE_KEY=1x00000000000000000000AA
```

None of these are secrets:

- The **anon key** is the Supabase CLI's fixed local demo key. It is identical on
  every machine, signs tokens for a database only you can reach, and is not the
  key your deployment will use.
- The **Turnstile site key** is Cloudflare's published always-pass test key, so
  the captcha on guest registration renders and clears without a Cloudflare
  account. Its paired always-pass secret is
  `1x0000000000000000000000000000000AA`, which you only need when running the
  edge functions locally (step 6).

If `supabase start` ever reports different ports, `make status` prints the real
ones.

## 3. Boot the database

```sh
make start
```

First run pulls the Postgres, Auth, PostgREST and Studio containers, so give it
a few minutes. It then applies every migration in `supabase/migrations/` and the
seed files listed in `supabase/config.toml`.

You now have:

| | |
| --- | --- |
| API | http://127.0.0.1:64421 |
| Studio (browse + edit the DB) | http://127.0.0.1:64423 — or `make studio` |
| Mailpit (every email the app sends) | http://127.0.0.1:64424 |

## 4. Run the app

```sh
make dev
```

Vite prints a URL — open it.

## 5. Sign in

`supabase/seeds/test-users.sql` creates three confirmed accounts, one per role:

| Email | Password | Role |
| --- | --- | --- |
| `diver@diver.diver` | `diverdiver` | diver |
| `admin@admin.admin` | `adminadmin` | admin |
| `staff@staff.staff` | `staffstaff` | staff |

The login page shows a button per account in dev builds, so you can fill the
form with one click rather than typing them. Sign in as **admin@admin.admin** to
see the whole app — creating events, managing divers, the catalog editors and
the admin dashboards all live behind that role.

Signing up through the app instead gets you a `diver`. To promote an account,
open Studio → `profiles` → set `role` to `admin`, or run in Studio's SQL editor:

```sql
update public.profiles set role = 'admin' where email = 'you@example.com';
```

(On a deployed shop this is [self-hosting.md Part 8](./self-hosting.md), which
does the same thing through the hosted Supabase dashboard.)

## 6. Optional: run the edge functions

Registration, account creation, and the emails and PDFs that go with them run as
Supabase Edge Functions. The app works without them — you can browse, create
events and manage divers — but a booking that would email a PDF needs one
running:

```sh
supabase functions serve create-registration --env-file .env.local
```

Add to `.env.local` first:

```sh
TURNSTILE_SECRET=1x0000000000000000000000000000000AA
GMAIL_USER=you@example.com
GMAIL_APP_PASSWORD=whatever
```

The Gmail values are only read when a function actually sends; with the local
stack up, mail is captured by Mailpit rather than delivered, so they need not be
real. See [deployment.md](./deployment.md#edge-functions) for the full list of
function secrets.

Push notifications need VAPID keys and a deployed Cloudflare Worker; they stay
off locally, which is deliberate — see [push-notifications.md](./push-notifications.md).

## 7. Run the tests

```sh
make test
```

That is typecheck + lint + `deno check` over the edge functions + every Vitest
project. The unit suite needs nothing but `npm install`; the integration,
scenario and security suites talk to the local stack, so `make start` has to
have run. See [testing.md](./testing.md).

## Everyday commands

```sh
make dev       # Vite against the local stack
make start     # boot the stack        make stop    # shut it down
make status    # ports and keys        make studio  # open Studio
make reset     # wipe and re-apply every migration + seed
make test      # the full gate         make lint    # eslint only
```

`make reset` is the one to reach for when local data gets into a state you can't
reason about: it drops the database, replays every migration, and re-seeds the
three test accounts. It never touches anything remote.

## Where to go next

- [architecture.md](./architecture.md) — how the platform and a deployment
  relate, and where the customization boundary sits.
- [forking.md](./forking.md) — making a clone yours: `fundive.config.ts`,
  branding assets, Terms of Use.
- [data-model.md](./data-model.md) — the unified `events` table and everything
  hanging off it.
- [deployment.md](./deployment.md) — which secret lives where, and shipping to
  Supabase + Cloudflare.

## Troubleshooting

**`make start` hangs or a container won't come up.** Check Docker is running,
then `make stop && make start`. If a port is taken, `docker ps` shows what has
it — FunDive uses 6442x precisely so it can sit alongside another Supabase
project.

**The app loads but every list is empty and nothing errors.** The client is
pointed at a stack that isn't answering. Compare `.env.local` against
`make status`; the lib helpers swallow auth failures and return `[]`, so a wrong
key looks like an empty database rather than an error.

**`npm run build` fails with "This env cannot produce a shippable bundle".**
Expected, if `.env.local` still holds the local values — a production bundle
pointing at `127.0.0.1`, or carrying Cloudflare's always-pass captcha key, is
never what you meant. The message names each one. `make dev` is unaffected;
only `build` is gated (`src/vite/build-env.ts`).

**Integration tests fail with `expected false to be true`.** That signature is
bad keys, not bad code. `make start`, then re-run.

**Sign-in rejects the seeded accounts.** They are created by the seed files,
which run on `supabase db reset` — `make reset` puts them back.
