#!/usr/bin/env node
// The `fundive` CLI — the interface a deployment drives the platform through.
// It shells out to the platform's own vite / wrangler / supabase, run from the
// deployment's cwd so the deployment's fundive.config.ts + .env are picked up
// (the vite config resolves `virtual:fundive-config` from process.cwd()).
//
// The deployment owns its infrastructure names: a wrangler.toml (SPA worker)
// and workers/push/wrangler.toml (push cron) in its own repo replace the
// platform's when present. See docs/deployment-repo.md.

import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { existsSync, mkdirSync, readFileSync, statSync } from 'node:fs'
import path from 'node:path'

const platformDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const deploymentDir = process.cwd()
const viteConfig = path.join(platformDir, 'vite.config.ts')

// The deployment's .env.local then .env, as plain KEY=value pairs. Anything
// already in the process environment wins, so CI secrets override the file.
function deploymentEnv() {
  const out = {}
  for (const f of ['.env', '.env.local']) {
    let text
    try { text = readFileSync(path.join(deploymentDir, f), 'utf8') } catch { continue }
    for (const line of text.split('\n')) {
      const m = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/)
      if (m) out[m[1]] = m[2].replace(/^(["'])(.*)\1$/, '$2')
    }
  }
  return { ...out, ...process.env }
}

const env = deploymentEnv()

// The deployment's own config file if it has one, else the platform's.
function ownOrPlatform(relative) {
  const own = path.join(deploymentDir, relative)
  return existsSync(own) ? own : path.join(platformDir, relative)
}

// Connection string for the deployment's database: SUPABASE_DB_URL, or one
// built from the pooler host, project ref and password the deployment's .env
// already holds for the Supabase CLI.
function dbUrl() {
  if (env.SUPABASE_DB_URL) return env.SUPABASE_DB_URL
  const { SUPABASE_POOLER_HOST: host, SUPABASE_PROJECT_REF: ref, SUPABASE_DB_PASSWORD: pw } = env
  if (!host || !ref || !pw) {
    console.error('fundive: set SUPABASE_DB_URL, or SUPABASE_POOLER_HOST + SUPABASE_PROJECT_REF + SUPABASE_DB_PASSWORD, in .env')
    process.exit(1)
  }
  return `postgresql://postgres.${ref}:${encodeURIComponent(pw)}@${host}:5432/postgres`
}

// Prefer the platform's own installed binaries; fall back to PATH.
function bin(name) {
  const local = path.join(platformDir, 'node_modules', '.bin', name)
  return existsSync(local) ? local : name
}

function run(cmd, args) {
  const child = spawn(cmd, args, { stdio: 'inherit', cwd: deploymentDir, env })
  child.on('error', (e) => { console.error(`fundive: ${e.message}`); process.exit(1) })
  child.on('exit', (code) => process.exit(code ?? 1))
}

// Like run(), but resolves so callers can sequence steps (a nonzero exit still
// aborts the whole command).
function runStep(cmd, args) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { stdio: 'inherit', cwd: deploymentDir, env })
    child.on('error', (e) => { console.error(`fundive: ${e.message}`); process.exit(1) })
    child.on('exit', (code) => { if (code) process.exit(code); resolve() })
  })
}

// The target Supabase project ref: an explicit env var wins, else the
// deployment's .env(.local). Undefined falls through to the linked project.
function projectRef() {
  return env.SUPABASE_PROJECT_REF
}

// The SPA worker. A deployment's own wrangler.toml names the worker and its
// domain and points `main` at node_modules/fundive/src/worker.ts; without one,
// the platform's is used with the deployment's built dist/.
function deployApp() {
  const own = path.join(deploymentDir, 'wrangler.toml')
  if (existsSync(own)) run(bin('wrangler'), ['deploy', '--config', own])
  else run(bin('wrangler'), ['deploy', '--config', path.join(platformDir, 'wrangler.toml'), '--assets', path.join(deploymentDir, 'dist')])
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

// A logical backup of the deployment's database: roles, schema and data as
// three files under backups/, the rollback point to take before `db push` or
// `db adopt --apply`. The Supabase CLI can exit non-zero from its telemetry
// shutdown after writing a complete file, so success is judged by the file.
async function backupDb() {
  const url = dbUrl()
  const stamp = new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19)
  const dir = path.join(deploymentDir, 'backups')
  mkdirSync(dir, { recursive: true })
  for (const [label, flags] of [['roles', ['--role-only']], ['schema', []], ['data', ['--data-only']]]) {
    const out = path.join(dir, `db_${label}_${stamp}.sql`)
    console.log(`-> ${label}  ->  ${path.relative(deploymentDir, out)}`)
    await new Promise((resolve) => {
      const child = spawn(bin('supabase'), ['db', 'dump', '--db-url', url, ...flags, '-f', out],
        { stdio: 'inherit', cwd: deploymentDir, env: { ...env, DO_NOT_TRACK: '1' } })
      child.on('error', (e) => { console.error(`fundive: ${e.message}`); process.exit(1) })
      child.on('exit', resolve)
    })
    if (!existsSync(out) || statSync(out).size === 0) {
      console.error(`fundive: the ${label} dump wrote nothing`)
      process.exit(1)
    }
  }
  console.log('Restore order if ever needed: roles -> schema -> data')
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
  deploy push         deploy the push-notification cron worker
  db backup           dump your database's roles, schema and data into backups/
  db push             apply the platform migrations to your Supabase
  db adopt ...        adopt a database built from another repo (see
                      scripts/adopt-existing-deployment.sh; dry run by default)
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
  case 'deploy':
    if (sub === 'push') run(bin('wrangler'), ['deploy', '--config', ownOrPlatform('workers/push/wrangler.toml')])
    else if (!sub) deployApp()
    else usage()
    break
  case 'db':
    if (sub === 'push') run(bin('supabase'), ['db', 'push', '--workdir', platformDir, '--db-url', dbUrl()])
    else if (sub === 'backup') backupDb().catch(e => { console.error(`fundive: ${e.message}`); process.exit(1) })
    else if (sub === 'adopt') {
      env.ADOPT_DB_URL = dbUrl()
      env.FUNDIVE_CLI = '1'
      run('bash', [path.join(platformDir, 'scripts', 'adopt-existing-deployment.sh'), ...process.argv.slice(4)])
    }
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
