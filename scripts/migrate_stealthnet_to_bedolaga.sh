#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Safe StealthNet -> Bedolaga migration helper.

Usage:
  scripts/migrate_stealthnet_to_bedolaga.sh --dump <path/to/stealthnet.sql> [options]

Options:
  --apply                       Apply changes (default: dry-run with rollback).
  --subs-mode <expired|active>  Imported subscription status mode (default: expired).
  --pg-container <name>         PostgreSQL container name (default: remnawave_bot_db).
  --pg-user <name>              PostgreSQL user (default: remnawave_user).
  --target-db <name>            Target Bedolaga database (default: remnawave_bot).
  --staging-db <name>           Staging database name (default: stealthnet_staging_<timestamp>).
  --no-backup                   Skip pre-migration target pg_dump.
  --drop-staging                Drop staging DB after successful run.
  --yes                         Skip interactive confirmation for --apply.
  -h, --help                    Show this help.

Examples:
  scripts/migrate_stealthnet_to_bedolaga.sh --dump stealthnet-backup-2026-04-24T06-18-24.sql
  scripts/migrate_stealthnet_to_bedolaga.sh --dump stealthnet.sql --apply --yes
  scripts/migrate_stealthnet_to_bedolaga.sh --dump stealthnet.sql --apply --subs-mode active --yes
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

DUMP_FILE=""
APPLY=false
SUBS_MODE="expired"
PG_CONTAINER="remnawave_bot_db"
PG_USER="remnawave_user"
TARGET_DB="remnawave_bot"
NO_BACKUP=false
DROP_STAGING=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dump)
      DUMP_FILE="${2:-}"
      shift 2
      ;;
    --apply)
      APPLY=true
      shift
      ;;
    --subs-mode)
      SUBS_MODE="${2:-}"
      shift 2
      ;;
    --pg-container)
      PG_CONTAINER="${2:-}"
      shift 2
      ;;
    --pg-user)
      PG_USER="${2:-}"
      shift 2
      ;;
    --target-db)
      TARGET_DB="${2:-}"
      shift 2
      ;;
    --staging-db)
      STAGING_DB="${2:-}"
      shift 2
      ;;
    --no-backup)
      NO_BACKUP=true
      shift
      ;;
    --drop-staging)
      DROP_STAGING=true
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
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$DUMP_FILE" ]]; then
  echo "--dump is required" >&2
  usage
  exit 1
fi

if [[ "$SUBS_MODE" != "expired" && "$SUBS_MODE" != "active" ]]; then
  echo "--subs-mode must be one of: expired, active" >&2
  exit 1
fi

if [[ ! -f "$DUMP_FILE" ]]; then
  echo "Dump file not found: $DUMP_FILE" >&2
  exit 1
fi

require_cmd docker
require_cmd sed
require_cmd awk

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
STAGING_DB="${STAGING_DB:-stealthnet_staging_${TIMESTAMP}}"
RUN_DIR="data/migrations/stealthnet/${TIMESTAMP}"
mkdir -p "$RUN_DIR"

MIGRATION_SQL="scripts/sql/stealthnet_to_bedolaga.sql"
if [[ ! -f "$MIGRATION_SQL" ]]; then
  echo "Migration SQL not found: $MIGRATION_SQL" >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -Fx "$PG_CONTAINER" >/dev/null 2>&1; then
  echo "PostgreSQL container is not running: $PG_CONTAINER" >&2
  exit 1
fi

MODE_LABEL="DRY-RUN"
TX_FINALIZE="ROLLBACK;"
if $APPLY; then
  MODE_LABEL="APPLY"
  TX_FINALIZE="COMMIT;"
fi

log "Mode: $MODE_LABEL"
log "Dump: $DUMP_FILE"
log "Target DB: $TARGET_DB"
log "Staging DB: $STAGING_DB"
log "Subscriptions mode: $SUBS_MODE"
log "Run directory: $RUN_DIR"

if $APPLY && ! $ASSUME_YES; then
  echo
  echo "This will modify database '$TARGET_DB' in container '$PG_CONTAINER'."
  read -r -p "Continue? [y/N] " ANSWER
  if [[ "${ANSWER:-}" != "y" && "${ANSWER:-}" != "Y" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

if $APPLY && ! $NO_BACKUP; then
  BACKUP_FILE="$RUN_DIR/bedolaga_pre_migration_${TIMESTAMP}.sql"
  log "Creating safety backup: $BACKUP_FILE"
  docker exec -t "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$TARGET_DB" > "$BACKUP_FILE"
fi

log "Recreating staging database"
docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d postgres -c "DROP DATABASE IF EXISTS \"$STAGING_DB\";" >/dev/null
docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d postgres -c "CREATE DATABASE \"$STAGING_DB\";" >/dev/null

log "Restoring dump into staging database"
RESTORE_LOG="$RUN_DIR/restore.log"
cat "$DUMP_FILE" | docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$STAGING_DB" >"$RESTORE_LOG" 2>&1

log "Ensuring staging compatibility tables"
cat <<'SQL' | docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$STAGING_DB" >>"$RESTORE_LOG" 2>&1
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
  END IF;

  IF source_table IS NULL THEN
    CREATE TABLE public.secondary_subscriptions (
      id text,
      owner_id text,
      remnawave_uuid text,
      subscription_index integer,
      tariff_id text,
      gift_status text,
      gifted_to_client_id text,
      created_at timestamp,
      updated_at timestamp
    );
    RAISE NOTICE '[compat] created empty public.secondary_subscriptions';
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
  RAISE NOTICE '[compat] created public.secondary_subscriptions from %', source_table;
END $$;
SQL

log "Running migration SQL ($MODE_LABEL)"
MIGRATION_LOG="$RUN_DIR/migration.log"
{
  echo "\\set ON_ERROR_STOP on"
  echo "BEGIN;"
  cat "$MIGRATION_SQL"
  echo "$TX_FINALIZE"
} | docker exec -i "$PG_CONTAINER" psql \
      -v ON_ERROR_STOP=1 \
      -v source_db="$STAGING_DB" \
      -v subs_mode="$SUBS_MODE" \
      -U "$PG_USER" \
      -d "$TARGET_DB" >"$MIGRATION_LOG" 2>&1

SUMMARY_FILE="$RUN_DIR/summary.txt"
{
  echo "Migration mode: $MODE_LABEL"
  echo "Timestamp: $TIMESTAMP"
  echo "Source dump: $DUMP_FILE"
  echo "Staging DB: $STAGING_DB"
  echo "Target DB: $TARGET_DB"
  echo "Subscriptions mode: $SUBS_MODE"
  echo
  echo "--- Last migration output lines ---"
  tail -n 80 "$MIGRATION_LOG"
} > "$SUMMARY_FILE"

if $DROP_STAGING; then
  log "Dropping staging database: $STAGING_DB"
  docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d postgres -c "DROP DATABASE IF EXISTS \"$STAGING_DB\";" >/dev/null
fi

log "Completed: $MODE_LABEL"
log "Restore log: $RESTORE_LOG"
log "Migration log: $MIGRATION_LOG"
log "Summary: $SUMMARY_FILE"

if ! $APPLY; then
  log "Dry-run finished. Re-run with --apply to commit changes."
fi
