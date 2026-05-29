#!/usr/bin/env bash
# Shared helpers sourced by the other scripts. Not meant to be run directly.
#
# Connection: pass an SSH target as "<user>@<host>" (e.g. ubuntu@203.0.113.10).
# Optional env:
#   SSH_KEY   path to the private key (adds -i)
#   SSH_OPTS  extra ssh/scp options
# Resolve a host's public IP from an instance id (optional convenience):
#   host_ip_from_instance <instance-id> [region]

set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m  ! \033[0m%s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

_ssh_key_opt() { [[ -n "${SSH_KEY:-}" ]] && printf -- '-i %s' "$SSH_KEY"; }

# Run a command (or a heredoc on stdin) on the host.
#   ssh_run ubuntu@host "docker ps"
#   ssh_run ubuntu@host bash <<'EOF' ... EOF
ssh_run() {
  local target="$1"; shift
  # shellcheck disable=SC2086
  ssh $(_ssh_key_opt) -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ${SSH_OPTS:-} "$target" "$@"
}

# Copy a local file to the host.
scp_to() {
  local src="$1" target="$2" dest="$3"
  # shellcheck disable=SC2086
  scp $(_ssh_key_opt) -o StrictHostKeyChecking=accept-new ${SSH_OPTS:-} "$src" "$target:$dest"
}

# Resolve public IP from an EC2 instance id (needs awscli + creds).
host_ip_from_instance() {
  local id="$1" region="${2:-}"
  aws ec2 describe-instances ${region:+--region "$region"} --instance-ids "$id" \
    --query 'Reservations[].Instances[].PublicIpAddress' --output text
}

# Detect the shared docker network name on the host (defaults to infra_net).
detect_network() {
  local target="$1"
  ssh_run "$target" "docker network ls --format '{{.Name}}' | grep -E '^(infra_net|infra|shared)$' | head -n1" || true
}

# Generate a URL-safe random secret of N chars (default 40).
gen_secret() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-40}"; }

require() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
