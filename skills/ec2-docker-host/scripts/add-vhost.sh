#!/usr/bin/env bash
# add-vhost.sh <fqdn> <host-port> <ssh-target> [shape]
#
# Adds ONE additive Caddy vhost and reloads — validate, then swap, then reload,
# never restart. A malformed block can never interrupt the vhosts already
# serving traffic, because the live config is only swapped after it validates.
#
# shape: reverse_proxy (default) | static:<release-dir>
# Idempotent: if a block for <fqdn> already exists, it does nothing.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"

FQDN="${1:-}"; PORT="${2:-}"; TARGET="${3:-}"; SHAPE="${4:-reverse_proxy}"
[[ -n "$FQDN" && -n "$TARGET" ]] || die "usage: $0 <fqdn> <host-port> <user@host> [reverse_proxy|static:<dir>]"
[[ "$SHAPE" == "reverse_proxy" && -z "$PORT" ]] && die "reverse_proxy shape needs a host port"

# Build the block locally.
case "$SHAPE" in
  reverse_proxy)
    BLOCK=$(cat <<EOF

# --- $FQDN (added by ec2-docker-host) ---
$FQDN {
	reverse_proxy 127.0.0.1:$PORT
	encode gzip zstd
}
EOF
);;
  static:*)
    DIR="${SHAPE#static:}"
    BLOCK=$(cat <<EOF

# --- $FQDN (static, added by ec2-docker-host) ---
$FQDN {
	root * $DIR
	file_server
	encode gzip zstd
}
EOF
);;
  *) die "unknown shape: $SHAPE";;
esac

log "Adding vhost for $FQDN -> ${PORT:-$SHAPE} on $TARGET (additive, validate-then-reload)"

ssh_run "$TARGET" bash <<EOF
set -euo pipefail
CF=/etc/caddy/Caddyfile
if sudo grep -qE "^${FQDN//./\\.} \{" "\$CF" 2>/dev/null; then
  echo "  vhost for $FQDN already present — nothing to do"; exit 0
fi
# Compose a candidate config = current + new block.
sudo cp "\$CF" /tmp/Caddyfile.cur
cat /tmp/Caddyfile.cur - > /tmp/Caddyfile.new <<BLOCKEOF
$BLOCK
BLOCKEOF
# Validate the candidate; only swap if it passes.
if ! sudo caddy validate --adapter caddyfile --config /tmp/Caddyfile.new; then
  echo "ERROR: candidate Caddyfile failed validation — live config left untouched." >&2
  rm -f /tmp/Caddyfile.new; exit 1
fi
sudo install -m 644 -o root -g root /tmp/Caddyfile.new "\$CF"
sudo systemctl reload caddy
rm -f /tmp/Caddyfile.new /tmp/Caddyfile.cur
echo "  reloaded caddy with $FQDN added"
EOF
ok "vhost live — first HTTPS request to https://$FQDN will trigger cert issuance"
