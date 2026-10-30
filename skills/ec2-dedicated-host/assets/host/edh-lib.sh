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

log() { printf '[edh %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

dc() { docker compose --project-directory "$EDH_APP_DIR" -f "$EDH_APP_DIR/compose.yml" "$@"; }
# pg <sql> [database] — run SQL as the app superuser inside the postgres container
pg() { dc exec -T postgres psql -v ON_ERROR_STOP=1 -U app -d "${2:-app}" -tAc "$1"; }

# alert <subject> <message> — email through SNS when monitoring is on; always logged. Never aborts.
alert() {
  log "ALERT: $1 — $2"
  if [[ -z "${EDH_ALERT_TOPIC_ARN:-}" ]]; then return 0; fi
  if [[ -z "${EDH_REGION:-}" ]]; then log "alert not sent: EDH_REGION is not set"; return 0; fi
  aws sns publish --region "$EDH_REGION" --topic-arn "$EDH_ALERT_TOPIC_ARN" \
    --subject "[${EDH_NAME:-edh}] $1" --message "$2" >/dev/null || log "sns publish failed"
}

# metric <name> [value] — custom metric in namespace EDH (watched by the backup alarm). Never aborts.
metric() {
  if [[ -z "${EDH_REGION:-}" || -z "${EDH_CLIENT:-}" || -z "${EDH_ENV:-}" ]]; then
    log "metric $1 not published: EDH_REGION, EDH_CLIENT or EDH_ENV is not set"; return 0
  fi
  aws cloudwatch put-metric-data --region "$EDH_REGION" --namespace EDH --metric-name "$1" \
    --dimensions "Client=$EDH_CLIENT,Env=$EDH_ENV" --value "${2:-1}" || log "metric $1 not published"
}

# wait_health [tries] — app /health through the compose network (2 s apart)
wait_health() {
  local _
  for _ in $(seq 1 "${1:-30}"); do
    if dc exec -T caddy wget -q -O /dev/null "http://app:${EDH_APP_PORT:-3000}/health" 2>/dev/null; then return 0; fi
    sleep 2
  done
  return 1
}

html_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"; }
