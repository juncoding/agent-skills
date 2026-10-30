# tests/ec2-dedicated-host/test_ssm_run.sh
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PATH="$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/log" EDH_SSM_POLL_SECONDS=0
# guarded <seconds> <commands> — run under lib.sh + config, killed after <seconds> so a regression can't hang the suite.
# Prints output then "rc=<exit code>" (143 = killed by the guard).
guarded() {
  local pid wd rc
  /bin/bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$SKILL_DIR/assets/project/deploy.yml'; $2" > "$T/out" 2>&1 &
  pid=$!
  ( sleep "$1"; kill "$pid" ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid"; rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  cat "$T/out"; echo "rc=$rc"
}

export EDH_TEST_SCRIPT='set -e
echo "hello $USER" '"'"'single'"'"' `x` \ back
printf "%s\n" "$(date)"'
out=$(guarded 20 'ssm_run i-stub 60 "$EDH_TEST_SCRIPT"')
assert_eq "$out" "$EDH_TEST_SCRIPT
rc=0" "script round-trips through base64 and ResponseCode 0 is returned"
b64=$(sed -n 's/.*echo \([A-Za-z0-9+/=]*\) | base64 -d.*/\1/p' "$STUB_LOG.ssm-params")
assert_eq "$(printf '%s' "$b64" | base64 --decode)" "$EDH_TEST_SCRIPT" "base64 in send-command parameters decodes to the script"
assert_contains "$(cat "$STUB_LOG.ssm-params")" '"executionTimeout":["60"]' "timeout passed to SSM"

out=$(STUB_SSM_RC=3 guarded 20 'ssm_run i-stub 60 "exit 3" || echo "returned=$?"')
assert_contains "$out" "returned=3" "ResponseCode 3 becomes the exit code"

start=$SECONDS
out=$(STUB_SSM_SEND_FAIL=1 guarded 20 'ssm_run i-stub 60 "echo hi"; echo continued')
assert_contains "$out" "send-command to i-stub failed" "failed send-command dies with a message"
assert_not_contains "$out" "continued" "failed send-command stops the script"
assert_not_contains "$out" "rc=143" "failed send-command does not loop until killed"
assert_eq "$(( SECONDS - start < 10 ))" "1" "failed send-command returns quickly"

# --- polling errors (STUB_SSM_POLL_FAIL=<n>: the first n Status polls fail with STUB_SSM_POLL_ERR)
rm -f "$STUB_LOG.polls"
out=$(STUB_SSM_POLL_FAIL=1000 STUB_SSM_POLL_ERR="An error occurred (AccessDeniedException): not allowed" \
      guarded 20 'ssm_run i-stub 60 "echo hi"; echo continued')
assert_contains "$out" "AccessDeniedException" "repeated poll errors die showing the last error"
assert_not_contains "$out" "continued" "repeated poll errors stop the script"
assert_not_contains "$out" "rc=143" "repeated poll errors do not loop until killed"
assert_eq "$(cat "$STUB_LOG.polls")" "10" "gives up after 10 failed polls in a row"

rm -f "$STUB_LOG.polls"
out=$(STUB_SSM_POLL_FAIL=9 STUB_SSM_POLL_ERR="An error occurred (ThrottlingException): slow down" \
      guarded 20 'ssm_run i-stub 60 "echo hi"')
assert_contains "$out" "rc=0" "fewer than 10 poll errors in a row are tolerated"

rm -f "$STUB_LOG.polls"
out=$(STUB_SSM_POLL_FAIL=15 STUB_SSM_POLL_ERR="An error occurred (InvocationDoesNotExist) when calling GetCommandInvocation" \
      guarded 20 'ssm_run i-stub 60 "echo hi"')
assert_contains "$out" "rc=0" "InvocationDoesNotExist keeps waiting and is not counted as an error"
finish
