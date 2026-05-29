#!/usr/bin/env bash
# allocate-port.sh <ssh-target> <env> [desired-offset]
#
# Picks a UNIQUE host port for a new app+env and verifies it is actually free on
# the live host. Scheme: prod = 3000+offset, staging = 4000+offset (offset 1-99).
# Containers always listen on 3000 internally; only this host-side port differs.
# Prints two lines:  OFFSET=<n>   HOST_PORT=<port>
#
# Reusing a port that another app already publishes is the #1 way to break a
# neighbor, so this always checks the live inventory rather than trusting a list.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"

TARGET="${1:-}"; ENV="${2:-}"; WANT="${3:-}"
[[ -n "$TARGET" && -n "$ENV" ]] || die "usage: $0 <user@host> <prod|staging> [desired-offset]"
case "$ENV" in prod) BASE=3000;; staging) BASE=4000;; *) die "env must be prod|staging";; esac

used="$(ssh_run "$TARGET" "docker ps --format '{{.Ports}}'" 2>/dev/null \
  | grep -oE ':[0-9]+->' | grep -oE '[0-9]+' | sort -n | uniq)"

is_free() { ! grep -qx "$1" <<<"$used"; }

if [[ -n "$WANT" ]]; then
  port=$((BASE + WANT))
  is_free "$port" || die "requested offset $WANT -> port $port is already in use on the host"
  echo "OFFSET=$WANT"; echo "HOST_PORT=$port"; exit 0
fi

for off in $(seq 1 99); do
  port=$((BASE + off))
  if is_free "$port"; then echo "OFFSET=$off"; echo "HOST_PORT=$port"; exit 0; fi
done
die "no free offset in 1-99 for env $ENV — host is unusually full, investigate"
