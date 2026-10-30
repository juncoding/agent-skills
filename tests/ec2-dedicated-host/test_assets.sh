# tests/ec2-dedicated-host/test_assets.sh
. "$(dirname "$0")/assert.sh"
for f in "$SKILL_DIR"/assets/host/cwagent.json "$SKILL_DIR"/assets/aws/*.json; do
  [[ -e "$f" ]] || continue   # assets/aws/ arrives in Task 10
  python3 -m json.tool "$f" >/dev/null 2>&1 && pass "valid JSON: $(basename "$f")" || fail "invalid JSON: $f"
done
out=$(bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$SKILL_DIR/assets/project/deploy.yml'; render_bootstrap vol-0abc123" 2>&1)
assert_contains "$out" 'VOLUME_ID="vol-0abc123"' "bootstrap gets the volume id"
assert_not_contains "$out" "__" "no unrendered placeholders in bootstrap"
assert_contains "$out" "install -d -m 755 /data/postgres" "bootstrap: /data/postgres is 0755 (postgres must traverse it)"
assert_not_contains "$out" "-m 700 /data/postgres" "bootstrap: /data/postgres is not 0700"
assert_contains "$out" "install -d -m 700 /data/backups" "bootstrap: /data/backups is owner-only"
assert_contains "$out" "install -d -m 755 /data/caddy /data/maint" "bootstrap: /data/caddy and /data/maint are 0755"
assert_contains "$out" "docker compose version --short" "bootstrap checks the compose version"
assert_contains "$out" "2.30" "bootstrap requires compose >= 2.30"
for p in python3 util-linux coreutils curl; do assert_contains "$out" " $p" "bootstrap installs $p"; done
# the compose version check on its own, with a fake `docker` reporting each version
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
chk=$(sed -n '/^need=/,/^fi$/p' "$SKILL_DIR/assets/host/bootstrap.sh")
for v in 2.40.3:0 2.30.0:0 v2.31.1:0 2.29.7:1 2.9.0:1 1.29.2:1; do
  printf '#!/bin/sh\necho %s\n' "${v%:*}" > "$T/docker"; chmod +x "$T/docker"
  out=$(PATH="$T:$PATH" bash -c "set -euo pipefail; $chk" 2>&1); rc=$?
  assert_status "$rc" "${v#*:}" "compose version check: ${v%:*}"
done
assert_contains "$out" "too old" "compose version check explains the failure"
out=$(bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$SKILL_DIR/assets/project/deploy.yml'; render_bootstrap 'vol-0abc;rm'" 2>&1)
assert_contains "$out" "volume id" "render_bootstrap rejects a malformed volume id"
for u in "$SKILL_DIR"/assets/host/systemd/*; do assert_contains "$(cat "$u")" "edh-" "unit $(basename "$u") references edh"; done
[[ -n "$(ls "$SKILL_DIR"/assets/host/systemd/ 2>/dev/null)" ]] && pass "systemd units exist" || fail "no systemd units"
finish
