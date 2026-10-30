# tests/ec2-dedicated-host/test_sizing.sh
. "$(dirname "$0")/assert.sh"
rec() { bash -c ". '$SKILL_DIR/scripts/lib.sh'; . '$SKILL_DIR/scripts/sizing.sh'; recommend_instance $1 $2" 2>&1; }
assert_eq "$(rec 400 false)"  "t4g.small"  "small app fits t4g.small (1168 MB)"
assert_eq "$(rec 460 false)"  "t4g.small"  "boundary: 1228 MB still fits t4g.small"
assert_eq "$(rec 461 false)"  "t4g.medium" "boundary: 1229 MB needs t4g.medium"
assert_eq "$(rec 700 true)"   "t4g.medium" "app + gotenberg fits t4g.medium (2368 MB)"
assert_eq "$(rec 1500 true)"  "t4g.large"  "bigger app needs t4g.large (3168 MB)"
assert_eq "$(rec 6000 true)"  "t4g.xlarge" "very large app needs t4g.xlarge (7668 MB)"
assert_contains "$(rec 9000 true)" "choose instance_type manually" "too large is refused"
finish
