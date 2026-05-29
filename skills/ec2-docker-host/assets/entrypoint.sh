#!/usr/bin/env sh
# App container entrypoint. Lives in the APP's repo (e.g. deploy/entrypoint.sh),
# baked into the image, and set as the container's entrypoint behind `tini`.
#
# Order matters: load secrets -> alias the DB URL -> migrate -> exec the app.
# `exec` at the end means signals (SIGTERM) reach the app for a clean shutdown.
set -eu

# --- 1. Load secrets ---------------------------------------------------------
# Lightweight backend: secrets arrive as env vars via the compose `env_file:`
# (/data/secrets/<app>-<env>.env), so there's nothing to fetch here.
#
# AWS-native (SSM) backend: pull this app's namespace at boot and export each.
# Uncomment when SECRET_BACKEND=ssm. Needs AWS_REGION + the host instance profile.
#
# if [ "${SECRET_BACKEND:-file}" = "ssm" ]; then
#   prefix="/apps/${APP}/${ENV}"
#   eval "$(aws ssm get-parameters-by-path --path "$prefix" --with-decryption \
#       --query 'Parameters[].[Name,Value]' --output text \
#     | while read -r name value; do
#         key=$(basename "$name" | tr '[:lower:]-' '[:upper:]_')
#         printf 'export %s=%s\n' "$key" "$value"
#       done)"
# fi

# --- 2. Alias the canonical DB URL to what the migrator expects --------------
# db-create.sh records DATABASE_URL. If your ORM/migrator wants a different name,
# alias it here (example: Prisma also reads DATABASE_URL, so this is often a no-op).
: "${DATABASE_URL:=${POSTGRES_URL:-}}"
export DATABASE_URL

# --- 3. Run migrations (skippable for out-of-band runs) ----------------------
if [ "${SKIP_MIGRATIONS:-0}" != "1" ]; then
  echo "[entrypoint] running migrations"
  # Replace with your tool, e.g.:  npx prisma migrate deploy
  #                                 npm run migrate:deploy
  #                                 ./bin/rails db:migrate
  :
fi

# --- 4. Hand off to the app (PID-forwarded by tini) --------------------------
echo "[entrypoint] starting app ($APP/$ENV)"
exec "$@"
