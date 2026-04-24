#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Bedolaga stack bootstrap (bot + cabinet).

This script prepares .env files, validates configuration, and starts:
- Bot stack from project root docker-compose.yml
- Cabinet frontend from bedolaga-cabinet-main/docker-compose.yml

Usage:
  scripts/bootstrap_bedolaga_stack.sh [options]

Options:
  --apply                         Apply changes and start containers.
                                  Default mode is dry-run (show checks only).
  --yes                           Skip interactive confirmation in --apply mode.
  --bot-env <path>                Bot env file path (default: .env)
  --cabinet-dir <path>            Cabinet repo path (default: ./bedolaga-cabinet-main)
  --cabinet-env <path>            Cabinet env path (default: <cabinet-dir>/.env)
  --cabinet-port <port>           Cabinet host port (default: 7053)
  --api-port <port>               Bot WEB_API_PORT (default: 8080)
  --api-origin <url>              Cabinet origin for CORS (default: http://localhost:<cabinet-port>)
  --api-url <url>                 VITE_API_URL for cabinet (default: http://localhost:<api-port>)
  --bot-username <username>       Telegram bot username for cabinet (without @)
  --admin-ids <csv>               Override ADMIN_IDS (e.g. 123,456)
  --web-token <token>             Override WEB_API_DEFAULT_TOKEN
  --jwt-secret <secret>           Override CABINET_JWT_SECRET
  --remnawave-url <url>           Override REMNAWAVE_API_URL
  --remnawave-key <key>           Override REMNAWAVE_API_KEY
  --skip-build                    Use docker compose up -d (without --build)
  --providers <list>              Enable payment providers (comma-separated).
                                  Supported: yookassa,cryptobot,heleket,mulenpay,pal24,freekassa,
                                             cloudpayments,kassa_ai,riopay,severpay,paypear,
                                             rollypay,aurapay,wata,platega,tribute
  --import-stealthnet <mode>      StealthNet SQL import mode: auto|on|off (default: auto)
  --backups-dir <path>            Directory with StealthNet dumps (default: ./backups)
  --stealthnet-dump <path>        Explicit StealthNet .sql dump file path
  --stealthnet-subs-mode <mode>   Subscriptions mode for import: expired|active (default: expired)
  -h, --help                      Show this help.

Examples:
  scripts/bootstrap_bedolaga_stack.sh
  scripts/bootstrap_bedolaga_stack.sh --apply --yes --bot-username my_vpn_bot
  scripts/bootstrap_bedolaga_stack.sh --apply --providers yookassa,cryptobot --yes
  scripts/bootstrap_bedolaga_stack.sh --apply --import-stealthnet on --yes
EOF
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

trim() {
  local s="$1"
  # shellcheck disable=SC2001
  s="$(echo "$s" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s' "$s"
}

normalize_bool() {
  local v
  v="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    1|true|yes|on) echo "true" ;;
    0|false|no|off) echo "false" ;;
    *) echo "" ;;
  esac
}

gen_secret_hex() {
  local bytes="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

is_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_valid_url() {
  [[ "$1" =~ ^https?://.+$ ]]
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp "$f" "$f.bak.$RUN_TS"
    log "backup created: $f.bak.$RUN_TS"
  fi
}

env_get() {
  local file="$1"
  local key="$2"
  if [[ ! -f "$file" ]]; then
    return 0
  fi
  local line
  line="$(grep -E "^${key}=" "$file" | tail -n 1 || true)"
  if [[ -z "$line" ]]; then
    return 0
  fi
  printf '%s' "${line#*=}"
}

env_set() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"

  if [[ -f "$file" ]] && grep -qE "^${key}=" "$file"; then
    awk -v k="$key" -v v="$value" 'BEGIN{done=0}
      $0 ~ "^"k"=" {if(!done){print k"="v; done=1} next}
      {print}
      END{if(!done) print k"="v}
    ' "$file" > "$tmp"
  else
    if [[ -f "$file" ]]; then
      cat "$file" > "$tmp"
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi

  mv "$tmp" "$file"
}

validate_admin_ids() {
  local ids="$1"
  [[ -z "$ids" ]] && return 1
  local IFS=','
  local item
  for item in $ids; do
    item="$(trim "$item")"
    [[ -z "$item" ]] && return 1
    [[ "$item" =~ ^-?[0-9]+$ ]] || return 1
  done
  return 0
}

validate_bot_token() {
  local t="$1"
  [[ "$t" =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]]
}

pick_stealthnet_dump() {
  local backups_dir="$1"
  local explicit_path="$2"

  if [[ -n "$explicit_path" ]]; then
    if [[ -f "$explicit_path" ]]; then
      printf '%s' "$explicit_path"
      return 0
    fi
    return 1
  fi

  if [[ ! -d "$backups_dir" ]]; then
    return 2
  fi

  local found
  found="$(find "$backups_dir" -maxdepth 1 -type f -name 'stealthnet-backup-*.sql' | sort | tail -n 1 || true)"
  if [[ -n "$found" ]]; then
    printf '%s' "$found"
    return 0
  fi

  found="$(find "$backups_dir" -maxdepth 1 -type f -name '*.sql' | sort | tail -n 1 || true)"
  if [[ -n "$found" ]]; then
    printf '%s' "$found"
    return 0
  fi

  return 3
}

provider_enabled() {
  local provider="$1"
  local list="$2"
  local csv=",$(echo "$list" | tr '[:upper:]' '[:lower:]' | tr -d ' '),"
  [[ "$csv" == *",$provider,"* ]]
}

validate_payment_provider_envs() {
  local bot_env="$1"
  local ok=true

  check_required_if_true() {
    local enabled_key="$1"
    shift
    local enabled_raw
    enabled_raw="$(env_get "$bot_env" "$enabled_key")"
    local enabled
    enabled="$(normalize_bool "$enabled_raw")"

    if [[ "$enabled" == "true" ]]; then
      local req_key
      for req_key in "$@"; do
        local req_val
        req_val="$(env_get "$bot_env" "$req_key")"
        if [[ -z "$(trim "$req_val")" ]]; then
          echo "missing required variable for enabled provider: $req_key (because $enabled_key=true)" >&2
          ok=false
        fi
      done
    fi
  }

  check_required_if_true "YOOKASSA_ENABLED" "YOOKASSA_SHOP_ID" "YOOKASSA_SECRET_KEY"
  check_required_if_true "CRYPTOBOT_ENABLED" "CRYPTOBOT_API_TOKEN"
  check_required_if_true "HELEKET_ENABLED" "HELEKET_API_KEY" "HELEKET_MERCHANT_ID"
  check_required_if_true "MULENPAY_ENABLED" "MULENPAY_API_KEY" "MULENPAY_SECRET_KEY" "MULENPAY_SHOP_ID"
  check_required_if_true "PAL24_ENABLED" "PAL24_API_TOKEN" "PAL24_SHOP_ID" "PAL24_SIGNATURE_TOKEN"
  check_required_if_true "FREEKASSA_ENABLED" "FREEKASSA_SHOP_ID" "FREEKASSA_API_KEY" "FREEKASSA_SECRET_WORD_1" "FREEKASSA_SECRET_WORD_2"
  check_required_if_true "CLOUDPAYMENTS_ENABLED" "CLOUDPAYMENTS_PUBLIC_ID" "CLOUDPAYMENTS_API_SECRET"
  check_required_if_true "KASSA_AI_ENABLED" "KASSA_AI_SHOP_ID" "KASSA_AI_API_KEY" "KASSA_AI_SECRET_WORD_2"
  check_required_if_true "RIOPAY_ENABLED" "RIOPAY_API_TOKEN"
  check_required_if_true "SEVERPAY_ENABLED" "SEVERPAY_MID" "SEVERPAY_TOKEN"
  check_required_if_true "PAYPEAR_ENABLED" "PAYPEAR_SHOP_ID" "PAYPEAR_SECRET_KEY"
  check_required_if_true "ROLLYPAY_ENABLED" "ROLLYPAY_API_KEY" "ROLLYPAY_SIGNING_SECRET"
  check_required_if_true "AURAPAY_ENABLED" "AURAPAY_API_KEY" "AURAPAY_SHOP_ID" "AURAPAY_SECRET_KEY"
  check_required_if_true "WATA_ENABLED" "WATA_ACCESS_TOKEN"
  check_required_if_true "PLATEGA_ENABLED" "PLATEGA_MERCHANT_ID" "PLATEGA_SECRET"
  check_required_if_true "TRIBUTE_ENABLED" "TRIBUTE_API_KEY" "TRIBUTE_DONATE_LINK"

  if [[ "$ok" != "true" ]]; then
    return 1
  fi
  return 0
}

APPLY=false
ASSUME_YES=false
SKIP_BUILD=false
BOT_ENV=".env"
CABINET_DIR="bedolaga-cabinet-main"
CABINET_ENV=""
CABINET_PORT="7053"
API_PORT="8080"
API_ORIGIN=""
API_URL=""
BOT_USERNAME=""
ADMIN_IDS_OVERRIDE=""
WEB_TOKEN_OVERRIDE=""
JWT_SECRET_OVERRIDE=""
REMNAWAVE_URL_OVERRIDE=""
REMNAWAVE_KEY_OVERRIDE=""
PROVIDERS=""
IMPORT_STEALTHNET="auto"
BACKUPS_DIR="backups"
STEALTHNET_DUMP=""
STEALTHNET_SUBS_MODE="expired"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=true
      shift
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    --bot-env)
      BOT_ENV="${2:-}"
      shift 2
      ;;
    --cabinet-dir)
      CABINET_DIR="${2:-}"
      shift 2
      ;;
    --cabinet-env)
      CABINET_ENV="${2:-}"
      shift 2
      ;;
    --cabinet-port)
      CABINET_PORT="${2:-}"
      shift 2
      ;;
    --api-port)
      API_PORT="${2:-}"
      shift 2
      ;;
    --api-origin)
      API_ORIGIN="${2:-}"
      shift 2
      ;;
    --api-url)
      API_URL="${2:-}"
      shift 2
      ;;
    --bot-username)
      BOT_USERNAME="${2:-}"
      shift 2
      ;;
    --admin-ids)
      ADMIN_IDS_OVERRIDE="${2:-}"
      shift 2
      ;;
    --web-token)
      WEB_TOKEN_OVERRIDE="${2:-}"
      shift 2
      ;;
    --jwt-secret)
      JWT_SECRET_OVERRIDE="${2:-}"
      shift 2
      ;;
    --remnawave-url)
      REMNAWAVE_URL_OVERRIDE="${2:-}"
      shift 2
      ;;
    --remnawave-key)
      REMNAWAVE_KEY_OVERRIDE="${2:-}"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --providers)
      PROVIDERS="${2:-}"
      shift 2
      ;;
    --import-stealthnet)
      IMPORT_STEALTHNET="${2:-}"
      shift 2
      ;;
    --backups-dir)
      BACKUPS_DIR="${2:-}"
      shift 2
      ;;
    --stealthnet-dump)
      STEALTHNET_DUMP="${2:-}"
      shift 2
      ;;
    --stealthnet-subs-mode)
      STEALTHNET_SUBS_MODE="${2:-}"
      shift 2
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

RUN_TS="$(date '+%Y%m%d_%H%M%S')"

require_cmd awk
require_cmd sed
require_cmd grep
require_cmd docker
require_cmd curl

is_int "$CABINET_PORT" || fail "--cabinet-port must be an integer"
is_int "$API_PORT" || fail "--api-port must be an integer"
[[ "$IMPORT_STEALTHNET" == "auto" || "$IMPORT_STEALTHNET" == "on" || "$IMPORT_STEALTHNET" == "off" ]] || fail "--import-stealthnet must be auto|on|off"
[[ "$STEALTHNET_SUBS_MODE" == "expired" || "$STEALTHNET_SUBS_MODE" == "active" ]] || fail "--stealthnet-subs-mode must be expired|active"

if [[ -z "$CABINET_ENV" ]]; then
  CABINET_ENV="$CABINET_DIR/.env"
fi

[[ -d "$CABINET_DIR" ]] || fail "cabinet directory not found: $CABINET_DIR"
[[ -f "$CABINET_DIR/.env.example" ]] || fail "cabinet .env.example not found: $CABINET_DIR/.env.example"
[[ -f ".env.example" ]] || fail "bot .env.example not found in project root"

if [[ -z "$API_ORIGIN" ]]; then
  API_ORIGIN="http://localhost:${CABINET_PORT}"
fi
if [[ -z "$API_URL" ]]; then
  API_URL="http://localhost:${API_PORT}"
fi

log "mode: $([[ "$APPLY" == true ]] && echo APPLY || echo DRY-RUN)"
log "bot env: $BOT_ENV"
log "cabinet env: $CABINET_ENV"
log "cabinet dir: $CABINET_DIR"
log "cabinet port: $CABINET_PORT"
log "api port: $API_PORT"
log "api origin: $API_ORIGIN"
log "cabinet api url: $API_URL"
log "stealthnet import mode: $IMPORT_STEALTHNET"
log "backups dir: $BACKUPS_DIR"

if [[ "$APPLY" == true && "$ASSUME_YES" != true ]]; then
  echo
  echo "This will modify env files and start Docker containers."
  read -r -p "Continue? [y/N] " ans
  if [[ "${ans:-}" != "y" && "${ans:-}" != "Y" ]]; then
    echo "aborted"
    exit 1
  fi
fi

# Ensure env files exist
if [[ ! -f "$BOT_ENV" ]]; then
  if [[ "$APPLY" == true ]]; then
    cp .env.example "$BOT_ENV"
    log "created $BOT_ENV from .env.example"
  else
    fail "$BOT_ENV not found. Run with --apply once to initialize it from .env.example"
  fi
fi
if [[ ! -f "$CABINET_ENV" ]]; then
  if [[ "$APPLY" == true ]]; then
    cp "$CABINET_DIR/.env.example" "$CABINET_ENV"
    log "created $CABINET_ENV from cabinet .env.example"
  else
    fail "$CABINET_ENV not found. Run with --apply once to initialize it from cabinet .env.example"
  fi
fi

if [[ "$APPLY" == true ]]; then
  backup_file "$BOT_ENV"
  backup_file "$CABINET_ENV"
  if [[ ! -d "$BACKUPS_DIR" ]]; then
    mkdir -p "$BACKUPS_DIR"
    log "created backups dir: $BACKUPS_DIR"
  fi
fi

# Derived / generated values
WEB_TOKEN_VALUE="$(trim "${WEB_TOKEN_OVERRIDE:-$(env_get "$BOT_ENV" "WEB_API_DEFAULT_TOKEN")}")"
if [[ -z "$WEB_TOKEN_VALUE" ]]; then
  WEB_TOKEN_VALUE="$(gen_secret_hex 24)"
fi

JWT_SECRET_VALUE="$(trim "${JWT_SECRET_OVERRIDE:-$(env_get "$BOT_ENV" "CABINET_JWT_SECRET")}")"
if [[ -z "$JWT_SECRET_VALUE" ]]; then
  JWT_SECRET_VALUE="$(gen_secret_hex 32)"
fi

if [[ -n "$ADMIN_IDS_OVERRIDE" ]]; then
  ADMIN_IDS_VALUE="$ADMIN_IDS_OVERRIDE"
else
  ADMIN_IDS_VALUE="$(env_get "$BOT_ENV" "ADMIN_IDS")"
fi

if [[ -n "$REMNAWAVE_URL_OVERRIDE" ]]; then
  REMNAWAVE_URL_VALUE="$REMNAWAVE_URL_OVERRIDE"
else
  REMNAWAVE_URL_VALUE="$(env_get "$BOT_ENV" "REMNAWAVE_API_URL")"
fi

if [[ -n "$REMNAWAVE_KEY_OVERRIDE" ]]; then
  REMNAWAVE_KEY_VALUE="$REMNAWAVE_KEY_OVERRIDE"
else
  REMNAWAVE_KEY_VALUE="$(env_get "$BOT_ENV" "REMNAWAVE_API_KEY")"
fi

BOT_TOKEN_VALUE="$(env_get "$BOT_ENV" "BOT_TOKEN")"

CABINET_BOT_USERNAME_VALUE="$BOT_USERNAME"
if [[ -z "$CABINET_BOT_USERNAME_VALUE" ]]; then
  CABINET_BOT_USERNAME_VALUE="$(env_get "$CABINET_ENV" "VITE_TELEGRAM_BOT_USERNAME")"
fi

# Apply payment provider toggles (only if --providers passed)
set_provider_toggle() {
  local env_file="$1"
  local key="$2"
  local provider="$3"
  if [[ -n "$PROVIDERS" ]]; then
    if provider_enabled "$provider" "$PROVIDERS"; then
      env_set "$env_file" "$key" "true"
    else
      env_set "$env_file" "$key" "false"
    fi
  fi
}

if [[ "$APPLY" == true ]]; then
  # Bot base
  env_set "$BOT_ENV" "CABINET_ENABLED" "true"
  env_set "$BOT_ENV" "CABINET_URL" "$API_ORIGIN"
  env_set "$BOT_ENV" "CABINET_JWT_SECRET" "$JWT_SECRET_VALUE"
  env_set "$BOT_ENV" "CABINET_ALLOWED_ORIGINS" "$API_ORIGIN"
  env_set "$BOT_ENV" "WEB_API_ENABLED" "true"
  env_set "$BOT_ENV" "WEB_API_HOST" "0.0.0.0"
  env_set "$BOT_ENV" "WEB_API_PORT" "$API_PORT"
  env_set "$BOT_ENV" "WEB_API_DOCS_ENABLED" "true"
  env_set "$BOT_ENV" "WEB_API_DEFAULT_TOKEN" "$WEB_TOKEN_VALUE"
  env_set "$BOT_ENV" "WEB_API_ALLOWED_ORIGINS" "$API_ORIGIN"

  # Ensure docker defaults are present
  if [[ -z "$(trim "$(env_get "$BOT_ENV" "POSTGRES_HOST")")" ]]; then env_set "$BOT_ENV" "POSTGRES_HOST" "postgres"; fi
  if [[ -z "$(trim "$(env_get "$BOT_ENV" "POSTGRES_PORT")")" ]]; then env_set "$BOT_ENV" "POSTGRES_PORT" "5432"; fi
  if [[ -z "$(trim "$(env_get "$BOT_ENV" "POSTGRES_DB")")" ]]; then env_set "$BOT_ENV" "POSTGRES_DB" "remnawave_bot"; fi
  if [[ -z "$(trim "$(env_get "$BOT_ENV" "POSTGRES_USER")")" ]]; then env_set "$BOT_ENV" "POSTGRES_USER" "remnawave_user"; fi
  if [[ -z "$(trim "$(env_get "$BOT_ENV" "POSTGRES_PASSWORD")")" ]]; then env_set "$BOT_ENV" "POSTGRES_PASSWORD" "secure_password_123"; fi
  if [[ -z "$(trim "$(env_get "$BOT_ENV" "REDIS_URL")")" ]]; then env_set "$BOT_ENV" "REDIS_URL" "redis://redis:6379/0"; fi

  if [[ -n "$(trim "$ADMIN_IDS_VALUE")" ]]; then
    env_set "$BOT_ENV" "ADMIN_IDS" "$ADMIN_IDS_VALUE"
  fi

  if [[ -n "$(trim "$REMNAWAVE_URL_VALUE")" ]]; then
    env_set "$BOT_ENV" "REMNAWAVE_API_URL" "$REMNAWAVE_URL_VALUE"
  fi
  if [[ -n "$(trim "$REMNAWAVE_KEY_VALUE")" ]]; then
    env_set "$BOT_ENV" "REMNAWAVE_API_KEY" "$REMNAWAVE_KEY_VALUE"
  fi

  # Provider toggles
  set_provider_toggle "$BOT_ENV" "YOOKASSA_ENABLED" "yookassa"
  set_provider_toggle "$BOT_ENV" "CRYPTOBOT_ENABLED" "cryptobot"
  set_provider_toggle "$BOT_ENV" "HELEKET_ENABLED" "heleket"
  set_provider_toggle "$BOT_ENV" "MULENPAY_ENABLED" "mulenpay"
  set_provider_toggle "$BOT_ENV" "PAL24_ENABLED" "pal24"
  set_provider_toggle "$BOT_ENV" "FREEKASSA_ENABLED" "freekassa"
  set_provider_toggle "$BOT_ENV" "CLOUDPAYMENTS_ENABLED" "cloudpayments"
  set_provider_toggle "$BOT_ENV" "KASSA_AI_ENABLED" "kassa_ai"
  set_provider_toggle "$BOT_ENV" "RIOPAY_ENABLED" "riopay"
  set_provider_toggle "$BOT_ENV" "SEVERPAY_ENABLED" "severpay"
  set_provider_toggle "$BOT_ENV" "PAYPEAR_ENABLED" "paypear"
  set_provider_toggle "$BOT_ENV" "ROLLYPAY_ENABLED" "rollypay"
  set_provider_toggle "$BOT_ENV" "AURAPAY_ENABLED" "aurapay"
  set_provider_toggle "$BOT_ENV" "WATA_ENABLED" "wata"
  set_provider_toggle "$BOT_ENV" "PLATEGA_ENABLED" "platega"
  set_provider_toggle "$BOT_ENV" "TRIBUTE_ENABLED" "tribute"

  # Cabinet env
  env_set "$CABINET_ENV" "VITE_API_URL" "$API_URL"
  env_set "$CABINET_ENV" "CABINET_PORT" "$CABINET_PORT"
  if [[ -n "$(trim "$CABINET_BOT_USERNAME_VALUE")" ]]; then
    env_set "$CABINET_ENV" "VITE_TELEGRAM_BOT_USERNAME" "$CABINET_BOT_USERNAME_VALUE"
  fi
fi

# Re-read effective values after optional apply
BOT_TOKEN_VALUE="$(trim "$(env_get "$BOT_ENV" "BOT_TOKEN")")"
ADMIN_IDS_VALUE="$(trim "$(env_get "$BOT_ENV" "ADMIN_IDS")")"
REMNAWAVE_URL_VALUE="$(trim "$(env_get "$BOT_ENV" "REMNAWAVE_API_URL")")"
REMNAWAVE_KEY_VALUE="$(trim "$(env_get "$BOT_ENV" "REMNAWAVE_API_KEY")")"
WEB_TOKEN_VALUE="$(trim "$(env_get "$BOT_ENV" "WEB_API_DEFAULT_TOKEN")")"
JWT_SECRET_VALUE="$(trim "$(env_get "$BOT_ENV" "CABINET_JWT_SECRET")")"
API_ORIGIN_VALUE="$(trim "$(env_get "$BOT_ENV" "CABINET_ALLOWED_ORIGINS")")"
CABINET_PORT_VALUE="$(trim "$(env_get "$CABINET_ENV" "CABINET_PORT")")"
VITE_API_URL_VALUE="$(trim "$(env_get "$CABINET_ENV" "VITE_API_URL")")"
CABINET_BOT_USERNAME_VALUE="$(trim "$(env_get "$CABINET_ENV" "VITE_TELEGRAM_BOT_USERNAME")")"

# Validation
VALID=true

if ! validate_bot_token "$BOT_TOKEN_VALUE"; then
  echo "invalid BOT_TOKEN format in $BOT_ENV" >&2
  VALID=false
fi

if ! validate_admin_ids "$ADMIN_IDS_VALUE"; then
  echo "invalid ADMIN_IDS in $BOT_ENV (expected comma-separated numeric IDs)" >&2
  VALID=false
fi

if [[ -z "$JWT_SECRET_VALUE" || ${#JWT_SECRET_VALUE} -lt 32 ]]; then
  echo "CABINET_JWT_SECRET must be at least 32 chars" >&2
  VALID=false
fi

if [[ -z "$WEB_TOKEN_VALUE" || ${#WEB_TOKEN_VALUE} -lt 24 ]]; then
  echo "WEB_API_DEFAULT_TOKEN must be at least 24 chars" >&2
  VALID=false
fi

if ! is_valid_url "$REMNAWAVE_URL_VALUE"; then
  echo "REMNAWAVE_API_URL must be a valid http(s) URL" >&2
  VALID=false
fi

if [[ -z "$REMNAWAVE_KEY_VALUE" ]]; then
  echo "REMNAWAVE_API_KEY is empty" >&2
  VALID=false
fi

if [[ -z "$API_ORIGIN_VALUE" ]]; then
  echo "CABINET_ALLOWED_ORIGINS is empty" >&2
  VALID=false
fi

if [[ -z "$CABINET_PORT_VALUE" || ! "$CABINET_PORT_VALUE" =~ ^[0-9]+$ ]]; then
  echo "CABINET_PORT in $CABINET_ENV must be numeric" >&2
  VALID=false
fi

if [[ -z "$VITE_API_URL_VALUE" ]]; then
  echo "VITE_API_URL in $CABINET_ENV is empty" >&2
  VALID=false
fi

if [[ -z "$CABINET_BOT_USERNAME_VALUE" || "$CABINET_BOT_USERNAME_VALUE" == "your_bot_username" ]]; then
  echo "VITE_TELEGRAM_BOT_USERNAME is empty or placeholder in $CABINET_ENV" >&2
  VALID=false
fi

if ! validate_payment_provider_envs "$BOT_ENV"; then
  VALID=false
fi

if [[ "$VALID" != true ]]; then
  fail "configuration validation failed. Fix env values and rerun."
fi

log "configuration validation: OK"

if [[ "$IMPORT_STEALTHNET" != "off" ]]; then
  if dump_candidate="$(pick_stealthnet_dump "$BACKUPS_DIR" "$STEALTHNET_DUMP")"; then
    log "stealthnet dump candidate: $dump_candidate"
  else
    rc=$?
    if [[ "$IMPORT_STEALTHNET" == "on" ]]; then
      case "$rc" in
        1) fail "explicit --stealthnet-dump not found: $STEALTHNET_DUMP" ;;
        2) fail "backups dir not found: $BACKUPS_DIR" ;;
        *) fail "no .sql dump found in backups dir: $BACKUPS_DIR" ;;
      esac
    else
      log "stealthnet dump not found (mode=auto), migration will be skipped"
    fi
  fi
fi

if [[ "$APPLY" != true ]]; then
  log "dry-run completed. run with --apply to write and start services."
  exit 0
fi

# Docker checks
if ! docker info >/dev/null 2>&1; then
  fail "docker daemon is not running or inaccessible"
fi

ROOT_COMPOSE_CMD=(docker compose)
CABINET_COMPOSE_CMD=(docker compose)

if [[ "$SKIP_BUILD" == true ]]; then
  BOT_UP_ARGS=(up -d)
  CAB_UP_ARGS=(up -d)
else
  BOT_UP_ARGS=(up -d --build)
  CAB_UP_ARGS=(up -d --build)
fi

log "starting bot stack..."
"${ROOT_COMPOSE_CMD[@]}" "${BOT_UP_ARGS[@]}"

if [[ "$IMPORT_STEALTHNET" != "off" ]] && [[ -n "${dump_candidate:-}" ]]; then
  MIGRATE_SCRIPT="scripts/migrate_stealthnet_to_bedolaga.sh"
  [[ -f "$MIGRATE_SCRIPT" ]] || fail "migration helper not found: $MIGRATE_SCRIPT"
  log "starting stealthnet migration from: $dump_candidate"
  "$MIGRATE_SCRIPT" \
    --dump "$dump_candidate" \
    --apply \
    --yes \
    --drop-staging \
    --subs-mode "$STEALTHNET_SUBS_MODE"
  log "stealthnet migration completed"
fi

log "starting cabinet stack..."
(
  cd "$CABINET_DIR"
  "${CABINET_COMPOSE_CMD[@]}" "${CAB_UP_ARGS[@]}"
)

API_PORT_VALUE="$(trim "$(env_get "$BOT_ENV" "WEB_API_PORT")")"
CABINET_PORT_VALUE="$(trim "$(env_get "$CABINET_ENV" "CABINET_PORT")")"

wait_http() {
  local name="$1"
  local url="$2"
  local header_name="${3:-}"
  local header_value="${4:-}"
  local max_attempts=60
  local i

  for ((i=1; i<=max_attempts; i++)); do
    if [[ -n "$header_name" ]]; then
      if curl -fsS -m 5 -H "$header_name: $header_value" "$url" >/dev/null 2>&1; then
        log "$name is ready: $url"
        return 0
      fi
    else
      if curl -fsS -m 5 "$url" >/dev/null 2>&1; then
        log "$name is ready: $url"
        return 0
      fi
    fi
    sleep 2
  done

  return 1
}

if ! wait_http "Bot API" "http://localhost:${API_PORT_VALUE}/health" "X-API-Key" "$WEB_TOKEN_VALUE"; then
  log "Bot API health check failed. Check: docker compose logs bot"
  exit 1
fi

if ! wait_http "Cabinet" "http://localhost:${CABINET_PORT_VALUE}/"; then
  log "Cabinet health check failed. Check: (cd $CABINET_DIR && docker compose logs cabinet-frontend)"
  exit 1
fi

cat <<EOF

Stack is up.

URLs:
- Cabinet: http://localhost:${CABINET_PORT_VALUE}
- Bot API: http://localhost:${API_PORT_VALUE}
- Bot API docs: http://localhost:${API_PORT_VALUE}/docs

Important:
- WEB_API_DEFAULT_TOKEN: $WEB_TOKEN_VALUE
- CABINET_ALLOWED_ORIGINS: $(env_get "$BOT_ENV" "CABINET_ALLOWED_ORIGINS")
- VITE_API_URL: $(env_get "$CABINET_ENV" "VITE_API_URL")

Next:
1) Put your reverse proxy in front of these ports.
2) If you enable payment providers, fill all required *_KEY/*_SECRET vars and rerun with --apply.
3) For next auto-import, put StealthNet dump into: $BACKUPS_DIR
EOF
