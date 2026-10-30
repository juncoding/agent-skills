#!/usr/bin/env bash
# edh-backup.sh [--tag auto|safety|manual] [--force]
# pg_dump (custom format) of the app database to /data/backups, then upload to S3. Hourly via systemd.
#   auto   : hourly (DB < 2 GB) → db/hourly/ ; at daily_backup_hour_utc also db/daily/ ; on the 1st also db/monthly/
#            Every auto run ends with the BackupFresh=1 heartbeat — only while the newest local dump is younger
#            than its schedule allows (hourly 2 h, daily 26 h); the backup alarm fires when it stops.
#   safety : before deploys/restores → db/safety/ (kept 30 days)
#   manual : on demand → db/daily/
# The newest 24 dumps are kept locally. The server can upload but never delete in S3; lifecycle rules expire them.
# Prints the dump's file name. Any failure sends an alert.
# shellcheck source-path=SCRIPTDIR source=edh-lib.sh
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh" || { echo "edh-backup: cannot load edh-lib.sh" >&2; exit 1; }

TAG=auto; FORCE=0; file=""
on_exit() {
  local rc=$?
  if [[ -n "$file" ]]; then rm -f "$file.part"; fi
  if (( rc )); then
    alert "backup failed" "edh-backup.sh ($TAG) failed on $(hostname) at $(date -u +%FT%TZ) (exit $rc). See: journalctl -u edh-backup"
  fi
  exit "$rc"
}
trap on_exit EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) [[ $# -ge 2 ]] || die "--tag needs a value"; TAG="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done
case "$TAG" in auto|safety|manual) ;; *) die "unknown tag: $TAG (auto, safety or manual)" ;; esac
case "${EDH_BACKUP_SCHEDULE:-auto}" in auto|hourly|daily) ;; *) die "EDH_BACKUP_SCHEDULE must be auto, hourly or daily" ;; esac
edh_lock

# heartbeat — BackupFresh=1 while the newest local dump is within the schedule's window (auto runs only)
heartbeat() {
  local window; window=$(fresh_minutes "$schedule")
  if [[ -n "$(find "$EDH_DATA_DIR/backups" -name 'app-*.dump' -mmin "-$window" 2>/dev/null | head -1)" ]]; then
    metric BackupFresh 1
  else
    log "no local dump younger than $window min: BackupFresh not published"
  fi
}

schedule=$(backup_schedule)
hour=$(date -u +%H); day=$(date -u +%d)
daily_slot=0
# 10# : the config allows "08", which printf would reject as an invalid octal number
if [[ "$hour" == "$(printf '%02d' "$((10#${EDH_DAILY_HOUR_UTC:-18}))")" ]]; then daily_slot=1; fi
if [[ "$TAG" == auto && "$schedule" == daily && $daily_slot == 0 && $FORCE == 0 ]]; then
  log "daily schedule: nothing to do this hour"
  heartbeat
  exit 0
fi

# dumps are owner-only: directory 0700 (tightened if it already exists), files 0600
mkdir -p "$EDH_DATA_DIR/backups"
chmod 700 "$EDH_DATA_DIR/backups"
umask 077
name="app-$(date -u +%Y%m%dT%H%M%SZ).dump"
file="$EDH_DATA_DIR/backups/$name"
dc exec -T postgres pg_dump -U app -d app -Fc > "$file.part"
[[ -s "$file.part" ]] || die "pg_dump produced an empty file"
dc exec -T postgres pg_restore --list < "$file.part" >/dev/null || die "pg_dump output is not a readable archive"
mv "$file.part" "$file"

upload() { aws s3 cp "$file" "s3://$EDH_BACKUP_BUCKET/db/$1/$name" --region "$EDH_REGION" --only-show-errors; log "uploaded db/$1/$name"; }
case "$TAG" in
  auto)
    if [[ "$schedule" == hourly ]]; then upload hourly; fi
    if (( daily_slot )); then upload daily; if [[ "$day" == 01 ]]; then upload monthly; fi; fi ;;
  safety) upload safety ;;
  manual) upload daily ;;
esac
# keep the newest 24 local dumps
ls -1t "$EDH_DATA_DIR"/backups/app-*.dump | tail -n +25 | while read -r old; do rm -f "$old"; done
if [[ "$TAG" == auto ]]; then heartbeat; fi
echo "$name"
