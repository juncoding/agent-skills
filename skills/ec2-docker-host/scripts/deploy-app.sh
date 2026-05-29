#!/usr/bin/env bash
# deploy-app.sh <app> <env> <image> <host-port> <ssh-target> [compose-file]
#
# Deploys (or redeploys) one app as its own Compose project, neighbor-safely:
#   1. Copies the deploy compose file to ~/apps/<app>-<env>/ on the host.
#   2. Writes a deploy-time .env (APP/ENV/IMAGE/HOST_PORT).
#   3. Pulls the image FIRST — if the pull fails (bad tag, registry down) it
#      aborts BEFORE touching the running container, so a typo can't take the
#      app down.
#   4. `docker compose up -d --remove-orphans` — scoped to this project only.
#   5. Polls /health until healthy.
#
# <image> is a full immutable reference, e.g. ghcr.io/me/myapp:main-<sha> or
# <acct>.dkr.ecr.<region>.amazonaws.com/myapp:main-<sha>. Refuses :latest.
# Registry login is assumed already configured on the host (deploy token, or
# instance profile for ECR — see references/secrets-and-images.md).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"

APP="${1:-}"; ENV="${2:-}"; IMAGE="${3:-}"; HOST_PORT="${4:-}"; TARGET="${5:-}"
COMPOSE_FILE="${6:-deploy/docker-compose.yml}"
[[ -n "$APP" && -n "$ENV" && -n "$IMAGE" && -n "$HOST_PORT" && -n "$TARGET" ]] \
  || die "usage: $0 <app> <prod|staging> <image-ref> <host-port> <user@host> [compose-file]"
[[ "$IMAGE" == *:latest ]] && die "refusing :latest — use an immutable <branch>-<sha> tag for deterministic rollback"
[[ -f "$COMPOSE_FILE" ]] || die "compose file not found: $COMPOSE_FILE (run from the app repo root or pass the path)"

# Relative path resolves to the SSH user's home dir on the host.
HOST_DIR="apps/${APP}-${ENV}"

log "Deploying $APP ($ENV) -> $IMAGE  on $TARGET  (host port $HOST_PORT)"

ssh_run "$TARGET" "mkdir -p '$HOST_DIR'"
scp_to "$COMPOSE_FILE" "$TARGET" "$HOST_DIR/docker-compose.yml"

ssh_run "$TARGET" bash <<EOF
set -euo pipefail
cd "$HOST_DIR"
cat > .env <<ENVEOF
APP=$APP
ENV=$ENV
IMAGE=$IMAGE
HOST_PORT=$HOST_PORT
ENVEOF

echo "==> pulling image (abort-before-swap if this fails)"
if ! docker pull "$IMAGE"; then
  echo "ERROR: pull failed for $IMAGE — leaving the running container untouched." >&2
  exit 1
fi

echo "==> docker compose up -d (scoped to project ${APP}-${ENV})"
docker compose up -d --remove-orphans
docker compose ps
EOF

log "Waiting for /health (up to 60s)"
for i in $(seq 1 30); do
  if ssh_run "$TARGET" "curl -fsS -m 4 http://127.0.0.1:$HOST_PORT/health >/dev/null 2>&1"; then
    ok "$APP ($ENV) healthy on 127.0.0.1:$HOST_PORT"
    exit 0
  fi
  sleep 2
done
warn "health did not turn green within 60s — check: ssh $TARGET 'docker logs ${APP}-${ENV} --tail 50'"
exit 1
