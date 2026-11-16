import { describe, it, expect } from 'vitest'
import { readdirSync, readFileSync, statSync } from 'node:fs'
import path from 'node:path'

// Edge functions must read shop config through _shared/config.ts, which applies
// the deployment's FUNDIVE_CONFIG secret. A function importing fundive.config.ts
// directly reads the platform's placeholder config instead, so a deployment's
// emails go out signed "Your Dive Shop" and priced in USD. Nothing else fails.
const functionsDir = path.resolve(__dirname, '..')
const seam = path.join(functionsDir, '_shared', 'config.ts')

function sources(dir: string): string[] {
  return readdirSync(dir).flatMap(name => {
    const full = path.join(dir, name)
    if (statSync(full).isDirectory()) return sources(full)
    return /\.tsx?$/.test(name) && !/\.test\.tsx?$/.test(name) ? [full] : []
  })
}

describe('edge function config seam', () => {
  it('only _shared/config.ts imports fundive.config.ts', () => {
    const offenders = sources(functionsDir)
      .filter(f => f !== seam)
      .filter(f => /from\s+["'][^"']*fundive\.config(\.ts)?["']/.test(readFileSync(f, 'utf8')))
      .map(f => path.relative(functionsDir, f))
    expect(offenders).toEqual([])
  })
})
