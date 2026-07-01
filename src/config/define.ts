// Public config entry for deployments — exported as `fundive/config`.
//
// A deployment authors its fundive.config.ts as:
//   import { defineConfig } from 'fundive/config'
//   export const siteConfig = defineConfig({ … })
//
// This module is deliberately runtime-empty except `defineConfig` (an identity
// helper): the type imports below are erased, so bundling a deployment's config
// never pulls in `site.ts` and its `virtual:fundive-config` import.
import type { SiteConfig } from './site'

export type { SiteConfig } from './site'

/** Identity helper: full type-checking + autocomplete when authoring a config. */
export function defineConfig(config: SiteConfig): SiteConfig {
  return config
}
