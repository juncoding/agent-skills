# tests/ec2-dedicated-host/test_int_host.sh — the host scripts end to end against Docker, with the stub `aws`
# (never real AWS): deploy (secrets, release validation, rollback, unstartable image, failed migration, aborts,
# exit 3), edh-rollback.sh, locking, backups (schedule, freshness, retention, permissions, failures),
# restore check / replace, drill, maintenance, status.
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); P=edhhosttest   # P = EDH_NAME = compose project name
export PATH="$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/aws.log" STUB_S3="$T/s3" STUB_SSM="$T/ssm.tsv"
export EDH_ENV_FILE="$T/etc/edh.env" EDH_APP_DIR="$T/app" EDH_DATA_DIR="$T/data" EDH_BIN_DIR="$T/bin"
export EDH_NO_SYSTEMD=1 EDH_SKIP_PULL=1 EDH_SKIP_PRUNE=1 EDH_HEALTH_TRIES=15 EDH_LOCK_FILE="$T/edh.lock"
export EDH_HTTP_PORT=18081 EDH_HTTPS_PORT=18443
REAL_DOCKER=$(command -v docker)
cleanup() {
  docker compose -p $P down -v >/dev/null 2>&1
  docker image rm edh-fixture:good2 edh-fixture:bad2 edh-fixture:broken >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT
# bail <message> [output] — fail, show the output, stop
bail() { fail "$1"; if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" | tail -30 | sed 's/^/    /'; fi; finish; }

# --- helpers
ALL_LOG="$T/aws-all.log"
step() { cat "$STUB_LOG" >> "$ALL_LOG" 2>/dev/null; : > "$STUB_LOG"; }   # each step sees only its own AWS calls
alerted() { if grep -qF -- "--subject [$P] $1" "$STUB_LOG"; then echo yes; else echo no; fi; }
metric_sent() { if grep -qF -- "--metric-name $1 " "$STUB_LOG"; then echo yes; else echo no; fi; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }   # GNU first: GNU `stat -f` means file-system status
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
deploy() { bash "$1/host/edh-deploy.sh" "$1" "$2" ${3:+"$3"} >"$T/out" 2>&1; echo $?; }
img() { sed -n 's/^APP_IMAGE=//p' "$T/app/.env"; }
site() { curl -s localhost:18081/; }
# in subshells: edh-lib.sh sets -Eeuo pipefail
pgq() { ( . "$EDH_BIN_DIR/edh-lib.sh"; pg "$1" "${2:-app}" ) 2>/dev/null; }
dcx() { ( . "$EDH_BIN_DIR/edh-lib.sh"; dc "$@" ); }
dumps() { ls "$T/data/backups" | grep -c '^app-.*\.dump$'; }
# age_backups <hours> — make every local dump and the last-upload marker <hours> old
age_backups() { /usr/bin/python3 -I -c 'import glob, os, sys, time
t = time.time() - float(sys.argv[1]) * 3600
for f in glob.glob(sys.argv[2] + "/app-*.dump") + glob.glob(sys.argv[2] + "/.last_upload"): os.utime(f, (t, t))' \
  "$1" "$T/data/backups"; }
ssm_default() {
  printf '%s\t%s\n' /t/prod/_edh/postgres-password pw123abc /t/prod/_edh/maint-bypass tok123 \
    /t/prod/api-key secret-value /t/prod/literal-value 'p$HOME$EDH_UNSET_X' > "$STUB_SSM"
}
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
# first_deploy — deploy r1, retrying once from scratch on a Docker Desktop (macOS) glitch: a freshly chowned
# bind-mounted file sometimes still shows the old owner, so the postgres image's first-boot init dies with
# "data directory ... has wrong ownership" and the restarted container skips init, leaving no "app" database
# (the deploy then fails waiting for it). Linux bind mounts don't do this; the retry needs both signs.
first_deploy() {
  local rc; rc=$(deploy "$T/r1" edh-fixture:good)
  if [[ "$rc" != 0 ]] && docker compose -p $P logs postgres 2>&1 | grep -q 'has wrong ownership'; then
    echo "  (Docker Desktop ownership glitch during postgres init — redeploying from scratch)" >&2
    docker compose -p $P down -v >/dev/null 2>&1
    rm -rf "$T/data/postgres" "$T/app/.env" "$T/app/.env.prev"
    rc=$(deploy "$T/r1" edh-fixture:good)
  fi
  echo "$rc"
}

# --- fixtures
docker compose -p $P down -v >/dev/null 2>&1   # leftovers from an interrupted run
out=$(docker build -q -t edh-fixture:good --build-arg HEALTHY=1 "$TESTS_DIR/fixtures/app" 2>&1) || bail "docker build failed" "$out"
out=$(docker build -q -t edh-fixture:bad  --build-arg HEALTHY=0 "$TESTS_DIR/fixtures/app" 2>&1) || bail "docker build failed" "$out"
out=$(printf 'FROM busybox:1.36\nCMD ["/nonexistent-binary"]\n' | docker build -q -t edh-fixture:broken - 2>&1) \
  || bail "docker build failed" "$out"
docker tag edh-fixture:good edh-fixture:good2; docker tag edh-fixture:bad edh-fixture:bad2

# shims (each used only where a test puts its dir first on PATH)
mkdir -p "$T/flockbin" "$T/mvbin" "$T/imgbin"
# flock: macOS has none; logs its calls, exits FAKE_FLOCK_RC
printf '#!/bin/sh\necho "flock $*" >> "%s"\nexit ${FAKE_FLOCK_RC:-0}\n' "$T/flock.log" > "$T/flockbin/flock"
# mv: refuses to install an .env naming FAIL_MV_IMAGE — a failure between the switch and the health check
cat > "$T/mvbin/mv" <<'EOS'
#!/bin/bash
for a in "$@"; do
  if [[ "$a" == *.env.new ]] && grep -qx "APP_IMAGE=$FAIL_MV_IMAGE" "$a" 2>/dev/null; then echo "mv shim: refusing $a" >&2; exit 1; fi
done
exec /bin/mv "$@"
EOS
# docker: `image ls` lists FAKE_IMAGES, `image rm` / `image prune` are only logged (prune exits FAIL_PRUNE),
# so prune_images runs for real without touching any image on this machine
cat > "$T/imgbin/docker" <<EOS
#!/bin/bash
case "\$1 \$2" in
  "image ls") printf '%s\n' \$FAKE_IMAGES ;;
  "image rm") echo "rm \$3" >> "$T/img.log" ;;
  "image prune") echo "prune" >> "$T/img.log"; exit "\${FAIL_PRUNE:-0}" ;;
  *) exec "$REAL_DOCKER" "\$@" ;;
esac
EOS
chmod +x "$T/flockbin/flock" "$T/mvbin/mv" "$T/imgbin/docker"
: > "$STUB_LOG"
ssm_default
make_release "$T/r1" "echo migrated"

# ============ first deploy
step
rc=$(first_deploy)
assert_status "$rc" 0 "first deploy succeeds"
if [[ "$rc" != 0 ]]; then bail "first deploy failed; output:" "$(cat "$T/out")"; fi
out=$(cat "$T/out")
assert_eq "$(site)" "fixture-ok" "site serves the app"
assert_contains "$(cat "$T/app/app.env")" "API_KEY=secret-value" "app secrets mapped from SSM names"
assert_contains "$(cat "$T/app/app.env")" "DATABASE_URL=postgres://app:pw123abc@postgres:5432/app" "DATABASE_URL injected"
assert_contains "$(cat "$T/app/app.env")" 'LITERAL_VALUE=p$HOME$EDH_UNSET_X' "a \$-value is written to app.env literally"
assert_eq "$(dcx exec -T app printenv LITERAL_VALUE 2>&1)" 'p$HOME$EDH_UNSET_X' "a \$-value reaches the container literally"
assert_not_contains "$out" "variable is not set" "no compose interpolation warning for secret values"
assert_eq "$(mode "$T/app/app.env") $(mode "$T/app/postgres.env") $(mode "$T/app/.env")" "600 600 600" "env files are 0600"
assert_not_contains "$out" "pw123abc" "deploy output does not show the postgres password"
assert_not_contains "$out" "secret-value" "deploy output does not show app secrets"
assert_not_contains "$out" "tok123" "deploy output does not show the bypass token"
assert_eq "$([[ -f "$T/data/maint/down.html" && -f "$T/data/maint/maintenance.html" ]] && echo yes)" "yes" \
  "deploy installs down.html and renders a default maintenance.html"
assert_eq "$(mode "$T/data/backups")" "700" "deploy creates the backups directory 0700"
assert_contains "$(cat "$STUB_LOG")" "--key db/safety/" "first deploy takes a safety dump too (the app database exists)"
if ! command -v flock >/dev/null; then assert_contains "$out" "flock not installed" "no flock: deploy says it runs unlocked"; fi

# a table to find again after backup → restore
( . "$EDH_BIN_DIR/edh-lib.sh"; pg "create table widgets(id int); insert into widgets values (1)" >/dev/null ) \
  || bail "could not create the test table"
app_env_before=$(cat "$T/app/app.env")

# ============ secrets are validated (deploy fails before touching anything; values never shown)
reject() { # reject <description> <expected text> <hidden text> — deploy with $STUB_SSM as set up by the caller
  step
  local rc out; rc=$(deploy "$T/r1" edh-fixture:good); out=$(cat "$T/out")
  assert_status "$rc" 1 "$1: deploy exits 1"
  assert_contains "$out" "$2" "$1: explained"
  assert_not_contains "$out" "$3" "$1: value not shown"
  assert_eq "$(alerted "deploy aborted")" "yes" "$1: alert sent"
  assert_eq "$(cat "$T/app/app.env")" "$app_env_before" "$1: app.env unchanged"
}
printf '%s\t%s\n' /t/prod/_edh/postgres-password pw123abc /t/prod/_edh/maint-bypass tok123 \
  /t/prod/multi-line 'first\nSECRETPART' > "$STUB_SSM"
reject "newline in a value" "/t/prod/multi-line" "SECRETPART"
printf '%s\t%s\n' /t/prod/_edh/postgres-password pw123abc /t/prod/_edh/maint-bypass tok123 \
  /t/prod/tabbed 'a\tSECRETPART' > "$STUB_SSM"
reject "tab in a value" "/t/prod/tabbed" "SECRETPART"
printf '%s\t%s\n' /t/prod/_edh/postgres-password pw123abc /t/prod/api-key secret-value > "$STUB_SSM"
reject "missing maint-bypass" "_edh/maint-bypass" "pw123abc"
printf '%s\t%s\n' /t/prod/_edh/postgres-password '' /t/prod/_edh/maint-bypass tok123 > "$STUB_SSM"
reject "empty postgres-password" "_edh/postgres-password" "tok123"
printf '%s\t%s\n' /t/prod/_edh/postgres-password pw123abc /t/prod/_edh/maint-bypass 'tok-SECRETPART!' > "$STUB_SSM"
reject "non-alphanumeric maint-bypass" "letters and digits" "SECRETPART"
ssm_default
assert_eq "$(img) $(site)" "edh-fixture:good fixture-ok" "rejected secrets: old version still serving"

# ============ an invalid Caddyfile is caught before anything is installed
make_release "$T/r3" "echo migrated"
sed 's/^\tencode zstd gzip/\tencode_bogus zstd gzip/' "$SKILL_DIR/assets/project/Caddyfile" > "$T/r3/app/Caddyfile"
cp "$T/app/caddy/Caddyfile" "$T/Caddyfile.before"
step
assert_status "$(deploy "$T/r3" edh-fixture:good)" 1 "invalid Caddyfile: deploy exits 1"
assert_contains "$(cat "$T/out")" "Caddyfile" "invalid Caddyfile: explained"
assert_eq "$(cmp -s "$T/Caddyfile.before" "$T/app/caddy/Caddyfile" && echo same)" "same" "invalid Caddyfile: old Caddyfile still installed"
assert_eq "$(site)" "fixture-ok" "invalid Caddyfile: site still serves"

# ============ unhealthy image → rolled back, with the previous secrets
sed 's/secret-value/secret-v2/' "$STUB_SSM" > "$T/ssm.v2" && cp "$T/ssm.v2" "$STUB_SSM"
step
assert_status "$(deploy "$T/r1" edh-fixture:bad)" 2 "unhealthy image exits 2"
assert_eq "$(img)" "edh-fixture:good" "rolled back to good image"
assert_eq "$(site)" "fixture-ok" "site still serves after rollback"
assert_eq "$(alerted "deploy rolled back")" "yes" "rollback alert sent"
assert_contains "$(cat "$STUB_LOG")" "--key db/safety/" "pre-deploy safety dump uploaded"
assert_contains "$(cat "$T/app/app.env")" "API_KEY=secret-value" "rollback restores the previous app.env"
assert_eq "$(dcx exec -T app printenv API_KEY 2>&1)" "secret-value" "rolled-back app runs with the previous secrets"
ssm_default

# ============ unstartable image (compose up fails) → rolled back, not left down
step
assert_status "$(deploy "$T/r1" edh-fixture:broken)" 2 "unstartable image exits 2"
assert_eq "$(img)" "edh-fixture:good" "unstartable image: .env back to the good image"
assert_eq "$(site)" "fixture-ok" "unstartable image: old image serving"
assert_eq "$(alerted "deploy rolled back")" "yes" "unstartable image: alert sent"

# ============ failed migration
make_release "$T/r2" "exit 3"
step
assert_status "$(deploy "$T/r2" edh-fixture:bad)" 1 "failed migration exits 1"
assert_eq "$(img)" "edh-fixture:good" "failed migration keeps old image"
assert_eq "$(alerted "deploy failed")" "yes" "failed migration: alert sent"

# ============ abort after the infra step (postgres won't start with the release's compose.yml)
make_release "$T/r4" "echo migrated"
awk '{ print } /image: postgres:18-alpine/ { print "    command: [postgres, -c, bogus_setting_xyz=1]" }' \
  "$SKILL_DIR/assets/project/compose.yml" > "$T/r4/app/compose.yml"
step
assert_status "$(deploy "$T/r4" edh-fixture:good)" 1 "infra abort (broken postgres config): exits 1"
assert_eq "$(site)" "fixture-ok" "infra abort: site still serving"
for _ in $(seq 1 30); do [[ "$(pgq 'select 1')" == 1 ]] && break; sleep 1; done   # postgres was just recreated
assert_eq "$(pgq 'select count(*) from widgets')" "1" "infra abort: old postgres container restored"
assert_eq "$(grep -c bogus_setting "$T/app/compose.yml")" "0" "infra abort: previous compose.yml restored"
assert_eq "$(alerted "deploy aborted at line")" "yes" "infra abort: alert sent"
assert_contains "$(cat "$STUB_LOG")" "previous version is still running" "infra abort: alert says the old version is serving"

# ============ unexpected failure between the switch and the health check → previous version back, exit 2
step
assert_status "$(PATH="$T/mvbin:$PATH" FAIL_MV_IMAGE=edh-fixture:good2 deploy "$T/r1" edh-fixture:good2)" 2 \
  "failure after the switch, previous version healthy: exits 2"
assert_eq "$(alerted "deploy aborted at line")" "yes" "failure after the switch: alert names the line"
assert_eq "$(img)" "edh-fixture:good" "failure after the switch: .env restored to the previous image"
assert_eq "$(site)" "fixture-ok" "failure after the switch: previous image serving"

# ============ bookkeeping failures after a healthy deploy don't roll it back
sed 's/secret-value/secret-v3/' "$STUB_SSM" > "$T/ssm.v3" && cp "$T/ssm.v3" "$STUB_SSM"
mv "$T/data/deploys.log" "$T/deploys.keep"; mkdir "$T/data/deploys.log"   # appending to it now fails
step
assert_status "$(deploy "$T/r1" edh-fixture:good2)" 0 "deploys.log unwritable after a healthy deploy: still exits 0"
assert_eq "$(img)" "edh-fixture:good2" "deploys.log unwritable: the new image is kept"
assert_contains "$(cat "$T/out")" "could not append to deploys.log" "deploys.log unwritable: logged"
rmdir "$T/data/deploys.log"; mv "$T/deploys.keep" "$T/data/deploys.log"
ssm_default

# ============ edh-rollback.sh (good2 runs with API_KEY=secret-v3; good ran with secret-value)
assert_eq "$(cat "$T/app/previous_image")" "edh-fixture:good" "previous image recorded"
assert_contains "$(cat "$T/app/app.env.rollback" 2>&1)" "API_KEY=secret-value" "deploy keeps the previous app.env for edh-rollback.sh"
out=$(PATH="$T/flockbin:$PATH" FAKE_FLOCK_RC=1 bash "$EDH_BIN_DIR/edh-rollback.sh" 2>&1); rc=$?
assert_status "$rc" 1 "edh-rollback.sh with the lock held elsewhere fails"
assert_contains "$out" "another edh operation is running" "edh-rollback.sh takes the edh lock"
assert_eq "$(img)" "edh-fixture:good2" "locked-out edh-rollback.sh changes nothing"
assert_status "$(bash "$EDH_BIN_DIR/edh-rollback.sh" >"$T/out" 2>&1; echo $?)" 0 "edh-rollback.sh succeeds"
assert_eq "$(img)" "edh-fixture:good" "edh-rollback.sh switches .env to the previous image"
assert_eq "$(cat "$T/app/previous_image")" "edh-fixture:good2" "edh-rollback.sh records the image it replaced"
assert_contains "$(tail -1 "$T/data/deploys.log")" "rollback" "edh-rollback.sh logs the rollback"
assert_eq "$(site)" "fixture-ok" "site serves after edh-rollback.sh"
assert_contains "$(cat "$T/app/app.env")" "API_KEY=secret-value" "edh-rollback.sh restores the previous app.env"
assert_eq "$(dcx exec -T app printenv API_KEY 2>&1)" "secret-value" "rolled-back app runs with its previous secrets"
cp "$T/app/previous_image" "$T/previous_image.keep"; img > "$T/app/previous_image"
out=$(bash "$EDH_BIN_DIR/edh-rollback.sh" 2>&1); rc=$?
assert_status "$rc" 1 "edh-rollback.sh when the previous image is already running fails"
assert_contains "$out" "nothing to roll back to" "edh-rollback.sh when the previous image is already running explains"
mv "$T/previous_image.keep" "$T/app/previous_image"
mv "$T/app/previous_image" "$T/previous_image.keep"
out=$(bash "$EDH_BIN_DIR/edh-rollback.sh" 2>&1); rc=$?
assert_status "$rc" 1 "edh-rollback.sh without a previous image fails"
assert_contains "$out" "no previous image recorded" "edh-rollback.sh without a previous image explains"
mv "$T/previous_image.keep" "$T/app/previous_image"
# previous image unhealthy → stays on the current image, with its app.env
cp "$T/app/previous_image" "$T/previous_image.keep"; echo edh-fixture:bad > "$T/app/previous_image"
cp -p "$T/app/app.env" "$T/app.env.keep"; cp -p "$T/app/app.env.rollback" "$T/app.env.rollback.keep"
nlog=$(wc -l < "$T/data/deploys.log")
step
out=$(bash "$EDH_BIN_DIR/edh-rollback.sh" 2>&1); rc=$?
assert_status "$rc" 1 "edh-rollback.sh to an unhealthy previous image fails"
assert_eq "$(img)" "edh-fixture:good" "unhealthy previous image: .env keeps the current image"
assert_eq "$(site)" "fixture-ok" "unhealthy previous image: site still serves the current image"
assert_eq "$(dcx exec -T app printenv API_KEY 2>&1)" "secret-value" "unhealthy previous image: app runs with the current secrets"
assert_eq "$(cmp -s "$T/app/app.env" "$T/app.env.keep" && cmp -s "$T/app/app.env.rollback" "$T/app.env.rollback.keep" \
  && echo same)" "same" "unhealthy previous image: app.env and app.env.rollback restored"
assert_eq "$(cat "$T/app/previous_image")" "edh-fixture:bad" "unhealthy previous image: previous_image unchanged"
assert_eq "$(alerted "rollback failed")" "yes" "unhealthy previous image: alert sent"
assert_contains "$(cat "$STUB_LOG")" "rollback failed — stayed on edh-fixture:good" "unhealthy previous image: alert names the image kept"
assert_eq "$(wc -l < "$T/data/deploys.log")" "$nlog" "unhealthy previous image: nothing added to deploys.log"
mv "$T/previous_image.keep" "$T/app/previous_image"; rm -f "$T/app.env.keep" "$T/app.env.rollback.keep"

# same image redeployed and now failing → falls back to previous_image
assert_status "$(deploy "$T/r1" edh-fixture:good2)" 0 "deploy good2 again"
docker tag edh-fixture:bad edh-fixture:good2   # the same tag now points at a broken build
step
assert_status "$(deploy "$T/r1" edh-fixture:good2)" 2 "same image redeployed and unhealthy exits 2"
assert_eq "$(img)" "edh-fixture:good" "same image: rolled back to previous_image"
docker tag edh-fixture:good edh-fixture:good2

# ============ both images unhealthy → exit 3
sed -i.bak 's/^APP_IMAGE=.*/APP_IMAGE=edh-fixture:bad/' "$T/app/.env"; rm -f "$T/app/.env.bak"   # a broken current version
step
assert_status "$(deploy "$T/r1" edh-fixture:bad2)" 3 "both images unhealthy exits 3"
assert_eq "$(alerted "SITE DOWN after deploy")" "yes" "both unhealthy: SITE DOWN alert"
assert_status "$(deploy "$T/r1" edh-fixture:good)" 0 "recovery deploy succeeds"
assert_eq "$(site)" "fixture-ok" "site serves after recovery"

# ============ --maint deploy ends with maintenance off
assert_status "$(deploy "$T/r1" edh-fixture:good --maint)" 0 "--maint deploy succeeds"
assert_eq "$(bash "$EDH_BIN_DIR/edh-maint.sh" status)" "off" "--maint deploy ends with maintenance off"

# ============ image pruning (docker shim: nothing on this machine is removed)
: > "$T/img.log"
assert_status "$(PATH="$T/imgbin:$PATH" EDH_SKIP_PRUNE='' \
  FAKE_IMAGES="edh-fixture:a edh-fixture:b edh-fixture:c edh-fixture:good edh-fixture:d edh-fixture:good2" \
  deploy "$T/r1" edh-fixture:good2)" 0 "deploy with pruning"
assert_eq "$(cat "$T/img.log" | tr '\n' ' ')" "rm edh-fixture:d prune " "prune keeps the 3 newest plus the current and previous images"
: > "$T/img.log"
assert_status "$(PATH="$T/imgbin:$PATH" EDH_SKIP_PRUNE='' FAIL_PRUNE=1 FAKE_IMAGES="edh-fixture:good" \
  deploy "$T/r1" edh-fixture:good)" 0 "failing image prune after a healthy deploy: still exits 0"
assert_eq "$(img)" "edh-fixture:good" "failing image prune: the new image is kept"
assert_contains "$(cat "$T/out")" "image cleanup failed" "failing image prune: logged"

# ============ locking (fake flock: macOS has none)
make_release "$T/r5" "echo migrated"; sed -i.bak 's/^EDH_APP_MEMORY_MB=.*/EDH_APP_MEMORY_MB=300/' "$T/r5/release.env"
echo "# r5 marker" >> "$T/r5/host/edh-maint.sh"
step
assert_status "$(PATH="$T/flockbin:$PATH" FAKE_FLOCK_RC=1 deploy "$T/r5" edh-fixture:good)" 1 "deploy with the lock held elsewhere exits 1"
assert_eq "$(grep -c '^EDH_APP_MEMORY_MB=256$' "$EDH_ENV_FILE")" "1" "locked-out deploy does not install release.env"
assert_eq "$(grep -c 'r5 marker' "$EDH_BIN_DIR/edh-maint.sh")" "0" "locked-out deploy does not install host scripts"
step
out=$(PATH="$T/flockbin:$PATH" FAKE_FLOCK_RC=1 bash "$EDH_BIN_DIR/edh-backup.sh" --tag manual 2>&1); rc=$?
assert_status "$rc" 1 "lock held elsewhere: backup exits 1"
assert_contains "$out" "another edh operation is running" "lock held elsewhere: explained"
assert_eq "$(alerted "backup failed")" "yes" "lock held elsewhere: alert sent"
: > "$T/flock.log"
assert_status "$(PATH="$T/flockbin:$PATH" deploy "$T/r1" edh-fixture:good)" 0 "deploy with flock available"
assert_eq "$(wc -l < "$T/flock.log" | tr -d ' ')" "1" "deploy locks once; its nested edh-backup.sh does not lock again"
assert_contains "$(cat "$T/flock.log")" "-w 600 9" "lock waits up to 600 s"

# ============ backups: permissions, retention, no metric for manual
for i in $(seq 10 39); do touch -t "2020010100$i" "$T/data/backups/app-20200101T00${i}00Z.dump"; done
chmod 755 "$T/data/backups"   # an existing, too-open directory gets tightened
step
name=$(bash "$EDH_BIN_DIR/edh-backup.sh" --tag manual --force 2>/dev/null)
assert_contains "$(ls "$STUB_S3/bkt/db/daily")" "$name" "manual backup uploaded to db/daily"
assert_eq "$(mode "$T/data/backups/$name" 2>&1)" "600" "backup dump is 0600"
assert_eq "$(mode "$T/data/backups")" "700" "backups directory is 0700"
assert_eq "$(dumps)" "24" "keeps the newest 24 local dumps"
assert_eq "$([[ -f "$T/data/backups/$name" ]] && echo kept)" "kept" "the new dump is kept"
assert_eq "$([[ -f "$T/data/backups/app-20200101T001000Z.dump" ]] && echo kept || echo gone)" "gone" "the oldest dump is removed"
assert_eq "$(metric_sent BackupFresh)" "no" "manual backup publishes no metric"

# a failed dump leaves no .part, sends an alert, adds no dump
mkdir -p "$T/dumpfail"
printf '#!/bin/bash\ncase " $* " in *" pg_dump "*) echo partial-dump; exit ${FAKE_DUMP_RC:-0} ;; esac\nexec "%s" "$@"\n' \
  "$REAL_DOCKER" > "$T/dumpfail/docker"
chmod +x "$T/dumpfail/docker"
n=$(dumps)
for c in 0 1; do
  step
  out=$(PATH="$T/dumpfail:$PATH" FAKE_DUMP_RC=$c bash "$EDH_BIN_DIR/edh-backup.sh" --tag manual 2>&1); rc=$?
  assert_eq "$(( rc != 0 ))" "1" "bad dump (pg_dump exit $c): backup fails"
  assert_eq "$(ls "$T/data/backups" | grep -c '\.part$')" "0" "bad dump (pg_dump exit $c): no .part left"
  assert_eq "$(alerted "backup failed")" "yes" "bad dump (pg_dump exit $c): alert sent"
  assert_eq "$(dumps)" "$n" "bad dump (pg_dump exit $c): no dump added"
  assert_not_contains "$(cat "$STUB_LOG")" "put-object" "bad dump (pg_dump exit $c): nothing uploaded"
done
step
out=$(PATH="$T/dumpfail:$PATH" FAKE_DUMP_RC=0 bash "$EDH_BIN_DIR/edh-backup.sh" --tag manual 2>&1)
assert_contains "$out" "not a readable" "unreadable dump: explained"

# bad arguments / settings are rejected before dumping
n=$(dumps); step
out=$(bash "$EDH_BIN_DIR/edh-backup.sh" --tag weekly 2>&1); rc=$?
assert_status "$rc" 1 "unknown --tag rejected"
assert_contains "$out" "unknown tag" "unknown --tag explained"
sed 's/^EDH_BACKUP_SCHEDULE=.*/EDH_BACKUP_SCHEDULE=weekly/' "$EDH_ENV_FILE" > "$T/etc/weekly.env"
out=$(EDH_ENV_FILE="$T/etc/weekly.env" bash "$EDH_BIN_DIR/edh-backup.sh" 2>&1); rc=$?
assert_status "$rc" 1 "unknown backup schedule rejected"
assert_contains "$out" "auto, hourly or daily" "unknown backup schedule explained"
assert_eq "$(dumps)" "$n" "rejected arguments: nothing dumped"

# ============ schedule: which S3 prefixes, and the BackupFresh heartbeat (simulated UTC hour/day)
mkdir -p "$T/datebin"
printf '#!/bin/bash\ncase "$*" in\n  "-u +%%H") echo "$FAKE_HOUR" ;;\n  "-u +%%d") echo "$FAKE_DAY" ;;\n  *) exec /bin/date "$@" ;;\nesac\n' \
  > "$T/datebin/date"
chmod +x "$T/datebin/date"
sed 's/^EDH_BACKUP_SCHEDULE=.*/EDH_BACKUP_SCHEDULE=daily/' "$EDH_ENV_FILE" > "$T/etc/daily.env"
sed -e 's/^EDH_BACKUP_SCHEDULE=.*/EDH_BACKUP_SCHEDULE=daily/' -e 's/^EDH_DAILY_HOUR_UTC=.*/EDH_DAILY_HOUR_UTC=08/' \
  "$EDH_ENV_FILE" > "$T/etc/daily08.env"
sched() { # sched <hour> <day> [env-file] — auto backup at a simulated UTC time; prints the S3 prefixes it uploaded to
  step
  PATH="$T/datebin:$PATH" FAKE_HOUR="$1" FAKE_DAY="$2" EDH_ENV_FILE="${3:-$EDH_ENV_FILE}" \
    bash "$EDH_BIN_DIR/edh-backup.sh" >/dev/null 2>"$T/out"
  sed -n 's#.* put-object --bucket bkt --key db/\([a-z]*\)/.*#\1#p' "$STUB_LOG" | tr '\n' ' '
}
assert_eq "$(sched 09 15)" "hourly " "hourly schedule, ordinary hour: db/hourly only"
assert_eq "$(metric_sent BackupFresh)" "yes" "hourly schedule: BackupFresh published"
assert_eq "$(sched 18 15)" "hourly daily " "hourly schedule, daily slot: db/hourly + db/daily"
assert_eq "$(sched 18 01)" "hourly daily monthly " "hourly schedule, daily slot on the 1st: + db/monthly"
assert_eq "$(sched 09 15 "$T/etc/daily.env")" "" "daily schedule, ordinary hour: nothing uploaded"
assert_contains "$(cat "$T/out")" "nothing to do" "daily schedule, ordinary hour: says so"
assert_eq "$(metric_sent BackupFresh)" "yes" "daily schedule, skipped hour: recent upload still reported fresh"
assert_eq "$(sched 18 15 "$T/etc/daily.env")" "daily " "daily schedule, daily slot: db/daily"
assert_eq "$(sched 08 15 "$T/etc/daily08.env")" "daily " "daily_backup_hour_utc 08 (leading zero) works"
age_backups 30
assert_eq "$(sched 09 15 "$T/etc/daily.env")" "" "daily schedule, stale backups, ordinary hour: nothing uploaded"
assert_eq "$(metric_sent BackupFresh)" "no" "last upload older than 26 h: BackupFresh not published"
# freshness counts successful uploads, not local dumps: a dump whose upload failed doesn't count
STUB_S3_FAIL=1 sched 18 15 "$T/etc/daily.env" >/dev/null
assert_eq "$(alerted "backup failed")" "yes" "failed upload: backup fails with an alert"
assert_eq "$(sched 09 15 "$T/etc/daily.env")" "" "after a failed upload, ordinary hour: nothing uploaded"
assert_eq "$(metric_sent BackupFresh)" "no" "a fresh local dump whose upload failed is not reported fresh"
# ============ write-once backups: uploads are create-only, an existing key is never overwritten
mkdir -p "$T/stampbin"   # date: every dump gets the same name
printf '#!/bin/bash\nif [[ "$*" == "-u +%%Y%%m%%dT%%H%%M%%SZ" ]]; then echo 20260101T000000Z; else exec /bin/date "$@"; fi\n' \
  > "$T/stampbin/date"
chmod +x "$T/stampbin/date"
step
assert_status "$(PATH="$T/stampbin:$PATH" bash "$EDH_BIN_DIR/edh-backup.sh" --tag manual >/dev/null 2>&1; echo $?)" 0 \
  "write-once: first upload succeeds"
assert_contains "$(cat "$STUB_LOG")" "s3api put-object --bucket bkt --key db/daily/app-20260101T000000Z.dump" "backup uploads with put-object"
assert_contains "$(cat "$STUB_LOG")" "--if-none-match *" "backup upload passes --if-none-match"
age_backups 5; before=$(mtime "$T/data/backups/.last_upload")
rm -f "$T/data/backups/app-20260101T000000Z.dump"   # only S3 has it (e.g. a rebuilt server): the name is reused
step
out=$(PATH="$T/stampbin:$PATH" bash "$EDH_BIN_DIR/edh-backup.sh" --tag manual 2>&1); rc=$?
assert_eq "$(( rc != 0 ))" "1" "write-once: second upload to the same key fails"
assert_contains "$out" "PreconditionFailed" "write-once: S3 refused the overwrite"
assert_eq "$(alerted "backup failed")" "yes" "write-once: alert sent"
assert_eq "$(mtime "$T/data/backups/.last_upload")" "$before" "write-once: .last_upload not touched"
rm -f "$STUB_S3/bkt/db/daily/app-20260101T000000Z.dump" "$T/data/backups/app-20260101T000000Z.dump"
step   # back-to-back backups (possibly within one second) get distinct names, so both uploads succeed
b1=$(bash "$EDH_BIN_DIR/edh-backup.sh" --tag manual 2>/dev/null) && b2=$(bash "$EDH_BIN_DIR/edh-backup.sh" --tag manual 2>/dev/null)
assert_status $? 0 "back-to-back backups both succeed"
assert_eq "$([[ -n "$b1" && "$b1" != "$b2" ]] && echo distinct)" "distinct" "back-to-back backups get distinct names"
name=$(bash "$EDH_BIN_DIR/edh-backup.sh" --tag manual --force 2>/dev/null)   # fresh dump of widgets (1 row)

# ============ restore check: side database only
step
assert_eq "$(bash "$EDH_BIN_DIR/edh-restore.sh" check "db/daily/$name" 2>/dev/null)" "1" "restore check finds 1 table"
assert_eq "$(pgq 'select count(*) from widgets')" "1" "restore check leaves the live database untouched"
assert_eq "$(pgq "select count(*) from pg_database where datname = 'app_restore_check'" postgres)" "0" "restore check drops app_restore_check"
mkdir -p "$T/dfbin"
printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/stub 100 99 1 99%% /data"\n' > "$T/dfbin/df"
chmod +x "$T/dfbin/df"
out=$(PATH="$T/dfbin:$PATH" bash "$EDH_BIN_DIR/edh-restore.sh" check "db/daily/$name" 2>&1); rc=$?
assert_status "$rc" 1 "restore check without free space fails"
assert_contains "$out" "not enough free space" "restore check without free space explains"
step
out=$(PATH="$T/dfbin:$PATH" bash "$EDH_BIN_DIR/edh-drill.sh" 2>&1); rc=$?
assert_eq "$(( rc != 0 ))" "1" "drill without free space fails"
assert_contains "$out" "not enough free space" "drill without free space explains"
assert_eq "$(alerted "restore drill FAILED")" "yes" "drill failure alerts"

# ============ drill
step
assert_eq "$(bash "$EDH_BIN_DIR/edh-drill.sh" >/dev/null 2>&1; echo $?)" "0" "restore drill passes"
assert_eq "$(metric_sent RestoreDrillSuccess)" "yes" "restore drill publishes RestoreDrillSuccess"

# ============ restore replace
printf 'not a dump' > "$STUB_S3/bkt/db/daily/app-corrupt.dump"
step
out=$(bash "$EDH_BIN_DIR/edh-restore.sh" replace db/daily/app-corrupt.dump --yes 2>&1); rc=$?
assert_status "$rc" 1 "replace with a corrupt dump fails"
assert_eq "$(pgq 'select count(*) from widgets')" "1" "corrupt dump: live database intact"
assert_eq "$(bash "$EDH_BIN_DIR/edh-maint.sh" status)" "off" "corrupt dump: maintenance off"
assert_eq "$(site)" "fixture-ok" "corrupt dump: app still serving"
assert_eq "$(alerted "restore failed")" "yes" "corrupt dump: alert sent"
rm -f "$STUB_S3/bkt/db/daily/app-corrupt.dump"

pgq 'insert into widgets values (2)' >/dev/null
step
out=$(bash "$EDH_BIN_DIR/edh-restore.sh" replace "db/daily/$name" --yes 2>&1); rc=$?
assert_status "$rc" 0 "replace with a good dump succeeds"
assert_eq "$(pgq 'select count(*) from widgets')" "1" "replace: live data is the dump's (row added later is gone)"
assert_eq "$(pgq 'select count(*) from widgets' app_pre_restore)" "2" "replace: previous data kept in app_pre_restore"
assert_contains "$out" "app_pre_restore" "replace: tells where the previous data is"
assert_contains "$(cat "$STUB_LOG")" "--key db/safety/" "replace: safety dump uploaded first"
assert_eq "$(bash "$EDH_BIN_DIR/edh-maint.sh" status)" "off" "replace: maintenance off afterwards"
assert_eq "$(site)" "fixture-ok" "replace: app serving afterwards"

# ============ maintenance
bash "$EDH_BIN_DIR/edh-maint.sh" on --message "Testing" >/dev/null
assert_eq "$(curl -s -o /dev/null -w '%{http_code}' localhost:18081/)" "503" "maintenance on via host script"
bash "$EDH_BIN_DIR/edh-maint.sh" off >/dev/null

# ============ status: STALE threshold follows the schedule (hourly 2 h, daily 26 h)
age_backups 3   # last upload (and dumps) 3 h ago
out=$(bash "$EDH_BIN_DIR/edh-status.sh" 2>&1)
assert_contains "$out" "maintenance: off" "status reports"
assert_contains "$out" "STALE" "status: 3 h old backup is stale on the hourly schedule"
assert_not_contains "$(EDH_ENV_FILE="$T/etc/daily.env" bash "$EDH_BIN_DIR/edh-status.sh" 2>&1)" "STALE" \
  "status: 3 h old backup is not stale on the daily schedule"

# ============ every AWS call went to the stub
step
log=$(cat "$ALL_LOG")
assert_contains "$log" "aws ssm get-parameters-by-path" "SSM secrets read through the stub"
assert_contains "$log" "aws s3 cp" "S3 uploads/downloads went through the stub"
assert_contains "$log" "aws s3 ls" "drill listed backups through the stub"
assert_contains "$log" "aws cloudwatch put-metric-data" "metrics went through the stub"
assert_contains "$log" "aws s3api put-object" "backup uploads went through the stub"
assert_contains "$log" "--namespace EDH/$P " "metrics go to the per-client namespace EDH/<name>"
assert_not_contains "$log" "--namespace EDH " "no metric in the shared EDH namespace"
assert_contains "$log" "aws sns publish" "alerts went through the stub"
assert_not_contains "$log" "BackupSuccess" "the old BackupSuccess metric is gone"
finish
