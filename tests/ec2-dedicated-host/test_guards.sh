# tests/ec2-dedicated-host/test_guards.sh
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PATH="$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/log"
run() { bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$SKILL_DIR/assets/project/deploy.yml'; $1" 2>&1; }

assert_contains "$(run 'guard_not_protected vol-protected')" "Protect=true" "refuses protected resource"
assert_eq "$(run 'guard_not_protected vol-other; echo passed')" "passed" "allows unprotected resource"
assert_eq "$(run 'aws_account')" "123456789012" "aws_account via sts"
assert_contains "$(run 'tag_spec volume edh-acme-prod-data Protect=true')" "{Key=Protect,Value=true}" "tag_spec adds extra tags"
assert_contains "$(run 'tag_spec volume x')" "{Key=Client,Value=acme}" "tag_spec adds cost tag"
assert_eq "$(run 'EDH_YES=1 confirm "go?"; echo yes')" "yes" "confirm honours EDH_YES=1"
assert_contains "$(run 'confirm "go?" </dev/null')" "aborted" "confirm without consent aborts"
assert_eq "$(run 'x=$(gen_secret 40); echo ${#x}')" "40" "gen_secret length"
finish
