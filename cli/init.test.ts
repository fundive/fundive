import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'

const cli = path.resolve(__dirname, 'index.js')
const platform = path.resolve(__dirname, '..')
let work: string

function fundive(...args: string[]) {
  return execFileSync('node', [cli, ...args], { cwd: work, encoding: 'utf8', stdio: 'pipe' })
}

beforeEach(() => { work = mkdtempSync(path.join(tmpdir(), 'fundive-init-')) })
afterEach(() => { rmSync(work, { recursive: true, force: true }) })

describe('fundive init', () => {
  it('creates a deployment repository from the template, dotfiles restored', () => {
    fundive('init', 'my-shop')
    const shop = path.join(work, 'my-shop')
    for (const f of [
      '.gitignore', '.env.example', '.github/workflows/deploy.yml', '.github/workflows/supabase-push.yml',
      'wrangler.toml', 'workers/push/wrangler.toml', 'README.md', 'public',
    ]) expect(existsSync(path.join(shop, f)), f).toBe(true)
    for (const f of ['gitignore', 'env.example', 'github']) expect(existsSync(path.join(shop, f)), f).toBe(false)
  })

  it('starts the config from the platform example, not a second copy of it', () => {
    fundive('init', 'my-shop')
    expect(readFileSync(path.join(work, 'my-shop', 'fundive.config.ts'), 'utf8'))
      .toBe(readFileSync(path.join(platform, 'fundive.config.example.ts'), 'utf8'))
  })

  it('names the package after the directory and pins the platform to this commit', () => {
    fundive('init', 'my-shop')
    const pkg = JSON.parse(readFileSync(path.join(work, 'my-shop', 'package.json'), 'utf8'))
    const head = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: platform, encoding: 'utf8' }).trim()
    expect(pkg.name).toBe('my-shop')
    expect(pkg.dependencies.fundive).toBe(`github:fundive/fundive#${head}`)
  })

  it('refuses a directory that already has files in it', () => {
    mkdirSync(path.join(work, 'taken'))
    writeFileSync(path.join(work, 'taken', 'keep.txt'), 'mine')
    expect(() => fundive('init', 'taken')).toThrow(/not empty/)
    expect(readFileSync(path.join(work, 'taken', 'keep.txt'), 'utf8')).toBe('mine')
  })
})
