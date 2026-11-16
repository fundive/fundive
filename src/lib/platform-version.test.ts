import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { FUNDIVE_VERSION, RELEASE_NOTES_URL } from './platform-version'

const pkg = JSON.parse(readFileSync(path.resolve(__dirname, '../../package.json'), 'utf8')) as { version: string }

describe('platform version', () => {
  it('is the version in package.json, so a release cannot ship naming an older one', () => {
    expect(FUNDIVE_VERSION).toBe(`v${pkg.version}`)
  })

  it('links to that release on GitHub', () => {
    expect(RELEASE_NOTES_URL).toBe(`https://github.com/fundive/fundive/releases/tag/v${pkg.version}`)
  })
})
