import { describe, it, expect } from 'vitest'
import { buildEnvProblems, REQUIRED_BUILD_ENV } from './build-env'

// `.env.example` ships working local values so a fresh clone runs with no
// setup. That is only safe because leaving them in place fails the production
// build — otherwise `make deploy` would cheerfully ship a bundle pointing at
// the deployer's own laptop, with a captcha that passes every bot.

const DEPLOYABLE = {
  VITE_SUPABASE_URL: 'https://abcdefghij.supabase.co',
  VITE_SUPABASE_ANON_KEY: 'eyJhbGciOiJIUzI1NiJ9.real.key',
  VITE_TURNSTILE_SITE_KEY: '0x4AAAAAAABkMYinukE8nzY',
}

describe('buildEnvProblems', () => {
  it('passes a fully configured deployment', () => {
    expect(buildEnvProblems(DEPLOYABLE)).toEqual([])
  })

  it('names every missing required var, with what it breaks', () => {
    const problems = buildEnvProblems({})
    expect(problems).toHaveLength(Object.keys(REQUIRED_BUILD_ENV).length)
    for (const key of Object.keys(REQUIRED_BUILD_ENV)) {
      expect(problems.some(p => p.startsWith(`${key} is not set`))).toBe(true)
    }
  })

  it('treats an empty string as unset', () => {
    expect(buildEnvProblems({ ...DEPLOYABLE, VITE_SUPABASE_ANON_KEY: '' }))
      .toEqual([expect.stringContaining('VITE_SUPABASE_ANON_KEY is not set')])
  })

  it.each([
    'http://127.0.0.1:64421',
    'http://localhost:64421',
    'http://0.0.0.0:64421',
    'https://127.0.0.1:64421/',
  ])('refuses to build against the local stack (%s)', url => {
    expect(buildEnvProblems({ ...DEPLOYABLE, VITE_SUPABASE_URL: url }))
      .toEqual([expect.stringContaining('points at your own machine')])
  })

  it('does not mistake a real host that merely mentions localhost', () => {
    expect(buildEnvProblems({ ...DEPLOYABLE, VITE_SUPABASE_URL: 'https://localhost.example.com' }))
      .toEqual([])
  })

  it.each([
    '1x00000000000000000000AA',
    '1x00000000000000000000BB',
    '2x00000000000000000000AB',
    '3x00000000000000000000FF',
  ])('refuses to ship Cloudflare\'s always-pass test key (%s)', key => {
    expect(buildEnvProblems({ ...DEPLOYABLE, VITE_TURNSTILE_SITE_KEY: key }))
      .toEqual([expect.stringContaining('always-pass test key')])
  })

  // The whole point of the local defaults: they work for development and stop
  // at the deployment boundary rather than sailing through it.
  it('rejects .env.example as shipped, on both counts', () => {
    const problems = buildEnvProblems({
      VITE_SUPABASE_URL: 'http://127.0.0.1:64421',
      VITE_SUPABASE_ANON_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.local.demo',
      VITE_TURNSTILE_SITE_KEY: '1x00000000000000000000AA',
    })
    expect(problems).toHaveLength(2)
  })
})
