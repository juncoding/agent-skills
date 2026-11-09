# tests/ec2-dedicated-host/test_deploy_no_rollback.sh — edh-deploy.sh --no-rollback and the rollback guard, with a
# fake `docker` and the stub `aws` (fast; no containers, never real AWS). The fake keeps the database schema in a
# file (migrate_cmd ADVANCE changes it, FAIL fails the migration) and which image the app container runs, so
# each path can show which image ends up running, whether maintenance is on and what the guard holds.
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/fake" "$T/s3" "$T/mvbin"
export PATH="$T/fake:$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/aws.log" STUB_S3="$T/s3" STUB_SSM="$T/ssm.tsv"
export EDH_ENV_FILE="$T/etc/edh.env" EDH_APP_DIR="$T/app" EDH_DATA_DIR="$T/data" EDH_BIN_DIR="$T/bin"
export EDH_NO_SYSTEMD=1 EDH_SKIP_PULL=1 EDH_SKIP_PRUNE=1 EDH_HEALTH_TRIES=1 EDH_LOCK_FILE="$T/edh.lock"
export FAKE_SCHEMA="$T/schema.sql" FAKE_RUNNING="$T/running" FAKE_CONTAINER="$T/container"
printf '%s\t%s\n' /t/prod/_edh/postgres-password pw123abc /t/prod/_edh/maint-bypass tok123 > "$STUB_SSM"
printf 'CREATE TABLE widgets (id int);\n' > "$FAKE_SCHEMA"
: > "$FAKE_RUNNING"; : > "$FAKE_CONTAINER"
REAL_DOCKER=$(command -v docker)
cat > "$T/fake/docker" <<EOS
#!/bin/bash
echo "docker \$*" >> "$T/docker.log"
if [[ "\$1" == compose && " \$* " == *" config "* ]]; then exec "$REAL_DOCKER" "\$@"; fi
EOS
cat >> "$T/fake/docker" <<'EOS'
if [[ "$1" == login ]]; then cat >/dev/null; fi
case "$*" in
  *" run --rm --no-deps"*)   # the migration: ADVANCE changes the schema, FAIL fails (after ADVANCE: a partial run)
    if [[ "$*" == *ADVANCE* ]]; then printf 'CREATE TABLE t%s (id int);\n' "$RANDOM$RANDOM" >> "$FAKE_SCHEMA"; fi
    if [[ "$*" == *FAIL* ]]; then echo "fake migrate: P3018 migration failed" >&2; exit 3; fi
    if [[ "$*" == *SIGTERM* ]]; then   # the deploy is cancelled mid-migration: signal edh-deploy.sh (our parent,
      p=$PPID                          # or timeout's parent where coreutils' timeout wraps the migration)
      if [[ "$(ps -o comm= -p "$p" 2>/dev/null)" == *timeout* ]]; then p=$(ps -o ppid= -p "$p" | tr -d ' '); fi
      kill -TERM "$p"; sleep 1
    fi
    exit 0 ;;
  *"pg_database_size"*) echo 100 ;;
  *" pg_dump "*"--schema-only"*)
    if [[ -n "${FAKE_SCHEMA_FAIL:-}" ]]; then exit 1; fi
    # PostgreSQL 17.6+ prints a random \restrict key and comments: neither may count as a schema change
    printf -- '-- Dumped at %s\n\\restrict %s\n' "$RANDOM" "$RANDOM$RANDOM"; cat "$FAKE_SCHEMA"
    printf '\\unrestrict %s\n' "$RANDOM" ;;
  *" pg_dump "*) if [[ -n "${FAKE_DUMP_FAIL:-}" ]]; then exit 1; fi; echo PGDMP-fake ;;
  # one app container: $FAKE_CONTAINER = its image (empty: none), $FAKE_RUNNING = its image while it runs
  *" up -d app"*)   # (re)created from .env and started (FAKE_UP_FAIL: `up` fails, the old one left running)
    if [[ -n "${FAKE_UP_FAIL:-}" ]]; then exit 1; fi
    sed -n 's/^APP_IMAGE=//p' "$EDH_APP_DIR/.env" > "$FAKE_CONTAINER"; cp "$FAKE_CONTAINER" "$FAKE_RUNNING" ;;
  *" up --no-start app"*) sed -n 's/^APP_IMAGE=//p' "$EDH_APP_DIR/.env" > "$FAKE_CONTAINER" ;;
  *" start app"*) cp "$FAKE_CONTAINER" "$FAKE_RUNNING" ;;
  *" stop app"*) : > "$FAKE_RUNNING" ;;
  *" rm -s -f app"*) : > "$FAKE_RUNNING"; : > "$FAKE_CONTAINER" ;;
  *" ps -q app"*) if [[ -s "$FAKE_RUNNING" ]]; then echo cid123; fi ;;
  *" ps -a -q app"*) if [[ -s "$FAKE_CONTAINER" ]]; then echo cid123; fi ;;
  "inspect -f {{.Config.Image}} cid123") cat "$FAKE_CONTAINER" ;;
  *" wget "*)   # healthy unless the running image is FAKE_BAD_IMAGE (or nothing runs)
    if [[ ! -s "$FAKE_RUNNING" ]]; then exit 1; fi
    if [[ -n "${FAKE_BAD_IMAGE:-}" ]] && grep -qx "$FAKE_BAD_IMAGE" "$FAKE_RUNNING"; then exit 1; fi
    exit 0 ;;
esac
exit 0
EOS
chmod +x "$T/fake/docker"
# mv: refuses to install an .env naming FAIL_MV_IMAGE — an unexpected failure between the migrations and the switch
cat > "$T/mvbin/mv" <<'EOS'
#!/bin/bash
for a in "$@"; do
  if [[ "$a" == *.env.new ]] && grep -qx "APP_IMAGE=$FAIL_MV_IMAGE" "$a" 2>/dev/null; then echo "mv shim: refusing $a" >&2; exit 1; fi
done
exec /bin/mv "$@"
EOS
chmod +x "$T/mvbin/mv"
export FAKE_DOCKER_LOG="$T/docker.log"
make_release() { # make_release <dir> <migrate_cmd>
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
EDH_APP_PORT=3000
EDH_APP_MEMORY_MB=256
EDH_USES_GOTENBERG=false
EDH_MIGRATE_CMD='$2'
EDH_ALERT_TOPIC_ARN=arn:aws:sns:ap-southeast-1:123456789012:edh-t-prod-alerts
EDH_ACCOUNT_ID=123456789012
EOV
}
# deploy <release> <image> [flags…] — prints edh-deploy.sh's exit code; output in $T/out
deploy() { local r="$1" i="$2"; shift 2; : > "$STUB_LOG"; : > "$FAKE_DOCKER_LOG"; bash "$r/host/edh-deploy.sh" "$r" "$i" "$@" >"$T/out" 2>&1; echo $?; }
rollback() { bash "$EDH_BIN_DIR/edh-rollback.sh" "$@" >"$T/out" 2>&1; echo $?; }
alert_text() { grep -- 'sns publish' "$STUB_LOG" || true; }
running() { cat "$FAKE_RUNNING"; }
container() { cat "$FAKE_CONTAINER"; }
dotenv_img() { sed -n 's/^APP_IMAGE=//p' "$EDH_APP_DIR/.env"; }
maint() { if [[ -f "$EDH_DATA_DIR/maint/ON" ]]; then echo on; else echo off; fi; }
maint_off() { bash "$EDH_BIN_DIR/edh-maint.sh" off >/dev/null 2>&1; }
guard() { cut -f1 "$EDH_DATA_DIR/incompatible_images" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
schema() { cat "$FAKE_SCHEMA"; }
make_release "$T/plain" "echo migrated"
make_release "$T/adv" "echo ADVANCE"
make_release "$T/fail" "echo FAIL"
make_release "$T/partial" "echo ADVANCE FAIL"
make_release "$T/kill" "echo ADVANCE SIGTERM"
make_release "$T/killnoop" "echo SIGTERM"

# ============ baseline: v1 deployed the ordinary way
assert_status "$(deploy "$T/plain" img:v1)" 0 "baseline deploy of img:v1"
if [[ "$(running)" != img:v1 ]]; then tail -20 "$T/out"; fi
assert_eq "$(running)" "img:v1" "baseline: img:v1 runs"

# ============ --no-rollback, migrations that change nothing: the random \restrict line is not a change, and an
# unhealthy image still rolls back as usual (the old image runs on this schema)
assert_status "$(deploy "$T/plain" img:v2 --no-rollback)" 0 "--no-rollback, schema unchanged, healthy: deployed"
assert_contains "$(cat "$T/out")" "left the database schema unchanged" "--no-rollback: the comparison is logged"
assert_eq "$(guard)" "" "--no-rollback, schema unchanged: nothing goes into the guard"
assert_status "$(FAKE_BAD_IMAGE=img:bad deploy "$T/plain" img:bad --no-rollback)" 2 \
  "--no-rollback, schema unchanged, unhealthy: rolled back as usual (exit 2)"
assert_eq "$(running)" "img:v2" "--no-rollback, schema unchanged, unhealthy: img:v2 serves again"
assert_eq "$(maint)" "off" "--no-rollback, schema unchanged, rolled back: maintenance off"

# ============ default behaviour is unchanged: without --no-rollback a schema-changing release that fails its
# health check still rolls back (no schema comparison, no guard)
s_before=$(schema)
assert_status "$(FAKE_BAD_IMAGE=img:bad deploy "$T/adv" img:bad)" 2 "default, schema changed, unhealthy: rolled back (exit 2)"
assert_eq "$(running)" "img:v2" "default: the previous image serves again"
assert_eq "$(guard)" "" "default: nothing goes into the guard"
assert_eq "$(grep -c -- '--schema-only' "$FAKE_DOCKER_LOG")" "0" "default: the schema is not read"
assert_eq "$([[ "$(schema)" != "$s_before" ]] && echo changed)" "changed" "(the fake migration did change the schema)"

# ============ A. --no-rollback, migration fails and the schema is unchanged (exit 5): the previous version keeps
# running untouched, its configuration back, but maintenance goes ON and the recovery explains the failed record
cp "$EDH_APP_DIR/.env" "$T/dotenv.before"
assert_status "$(deploy "$T/fail" img:v3 --no-rollback)" 5 "A: --no-rollback, failed migration, schema unchanged: exit 5"
assert_eq "$(running)" "img:v2" "A: the previous version is still running"
assert_eq "$(grep -c ' stop app' "$FAKE_DOCKER_LOG")" "0" "A: nothing was stopped"
assert_eq "$(cmp -s "$T/dotenv.before" "$EDH_APP_DIR/.env" && echo same)" "same" "A: previous .env restored"
assert_eq "$(maint)" "on" "A: maintenance switched ON (the old version may not survive a restart)"
assert_eq "$(guard)" "" "A: nothing goes into the guard (the schema is unchanged)"
assert_contains "$(alert_text)" "P3009" "A: the alert names the failed-migration record"
assert_contains "$(alert_text)" "migrate resolve --rolled-back" "A: the alert says how to clear it"
assert_contains "$(alert_text)" "docker compose restart app" "A: the alert says to check the app restarts"
maint_off
# without --no-rollback the failed migration ends as before (exit 1, maintenance off) and the alert warns too
assert_status "$(deploy "$T/fail" img:v3)" 1 "A, default: failed migration exits 1 as before"
assert_eq "$(maint)" "off" "A, default: maintenance off as before"
assert_contains "$(alert_text)" "P3009" "A, default: the alert warns about the failed-migration record"

# ============ --no-rollback, schema can't be read before migrating: nothing migrates
assert_status "$(FAKE_SCHEMA_FAIL=1 deploy "$T/adv" img:v3 --no-rollback)" 1 "schema unreadable before: not deployed (exit 1)"
assert_contains "$(cat "$T/out")" "could not read the database schema before the migrations" "schema unreadable before: explained"
assert_eq "$(grep -c ' run --rm --no-deps' "$FAKE_DOCKER_LOG")" "0" "schema unreadable before: no migration ran"
assert_eq "$(running)" "img:v2" "schema unreadable before: img:v2 still serving"

# ============ --no-rollback, schema-changing release, healthy (with --maint): deployed; the image it replaced goes
# into the guard; maintenance ends off
assert_status "$(deploy "$T/adv" img:v3 --maint --no-rollback)" 0 "--no-rollback, schema changed, healthy: deployed"
assert_eq "$(running)" "img:v3" "schema changed, healthy: img:v3 runs"
assert_contains " $(guard) " " img:v2 " "schema changed: img:v2 (replaced) recorded as unable to run on the new schema"
assert_contains " $(guard) " " img:v1 " "schema changed: img:v1 (ran earlier) recorded too"
assert_not_contains " $(guard) " " img:v3 " "schema changed: img:v3 itself is not listed"
assert_contains "$(cat "$EDH_DATA_DIR/incompatible_images")" "img:v3" "the guard line names the image whose migrations changed it"
assert_eq "$(maint)" "off" "schema changed, healthy, --maint: maintenance off at the end"

# ============ B. the guard: edh-rollback.sh refuses the listed image (exit 4), status shows it, a deploy of it is
# refused, and an ordinary later deploy doesn't clear it
assert_status "$(rollback)" 4 "B: edh-rollback.sh to a listed image: refused (exit 4)"
assert_contains "$(cat "$T/out")" "can't run on this database's schema" "B: rollback refusal explained"
assert_contains "$(cat "$T/out")" "img:v3" "B: rollback refusal names the image that changed the schema"
assert_eq "$(running) $(dotenv_img)" "img:v3 img:v3" "B: refused rollback changes nothing"
assert_contains "$(bash "$EDH_BIN_DIR/edh-status.sh" 2>/dev/null)" "rollback guard" "B: status.sh shows the guard"
assert_status "$(deploy "$T/plain" img:v2)" 1 "B: deploying a listed image: refused (exit 1)"
assert_contains "$(cat "$T/out")" "can't run on this database's schema" "B: deploy refusal explained"
assert_contains "$(alert_text)" "deploy refused" "B: deploy refusal alerts"
assert_eq "$(running)" "img:v3" "B: refused deploy: img:v3 still serving"
assert_eq "$(grep -c ' run --rm --no-deps' "$FAKE_DOCKER_LOG")" "0" "B: refused deploy: nothing migrated"
# an automatic rollback never picks a listed image either: redeploying img:v3 (rollback target = previous_image
# img:v2, listed) and failing → held, not rolled back
assert_status "$(FAKE_BAD_IMAGE=img:v3 deploy "$T/plain" img:v3)" 4 "B: redeploy with a listed rollback target, unhealthy: held (exit 4)"
assert_eq "$(running)" "img:v3" "B: held: img:v2 not started"
assert_eq "$(maint)" "on" "B: held: maintenance ON"
assert_not_contains "$(alert_text)" "deploy rolled back" "B: held: no rollback alert"
maint_off
assert_status "$(deploy "$T/plain" img:v4 --maint)" 0 "B: an ordinary later deploy (img:v4)"
assert_contains " $(guard) " " img:v2 " "B: an ordinary deploy doesn't clear the guard"
assert_not_contains " $(guard) " " img:v3 " "B: an ordinary deploy adds nothing either"
assert_status "$(deploy "$T/plain" img:v2 --maint)" 1 "B: img:v2 is still refused after it"

# ============ --no-rollback, schema-changing release that fails its health check: NOT rolled back (exit 4)
assert_status "$(FAKE_BAD_IMAGE=img:v5 deploy "$T/adv" img:v5 --maint --no-rollback)" 4 \
  "--no-rollback, schema changed, unhealthy: held (exit 4)"
assert_eq "$(running)" "img:v5" "unhealthy: the failed version is left as it is (not replaced by img:v4)"
assert_eq "$(dotenv_img)" "img:v5" "unhealthy: .env still names the failed version"
assert_eq "$(maint)" "on" "unhealthy: maintenance stays ON"
assert_contains " $(guard) " " img:v4 " "unhealthy: img:v4 recorded as unable to run on the new schema"
assert_contains " $(guard) " " img:v3 " "unhealthy: img:v3 (edh-rollback.sh's previous image) recorded too"
assert_not_contains "$(alert_text)" "deploy rolled back" "unhealthy: no rollback"
assert_contains "$(alert_text)" "restore.sh db" "unhealthy: the alert says a restore is the way back"
assert_contains "$(alert_text)" "explicit authorization" "unhealthy: the alert says a restore needs authorization"
assert_contains "$(tail -1 "$EDH_DATA_DIR/deploys.log")" "held" "unhealthy: deploys.log records the held deploy"
assert_status "$(rollback)" 4 "unhealthy: a manual rollback (to img:v3, the recorded previous image) is refused too"
# fix forward: a corrected release deploys and switches maintenance off
assert_status "$(deploy "$T/plain" img:v6 --maint --no-rollback)" 0 "fix forward with img:v6: deployed"
assert_eq "$(running) $(maint)" "img:v6 off" "fix forward: img:v6 runs, maintenance off"

# ============ the new image can't even start (`up` fails, the old container left running): stopped, not serving
assert_status "$(FAKE_UP_FAIL=1 deploy "$T/adv" img:v7 --maint --no-rollback)" 4 \
  "--no-rollback, schema changed, \`up\` fails: held (exit 4)"
assert_eq "$(running)" "" "\`up\` fails: the old container (img:v6) is not left running on the new schema"
assert_eq "$(container)" "img:v7" "\`up\` fails: img:v6's container is gone; a start would start img:v7"
assert_eq "$(dotenv_img)" "img:v7" "\`up\` fails: .env names img:v7"
assert_eq "$(ls "$EDH_DATA_DIR"/held-app-*.log 2>/dev/null | grep -c .)" "1" "\`up\` fails: the removed container's logs are saved"
assert_eq "$(maint)" "on" "\`up\` fails: maintenance ON"
assert_contains "$(guard)" "img:v6" "\`up\` fails: img:v6 in the guard"
# fix forward WITHOUT --maint: the healthy deploy switches the held maintenance off itself
assert_status "$(deploy "$T/plain" img:v8 --no-rollback)" 0 "after \`up\` failed: fix forward with img:v8 (no --maint)"
assert_eq "$(running) $(maint)" "img:v8 off" "fix forward without --maint: img:v8 runs, maintenance switched off"

# ============ interrupted between the migrations and the switch (an unexpected error): exit 4, the previous
# version (still running on the changed schema) stopped, nothing restored
assert_status "$(PATH="$T/mvbin:$PATH" FAIL_MV_IMAGE=img:v9 deploy "$T/adv" img:v9 --maint --no-rollback)" 4 \
  "interrupted after the migrations: held (exit 4)"
assert_eq "$(running)" "" "interrupted: the previous version (img:v8) was stopped"
# (the mv shim also stops .env from naming img:v9 here, so no new container is created from the old .env)
assert_eq "$(container)" "" "interrupted: no img:v8 container left to start (removed, its logs saved)"
assert_contains "$(cat "$T/out")" "could not point .env at img:v9" "interrupted: the .env problem is reported"
assert_eq "$(maint)" "on" "interrupted: maintenance ON"
assert_contains "$(guard)" "img:v8" "interrupted: img:v8 in the guard"
assert_contains "$(alert_text)" "stopped unexpectedly" "interrupted: the alert says the deploy stopped unexpectedly"
assert_not_contains "$(alert_text)" "was restored and is healthy" "interrupted: no previous version restored"
maint_off
assert_status "$(deploy "$T/plain" img:v10 --maint --no-rollback)" 0 "after the interruption: fix forward with img:v10"

# ============ a migration that fails after changing part of the schema: exit 4, the version still running stopped
assert_status "$(deploy "$T/partial" img:v11 --maint --no-rollback)" 4 "partial migration: held (exit 4)"
assert_eq "$(running)" "" "partial migration: the previous version (img:v10) was stopped"
assert_eq "$(container) $(dotenv_img)" "img:v11 img:v11" "partial migration: no img:v10 container, .env names img:v11 (resize/upgrade/restore can't start img:v10)"
assert_contains "$(alert_text)" "P3009" "partial migration: the alert names the failed-migration record"
assert_eq "$(maint)" "on" "partial migration: maintenance ON"
assert_contains "$(guard)" "img:v10" "partial migration: img:v10 in the guard"
assert_contains "$(alert_text)" "schema changed" "partial migration: the alert says the schema changed"
# a retry whose migration fails again without changing anything, while nothing runs: exit 5, not "site down"
assert_status "$(deploy "$T/fail" img:v11b --no-rollback)" 5 "after the hold, a failing retry: exit 5 (maintenance on)"
assert_contains "$(alert_text)" "No version is serving" "failing retry: says nothing is serving"
assert_not_contains "$(alert_text)" "SITE DOWN" "failing retry: no false SITE DOWN"
assert_eq "$(maint)" "on" "failing retry: maintenance still on"
assert_status "$(deploy "$T/plain" img:v12 --no-rollback)" 0 "after the partial migration: fix forward with img:v12"
assert_eq "$(maint)" "off" "fix forward: maintenance off"

# ============ cancelled (SIGTERM) in the middle of a migration that changed the schema: judged by the schema
assert_status "$(deploy "$T/kill" img:k1 --maint --no-rollback)" 4 "SIGTERM during a schema-changing migration: held (exit 4)"
assert_eq "$(running)" "" "SIGTERM, schema changed: img:v12 not left running"
assert_contains " $(guard) " " img:v12 " "SIGTERM, schema changed: img:v12 in the guard"
assert_eq "$(maint)" "on" "SIGTERM, schema changed: maintenance on"
assert_status "$(deploy "$T/plain" img:k2 --no-rollback)" 0 "(fix forward with img:k2)"
# … and one that changed nothing: the previous version keeps running, maintenance stays on (like exit 5)
assert_status "$(deploy "$T/killnoop" img:k3 --maint --no-rollback)" 1 "SIGTERM during a migration that changed nothing: aborted (exit 1)"
assert_eq "$(running)" "img:k2" "SIGTERM, schema unchanged: img:k2 still running"
assert_eq "$(maint)" "on" "SIGTERM, schema unchanged: maintenance stays on (restart-safety unknown)"
assert_not_contains " $(guard) " " img:k2 " "SIGTERM, schema unchanged: nothing added to the guard"
maint_off
# without --no-rollback a SIGTERM now also reaches the abort path (it used to look like success to the EXIT trap)
assert_status "$(deploy "$T/killnoop" img:k4)" 1 "default, SIGTERM during the migration: aborted (exit 1), not 'success'"
assert_eq "$(running) $(maint)" "img:k2 off" "default, SIGTERM: img:k2 still serving, maintenance off as before"
assert_status "$(deploy "$T/plain" img:v12b --maint --no-rollback)" 0 "(img:v12b deployed)"

# ============ schema unreadable after the migrations: treated as changed
assert_status "$(deploy "$T/plain" img:v13 --maint --no-rollback)" 0 "(img:v13 deployed)"
# fail only the second schema read of the next deploy (the one after its migrations)
cp "$T/fake/docker" "$T/fake/docker.real"
cat > "$T/fake/docker" <<EOS
#!/bin/bash
if [[ "\$*" == *"--schema-only"* ]]; then
  n=\$(( \$(cat "$T/schema-reads" 2>/dev/null || echo 0) + 1 )); echo \$n > "$T/schema-reads"
  if (( n == 2 )); then echo "docker \$*" >> "$T/docker.log"; exit 1; fi
fi
exec "$T/fake/docker.real" "\$@"
EOS
chmod +x "$T/fake/docker"; rm -f "$T/schema-reads"
assert_status "$(FAKE_BAD_IMAGE=img:v14 deploy "$T/plain" img:v14 --maint --no-rollback)" 4 \
  "schema unreadable after the migrations, unhealthy: held (treated as changed)"
assert_contains "$(cat "$T/out")" "could not be read after the migrations" "schema unreadable after: logged"
assert_contains "$(guard)" "img:v13" "schema unreadable after: img:v13 in the guard"
mv "$T/fake/docker.real" "$T/fake/docker"; maint_off

# ============ maintenance switched on by hand after a hold is the operator's: a healthy deploy leaves it on
assert_status "$(FAKE_BAD_IMAGE=img:h1 deploy "$T/adv" img:h1 --no-rollback)" 4 "(img:h1 held)"
bash "$EDH_BIN_DIR/edh-maint.sh" on --message "Data check" >/dev/null 2>&1
assert_status "$(deploy "$T/plain" img:h2 --no-rollback)" 0 "(img:h2 deployed)"
assert_eq "$(maint)" "on" "maintenance put on by hand after the hold stays on after a healthy deploy"
maint_off

# ============ the deliberate way back: --allow-incompatible switches to a listed image and removes its line
assert_status "$(deploy "$T/plain" img:v15 --maint)" 0 "(img:v15 deployed; previous image img:v14)"
printf 'img:v13\n' > "$EDH_APP_DIR/previous_image"   # as if the database had been restored for img:v13
assert_status "$(rollback)" 4 "rollback to img:v13 without the override: refused"
assert_status "$(rollback --allow-incompatible)" 0 "rollback --allow-incompatible: switched"
assert_eq "$(running)" "img:v13" "rollback --allow-incompatible: img:v13 runs"
assert_not_contains " $(guard) " " img:v13 " "rollback --allow-incompatible: img:v13's line removed"
assert_contains "$(guard)" "img:v2" "rollback --allow-incompatible: the other lines stay"
assert_contains "$(tail -1 "$EDH_DATA_DIR/deploys.log")" "allow-incompatible" "rollback --allow-incompatible: logged"
assert_status "$(rollback --bogus)" 1 "edh-rollback.sh with an unknown option fails"
finish
