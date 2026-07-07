# Trusted partners

A shop-curated directory of **vouched partner dive shops** — places the shop
trusts to send divers when a request falls outside its own waters — plus an
in-app channel for a diver to message one of them. It's the referral counterpart
to [Packages](./packages.md): Packages lists specific partner *travel packages*
abroad you can book; Trusted Partners is the directory of partner *shops* and a
way to reach them. Both read the **same** `trusted_partners` table — a package's
hosting shop is a row here (`packages.trusted_partner_id`).

The load-bearing design goal is **email privacy**: a partner's contact address is
never exposed to divers. Divers see only a name, region, blurb, and optional
website; the message is relayed server-side.

## Data model

One table, `trusted_partners`. It began as a thin directory (migration
[`20260706000000_trusted_partners.sql`](https://github.com/fundive/fundive/blob/main/supabase/migrations/20260706000000_trusted_partners.sql))
and was later **unified** with the richer `partner_shops` registry that hosts
Packages, keeping the superset under the `trusted_partners` name (migration
[`20260708080000_unify_partner_tables.sql`](https://github.com/fundive/fundive/blob/main/supabase/migrations/20260708080000_unify_partner_tables.sql)):

| Column | Notes |
| --- | --- |
| `id` | uuid PK |
| `name` | Partner shop name (public) |
| `country` | Country — **nullable** (directory-only partners may omit it) |
| `location` | Where they operate, e.g. "Cebu, Philippines" (public) |
| `website` | Partner site link (public, optional) |
| `logo_url` | Partner logo (public, optional) |
| `vouch_notes` | Why the shop vouches for them (public) |
| `contact_name` | Internal contact person — admin-only |
| `contact_email` | Contact address — **private**, admin-only |
| `default_kickback_rate` | Default Packages kickback rate — admin-only |
| `active` | Retired partners set `false`; hidden from divers |
| `created_by` / `created_at` | Audit |

**RLS is admin-only for every verb** (`is_admin()` in `using` + `with check`), so
a diver's direct `select` on `trusted_partners` returns nothing — `contact_email`
can't leak through PostgREST. Divers read the directory through one
`SECURITY DEFINER` RPC instead:

```sql
list_trusted_partners()  -- returns id, name, region (= coalesce(location, country)),
                         -- blurb (= vouch_notes), website — for active rows that have
                         -- a contact_email. No email column in the projection.
                         -- Granted to authenticated.
```

The integration test
[`tests/integration/trusted-partners.test.ts`](https://github.com/fundive/fundive/blob/main/tests/integration/trusted-partners.test.ts)
pins this contract: a diver's direct table read is empty, the RPC row has no
`contact_email` property, retired partners are withheld, and an admin's direct
read does return the contact email.

## Diver side — `/partner-connect`

`TrustedPartnersPage` (`src/pages/TrustedPartnersPage.tsx`) lists the active
partners from `list_trusted_partners()` (so, no emails on the wire) and, for each,
offers a **"send a message"** form. It also embeds the open-ended
"request a destination" form (`sendPartnerConnectRequest`) for divers who want
somewhere not yet listed.

## Messaging — the `contact-trusted-partner` edge function

A diver's message is relayed by
[`supabase/functions/contact-trusted-partner/index.ts`](https://github.com/fundive/fundive/blob/main/supabase/functions/contact-trusted-partner/index.ts).
It resolves the partner's `contact_email` **server-side** with the service-role
key (the client only ever sent a `partner_id`) and sends one email:

- **To:** the partner (resolved server-side).
- **CC:** the shop inbox (`siteConfig.app.supportEmail`) — so the business sees
  what it brokered.
- **From:** the shop's Gmail, display name `siteConfig.app.name` — the partner
  knows the shop vouched for the intro.
- **Reply-To:** the diver's own email — so the partner answers the diver directly.

It verifies the caller's Bearer JWT, validates `{ partner_id, message }`, returns
**404** if the partner is missing or `active = false`, and never writes to the DB.
The partner's address appears in exactly one place — the SMTP envelope — and never
in a response body. Email delivery uses the same Gmail SMTP secrets as the rest of
the platform (`GMAIL_USER` / `GMAIL_APP_PASSWORD`; see
[deployment.md](./deployment.md)).

## Admin side — `/admin/trusted-partners`

`AdminTrustedPartnersPage` (`src/pages/admin/AdminTrustedPartnersPage.tsx`) is
plain CRUD over `trusted_partners`, **including** the private `contact_email` /
`contact_name` / `default_kickback_rate` columns (admins read and write them
directly under their RLS). This is the single editor for every partner — the
same rows are picked from a dropdown when curating a Package
([packages.md](./packages.md)). Retire a partner by unticking `active` rather
than deleting, so historical intros keep their referent.

## Shop-config touch-points

Nothing about a partner is shop-config — partners are data a shop enters. But the
relay reads two config fields through the edge `_shared/config.ts` seam:
`siteConfig.app.supportEmail` (the CC inbox) and `siteConfig.app.name` (the From
name). Both come from `fundive.config.ts` — see [forking.md](./forking.md).
