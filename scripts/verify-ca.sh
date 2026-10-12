#!/bin/sh
# Acceptance Criteria of HU 01.1 - Containerized Local Development Environment.
# Usage: make verify   (or: sh scripts/verify-ca.sh)
#
# The ACs have document numbers (docs/02.md, HU 01.1 section).

# The compose commands are relative to the repo root.
cd "$(dirname "$0")/.." || exit 1

BASE="docker-compose.yml"
DC="docker compose -f $BASE"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

if ! docker info >/dev/null 2>&1; then
  echo "The Docker daemon is not responding. Open Docker Desktop and run again."
  exit 1
fi

# ---------------------------------------------------------------- AC 5
# No versioned secret: .env ignored and .env.example present.
head_ "AC 5 - No secret is versioned"

if [ -f .env.example ]; then
  ok ".env.example exists"
else
  bad ".env.example does not exist"
fi

if [ -f .gitignore ] && grep -qx '\.env' .gitignore; then
  ok ".env is in .gitignore"
else
  bad ".env is not in .gitignore"
fi

if [ -d .git ]; then
  if git ls-files --error-unmatch .env >/dev/null 2>&1; then
    bad ".env is tracked in git"
  else
    ok ".env is not tracked in git"
  fi
else
  printf '  --   (no git repo initialized: tracking check skipped)\n'
fi

# ---------------------------------------------------------------- AC 1
# `up -d --wait` exits with 0 and every container stays healthy.
head_ "AC 1 - up -d --wait exits with 0 and everything is healthy"

START=$(date +%s)
if $DC up -d --wait; then
  ELAPSED=$(( $(date +%s) - START ))
  ok "docker compose up -d --wait exited with 0 (${ELAPSED}s)"
else
  bad "docker compose up -d --wait returned an error"
  $DC ps
  echo "  $DC logs --tail=80"
  exit 1
fi

UNHEALTHY=$($DC ps -q | while read -r id; do
  [ -n "$id" ] || continue
  h=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$id")
  [ "$h" = "healthy" ] || echo "$h"
done)

if [ -z "$UNHEALTHY" ]; then
  ok "all containers are healthy"
else
  bad "unhealthy containers: $(echo "$UNHEALTHY" | tr '\n' ' ')"
  $DC ps
fi

# ---------------------------------------------------------------- AC 4
# psql works against the direct Postgres (5432) and through PgBouncer (6432).
head_ "AC 4 - psql against 5432 (direct) and 6432 (PgBouncer)"

if $DC exec -T postgres psql -U app -d tickets -tAc 'select 1' >/dev/null 2>&1; then
  ok "direct psql (5432) responds"
else
  bad "direct psql (5432) failed"
fi

# The app is pooled through pgbouncer: the query leaves from another container and
# enters through the pooler, which is the real runtime path. PGPASSWORD is resolved
# INSIDE the container, which is where the environment variable lives.
#
# stderr is captured and printed: pgbouncer logs "login attempt" and nothing else
# when the password does not match, so without the psql error the only symptom is
# "failed" and you cannot tell why.
PG_ERR=$(mktemp)
if $DC exec -T postgres sh -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" psql -h pgbouncer -p 5432 -U app -d tickets -tAc "select 1"' \
     >/dev/null 2>"$PG_ERR"; then
  ok "real query through PgBouncer responds"
else
  bad "the query through PgBouncer failed"
  sed 's/^/       /' "$PG_ERR"
  echo "       most likely cause: the password pgbouncer expects is not the one in"
  echo "       the volume. pgbouncer is generated from DATABASE_URL at startup, and"
  echo "       postgres only applies POSTGRES_PASSWORD when the volume is initialized."
  echo "       Changing the password (in .env or via an environment variable, which"
  echo "       takes precedence over .env) without 'make reset' leaves the userlist"
  echo "       out of sync. Fix: make reset && make up"
  $DC logs --tail=20 pgbouncer | sed 's/^/       /'
fi
rm -f "$PG_ERR"

# ---------------------------------------------------------------- AC 2
# Data survives `down` + `up`, and does not survive `reset`.
head_ "AC 2 - data survives down/up and does not survive reset"

$DC exec -T postgres psql -U app -d tickets -q \
  -c "create table if not exists _ca_marker(id int primary key, v text)" \
  -c "insert into _ca_marker values (1,'ca-01-1') on conflict do nothing" >/dev/null 2>&1

$DC down >/dev/null 2>&1
if $DC up -d --wait >/dev/null 2>&1; then
  MARKER=$($DC exec -T postgres psql -U app -d tickets -tAc 'select v from _ca_marker where id=1' 2>/dev/null)
  if [ "$MARKER" = "ca-01-1" ]; then
    ok "the marker is still present after down + up"
  else
    bad "the marker was lost on down + up"
  fi
else
  bad "could not bring the environment back up after down"
fi

$DC down --remove-orphans -v >/dev/null 2>&1
if $DC up -d --wait >/dev/null 2>&1; then
  LEFT=$($DC exec -T postgres psql -U app -d tickets -tAc "select count(*) from _ca_marker" 2>/dev/null)
  if [ -z "$LEFT" ]; then
    ok "reset deleted the volumes (the table no longer exists)"
  else
    bad "reset did not delete the volumes"
  fi
else
  bad "could not bring the environment up after reset"
fi

# ---------------------------------------------------------------- AC 3
# With the images already downloaded, the environment is operational in < 2 min.
head_ "AC 3 - environment operational in under 2 minutes (images already downloaded)"

$DC down --remove-orphans >/dev/null 2>&1
START=$(date +%s)
if $DC up -d --wait >/dev/null 2>&1; then
  ELAPSED=$(( $(date +%s) - START ))
  if [ "$ELAPSED" -lt 120 ]; then
    ok "brought up in ${ELAPSED}s (< 120s)"
  else
    bad "brought up in ${ELAPSED}s, exceeds the 120s limit"
  fi
else
  bad "the bring-up failed"
fi

# ---------------------------------------------------------------- summary
printf '\n\033[1mSummary: %d OK, %d failures\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
