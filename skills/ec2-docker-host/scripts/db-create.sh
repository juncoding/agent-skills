#!/usr/bin/env bash
# db-create.sh <app> <env> <ssh-target>
#
# Creates a per-app Postgres database + a dedicated role scoped to only that DB,
# with a generated password, then records the connection URL as a secret.
# Idempotent: if the DB/role already exist it leaves them alone.
#
#   prod    -> database & role "<app>"
#   staging -> database & role "<app>_staging"
#
# Secret recording (lightweight default): appends DATABASE_URL to
# /data/secrets/<app>-<env>.env (chmod 600). For the SSM upgrade, set
# SECRET_BACKEND=ssm and SSM_PREFIX=/apps to put-parameter instead.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"

APP="${1:-}"; ENV="${2:-}"; TARGET="${3:-}"
[[ -n "$APP" && -n "$ENV" && -n "$TARGET" ]] || die "usage: $0 <app> <prod|staging> <user@host>"
case "$ENV" in prod) DB="$APP"; ROLE="${APP}";; staging) DB="${APP}_staging"; ROLE="${APP}_staging";; *) die "env must be prod|staging";; esac

PW="$(gen_secret 40)"
log "Ensuring database '$DB' and role '$ROLE' on $TARGET"

# Create role + db idempotently inside the shared postgres container.
ssh_run "$TARGET" bash <<EOF
set -euo pipefail
exists_role=\$(docker exec postgres psql -U postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='$ROLE';")
if [[ "\$exists_role" != "1" ]]; then
  docker exec postgres psql -U postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE \"$ROLE\" LOGIN PASSWORD '$PW';"
  echo "  created role $ROLE"
else
  echo "  role $ROLE already exists (leaving password unchanged)"
fi
exists_db=\$(docker exec postgres psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB';")
if [[ "\$exists_db" != "1" ]]; then
  docker exec postgres psql -U postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$DB\" OWNER \"$ROLE\";"
  echo "  created database $DB"
else
  echo "  database $DB already exists"
fi
EOF

URL="postgres://${ROLE}:${PW}@postgres:5432/${DB}"

if [[ "${SECRET_BACKEND:-file}" == "ssm" ]]; then
  PREFIX="${SSM_PREFIX:-/apps}/$APP/$ENV"
  aws ssm put-parameter --name "$PREFIX/postgres-url" --type SecureString --overwrite --value "$URL" >/dev/null
  aws ssm put-parameter --name "$PREFIX/postgres-password" --type SecureString --overwrite --value "$PW" >/dev/null
  ok "recorded postgres-url + postgres-password in SSM under $PREFIX"
else
  ssh_run "$TARGET" bash <<EOF
set -euo pipefail
sudo mkdir -p /data/secrets
f=/data/secrets/${APP}-${ENV}.env
sudo touch "\$f"; sudo chmod 600 "\$f"
# replace existing DATABASE_URL line if present, else append
if sudo grep -q '^DATABASE_URL=' "\$f" 2>/dev/null; then
  sudo sed -i "s#^DATABASE_URL=.*#DATABASE_URL=$URL#" "\$f"
else
  echo "DATABASE_URL=$URL" | sudo tee -a "\$f" >/dev/null
fi
EOF
  ok "recorded DATABASE_URL in /data/secrets/${APP}-${ENV}.env (chmod 600)"
fi

warn "DB URL (host-internal): postgres://${ROLE}:****@postgres:5432/${DB}"
