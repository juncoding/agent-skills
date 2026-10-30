#!/usr/bin/env bash
# edh-rollback.sh — switch the app back to the previously deployed image.
# shellcheck source-path=SCRIPTDIR source=edh-lib.sh
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh" || { echo "edh-rollback: cannot load edh-lib.sh" >&2; exit 1; }
prev=$(cat "$EDH_APP_DIR/previous_image" 2>/dev/null || true)
[[ -n "$prev" ]] || die "no previous image recorded"
cur=$(sed -n 's/^APP_IMAGE=//p' "$EDH_APP_DIR/.env")
sed -i.bak "s#^APP_IMAGE=.*#APP_IMAGE=$prev#" "$EDH_APP_DIR/.env" && rm -f "$EDH_APP_DIR/.env.bak"
dc up -d app
wait_health || die "previous image $prev is unhealthy too"
printf '%s\n' "$cur" > "$EDH_APP_DIR/previous_image"
printf '%s\t%s\t%s\trollback\n' "$(date -u +%FT%TZ)" "$prev" "$cur" >> "$EDH_DATA_DIR/deploys.log"
log "rolled back to $prev"
