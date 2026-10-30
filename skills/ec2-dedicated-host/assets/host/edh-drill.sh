#!/usr/bin/env bash
# edh-drill.sh — monthly restore test: newest dump in S3 → side database → count tables → drop. Alerts on failure.
# shellcheck source-path=SCRIPTDIR source=edh-lib.sh
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh" || { echo "edh-drill: cannot load edh-lib.sh" >&2; exit 1; }
trap 'alert "restore drill FAILED" "The monthly restore test failed on $(hostname). Backups may not be restorable — investigate now."' ERR
key=$(aws s3 ls "s3://$EDH_BACKUP_BUCKET/db/" --recursive --region "$EDH_REGION" \
  | awk '{print $4}' | grep -E '^db/(hourly|daily)/app-.*\.dump$' \
  | awk -F/ '{print $NF " " $0}' | sort | tail -1 | cut -d' ' -f2)
[[ -n "$key" ]] || die "no backups found in s3://$EDH_BACKUP_BUCKET/db/"
n=$("$EDH_BIN_DIR/edh-restore.sh" check "$key")
metric RestoreDrillSuccess 1
log "restore drill ok: $key ($n tables)"
