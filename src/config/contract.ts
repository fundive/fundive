// The config-contract version. Kept in its own dependency-free module so build
// tooling (vite.config, the fundive plugin, the zod schema) can read it WITHOUT
// pulling in `site.ts` — which imports `virtual:fundive-config`, a specifier
// that only resolves inside the Vite module graph, not at config-load time.
//
// Bump when the SiteConfig contract changes in a way that requires a deployment
// to migrate its fundive.config.ts. The build compares this against
// siteConfig.configVersion and fails loudly on a mismatch.
export const CONFIG_CONTRACT_VERSION = 2
