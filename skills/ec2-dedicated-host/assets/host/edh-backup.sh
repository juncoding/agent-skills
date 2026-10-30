#!/usr/bin/env bash
# edh-backup.sh [--tag auto|safety|manual] [--force]
# pg_dump (custom format) of the app database to /data/backups, then upload to S3. Hourly via systemd.
#   auto   : hourly (DB < 2 GB) → db/hourly/ ; at daily_backup_hour_utc also db/daily/ ; on the 1st also db/monthly/
#            Every auto run ends with the BackupFresh=1 heartbeat — only while the last successful upload
#            (backups/.last_upload) is younger than the schedule allows (hourly 2 h, daily 26 h); the backup
#            alarm fires when it stops.
#   safety : before deploys/restores → db/safety/ (kept 30 days)
#   manual : on demand → db/daily/
# Every upload is recorded in the manifest ($EDH_MANIFEST: key, sha256, S3 VersionId, time; newest 2000 lines),
# which restores verify against. The newest 24 dumps are kept locally. The server can create backups but never
# overwrite or delete them in S3; lifecycle rules expire them.
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

# heartbeat — BackupFresh=1 while the last successful upload is within the schedule's window (auto runs only)
heartbeat() {
  local window; window=$(fresh_minutes "$schedule")
  if [[ -n "$(find "$EDH_DATA_DIR/backups" -maxdepth 1 -name .last_upload -mmin "-$window" 2>/dev/null)" ]]; then
    metric BackupFresh 1
  else
    log "no successful upload in the last $window min: BackupFresh not published"
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
# the upload checks the bucket owner (bucket names are global): refuse before dumping if it isn't known
[[ "${EDH_ACCOUNT_ID:-}" =~ ^[0-9]{12}$ ]] || die "EDH_ACCOUNT_ID (12-digit AWS account) is not set in $EDH_ENV_FILE"
# uploads are create-only, so two backups in the same second must not share a name: wait for a new one
for _ in 1 2 3 4 5; do
  name="app-$(date -u +%Y%m%dT%H%M%SZ).dump"
  [[ -e "$EDH_DATA_DIR/backups/$name" ]] || break
  sleep 1
done
file="$EDH_DATA_DIR/backups/$name"
dc exec -T postgres pg_dump -U app -d app -Fc > "$file.part"
[[ -s "$file.part" ]] || die "pg_dump produced an empty file"
dc exec -T postgres pg_restore --list < "$file.part" >/dev/null || die "pg_dump output is not a readable archive"
mv "$file.part" "$file"
sha=$(sha256_of "$file")
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "could not checksum $file"

uploaded=0
# upload <prefix> — create-only (--if-none-match '*'): the host policy allows nothing else, so the server can
# never overwrite a backup (which would push the genuine one into a noncurrent version).
# A single PUT is limited to 5 GB, which is fine for the dump sizes we target, and 5 GB is a HARD ceiling for
# now: multipart upload can't work under the current policy, because UploadPart is authorised as s3:PutObject
# without If-None-Match, which BackupsWrite denies (only CompleteMultipartUpload carries If-None-Match).
# TODO: for dumps over 5 GB, change the policy to allow parts and switch to multipart upload with If-None-Match.
# The upload's VersionId goes into the manifest: restores fetch exactly that version and check its sha256.
upload() {
  local vid
  vid=$(aws s3api put-object --bucket "$EDH_BACKUP_BUCKET" --key "db/$1/$name" --body "$file" --if-none-match '*' \
    --expected-bucket-owner "$EDH_ACCOUNT_ID" --region "$EDH_REGION" --query VersionId --output text)
  [[ "$vid" =~ ^[A-Za-z0-9._+/=-]+$ && "$vid" != None && "$vid" != null ]] \
    || die "db/$1/$name was uploaded without a usable VersionId ('$vid'; is bucket versioning on?) — not recorded in the manifest"
  printf '%s\t%s\t%s\t%s\n' "db/$1/$name" "$sha" "$vid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$EDH_MANIFEST"
  chmod 600 "$EDH_MANIFEST"
  log "uploaded db/$1/$name (version $vid)"; uploaded=1
}
case "$TAG" in
  auto)
    if [[ "$schedule" == hourly ]]; then upload hourly; fi
    if (( daily_slot )); then upload daily; if [[ "$day" == 01 ]]; then upload monthly; fi; fi ;;
  safety) upload safety ;;
  manual) upload daily ;;
esac
if (( uploaded )); then touch "$EDH_DATA_DIR/backups/.last_upload"; fi   # freshness = last successful upload
# the manifest keeps the newest 2000 uploads (far more than the lifecycle rules keep in S3)
if [[ -f "$EDH_MANIFEST" ]] && (( $(wc -l < "$EDH_MANIFEST") > 2000 )); then
  tail -n 2000 "$EDH_MANIFEST" > "$EDH_MANIFEST.new" && mv -f "$EDH_MANIFEST.new" "$EDH_MANIFEST"
fi
# keep the newest 24 local dumps
ls -1t "$EDH_DATA_DIR"/backups/app-*.dump | tail -n +25 | while read -r old; do rm -f "$old"; done
if [[ "$TAG" == auto ]]; then heartbeat; fi
echo "$name"
