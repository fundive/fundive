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
    if (sub === 'deploy') run(bin('supabase'), ['functions', 'deploy'])
    else usage()
    break
  case 'version': case '--version': case '-v': version(); break
  default: usage(); if (command && command !== 'help' && command !== '--help') process.exit(1)
}
