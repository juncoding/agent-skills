# tests/ec2-dedicated-host/test_init.sh
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export STUB_LOG="$T/aws.log"
mkdir "$T/a"; cd "$T/a" || exit 1
bash "$SKILL_DIR/scripts/init.sh" --client acme --domain erp.example.com --emails "a@example.com,b@example.com" \
  --gotenberg --app-memory 700 --migrate "npx prisma migrate deploy && node seed.js" >/dev/null 2>&1
assert_status $? 0 "init succeeds"
y=$(cat deploy/deploy.yml)
assert_contains "$y" "client: acme" "client set"
assert_contains "$y" "domain: erp.example.com" "domain set"
assert_contains "$y" "alert_emails: a@example.com,b@example.com" "emails set"
assert_contains "$y" "uses_gotenberg: true" "gotenberg set"
assert_contains "$y" "app_memory_mb: 700" "app memory set"
assert_contains "$y" 'migrate_cmd: "npx prisma migrate deploy && node seed.js"' "migrate set (& kept literally)"
assert_contains "$y" 'account_id: ""' "account_id left empty without --account-id"
assert_contains "$y" "app_uses_instance_role: true" "app may use the instance role by default"
for f in compose.yml Caddyfile maint/maintenance.html maint/down.html OPERATIONS.md; do [[ -f "deploy/$f" ]] && pass "has $f" || fail "missing $f"; done
ops=$(cat deploy/OPERATIONS.md 2>/dev/null)
assert_contains "$ops" "# Operations log" "OPERATIONS.md has a title"
assert_contains "$ops" "## Notes" "OPERATIONS.md has a Notes section"
assert_contains "$ops" "decisions, incidents, one-off work — written by people or the agent" "Notes: what goes there"
assert_contains "$ops" "## Log" "OPERATIONS.md has a Log section"
assert_contains "$ops" "appended automatically by ec2-dedicated-host; newest at the bottom" "Log: how it is written"
assert_eq "$(grep -c '^- ' deploy/OPERATIONS.md)" "0" "a new OPERATIONS.md has no log lines yet"
out=$(bash "$SKILL_DIR/scripts/init.sh" --client acme --domain erp.example.com --emails a@example.com 2>&1)
assert_contains "$out" "already exists" "refuses to overwrite"
assert_contains "$(cat deploy/deploy.yml)" "uses_gotenberg: true" "refused init leaves deploy.yml untouched"

# an existing OPERATIONS.md alone is enough to refuse (init never overwrites it)
mkdir -p "$T/ops/deploy"; cd "$T/ops" || exit 1; echo "keep me" > deploy/OPERATIONS.md
out=$(bash "$SKILL_DIR/scripts/init.sh" --client acme --domain erp.example.com --emails a@example.com 2>&1); rc=$?
assert_status $rc 1 "init refuses when deploy/OPERATIONS.md exists"
assert_eq "$(cat deploy/OPERATIONS.md)" "keep me" "init leaves an existing OPERATIONS.md alone"

# symlinks: a symlinked deploy/ or deploy/OPERATIONS.md (even a dangling one) is refused
mkdir -p "$T/sym1/real"; cd "$T/sym1" || exit 1; ln -s real deploy
out=$(bash "$SKILL_DIR/scripts/init.sh" --client acme --domain erp.example.com --emails a@example.com 2>&1); rc=$?
assert_status $rc 1 "init refuses a symlinked deploy/"
assert_eq "$(ls real | wc -l | tr -d ' ')" "0" "init writes nothing through a symlinked deploy/"
mkdir -p "$T/sym2/deploy"; cd "$T/sym2" || exit 1; ln -s "$T/nowhere.md" deploy/OPERATIONS.md
out=$(bash "$SKILL_DIR/scripts/init.sh" --client acme --domain erp.example.com --emails a@example.com 2>&1); rc=$?
assert_status $rc 1 "init refuses a (dangling) symlinked deploy/OPERATIONS.md"
[[ ! -e "$T/nowhere.md" ]] && pass "init writes nothing through the symlink" || fail "init wrote through the symlink"

# --account-id
mkdir "$T/b"; cd "$T/b" || exit 1
bash "$SKILL_DIR/scripts/init.sh" --client acme --domain erp.example.com --emails a@example.com --account-id 123456789012 \
  --no-instance-role >/dev/null 2>&1
assert_status $? 0 "init with --account-id succeeds"
assert_contains "$(cat deploy/deploy.yml)" 'account_id: "123456789012"' "account_id set"
assert_contains "$(cat deploy/deploy.yml)" "app_uses_instance_role: false" "--no-instance-role sets app_uses_instance_role: false"
assert_eq "$(bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config; echo \$EDH_ACCOUNT_ID")" "123456789012" "account_id loads back"

# invalid input: refuses and creates nothing
mkdir "$T/c"; cd "$T/c" || exit 1
out=$(bash "$SKILL_DIR/scripts/init.sh" --client acme --domain erp.example.com --emails a@example.com --account-id 1234 2>&1); rc=$?
assert_status "$rc" 1 "init with a bad --account-id fails"
assert_contains "$out" "account_id" "bad --account-id is explained"
[[ ! -e deploy ]] && pass "failed init creates nothing" || fail "failed init left deploy/ behind"
out=$(bash "$SKILL_DIR/scripts/init.sh" --domain erp.example.com 2>&1); rc=$?
assert_status "$rc" 1 "init without --client fails"
[[ ! -e deploy ]] && pass "init without --client creates nothing" || fail "init without --client left deploy/ behind"
out=$(bash "$SKILL_DIR/scripts/init.sh" --client 2>&1); rc=$?
assert_contains "$out" "--client needs a value" "option without its value is explained"
assert_eq "$(cat "$T/aws.log" 2>/dev/null)" "" "init makes no AWS calls"
finish
