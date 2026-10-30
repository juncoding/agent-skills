# tests/ec2-dedicated-host/test_smoke.sh
. "$(dirname "$0")/assert.sh"
out=$(bash -c ". '$SKILL_DIR/scripts/lib.sh'; ok hello" 2>&1)
assert_contains "$out" "hello" "lib.sh loads and ok() logs"
finish
