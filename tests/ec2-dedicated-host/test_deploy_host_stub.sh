# tests/ec2-dedicated-host/test_deploy_host_stub.sh — edh-deploy.sh abort paths with a fake `docker` and the stub
# `aws` (fast; no containers, never real AWS): a first deploy that fails has nothing to fall back to, and an abort
# puts /etc/edh/edh.env back so the health check asks the port the previous version really uses.
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/fake" "$T/s3"
export PATH="$T/fake:$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/aws.log" STUB_S3="$T/s3" STUB_SSM="$T/ssm.tsv"
export EDH_ENV_FILE="$T/etc/edh.env" EDH_APP_DIR="$T/app" EDH_DATA_DIR="$T/data" EDH_BIN_DIR="$T/bin"
export EDH_NO_SYSTEMD=1 EDH_SKIP_PULL=1 EDH_SKIP_PRUNE=1 EDH_HEALTH_TRIES=1 EDH_LOCK_FILE="$T/edh.lock"
printf '%s\t%s\n' /t/prod/_edh/postgres-password pw123abc /t/prod/_edh/maint-bypass tok123 > "$STUB_SSM"
# fake docker: logs every call; a migrate_cmd starting with "exit" fails; pg_dump fails with
# FAKE_DUMP_FAIL=1; the app's /health answers only on port FAKE_HEALTHY_PORT
# `compose … config` runs for real (the compose check renders the staged compose.yml; it needs no daemon)
REAL_DOCKER=$(command -v docker)
cat > "$T/fake/docker" <<EOS
#!/bin/bash
echo "docker \$*" >> "$T/docker.log"
if [[ "\$1" == compose && " \$* " == *" config "* ]]; then exec "$REAL_DOCKER" "\$@"; fi
EOS
cat >> "$T/fake/docker" <<'EOS'
if [[ "$1" == login ]]; then cat >/dev/null; fi
case "$*" in
  *" run --rm --no-deps"*) if [[ "$*" == *"sh -c exit"* ]]; then exit 3; fi ;;
  *"pg_database_size"*) echo 100 ;;
  *" pg_dump "*) if [[ -n "${FAKE_DUMP_FAIL:-}" ]]; then exit 1; fi; echo PGDMP-fake ;;
  *" wget "*)
    if [[ -n "${FAKE_BAD_IMAGE:-}" ]] && grep -qx "APP_IMAGE=$FAKE_BAD_IMAGE" "$EDH_APP_DIR/.env" 2>/dev/null; then exit 1; fi
    if [[ "$*" == *"http://app:${FAKE_HEALTHY_PORT:-3000}/health"* ]]; then exit 0; fi; exit 1 ;;
esac
exit 0
EOS
chmod +x "$T/fake/docker"
export FAKE_DOCKER_LOG="$T/docker.log"
make_release() { # make_release <dir> <migrate_cmd> <app_port>
  local r="$1"; mkdir -p "$r/app/maint" "$r/host/systemd"
  cp "$SKILL_DIR/assets/project/compose.yml" "$SKILL_DIR/assets/project/Caddyfile" "$r/app/"
  cp "$SKILL_DIR/assets/project/maint/"*.html "$r/app/maint/"
  cp "$SKILL_DIR/assets/host/"edh-*.sh "$SKILL_DIR/assets/host/"edh-*.py "$r/host/"
  cat > "$r/release.env" <<EOV
EDH_CLIENT=t
EDH_ENV=prod
EDH_NAME=edhstub
EDH_REGION=ap-southeast-1
EDH_DOMAIN=app.example.com
EDH_SSM_PATH=/t/prod
EDH_BACKUP_BUCKET=bkt
EDH_BACKUP_SCHEDULE=hourly
EDH_DAILY_HOUR_UTC=18
EDH_APP_PORT=$3
EDH_APP_MEMORY_MB=256
EDH_USES_GOTENBERG=false
EDH_MIGRATE_CMD='$2'
EDH_ALERT_TOPIC_ARN=arn:aws:sns:ap-southeast-1:123456789012:edh-t-prod-alerts
EDH_ACCOUNT_ID=123456789012
EOV
}
deploy() { : > "$STUB_LOG"; : > "$FAKE_DOCKER_LOG"; bash "$1/host/edh-deploy.sh" "$1" "$2" >"$T/out" 2>&1; echo $?; }
alert_text() { grep -- 'sns publish' "$STUB_LOG" || true; }
health_checks() { grep -c ' wget ' "$FAKE_DOCKER_LOG" || true; }

# ============ before the first deploy there is nothing to back up: the hourly timer is quiet (no alert)
make_release "$T/r0" "echo migrated" 3000
cp "$T/r0/release.env" "$T/release0.env"
: > "$STUB_LOG"
out=$(EDH_ENV_FILE="$T/release0.env" EDH_BIN_DIR="$T/r0/host" bash "$T/r0/host/edh-backup.sh" 2>&1); rc=$?
assert_status "$rc" 0 "backup before the first deploy: exit 0"
assert_contains "$out" "no app deployed yet" "backup before the first deploy: says why it does nothing"
assert_eq "$(grep -c 'sns publish' "$STUB_LOG")" "0" "backup before the first deploy: no 'backup failed' email"
assert_eq "$(grep -c 'put-object' "$STUB_LOG")" "0" "backup before the first deploy: nothing uploaded"

# manual and safety backups are asked for on purpose: before the first deploy they fail loudly
for tag in manual safety; do
  out=$(EDH_ENV_FILE="$T/release0.env" EDH_BIN_DIR="$T/r0/host" bash "$T/r0/host/edh-backup.sh" --tag "$tag" --force 2>&1); rc=$?
  assert_status "$rc" 1 "--tag $tag before the first deploy: fails"
  assert_contains "$out" "no app deployed yet" "--tag $tag before the first deploy: explained"
done

# ============ the server runs the same compose check, with the real values, before installing anything
make_release "$T/rx" "echo migrated" 3000
printf '  probe:\n    image: busybox\n    env_file: /etc/edh/edh.env\n' >> "$T/rx/app/compose.yml"
rc=$(deploy "$T/rx" img:x)
assert_status "$rc" 1 "server compose check: a refused compose.yml exits 1"
assert_contains "$(cat "$T/out")" "outside the compose directory" "server compose check: explained"
assert_eq "$([[ -e "$EDH_APP_DIR/compose.yml" ]] && echo installed || echo none)" "none" "server compose check: nothing installed"
assert_contains "$(grep -c 'config --no-env-resolution --format json' "$T/docker.log")" "1" "server compose check: normalized config rendered"

# ============ first deploy, migration fails: nothing to fall back to and nothing was serving
make_release "$T/r1" "exit 3" 3000
rc=$(deploy "$T/r1" img:v1)
assert_status "$rc" 1 "first deploy, failed migration: exit 1 (not 3: nothing was serving)"
assert_contains "$(alert_text)" "no previous version" "first deploy, failed migration: the alert says there was no previous version"
assert_not_contains "$(alert_text)" "SITE DOWN" "first deploy, failed migration: no SITE DOWN alert"
assert_eq "$(health_checks)" "0" "first deploy, failed migration: no health check of a version that never ran"

# ============ first deploy, aborted before the switch (pre-deploy backup fails): the same
rc=$(FAKE_DUMP_FAIL=1 deploy "$T/r1" img:v1)
assert_status "$rc" 1 "first deploy, aborted: exit 1"
assert_contains "$(alert_text)" "no previous version" "first deploy, aborted: the alert says there was no previous version"
assert_eq "$(health_checks)" "0" "first deploy, aborted: no health check"

# ============ a good deploy on port 3000
make_release "$T/r2" "echo migrated" 3000
rc=$(deploy "$T/r2" img:v2)
assert_status "$rc" 0 "deploy on port 3000 succeeds"
if [[ "$rc" != 0 ]]; then tail -20 "$T/out"; fi
assert_contains "$(cat "$EDH_ENV_FILE")" "EDH_APP_PORT=3000" "edh.env has port 3000"

# ============ a release moving to port 3001 whose migration fails: edh.env goes back, so the health check asks
# port 3000 — where the previous version really runs — and finds it healthy (no false SITE DOWN)
make_release "$T/r3" "exit 3" 3001
cp "$EDH_ENV_FILE" "$T/edh.env.before"
rc=$(deploy "$T/r3" img:v3)
assert_status "$rc" 1 "port change + failed migration: exit 1"
assert_eq "$(cmp -s "$T/edh.env.before" "$EDH_ENV_FILE" && echo same)" "same" "port change + failed migration: edh.env restored"
assert_contains "$(grep ' wget ' "$FAKE_DOCKER_LOG")" "http://app:3000/health" "port change + failed migration: health checked on the previous port"
assert_not_contains "$(alert_text)" "SITE DOWN" "port change + failed migration: no false SITE DOWN"
assert_contains "$(alert_text)" "Migrations failed" "port change + failed migration: deploy failed alert"
# the same for an abort before the migration
rc=$(FAKE_DUMP_FAIL=1 deploy "$T/r3" img:v3)
assert_status "$rc" 1 "port change + aborted: exit 1"
assert_eq "$(cmp -s "$T/edh.env.before" "$EDH_ENV_FILE" && echo same)" "same" "port change + aborted: edh.env restored"
assert_not_contains "$(alert_text)" "SITE DOWN" "port change + aborted: no false SITE DOWN"

# ============ rollback when .env was missing (so no app.env.prev was saved): the rollback keeps the app.env and
# postgres.env just written instead of deleting them
rc=$(deploy "$T/r2" img:good)
assert_status "$rc" 0 "deploy img:good"
printf 'img:good\n' > "$EDH_APP_DIR/previous_image"
rm -f "$EDH_APP_DIR/.env" "$EDH_APP_DIR/app.env" "$EDH_APP_DIR/postgres.env"
rc=$(FAKE_BAD_IMAGE=img:bad deploy "$T/r2" img:bad)
assert_status "$rc" 2 "unhealthy image, .env missing: rolled back (exit 2)"
assert_eq "$([[ -f "$EDH_APP_DIR/app.env" && -f "$EDH_APP_DIR/postgres.env" ]] && echo kept)" "kept" \
  "rollback without saved copies: app.env and postgres.env not deleted"
assert_contains "$(cat "$EDH_APP_DIR/.env")" "APP_IMAGE=img:good" "rollback without saved copies: back on img:good"

# ============ the registry login comes before the Caddyfile is validated (private caddy images)
rc=$(EDH_SKIP_PULL= deploy "$T/r2" "123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/edh/t:v4")
assert_status "$rc" 0 "deploy with registry login and pull succeeds"
l=$(grep -n '^docker login' "$FAKE_DOCKER_LOG" | head -1 | cut -d: -f1); v=$(grep -n 'caddy validate' "$FAKE_DOCKER_LOG" | head -1 | cut -d: -f1)
assert_eq "$(( ${l:-999} < ${v:-0} ))" "1" "ECR login before the caddy validate run"
finish
