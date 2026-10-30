#!/usr/bin/env bash
# edh-drill.sh — monthly restore test: newest dump in the backup manifest → side database → count tables → drop. Alerts on failure.
# shellcheck source-path=SCRIPTDIR source=edh-lib.sh
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh" || { echo "edh-drill: cannot load edh-lib.sh" >&2; exit 1; }
on_exit() {
  local rc=$?
  if (( rc )); then
    alert "restore drill FAILED" "The monthly restore test failed on $(hostname) (exit $rc). Backups may not be restorable — investigate now."
  fi
  exit "$rc"
}
trap on_exit EXIT
edh_lock   # held for the whole drill; the nested edh-restore.sh sees EDH_LOCK_HELD
# only a backup this server made: the newest hourly/daily entry of the manifest (never a listing of the bucket,
# where anything holding the instance role can add objects)
key=$(awk -F'\t' '$1 ~ /^db\/(hourly|daily)\/app-[0-9]+T[0-9]+Z\.dump$/ { k = $1 } END { print k }' "$EDH_MANIFEST" 2>/dev/null || true)
[[ -n "$key" ]] || die "no backups in this server's backup manifest ($EDH_MANIFEST)"
n=$("$EDH_BIN_DIR/edh-restore.sh" check "$key")
metric RestoreDrillSuccess 1
log "restore drill ok: $key ($n tables)"
