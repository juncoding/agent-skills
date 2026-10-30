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
assert_contains "$out" "instance metadata hop limit 2" "plan shows hop limit 2 (app may use the instance role)"
assert_eq "$(grep 'head-bucket' "$T/log" | grep -vc -- '--expected-bucket-owner 123456789012')" "0" \
  "head-bucket always checks the bucket owner"
assert_eq "$(grep -c 'head-bucket' "$T/log")" "2" "both buckets checked"

: > "$T/log"
out=$(STUB_MODE=existing bash "$SKILL_DIR/scripts/provision.sh" 2>&1); rc=$?
assert_status $rc 0 "plan on existing resources exits 0"
assert_contains "$out" "server edh-acme-prod: exists" "detects existing server"
assert_contains "$out" "data volume edh-acme-prod-data: exists" "detects existing volume"
assert_contains "$out" "IAM role edh-acme-prod-host: exists" "detects existing role"
mut=$(grep -E "$MUTATING" "$T/log" || true)
assert_eq "$mut" "" "plan on existing resources makes no mutating AWS calls"

# buckets that exist but aren't ours (403 / other owner): refuse, in plan and in apply mode
for args in "" --apply; do
  : > "$T/log"
  out=$(STUB_MODE=existing STUB_BUCKET=foreign bash "$SKILL_DIR/scripts/provision.sh" $args 2>&1); rc=$?
  assert_status $rc 1 "foreign bucket (${args:-plan}): provision refuses"
  assert_contains "$out" "bucket edh-acme-prod-backups-123456789012 exists but is not owned by account 123456789012 (or is inaccessible) — refusing" \
    "foreign bucket (${args:-plan}): explained"
  assert_eq "$(grep -cE ' s3api (create-bucket|put-)' "$T/log")" "0" "foreign bucket (${args:-plan}): bucket never configured"
done

# app_uses_instance_role: false → hop limit 1; an existing server with hop limit 2 is changed on --apply
cp deploy/deploy.yml "$T/keep.yml"
sed -i.bak 's/^app_uses_instance_role: .*/app_uses_instance_role: false/' deploy/deploy.yml
: > "$T/log"
out=$(STUB_MODE=empty bash "$SKILL_DIR/scripts/provision.sh" 2>&1)
assert_contains "$out" "instance metadata hop limit 1" "plan shows hop limit 1 (containers cannot reach instance metadata)"
: > "$T/log"
out=$(STUB_MODE=existing bash "$SKILL_DIR/scripts/provision.sh" 2>&1); rc=$?
assert_contains "$out" "instance metadata hop limit: would change 2 -> 1" "plan reports the hop limit change on an existing server"
assert_eq "$(grep -c 'modify-instance-metadata-options' "$T/log")" "0" "plan does not change the hop limit"
sed -i.bak 's/^monitoring: .*/monitoring: none/' deploy/deploy.yml   # monitoring.sh arrives in a later task
: > "$T/log"
out=$(STUB_MODE=existing EDH_SSM_POLL_SECONDS=0 bash "$SKILL_DIR/scripts/provision.sh" --apply 2>&1); rc=$?
assert_status $rc 0 "apply on existing resources succeeds"
assert_contains "$(cat "$T/log")" "modify-instance-metadata-options --instance-id i-stub --http-put-response-hop-limit 1" \
  "apply changes the hop limit of the existing server"
assert_contains "$out" "instance metadata hop limit: 2 -> 1" "apply reports the hop limit change"
cp "$T/keep.yml" deploy/deploy.yml

# account_id mismatch: refuses before any other AWS call
: > "$T/log"
sed -i.bak 's/^account_id: .*/account_id: "111111111111"/' deploy/deploy.yml
out=$(STUB_MODE=existing bash "$SKILL_DIR/scripts/provision.sh" 2>&1); rc=$?
assert_status $rc 1 "wrong account: provision refuses"
assert_contains "$out" "but deploy.yml says 111111111111" "wrong account: explained"
assert_eq "$(grep -cv 'sts get-caller-identity' "$T/log")" "0" "wrong account: no AWS call besides sts"
finish
