# tests/ec2-dedicated-host/test_provision_plan.sh
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PATH="$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/log"
mkdir -p "$T/p/deploy"
sed 's/^account_id: .*/account_id: "123456789012"/' "$SKILL_DIR/assets/project/deploy.yml" > "$T/p/deploy/deploy.yml"
cd "$T/p" || exit 1
MUTATING=' (create-|run-instances|put-|attach-|associate-|allocate-|authorize-|modify-|delete-|terminate-|add-role|tag-|update-|send-command|describe-instance-information)'

out=$(STUB_MODE=empty bash "$SKILL_DIR/scripts/provision.sh" 2>&1); rc=$?
assert_status $rc 0 "plan on empty account exits 0"
for r in "IAM role" "security group" "backup bucket" "uploads bucket" "ECR repo" "data volume" "Elastic IP" "server"; do
  assert_contains "$out" "$r edh" "plan lists $r"
done
assert_contains "$out" "would create" "plan says would create"
assert_contains "$out" "backup bucket edh-acme-prod-backups-123456789012: would create" "bucket names carry the account id"
assert_contains "$out" "plan only" "plan says nothing changes"
mut=$(grep -E "$MUTATING" "$T/log" || true)
assert_eq "$mut" "" "plan makes no mutating AWS calls (and no SSM commands)"
assert_eq "$(grep -c 'sts get-caller-identity' "$T/log")" "1" "account looked up once"

: > "$T/log"
out=$(STUB_MODE=existing bash "$SKILL_DIR/scripts/provision.sh" 2>&1); rc=$?
assert_status $rc 0 "plan on existing resources exits 0"
assert_contains "$out" "server edh-acme-prod: exists" "detects existing server"
assert_contains "$out" "data volume edh-acme-prod-data: exists" "detects existing volume"
assert_contains "$out" "IAM role edh-acme-prod-host: exists" "detects existing role"
mut=$(grep -E "$MUTATING" "$T/log" || true)
assert_eq "$mut" "" "plan on existing resources makes no mutating AWS calls"

# account_id mismatch: refuses before any other AWS call
: > "$T/log"
sed -i.bak 's/^account_id: .*/account_id: "111111111111"/' deploy/deploy.yml
out=$(STUB_MODE=existing bash "$SKILL_DIR/scripts/provision.sh" 2>&1); rc=$?
assert_status $rc 1 "wrong account: provision refuses"
assert_contains "$out" "but deploy.yml says 111111111111" "wrong account: explained"
assert_eq "$(grep -cv 'sts get-caller-identity' "$T/log")" "0" "wrong account: no AWS call besides sts"
finish
