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
| [GitHub](https://github.com/signup) | Stores your copy of the code and runs the deploy for you |
| [Supabase](https://supabase.com) | Your database + logins (where bookings and diver accounts live) |
| [Cloudflare](https://dash.cloudflare.com/sign-up) | Hosts the actual website your divers visit |
| A [Gmail](https://gmail.com) account | Sends booking-confirmation emails |

**On your own computer, one time:** install [Node.js](https://nodejs.org) (pick
the "LTS" button) and [Git](https://git-scm.com/downloads). These let you run the
two or three setup commands below. (You do **not** need Docker unless you also
want to run the app on your own machine for testing.)

---

## Part 1 · Copy the code

1. Sign in to GitHub and open **https://github.com/fundive/fundive**.
2. Click **Fork** (top-right) → **Create fork**. You now own a copy at
   `github.com/<your-username>/fundive`. Everything below happens in *your* copy.

## Part 2 · Create your database (Supabase)

1. In Supabase, click **New project**. Give it a name, pick a region near your
   divers, and **write down the database password it generates** — you'll need it
   in a moment.
2. Wait ~2 minutes for it to finish, then open **Project Settings** (the gear):
   - **Settings → API** → copy the **Project URL** and the **`anon` `public`**
     key, and the **`service_role`** key (keep this one secret).
   - **Settings → General** → copy the **Reference ID** (a short code like
     `abcdefghij`).
   - **Settings → Access Tokens** (your account menu → **Access Tokens**) →
     **Generate new token**, copy it.
3. Now load the app's database structure. On your computer, open a terminal and
   run these (replace `<your-username>`):

   ```sh
   git clone https://github.com/<your-username>/fundive.git
   cd fundive
   npm install
   cp .env.example .env.local
   ```

4. Open the new `.env.local` file in any text editor and fill in the values you
   copied — the lines starting with `SUPABASE_` and `VITE_SUPABASE_`
   (`VITE_SUPABASE_URL` = Project URL, `VITE_SUPABASE_ANON_KEY` = the anon key,
   `SUPABASE_PROJECT_REF` = Reference ID, `SUPABASE_DB_PASSWORD` = the password
   from step 1, `SUPABASE_ACCESS_TOKEN` = the token from step 2). Save it.
5. Back in the terminal, run:

   ```sh
   make link      # connects to your Supabase project
   make push      # builds all the tables — this is the important one
   ```

   When `make push` finishes without red errors, your database is ready. (You can
   confirm with `make verify`.)

## Part 3 · Make it your shop

You can edit these files right in GitHub's website — no terminal needed. In your
fork, click a file, then the **pencil** icon to edit, and **Commit changes** to
save.

1. **`fundive.config.ts`** — your shop's name, contact details, timezone,
   currency, gear list, and colors. Every field is explained in
   [`forking.md`](forking.md). This is the main "make it mine" file.
2. **Images in `public/`** — replace the logo and icons with yours (drag your
   files in via GitHub's **Add file → Upload files**, keeping the same file
   names). The list of images is in [`forking.md`](forking.md).
3. **`src/config/terms.tsx`** — your Terms of Use / privacy wording. Have someone
   check the legal side before you go live.

## Part 4 · Get an anti-spam key (Cloudflare Turnstile)

The sign-up form uses a free "are you human?" check.

1. In the Cloudflare dashboard, open **Turnstile → Add widget**. Enter your
   site's domain (you can use the temporary one from Part 5 and update it later).
2. Copy the **Site Key** and **Secret Key** it gives you.

## Part 5 · Put the website online (Cloudflare + GitHub)

GitHub will build and publish the site for you — you just give it the keys once.

1. **Get two Cloudflare values:** in the Cloudflare dashboard, the **Account ID**
   is on the right of the Workers page. Then **My Profile → API Tokens → Create
   Token → "Edit Cloudflare Workers"** template → copy the token.
2. **Tell GitHub the keys:** in your fork, go to **Settings → Secrets and
   variables → Actions → New repository secret**, and add each of these (name on
   the left, value on the right):

   | Secret name | Value |
   | --- | --- |
   | `CLOUDFLARE_API_TOKEN` | the token from step 1 |
   | `CLOUDFLARE_ACCOUNT_ID` | the Account ID from step 1 |
   | `VITE_SUPABASE_URL` | your Supabase Project URL |
   | `VITE_SUPABASE_ANON_KEY` | your Supabase anon key |
   | `VITE_TURNSTILE_SITE_KEY` | the Turnstile **Site** Key from Part 4 |

3. **Publish:** go to the **Actions** tab → **Deploy to Cloudflare** → **Run
   workflow** → choose **spa** → **Run**. After a few minutes it finishes green,
   and your app is live at a `https://fundive-app.<your-subdomain>.workers.dev`
   address (shown in the Cloudflare dashboard under **Workers**). You can attach
   your own domain there later.

## Part 6 · Turn on booking emails

Registration confirmations are sent from your Gmail. This step uses the terminal
again.

1. In your Google account, turn on 2-Step Verification, then create an **[App
   Password](https://support.google.com/accounts/answer/185833)** (a 16-character
   code just for this app).
2. In your terminal (still in the `fundive` folder), run:

   ```sh
   make deploy-functions
   npx supabase secrets set --project-ref <your-Reference-ID> \
     GMAIL_USER=<your-gmail-address> \
     GMAIL_APP_PASSWORD=<the-app-password> \
     TURNSTILE_SECRET=<the-Turnstile-Secret-Key>
   ```

   That's the Turnstile **Secret** Key from Part 4 (the secret half, not the site
   key). Emails now send on every registration.

## Part 7 · (Optional) Push notifications

Booking reminders and admin broadcasts are optional. If you want them, follow
[`push-notifications.md`](push-notifications.md) — it walks through generating the
notification keys, adding the push-worker secrets, and deploying the second
worker (in the **Actions** deploy, choose **push** or **both**). You can skip this
and add it any time; the app works fine without it.

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

- [ ] Your logo, colors, and shop details look right (`fundive.config.ts` + images).
- [ ] A test booking works end-to-end and you received the confirmation email.
- [ ] Terms of Use reviewed for your jurisdiction.
- [ ] (Optional) A custom domain attached in Cloudflare → Workers.
- [ ] **A visible link to your source code** is present in the app — this is
      required by the license (see [License](https://github.com/fundive/fundive/blob/main/README.md#license)); you're
      running a modified copy over the network, so AGPL §13 obliges you to offer
      users the source.

**Stuck?** Open an issue on the repo, or read the deeper docs in this folder —
[`deployment.md`](deployment.md) maps every key to where it goes, and
[`forking.md`](forking.md) covers the config fields in detail.
