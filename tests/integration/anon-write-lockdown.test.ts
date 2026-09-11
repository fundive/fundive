import { describe, it, expect } from 'vitest'
import { anonClient } from './helpers'

// H2 of the 2026-09-11 audit. The squashed baseline carried Supabase's stock
// `ALTER DEFAULT PRIVILEGES ... GRANT ALL ON TABLES TO anon`, so every table
// created since granted the logged-out role INSERT, UPDATE and DELETE. RLS
// refused the writes, so nothing was exploitable — but RLS was carrying the
// whole load alone, and the same default on FUNCTIONS is what made
// normalize_profile_values() callable by the internet (H1).
// 20260911110000 fixes the defaults and revokes the grants already handed out.
//
// These assertions distinguish the two layers by message, which is the point:
//
//   no grant   -> "permission denied for table taxa"
//   grant, RLS -> "new row violates row-level security policy for table \"taxa\""
//
// Before the migration every case below returned the second message. A test
// that only checked `error !== null` would have passed before the fix too, and
// proved nothing.
const RLS_MESSAGE = /violates row-level security policy/i
const GRANT_MESSAGE = /permission denied/i

// One table per category: a catalog table the register form reads while logged
// out, the two tables that hold money, the central identity table, and a table
// created well after the baseline (so it can only have been granted by the
// defaults this migration changes).
//
// Each carries a real column, because PostgREST answers an empty patch without
// ever reaching the database — an UPDATE test with `{}` passes whether or not
// the privilege is there.
const TABLES = [
  { table: 'payment_methods', column: 'label' },
  { table: 'payments', column: 'reference' },
  { table: 'bookings', column: 'notes' },
  { table: 'profiles', column: 'name' },
  { table: 'taxa', column: 'scientific_name' },
] as const

const NO_SUCH_ID = '00000000-0000-0000-0000-000000000000'

describe('anon holds no write privileges', () => {
  it.each(TABLES)(
    'anon INSERT into $table is refused by grant, not merely by RLS',
    async ({ table }) => {
      const { error } = await anonClient()
        .from(table)
        .insert({} as never)

      expect(error).not.toBeNull()
      expect(error!.message).toMatch(GRANT_MESSAGE)
      expect(error!.message).not.toMatch(RLS_MESSAGE)
    },
  )

  it.each(TABLES)('anon UPDATE on $table is refused by grant', async ({ table, column }) => {
    const { error } = await anonClient()
      .from(table)
      .update({ [column]: 'anon was here' } as never)
      .neq('id', NO_SUCH_ID)

    expect(error).not.toBeNull()
    expect(error!.message).toMatch(GRANT_MESSAGE)
    expect(error!.message).not.toMatch(RLS_MESSAGE)
  })

  it.each(TABLES)('anon DELETE on $table is refused by grant', async ({ table }) => {
    const { error } = await anonClient().from(table).delete().neq('id', NO_SUCH_ID)

    expect(error).not.toBeNull()
    expect(error!.message).toMatch(GRANT_MESSAGE)
    expect(error!.message).not.toMatch(RLS_MESSAGE)
  })

  // The revoke took INSERT/UPDATE/DELETE only. SELECT has to survive: the
  // register form renders payment options, terms and waivers before sign-in
  // completes, and their RLS policies are what decide the rows.
  it.each(['payment_methods', 'shop_contact', 'terms', 'waivers', 'prices'] as const)(
    'anon can still read %s',
    async (table) => {
      const { error } = await anonClient().from(table).select('*').limit(1)
      expect(error).toBeNull()
    },
  )
})
