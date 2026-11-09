#!/usr/bin/env bash
# edh-deploy.sh <release-dir> <image> [--maint] [--no-rollback]
# Runs ON the server as root (sent by deploy.sh via SSM). Installs the release's host scripts and config,
# then swaps the app image: validate release → safety dump → migrations → up → /health → automatic rollback.
#   --no-rollback  for a release whose migrations the previous version can't run on. The schema is compared
#                  before and after the migrations; once they have changed it, nothing starts the previous
#                  image again: a failure leaves maintenance ON and the state as it is (exit 4), the replaced
#                  image goes into the rollback guard (edh-lib.sh), and a migration that failed without
#                  changing the schema also keeps maintenance ON (exit 5).
# Exit: 0 deployed · 1 failed before the swap (old version still serving, previous configuration restored)
#       · 2 unhealthy, rolled back · 3 site down
#       · 4 failed after the migrations changed the schema (or with no compatible image to roll back to):
#         maintenance ON, previous image not started · 5 (--no-rollback) migrations failed, schema unchanged,
#         previous version still running behind maintenance
# Every failure sends an alert. An unexpected exit restores the previous configuration (EXIT trap), except
# after the migrations changed the schema (exit 4).
set -Eeuo pipefail
REL="${1:?release dir}"; IMAGE="${2:?image}"; shift 2
MAINT="" NO_ROLLBACK=0
for a in "$@"; do
  case "$a" in
    --maint) MAINT=--maint ;;
    --no-rollback) NO_ROLLBACK=1 ;;
    *) echo "edh-deploy: unknown option: $a" >&2; exit 1 ;;
  esac
done
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
ADVANCED=0    # 1 once (--no-rollback) the migrations changed the schema: the previous image never runs again
KEEP_MAINT=0  # 1 when an abort must leave maintenance on (an interrupted --no-rollback migration, schema unchanged)
SCHEMA_BEFORE=""
MIGRATING=0   # 1 (--no-rollback) from the start of the migrations until the schema comparison has decided ADVANCED
ROLLBACK_BLOCKED=""   # the rollback target, when the guard says it can't run on this schema
maint_on=0
STAGE=""
PREV=""
services="caddy postgres"
KEPT=".env app.env postgres.env compose.yml caddy/Caddyfile"   # restored from *.prev on an unexpected exit

done_exit() { EXPECTED=1; exit "$1"; }

# hold <subject> <message> — the outcome once the previous image must not run again: maintenance ON (it stays
# on until a deploy passes /health), no container of an older image left to start, the failed state kept for
# whoever recovers it, a deploys.log line, an alert, exit 4. Never restores the previous configuration.
hold() {
  trap '' TERM INT HUP   # finish the hold even if signalled again
  retire_old_app
  keep_maint_on
  printf '%s\t%s\t%s\theld: %s\n' "$(date -u +%FT%TZ)" "$IMAGE" "${PREV:--}" "$1" >> "$EDH_DATA_DIR/deploys.log" 2>/dev/null \
    || log "could not append to deploys.log"
  alert "$1" "$2"
  log "$2"
  done_exit 4
}
# keep_maint_on — maintenance ON, marked as left on by a failed deploy (edh-maint.sh on/off clear the mark): the
# next deploy that passes /health switches it off, with or without --maint
keep_maint_on() {
  "$EDH_BIN_DIR/edh-maint.sh" on --message "We're upgrading the system." --until "shortly" >/dev/null 2>&1 \
    || log "could not switch maintenance on — run: edh-maint.sh on"
  maint_on=0
  : > "$EDH_APP_DIR/maint_held" 2>/dev/null || true
}
# retire_old_app — after the migrations changed the schema, nothing may start an older image again: not this
# script, and not a later `docker compose start` / `up` (restore.sh's failure path, resize.sh, upgrade.sh). So .env
# names this deploy's image, and an app container of another image — running, or stopped — is saved to a log
# file and removed, its place taken by a created (not started) container of this image. A failed container of
# this image is left as it is, running, for diagnosis.
retire_old_app() {
  local id img f
  if [[ "$(current_image)" != "$IMAGE" ]]; then
    write_compose_env "$IMAGE" || log "could not point .env at $IMAGE — check $EDH_APP_DIR/.env before any docker compose up"
  fi
  id=$(dc ps -a -q app 2>/dev/null | head -1 || true)
  [[ -n "$id" ]] || return 0
  img=$(docker inspect -f '{{.Config.Image}}' "$id" 2>/dev/null || true)
  [[ "$img" != "$IMAGE" ]] || return 0
  f="$EDH_DATA_DIR/held-app-$(date -u +%Y%m%dT%H%M%SZ).log"
  dc logs --no-color --tail 2000 app > "$f" 2>&1 || true
  ls -1t "$EDH_DATA_DIR"/held-app-*.log 2>/dev/null | tail -n +11 | xargs -r rm -f || true   # keep the 10 newest
  if dc rm -s -f app >/dev/null 2>&1; then
    log "removed the app container of ${img:-an unknown image}: it may not run on this schema (its last log lines: $f)"
  else
    log "could not remove the app container of ${img:-an unknown image} — stop and remove it: docker compose rm -s -f app"
  fi
  # only once .env names this image: created from an older .env, the container would be the old image again
  if [[ "$(current_image)" == "$IMAGE" ]]; then
    dc up --no-start app >/dev/null 2>&1 || log "could not create the app container of $IMAGE (nothing is serving; maintenance is on)"
  fi
}
# recovery_steps — the way out of exit 4, for the alert and the log
recovery_steps() {
  printf '%s' "Maintenance is ON and stays on until a deploy passes /health. Recover by fixing forward: deploy a corrected release (with --no-rollback again). If a migration failed, its tool may have recorded the failure (Prisma: a failed _prisma_migrations row, P3009) and refuse to migrate again until it is cleared (Prisma: migrate resolve, after checking what the migration left). Going back instead means restoring the database to a schema the old version runs on (restore.sh db from this deploy's safety dump: a destructive step that needs explicit authorization), then rollback.sh --allow-incompatible. The restore starts the app container of the held new version on the restored schema, which may fail /health; maintenance stays on through it, and rollback.sh --allow-incompatible is the next step either way. The images that can't run on this schema are listed in $EDH_GUARD_FILE."
}
# block_prev — after the migrations changed the schema, record every image this server ran before (the one
# being replaced, edh-rollback.sh's previous image, every image in deploys.log) as unable to run on it: each of
# them ran on an older schema
block_prev() {
  local i
  { printf '%s\n' "$PREV"; cat "$EDH_APP_DIR/previous_image" 2>/dev/null || true
    awk -F'\t' '{ print $2; print $3 }' "$EDH_DATA_DIR/deploys.log" 2>/dev/null || true; } \
    | awk 'NF && $0 != "-" && !seen[$0]++' | while IFS= read -r i; do
        if [[ "$i" == "$IMAGE" ]]; then continue; fi
        block_image "$i" "$IMAGE" || log "could not record $i in $EDH_GUARD_FILE — rollback.sh will not refuse it"
      done
}
reload_caddy_once() { dc exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || log "caddy reload failed"; }
finish_maint() {
  if (( KEEP_MAINT )); then keep_maint_on; return 0; fi
  if (( maint_on )); then "$EDH_BIN_DIR/edh-maint.sh" off >/dev/null; maint_on=0; fi
}

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
  trap '' TERM INT HUP   # a second signal (SSM repeats them) must not cut the clean-up short
  if [[ -n "$STAGE" ]]; then rm -rf "$STAGE"; fi
  if (( EXPECTED || rc == 0 )); then exit "$rc"; fi
  if (( DEPLOYED )); then
    alert "deploy: follow-up step failed at line $line" "$IMAGE is deployed and healthy, but a step after the health check failed (exit $rc). See the deploy output."
    exit 0
  fi
  if (( MIGRATING && ! ADVANCED )); then
    # interrupted while migrating (or before the comparison): decide from the schema itself, as the normal path does
    local now
    now=$(schema_fingerprint) || now=""
    if [[ -z "$now" || "$now" != "$SCHEMA_BEFORE" ]]; then
      ADVANCED=1; block_prev
      log "interrupted during the migrations, and the schema changed (or could not be read): treated as changed"
    else
      KEEP_MAINT=1   # unchanged: the previous version keeps running, but maybe not restart-safe (exit 5's reason)
    fi
  fi
  if (( ADVANCED )) || { (( SWAPPED )) && [[ -n "$ROLLBACK_BLOCKED" ]]; }; then
    # the previous image must not take over: keep this deploy's state, behind the maintenance page
    hold "deploy failed after migrations" "Deploying $IMAGE stopped unexpectedly at line $line (exit $rc) after its migrations changed the database schema (or with no image to roll back to that runs on it). No previous image was started again, and an app container still running another image was stopped. $(recovery_steps)"
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
  if (( KEEP_MAINT )); then
    alert "deploy aborted, maintenance on" "Deploying $IMAGE stopped at line $line (exit $rc) during its migrations; the database schema is unchanged and the previous version is still running, behind the maintenance page (--no-rollback). Don't assume it can restart: if the migration tool recorded the interrupted migration (Prisma: P3009), clear the record and check docker compose restart app before maint.sh off."
    exit 5
  fi
  alert "deploy aborted at line $line" "Deploying $IMAGE failed before the switch (exit $rc); the previous version is still running. See the deploy output."
  exit 1
}
# the image running now (empty on a first deploy), known before anything can fail
PREV=$(sed -n 's/^APP_IMAGE=//p' "$EDH_APP_DIR/.env" 2>/dev/null || true)
ENV_SAVED=0   # 1 once the previous edh.env is saved as edh.env.prev
trap 'on_exit $LINENO' EXIT
# a signal (SSM cancelling the command, a terminal closing) must reach on_exit as a failure: without these the EXIT
# trap sees status 0 and would treat an interrupted deploy as finished
trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
edh_lock
# the rollback guard holds for every deploy, with or without --no-rollback: an image a later migration left
# behind is never put back by a deploy either (only edh-rollback.sh --allow-incompatible, after a restore)
if image_blocked "$IMAGE"; then
  msg="Refused to deploy $IMAGE: it can't run on this database's schema, which a later deploy's migrations changed ($EDH_GUARD_FILE). Nothing changed; the current version keeps serving. Deploy a newer release; going back needs the database restored first, then rollback.sh --allow-incompatible."
  log "$msg"
  alert "deploy refused" "$msg"
  done_exit 1
fi
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

# compose_check — the skill's compose rules (edh-compose-check.py, the same check deploy.sh runs on the Mac), on
# the staged compose.yml rendered with the real values it is about to get. Under env -i (only PATH, HOME and the
# Docker client settings), so nothing in this shell's environment changes what it renders to.
compose_check() {
  local keep=() v out rc w="$STAGE/.check" vargs=()
  for v in PATH HOME DOCKER_HOST DOCKER_CONFIG DOCKER_CONTEXT; do
    if [[ -n "${!v:-}" ]]; then keep+=("$v=${!v}"); fi
  done
  mkdir -m 700 "$w"
  if ! env -i "${keep[@]}" docker compose --project-directory "$STAGE" -f "$STAGE/compose.yml" \
       config --no-env-resolution --format json > "$w/cfg.json" 2>"$w/err"; then
    tail -20 "$w/err" >&2
    die "the release's compose.yml is invalid — nothing installed"
  fi
  if env -i "${keep[@]}" docker compose --project-directory "$STAGE" -f "$STAGE/compose.yml" \
       config --variables --format json > "$w/vars.json" 2>/dev/null; then
    vargs=(--variables "$w/vars.json")
  else
    log "this Docker Compose can't list variables (config --variables): scanning compose.yml for them instead"
    vargs=(--scan "$STAGE/compose.yml")
  fi
  rc=0
  # --mount-root: bind sources are also checked where Docker will mount them (the installed app dir, /data)
  out=$(python3 -I "$REL/host/edh-compose-check.py" "$w/cfg.json" "$STAGE" --data-dir "$EDH_DATA_DIR" \
    --mount-root "$EDH_APP_DIR" "${vargs[@]}" 2>&1) || rc=$?
  rm -rf "$w"   # the rendered config holds the bypass token
  if (( rc == 1 )); then printf '%s\n' "$out" >&2; die "the release's compose.yml breaks the compose rules — nothing installed"; fi
  (( rc == 0 )) || die "could not check the release's compose.yml: $out"
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
  compose_check
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
# never roll back automatically to an image the guard lists
if image_blocked "$ROLLBACK"; then ROLLBACK_BLOCKED="$ROLLBACK"; ROLLBACK=""; fi
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
  if (( NO_ROLLBACK )); then
    SCHEMA_BEFORE=$(schema_fingerprint) || SCHEMA_BEFORE=""
    [[ -n "$SCHEMA_BEFORE" ]] \
      || die "--no-rollback: could not read the database schema before the migrations (it is compared after them) — not deploying"
    MIGRATING=1   # from here an interruption is judged by the schema (on_exit)
  fi
  log "running migrations with $IMAGE"
  mrc=0
  migrate || mrc=$?
  if (( NO_ROLLBACK )); then
    # what decides whether the previous image may run again is the schema, not the migration's exit code: a
    # failed run may have committed part of its work, and a successful one may have changed nothing
    schema_after=$(schema_fingerprint) || schema_after=""
    if [[ -z "$schema_after" ]]; then schema_after=unreadable; fi
    if [[ "$schema_after" != "$SCHEMA_BEFORE" ]]; then
      ADVANCED=1
      block_prev
      if [[ "$schema_after" == unreadable ]]; then
        log "the database schema could not be read after the migrations: treated as changed"
      fi
      log "the migrations changed the database schema: ${PREV:-the previous image} is not started again"
    else
      log "the migrations left the database schema unchanged"
    fi
    MIGRATING=0
  fi
  if (( mrc != 0 )); then
    if (( ADVANCED )); then
      # part of the migrations committed: the version still running may not work on this schema (hold stops it)
      hold "migrations failed, schema changed" "Migrations failed for $IMAGE, but the database schema changed (part of them committed, or it could not be read afterwards). The previous version (${PREV:-none}) was stopped, because it may not run on this schema, and the new version was not started. Fix the failed migration and deploy forward, or restore the database first (see below). $(recovery_steps)"
    fi
    # like every abort before the switch: the previous configuration back (env files, compose.yml, Caddyfile,
    # edh.env), and caddy/postgres re-upped with it; the old app version keeps serving
    log "migrations failed: restoring the previous configuration"
    # shellcheck disable=SC2086
    restore_prev $KEPT
    restore_env_file
    if [[ -z "$PREV" ]]; then abort_first_deploy "deploy failed" "Migrations failed for $IMAGE."; fi
    restart_note="If the migration tool recorded the failed migration (Prisma: a failed _prisma_migrations row, error P3009), an app that migrates when it starts will refuse to boot until it is cleared: fix the cause, clear the record (Prisma: migrate resolve --rolled-back <migration>, run in the app container), and check the app restarts (docker compose restart app, then /health) before anything restarts it."
    if (( NO_ROLLBACK )); then
      # the schema is unchanged, so the version running keeps working — but it may not survive a restart; and
      # after an earlier hold nothing may be running at all: maintenance on either way, exit 5
      keep_maint_on
      if revert_infra; then
        state="The previous version (${PREV}) is still running with its previous configuration, behind the maintenance page (--no-rollback keeps it on). Don't assume it can restart."
      else
        state="No version is serving (the app is not running or fails /health: an earlier held deploy may have left it stopped); the maintenance page is up."
      fi
      msg="Migrations failed for $IMAGE and the database schema is unchanged. $state $restart_note Switch maintenance off (maint.sh off) only once a version passes /health, then release again."
      alert "deploy failed, maintenance on" "$msg"
      log "$msg"
      done_exit 5
    fi
    if ! revert_infra; then
      alert "SITE DOWN after deploy" "Migrations failed for $IMAGE, and with the previous configuration restored the app fails /health."
      done_exit 3
    fi
    finish_maint
    alert "deploy failed" "Migrations failed for $IMAGE. The previous version is still running with its previous configuration. $restart_note"
    done_exit 1
  fi
fi

SWAPPED=1
write_compose_env "$IMAGE"
if dc up -d app && wait_health; then
  DEPLOYED=1   # healthy: from here on everything is best-effort bookkeeping
  finish_maint || log "could not switch maintenance off — run: edh-maint.sh off"
  if [[ -f "$EDH_APP_DIR/maint_held" ]]; then   # left on by a failed deploy: a version passes /health now
    if "$EDH_BIN_DIR/edh-maint.sh" off >/dev/null; then log "maintenance (left on by a failed deploy) switched off: $IMAGE passes /health"
    else log "could not switch maintenance off — run: edh-maint.sh off"; fi
  fi
  if [[ -n "$PREV" && "$PREV" != "$IMAGE" ]]; then record_previous || log "could not record the previous image for edh-rollback.sh"; fi
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$IMAGE" "${PREV:--}" >> "$EDH_DATA_DIR/deploys.log" \
    || log "could not append to deploys.log"
  prune_images "$IMAGE" || log "image cleanup failed (not fatal)"
  log "deployed $IMAGE"
  done_exit 0
fi

log "health check failed for $IMAGE"
if (( ADVANCED )); then
  hold "deploy failed after migrations" "$IMAGE failed to start or failed its health check after its migrations changed the database schema. The previous image (${PREV:-none}) was not started again, because it may not run on the new schema; the failed version is left as it is (docker compose logs app). $(recovery_steps)"
fi
if [[ -n "$ROLLBACK_BLOCKED" ]]; then
  hold "deploy failed, no compatible rollback" "$IMAGE failed to start or failed its health check, and the image it would roll back to ($ROLLBACK_BLOCKED) can't run on this database's schema. Nothing was rolled back; the failed version is left as it is (docker compose logs app). $(recovery_steps)"
fi
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
