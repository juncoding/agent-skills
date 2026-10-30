# tests/ec2-dedicated-host/test_provision_plan.sh — provision.sh against the stub `aws` (never real AWS)
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PATH="$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/log" EDH_IAM_WAIT=0 EDH_SSM_POLL_SECONDS=0
mkdir -p "$T/p/deploy"
sed 's/^account_id: .*/account_id: "123456789012"/' "$SKILL_DIR/assets/project/deploy.yml" > "$T/base.yml"
sed 's/^monitoring: .*/monitoring: none/' "$T/base.yml" > "$T/nomon.yml"   # monitoring.sh arrives in a later task
cp "$T/base.yml" "$T/p/deploy/deploy.yml"
cd "$T/p" || exit 1
prov() { bash "$SKILL_DIR/scripts/provision.sh" "$@" 2>&1; }
refused() { grep -c 'STUB_READONLY refused' "$T/log" || true; }   # mutating calls the read-only stub refused
calls() { grep -c -- "$1" "$T/log" || true; }

# ============ plan, empty account: lists everything, changes nothing
: > "$T/log"
out=$(STUB_MODE=empty STUB_READONLY=1 prov); rc=$?
assert_status $rc 0 "plan on empty account exits 0"
for r in "IAM role" "security group" "backup bucket" "uploads bucket" "ECR repo" "data volume" "Elastic IP" "server"; do
  assert_contains "$out" "$r edh" "plan lists $r"
done
assert_contains "$out" "would create" "plan says would create"
assert_contains "$out" "backup bucket edh-acme-prod-backups-123456789012: would create" "bucket names carry the account id"
for s in "IAM role policies" "security group rules" "backup bucket settings" "uploads bucket settings" "ECR lifecycle policy"; do
  assert_contains "$out" "$s: would sync" "plan reports '$s' as would sync"
done
assert_contains "$out" "plan only" "plan says nothing changes"
assert_eq "$(refused)" "0" "plan makes no mutating AWS calls (read-only stub)"
assert_eq "$(calls describe-instance-information)" "0" "plan does not wait for SSM"
assert_eq "$(calls 'sts get-caller-identity')" "1" "account looked up once"
assert_contains "$out" "instance metadata hop limit 2" "plan shows hop limit 2 (app may use the instance role)"
assert_eq "$(grep 'head-bucket' "$T/log" | grep -vc -- '--expected-bucket-owner 123456789012')" "0" \
  "head-bucket always checks the bucket owner"
assert_eq "$(grep 'head-bucket' "$T/log" | grep -vc -- '--region ap-southeast-1')" "0" "head-bucket names the region"
assert_eq "$(calls head-bucket)" "2" "both buckets checked"
# placement: the stub offers t4g.medium in 1a, 1b, 1c, but only 1b and 1c have a default subnet
assert_contains "$out" "placement: t4g.medium in ap-southeast-1b" "AZ offers the type AND has a default subnet"

# ============ plan, existing resources
: > "$T/log"
out=$(STUB_MODE=existing STUB_READONLY=1 prov); rc=$?
assert_status $rc 0 "plan on existing resources exits 0"
assert_contains "$out" "server edh-acme-prod: exists" "detects existing server"
assert_contains "$out" "data volume edh-acme-prod-data: exists" "detects existing volume"
assert_contains "$out" "IAM role edh-acme-prod-host: exists" "detects existing role"
assert_contains "$out" "placement: t4g.medium in ap-southeast-1a" "existing server: its own AZ is used"
assert_eq "$(refused)" "0" "plan on existing resources makes no mutating AWS calls"

# ============ apply on existing resources: completes a partial earlier run (config re-applied every time)
cp "$T/nomon.yml" deploy/deploy.yml
: > "$T/log"
out=$(STUB_MODE=existing STUB_NO_SECRETS=1 STUB_SG_DUP=1 prov --apply); rc=$?
assert_status $rc 0 "apply on existing resources succeeds"
for c in "s3api put-public-access-block:2" "s3api put-bucket-versioning:2" "s3api put-bucket-tagging:2" \
         "s3api put-bucket-lifecycle-configuration:2" "ecr put-lifecycle-policy:1" "ec2 authorize-security-group-ingress:5" \
         "iam attach-role-policy:1" "iam put-role-policy:1"; do
  assert_eq "$(calls "${c%:*}")" "${c##*:}" "apply re-runs ${c%:*} (x${c##*:})"
done
assert_contains "$out" "security group rules: synced" "rules that already exist (InvalidPermission.Duplicate) are fine"
assert_eq "$(grep ' s3api put-' "$T/log" | grep -vc -- '--expected-bucket-owner 123456789012')" "0" \
  "every bucket configuration call checks the bucket owner"
assert_eq "$(grep -cE ' (create-|run-instances|allocate-|add-role-to)' "$T/log")" "0" "existing resources: nothing new created"
# C2: internal secrets: 40 hex characters, no trailing newline, passed by file (never on the command line)
for n in postgres-password maint-bypass; do
  f="$T/log.params/_acme_prod__edh_$n"
  v=$(cat "$f" 2>/dev/null)
  assert_eq "$([[ "$v" =~ ^[0-9a-f]{40}$ ]] && echo hex40)" "hex40" "secret $n is 40 hex characters"
  assert_eq "$(wc -c < "$f" 2>/dev/null | tr -d ' ')" "40" "secret $n has no trailing newline"
  assert_not_contains "$(cat "$T/log")" "$v" "secret $n is not on the command line"
done
assert_eq "$(grep 'put-parameter' "$T/log" | grep -vc -- '--value file://')" "0" "secrets are passed by file"
leftover=$(grep -o 'file://[^ ]*' "$T/log" | sed 's#file://##' | while read -r f; do [[ -e "$f" ]] && echo "$f"; done)
assert_eq "$leftover" "" "temp files (secrets, policies, lifecycle) removed"

# role exists but its instance profile has no role (a run that stopped half way): only the missing piece is added
: > "$T/log"
out=$(STUB_MODE=existing STUB_PROFILE_EMPTY=1 STUB_READONLY=1 prov); rc=$?
assert_contains "$out" "IAM role edh-acme-prod-host: would create" "instance profile without the role: role step incomplete"
: > "$T/log"
out=$(STUB_MODE=existing STUB_PROFILE_EMPTY=1 prov --apply); rc=$?
assert_status $rc 0 "instance profile without the role: apply succeeds"
assert_eq "$(calls 'add-role-to-instance-profile')" "1" "the role is added to the instance profile"
assert_eq "$(grep -cE 'iam (create-role|create-instance-profile)' "$T/log")" "0" "role and profile are not re-created"

# bootstrap failed on the server: fail fast, pointing at the log
: > "$T/log"
out=$(STUB_MODE=existing STUB_SSM_RC=3 prov --apply); rc=$?
assert_status $rc 1 "bootstrap failed: apply fails"
assert_contains "$out" "bootstrap FAILED" "bootstrap failed: explained"
assert_contains "$out" "/var/log/edh-bootstrap.log" "bootstrap failed: points at the log"
assert_eq "$(calls 'ssm send-command')" "1" "bootstrap failed: detected on the first check (no waiting)"
cp "$T/base.yml" deploy/deploy.yml

# ============ buckets that exist but aren't ours (403 / other owner): refuse before any change
for args in "" --apply; do
  : > "$T/log"
  out=$(STUB_MODE=existing STUB_BUCKET=foreign STUB_READONLY=1 prov $args); rc=$?
  assert_status $rc 1 "foreign bucket (${args:-plan}): provision refuses"
  assert_contains "$out" "bucket edh-acme-prod-backups-123456789012 exists but is not owned by account 123456789012 (or is inaccessible) — refusing" \
    "foreign bucket (${args:-plan}): explained"
  assert_eq "$(refused)" "0" "foreign bucket (${args:-plan}): zero mutating calls"
done

# ============ more than one tagged data volume / Elastic IP: refuse
out=$(STUB_MODE=existing STUB_MULTI=volume STUB_READONLY=1 prov); rc=$?
assert_status $rc 1 "two data volumes: refuses"
assert_contains "$out" "more than one data volume" "two data volumes: explained"
out=$(STUB_MODE=existing STUB_MULTI=eip STUB_READONLY=1 prov); rc=$?
assert_status $rc 1 "two Elastic IPs: refuses"
assert_contains "$out" "more than one Elastic IP" "two Elastic IPs: explained"

# ============ placement
out=$(STUB_MODE=empty STUB_NO_SUBNET=1 STUB_READONLY=1 prov); rc=$?
assert_status $rc 1 "no default subnet: refuses"
assert_contains "$out" "no default subnet in ap-southeast-1b" "no default subnet: explained"
out=$(STUB_MODE=empty STUB_SUBNET_AZS=ap-southeast-1z STUB_READONLY=1 prov); rc=$?
assert_status $rc 1 "no AZ offers the type and has a default subnet: refuses"
assert_contains "$out" "no availability zone" "no usable AZ: explained"
out=$(STUB_MODE=empty STUB_ARCH=x86_64 STUB_READONLY=1 prov); rc=$?
assert_status $rc 1 "instance type without arm64: refuses"
assert_contains "$out" "arm64" "instance type without arm64: explained"
# a server without its data volume: never create an empty data volume for it
: > "$T/log"
out=$(STUB_MODE=existing STUB_NO_VOLUME=1 STUB_READONLY=1 prov); rc=$?
assert_status $rc 0 "server without data volume: plan still exits 0"
assert_contains "$out" "--apply will refuse" "server without data volume: plan warns"
: > "$T/log"
out=$(STUB_MODE=existing STUB_NO_VOLUME=1 STUB_READONLY=1 prov --apply); rc=$?
assert_status $rc 1 "server without data volume: apply refuses"
assert_contains "$out" "refusing to create an empty data volume" "server without data volume: explained"
assert_eq "$(refused)" "0" "server without data volume: zero mutating calls"

# ============ app_uses_instance_role: false → hop limit 1; an existing server with hop limit 2 is changed on --apply
sed 's/^app_uses_instance_role: .*/app_uses_instance_role: false/' "$T/base.yml" > deploy/deploy.yml
out=$(STUB_MODE=empty STUB_READONLY=1 prov)
assert_contains "$out" "instance metadata hop limit 1" "plan shows hop limit 1 (containers cannot reach instance metadata)"
: > "$T/log"
out=$(STUB_MODE=existing STUB_READONLY=1 prov); rc=$?
assert_contains "$out" "instance metadata hop limit: would change 2 -> 1" "plan reports the hop limit change on an existing server"
assert_eq "$(refused)" "0" "plan does not change the hop limit"
sed 's/^app_uses_instance_role: .*/app_uses_instance_role: false/' "$T/nomon.yml" > deploy/deploy.yml
: > "$T/log"
out=$(STUB_MODE=existing prov --apply); rc=$?
assert_status $rc 0 "apply with a hop limit change succeeds"
assert_contains "$(cat "$T/log")" "modify-instance-metadata-options --instance-id i-stub --http-put-response-hop-limit 1" \
  "apply changes the hop limit of the existing server"
assert_contains "$out" "instance metadata hop limit: 2 -> 1" "apply reports the hop limit change"
cp "$T/base.yml" deploy/deploy.yml

# ============ account_id mismatch: refuses before any other AWS call
: > "$T/log"
sed 's/^account_id: .*/account_id: "111111111111"/' "$T/base.yml" > deploy/deploy.yml
out=$(STUB_MODE=existing prov); rc=$?
assert_status $rc 1 "wrong account: provision refuses"
assert_contains "$out" "but deploy.yml says 111111111111" "wrong account: explained"
assert_eq "$(grep -cv 'sts get-caller-identity' "$T/log")" "0" "wrong account: no AWS call besides sts"
finish
