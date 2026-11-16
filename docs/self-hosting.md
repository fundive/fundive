# Self-hosting walkthrough — launch your shop's app step by step

This walkthrough takes you from nothing to a live booking app for your dive
shop. **You do not need to be a programmer.** Most of it is creating accounts and
clicking buttons on websites; a couple of steps ask you to copy-paste a few
commands into a terminal, and each one is spelled out exactly. Budget an
afternoon the first time.

**What it costs:** the free tiers of GitHub, Supabase, and Cloudflare comfortably
run a small shop — you can launch for **$0**. You'll only pay later if you
outgrow the free limits or add a paid custom domain.

**Accounts you'll create** (all free to start):

| Service | What it does for you |
| --- | --- |
| [GitHub](https://github.com/signup) | Stores your shop's own small repository and runs its deploy buttons |
| [Supabase](https://supabase.com) | Your database + logins (where bookings and diver accounts live) |
| [Cloudflare](https://dash.cloudflare.com/sign-up) | Hosts the actual website your divers visit |
| A [Gmail](https://gmail.com) account | Sends booking-confirmation emails |

**On your own computer, one time:** install [Node.js](https://nodejs.org) (pick
the "LTS" button) and [Git](https://git-scm.com/downloads). These let you run the
copy-paste commands below. You do **not** need Docker.

**How it fits together:** FunDive itself stays where it is, on GitHub. Your shop
gets its own small repository holding only what is yours: your settings, your
logo and photos, and the names of your servers. Your repository points at the
FunDive version it runs, and the `npx fundive` commands build and deploy the
app from the two together.

---

## Part 1 · Create your shop's repository

1. Open a terminal and run these (`my-shop` can be any folder name):

   ```sh
   npx github:fundive/fundive init my-shop
   cd my-shop
   npm install
   cp .env.example .env.local
   ```

   `my-shop` now holds your settings file (`fundive.config.ts`), an empty
   `public/` folder for your images, your private credentials file
   (`.env.local`, which never leaves your computer), and two deploy buttons for
   GitHub.
2. Put it on GitHub: **New repository** → name it (say `my-shop`) → **Create
   repository**, without adding a README. Then, in the terminal (replace
   `<your-username>`):

   ```sh
   git init -b main
   git add -A
   git commit -m "my shop"
   git remote add origin https://github.com/<your-username>/my-shop.git
   git push -u origin main
   ```

## Part 2 · Create your database (Supabase)

1. In Supabase, click **New project**. Give it a name, pick a region near your
   divers, and **write down the database password it generates**.
2. Wait ~2 minutes for it to finish, then open `.env.local` in any text editor
   and fill in the Supabase lines:

   | Line in `.env.local` | Where to find it |
   | --- | --- |
   | `VITE_SUPABASE_URL` | **Project Settings → API** → Project URL |
   | `VITE_SUPABASE_ANON_KEY` | **Project Settings → API** → the `anon` `public` key |
   | `SUPABASE_PROJECT_REF` | **Project Settings → General** → Reference ID (a short code like `abcdefghij`) |
   | `SUPABASE_DB_PASSWORD` | the password from step 1 |
   | `SUPABASE_POOLER_HOST` | the **Connect** button at the top of the project → **Session pooler**: the host part of that connection string, like `aws-0-ap-east-1.pooler.supabase.com` |
   | `SUPABASE_ACCESS_TOKEN` | your account menu → **Access Tokens** → **Generate new token** |

   Keep the **`service_role`** key from **Project Settings → API** handy too;
   you'll need it in Part 7 if you turn on push notifications. Save the file.
3. Build the database's tables:

   ```sh
   npx fundive db push
   ```

   Answer `Y` when it asks. When it finishes without red errors, your database
   is ready. `npx fundive db verify` lists every migration as applied.

## Part 3 · Make it your shop

1. **`fundive.config.ts`** — your shop's name, website, timezone, currency,
   language, gear list and prices, and which of the two designs you want. Every
   field is explained in [configuration.md](./configuration.md).
2. **Images in `public/`** — your logo and icons, at the paths listed under
   `assets` in `fundive.config.ts` (for example `public/imgs/fd_logo.png` for
   the logo). Anything you leave out shows FunDive's placeholder. The list is in
   [configuration.md § 2](./configuration.md#_2-branding-assets-in-public).
3. **Terms of Use** — written inside the app, not in a file. Once you are
   running, sign in as an admin and open **Manage → Terms of Use**, then click
   **Load starter template** and fill in every `TODO`. Have someone check the
   legal side before you go live.

Save your changes to GitHub whenever you like:
`git add -A && git commit -m "shop settings" && git push`.

## Part 4 · Get an anti-spam key (Cloudflare Turnstile)

The sign-up form uses a free "are you human?" check.

1. In the Cloudflare dashboard, open **Turnstile → Add widget**. Enter your
   site's domain (you can use the temporary one from Part 5 and update it later).
2. Put the **Site Key** in `.env.local` as `VITE_TURNSTILE_SITE_KEY`, and keep
   the **Secret Key** for Part 6.

## Part 5 · Put the website online (Cloudflare)

1. **Get two Cloudflare values** and put them in `.env.local`: the **Account
   ID** (on the right of the **Workers & Pages** page) as
   `CLOUDFLARE_ACCOUNT_ID`, and an API token (**My Profile → API Tokens →
   Create Token → "Edit Cloudflare Workers"** template) as
   `CLOUDFLARE_API_TOKEN`.
2. **Publish:**

   ```sh
   npx fundive build
   npx fundive deploy
   ```

   Your app is live at a `https://fundive-app.<your-subdomain>.workers.dev`
   address (shown in the Cloudflare dashboard under **Workers & Pages**). To
   give the server your shop's name instead, change `name` in `wrangler.toml`
   **before** this first deploy. Your own domain can be added later in
   `wrangler.toml` (see [deployment.md § The app worker](./deployment.md#the-app-worker)).

**Rather click a button than run commands?** Your repository has a **Deploy**
button: in GitHub, **Settings → Secrets and variables → Actions → New
repository secret**, add the values from your `.env.local` (the list is in
[deployment.md § GitHub Actions](./deployment.md#github-actions)), then
**Actions → Deploy → Run workflow**. Useful when more than one person ships,
or when you would rather not keep the credentials on a laptop.

## Part 6 · Turn on booking emails

Registration confirmations are sent from your Gmail.

1. In your Google account, turn on 2-Step Verification, then create an **[App
   Password](https://support.google.com/accounts/answer/185833)** (a 16-character
   code just for this app).
2. In your terminal (still in your shop's folder), run:

   ```sh
   npx fundive functions deploy
   npx supabase secrets set --project-ref <your-Reference-ID> \
     GMAIL_USER=<your-gmail-address> \
     GMAIL_APP_PASSWORD=<the-app-password> \
     TURNSTILE_SECRET=<the-Turnstile-Secret-Key>
   ```

   The first command uploads the app's server functions along with your shop's
   settings, so emails carry your shop's name. The second gives them your Gmail
   and the Turnstile **Secret** Key from Part 4. Emails now send on every
   registration.

## Part 7 · (Optional) Push notifications

Booking reminders and admin broadcasts are optional. If you want them, follow
[push-notifications.md](./push-notifications.md) — it walks through generating
the notification keys, setting the push worker's secrets, and deploying it with
`npx fundive deploy push`. You can skip this and add it any time; the app works
fine without it.

## Part 8 · Make yourself the admin

1. Open your live app and **sign up** like a normal diver would, with your own
   email.
2. In Supabase, open **SQL Editor → New query**, paste this (with your email),
   and click **Run** — it promotes your account to administrator:

   ```sql
   update public.profiles
   set role = 'admin'
   where id = (select id from auth.users where email = 'you@yourshop.com');
   ```

3. Refresh the app — you now have the admin menu (create dives, manage divers,
   logistics, and so on).

## Part 9 · Go-live checklist

- [ ] Your logo, design, and shop details look right (`fundive.config.ts` + images).
- [ ] A test booking works end-to-end and you received the confirmation email.
- [ ] Terms of Use reviewed for your jurisdiction.
- [ ] (Optional) Your own domain on the app worker (`wrangler.toml`).
- [ ] **A visible link to your source code** is present in the app — this is
      required by the license (see [License](https://github.com/fundive/fundive/blob/main/README.md#license)). Your
      app is FunDive plus your repository's settings, run over the network, so
      AGPL §13 obliges you to offer users that source; a public shop repository
      that names the FunDive version it pins does it.

**Closing down one day?** [shutdown.md](./shutdown.md) is this walkthrough in
reverse: what to settle first, how to take your records with you, and the order
to switch things off in.

**Keeping up to date:** new FunDive versions arrive when you move the version
your `package.json` points at; [deployment.md § Upgrading](./deployment.md#upgrading)
is the four steps.

**Stuck?** Open an issue on the FunDive repo, or read the deeper docs —
[deployment.md](./deployment.md) maps every key to where it goes, and
[configuration.md](./configuration.md) covers the config fields in detail.
