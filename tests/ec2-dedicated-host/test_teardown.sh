# tests/ec2-dedicated-host/test_teardown.sh — teardown.sh never deletes data (stub `aws`, never real AWS)
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PATH="$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/log" STUB_MODE=existing EDH_YES=1 EDH_SKIP_SSM=1 EDH_CONFIRM_NAME=acme-prod
export EDH_SSM_POLL_SECONDS=0
mkdir -p "$T/p/deploy"; cp "$SKILL_DIR/assets/project/deploy.yml" "$T/p/deploy/"; cd "$T/p" || exit 1
td() { bash "$SKILL_DIR/scripts/teardown.sh" "$@" 2>&1; }
line_of() { grep -n -- "$1" "$T/log" | head -1 | cut -d: -f1; }

out=$(td); rc=$?
log=$(cat "$T/log")
assert_status $rc 0 "teardown succeeds"
assert_contains "$log" "terminate-instances" "terminates the server"
assert_contains "$log" "release-address" "releases the IP"
assert_not_contains "$log" "delete-volume" "keeps the data volume"
assert_not_contains "$log" "delete-bucket" "keeps the buckets"
assert_not_contains "$log" "delete-parameter" "keeps the secrets"
assert_not_contains "$log" "delete-repository" "keeps the ECR repo"
assert_not_contains "$log" "delete-snapshot" "keeps the snapshots"
assert_not_contains "$log" " s3 rm" "deletes no S3 objects"
assert_not_contains "$log" " s3 rb" "removes no bucket"
assert_contains "$out" "kept" "explains what was kept"
assert_contains "$out" "no longer expire" "explains that snapshots stop expiring"
# IAM: inline policies, the managed policy, profile, then the role
for c in "delete-role-policy --role-name edh-acme-prod-host --policy-name edh-host" \
         "delete-role-policy --role-name edh-acme-prod-host --policy-name edh-cwagent" \
         "detach-role-policy --role-name edh-acme-prod-host --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" \
         "remove-role-from-instance-profile --instance-profile-name edh-acme-prod-host --role-name edh-acme-prod-host" \
         "delete-instance-profile --instance-profile-name edh-acme-prod-host" "delete-role --role-name edh-acme-prod-host"; do
  assert_contains "$log" "iam $c" "IAM: $c"
done
r=$(line_of 'iam delete-role --'); p=$(line_of 'iam delete-instance-profile'); x=$(line_of 'iam remove-role-from-instance-profile')
d=$(line_of 'iam detach-role-policy'); i=$(line_of 'iam delete-role-policy')
assert_eq "$(( i < d && d < x && x < p && p < r ))" "1" "IAM order: inline policies, managed policy, profile, role"
assert_not_contains "$log" "CloudWatchAgentServerPolicy" "never touches CloudWatchAgentServerPolicy"
# the security group passes the Protect=true guard before it is deleted
assert_eq "$(( $(line_of 'describe-tags --filters Name=resource-id,Values=sg-stub') < $(line_of 'delete-security-group') ))" "1" \
  "security group checked for Protect=true before deletion"
assert_contains "$log" "dlm delete-lifecycle-policy --policy-id policy-stub" "snapshot policy removed"
assert_contains "$log" "delete-alarms" "monitoring removed"

# a protected volume that would be deleted with the server: refuse before anything changes
: > "$T/log"
out=$(STUB_DOT_VOLUMES=vol-protected td); rc=$?
assert_status $rc 1 "protected DeleteOnTermination volume: teardown refuses"
assert_contains "$out" "Protect=true" "protected DeleteOnTermination volume: explained"
assert_eq "$(grep -cE 'terminate-instances|delete-|release-address|detach-' "$T/log")" "0" "protected DeleteOnTermination volume: nothing changed"

# without the typed confirmation: nothing happens
: > "$T/log"
out=$(EDH_CONFIRM_NAME='' td </dev/null); rc=$?
assert_status $rc 1 "teardown without confirmation aborts"
assert_eq "$(grep -cE 'terminate-instances|delete-|release-address' "$T/log")" "0" "teardown without confirmation changes nothing"

# another account: refuse before any AWS call besides sts
sed 's/^account_id: .*/account_id: "111111111111"/' "$SKILL_DIR/assets/project/deploy.yml" > deploy/deploy.yml
: > "$T/log"
out=$(STUB_READONLY=1 td); rc=$?
assert_status $rc 1 "wrong account: teardown refuses"
assert_contains "$out" "but deploy.yml says 111111111111" "wrong account: teardown explains"
assert_eq "$(grep -c 'STUB_READONLY refused' "$T/log")" "0" "wrong account: teardown makes no mutating call"
assert_eq "$(grep -v 'sts get-caller-identity' "$T/log" | grep -c .)" "0" "wrong account: teardown makes no AWS call besides sts"
finish
