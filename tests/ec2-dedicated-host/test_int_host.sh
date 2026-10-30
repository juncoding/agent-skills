# tests/ec2-dedicated-host/test_int_host.sh — deploy, rollback, failed migration, backup, restore, maintenance.
# Runs the real host scripts on this machine against Docker, with the stub `aws` (never real AWS).
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); P=edhhosttest   # P = EDH_NAME = compose project name
export PATH="$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/aws.log" STUB_S3="$T/s3" STUB_SSM="$T/ssm.tsv"
export EDH_ENV_FILE="$T/etc/edh.env" EDH_APP_DIR="$T/app" EDH_DATA_DIR="$T/data" EDH_BIN_DIR="$T/bin"
export EDH_NO_SYSTEMD=1 EDH_SKIP_PULL=1 EDH_HTTP_PORT=18081 EDH_HTTPS_PORT=18443
cleanup() { docker compose -p $P down -v >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
# bail <message> [output] — fail, show the output, stop
bail() { fail "$1"; if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" | tail -30 | sed 's/^/    /'; fi; finish; }

docker compose -p $P down -v >/dev/null 2>&1   # leftovers from an interrupted run
out=$(docker build -q -t edh-fixture:good --build-arg HEALTHY=1 "$TESTS_DIR/fixtures/app" 2>&1) || bail "docker build failed" "$out"
out=$(docker build -q -t edh-fixture:bad  --build-arg HEALTHY=0 "$TESTS_DIR/fixtures/app" 2>&1) || bail "docker build failed" "$out"
: > "$STUB_LOG"
printf '/t/prod/_edh/postgres-password\tpw123abc\n/t/prod/_edh/maint-bypass\ttok123\n/t/prod/api-key\tsecret-value\n' > "$STUB_SSM"

make_release() { # make_release <dir> <migrate_cmd>
  local r="$1"; mkdir -p "$r/app/maint" "$r/host/systemd"
  cp "$SKILL_DIR/assets/project/compose.yml" "$SKILL_DIR/assets/project/Caddyfile" "$r/app/"
  cp "$SKILL_DIR/assets/project/maint/"*.html "$r/app/maint/"
  cp "$SKILL_DIR/assets/host/"edh-*.sh "$r/host/"
  cat > "$r/release.env" <<EOF
EDH_CLIENT=t
EDH_ENV=prod
EDH_NAME=$P
EDH_REGION=ap-southeast-1
EDH_DOMAIN=:80
EDH_SSM_PATH=/t/prod
EDH_BACKUP_BUCKET=bkt
EDH_BACKUP_SCHEDULE=auto
EDH_DAILY_HOUR_UTC=18
EDH_APP_PORT=3000
EDH_APP_MEMORY_MB=256
EDH_USES_GOTENBERG=false
EDH_MIGRATE_CMD='$2'
EDH_ALERT_TOPIC_ARN=arn:aws:sns:ap-southeast-1:123456789012:edh-t-prod-alerts
EOF
}
deploy() { bash "$1/host/edh-deploy.sh" "$1" "$2" >"$T/out" 2>&1; echo $?; }
img() { sed -n 's/^APP_IMAGE=//p' "$T/app/.env"; }

# first_deploy — deploy r1, retrying once from scratch on a Docker Desktop (macOS) glitch: a freshly chowned
# bind-mounted file sometimes still shows the old owner, so the postgres image's first-boot init dies with
# "data directory ... has wrong ownership" and the restarted container skips init, leaving no "app" database.
# Linux bind mounts don't do this; the retry only triggers on that exact log line.
first_deploy() {
  local rc; rc=$(deploy "$T/r1" edh-fixture:good)
  if [[ "$rc" == 0 ]] && ! ( . "$EDH_BIN_DIR/edh-lib.sh"; pg "select 1" ) >/dev/null 2>&1 \
     && docker compose -p $P logs postgres 2>&1 | grep -q 'has wrong ownership'; then
    echo "  (Docker Desktop ownership glitch during postgres init — redeploying from scratch)" >&2
    docker compose -p $P down -v >/dev/null 2>&1
    rm -rf "$T/data/postgres" "$T/app/.env"
    rc=$(deploy "$T/r1" edh-fixture:good)
  fi
  echo "$rc"
}

make_release "$T/r1" "echo migrated"
rc=$(first_deploy)
assert_status "$rc" 0 "first deploy succeeds"
if [[ "$rc" != 0 ]]; then bail "first deploy failed; output:" "$(cat "$T/out")"; fi
assert_eq "$(curl -s localhost:18081/)" "fixture-ok" "site serves the app"
assert_contains "$(cat "$T/app/app.env")" "API_KEY=secret-value" "app secrets mapped from SSM names"
assert_contains "$(cat "$T/app/app.env")" "DATABASE_URL=postgres://app:pw123abc@postgres:5432/app" "DATABASE_URL injected"
assert_eq "$(stat -f %Lp "$T/app/app.env")" "600" "app.env is 0600"
assert_not_contains "$(cat "$T/out")" "pw123abc" "deploy output does not show the postgres password"
assert_not_contains "$(cat "$T/out")" "secret-value" "deploy output does not show app secrets"
assert_eq "$([[ -f "$T/data/maint/down.html" && -f "$T/data/maint/maintenance.html" ]] && echo yes)" "yes" \
  "deploy installs down.html and renders a default maintenance.html"
assert_eq "$(stat -f %Lp "$T/data/backups")" "700" "deploy creates the backups directory 0700"

# a table to find again after backup → restore; in a subshell, because edh-lib.sh sets -Eeuo pipefail
( . "$EDH_BIN_DIR/edh-lib.sh"; pg "create table widgets(id int); insert into widgets values (1)" >/dev/null ) \
  || bail "could not create the test table"

assert_status "$(deploy "$T/r1" edh-fixture:bad)" 2 "unhealthy image exits 2"
assert_eq "$(img)" "edh-fixture:good" "rolled back to good image"
assert_eq "$(curl -s localhost:18081/)" "fixture-ok" "site still serves after rollback"
assert_contains "$(cat "$STUB_LOG")" "sns publish" "rollback alert sent"
assert_contains "$(ls "$STUB_S3/bkt/db/safety")" "app-" "pre-deploy safety dump uploaded"

make_release "$T/r2" "exit 3"
assert_status "$(deploy "$T/r2" edh-fixture:bad)" 1 "failed migration exits 1"
assert_eq "$(img)" "edh-fixture:good" "failed migration keeps old image"

name=$(bash "$EDH_BIN_DIR/edh-backup.sh" --tag manual --force 2>/dev/null)
assert_contains "$(ls "$STUB_S3/bkt/db/daily")" "$name" "manual backup uploaded to db/daily"
assert_contains "$(cat "$STUB_LOG")" "put-metric-data" "backup metric published"
assert_eq "$(bash "$EDH_BIN_DIR/edh-restore.sh" check "db/daily/$name" 2>/dev/null)" "1" "restore check finds 1 table"
assert_eq "$(bash "$EDH_BIN_DIR/edh-drill.sh" >/dev/null 2>&1; echo $?)" "0" "restore drill passes"

bash "$EDH_BIN_DIR/edh-maint.sh" on --message "Testing" >/dev/null
assert_eq "$(curl -s -o /dev/null -w '%{http_code}' localhost:18081/)" "503" "maintenance on via host script"
bash "$EDH_BIN_DIR/edh-maint.sh" off >/dev/null

assert_contains "$(bash "$EDH_BIN_DIR/edh-status.sh" 2>&1)" "maintenance: off" "status reports"

# --- every AWS call went to the stub: it logged each one the scripts make
log=$(cat "$STUB_LOG")
assert_contains "$log" "aws ssm get-parameters-by-path" "SSM secrets read through the stub"
assert_contains "$log" "aws s3 cp" "S3 uploads/downloads went through the stub"
assert_contains "$log" "aws s3 ls" "drill listed backups through the stub"
assert_contains "$log" "aws cloudwatch put-metric-data" "metrics went through the stub"
assert_contains "$log" "aws sns publish" "alerts went through the stub"
finish
