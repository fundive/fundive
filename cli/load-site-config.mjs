import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildSync } from 'esbuild'

// Load a deployment's fundive.config.ts into a plain object from the JS CLI —
// the runtime twin of src/vite `loadSiteConfig`. Bundles (not just transpiles)
// so a config authored as `import { defineConfig } from 'fundive/config'`
// resolves, aliasing that specifier to the platform's runtime-empty define
// entry. Used by `fundive functions deploy` to serialize the config into the
// FUNDIVE_CONFIG edge secret.

const platformDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const defineEntry = path.join(platformDir, 'src', 'config', 'define.ts')

export function loadSiteConfig(cwd = process.cwd()) {
  const file = path.resolve(cwd, 'fundive.config.ts')
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
  const mod = { exports: {} }
  new Function('module', 'exports', code)(mod, mod.exports)
  const siteConfig = mod.exports.siteConfig ?? mod.exports.default
  if (!siteConfig || typeof siteConfig !== 'object') {
    throw new Error(`fundive: ${file} did not export a siteConfig object`)
  }
  return siteConfig
}
