#!/usr/bin/env bash
# Adopt an existing Supabase project into THIS repo's migration history.
#
# Use this once, when a deployment that was built from a different repo (e.g. a
# shop's own fork) starts tracking the platform's migrations instead. The remote
# schema is already correct; only the registry
# (supabase_migrations.schema_migrations) disagrees, so `supabase db push` says:
#
#   "Remote migration versions not found in local migrations directory."
#
# What it does, and only this:
#   1. marks every REMOTE-ONLY version as `reverted` (they name files this repo
#      does not have — their objects stay in the database, untouched);
#   2. marks THIS repo's baseline as `applied` WITHOUT running it (the remote
#      already has those tables — re-running would fail);
#   3. with --applied-through V, also marks every other local-only version up to
#      and including V as `applied` WITHOUT running it — for a deployment that
#      already has those changes under different version numbers (a fork that
#      ported them, renumbered). Leave it out if the deployment only shares the
#      baseline;
#   4. leaves everything else alone. A later `supabase db push` then applies only
#      the genuinely new migrations.
#
# It NEVER touches your schema or your data. It edits the registry table only.
#
# The remote-only set is computed from `supabase migration list`, not hardcoded,
# so this works for any deployment. The baseline is the one thing you must name:
# a script cannot tell "this file already ran under another name" from "this file
# has never run", and guessing wrong would either skip a real migration or try to
# re-create existing tables. --applied-through is the same claim for a range, so
# make it only after diffing the deployment's schema against this repo's at V.
#
# Usage:
#   scripts/adopt-existing-deployment.sh --baseline 20260708090000            # dry run
#   scripts/adopt-existing-deployment.sh --baseline 20260708090000 --apply
#   scripts/adopt-existing-deployment.sh --baseline 20260708090000 --applied-through 20261029120000
#
# PREREQ: back the database up first, and `supabase link` to the project (or
#         run it as `fundive db adopt` from a deployment, which needs neither).
# AFTER:  `supabase db push` to apply the migrations this repo has and the
#         deployment does not.
set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="$PWD/node_modules/.bin:$PATH"
export DO_NOT_TRACK=1   # PostHog's shutdown timeout returns a spurious non-zero

# The follow-up commands differ by where this runs: `fundive db adopt` from a
# deployment repo (FUNDIVE_CLI is set) or the platform repo's npm scripts.
if [ -n "${FUNDIVE_CLI:-}" ]; then
  BACKUP_HINT="npx fundive db backup"
  VERIFY_HINT="npx fundive db adopt --baseline <same> (a dry run; nothing left remote-only)"
  PUSH_HINT="npx fundive db push"
else
  BACKUP_HINT="npm run db:backup-prod"
  VERIFY_HINT="dotenv -e .env.local -- sh -c 'supabase migration list --password \"\$SUPABASE_DB_PASSWORD\"'"
  PUSH_HINT="npm run db:push"
fi

BASELINE=""
APPLIED_THROUGH=""
APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --baseline) BASELINE="${2:-}"; shift 2 ;;
    --applied-through) APPLIED_THROUGH="${2:-}"; shift 2 ;;
    --apply)    APPLY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$BASELINE" ]; then
  echo "error: --baseline <version> is required (this repo's squashed baseline)." >&2
  echo "       Candidates: $(ls supabase/migrations | head -1 | cut -d_ -f1)" >&2
  exit 2
fi
if ! ls "supabase/migrations/${BASELINE}"_*.sql >/dev/null 2>&1; then
  echo "error: no local migration file for baseline $BASELINE" >&2
  exit 2
fi
if [ -n "$APPLIED_THROUGH" ] && ! ls "supabase/migrations/${APPLIED_THROUGH}"_*.sql >/dev/null 2>&1; then
  echo "error: no local migration file for --applied-through $APPLIED_THROUGH" >&2
  exit 2
fi

# Normally runs against the linked project. ADOPT_DB_URL points it at any
# database instead — used to rehearse the whole thing against a restored
# snapshot (or the local stack) before touching production.
link() {
  if [ -n "${ADOPT_DB_URL:-}" ]; then
    supabase "$@" --db-url "$ADOPT_DB_URL"
  else
    dotenv -e .env.local -- sh -c "supabase $* --password \"\$SUPABASE_DB_PASSWORD\""
  fi
}

echo "Reading the remote migration registry..."
LIST_JSON="$(link migration list 2>/dev/null | grep -o '{"migrations":.*}' || true)"
if [ -z "$LIST_JSON" ]; then
  echo "error: could not read the migration list. Is the project linked and .env.local set?" >&2
  exit 1
fi

# Remote-only = recorded on the deployment, absent from this repo.
REMOTE_ONLY="$(printf '%s' "$LIST_JSON" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print(" ".join(m["remote"] for m in d["migrations"] if m["remote"] and not m["local"]))
')"
LOCAL_ONLY="$(printf '%s' "$LIST_JSON" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print(" ".join(m["local"] for m in d["migrations"] if m["local"] and not m["remote"]))
')"

# Local-only versions to record as applied without running: the baseline, plus
# everything up to --applied-through. The rest is left for `db push`.
MARK_APPLIED="$BASELINE"
TO_PUSH=""
for v in $LOCAL_ONLY; do
  [ "$v" = "$BASELINE" ] && continue
  if [ -n "$APPLIED_THROUGH" ] && [ "$v" -le "$APPLIED_THROUGH" ]; then
    MARK_APPLIED="$MARK_APPLIED $v"
  else
    TO_PUSH="$TO_PUSH $v"
  fi
done
echo
echo "  remote-only (will be marked reverted)         : ${REMOTE_ONLY:-<none>}"
echo "  local-only  (will be marked applied, not run) : $MARK_APPLIED"
echo "  local-only  (left for \`db push\`)             : $(echo $TO_PUSH)"
echo

if [ "$APPLY" -ne 1 ]; then
  echo "Dry run. Re-run with --apply to write these changes to the registry."
  echo "Back up the database first: $BACKUP_HINT"
  exit 0
fi

if [ -n "$REMOTE_ONLY" ]; then
  echo "Marking remote-only versions as reverted..."
  # shellcheck disable=SC2086
  link migration repair --status reverted $REMOTE_ONLY
fi

echo "Marking local-only versions as applied (without running them)..."
# shellcheck disable=SC2086
link migration repair --status applied $MARK_APPLIED

echo
echo "Done. Verify with:"
echo "  $VERIFY_HINT"
echo "Then apply the genuinely new migrations:"
echo "  $PUSH_HINT"
