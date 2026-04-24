#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Full safe StealthNet -> Bedolaga migration wrapper.

What it does:
- runs from project root automatically
- auto-detects dump from ./backups (or accepts --dump)
- sanitizes dump from pg_dump18 meta-commands (\\restrict/\\unrestrict) and ownership/grants
- runs official full migration script (users, tariffs, promo groups, subscriptions, payments, tickets, etc.)
- prints last restore/migration logs on failure
- optionally runs post-sync of subscription statuses via local API

Usage:
  scripts/migrate_stealthnet_full_safe.sh [options]

Options:
  --dump <path>                 Explicit dump path (.sql)
  --subs-mode <active|expired>  Subscription import mode (default: active)
  --no-backup                   Skip pre-migration pg_dump backup
  --skip-sync                   Skip post-migration API sync calls
  --yes                         Non-interactive mode
  -h, --help                    Show help
USAGE
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DUMP_FILE=""
SUBS_MODE="active"
NO_BACKUP=false
SKIP_SYNC=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dump)
      DUMP_FILE="${2:-}"
      shift 2
      ;;
    --subs-mode)
      SUBS_MODE="${2:-}"
      shift 2
      ;;
    --no-backup)
      NO_BACKUP=true
      shift
      ;;
    --skip-sync)
      SKIP_SYNC=true
      shift
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ "$SUBS_MODE" == "active" || "$SUBS_MODE" == "expired" ]] || fail "--subs-mode must be active|expired"

require_cmd docker
require_cmd sed
require_cmd grep
require_cmd find
require_cmd awk
require_cmd tail

[[ -f .env ]] || fail ".env not found in $ROOT_DIR"
[[ -f scripts/migrate_stealthnet_to_bedolaga.sh ]] || fail "scripts/migrate_stealthnet_to_bedolaga.sh not found"

if [[ -z "$DUMP_FILE" ]]; then
  DUMP_FILE="$(find backups -maxdepth 1 -type f -name 'stealthnet-backup-*.sql' | sort | tail -n 1 || true)"
  if [[ -z "$DUMP_FILE" ]]; then
    DUMP_FILE="$(find backups -maxdepth 1 -type f -name '*.sql' | sort | tail -n 1 || true)"
  fi
fi

[[ -n "$DUMP_FILE" ]] || fail "no dump found. put .sql into ./backups or use --dump"
[[ -f "$DUMP_FILE" ]] || fail "dump not found: $DUMP_FILE"

PG_CID="$(docker compose ps -q postgres || true)"
[[ -n "$PG_CID" ]] || fail "postgres service container not found (docker compose ps -q postgres)"
PG_CONTAINER="$(docker inspect --format '{{.Name}}' "$PG_CID" | sed 's#^/##')"

PG_USER="$(grep -E '^POSTGRES_USER=' .env | tail -n1 | cut -d= -f2- || true)"
PG_USER="${PG_USER:-remnawave_user}"
TARGET_DB="$(grep -E '^POSTGRES_DB=' .env | tail -n1 | cut -d= -f2- || true)"
TARGET_DB="${TARGET_DB:-remnawave_bot}"
WEB_TOKEN="$(grep -E '^WEB_API_DEFAULT_TOKEN=' .env | tail -n1 | cut -d= -f2- || true)"

RUN_TS="$(date '+%Y%m%d_%H%M%S')"
PREP_DIR="data/migrations/stealthnet/prepared"
mkdir -p "$PREP_DIR"
SANITIZED_DUMP="$PREP_DIR/stealthnet_sanitized_${RUN_TS}.sql"
WRAP_LOG="$PREP_DIR/full_safe_wrapper_${RUN_TS}.log"

log "root dir: $ROOT_DIR"
log "postgres container: $PG_CONTAINER"
log "postgres user: $PG_USER"
log "target db: $TARGET_DB"
log "source dump: $DUMP_FILE"
log "subscriptions mode: $SUBS_MODE"
log "sanitizing dump -> $SANITIZED_DUMP"

# Official SQL migration uses dblink('dbname=<staging>') without explicit user.
# In some environments dblink tries role "postgres". Ensure that role exists and is usable.
POSTGRES_ROLE_STATE="$(docker exec -i "$PG_CONTAINER" psql -At -U "$PG_USER" -d postgres -c "SELECT (rolcanlogin::int::text || ':' || rolsuper::int::text) FROM pg_roles WHERE rolname='postgres' LIMIT 1;" 2>/dev/null || true)"
if [[ -z "$POSTGRES_ROLE_STATE" ]]; then
  log "role 'postgres' is missing; creating it for dblink compatibility"
  docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d postgres -c "CREATE ROLE postgres WITH LOGIN SUPERUSER;" >/dev/null \
    || fail "failed to create role 'postgres'. create it manually and rerun."
elif [[ "$POSTGRES_ROLE_STATE" != "1:1" ]]; then
  log "role 'postgres' exists but is not LOGIN+SUPERUSER; updating for dblink compatibility"
  docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d postgres -c "ALTER ROLE postgres WITH LOGIN SUPERUSER;" >/dev/null \
    || fail "failed to alter role 'postgres' to LOGIN SUPERUSER. fix role and rerun."
fi

# Remove dump directives that break restore into non-superuser staging DBs or old psql clients.
sed -E \
  -e '/^[[:space:]]*\\(restrict|unrestrict)\b/d' \
  -e '/^[[:space:]]*\\connect\b/d' \
  -e '/^[[:space:]]*CREATE DATABASE\b/Id' \
  -e '/^[[:space:]]*ALTER DATABASE\b/Id' \
  -e '/^[[:space:]]*SET[[:space:]]+transaction_timeout[[:space:]]*=.*/Id' \
  -e '/^[[:space:]]*SET[[:space:]]+SESSION[[:space:]]+AUTHORIZATION\b/Id' \
  -e '/^[[:space:]]*ALTER[[:space:]].*OWNER TO\b/Id' \
  -e '/^[[:space:]]*(GRANT|REVOKE)\b/Id' \
  "$DUMP_FILE" > "$SANITIZED_DUMP"

# Compatibility shim for StealthNet variants without public.secondary_subscriptions.
cat >> "$SANITIZED_DUMP" <<'SQL'

DO $$
DECLARE
  source_table text;
  source_table_name text;
  id_expr text;
  owner_expr text;
  rem_expr text;
  idx_expr text;
  tariff_expr text;
  created_expr text;
  updated_expr text;
BEGIN
  IF to_regclass('public.secondary_subscriptions') IS NOT NULL THEN
    RETURN;
  END IF;

  IF to_regclass('public.subscriptions') IS NOT NULL THEN
    source_table := 'public.subscriptions';
  ELSIF to_regclass('public.user_subscriptions') IS NOT NULL THEN
    source_table := 'public.user_subscriptions';
  ELSIF to_regclass('public.client_subscriptions') IS NOT NULL THEN
    source_table := 'public.client_subscriptions';
  ELSE
    RAISE NOTICE '[compat] secondary_subscriptions is missing and no fallback table found';
    RETURN;
  END IF;

  source_table_name := split_part(source_table, '.', 2);

  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=source_table_name AND column_name='id') THEN 'id::text'
    WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=source_table_name AND column_name='subscription_id') THEN 'subscription_id::text'
    WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=source_table_name AND column_name='uuid') THEN 'uuid::text'
    ELSE 'md5(random()::text || clock_timestamp()::text)'
  END INTO id_expr;

  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=source_table_name AND column_name='owner_id') THEN 'owner_id::text'
    WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=source_table_name AND column_name='client_id') THEN 'client_id::text'
    WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=source_table_name AND column_name='user_id') THEN 'user_id::text'
    ELSE 'NULL::text'
  END INTO owner_expr;

  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=source_table_name AND column_name='remnawave_uuid') THEN 'remnawave_uuid::text'
    WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=source_table_name AND column_name='uuid') THEN 'uuid::text'
    WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=source_table_name AND column_name='subscription_uuid') THEN 'subscription_uuid::text'
    ELSE 'NULL::text'
  END INTO rem_expr;

  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=source_table_name AND column_name='subscription_index') THEN 'subscription_index::integer'
    ELSE '1::integer'
  END INTO idx_expr;

  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=source_table_name AND column_name='tariff_id') THEN 'tariff_id::text'
    WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=source_table_name AND column_name='plan_id') THEN 'plan_id::text'
    WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=source_table_name AND column_name='subscription_plan_id') THEN 'subscription_plan_id::text'
    ELSE 'NULL::text'
  END INTO tariff_expr;

  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=source_table_name AND column_name='created_at') THEN 'created_at::timestamp'
    ELSE 'now()::timestamp'
  END INTO created_expr;

  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=source_table_name AND column_name='updated_at') THEN 'updated_at::timestamp'
    WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=source_table_name AND column_name='created_at') THEN 'created_at::timestamp'
    ELSE 'now()::timestamp'
  END INTO updated_expr;

  EXECUTE format(
    'CREATE TABLE public.secondary_subscriptions AS
       SELECT
         %s AS id,
         %s AS owner_id,
         %s AS remnawave_uuid,
         %s AS subscription_index,
         %s AS tariff_id,
         NULL::text AS gift_status,
         NULL::text AS gifted_to_client_id,
         %s AS created_at,
         %s AS updated_at
       FROM %s',
    id_expr, owner_expr, rem_expr, idx_expr, tariff_expr, created_expr, updated_expr, source_table
  );

  RAISE NOTICE '[compat] created secondary_subscriptions from %', source_table;
END $$;
SQL

MIGRATE_CMD=(
  scripts/migrate_stealthnet_to_bedolaga.sh
  --dump "$SANITIZED_DUMP"
  --apply
  --drop-staging
  --subs-mode "$SUBS_MODE"
  --pg-container "$PG_CONTAINER"
  --pg-user "$PG_USER"
  --target-db "$TARGET_DB"
)

if [[ "$ASSUME_YES" == true ]]; then
  MIGRATE_CMD+=(--yes)
fi
if [[ "$NO_BACKUP" == true ]]; then
  MIGRATE_CMD+=(--no-backup)
fi

log "running full migration..."
set +e
"${MIGRATE_CMD[@]}" 2>&1 | tee "$WRAP_LOG"
MIGRATE_STATUS=${PIPESTATUS[0]}
set -e

LATEST_RUN_DIR="$(grep -E 'Run directory:' "$WRAP_LOG" | tail -n1 | sed -E 's/^.*Run directory:[[:space:]]*//' || true)"
if [[ -z "$LATEST_RUN_DIR" ]]; then
  LATEST_RUN_DIR="$(find data/migrations/stealthnet -mindepth 1 -maxdepth 1 -type d -name '20*' 2>/dev/null | sort | tail -n 1 || true)"
fi

if [[ $MIGRATE_STATUS -ne 0 ]]; then
  echo
  log "migration failed (exit=$MIGRATE_STATUS)"
  if [[ -n "$LATEST_RUN_DIR" ]]; then
    log "run dir: $LATEST_RUN_DIR"
    [[ -f "$LATEST_RUN_DIR/restore.log" ]] && { echo "--- restore.log (tail) ---"; tail -n 120 "$LATEST_RUN_DIR/restore.log"; }
    [[ -f "$LATEST_RUN_DIR/migration.log" ]] && { echo "--- migration.log (tail) ---"; tail -n 120 "$LATEST_RUN_DIR/migration.log"; }
  else
    log "run dir not found. wrapper log: $WRAP_LOG"
  fi
  exit $MIGRATE_STATUS
fi

if [[ -n "$LATEST_RUN_DIR" && -f "$LATEST_RUN_DIR/summary.txt" ]]; then
  log "summary: $LATEST_RUN_DIR/summary.txt"
  tail -n 80 "$LATEST_RUN_DIR/summary.txt"
fi

log "checking resulting counts..."
docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$TARGET_DB" -c \
"select count(*) as users from users; select count(*) as subscriptions from subscriptions; select count(*) as active_subscriptions from subscriptions where status='active';"

if [[ "$SKIP_SYNC" != true && -n "$WEB_TOKEN" ]]; then
  require_cmd curl
  log "post-sync subscriptions via local API..."
  curl -fsS -X POST "http://127.0.0.1:8080/remnawave/sync/subscriptions/validate" -H "X-API-Key: $WEB_TOKEN" || true
  echo
  curl -fsS -X POST "http://127.0.0.1:8080/remnawave/sync/subscriptions/statuses" -H "X-API-Key: $WEB_TOKEN" || true
  echo
fi

log "done"
log "wrapper log: $WRAP_LOG"
