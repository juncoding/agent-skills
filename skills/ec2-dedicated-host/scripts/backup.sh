#!/usr/bin/env bash
# backup.sh now        take a backup immediately (uploaded to db/daily/)
# backup.sh list [N]   newest N backups in S3 (default 20): upload time, size, key — what the bucket holds, not
#                      verified against the server's backup manifest
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config
case "${1:-}" in
  now)
    oplog_begin backup now
    require_account
    require_instance
    out=$(ssm_run "$EDH_IID" 2400 '/opt/edh/bin/edh-backup.sh --tag manual --force') \
      || { printf '%s\n' "$out"; die "backup failed (see the output above)"; }
    printf '%s\n' "$out"
    name=$(printf '%s\n' "$out" | tail -n 1)   # edh-backup.sh prints the dump's file name last
    if [[ "$name" =~ ^app-[0-9]{8}T[0-9]{6}Z\.dump$ ]]; then OPLOG_DETAIL="now db/daily/$name"; fi
    ok "backup uploaded to db/daily/" ;;
  list)
    n="${2:-20}"; [[ "$n" =~ ^[0-9]+$ ]] || die "N must be a number"
    ACCT=$(aws_account)
    # this account's bucket only (bucket names are global); newest by upload time, not by key (which would group
    # them by folder)
    rows=$(awsr s3api list-objects-v2 --bucket "${EDH_PREFIX}-backups-${ACCT}" --prefix db/ --expected-bucket-owner "$ACCT" \
      --query 'Contents[].[LastModified,Size,Key]' --output text) || die "cannot list s3://${EDH_PREFIX}-backups-${ACCT}/db/"
    printf '%s\n' "$rows" | { grep -v -e '^None$' -e '^$' || true; } | sort -k1,1 | tail -n "$n" ;;
  *) die "usage: backup.sh now | list [N]" ;;
esac
