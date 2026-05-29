#!/usr/bin/env bash
# discover-host.sh <ssh-target>
#
# READ-ONLY host inventory. Run this before changing anything on a host so your
# decisions (free ports, existing DBs, live vhosts) are grounded in reality.
# Prints: containers + published ports, networks, shared DBs, reverse proxy +
# served domains, /data usage, and any backup cron. Mutates nothing.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"

TARGET="${1:-}"; [[ -n "$TARGET" ]] || die "usage: $0 <user@host>"

log "Inventorying $TARGET (read-only)"
ssh_run "$TARGET" bash <<'EOF'
set -uo pipefail
echo "=== containers (name | status | image | host ports) ==="
docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null || echo "  (docker not available?)"
echo
echo "=== published host ports in use ==="
docker ps --format '{{.Ports}}' 2>/dev/null | grep -oE '127\.0\.0\.1:[0-9]+|0\.0\.0\.0:[0-9]+|:[0-9]+->' | grep -oE '[0-9]+' | sort -n | uniq | paste -sd' ' -
echo
echo "=== docker networks ==="
docker network ls --format '{{.Name}}\t{{.Driver}}' 2>/dev/null
echo
echo "=== shared databases ==="
for c in postgres mongo redis; do
  if docker ps --format '{{.Names}}' | grep -qx "$c"; then echo "  $c: running"; else echo "  $c: (not found)"; fi
done
if docker ps --format '{{.Names}}' | grep -qx postgres; then
  echo "  postgres databases:"; docker exec postgres psql -U postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate=false;" 2>/dev/null | sed 's/^/    - /'
fi
echo
echo "=== reverse proxy ==="
if systemctl is-active --quiet caddy 2>/dev/null; then
  echo "  caddy: systemd service (active)"
  echo "  served sites:"; grep -oE '^[a-zA-Z0-9.*_-]+\.[a-zA-Z]+ \{|^[a-zA-Z0-9.*_-]+ \{' /etc/caddy/Caddyfile 2>/dev/null | sed 's/ {//; s/^/    - /'
elif docker ps --format '{{.Names}}' | grep -qiE 'caddy|nginx|traefik'; then
  echo "  containerized proxy: $(docker ps --format '{{.Names}}' | grep -iE 'caddy|nginx|traefik')"
else
  echo "  (no caddy/nginx/traefik detected)"
fi
echo
echo "=== /data volume ==="
if mountpoint -q /data 2>/dev/null; then df -h /data | tail -n1 | awk '{print "  mounted: "$2" total, "$3" used, "$5" full"}'; ls /data 2>/dev/null | sed 's/^/    - /'; else echo "  (no /data mountpoint)"; fi
echo
echo "=== backup cron ==="
( crontab -l 2>/dev/null; sudo crontab -l 2>/dev/null ) | grep -iE 'backup|dump|snapshot' | sed 's/^/  /' || echo "  (none found in crontab)"
EOF
ok "discovery complete — review for anything unexpected before deploying"
