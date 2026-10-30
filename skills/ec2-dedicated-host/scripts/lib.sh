#!/usr/bin/env bash
# Shared helpers for ec2-dedicated-host local scripts (run on the operator's machine). Source, don't run.
# Must stay compatible with macOS bash 3.2.
# shellcheck disable=SC2034  # EDH_* globals set here are read by the scripts that source this file.
set -euo pipefail

EDH_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# cfg_get <file> <key> [default] — value of a flat `key: value` line; strips quotes and trailing comments.
cfg_get() {
  local file="$1" key="$2" def="${3-}" val
  val=$(awk -v k="$key" '
    BEGIN { q = sprintf("%c", 39) }
    $0 ~ "^" k ":" {
      sub("^" k ":[ \t]*", ""); sub(/\r$/, ""); sub(/[ \t]+#.*$/, ""); sub(/[ \t]+$/, "")
      f = substr($0, 1, 1)
      if ((f == "\"" || f == q) && length($0) >= 2) $0 = substr($0, 2, length($0) - 2)
      print; exit
    }' "$file")
  printf '%s' "${val:-$def}"
}

# load_config [path] — read deploy.yml into EDH_* variables and validate them.
load_config() {
  local f="${1:-deploy/deploy.yml}"
  [[ -f "$f" ]] || die "config not found: $f (run from the project root, or create it with init.sh)"
  EDH_CONFIG="$f"
  EDH_CLIENT=$(cfg_get "$f" client)
  EDH_ENV=$(cfg_get "$f" env prod)
  EDH_REGION=$(cfg_get "$f" region ap-southeast-1)
  EDH_DOMAIN=$(cfg_get "$f" domain)
  EDH_ALERT_EMAILS=$(cfg_get "$f" alert_emails)
  EDH_MONITORING=$(cfg_get "$f" monitoring cloudwatch)
  EDH_INSTANCE_TYPE=$(cfg_get "$f" instance_type auto)
  EDH_DATA_GB=$(cfg_get "$f" data_volume_gb 20)
  EDH_APP_PORT=$(cfg_get "$f" app_port 3000)
  EDH_APP_MEMORY_MB=$(cfg_get "$f" app_memory_mb 768)
  EDH_USES_GOTENBERG=$(cfg_get "$f" uses_gotenberg false)
  EDH_BACKUP_SCHEDULE=$(cfg_get "$f" backup_schedule auto)
  EDH_DAILY_HOUR_UTC=$(cfg_get "$f" daily_backup_hour_utc 18)
  EDH_MIGRATE_CMD=$(cfg_get "$f" migrate_cmd "")
  EDH_DOCKERFILE=$(cfg_get "$f" dockerfile Dockerfile)
  EDH_BUILD_CONTEXT=$(cfg_get "$f" build_context .)
  validate_config
  EDH_NAME="${EDH_CLIENT}-${EDH_ENV}"
  EDH_PREFIX="edh-${EDH_NAME}"
  EDH_SSM_PATH="/${EDH_CLIENT}/${EDH_ENV}"
  EDH_ECR_REPO="edh/${EDH_CLIENT}"
}

validate_config() {
  [[ "$EDH_CLIENT" =~ ^[a-z][a-z0-9-]{1,20}$ ]] || die "client must be 2-21 lowercase letters/digits/dashes: '$EDH_CLIENT'"
  [[ "$EDH_ENV" =~ ^[a-z][a-z0-9]{1,9}$ ]] || die "env must be 2-10 lowercase letters/digits: '$EDH_ENV'"
  [[ "$EDH_DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || die "domain looks invalid: '$EDH_DOMAIN'"
  [[ "$EDH_MONITORING" == cloudwatch || "$EDH_MONITORING" == none ]] || die "monitoring must be cloudwatch or none"
  [[ "$EDH_BACKUP_SCHEDULE" =~ ^(auto|hourly|daily)$ ]] || die "backup_schedule must be auto, hourly or daily"
  [[ "$EDH_USES_GOTENBERG" == true || "$EDH_USES_GOTENBERG" == false ]] || die "uses_gotenberg must be true or false"
  [[ "$EDH_DATA_GB" =~ ^[0-9]+$ ]] && (( EDH_DATA_GB >= 8 )) || die "data_volume_gb must be a number >= 8"
  [[ "$EDH_APP_MEMORY_MB" =~ ^[0-9]+$ ]] || die "app_memory_mb must be a number"
  [[ "$EDH_APP_PORT" =~ ^[0-9]+$ ]] || die "app_port must be a number"
  [[ "$EDH_DAILY_HOUR_UTC" =~ ^[0-9]+$ ]] && (( EDH_DAILY_HOUR_UTC < 24 )) || die "daily_backup_hour_utc must be 0-23"
  [[ "$EDH_MIGRATE_CMD" != *"'"* ]] || die "migrate_cmd must not contain single quotes"
  if [[ "$EDH_MONITORING" == cloudwatch && -z "$EDH_ALERT_EMAILS" ]]; then
    die "alert_emails required when monitoring: cloudwatch"
  fi
}
