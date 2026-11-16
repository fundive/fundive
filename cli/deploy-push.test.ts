import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'

// The push worker imports the platform's i18n, which reads the shop config
// through `virtual:fundive-config`. Before `fundive deploy push` mapped that
// alias, the worker could not be bundled at all, and the first real deploy was
// where anyone found out. This builds it from a freshly initialized shop
// without deploying anything (wrangler --dry-run).
const cli = path.resolve(__dirname, 'index.js')
const platform = path.resolve(__dirname, '..')
let work: string
let shop: string

beforeAll(() => {
  work = mkdtempSync(path.join(tmpdir(), 'fundive-push-'))
  execFileSync('node', [cli, 'init', 'shop'], { cwd: work, stdio: 'pipe' })
  shop = path.join(work, 'shop')
  mkdirSync(path.join(shop, 'node_modules'))
  symlinkSync(platform, path.join(shop, 'node_modules', 'fundive'), 'dir')
  const config = path.join(shop, 'fundive.config.ts')
  writeFileSync(config, readFileSync(config, 'utf8').replace("shopName: 'Your Dive Shop'", "shopName: 'Push Test Divers'"))
})

afterAll(() => { rmSync(work, { recursive: true, force: true }) })

describe('fundive deploy push', () => {
  it('bundles the push worker with the deployment\'s own config', () => {
    const out = path.join(work, 'out')
    execFileSync('node', [cli, 'deploy', 'push', '--dry-run', '--outdir', out], {
      cwd: shop, stdio: 'pipe', env: { ...process.env, WRANGLER_SEND_METRICS: 'false' },
    })
    const bundle = readFileSync(path.join(out, 'index.js'), 'utf8')
    expect(bundle).toContain('Push Test Divers')
  }, 120_000)

  it('leaves no generated config behind', () => {
    expect(existsSync(path.join(shop, 'node_modules', '.cache', 'fundive', 'push-wrangler.toml'))).toBe(false)
  })
})
