#!/usr/bin/env bash
# edh-restore.sh check <s3-key> [--keep]   restore into side database app_restore_check, count tables
# edh-restore.sh replace <s3-key> --yes    replace the live database: maintenance on → safety dump → restore → health → off
# shellcheck source-path=SCRIPTDIR source=edh-lib.sh
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh" || { echo "edh-restore: cannot load edh-lib.sh" >&2; exit 1; }

fetch() { # fetch <s3-key> → local path
  local f; f="$EDH_DATA_DIR/backups/restore-$(basename "$1")"
  if [[ ! -s "$f" ]]; then aws s3 cp "s3://$EDH_BACKUP_BUCKET/$1" "$f" --region "$EDH_REGION" --only-show-errors; fi
  printf '%s' "$f"
}
restore_into() { # restore_into <database> <dump-file>
  pg "drop database if exists \"$1\" with (force)" postgres >/dev/null
  pg "create database \"$1\" owner app" postgres >/dev/null
  dc exec -T postgres pg_restore -U app -d "$1" --no-owner --exit-on-error < "$2"
}
table_count() { pg "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')" "$1"; }

cmd="${1:-}"; key="${2:-}"; opt="${3:-}"
[[ -n "$key" ]] || die "usage: edh-restore.sh check|replace <s3-key> [--keep|--yes]"
case "$cmd" in
  check)
    f=$(fetch "$key")
    restore_into app_restore_check "$f"
    n=$(table_count app_restore_check)
    log "restored $key into app_restore_check: $n tables"
    (( n > 0 )) || die "restore produced no tables"
    if [[ "$opt" != --keep ]]; then pg 'drop database app_restore_check with (force)' postgres >/dev/null; fi
    rm -f "$f"
    echo "$n" ;;
  replace)
    [[ "$opt" == --yes ]] || die "replace needs --yes"
    f=$(fetch "$key")
    "$EDH_BIN_DIR/edh-maint.sh" on --message "We're restoring data from a backup." --until "in a few minutes" >/dev/null
    "$EDH_BIN_DIR/edh-backup.sh" --tag safety --force >/dev/null
    dc stop app
    restore_into app "$f"
    dc start app
    if ! wait_health 30; then
      alert "restore: app unhealthy" "Restored $key but the app fails /health. Maintenance page left ON."
      die "app unhealthy after restore — maintenance left ON"
    fi
    "$EDH_BIN_DIR/edh-maint.sh" off >/dev/null
    rm -f "$f"
    log "restore of $key complete" ;;
  *) die "unknown command: $cmd" ;;
esac
