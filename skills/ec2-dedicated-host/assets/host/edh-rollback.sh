#!/usr/bin/env bash
# edh-rollback.sh [--allow-incompatible] — switch the app back to the previously deployed image, with the
# app.env it ran with (app.env.rollback, saved by the deploy that replaced it). Running it again rolls forward.
# If the previous image fails /health, the current image and its app.env are put back (exit 1, alert),
# or exit 3 if the current image then fails /health as well.
# Refuses (exit 4, nothing changed) when the rollback guard lists the previous image: a later --no-rollback
# deploy's migrations changed the schema it ran on. --allow-incompatible switches anyway and removes its line
# from the guard — only after the database was restored to a schema that image runs on.
# shellcheck source-path=SCRIPTDIR source=edh-lib.sh
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh" || { echo "edh-rollback: cannot load edh-lib.sh" >&2; exit 1; }
ALLOW_INCOMPATIBLE=0
for a in "$@"; do
  case "$a" in --allow-incompatible) ALLOW_INCOMPATIBLE=1 ;; *) die "unknown option: $a" ;; esac
done
edh_lock
prev=$(cat "$EDH_APP_DIR/previous_image" 2>/dev/null || true)
[[ -n "$prev" ]] || die "no previous image recorded"
cur=$(sed -n 's/^APP_IMAGE=//p' "$EDH_APP_DIR/.env")
[[ "$prev" != "$cur" ]] || die "nothing to roll back to: the previous image $prev is the one running"
if image_blocked "$prev"; then
  if (( ! ALLOW_INCOMPATIBLE )); then
    log "refused: the previous image $prev can't run on this database's schema — the migrations of $(awk -F'\t' -v i="$prev" '$1 == i { print $3 " (" $2 ")"; exit }' "$EDH_GUARD_FILE") changed it ($EDH_GUARD_FILE). Nothing changed. Fix forward with a new release; going back needs the database restored to a schema $prev runs on first (restore.sh db, explicit authorization), then rollback.sh --allow-incompatible."
    exit 4
  fi
  log "--allow-incompatible: switching to $prev although the rollback guard lists it (the database must have been restored to a schema it runs on)"
fi

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
  how=rollback
  if (( ALLOW_INCOMPATIBLE )) && image_blocked "$prev"; then
    unblock_image "$prev" || log "could not remove $prev from $EDH_GUARD_FILE"
    how="rollback (allow-incompatible)"
  fi
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$prev" "$cur" "$how" >> "$EDH_DATA_DIR/deploys.log"
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
