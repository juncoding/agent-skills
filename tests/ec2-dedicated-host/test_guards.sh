# tests/ec2-dedicated-host/test_guards.sh
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PATH="$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/log"
TPL="$SKILL_DIR/assets/project/deploy.yml"
# runf <deploy.yml> <commands> — load the config, then run commands; prints stdout+stderr
runf() { bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$1'; $2" 2>&1; }
run() { runf "$TPL" "$1"; }

assert_contains "$(run 'guard_not_protected vol-protected')" "Protect=true" "refuses protected resource"
assert_contains "$(run 'guard_not_protected vol-upper')" "Protect=true" "Protect=TRUE (any case) also refused"
assert_eq "$(run 'guard_not_protected vol-other; echo passed')" "passed" "allows unprotected resource"
out=$(run 'guard_not_protected vol-error; echo passed')
assert_contains "$out" "cannot read tags" "refuses when describe-tags fails"
assert_not_contains "$out" "passed" "describe-tags failure does not continue"

assert_eq "$(run 'aws_account')" "123456789012" "aws_account via sts"
out=$(STUB_STS_FAIL=1 run 'aws_account; echo passed')
assert_contains "$out" "cannot read AWS account" "aws_account dies when sts fails"
assert_not_contains "$out" "passed" "sts failure does not continue"
assert_contains "$(STUB_ACCOUNT=None run 'aws_account')" "not a 12-digit" "aws_account rejects non-account output"

assert_contains "$(run 'tag_spec volume edh-acme-prod-data Protect=true')" "{Key=Protect,Value=true}" "tag_spec adds extra tags"
assert_contains "$(run 'tag_spec volume x')" "{Key=Client,Value=acme}" "tag_spec adds cost tag"

assert_eq "$(run 'EDH_YES=1 confirm "go?"; echo yes')" "yes" "confirm honours EDH_YES=1"
assert_contains "$(run 'confirm "go?" </dev/null')" "aborted" "confirm without consent aborts"
assert_eq "$(run 'confirm "go?" <<<y && echo agreed')" "agreed" "confirm accepts y"
assert_eq "$(run 'confirm "go?" <<<YES && echo agreed')" "agreed" "confirm accepts YES"
assert_eq "$(run 'confirm "go?" <<<Yes && echo agreed')" "agreed" "confirm accepts Yes"
out=$(run 'confirm "go?" <<<no && echo agreed')
assert_contains "$out" "aborted" "confirm rejects no"
assert_not_contains "$out" "agreed" "confirm 'no' does not continue"

assert_eq "$(run 'x=$(gen_secret 40); echo ${#x}')" "40" "gen_secret length"
assert_eq "$(run 'x=$(gen_secret 64); echo ${#x}')" "64" "gen_secret max length"
assert_contains "$(run 'x=$(gen_secret 65); echo ${#x}')" "gen_secret" "gen_secret refuses > 64"

# --- require_account (stub account is 123456789012)
sed 's/^account_id: .*/account_id: 123456789012/' "$TPL" > "$T/match.yml"
sed 's/^account_id: .*/account_id: 111111111111/' "$TPL" > "$T/other.yml"
assert_eq "$(runf "$T/match.yml" 'require_account; echo passed')" "passed" "require_account passes on matching account"
out=$(runf "$T/other.yml" 'require_account; echo passed')
assert_contains "$out" "AWS credentials are for account 123456789012 but deploy.yml says 111111111111" "require_account refuses other account"
assert_not_contains "$out" "passed" "account mismatch does not continue"
out=$(run 'require_account; require_account; echo passed')
assert_contains "$out" "passed" "require_account without account_id continues"
n=$(printf '%s\n' "$out" | grep -c "account_id")
assert_eq "$n" "1" "require_account without account_id warns exactly once"
finish
