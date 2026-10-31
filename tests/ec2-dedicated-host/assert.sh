# tests/ec2-dedicated-host/assert.sh
# Minimal assertions for the ec2-dedicated-host tests (no bats dependency). Source, don't run.
FAILS=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILS=$((FAILS + 1)); }
assert_eq()           { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (expected '$2', got '$1')"; fi; }
assert_contains()     { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (missing '$2')"; fi; }
assert_not_contains() { if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3 (unexpected '$2')"; fi; }
assert_status()       { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (exit $1, expected $2)"; fi; }
finish() { if (( FAILS == 0 )); then echo "  all passed"; exit 0; else echo "  $FAILS failed"; exit 1; fi; }

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/../.." && pwd)"
SKILL_DIR="$REPO_DIR/skills/ec2-dedicated-host"
# Always exercise scripts with the system bash (3.2 on macOS), even if a newer bash is first on PATH,
# so a bash-4-only feature in scripts/*.sh fails here instead of on a user's Mac.
bash() { /bin/bash "$@"; }

# Fence off real AWS for every test: `aws` resolves to the stub, and even if a test bypassed it,
# the real CLI would find no config, no credentials, no profile and no instance metadata.
export PATH="$TESTS_DIR/stubs:$PATH"
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
export AWS_PROFILE=edh-test-none AWS_EC2_METADATA_DISABLED=true
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_PROFILE
