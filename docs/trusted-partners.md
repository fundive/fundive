# Trusted partners

A shop-curated directory of **vouched partner dive shops** — places the shop
trusts to send divers when a request falls outside its own waters — plus an
in-app channel for a diver to message one of them. It's the referral counterpart
to the [Trip Board](./trip-board.md): the Trip Board lists specific partner
*trips* you can book; Trusted Partners is the directory of partner *shops* and a
way to reach them.

The load-bearing design goal is **email privacy**: a partner's contact address is
never exposed to divers. Divers see only a name, region, and blurb; the message
is relayed server-side.

## Data model

One table, `trusted_partners` (migration
[`20260706000000_trusted_partners.sql`](https://github.com/fundive/fundive/blob/main/supabase/migrations/20260706000000_trusted_partners.sql)):

| Column | Notes |
| --- | --- |
| `id` | uuid PK |
| `name` | Partner shop name (public) |
| `region` | Where they operate, e.g. "Cebu, Philippines" (public) |
| `blurb` | Why the shop vouches for them (public) |
| `email` | Contact address — **private**, admin-only |
| `active` | Retired partners set `false`; hidden from divers |
| `created_by` / `created_at` | Audit |

**RLS is admin-only for every verb** (`is_admin()` in `using` + `with check`), so
a diver's direct `select` on `trusted_partners` returns nothing — the `email`
column can't leak through PostgREST. Divers read the directory through one
`SECURITY DEFINER` RPC instead:

```sql
list_trusted_partners()  -- returns id, name, region, blurb for active rows.
                         -- No email column in the projection. Granted to authenticated.
```

The integration test
[`tests/integration/trusted-partners.test.ts`](https://github.com/fundive/fundive/blob/main/tests/integration/trusted-partners.test.ts)
pins this contract: a diver's direct table read is empty, the RPC row has no
`email` property, retired partners are withheld, and an admin's direct read does
return the email.

## Diver side — `/partner-connect`

`TrustedPartnersPage` (`src/pages/TrustedPartnersPage.tsx`) lists the active
partners from `list_trusted_partners()` (so, no emails on the wire) and, for each,
offers a **"send a message"** form. It also embeds the open-ended
"request a destination" form (`sendPartnerConnectRequest`) for divers who want
somewhere not yet listed.

## Messaging — the `contact-trusted-partner` edge function

A diver's message is relayed by
[`supabase/functions/contact-trusted-partner/index.ts`](https://github.com/fundive/fundive/blob/main/supabase/functions/contact-trusted-partner/index.ts).
It resolves the partner's email **server-side** with the service-role key (the
client only ever sent a `partner_id`) and sends one email:

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
plain CRUD over `trusted_partners`, **including** the `email` column (admins read
and write it directly under their RLS). Retire a partner by unticking `active`
rather than deleting, so historical intros keep their referent.

## Shop-config touch-points

Nothing about a partner is shop-config — partners are data a shop enters. But the
relay reads two config fields through the edge `_shared/config.ts` seam:
`siteConfig.app.supportEmail` (the CC inbox) and `siteConfig.app.name` (the From
name). Both come from `fundive.config.ts` — see [forking.md](./forking.md).
