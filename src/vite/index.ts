import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildSync } from 'esbuild'
import type { Plugin } from 'vite'
import { assertValidSiteConfig } from '../config/site.schema'
import type { SiteConfig } from '../config/site'

// The `fundive/config` entry (defineConfig + types), so a deployment's config
// can `import { defineConfig } from 'fundive/config'` and still be loaded here.
const defineEntry = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../config/define.ts')

// The FunDive platform is consumed as a dependency: the app code imports its
// config from the virtual module `virtual:fundive-config`, which this plugin
// resolves to the *deployment's* fundive.config.ts (in the cwd where the build
// runs). That's how one platform build produces each operator's own bundle.

const VIRTUAL_ID = 'virtual:fundive-config'

/** Absolute path to the consuming deployment's config (its cwd). */
export function configPathFor(cwd = process.cwd()): string {
  return path.resolve(cwd, 'fundive.config.ts')
}

/**
 * Load + validate the deployment's config at config/build time. Read directly
 * (not through the Vite graph) because vite.config needs the values before the
 * graph exists — for the PWA manifest, index.html, and the env gate. The config
 * file is pure data (no imports), so a single esbuild transform + eval suffices.
 */
export function loadSiteConfig(cwd = process.cwd()): SiteConfig {
  const file = configPathFor(cwd)
  // Bundle (not just transpile) so a config that `import { defineConfig } from
  // 'fundive/config'` resolves — aliased to the platform's define entry, whose
  // runtime is just the identity helper (no virtual:fundive-config).
  const result = buildSync({
    entryPoints: [file],
    bundle: true,
    format: 'cjs',
    platform: 'node',
    write: false,
    logLevel: 'silent',
    alias: { 'fundive/config': defineEntry },
  })
  const code = result.outputFiles[0].text
  const mod: { exports: Record<string, unknown> } = { exports: {} }
  new Function('module', 'exports', code)(mod, mod.exports)
  const siteConfig = (mod.exports.siteConfig ?? mod.exports.default) as SiteConfig
  assertValidSiteConfig(siteConfig)
  return siteConfig
}

/**
 * The FunDive Vite plugin: resolves `virtual:fundive-config` to the deployment's
 * config and bakes config values into index.html at build. Add it to the
 * platform's vite.config plugins.
 */
export function fundive(): Plugin {
  const file = configPathFor()
  const siteConfig = loadSiteConfig()
  return {
    name: 'fundive:config',
    enforce: 'pre',
    resolveId(id) {
      if (id === VIRTUAL_ID) return file
    },
    transformIndexHtml(html) {
      const replacements: Record<string, string> = {
        '%APP_TITLE%': siteConfig.app.name,
        '%APP_DESCRIPTION%': siteConfig.app.description,
        '%THEME_COLOR%': siteConfig.theme.themeColor,
        '%FAVICON%': siteConfig.assets.favicon,
      }
      return Object.entries(replacements).reduce(
        (out, [token, value]) => out.replaceAll(token, value),
        html,
      )
    },
  }
}
