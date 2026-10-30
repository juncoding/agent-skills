#!/usr/bin/env bash
# edh-deploy.sh <release-dir> <image> [--maint]
# Runs ON the server as root (sent by deploy.sh via SSM). Installs the release's host scripts and config,
# then swaps the app image: validate release → safety dump → migrations → up → /health → automatic rollback.
# Exit: 0 deployed · 1 failed before the swap (old version still serving, previous configuration restored)
#       · 2 unhealthy, rolled back · 3 site down
# Every failure sends an alert. An unexpected exit restores the previous configuration (EXIT trap).
set -Eeuo pipefail
REL="${1:?release dir}"; IMAGE="${2:?image}"; MAINT="${3:-}"
EDH_BIN_DIR="${EDH_BIN_DIR:-/opt/edh/bin}"
EDH_ENV_FILE="${EDH_ENV_FILE:-/etc/edh/edh.env}"
# The lock comes before installing anything, so it is taken with the release's own copy of edh-lib.sh;
# the installed copy (with the new release.env) is loaded once the release is in place.
# shellcheck source-path=SCRIPTDIR source=edh-lib.sh
. "$REL/host/edh-lib.sh" || { echo "edh-deploy: cannot load the release's edh-lib.sh" >&2; exit 1; }

# --- state for the EXIT trap
SAVED=0       # 1 once the current config is copied to *.prev
INFRA=0       # 1 once caddy/postgres may be running from the release's files
SWAPPED=0     # 1 once the app may be running the new image
DEPLOYED=0    # 1 once the new image passed its health check: nothing after that rolls it back
EXPECTED=0    # 1 when exiting through done_exit (a planned outcome)
maint_on=0
STAGE=""
PREV=""
services="caddy postgres"
KEPT=".env app.env postgres.env compose.yml caddy/Caddyfile"   # restored from *.prev on an unexpected exit

done_exit() { EXPECTED=1; exit "$1"; }
reload_caddy_once() { dc exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || log "caddy reload failed"; }
finish_maint() { if (( maint_on )); then "$EDH_BIN_DIR/edh-maint.sh" off >/dev/null; maint_on=0; fi; }

save_prev() { # copy the live config to *.prev before changing anything
  local f
  for f in $KEPT; do
    if [[ -f "$EDH_APP_DIR/$f" ]]; then cp -p "$EDH_APP_DIR/$f" "$EDH_APP_DIR/$f.prev"; else rm -f "$EDH_APP_DIR/$f.prev"; fi
  done
  SAVED=1
}
# restore_prev [--saved-only] <file>... — put back the copies made by save_prev. A file without a copy didn't exist
# before this deploy (save_prev removes stale copies) and is removed — except with --saved-only (the rollback
# branch), which only restores what was saved and never deletes.
restore_prev() {
  local f only=0
  if [[ "${1:-}" == --saved-only ]]; then only=1; shift; fi
  (( SAVED )) || return 0
  for f in "$@"; do
    if [[ -f "$EDH_APP_DIR/$f.prev" ]]; then cp -p "$EDH_APP_DIR/$f.prev" "$EDH_APP_DIR/$f"
    elif (( ! only )); then rm -f "$EDH_APP_DIR/$f"; fi
  done
}

# revert_infra [--no-health] — after restore_prev: caddy/postgres may already run from the release's files, so
# bring the previous ones back (only if they were touched). Non-zero if the app then fails /health.
revert_infra() {
  if (( INFRA )); then
    # shellcheck disable=SC2086
    dc up -d --remove-orphans $services >/dev/null 2>&1 || log "could not restart $services with the previous configuration"
    reload_caddy_once
  fi
  if [[ "${1:-}" == --no-health ]] || (( ! INFRA )); then return 0; fi
  wait_health
}

# restore_env_file — put back the previous /etc/edh/edh.env (saved before the release's was installed) and load
# it again, so health checks after an abort use the settings (e.g. the app port) the previous version runs with
restore_env_file() {
  (( ENV_SAVED )) || return 0
  cp -p "$EDH_ENV_FILE.prev" "$EDH_ENV_FILE" || { log "could not restore $EDH_ENV_FILE"; return 0; }
  # shellcheck disable=SC1090
  . "$EDH_ENV_FILE"
}

# abort_first_deploy <subject> <message> — an abort with no previous version: nothing was serving, so there is
# nothing to health-check or fall back to
abort_first_deploy() {
  revert_infra --no-health
  finish_maint || true
  alert "$1" "$2 There is no previous version — nothing was serving."
  log "no previous version — nothing was serving"
  EXPECTED=1; exit 1
}

on_exit() {
  local rc=$? line="${EDH_DIE_LINE:-$1}"
  trap - EXIT
  if [[ -n "$STAGE" ]]; then rm -rf "$STAGE"; fi
  if (( EXPECTED || rc == 0 )); then exit "$rc"; fi
  if (( DEPLOYED )); then
    alert "deploy: follow-up step failed at line $line" "$IMAGE is deployed and healthy, but a step after the health check failed (exit $rc). See the deploy output."
    exit 0
  fi
  log "deploy aborted at line $line (exit $rc): restoring the previous configuration"
  # shellcheck disable=SC2086
  restore_prev $KEPT
  restore_env_file
  if [[ -z "$PREV" ]]; then
    abort_first_deploy "deploy aborted at line $line" "Deploying $IMAGE stopped at line $line (exit $rc)."
  fi
  if (( SWAPPED )); then
    dc up -d app >/dev/null 2>&1 || log "could not restart the app with the previous configuration"
    reload_caddy_once
    if wait_health; then
      finish_maint || true
      alert "deploy aborted at line $line" "Deploying $IMAGE stopped unexpectedly after the switch (exit $rc); the previous version (${PREV:-none}) was restored and is healthy."
      exit 2
    fi
    # with --maint, maintenance stays ON: users see the maintenance page rather than down.html
    alert "SITE DOWN after deploy" "Deploying $IMAGE stopped unexpectedly at line $line (exit $rc) after the switch, and the restored previous version (${PREV:-none}) fails /health."
    exit 3
  fi
  if ! revert_infra; then
    # with --maint, maintenance stays ON: users see the maintenance page rather than down.html
    alert "SITE DOWN after deploy" "Deploying $IMAGE stopped at line $line (exit $rc) after $services were updated; with the previous configuration restored the app still fails /health."
    exit 3
  fi
  finish_maint || true
  alert "deploy aborted at line $line" "Deploying $IMAGE failed before the switch (exit $rc); the previous version is still running. See the deploy output."
  exit 1
}
# the image running now (empty on a first deploy), known before anything can fail
PREV=$(sed -n 's/^APP_IMAGE=//p' "$EDH_APP_DIR/.env" 2>/dev/null || true)
ENV_SAVED=0   # 1 once the previous edh.env is saved as edh.env.prev
trap 'on_exit $LINENO' EXIT
edh_lock
install -d -m 755 "$EDH_BIN_DIR" "$(dirname "$EDH_ENV_FILE")"
install -m 755 "$REL"/host/edh-*.sh "$EDH_BIN_DIR"/
if [[ -f "$EDH_ENV_FILE" ]]; then cp -p "$EDH_ENV_FILE" "$EDH_ENV_FILE.prev" && ENV_SAVED=1; fi
install -m 644 "$REL/release.env" "$EDH_ENV_FILE"
# shellcheck source-path=SCRIPTDIR source=edh-lib.sh
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh" || { echo "edh-deploy: cannot load edh-lib.sh" >&2; exit 1; }

install_units() {
  if [[ "${EDH_NO_SYSTEMD:-}" == 1 ]]; then return 0; fi
  install -m 644 "$REL"/host/systemd/* /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now edh-backup.timer edh-drill.timer >/dev/null
}

# write_env_file <path> — stdin → <path>, mode 0600 (also tightens an existing file), replaced atomically
write_env_file() {
  ( umask 077; cat > "$1.new" )
  chmod 600 "$1.new"
  mv -f "$1.new" "$1"
}

# parse_params — SSM get-parameters-by-path JSON (stdin) → "name<TAB>value" lines.
# Values with a newline or tab can't be passed safely: fail, naming the parameters (never the values).
PARSE_PARAMS='import json, sys
params = json.load(sys.stdin).get("Parameters") or []
bad = [p["Name"] for p in params if any(c in p.get("Value", "") for c in "\n\r\t")]
if bad:
    sys.stderr.write("parameter value contains a newline or tab (not allowed): " + ", ".join(bad) + "\n")
    sys.exit(2)
for p in params:
    sys.stdout.write(p["Name"] + "\t" + p.get("Value", "") + "\n")'

# write_secrets — SSM <path>/<name> → app.env NAME (dashes → underscores, upper case); _edh/* is internal.
# Then DATABASE_URL and the app_env_defaults, each only where the app hasn't set that name. Values are never logged.
write_secrets() {
  local params name value key k pg_pw="" bypass="" lines="" defaults
  params=$(aws ssm get-parameters-by-path --region "$EDH_REGION" --path "$EDH_SSM_PATH/" --recursive \
    --with-decryption --output json | python3 -I -c "$PARSE_PARAMS") \
    || die "could not read the parameters under $EDH_SSM_PATH/ (see above)"
  while IFS=$'\t' read -r name value; do
    [[ -n "$name" ]] || continue
    key="${name#"$EDH_SSM_PATH"/}"
    case "$key" in
      _edh/postgres-password) pg_pw="$value" ;;
      _edh/maint-bypass) bypass="$value" ;;
      _edh/*|*/*) ;;
      *) k=$(printf '%s' "$key" | tr 'a-z-' 'A-Z_'); lines="$lines$k=$value"$'\n' ;;
    esac
  done <<< "$params"
  [[ -n "$pg_pw" ]] || die "$EDH_SSM_PATH/_edh/postgres-password is missing or empty — run provision.sh"
  [[ -n "$bypass" ]] || die "$EDH_SSM_PATH/_edh/maint-bypass is missing or empty — run provision.sh"
  [[ "$pg_pw" =~ ^[A-Za-z0-9]+$ ]] || die "$EDH_SSM_PATH/_edh/postgres-password must be letters and digits only"
  [[ "$bypass" =~ ^[A-Za-z0-9]+$ ]] || die "$EDH_SSM_PATH/_edh/maint-bypass must be letters and digits only"
  if [[ "$lines" != *$'\n'DATABASE_URL=* && "$lines" != DATABASE_URL=* ]]; then
    lines="${lines}DATABASE_URL=postgres://app:${pg_pw}@postgres:5432/app"$'\n'
  fi
  # AWS_REGION, EDH_UPLOADS_BUCKET, GOTENBERG_URL — unless the app set them itself
  defaults=$(printf '%s' "$lines" | app_env_defaults)
  if [[ -n "$defaults" ]]; then lines="$lines$defaults"$'\n'; fi
  printf '%s' "$lines" | write_env_file "$EDH_APP_DIR/app.env"
  printf 'POSTGRES_USER=app\nPOSTGRES_DB=app\nPOSTGRES_PASSWORD=%s\n' "$pg_pw" | write_env_file "$EDH_APP_DIR/postgres.env"
  MAINT_BYPASS="$bypass"
}

# write_compose_env <image> [dir] — interpolation values for compose.yml (0600: holds the bypass token)
write_compose_env() {
  local profiles=""
  if [[ "${EDH_USES_GOTENBERG:-false}" == true ]]; then profiles=gotenberg; fi
  write_env_file "${2:-$EDH_APP_DIR}/.env" <<EOF
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
}

# caddy_image — the image of the caddy service in the staged compose.yml (so the Caddyfile is validated by the
# Caddy version that will run it); caddy:2.10-alpine if it can't be read
CADDY_IMAGE_PY='import json, re, sys
img = (json.load(sys.stdin).get("services", {}).get("caddy") or {}).get("image") or ""
print(img if re.match(r"^[A-Za-z0-9][A-Za-z0-9._/:@-]*$", img) else "")'
caddy_image() {
  local img
  img=$(docker compose --project-directory "$STAGE" -f "$STAGE/compose.yml" config --format json 2>/dev/null \
    | python3 -I -c "$CADDY_IMAGE_PY" 2>/dev/null) || img=""
  if [[ -z "$img" ]]; then
    img=caddy:2.10-alpine
    log "could not read the caddy image from the release's compose.yml: validating the Caddyfile with $img"
  fi
  printf '%s' "$img"
}

# validate_release — check the release's compose.yml and Caddyfile in a staging dir before installing anything
validate_release() {
  local out caddy_img
  STAGE=$(mktemp -d)
  mkdir "$STAGE/caddy"
  cp "$REL/app/compose.yml" "$STAGE/compose.yml"
  cp "$REL/app/Caddyfile" "$STAGE/caddy/Caddyfile"
  cp -p "$EDH_APP_DIR/app.env" "$EDH_APP_DIR/postgres.env" "$STAGE/"
  write_compose_env "${PREV:-$IMAGE}" "$STAGE"
  out=$(docker compose --project-directory "$STAGE" -f "$STAGE/compose.yml" config -q 2>&1) \
    || { printf '%s\n' "$out" | tail -20 >&2; die "the release's compose.yml is invalid — nothing installed"; }
  caddy_img=$(caddy_image)
  # values through the environment, not the command line; the token is masked in any error output
  out=$(DOMAIN="$EDH_DOMAIN" MAINT_BYPASS="$MAINT_BYPASS" APP_PORT="${EDH_APP_PORT:-3000}" \
    docker run --rm -e DOMAIN -e MAINT_BYPASS -e APP_PORT -v "$STAGE/caddy:/etc/caddy:ro" "$caddy_img" \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1) \
    || { printf '%s\n' "$out" | sed "s/$MAINT_BYPASS/<bypass-token>/g" | tail -20 >&2
         die "the release's Caddyfile is invalid — nothing installed"; }
}

install_app_files() {
  # postgres/ is 755: the container's postgres user must traverse it; PGDATA below it is 0700 (set by the image)
  install -d -m 755 "$EDH_APP_DIR/caddy" "$EDH_APP_DIR/maint-templates" \
    "$EDH_DATA_DIR/caddy" "$EDH_DATA_DIR/maint" "$EDH_DATA_DIR/postgres"
  install -d -m 700 "$EDH_DATA_DIR/backups"   # database dumps are owner-only
  install -m 644 "$STAGE/compose.yml" "$EDH_APP_DIR/compose.yml"
  install -m 644 "$STAGE/caddy/Caddyfile" "$EDH_APP_DIR/caddy/Caddyfile"
  install -m 644 "$REL"/app/maint/*.html "$EDH_APP_DIR/maint-templates/"
  install -m 644 "$REL/app/maint/down.html" "$EDH_DATA_DIR/maint/down.html"
  if [[ ! -f "$EDH_DATA_DIR/maint/ON" ]]; then "$EDH_BIN_DIR/edh-maint.sh" render; fi
}

# record_previous — for edh-rollback.sh: the image this deploy replaced, and the app.env it ran with
record_previous() {
  printf '%s\n' "$PREV" > "$EDH_APP_DIR/previous_image" \
    && { [[ ! -f "$EDH_APP_DIR/app.env.prev" ]] || cp -p "$EDH_APP_DIR/app.env.prev" "$EDH_APP_DIR/app.env.rollback"; }
}

current_image() { sed -n 's/^APP_IMAGE=//p' "$EDH_APP_DIR/.env" 2>/dev/null || true; }

# wait_postgres — the app database itself answers over TCP. During first-boot init the image runs a
# socket-only temporary server, and the app database does not exist until init has created it.
wait_postgres() {
  local _
  for _ in $(seq 1 30); do
    dc exec -T postgres psql -h 127.0.0.1 -U app -d app -tAc 'select 1' >/dev/null 2>&1 && return 0
    sleep 2
  done
  die "postgres did not become ready (the app database does not answer)"
}

reload_caddy() {
  local _
  for _ in 1 2 3 4 5; do
    dc exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 && return 0
    sleep 2
  done
  die "Caddy rejected the Caddyfile — previous config still active"
}

# migrate — run EDH_MIGRATE_CMD in a one-off container of the new image (15 min limit where `timeout` exists)
migrate() {
  if command -v timeout >/dev/null 2>&1; then
    APP_IMAGE="$IMAGE" timeout 900 docker compose --project-directory "$EDH_APP_DIR" -f "$EDH_APP_DIR/compose.yml" \
      run --rm --no-deps -T app sh -c "$EDH_MIGRATE_CMD"
  else
    APP_IMAGE="$IMAGE" dc run --rm --no-deps -T app sh -c "$EDH_MIGRATE_CMD"
  fi
}

prune_images() { # keep the 3 newest images of this repo, never the current or the previous one
  if [[ "${EDH_SKIP_PRUNE:-}" == 1 ]]; then return 0; fi
  local n=0 ref keep_prev
  keep_prev=$(cat "$EDH_APP_DIR/previous_image" 2>/dev/null || true)
  docker image ls "${1%:*}" --format '{{.Repository}}:{{.Tag}}' | while read -r ref; do
    n=$((n + 1))
    if (( n > 3 )) && [[ "$ref" != "$1" && "$ref" != "$keep_prev" ]]; then docker image rm "$ref" >/dev/null 2>&1 || true; fi
  done
  docker image prune -f >/dev/null
}

install_units
PREV=$(current_image)
# rollback target: the running image, or — when the same image is redeployed — the one before it
ROLLBACK=""
if [[ -n "$PREV" && "$PREV" != "$IMAGE" ]]; then
  ROLLBACK="$PREV"
else
  ROLLBACK=$(cat "$EDH_APP_DIR/previous_image" 2>/dev/null || true)
  if [[ "$ROLLBACK" == "$IMAGE" ]]; then ROLLBACK=""; fi
fi
install -d -m 755 "$EDH_APP_DIR"
save_prev
write_secrets
# log in to the registry first: the Caddyfile check may pull a caddy image from it
if [[ "${EDH_SKIP_PULL:-}" != 1 ]]; then
  aws ecr get-login-password --region "$EDH_REGION" | docker login --username AWS --password-stdin "${IMAGE%%/*}" >/dev/null
fi
validate_release
install_app_files

if [[ "${EDH_SKIP_PULL:-}" != 1 ]]; then docker pull -q "$IMAGE" >/dev/null; fi

write_compose_env "${PREV:-$IMAGE}"
if [[ "${EDH_USES_GOTENBERG:-false}" == true ]]; then services="$services gotenberg"; fi
INFRA=1   # set just before the `up`, so a failing `up` is restored too
# shellcheck disable=SC2086
dc up -d --remove-orphans $services
reload_caddy
wait_postgres   # the app database exists from here on, so there is always something to back up

if [[ "$MAINT" == --maint ]]; then
  "$EDH_BIN_DIR/edh-maint.sh" on --message "We're upgrading the system." --until "in a few minutes" >/dev/null
  maint_on=1
fi
"$EDH_BIN_DIR/edh-backup.sh" --tag safety --force >/dev/null || die "pre-deploy backup failed — not deploying"
if [[ -n "${EDH_MIGRATE_CMD:-}" ]]; then
  log "running migrations with $IMAGE"
  if ! migrate; then
    # like every abort before the switch: the previous configuration back (env files, compose.yml, Caddyfile,
    # edh.env), and caddy/postgres re-upped with it; the old app version keeps serving
    log "migrations failed: restoring the previous configuration"
    # shellcheck disable=SC2086
    restore_prev $KEPT
    restore_env_file
    if [[ -z "$PREV" ]]; then abort_first_deploy "deploy failed" "Migrations failed for $IMAGE."; fi
    if ! revert_infra; then
      alert "SITE DOWN after deploy" "Migrations failed for $IMAGE, and with the previous configuration restored the app fails /health."
      done_exit 3
    fi
    finish_maint
    alert "deploy failed" "Migrations failed for $IMAGE. The previous version is still running with its previous configuration."
    done_exit 1
  fi
fi

SWAPPED=1
write_compose_env "$IMAGE"
if dc up -d app && wait_health; then
  DEPLOYED=1   # healthy: from here on everything is best-effort bookkeeping
  finish_maint || log "could not switch maintenance off — run: edh-maint.sh off"
  if [[ -n "$PREV" && "$PREV" != "$IMAGE" ]]; then record_previous || log "could not record the previous image for edh-rollback.sh"; fi
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$IMAGE" "${PREV:--}" >> "$EDH_DATA_DIR/deploys.log" \
    || log "could not append to deploys.log"
  prune_images "$IMAGE" || log "image cleanup failed (not fatal)"
  log "deployed $IMAGE"
  done_exit 0
fi

log "health check failed for $IMAGE"
if [[ -n "$ROLLBACK" ]]; then
  restore_prev --saved-only app.env postgres.env   # roll back with the secrets it ran with (if they were saved)
  write_compose_env "$ROLLBACK"
  if dc up -d app && wait_health; then
    finish_maint
    alert "deploy rolled back" "$IMAGE failed to start or failed its health check; rolled back to $ROLLBACK."
    done_exit 2
  fi
  # with --maint, maintenance is deliberately left ON: users see the maintenance page rather than down.html
  alert "SITE DOWN after deploy" "Both $IMAGE and $ROLLBACK fail /health."
  done_exit 3
fi
alert "deploy failed" "$IMAGE fails /health and there is no previous version."
done_exit 3
