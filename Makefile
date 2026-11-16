# The Supabase CLI ships PostHog telemetry, and its shutdown flush can time out
# and take the CLI's EXIT CODE with it — so a command that had done its job
# still failed with "Timeout while shutting down PostHog" followed by make
# Error 1. DO_NOT_TRACK is the cross-tool convention
# (consoledonottrack.com) the CLI honours: no telemetry, no flush, no spurious
# failure. Set here rather than via `supabase telemetry disable` so it travels
# with the repo — every fork and CI run gets it, with no per-machine setup.
export DO_NOT_TRACK := 1

.PHONY: help dev studio mail start stop status reset diff test test-only security scenario preflight check-edge lint lint-fix typecheck

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
	@echo ""
	@echo "Testing:"
	@echo "  make preflight   — run before pushing a commit: everything below, incl. the suites CI cannot (they need Docker)"
	@echo "  make test        — the gate: typecheck + lint + deno check + every local test"
	@echo "  make test-only   — just the test run, skipping typecheck and lint"
	@echo "  make scenario    — only the multi-step feature journeys in tests/scenario/"
	@echo "  make security    — run only the black-box attacker probes in tests/security/"
	@echo "  make check-edge  — deno check over supabase/functions/ (tsc -b cannot read them)"
	@echo "  make lint        — run eslint over the SPA + tests"
	@echo "  make lint-fix    — run eslint with --fix to auto-correct what it can"
	@echo "  make typecheck   — run tsc --noEmit (no build, just type validation)"
	@echo ""
	@echo "Shops deploy from their own deployment repo with npx fundive: docs/deployment.md"

# Guard for anything that reads or writes the LOCAL database.
#
# fundive and app-fundivers run their local Supabase stacks on the SAME ports, so
# only one can be up at a time. A CLI command run from this repo while the other
# stack is the live one connects happily to the WRONG database: `supabase
# migration list --local` then reports the other repo's migrations as "remote",
# which reads exactly like production drift, and the integration suite would
# assert against the other repo's schema. Both have happened.
#
# The container name is project-scoped (supabase_db_<project_id>), so its
# presence is the one unambiguous check.
LOCAL_DB_CONTAINER = supabase_db_fundive
REQUIRE_LOCAL = \
	if ! docker ps --format '{{.Names}}' | grep -qx "$(LOCAL_DB_CONTAINER)"; then \
	  echo "ERROR: this repo's local stack is not running ($(LOCAL_DB_CONTAINER))."; \
	  echo "       Another project's stack may hold the ports — check: docker ps --format '{{.Names}}'"; \
	  echo "       Start this one with: make start"; \
	  exit 1; \
	fi

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
test:       typecheck lint check-edge test-only
test-only:
	@$(REQUIRE_LOCAL)
	@npm run test:all
security:
	@$(REQUIRE_LOCAL)
	@npx vitest run --project security
# Just the multi-step journeys, for when you want to know whether a whole
# feature still works rather than which rule broke.
scenario:
	@$(REQUIRE_LOCAL)
	@npx vitest run --project scenario

# Run this before pushing a commit.
#
# `make test` already covers every vitest project, including the three that need
# the local Supabase stack (integration, scenario, security) and which CI
# therefore cannot run. This target exists to name that moment: the gate a push
# is meant to clear.
preflight: test
	@echo ""
	@echo "preflight: tsc + eslint + deno check + unit + integration + scenario + security — all green."
	@echo "           Safe to push."

lint:       ; @npm run lint
lint-fix:   ; @npm run lint:fix
typecheck:  ; @npx tsc -b
# tsc -b cannot read supabase/functions/ (jsr:/npm:/https: specifiers), so a
# broken import there only shows up as a 503 on boot after deploy. Deno's own
# checker is the only thing that reads those files the way the runtime does.
check-edge: ; @bash scripts/check-edge.sh


dev:
	@if ! docker ps --format '{{.Names}}' | grep -q supabase_db_$(PROJECT_ID); then \
	  echo "Local supabase stack not running — starting it first…"; \
	  npm run db:start; \
	fi
	@npm run dev

studio: ; @command -v xdg-open >/dev/null && xdg-open http://127.0.0.1:64423 || echo "Open http://127.0.0.1:64423"
mail:   ; @command -v xdg-open >/dev/null && xdg-open http://127.0.0.1:64424 || echo "Open http://127.0.0.1:64424"
