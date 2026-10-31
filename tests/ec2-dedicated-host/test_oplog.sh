# tests/ec2-dedicated-host/test_oplog.sh — deploy/OPERATIONS.md: every mutating command appends one line under
# "## Log", success or failure; plan and read-only runs don't; secret values and the bypass token never appear
# (stub `aws`, fake docker; never real AWS)
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/s3"
REAL_DOCKER=$(command -v docker)
printf '#!/bin/bash\necho "docker $*" >> "%s"\ncase "$1" in login) cat >/dev/null ;; esac\nif [[ "$1" == compose && " $* " == *" config "* ]]; then exec "%s" "$@"; fi\nexit 0\n' "$T/log.docker" "$REAL_DOCKER" > "$T/bin/docker"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/curl"
printf '#!/bin/sh\necho 203.0.113.10\n' > "$T/bin/dig"
chmod +x "$T/bin/"*
export PATH="$T/bin:$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/log" STUB_S3="$T/s3" STUB_MODE=existing
export EDH_SSM_POLL_SECONDS=0 EDH_REBOOT_POLL_SECONDS=0 EDH_IAM_WAIT=0 EDH_SKIP_SSM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
git init -q --bare -b main "$T/origin.git"
mkdir "$T/p"; cd "$T/p" || exit 1
git init -q -b main . && git config user.name "Op Erator"
bash "$SKILL_DIR/scripts/init.sh" --client acme --domain app.example.com --emails ops@example.com --account-id 123456789012 >/dev/null 2>&1
git add -A && git commit -qm "Add PDF export" && git remote add origin "$T/origin.git" && git push -q origin main
OPS=deploy/OPERATIONS.md
run() { bash "$SKILL_DIR/scripts/$1" "${@:2}" 2>&1; }
lines() { grep -c '^- ' "$OPS" 2>/dev/null || echo 0; }
last() { grep '^- ' "$OPS" | tail -1; }
# logged <description> <expected substring of the new last line> <script> [args...] — one new line, as expected
logged() {
  local desc="$1" want="$2" n; shift 2
  n=$(lines); run "$@" >/dev/null
  assert_eq "$(lines)" "$((n + 1))" "$desc: one line appended"
  assert_contains "$(last)" "$want" "$desc: $want"
}
sha=$(git rev-parse --short=12 HEAD)

# ============ deploy: success, failures, refusal
logged "deploy ok" "· deploy · ok · $sha \"Add PDF export\" · Op Erator" deploy.sh
assert_contains "$(last)" "UTC · deploy" "the line starts with the UTC time"
assert_eq "$(last | grep -cE '^- [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} UTC · ')" "1" "the line has the date and time"
assert_eq "$(awk '/^## Log/ { f = 1 } f && /^- / { n++ } END { print n }' "$OPS")" "$(lines)" "log lines are under ## Log"
STUB_SSM_RC=2 logged "deploy rolled back" "· deploy · rolled back · $sha" deploy.sh
STUB_SSM_RC=1 logged "deploy failed" "· deploy · failed (exit 1) · $sha" deploy.sh
( cd "$T" && git clone -q origin.git other && cd other && git commit -q --allow-empty -m newer && git push -q origin main )
logged "deploy refused" "· deploy · refused" deploy.sh
assert_contains "$(last)" "behind origin/main" "a refusal says why"
git pull -q --ff-only origin main
# the deploy that wrote the log is not blocked by it next time
logged "deploy after a logged deploy" "· deploy · ok ·" deploy.sh

# ============ plan and read-only runs don't log
n=$(lines)
run provision.sh >/dev/null; run status.sh >/dev/null; run secrets.sh list >/dev/null; run backup.sh list >/dev/null
run maint.sh status >/dev/null; run monitoring.sh status >/dev/null
assert_eq "$(lines)" "$n" "plan and read-only commands append nothing"

# ============ every other mutating command logs, with its key detail
export EDH_YES=1
printf 'S3cretValue-XYZ' | logged "secrets set" "· secrets · ok · set resend-api-key" secrets.sh set resend-api-key
logged "secrets delete" "· secrets · ok · delete resend-api-key" secrets.sh delete resend-api-key
logged "maint on" '· maint · ok · on "Upgrading the ERP" until 23:00' maint.sh on --message "Upgrading the ERP" --until 23:00
logged "maint off" "· maint · ok · off" maint.sh off
logged "maint rotate-bypass" "· maint · ok · rotate-bypass" maint.sh rotate-bypass
logged "rollback" "· rollback · ok" rollback.sh
STUB_SSM_RC=1 logged "rollback failed" "· rollback · failed (exit 1)" rollback.sh
STUB_SSM_OUT="app-20261030T010000Z.dump" logged "backup now" "· backup · ok · now db/daily/app-20261030T010000Z.dump" backup.sh now
STUB_SSM_OUT="db/hourly/app-20261030T010000Z.dump	2026-10-30T01:00:05Z" \
  logged "restore check" "· restore · ok · db check db/hourly/app-20261030T010000Z.dump" restore.sh db --latest --check
logged "restore replace" "· restore · ok · db replace db/daily/app-20261029T180000Z.dump" restore.sh db --key db/daily/app-20261029T180000Z.dump
STUB_VOL_ATTACHED=i-stub logged "restore disk" "· restore · ok · disk snap-0123abcd" restore.sh disk --snapshot snap-0123abcd
logged "monitoring add" "· monitoring · ok · add" monitoring.sh add
logged "monitoring remove" "· monitoring · ok · remove" monitoring.sh remove
logged "resize instance" "· resize · ok · instance t4g.medium → m7g.large" resize.sh instance m7g.large
logged "resize disk" "· resize · ok · disk 20 → 40 GB" resize.sh disk 40
STUB_SSM_OUT=NO-REBOOT logged "upgrade" "· upgrade · ok · os" upgrade.sh os
logged "provision apply" "· provision · ok · apply" provision.sh --apply
EDH_CONFIRM_NAME=acme-prod logged "teardown" "· teardown · ok" teardown.sh --keep-ip
assert_contains "$(last)" "--keep-ip" "teardown: the option is logged"
unset EDH_YES
logged "confirmation declined" "· rollback · aborted" rollback.sh </dev/null
# nested calls (provision/teardown → monitoring.sh) don't add their own lines: checked by the counts above

# ============ never a secret value or the bypass token
assert_not_contains "$(cat "$OPS")" "S3cretValue-XYZ" "a secret value never reaches OPERATIONS.md"
tok=$(cat "$T/log.params/_acme_prod__edh_maint-bypass" 2>/dev/null)
[[ -n "$tok" ]] && assert_not_contains "$(cat "$OPS")" "$tok" "the new bypass token never reaches OPERATIONS.md" || fail "no rotated token to check"
assert_not_contains "$(cat "$OPS")" "maint_bypass=" "no bypass link in OPERATIONS.md"

# ============ a rejected secrets name is never echoed or logged (a value pasted as the name)
n=$(lines)
out=$(printf 'x' | run secrets.sh set Sk_Live_SECRETVALUE123); rc=$?
assert_status $rc 1 "secrets set with an invalid name: refused"
assert_not_contains "$out" "SECRETVALUE123" "an invalid name is not echoed on stdout/stderr"
assert_not_contains "$(cat "$OPS")" "SECRETVALUE123" "an invalid name never reaches OPERATIONS.md"
assert_eq "$(lines)" "$((n + 1))" "an invalid name: one line logged"
assert_contains "$(last)" "· secrets · refused · set <invalid name>" "an invalid name is logged as <invalid name>"
out=$(EDH_YES=1 run secrets.sh delete 'Sk_Live_SECRETVALUE123'); rc=$?
assert_not_contains "$out$(cat "$OPS")" "SECRETVALUE123" "delete with an invalid name: not echoed or logged"
assert_contains "$(last)" "· secrets · refused · delete <invalid name>" "delete with an invalid name is logged as <invalid name>"

# ============ one action is exactly one line: control characters in any field are dropped
git commit -q --allow-empty -m "$(printf 'Fix\r\033[31m red\001\nsecond line')" && git push -q origin main
before=$(wc -l < "$OPS")
run deploy.sh >/dev/null
assert_eq "$(( $(wc -l < "$OPS") - before ))" "1" "a commit subject with CR, ESC and a newline adds exactly one line"
assert_eq "$(printf '%s' "$(last)" | LC_ALL=C tr -d '\040-\176\200-\377' | wc -c | tr -d ' ')" "0" "the line has no control characters"
assert_contains "$(last)" "Fix [31m red" "the subject is kept, minus its control characters"
EDH_YES=1 run maint.sh on --message "$(printf 'two\nlines\rhere')" --no-link >/dev/null
assert_contains "$(last)" '"two lines here"' "a maintenance message with newline and CR stays on one line"
EDH_YES=1 run maint.sh off >/dev/null

# ============ the log is a regular file in a real directory: never written through a symlink
printf 'outside\n' > "$T/elsewhere.md"
mv "$OPS" "$T/ops.keep"; ln -s "$T/elsewhere.md" "$OPS"
out=$(EDH_YES=1 run maint.sh off); rc=$?
assert_status $rc 0 "a symlinked OPERATIONS.md doesn't fail the command"
assert_eq "$(cat "$T/elsewhere.md")" "outside" "a symlinked OPERATIONS.md is not written through"
assert_eq "$(printf '%s\n' "$out" | grep -c 'symlink')" "1" "a symlinked OPERATIONS.md: a single warning"
rm -f "$OPS"; mv "$T/ops.keep" "$OPS"
mv deploy "$T/realdeploy"; ln -s "$T/realdeploy" deploy
n=$(grep -c '^- ' "$T/realdeploy/OPERATIONS.md")
out=$(EDH_YES=1 run maint.sh off); rc=$?
assert_eq "$(grep -c '^- ' "$T/realdeploy/OPERATIONS.md")" "$n" "a symlinked deploy/ directory: the log is not written"
assert_contains "$out" "symlink" "a symlinked deploy/ directory: warned"
rm -f deploy; mv "$T/realdeploy" deploy

# ============ an older project without OPERATIONS.md: created with the skeleton on the first logged command
rm -f "$OPS"
logged "older project" "· maint · ok · off" maint.sh off
assert_contains "$(cat "$OPS")" "## Notes" "older project: the skeleton is created"
assert_contains "$(cat "$OPS")" "## Log" "older project: with a Log section"

# ============ a log that can't be written never fails the command
rm -f "$OPS"; mkdir "$OPS"
out=$(run maint.sh off); rc=$?
assert_status $rc 0 "an unwritable OPERATIONS.md doesn't fail the command"
assert_contains "$out" "not a regular file" "an OPERATIONS.md that isn't a regular file: warned"
rmdir "$OPS"
cp "$SKILL_DIR/assets/project/OPERATIONS.md" "$OPS"; chmod 444 "$OPS"
out=$(run maint.sh off); rc=$?
assert_status $rc 0 "a read-only OPERATIONS.md doesn't fail the command"
assert_contains "$out" "could not write" "a read-only OPERATIONS.md: warned"
chmod 644 "$OPS"
# the skill never commits or pushes it
assert_eq "$(git log --format=%s -- "$OPS" | grep -vc '^Add PDF export$')" "0" "OPERATIONS.md is never committed by the skill"
finish
