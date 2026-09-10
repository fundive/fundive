// The build-time env gate, kept apart from vite.config.ts so vitest can drive it.
//
// Every `VITE_*` value is inlined into the bundle at build time, so a wrong one
// does not fail the build — it ships an app that only breaks in someone's
// browser. These two checks are what stand between that and a deploy.

/** Values whose absence silently breaks a core flow at runtime, not at build. */
export const REQUIRED_BUILD_ENV: Record<string, string> = {
  VITE_SUPABASE_URL:       'Supabase client cannot initialise — the whole app fails to boot.',
  VITE_SUPABASE_ANON_KEY:  'Supabase client cannot initialise — the whole app fails to boot.',
  VITE_TURNSTILE_SITE_KEY: 'Guest registration captcha cannot render, yet the edge function still requires a token — guest signup dead-ends.',
}

/** Loopback hosts: a Supabase URL on one of these is a developer's own stack. */
const LOOPBACK = /^https?:\/\/(?:127\.0\.0\.1|localhost|0\.0\.0\.0|\[::1\])(?::\d+)?(?:\/|$)/i

/**
 * Cloudflare's published always-pass Turnstile keys. They exist so a captcha
 * renders and clears with no Cloudflare account, which is exactly what local
 * development wants and exactly what a deployment must not have.
 */
const TURNSTILE_TEST_KEYS = new Set([
  '1x00000000000000000000AA', // always passes, visible
  '1x00000000000000000000BB', // always passes, invisible
  '2x00000000000000000000AB', // always blocks
  '3x00000000000000000000FF', // forces an interactive challenge
])

/**
 * Why this env cannot produce a shippable bundle, or an empty list.
 *
 * `.env.example` ships values that work against `make start` out of the box, so
 * the first `npm run build` in a fresh clone succeeds by default. That
 * convenience is only safe because leaving them in place fails here instead of
 * shipping an app that talks to a database on the deployer's laptop.
 */
export function buildEnvProblems(env: Record<string, string | undefined>): string[] {
  const problems: string[] = []

  for (const key of Object.keys(REQUIRED_BUILD_ENV)) {
    if (!env[key]) problems.push(`${key} is not set: ${REQUIRED_BUILD_ENV[key]}`)
  }

  const url = env.VITE_SUPABASE_URL
  if (url && LOOPBACK.test(url)) {
    problems.push(
      `VITE_SUPABASE_URL points at your own machine (${url}). ` +
      'That is the local development value from .env.example — replace it with ' +
      'your Supabase project URL before building for deployment.',
    )
  }

  const siteKey = env.VITE_TURNSTILE_SITE_KEY
  if (siteKey && TURNSTILE_TEST_KEYS.has(siteKey)) {
    problems.push(
      `VITE_TURNSTILE_SITE_KEY is Cloudflare's always-pass test key (${siteKey}), ` +
      'so the captcha would wave through every bot. Replace it with your own ' +
      'Turnstile site key before building for deployment.',
    )
  }

  return problems
}
