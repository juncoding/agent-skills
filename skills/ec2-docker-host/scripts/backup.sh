#!/usr/bin/env bash
# backup.sh <ssh-target>
#
# Runs the logical-dump + off-host-sync backup layers (the volume-snapshot layer
# is a provider call scheduled separately — see references/backups-and-maintenance.md).
#   - pg_dumpall (roles + all per-app DBs) -> /data/backups, atomic .tmp+rename
#   - mongodump --gzip --archive (if mongo present)
#   - prune local dumps older than 14 days
#   - optional: sync /data/backups to an object store if BACKUP_S3 is set
#
# Filenames use UTC to avoid DST ambiguity. Intended to run from host cron, but
# can be invoked over SSH for an on-demand backup or a restore-drill prep.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"

TARGET="${1:-}"; [[ -n "$TARGET" ]] || die "usage: $0 <user@host>   (env: BACKUP_S3=s3://bucket/prefix)"
S3="${BACKUP_S3:-}"

log "Running logical backups on $TARGET"
ssh_run "$TARGET" bash <<EOF
set -euo pipefail
ts=\$(date -u +%Y%m%dT%H%M%SZ)
dir=/data/backups
sudo mkdir -p "\$dir"

# Postgres: dump to .tmp then atomically rename so a partial dump is never seen as good.
if docker ps --format '{{.Names}}' | grep -qx postgres; then
  docker exec postgres pg_dumpall -U postgres | gzip | sudo tee "\$dir/pg_all_\$ts.sql.gz.tmp" >/dev/null
  sudo mv "\$dir/pg_all_\$ts.sql.gz.tmp" "\$dir/pg_all_\$ts.sql.gz"
  echo "  postgres -> pg_all_\$ts.sql.gz (\$(sudo du -h "\$dir/pg_all_\$ts.sql.gz" | cut -f1))"
fi

# Mongo: archive+gzip if present.
if docker ps --format '{{.Names}}' | grep -qx mongo; then
  docker exec mongo sh -c 'mongodump --gzip --archive' | sudo tee "\$dir/mongo_\$ts.archive.gz.tmp" >/dev/null
  sudo mv "\$dir/mongo_\$ts.archive.gz.tmp" "\$dir/mongo_\$ts.archive.gz"
  echo "  mongo -> mongo_\$ts.archive.gz"
fi

# Prune local copies older than 14 days (off-host keeps the long tail).
sudo find "\$dir" -name '*.gz' -mtime +14 -delete
echo "  pruned local dumps older than 14d"
EOF

if [[ -n "$S3" ]]; then
  log "Syncing /data/backups off-host -> $S3"
  ssh_run "$TARGET" "aws s3 sync /data/backups '$S3' --no-progress" \
    && ok "off-host sync complete" \
    || warn "off-host sync failed — check the host's credentials/instance profile"
else
  warn "BACKUP_S3 not set — skipped off-host sync (local dumps only; not disaster-safe)"
fi
ok "backup run complete"
