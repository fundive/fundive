.PHONY: help dev studio mail start stop status reset diff link pull push dump-data backup-prod verify test test-only security lint lint-fix typecheck deploy deploy-app deploy-push deploy-functions

# The local Supabase stack names its Docker containers supabase_<svc>_<project_id>,
# so derive the prefix from config.toml — a fork only changes project_id there.
PROJECT_ID := $(shell sed -n 's/^project_id = "\(.*\)"/\1/p' supabase/config.toml)

help:
	@echo "Local dev:"
	@echo "  make dev         — start Vite against the local supabase stack"
	@echo "  make studio      — open Supabase Studio (DB browser) in your browser"
	@echo "  make mail        — open Inbucket (local email inbox) in your browser"
	@echo ""
	@echo "Supabase stack:"
	@echo "  make start       — boot local stack"
	@echo "  make stop        — tear down local stack"
	@echo "  make status      — print local URLs + keys"
	@echo "  make reset       — wipe local db and reapply migrations + seed.sql"
	@echo "  make diff        — show schema drift between local db and migrations"
	@echo "  make link        — link repo to cloud project"
	@echo "  make pull        — pull cloud schema into a new migration"
	@echo "  make push        — push local migrations to cloud"
	@echo "  make dump-data   — dump cloud data into supabase/seed.sql"
	@echo "  make backup-prod — snapshot the linked PROD db (schema+data+roles) to backups/ — run on a networked machine, before a risky migration"
	@echo "  make verify      — check local is in sync with cloud (schema + row counts)"
	@echo ""
	@echo "Testing:"
	@echo "  make test        — the gate: typecheck + lint + every local test (unit + component + integration + security)"
	@echo "  make test-only   — just the test run, skipping typecheck and lint"
	@echo "  make security    — run only the black-box attacker probes in tests/security/"
	@echo "  make lint        — run eslint over the SPA + tests"
	@echo "  make lint-fix    — run eslint with --fix to auto-correct what it can"
	@echo "  make typecheck   — run tsc --noEmit (no build, just type validation)"
	@echo ""
	@echo "Deploy:"
	@echo "  make deploy            — deploy both workers (SPA + push cron) + edge functions"
	@echo "  make deploy-app        — deploy just the SPA (fundive-app)"
	@echo "  make deploy-push       — deploy just the push cron (fundivers-push)"
	@echo "  make deploy-functions  — deploy all supabase edge functions in supabase/functions/"

start:      ; @npm run db:start
stop:       ; @npm run db:stop
status:     ; @npm run db:status
reset:
	@# The CLI's post-reset "Restarting containers..." step often returns 502
	@# while migrations + seeds did apply cleanly — Kong/PostgREST are still
	@# pointing at the pre-reset DB. Restart them unconditionally so the
	@# stack is usable on the next command, then propagate the CLI's exit
	@# code so genuine migration failures still surface.
	@npm run db:reset; status=$$?; \
	  docker restart supabase_rest_$(PROJECT_ID) supabase_kong_$(PROJECT_ID) >/dev/null 2>&1 || true; \
	  exit $$status
diff:       ; @npm run db:diff
link:       ; @npm run db:link
pull:       ; @npm run db:pull
push:       ; @npm run db:push
dump-data:  ; @npm run db:dump-data
backup-prod: ; @npm run db:backup-prod
verify:     ; @bash scripts/verify-sync.sh
test:       typecheck lint test-only
test-only:  ; @npm run test:all
security:   ; @npx vitest run --project security
lint:       ; @npm run lint
lint-fix:   ; @npm run lint:fix
typecheck:  ; @npx tsc -b

# Cloudflare Worker deploys read their creds (CLOUDFLARE_API_TOKEN,
# CLOUDFLARE_ACCOUNT_ID) and the VITE_* build vars from .env.local, so a deploy
# is non-interactive and reproducible — no `wrangler login`, no GitHub Actions
# secrets needed. REQUIRE_CF fails fast with a clear message when those creds are
# missing; it sources .env.local in its own sub-shell so nothing leaks into the
# vite build (which loads .env.local itself).
REQUIRE_CF = if [ ! -f .env.local ]; then echo "ERROR: .env.local not found — see docs/deployment.md"; exit 1; fi; \
	set -a; . ./.env.local; set +a; \
	if [ -z "$$CLOUDFLARE_API_TOKEN" ] || [ -z "$$CLOUDFLARE_ACCOUNT_ID" ]; then \
	  echo "ERROR: set CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID in .env.local"; \
	  echo "  Token (Edit Cloudflare Workers template): https://dash.cloudflare.com/profile/api-tokens"; \
	  exit 1; \
	fi

deploy: deploy-app deploy-push deploy-functions

deploy-app:
	@$(REQUIRE_CF)
	@npm run build
	@set -a; . ./.env.local; set +a; npx wrangler deploy

deploy-push:
	@$(REQUIRE_CF)
	@if [ ! -d workers/push/node_modules ]; then \
	  echo "Installing workers/push deps…"; \
	  (cd workers/push && npm install); \
	fi
	@set -a; . ./.env.local; set +a; cd workers/push && npx wrangler deploy

deploy-functions: ; @npm run functions:deploy

dev:
	@if ! docker ps --format '{{.Names}}' | grep -q supabase_db_$(PROJECT_ID); then \
	  echo "Local supabase stack not running — starting it first…"; \
	  npm run db:start; \
	fi
	@npm run dev

studio: ; @command -v xdg-open >/dev/null && xdg-open http://127.0.0.1:64323 || echo "Open http://127.0.0.1:64323"
mail:   ; @command -v xdg-open >/dev/null && xdg-open http://127.0.0.1:64324 || echo "Open http://127.0.0.1:64324"
