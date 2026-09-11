import { describe, it, expect } from 'vitest'
import { adminClient, anonClient } from './helpers'

// Migration 20260720070000 revokes anon/authenticated EXECUTE on two
// SECURITY DEFINER (RLS-bypassing) writer RPCs that were anon-callable in the
// baseline. They are meant to run only from a DB trigger (internal) or the
// service-role push worker. A random event UUID is safe to pass: with no
// matching waitlisted booking / event row, both no-op instead of writing.
const RANDOM_EVENT_ID = '00000000-0000-0000-0000-000000000000'

describe('anon-granted SECURITY DEFINER RPC lockdown', () => {
  it('offer_next_waitlist_spot is not callable by an unauthenticated client', async () => {
    const { error } = await anonClient().rpc('offer_next_waitlist_spot', {
      p_event_id: RANDOM_EVENT_ID,
    })
    expect(error).not.toBeNull()
  })

  it('refresh_event_display_title is not callable by an unauthenticated client', async () => {
    const { error } = await anonClient().rpc('refresh_event_display_title', {
      p_event_id: RANDOM_EVENT_ID,
    })
    expect(error).not.toBeNull()
  })

  it('both remain callable by the service role', async () => {
    const offer = await adminClient().rpc('offer_next_waitlist_spot', {
      p_event_id: RANDOM_EVENT_ID,
    })
    expect(offer.error).toBeNull()

    const refresh = await adminClient().rpc('refresh_event_display_title', {
      p_event_id: RANDOM_EVENT_ID,
    })
    expect(refresh.error).toBeNull()
  })

  // H1 of the 2026-09-11 audit. normalize_profile_values() is SECURITY DEFINER,
  // owned by postgres, and has no authorization check of its own: it rewrites
  // cert_level and nationality across every row of `profiles` and brackets that
  // in `alter table ... disable trigger`, which locks the table against writes.
  // 20260910100000 revoked it from `public, authenticated` but not from `anon`,
  // and this repo's baseline had handed `anon` an explicit grant that a revoke
  // aimed at PUBLIC does not touch. Before 20260911100000 this call returned
  // 200 and rewrote the table.
  it('normalize_profile_values is not callable by an unauthenticated client', async () => {
    const { error } = await anonClient().rpc('normalize_profile_values')
    expect(error).not.toBeNull()
    expect(error!.message).toMatch(/permission denied/i)
  })

  it('normalize_profile_values remains callable by the service role', async () => {
    const { error } = await adminClient().rpc('normalize_profile_values')
    expect(error).toBeNull()
  })
})
