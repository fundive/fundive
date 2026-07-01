#!/usr/bin/env node
// The `fundive` CLI — the interface a deployment drives the platform through.
// It shells out to the platform's own vite / wrangler / supabase, run from the
// deployment's cwd so the deployment's fundive.config.ts + .env are picked up
// (the vite config resolves `virtual:fundive-config` from process.cwd()).
//
// Skeleton: the command surface is here and works from the platform repo; full
// consumer-root resolution (serving the platform's index.html/src while reading
// the consumer's public/brand) is a follow-up. See docs/architecture.md.

import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'

const platformDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const viteConfig = path.join(platformDir, 'vite.config.ts')
const wranglerConfig = path.join(platformDir, 'wrangler.toml')

// Prefer the platform's own installed binaries; fall back to PATH.
function bin(name) {
  const local = path.join(platformDir, 'node_modules', '.bin', name)
  return existsSync(local) ? local : name
}

function run(cmd, args) {
  const child = spawn(cmd, args, { stdio: 'inherit', cwd: process.cwd(), env: process.env })
  child.on('error', (e) => { console.error(`fundive: ${e.message}`); process.exit(1) })
  child.on('exit', (code) => process.exit(code ?? 1))
}

// Like run(), but resolves so callers can sequence steps (a nonzero exit still
// aborts the whole command).
function runStep(cmd, args) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { stdio: 'inherit', cwd: process.cwd(), env: process.env })
    child.on('error', (e) => { console.error(`fundive: ${e.message}`); process.exit(1) })
    child.on('exit', (code) => { if (code) process.exit(code); resolve() })
  })
}

// The target Supabase project ref: an explicit env var wins, else the
// deployment's .env(.local). Undefined falls through to the linked project.
function projectRef() {
  if (process.env.SUPABASE_PROJECT_REF) return process.env.SUPABASE_PROJECT_REF
  for (const f of ['.env.local', '.env']) {
    try {
      const m = readFileSync(path.join(process.cwd(), f), 'utf8')
        .match(/^\s*SUPABASE_PROJECT_REF\s*=\s*(.+?)\s*$/m)
      if (m) return m[1].replace(/^["']|["']$/g, '')
    } catch { /* no such file */ }
  }
  return undefined
}

// Deploy the platform's edge functions to the deployment's project, injecting
// the deployment's config as the FUNDIVE_CONFIG secret (read by the
// _shared/config.ts seam). --workdir points Supabase at the platform's
// supabase/ dir so a thin deployment (no supabase/functions of its own) can
// ship them.
async function deployFunctions() {
  const { loadSiteConfig } = await import('./load-site-config.mjs')
  const ref = projectRef()
  const refArgs = ref ? ['--project-ref', ref] : []
  const configJson = JSON.stringify(loadSiteConfig())
  await runStep(bin('supabase'), ['secrets', 'set', `FUNDIVE_CONFIG=${configJson}`, ...refArgs])
  await runStep(bin('supabase'), ['functions', 'deploy', '--workdir', platformDir, ...refArgs])
  process.exit(0)
}

function version() {
  const pkg = JSON.parse(readFileSync(path.join(platformDir, 'package.json'), 'utf8'))
  console.log(`fundive ${pkg.version}`)
}

function usage() {
  console.log(`fundive — self-hostable dive-center platform

Usage: fundive <command>

  dev                 start the dev server (local Supabase stack)
  build               production build with your branding baked in
  preview             preview the production build locally
  deploy              deploy the SPA worker to your Cloudflare
  db push             apply the platform migrations to your Supabase
  db verify           confirm your DB schema matches the pinned version
  functions deploy    deploy the Supabase edge functions
  version             print the platform version

Run from a deployment repo; your fundive.config.ts and .env are used.`)
}

const [command, sub] = process.argv.slice(2)

switch (command) {
  case 'dev':     run(bin('vite'), ['--config', viteConfig]); break
  case 'build':   run(bin('vite'), ['build', '--config', viteConfig]); break
  case 'preview': run(bin('vite'), ['preview', '--config', viteConfig]); break
  case 'deploy':  run(bin('wrangler'), ['deploy', '--config', wranglerConfig]); break
  case 'db':
    if (sub === 'push') run(bin('supabase'), ['db', 'push'])
    else if (sub === 'verify') run('bash', [path.join(platformDir, 'scripts', 'verify-sync.sh')])
    else usage()
    break
  case 'functions':
    if (sub === 'deploy') deployFunctions().catch(e => { console.error(`fundive: ${e.message}`); process.exit(1) })
    else usage()
    break
  case 'version': case '--version': case '-v': version(); break
  default: usage(); if (command && command !== 'help' && command !== '--help') process.exit(1)
}
