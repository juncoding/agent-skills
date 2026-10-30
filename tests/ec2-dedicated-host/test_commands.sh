# tests/ec2-dedicated-host/test_commands.sh — the local day-2 commands against the stub `aws` (never real AWS)
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/s3"
# fake docker / curl / dig: no image is built, no network is used
printf '#!/bin/sh\necho "docker $*" >> "$STUB_LOG.docker"\ncase "$1" in login) cat >/dev/null ;; esac\nexit 0\n' > "$T/bin/docker"
printf '#!/bin/sh\nexit ${FAKE_CURL_RC:-0}\n' > "$T/bin/curl"
printf '#!/bin/sh\necho 203.0.113.10\n' > "$T/bin/dig"
chmod +x "$T/bin/"*
export PATH="$T/bin:$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/log" STUB_S3="$T/s3" STUB_MODE=existing EDH_SSM_POLL_SECONDS=0
BUCKET="edh-acme-prod-backups-123456789012"

mkdir "$T/p"; cd "$T/p" || exit 1
bash "$SKILL_DIR/scripts/init.sh" --client acme --domain erp.acme.com --emails a@x.com --account-id 123456789012 >/dev/null 2>&1
git init -q . && git add -A && git -c user.email=t@example.com -c user.name=t commit -qm init

run() { local s="$1"; shift; bash "$SKILL_DIR/scripts/$s" "$@" 2>&1; }
calls() { grep -c -- "$1" "$T/log" || true; }
line_of() { grep -n -- "$1" "$T/log" | sed -n "${2:-1}p" | cut -d: -f1; }   # line_of <pattern> [nth]
# scripts — every script sent through SSM in this run, decoded, each followed by a "----" line
scripts() {
  grep 'ssm send-command' "$T/log" | sed -n 's/.*echo \([A-Za-z0-9+/=]*\) | base64 -d.*/\1/p' \
    | while read -r b; do printf '%s' "$b" | base64 --decode; printf '\n----\n'; done
}
script_n() { scripts | awk -v n="$1" 'BEGIN { RS = "\n----\n" } NR == n'; }
pos() { local pre="${1%%"$2"*}"; if [[ "$pre" == "$1" ]]; then echo -1; else echo "${#pre}"; fi; }
# in_order <text> <a> <b> ... — each piece occurs, after the one before it
in_order() {
  local text="$1" last=-1 p s; shift
  for s in "$@"; do p=$(pos "$text" "$s"); if (( p <= last )); then echo "out of order or missing: $s"; return; fi; last=$p; done
  echo ok
}

# ============ every mutating command refuses another AWS account before any other AWS call
mkdir "$T/q"; mkdir -p "$T/q/deploy"
sed 's/^account_id: .*/account_id: "111111111111"/' deploy/deploy.yml > "$T/q/deploy/deploy.yml"
cd "$T/q" || exit 1
while IFS= read -r c; do
  : > "$T/log"
  # shellcheck disable=SC2086
  out=$(printf 'value' | STUB_READONLY=1 EDH_YES=1 run $c); rc=$?
  assert_status $rc 1 "wrong account: $c refuses"
  assert_contains "$out" "but deploy.yml says 111111111111" "wrong account: $c explains"
  assert_eq "$(grep -v 'sts get-caller-identity' "$T/log" | grep -c .)" "0" "wrong account: $c makes no AWS call besides sts"
done <<'EOF'
deploy.sh
secrets.sh set db-pass
secrets.sh delete db-pass
maint.sh on
maint.sh off
rollback.sh
backup.sh now
restore.sh db --latest
restore.sh disk --snapshot snap-0123abcd
EOF
cd "$T/p" || exit 1

# ============ deploy
: > "$T/log"; : > "$T/log.docker"
out=$(run deploy.sh); rc=$?
sha=$(git rev-parse --short=12 HEAD)
img="123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/edh/acme:$sha"
assert_status $rc 0 "deploy succeeds"
assert_contains "$out" "live: https://erp.acme.com ($sha)" "deploy reports the live site"
assert_contains "$(cat "$T/log.docker")" "buildx build --platform linux/arm64 -f Dockerfile -t $img --push ." "deploy builds and pushes arm64"
assert_eq "$(calls 'sts get-caller-identity')" "1" "deploy checks the account once"
b="$T/s3/$BUCKET/_edh/bundles/$sha.tgz"
[[ -f "$b" ]] && pass "bundle uploaded to _edh/bundles/" || fail "bundle not uploaded"
assert_contains "$(tar tzf "$b" 2>/dev/null)" "./host/edh-deploy.sh" "uploaded bundle has the host scripts"
assert_contains "$(tar xzOf "$b" ./release.env 2>/dev/null)" "EDH_ACCOUNT_ID=123456789012" "uploaded bundle has the account id"
assert_contains "$(grep 'put-object' "$T/log")" "--expected-bucket-owner 123456789012" "bundle upload checks the bucket owner"
body=$(grep -o -- '--body [^ ]*' "$T/log" | cut -d' ' -f2)
[[ -n "$body" && ! -e "$body" ]] && pass "local bundle removed" || fail "local bundle left behind: $body"
s=$(script_n 1)
assert_contains "$s" "bash \"\$R/host/edh-deploy.sh\" \"\$R\" $img" "remote runs edh-deploy.sh with the image"
assert_contains "$s" "s3://$BUCKET/_edh/bundles/$sha.tgz" "remote fetches the bundle"
assert_contains "$s" "tar xz --no-same-owner" "remote extracts without the Mac's file owners"
assert_not_contains "$s" "with-decryption" "remote deploy command holds no secrets"
: > "$T/log"
out=$(run deploy.sh --maint); rc=$?
assert_contains "$(script_n 1)" "$img --maint" "--maint is passed to edh-deploy.sh"
for c in "1:previous version is still serving" "2:rolled back to the previous version" "3:site may be down" "7:site may be down"; do
  out=$(STUB_SSM_RC=${c%%:*} run deploy.sh); rc=$?
  assert_status $rc 1 "edh-deploy exit ${c%%:*}: deploy fails"
  assert_contains "$out" "${c#*:}" "edh-deploy exit ${c%%:*}: '${c#*:}'"
  assert_not_contains "$out" "live:" "edh-deploy exit ${c%%:*}: not reported live"
done
touch untracked
out=$(run deploy.sh); rc=$?
assert_status $rc 1 "uncommitted changes: deploy refuses"
assert_contains "$out" "uncommitted changes" "uncommitted changes: explained"
rm -f untracked

# ============ secrets
: > "$T/log"
out=$(printf 'p@ss w0rd$x\n' | run secrets.sh set db-pass); rc=$?
assert_status $rc 0 "secrets set succeeds"
f="$T/log.params/_acme_prod_db-pass"
assert_eq "$(cat "$f" 2>/dev/null)" 'p@ss w0rd$x' "secret value stored as given"
assert_eq "$(wc -c < "$f" 2>/dev/null | tr -d ' ')" "11" "secret value has no trailing newline"
assert_not_contains "$(cat "$T/log")" "w0rd" "secret value never on the command line"
assert_contains "$(grep put-parameter "$T/log")" "--type SecureString --value file://" "secret passed by file, as SecureString"
assert_contains "$(grep put-parameter "$T/log")" "--overwrite" "secret set overwrites"
tmpf=$(grep -o 'file://[^ ]*' "$T/log" | sed 's#file://##')
[[ -n "$tmpf" && ! -e "$tmpf" ]] && pass "secret temp file removed" || fail "secret temp file left: $tmpf"
for v in 'a\nb' 'a\tb' 'a\rb'; do
  : > "$T/log"
  out=$(printf "$v" | run secrets.sh set x); rc=$?
  assert_status $rc 1 "secret with $v refused"
  assert_contains "$out" "newline or tab" "secret with $v: explained"
  assert_eq "$(calls put-parameter)" "0" "secret with $v: nothing stored"
done
out=$(printf '' | run secrets.sh set x); rc=$?
assert_contains "$out" "empty value" "empty secret refused"
for n in _edh/postgres-password ../x Upper; do
  : > "$T/log"
  out=$(printf 'v' | run secrets.sh set "$n"); rc=$?
  assert_status $rc 1 "secret name $n refused (set)"
  out=$(EDH_YES=1 run secrets.sh delete "$n"); rc=$?
  assert_status $rc 1 "secret name $n refused (delete)"
  assert_eq "$(grep -cE 'put-parameter|delete-parameter' "$T/log")" "0" "secret name $n: nothing changed"
done
: > "$T/log"
out=$(EDH_YES=1 run secrets.sh delete db-pass); rc=$?
assert_contains "$(cat "$T/log")" "ssm delete-parameter --name /acme/prod/db-pass" "secrets delete removes the parameter"
out=$(run secrets.sh delete db-pass </dev/null); rc=$?
assert_status $rc 1 "secrets delete without consent aborts"

# ============ maintenance
: > "$T/log"
out=$(run maint.sh on --message "Back soon"); rc=$?
assert_status $rc 0 "maint on succeeds"
assert_contains "$(script_n 1)" "/opt/edh/bin/edh-maint.sh on --message Back\\ soon" "maint on runs edh-maint.sh with the message"
assert_contains "$(grep disable-alarm-actions "$T/log")" "--region us-east-1 cloudwatch disable-alarm-actions --alarm-names edh-acme-prod-site-down" "maint on pauses the site-down alarm"
assert_contains "$out" "https://erp.acme.com/?maint_bypass=" "maint on shows the bypass link"
: > "$T/log"
out=$(run maint.sh off); rc=$?
assert_contains "$(grep enable-alarm-actions "$T/log")" "edh-acme-prod-site-down" "maint off resumes the site-down alarm"

# ============ rollback
: > "$T/log"
out=$(EDH_YES=1 run rollback.sh); rc=$?
assert_status $rc 0 "rollback succeeds"
assert_contains "$(script_n 1)" "/opt/edh/bin/edh-rollback.sh" "rollback runs edh-rollback.sh"
out=$(EDH_YES=1 STUB_SSM_RC=1 run rollback.sh); rc=$?
assert_status $rc 1 "edh-rollback exit 1: rollback fails"
assert_contains "$out" "previous version is unhealthy" "edh-rollback exit 1: previous version unhealthy"
assert_contains "$out" "stayed on the current version" "edh-rollback exit 1: stayed on current"
out=$(EDH_YES=1 STUB_SSM_RC=3 run rollback.sh); rc=$?
assert_status $rc 1 "edh-rollback exit 3: rollback fails"
assert_contains "$out" "site may be down" "edh-rollback exit 3: site may be down"
: > "$T/log"
out=$(run rollback.sh </dev/null); rc=$?
assert_eq "$(calls 'ssm send-command')" "0" "rollback without consent sends nothing"

# ============ backup
: > "$T/log"
out=$(run backup.sh now); rc=$?
assert_status $rc 0 "backup now succeeds"
assert_contains "$(script_n 1)" "/opt/edh/bin/edh-backup.sh --tag manual --force" "backup now runs a manual backup"
mkdir -p "$T/s3/$BUCKET/db/hourly" "$T/s3/$BUCKET/db/daily"
touch "$T/s3/$BUCKET/db/hourly/app-20261030T010000Z.dump" "$T/s3/$BUCKET/db/daily/app-20261029T180000Z.dump"
out=$(run backup.sh list); rc=$?
assert_contains "$out" "db/hourly/app-20261030T010000Z.dump" "backup list shows the backups"

# ============ restore db
: > "$T/log"
out=$(EDH_YES=1 run restore.sh db --latest); rc=$?
assert_status $rc 0 "restore --latest succeeds"
assert_contains "$(script_n 1)" "/opt/edh/bin/edh-restore.sh replace db/hourly/app-20261030T010000Z.dump --yes" "restore --latest picks the newest dump"
: > "$T/log"
out=$(run restore.sh db --date 2026-10-29 --check); rc=$?
assert_contains "$(script_n 1)" "/opt/edh/bin/edh-restore.sh check db/daily/app-20261029T180000Z.dump --keep" "restore --date --check: that day's dump, side database"
out=$(run restore.sh db --date 2026-01-01 --check); rc=$?
assert_contains "$out" "no matching backup found" "restore --date without a dump that day: explained"
: > "$T/log"
out=$(EDH_YES=1 run restore.sh db --key 'db/daily/app-20261029T180000Z.dump; reboot'); rc=$?
assert_status $rc 1 "restore --key with shell syntax refused"
assert_eq "$(calls 'ssm send-command')" "0" "restore --key with shell syntax: nothing sent"
out=$(EDH_YES=1 STUB_SSM_RC=1 run restore.sh db --latest); rc=$?
assert_status $rc 1 "edh-restore failure: restore fails"
assert_contains "$out" "failed" "edh-restore failure: explained"

# ============ restore disk: stop app, timers, docker (RequiresMountsFor=/data) → umount → swap → mount → start
: > "$T/log"
out=$(EDH_YES=1 STUB_VOL_ATTACHED=i-stub run restore.sh disk --snapshot snap-0123abcd); rc=$?
assert_status $rc 0 "restore disk succeeds"
assert_eq "$(in_order "$(script_n 1)" "docker compose down" "systemctl stop edh-backup.timer edh-drill.timer" \
  "systemctl stop docker.socket docker" "umount /data")" ok "restore disk: compose down, timers, docker stopped, then umount"
assert_eq "$(in_order "$(script_n 2)" "mount -a && mountpoint -q /data" "systemctl start docker" "docker compose up -d" \
  "systemctl start edh-backup.timer edh-drill.timer" "wait_health")" ok "restore disk: mount, docker, compose up, timers, health check"
s1=$(line_of 'ssm send-command' 1); s2=$(line_of 'ssm send-command' 2)
d=$(line_of 'detach-volume --volume-id vol-stub'); a=$(line_of 'attach-volume')
assert_eq "$(( s1 < d && d < a && a < s2 ))" "1" "restore disk: volumes are swapped between unmount and mount"
assert_contains "$(grep create-volume "$T/log")" "--snapshot-id snap-0123abcd" "restore disk: new volume from the snapshot"
assert_contains "$(grep create-volume "$T/log")" "{Key=edh:role,Value=data-restoring},{Key=Protect,Value=true}" \
  "restore disk: new volume is protected and not yet tagged as the data volume"
assert_contains "$(cat "$T/log")" "create-tags --resources vol-stub --tags Key=edh:role,Value=data-replaced-" "restore disk: old volume re-tagged"
assert_contains "$(cat "$T/log")" "create-tags --resources stub --tags Key=edh:role,Value=data Key=edh:snapshot,Value=acme-prod" \
  "restore disk: new volume becomes the data volume"
assert_eq "$(calls delete-volume)" "0" "restore disk never deletes a volume"
: > "$T/log"
out=$(EDH_YES=1 run restore.sh disk --snapshot snap-0123abcd); rc=$?
assert_status $rc 1 "restore disk: data volume not attached to the server: refuses"
assert_eq "$(calls create-volume)" "0" "restore disk: not attached: nothing created"
: > "$T/log"
out=$(EDH_YES=1 STUB_VOL_ATTACHED=i-stub STUB_SSM_RC=1 run restore.sh disk --snapshot snap-0123abcd); rc=$?
assert_status $rc 1 "restore disk: unmount fails: stops"
assert_contains "$out" "nothing was swapped" "restore disk: unmount fails: explained"
assert_eq "$(calls detach-volume)" "0" "restore disk: unmount fails: old volume stays attached"
assert_contains "$(script_n 2)" "systemctl start docker" "restore disk: unmount fails: the app is started again"

# ============ status (read-only)
: > "$T/log"
out=$(run status.sh); rc=$?
assert_status $rc 0 "status succeeds"
assert_contains "$out" "server:  i-stub" "status shows the server"
assert_contains "$(script_n 1)" "/opt/edh/bin/edh-status.sh" "status runs edh-status.sh"
assert_not_contains "$(cat "$T/log")" "alarm-name-prefix" "status asks for exact alarm names (a prefix also matches other clients)"
assert_contains "$(cat "$T/log")" "--alarm-names edh-acme-prod-disk-root-warn" "status asks for this client's alarms"
finish
