#!/usr/bin/env bash
# edh-rollback.sh — switch the app back to the previously deployed image, with the app.env it ran with
# (app.env.rollback, saved by the deploy that replaced it). Running it again rolls forward.
# If the previous image fails /health, the current image and its app.env are put back (exit 1, alert),
# or exit 3 if the current image then fails /health as well.
# shellcheck source-path=SCRIPTDIR source=edh-lib.sh
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh" || { echo "edh-rollback: cannot load edh-lib.sh" >&2; exit 1; }
edh_lock
prev=$(cat "$EDH_APP_DIR/previous_image" 2>/dev/null || true)
[[ -n "$prev" ]] || die "no previous image recorded"
cur=$(sed -n 's/^APP_IMAGE=//p' "$EDH_APP_DIR/.env")
[[ "$prev" != "$cur" ]] || die "nothing to roll back to: the previous image $prev is the one running"

swap_app_env() { # swap app.env and app.env.rollback (no-op without app.env.rollback)
  if [[ -f "$EDH_APP_DIR/app.env.rollback" ]]; then
    cp -p "$EDH_APP_DIR/app.env" "$EDH_APP_DIR/app.env.swap"
    cp -p "$EDH_APP_DIR/app.env.rollback" "$EDH_APP_DIR/app.env"
    mv -f "$EDH_APP_DIR/app.env.swap" "$EDH_APP_DIR/app.env.rollback"
  fi
}
set_image() { sed -i.bak "s#^APP_IMAGE=.*#APP_IMAGE=$1#" "$EDH_APP_DIR/.env" && rm -f "$EDH_APP_DIR/.env.bak"; }

swap_app_env
set_image "$prev"
if dc up -d app && wait_health; then
  printf '%s\n' "$cur" > "$EDH_APP_DIR/previous_image"
  printf '%s\t%s\t%s\trollback\n' "$(date -u +%FT%TZ)" "$prev" "$cur" >> "$EDH_DATA_DIR/deploys.log"
  log "rolled back to $prev"
  exit 0
fi

log "previous image $prev is unhealthy: going back to $cur"
swap_app_env
set_image "$cur"
if dc up -d app && wait_health; then
  # SNS subjects must be ASCII and under 100 characters: the image names go in the message
  alert "rollback failed" "rollback failed — stayed on $cur: $prev failed its health check, so $cur and its app.env were restored and are healthy."
  exit 1
fi
alert "SITE DOWN after rollback" "Rolling back to $prev failed its health check, and $cur fails /health after being restored too."
exit 3
