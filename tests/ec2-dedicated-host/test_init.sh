# tests/ec2-dedicated-host/test_init.sh
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export STUB_LOG="$T/aws.log"
mkdir "$T/a"; cd "$T/a" || exit 1
bash "$SKILL_DIR/scripts/init.sh" --client acme --domain erp.acme.com --emails "a@x.com,b@x.com" \
  --gotenberg --app-memory 700 --migrate "npx prisma migrate deploy && node seed.js" >/dev/null 2>&1
assert_status $? 0 "init succeeds"
y=$(cat deploy/deploy.yml)
assert_contains "$y" "client: acme" "client set"
assert_contains "$y" "domain: erp.acme.com" "domain set"
assert_contains "$y" "alert_emails: a@x.com,b@x.com" "emails set"
assert_contains "$y" "uses_gotenberg: true" "gotenberg set"
assert_contains "$y" "app_memory_mb: 700" "app memory set"
assert_contains "$y" 'migrate_cmd: "npx prisma migrate deploy && node seed.js"' "migrate set (& kept literally)"
assert_contains "$y" 'account_id: ""' "account_id left empty without --account-id"
for f in compose.yml Caddyfile maint/maintenance.html maint/down.html; do [[ -f "deploy/$f" ]] && pass "has $f" || fail "missing $f"; done
out=$(bash "$SKILL_DIR/scripts/init.sh" --client acme --domain erp.acme.com --emails a@x.com 2>&1)
assert_contains "$out" "already exists" "refuses to overwrite"
assert_contains "$(cat deploy/deploy.yml)" "uses_gotenberg: true" "refused init leaves deploy.yml untouched"

# --account-id
mkdir "$T/b"; cd "$T/b" || exit 1
bash "$SKILL_DIR/scripts/init.sh" --client acme --domain erp.acme.com --emails a@x.com --account-id 123456789012 >/dev/null 2>&1
assert_status $? 0 "init with --account-id succeeds"
assert_contains "$(cat deploy/deploy.yml)" 'account_id: "123456789012"' "account_id set"
assert_eq "$(bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config; echo \$EDH_ACCOUNT_ID")" "123456789012" "account_id loads back"

# invalid input: refuses and creates nothing
mkdir "$T/c"; cd "$T/c" || exit 1
out=$(bash "$SKILL_DIR/scripts/init.sh" --client acme --domain erp.acme.com --emails a@x.com --account-id 1234 2>&1); rc=$?
assert_status "$rc" 1 "init with a bad --account-id fails"
assert_contains "$out" "account_id" "bad --account-id is explained"
[[ ! -e deploy ]] && pass "failed init creates nothing" || fail "failed init left deploy/ behind"
out=$(bash "$SKILL_DIR/scripts/init.sh" --domain erp.acme.com 2>&1); rc=$?
assert_status "$rc" 1 "init without --client fails"
[[ ! -e deploy ]] && pass "init without --client creates nothing" || fail "init without --client left deploy/ behind"
out=$(bash "$SKILL_DIR/scripts/init.sh" --client 2>&1); rc=$?
assert_contains "$out" "--client needs a value" "option without its value is explained"
assert_eq "$(cat "$T/aws.log" 2>/dev/null)" "" "init makes no AWS calls"
finish
