#!/usr/bin/env bash
# backup.sh now        take a backup immediately (uploaded to db/daily/)
# backup.sh list [N]   newest N backups in S3 (default 20)
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config
case "${1:-}" in
  now)
    require_account
    require_instance
    ssm_run "$EDH_IID" 2400 '/opt/edh/bin/edh-backup.sh --tag manual --force' || die "backup failed (see the output above)"
    ok "backup uploaded to db/daily/" ;;
  list)
    n="${2:-20}"; [[ "$n" =~ ^[0-9]+$ ]] || die "N must be a number"
    ACCT=$(aws_account)
    # newest by upload time (columns 1-2), not by key, which would group them by folder
    awsr s3 ls "s3://${EDH_PREFIX}-backups-${ACCT}/db/" --recursive | sort -k1,2 | tail -n "$n" ;;
  *) die "usage: backup.sh now | list [N]" ;;
esac
