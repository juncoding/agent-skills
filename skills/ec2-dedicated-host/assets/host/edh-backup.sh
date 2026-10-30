#!/usr/bin/env bash
# edh-backup.sh [--tag auto|safety|manual] [--force]
# pg_dump (custom format) of the app database to /data/backups, then upload to S3. Hourly via systemd.
#   auto   : hourly (DB < 2 GB) → db/hourly/ ; at daily_backup_hour_utc also db/daily/ ; on the 1st also db/monthly/
#   safety : before deploys/restores → db/safety/ (kept 30 days)
#   manual : on demand → db/daily/
# The server can upload but never delete backups; S3 lifecycle rules do the expiring.
# shellcheck source-path=SCRIPTDIR source=edh-lib.sh
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh" || { echo "edh-backup: cannot load edh-lib.sh" >&2; exit 1; }

TAG=auto; FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in --tag) TAG="$2"; shift 2 ;; --force) FORCE=1; shift ;; *) die "unknown option: $1" ;; esac
done
trap 'alert "backup failed" "edh-backup.sh ($TAG) failed on $(hostname) at $(date -u +%FT%TZ). See: journalctl -u edh-backup"' ERR

size=$(pg "select pg_database_size('app')")
schedule="${EDH_BACKUP_SCHEDULE:-auto}"
if [[ "$schedule" == auto ]]; then
  if (( size < 2147483648 )); then schedule=hourly; else schedule=daily; fi
fi
hour=$(date -u +%H); day=$(date -u +%d)
daily_slot=0
# 10# : the config allows "08", which printf would reject as an invalid octal number
if [[ "$hour" == "$(printf '%02d' "$((10#${EDH_DAILY_HOUR_UTC:-18}))")" ]]; then daily_slot=1; fi
if [[ "$TAG" == auto && "$schedule" == daily && $daily_slot == 0 && $FORCE == 0 ]]; then
  log "daily schedule (database is $((size / 1048576)) MB): nothing to do this hour"; exit 0
fi

name="app-$(date -u +%Y%m%dT%H%M%SZ).dump"
file="$EDH_DATA_DIR/backups/$name"
mkdir -p "$EDH_DATA_DIR/backups"
dc exec -T postgres pg_dump -U app -d app -Fc > "$file.part"
mv "$file.part" "$file"
[[ -s "$file" ]] || die "pg_dump produced an empty file"

upload() { aws s3 cp "$file" "s3://$EDH_BACKUP_BUCKET/db/$1/$name" --region "$EDH_REGION" --only-show-errors; log "uploaded db/$1/$name"; }
case "$TAG" in
  auto)
    if [[ "$schedule" == hourly ]]; then upload hourly; fi
    if (( daily_slot )); then upload daily; if [[ "$day" == 01 ]]; then upload monthly; fi; fi ;;
  safety) upload safety ;;
  manual) upload daily ;;
  *) die "unknown tag: $TAG" ;;
esac
metric BackupSuccess 1
find "$EDH_DATA_DIR/backups" -name 'app-*.dump' -mmin +4320 -delete   # keep 3 days locally
echo "$name"
