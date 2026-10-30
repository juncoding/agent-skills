#!/usr/bin/env bash
# edh-restore.sh check <s3-key> [--keep]   restore into side database app_restore_check, count tables, drop it
# edh-restore.sh replace <s3-key> --yes    replace the live database:
#     validate the dump → restore it into app_restore_new (the app keeps serving) → maintenance on → safety dump
#     → stop app → rename app → app_pre_restore, app_restore_new → app → start app → /health → maintenance off.
#     The previous data stays in database app_pre_restore until you drop it. Any failure alerts.
# shellcheck source-path=SCRIPTDIR source=edh-lib.sh
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh" || { echo "edh-restore: cannot load edh-lib.sh" >&2; exit 1; }

fetch() { # fetch <s3-key> → local path (0600)
  local f; f="$EDH_DATA_DIR/backups/restore-$(basename "$1")"
  if [[ ! -s "$f" ]]; then ( umask 077; aws s3 cp "s3://$EDH_BACKUP_BUCKET/$1" "$f" --region "$EDH_REGION" --only-show-errors ); fi
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

cmd="${1:-}"; key="${2:-}"; opt="${3:-}"
[[ -n "$key" ]] || die "usage: edh-restore.sh check|replace <s3-key> [--keep|--yes]"
case "$cmd" in check|replace) ;; *) die "unknown command: $cmd" ;; esac
if [[ "$cmd" == replace && "$opt" != --yes ]]; then die "replace needs --yes"; fi
edh_lock

if [[ "$cmd" == check ]]; then
  f=$(fetch "$key")
  need_space "$f"
  restore_into app_restore_check "$f"
  n=$(table_count app_restore_check)
  log "restored $key into app_restore_check: $n tables"
  (( n > 0 )) || die "restore produced no tables"
  if [[ "$opt" != --keep ]]; then pg 'drop database app_restore_check with (force)' postgres >/dev/null; fi
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
