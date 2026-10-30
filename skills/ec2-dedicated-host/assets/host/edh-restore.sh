#!/usr/bin/env bash
# edh-restore.sh pick [YYYYMMDD]   print "<key><TAB><upload time>" of the newest backup in the manifest (uploaded that day)
# edh-restore.sh check <s3-key> [--keep] [--unverified]   restore into side database app_restore_check, count tables, drop it
# edh-restore.sh replace <s3-key> --yes [--unverified]    replace the live database:
#     validate the dump → restore it into app_restore_new (the app keeps serving) → maintenance on → safety dump
#     → stop app → rename app → app_pre_restore, app_restore_new → app → start app → /health → maintenance off.
#     The previous data stays in database app_pre_restore until you drop it. Any failure alerts.
# Only backups in this server's manifest are restored: the exact S3 version it recorded, checked against its
# sha256 (a compromised app can add objects to the bucket through the instance role, but not to the manifest).
# --unverified restores a key that is not in the manifest (e.g. the manifest was lost), with a warning and an alert.
# shellcheck source-path=SCRIPTDIR source=edh-lib.sh
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh" || { echo "edh-restore: cannot load edh-lib.sh" >&2; exit 1; }

UNVERIFIED=0
# fetch <s3-key> → local path (0600). Manifest key: that exact version, sha256 checked. Otherwise refused,
# unless --unverified (then the current version, with an alert).
fetch() {
  local f entry vid want got
  [[ "${EDH_ACCOUNT_ID:-}" =~ ^[0-9]{12}$ ]] || die "EDH_ACCOUNT_ID (12-digit AWS account) is not set in $EDH_ENV_FILE"
  f="$EDH_DATA_DIR/backups/restore-$(basename "$1")"
  rm -f "$f"   # never reuse an earlier download: only what is verified now counts
  entry=$(awk -F'\t' -v k="$1" '$1 == k { e = $0 } END { if (e != "") print e }' "$EDH_MANIFEST" 2>/dev/null || true)
  if [[ -n "$entry" ]]; then
    want=$(printf '%s' "$entry" | cut -f2); vid=$(printf '%s' "$entry" | cut -f3)
    ( umask 077; aws s3api get-object --bucket "$EDH_BACKUP_BUCKET" --key "$1" --version-id "$vid" \
        --expected-bucket-owner "$EDH_ACCOUNT_ID" --region "$EDH_REGION" "$f" >/dev/null ) \
      || die "could not download $1 (version $vid)"
    got=$(sha256_of "$f")
    if [[ "$got" != "$want" ]]; then
      rm -f "$f"
      die "backup $1 (version $vid) does not match the sha256 in this server's backup manifest — refusing (it may have been tampered with)"
    fi
    log "verified $1 against the backup manifest (version $vid)"
  elif (( UNVERIFIED )); then
    log "WARNING: $1 is not in this server's backup manifest — restoring it UNVERIFIED (--unverified)"
    alert "unverified backup restored" "edh-restore.sh $cmd used $1, which is not in this server's backup manifest (--unverified): it may not have been made by this server's backup job."
    ( umask 077; aws s3api get-object --bucket "$EDH_BACKUP_BUCKET" --key "$1" \
        --expected-bucket-owner "$EDH_ACCOUNT_ID" --region "$EDH_REGION" "$f" >/dev/null ) \
      || die "could not download $1"
  else
    # an object under db/ that this server's backup job didn't make is a tamper signal: alert (replace alerts on exit)
    if [[ "$cmd" == check ]]; then
      alert "restore refused: backup not in manifest" "edh-restore.sh check was asked for $1, which is not in this server's backup manifest: something other than this server's backup job may have uploaded it."
    fi
    die "backup $1 is not in this server's backup manifest. If the server was rebuilt and the manifest lost, see references/backup-restore.md before using --unverified."
  fi
  printf '%s' "$f"
}
# need_space <dump-file> — restoring needs room: free space on the data volume must exceed twice the dump's size
need_space() {
  local avail need
  avail=$(df -Pk "$EDH_DATA_DIR" | awk 'NR == 2 { print $4 }')
  need=$(( ($(wc -c < "$1") / 1024 + 1) * 2 ))
  (( avail > need )) || die "not enough free space on $EDH_DATA_DIR to restore: ${avail} KB free, need more than ${need} KB (2x the dump)"
}
restore_into() { # restore_into <database> <dump-file>
  pg "drop database if exists \"$1\" with (force)" postgres >/dev/null
  pg "create database \"$1\" owner app" postgres >/dev/null
  dc exec -T postgres pg_restore -U app -d "$1" --no-owner --exit-on-error < "$2"
}
table_count() { pg "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')" "$1"; }

# pick — read-only, from the manifest alone (no lock, no AWS call): what --latest / --date restore
if [[ "${1:-}" == pick ]]; then
  day="${2:-}"; d=""
  [[ -z "$day" || "$day" =~ ^[0-9]{8}$ ]] || die "usage: edh-restore.sh pick [YYYYMMDD]"
  if [[ -n "$day" ]]; then d="${day:0:4}-${day:4:2}-${day:6:2}"; fi
  [[ -f "$EDH_MANIFEST" ]] || exit 0
  # the manifest is in upload order: the last match is the newest
  awk -F'\t' -v d="$d" '$1 ~ /^db\/(hourly|daily|monthly|safety)\/app-[0-9]+T[0-9]+Z\.dump$/ && (d == "" || substr($4, 1, 10) == d) { k = $1; t = $4 }
    END { if (k != "") print k "\t" t }' "$EDH_MANIFEST"
  exit 0
fi

cmd="${1:-}"; key="${2:-}"; keep=0; yes=0
[[ -n "$key" ]] || die "usage: edh-restore.sh check|replace <s3-key> [--keep|--yes] [--unverified]"
case "$cmd" in check|replace) ;; *) die "unknown command: $cmd" ;; esac
shift 2
for a in "$@"; do
  case "$a" in
    --keep) keep=1 ;; --yes) yes=1 ;; --unverified) UNVERIFIED=1 ;;
    *) die "unknown option: $a" ;;
  esac
done
if [[ "$cmd" == replace && $yes != 1 ]]; then die "replace needs --yes"; fi
edh_lock

if [[ "$cmd" == check ]]; then
  f=$(fetch "$key")
  need_space "$f"
  restore_into app_restore_check "$f"
  n=$(table_count app_restore_check)
  log "restored $key into app_restore_check: $n tables"
  (( n > 0 )) || die "restore produced no tables"
  if (( ! keep )); then pg 'drop database app_restore_check with (force)' postgres >/dev/null; fi
  rm -f "$f"
  echo "$n"
  exit 0
fi

# --- replace
stage=prepare; safety=""; f=""
on_exit() {
  local rc=$? dbs state health
  trap - EXIT
  if (( rc == 0 )); then exit 0; fi
  case "$stage" in
    prepare)
      alert "restore failed" "Restoring $key failed before anything changed: the live database is untouched." ;;
    maint|swap)
      # the renames run in one transaction; look at which databases exist to report what the app now uses
      dbs=$(pg "select string_agg(datname, ',' order by datname) from pg_database where datname in ('app', 'app_pre_restore', 'app_restore_new')" postgres 2>/dev/null || echo unknown)
      case ",$dbs," in
        *,app_pre_restore,*) state="the swap completed: the live database holds the restored data; the previous data is in app_pre_restore" ;;
        *,app,*app_restore_new,*) state="the live database is unchanged" ;;
        *) state="unexpected database state ($dbs) — check before using the app" ;;
      esac
      dc start app >/dev/null 2>&1 || true
      if wait_health; then "$EDH_BIN_DIR/edh-maint.sh" off >/dev/null || true; health="the app is healthy"; else health="the app fails /health; maintenance left ON"; fi
      alert "restore failed" "Restoring $key failed: $state; $health. Safety dump: ${safety:-none taken}." ;;
    swapped)
      alert "restore: app unhealthy" "Restored $key but the app fails /health. Maintenance page left ON. The previous data is in database app_pre_restore; safety dump: ${safety:-none}." ;;
  esac
  if [[ -n "$f" ]]; then rm -f "$f"; fi
  exit "$rc"
}
trap on_exit EXIT

f=$(fetch "$key")
need_space "$f"
dc exec -T postgres pg_restore --list < "$f" >/dev/null || die "$key is not a readable pg_dump archive — live database untouched"
restore_into app_restore_new "$f"   # the app keeps serving meanwhile
n=$(table_count app_restore_new)
(( n > 0 )) || die "restoring $key produced no tables — live database untouched"
if [[ "$(pg "select count(*) from pg_database where datname = 'app_pre_restore'" postgres)" != 0 ]]; then
  log "dropping app_pre_restore left by an earlier restore"
  pg 'drop database app_pre_restore with (force)' postgres >/dev/null
fi

stage=maint
"$EDH_BIN_DIR/edh-maint.sh" on --message "We're restoring data from a backup." --until "in a few minutes" >/dev/null
safety=$("$EDH_BIN_DIR/edh-backup.sh" --tag safety --force)
stage=swap
dc stop app
pg "select pg_terminate_backend(pid) from pg_stat_activity where datname in ('app', 'app_restore_new') and pid <> pg_backend_pid()" postgres >/dev/null
pg 'alter database app rename to app_pre_restore; alter database app_restore_new rename to app' postgres >/dev/null
stage=swapped
dc start app
wait_health || die "app unhealthy after restore — maintenance left ON"
"$EDH_BIN_DIR/edh-maint.sh" off >/dev/null
stage=finished
rm -f "$f"
log "restore of $key complete (safety dump: $safety). The previous data is in database app_pre_restore; drop it when no longer needed: drop database app_pre_restore"
