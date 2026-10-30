#!/usr/bin/env bash
# Shared helpers for ec2-dedicated-host scripts that run ON the server. Source, don't run.
set -Eeuo pipefail
export PATH="${PATH:+$PATH:}/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EDH_ENV_FILE="${EDH_ENV_FILE:-/etc/edh/edh.env}"
# shellcheck disable=SC1090
if [[ -f "$EDH_ENV_FILE" ]]; then . "$EDH_ENV_FILE"; fi
EDH_APP_DIR="${EDH_APP_DIR:-/opt/edh/app}"
EDH_DATA_DIR="${EDH_DATA_DIR:-/data}"
EDH_BIN_DIR="${EDH_BIN_DIR:-/opt/edh/bin}"
# The backup manifest: one line per uploaded dump, "<s3-key>\t<sha256>\t<VersionId>\t<UTC time>", written only by
# edh-backup.sh. It lives in /data/backups (0700, root), which no container mounts: a compromised app can add
# objects to the bucket through the instance role, but cannot add them to the manifest, and restores verify
# against it.
EDH_MANIFEST="${EDH_MANIFEST:-$EDH_DATA_DIR/backups/manifest.tsv}"

log() { printf '[edh %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
# die <message> — log and exit 1; EDH_DIE_LINE = the caller's line, for EXIT traps that report where it stopped
# shellcheck disable=SC2034  # read by the EXIT traps of the scripts that source this
die() { EDH_DIE_LINE="${BASH_LINENO[0]:-}"; log "ERROR: $*"; exit 1; }

dc() { docker compose --project-directory "$EDH_APP_DIR" -f "$EDH_APP_DIR/compose.yml" "$@"; }
# pg <sql> [database] — run SQL as the app superuser inside the postgres container
pg() { dc exec -T postgres psql -v ON_ERROR_STOP=1 -U app -d "${2:-app}" -tAc "$1"; }

# edh_lock — one edh operation at a time (deploy, backup, restore, drill), waiting up to 10 min.
# The lock is held on fd 9 until the script exits; nested edh scripts see EDH_LOCK_HELD=1 and don't lock again.
edh_lock() {
  if [[ "${EDH_LOCK_HELD:-}" == 1 ]]; then return 0; fi
  export EDH_LOCK_HELD=1
  if ! command -v flock >/dev/null 2>&1; then log "flock not installed: running without the edh lock"; return 0; fi
  exec 9>"${EDH_LOCK_FILE:-/run/edh.lock}"
  flock -w 600 9 || die "another edh operation is running (waited 10 min for ${EDH_LOCK_FILE:-/run/edh.lock})"
}

# alert <subject> <message> — email through SNS when monitoring is on; always logged. Never aborts.
alert() {
  log "ALERT: $1 — $2"
  if [[ -z "${EDH_ALERT_TOPIC_ARN:-}" ]]; then return 0; fi
  if [[ -z "${EDH_REGION:-}" ]]; then log "alert not sent: EDH_REGION is not set"; return 0; fi
  aws sns publish --region "$EDH_REGION" --topic-arn "$EDH_ALERT_TOPIC_ARN" \
    --subject "[${EDH_NAME:-edh}] $1" --message "$2" >/dev/null || log "sns publish failed"
}

# metric <name> [value] — custom metric in namespace EDH/<name>, one per client: the host policy allows only
# its own (watched by the backup alarm). Never aborts.
metric() {
  if [[ -z "${EDH_REGION:-}" || -z "${EDH_NAME:-}" || -z "${EDH_CLIENT:-}" || -z "${EDH_ENV:-}" ]]; then
    log "metric $1 not published: EDH_REGION, EDH_NAME, EDH_CLIENT or EDH_ENV is not set"; return 0
  fi
  aws cloudwatch put-metric-data --region "$EDH_REGION" --namespace "EDH/$EDH_NAME" --metric-name "$1" \
    --dimensions "Client=$EDH_CLIENT,Env=$EDH_ENV" --value "${2:-1}" || log "metric $1 not published"
}

# wait_health [tries] — app /health through the compose network (2 s apart; default EDH_HEALTH_TRIES or 30)
wait_health() {
  local _
  for _ in $(seq 1 "${1:-${EDH_HEALTH_TRIES:-30}}"); do
    if dc exec -T caddy wget -q -T 5 -O /dev/null "http://app:${EDH_APP_PORT:-3000}/health" 2>/dev/null; then return 0; fi
    sleep 2
  done
  return 1
}

# backup_schedule — hourly|daily from EDH_BACKUP_SCHEDULE; auto = hourly while the database is under 2 GB
backup_schedule() {
  local size
  case "${EDH_BACKUP_SCHEDULE:-auto}" in
    hourly|daily) echo "$EDH_BACKUP_SCHEDULE"; return 0 ;;
    auto) ;;
    *) die "EDH_BACKUP_SCHEDULE must be auto, hourly or daily (got '${EDH_BACKUP_SCHEDULE}')" ;;
  esac
  size=$(pg "select pg_database_size('app')")
  if (( size < 2147483648 )); then echo hourly; else echo daily; fi
}
# fresh_minutes <hourly|daily> — how old the newest backup may be before it counts as stale
fresh_minutes() { if [[ "$1" == hourly ]]; then echo 120; else echo 1560; fi; }

html_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"; }

# sha256_of <file> — hex SHA-256 (sha256sum on the server; shasum on macOS, for the tests)
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
