#!/usr/bin/env bash
# edh-deploy.sh <release-dir> <image> [--maint]
# Runs ON the server as root (sent by deploy.sh via SSM). Installs the release's host scripts and config,
# then swaps the app image: safety dump → migrations → up → /health → automatic rollback on failure.
# Exit: 0 deployed · 1 failed before the swap (old version still serving) · 2 unhealthy, rolled back · 3 site down
set -Eeuo pipefail
REL="${1:?release dir}"; IMAGE="${2:?image}"; MAINT="${3:-}"
EDH_BIN_DIR="${EDH_BIN_DIR:-/opt/edh/bin}"
EDH_ENV_FILE="${EDH_ENV_FILE:-/etc/edh/edh.env}"
install -d -m 755 "$EDH_BIN_DIR" "$(dirname "$EDH_ENV_FILE")"
install -m 755 "$REL"/host/edh-*.sh "$EDH_BIN_DIR"/
install -m 644 "$REL/release.env" "$EDH_ENV_FILE"
# shellcheck source-path=SCRIPTDIR source=edh-lib.sh
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh" || { echo "edh-deploy: cannot load edh-lib.sh" >&2; exit 1; }

install_units() {
  if [[ "${EDH_NO_SYSTEMD:-}" == 1 ]]; then return 0; fi
  install -m 644 "$REL"/host/systemd/* /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now edh-backup.timer edh-drill.timer >/dev/null
}

install_app_files() {
  # postgres/ is 755: the container's postgres user must traverse it; PGDATA below it is 0700 (set by the image)
  install -d -m 755 "$EDH_APP_DIR/caddy" "$EDH_APP_DIR/maint-templates" \
    "$EDH_DATA_DIR/caddy" "$EDH_DATA_DIR/maint" "$EDH_DATA_DIR/postgres"
  install -d -m 700 "$EDH_DATA_DIR/backups"   # database dumps are owner-only
  install -m 644 "$REL/app/compose.yml" "$EDH_APP_DIR/compose.yml"
  install -m 644 "$REL/app/Caddyfile" "$EDH_APP_DIR/caddy/Caddyfile"
  install -m 644 "$REL"/app/maint/*.html "$EDH_APP_DIR/maint-templates/"
  install -m 644 "$REL/app/maint/down.html" "$EDH_DATA_DIR/maint/down.html"
  if [[ ! -f "$EDH_DATA_DIR/maint/ON" ]]; then "$EDH_BIN_DIR/edh-maint.sh" render; fi
}

# write_secrets — SSM <path>/<name> → app.env NAME (dashes → underscores, upper case); _edh/* is internal.
# Values are never logged.
write_secrets() {
  local tmp name value key k pg_pw="" bypass=""
  tmp=$(mktemp)
  aws ssm get-parameters-by-path --region "$EDH_REGION" --path "$EDH_SSM_PATH/" --recursive --with-decryption \
    --query 'Parameters[].[Name,Value]' --output text > "$tmp"
  ( umask 077; : > "$EDH_APP_DIR/app.env.new" )
  while IFS=$'\t' read -r name value; do
    [[ -n "$name" ]] || continue
    key="${name#"$EDH_SSM_PATH"/}"
    case "$key" in
      _edh/postgres-password) pg_pw="$value" ;;
      _edh/maint-bypass) bypass="$value" ;;
      _edh/*|*/*) ;;
      *) k=$(printf '%s' "$key" | tr 'a-z-' 'A-Z_'); printf '%s=%s\n' "$k" "$value" >> "$EDH_APP_DIR/app.env.new" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  if [[ -z "$pg_pw" ]]; then rm -f "$EDH_APP_DIR/app.env.new"; die "$EDH_SSM_PATH/_edh/postgres-password is missing or empty — run provision.sh"; fi
  if [[ -z "$bypass" ]]; then rm -f "$EDH_APP_DIR/app.env.new"; die "$EDH_SSM_PATH/_edh/maint-bypass is missing or empty — run provision.sh"; fi
  if ! grep -q '^DATABASE_URL=' "$EDH_APP_DIR/app.env.new"; then
    echo "DATABASE_URL=postgres://app:${pg_pw}@postgres:5432/app" >> "$EDH_APP_DIR/app.env.new"
  fi
  mv "$EDH_APP_DIR/app.env.new" "$EDH_APP_DIR/app.env"
  ( umask 077; printf 'POSTGRES_USER=app\nPOSTGRES_DB=app\nPOSTGRES_PASSWORD=%s\n' "$pg_pw" > "$EDH_APP_DIR/postgres.env" )
  MAINT_BYPASS="$bypass"
}

# write_compose_env <image> — interpolation values for compose.yml (0600: holds the bypass token)
write_compose_env() {
  local profiles=""
  if [[ "${EDH_USES_GOTENBERG:-false}" == true ]]; then profiles=gotenberg; fi
  ( umask 077; cat > "$EDH_APP_DIR/.env.new" <<EOF
EDH_NAME=$EDH_NAME
APP_IMAGE=$1
APP_PORT=${EDH_APP_PORT:-3000}
APP_MEMORY_MB=${EDH_APP_MEMORY_MB:-768}
DOMAIN=$EDH_DOMAIN
MAINT_BYPASS=$MAINT_BYPASS
COMPOSE_PROFILES=$profiles
EDH_DATA_DIR=$EDH_DATA_DIR
EDH_HTTP_PORT=${EDH_HTTP_PORT:-80}
EDH_HTTPS_PORT=${EDH_HTTPS_PORT:-443}
EOF
  )
  mv "$EDH_APP_DIR/.env.new" "$EDH_APP_DIR/.env"
}

current_image() { sed -n 's/^APP_IMAGE=//p' "$EDH_APP_DIR/.env" 2>/dev/null || true; }

# wait_postgres — over TCP: during first-boot initdb the image runs a socket-only temporary server,
# which pg_isready over the socket would wrongly report as ready.
wait_postgres() {
  local _
  for _ in $(seq 1 30); do dc exec -T postgres pg_isready -q -h 127.0.0.1 -U app -d app 2>/dev/null && return 0; sleep 2; done
  die "postgres did not become ready"
}

reload_caddy() {
  local _
  for _ in 1 2 3 4 5; do
    dc exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 && return 0
    sleep 2
  done
  die "Caddy rejected the Caddyfile — previous config still active"
}

prune_images() { # keep the 3 newest images of this repo
  local n=0 ref
  docker image ls "${1%:*}" --format '{{.Repository}}:{{.Tag}}' | while read -r ref; do
    n=$((n + 1))
    if (( n > 3 )); then docker image rm "$ref" >/dev/null 2>&1 || true; fi
  done
  docker image prune -f >/dev/null
}

maint_on=0
finish_maint() { if (( maint_on )); then "$EDH_BIN_DIR/edh-maint.sh" off >/dev/null; fi; }

install_units
install_app_files
write_secrets
PREV=$(current_image)

if [[ "${EDH_SKIP_PULL:-}" != 1 ]]; then
  aws ecr get-login-password --region "$EDH_REGION" | docker login --username AWS --password-stdin "${IMAGE%%/*}" >/dev/null
  docker pull -q "$IMAGE" >/dev/null
fi

write_compose_env "${PREV:-$IMAGE}"
services="caddy postgres"
if [[ "${EDH_USES_GOTENBERG:-false}" == true ]]; then services="$services gotenberg"; fi
# shellcheck disable=SC2086
dc up -d --remove-orphans $services
reload_caddy
wait_postgres

if [[ -n "$PREV" ]]; then
  "$EDH_BIN_DIR/edh-backup.sh" --tag safety --force >/dev/null || die "pre-deploy backup failed — not deploying"
fi
if [[ "$MAINT" == --maint ]]; then
  "$EDH_BIN_DIR/edh-maint.sh" on --message "We're upgrading the system." --until "in a few minutes" >/dev/null
  maint_on=1
fi
if [[ -n "${EDH_MIGRATE_CMD:-}" ]]; then
  log "running migrations with $IMAGE"
  if ! APP_IMAGE="$IMAGE" dc run --rm --no-deps -T app sh -c "$EDH_MIGRATE_CMD"; then
    finish_maint
    alert "deploy failed" "Migrations failed for $IMAGE. The previous version is still running."
    exit 1
  fi
fi

write_compose_env "$IMAGE"
dc up -d app
if wait_health 30; then
  finish_maint
  if [[ -n "$PREV" && "$PREV" != "$IMAGE" ]]; then printf '%s\n' "$PREV" > "$EDH_APP_DIR/previous_image"; fi
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$IMAGE" "${PREV:--}" >> "$EDH_DATA_DIR/deploys.log"
  prune_images "$IMAGE"
  log "deployed $IMAGE"
  exit 0
fi

log "health check failed for $IMAGE"
if [[ -n "$PREV" && "$PREV" != "$IMAGE" ]]; then
  write_compose_env "$PREV"
  dc up -d app
  if wait_health 30; then
    finish_maint
    alert "deploy rolled back" "$IMAGE failed its health check; rolled back to $PREV."
    exit 2
  fi
  alert "SITE DOWN after deploy" "Both $IMAGE and $PREV fail /health."
  exit 3
fi
alert "deploy failed" "$IMAGE fails /health and there is no previous version."
exit 3
