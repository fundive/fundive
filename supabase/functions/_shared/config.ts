import { siteConfig as defaultConfig } from "../../../fundive.config.ts"

// The single seam through which every edge function reads shop config.
//
// A deployment's config is injected at deploy time as the FUNDIVE_CONFIG
// secret (the deployment's resolved fundive.config.ts, serialized to JSON —
// see `fundive functions deploy`). When it's absent — local dev, `functions
// serve` without the secret, and the vitest handler/_shared tests (which run
// under Node where `Deno` is undefined) — we fall back to the platform's own
// fundive.config.ts. The `typeof Deno` guard is load-bearing: it keeps this
// module import-safe outside Deno.
const injected = typeof Deno !== "undefined" ? Deno.env.get("FUNDIVE_CONFIG") : undefined

export const siteConfig: typeof defaultConfig = injected ? JSON.parse(injected) : defaultConfig
