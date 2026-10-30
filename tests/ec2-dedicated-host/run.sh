#!/usr/bin/env bash
# tests/ec2-dedicated-host/run.sh [--fast]
# Runs every test_*.sh, then shellcheck. --fast skips Docker integration tests (test_int_*.sh).
set -uo pipefail
cd "$(dirname "$0")"
rc=0
for t in test_*.sh; do
  if [[ "${1:-}" == --fast && "$t" == test_int_* ]]; then continue; fi
  echo "== $t"
  /bin/bash "$t" || rc=1   # system bash on purpose (3.2 on macOS) — see assert.sh
done
echo "== shellcheck"
repo="$(cd ../.. && pwd)"
# Expand the globs from the repo root (docker does not expand them); nullglob skips dirs that don't exist yet.
cd "$repo"
shopt -s nullglob
files=(skills/ec2-dedicated-host/scripts/*.sh skills/ec2-dedicated-host/assets/host/*.sh)
shopt -u nullglob
if (( ${#files[@]} > 0 )); then
  docker run --rm -v "$repo":/w -w /w koalaman/shellcheck:v0.10.0 -x -S warning "${files[@]}" || rc=1
fi
exit $rc
