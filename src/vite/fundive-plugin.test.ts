import { describe, it, expect } from 'vitest'
import { fundive, configPathFor, loadSiteConfig } from './index'
import type { SiteConfig } from '../config/site'

// The plugin has two modes and the difference matters. With no overlay it
// resolves `virtual:fundive-config` to the shop's own config file, exactly as
// it always has — a build that changes nothing must not change how the config
// reaches the bundle. With one, it serves the merged object instead, because
// the values the build changed are not in that file.

const VIRTUAL = 'virtual:fundive-config'

/** Plugin hooks are declared as object properties or hook objects; call either. */
function callHook(plugin: ReturnType<typeof fundive>, name: 'resolveId' | 'load', id: string) {
  const hook = plugin[name] as unknown as ((this: unknown, id: string) => unknown)
  return hook.call({}, id)
}

describe('fundive() with no overlay', () => {
  const plugin = fundive()

  it('resolves the virtual module to the deployment’s own config file', () => {
    expect(callHook(plugin, 'resolveId', VIRTUAL)).toBe(configPathFor())
  })

  it('serves nothing itself, leaving the file to be loaded as a module', () => {
    expect(callHook(plugin, 'load', configPathFor())).toBeUndefined()
  })

  it('leaves an unrelated id alone', () => {
    expect(callHook(plugin, 'resolveId', 'react')).toBeUndefined()
  })
})

describe('fundive() with an overlay', () => {
  const overlaid = {
    ...loadSiteConfig(),
    locale: { ...loadSiteConfig().locale, currency: 'JPY', language: 'ja' },
  } as SiteConfig
  const plugin = fundive(overlaid)
  const resolved = callHook(plugin, 'resolveId', VIRTUAL) as string

  it('resolves the virtual module to itself rather than to the file', () => {
    expect(resolved).not.toBe(configPathFor())
    expect(resolved.startsWith('\0')).toBe(true)
  })

  it('serves the merged config, so the bundle carries what the shop chose', () => {
    const code = callHook(plugin, 'load', resolved) as string
    expect(code).toContain('export const siteConfig =')
    // Parse it rather than string-matching: what matters is the value the app
    // ends up importing, not how it was spelled.
    const json = code.slice(code.indexOf('{'), code.lastIndexOf('}') + 1)
    const served = JSON.parse(json) as SiteConfig
    expect(served.locale.currency).toBe('JPY')
    expect(served.locale.language).toBe('ja')
    // Everything else survives the round trip.
    expect(served.identity.shopName).toBe(overlaid.identity.shopName)
    expect(served.assets.logo).toBe(overlaid.assets.logo)
  })
})
