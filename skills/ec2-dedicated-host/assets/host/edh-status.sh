#!/usr/bin/env bash
# edh-status.sh — one-screen health summary of this server (read-only).
# shellcheck source-path=SCRIPTDIR source=edh-lib.sh
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh" || { echo "edh-status: cannot load edh-lib.sh" >&2; exit 1; }
echo "maintenance: $("$EDH_BIN_DIR/edh-maint.sh" status)"
echo "image: $(sed -n 's/^APP_IMAGE=//p' "$EDH_APP_DIR/.env" 2>/dev/null)"
echo "last deploy: $(tail -1 "$EDH_DATA_DIR/deploys.log" 2>/dev/null || echo none)"
last=$(ls -1t "$EDH_DATA_DIR"/backups/app-*.dump 2>/dev/null | head -1 || true)
if [[ -n "$last" ]]; then echo "last local dump: $(basename "$last")"; else echo "last local dump: none"; fi
# freshness = the last successful upload to S3; stale after 2 h (hourly schedule) or 26 h (daily)
schedule=$(backup_schedule 2>/dev/null || echo hourly)
window=$(fresh_minutes "$schedule")
marker="$EDH_DATA_DIR/backups/.last_upload"
if [[ -f "$marker" ]]; then
  age=$(( ($(date +%s) - $(date -r "$marker" +%s)) / 60 ))
  echo "last upload: ${age} min ago ($schedule schedule)$( (( age > window )) && echo '  ← STALE')"
else
  echo "last upload: none  ← STALE"
fi
echo "containers:"; dc ps --format '  {{.Service}}: {{.State}} {{.Health}}' 2>/dev/null || true
echo "disk:"; df -h / "$EDH_DATA_DIR" 2>/dev/null | sed 's/^/  /'
if command -v free >/dev/null; then echo "memory:"; free -m | sed 's/^/  /'; fi
