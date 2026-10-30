#!/usr/bin/env bash
# edh-rollback.sh — switch the app back to the previously deployed image, with the app.env it ran with
# (app.env.rollback, saved by the deploy that replaced it). Running it again rolls forward.
# shellcheck source-path=SCRIPTDIR source=edh-lib.sh
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh" || { echo "edh-rollback: cannot load edh-lib.sh" >&2; exit 1; }
edh_lock
prev=$(cat "$EDH_APP_DIR/previous_image" 2>/dev/null || true)
[[ -n "$prev" ]] || die "no previous image recorded"
cur=$(sed -n 's/^APP_IMAGE=//p' "$EDH_APP_DIR/.env")
[[ "$prev" != "$cur" ]] || die "nothing to roll back to: the previous image $prev is the one running"
if [[ -f "$EDH_APP_DIR/app.env.rollback" ]]; then   # swap app.env and app.env.rollback
  cp -p "$EDH_APP_DIR/app.env" "$EDH_APP_DIR/app.env.swap"
  cp -p "$EDH_APP_DIR/app.env.rollback" "$EDH_APP_DIR/app.env"
  mv -f "$EDH_APP_DIR/app.env.swap" "$EDH_APP_DIR/app.env.rollback"
fi
sed -i.bak "s#^APP_IMAGE=.*#APP_IMAGE=$prev#" "$EDH_APP_DIR/.env" && rm -f "$EDH_APP_DIR/.env.bak"
dc up -d app
wait_health || die "previous image $prev is unhealthy too"
printf '%s\n' "$cur" > "$EDH_APP_DIR/previous_image"
printf '%s\t%s\t%s\trollback\n' "$(date -u +%FT%TZ)" "$prev" "$cur" >> "$EDH_DATA_DIR/deploys.log"
log "rolled back to $prev"
