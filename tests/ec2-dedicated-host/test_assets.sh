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

# --- AWS templates
export STUB_LOG="$T/aws.log"
render() { bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$SKILL_DIR/assets/project/deploy.yml'; EDH_ACCOUNT=123456789012; render_aws $1" 2>&1; }
for f in ec2-trust.json host-policy.json backups-lifecycle.json uploads-lifecycle.json dlm-policy.json; do
  [[ -f "$SKILL_DIR/assets/aws/$f" ]] && pass "has $f" || fail "missing assets/aws/$f"
done
pol=$(render host-policy.json)
printf '%s' "$pol" | python3 -m json.tool >/dev/null 2>&1 && pass "rendered host policy is JSON" || fail "rendered host policy invalid"
assert_contains "$pol" "parameter/acme/prod/*" "policy scoped to client SSM path"
assert_contains "$pol" "edh-acme-prod-backups-123456789012/db/*" "backup writes scoped to db/"
assert_not_contains "$pol" "s3:DeleteObject\",\"Resource\":\"arn:aws:s3:::edh-acme-prod-backups" "host cannot delete backups"
assert_not_contains "$pol" "__" "no unrendered placeholders"
# structurally: no delete on the backup bucket; backup writes create-only; metrics only in namespace EDH/<name>
chk=$(printf '%s' "$pol" | python3 -I -c 'import json, sys
st = json.load(sys.stdin)["Statement"]
lst = lambda v: v if isinstance(v, list) else [v]
bad = [s["Sid"] for s in st if any("Delete" in a or a in ("s3:*", "*") for a in lst(s["Action"]))
       and any("backups" in r for r in lst(s["Resource"]))]
m = [s for s in st if "cloudwatch:PutMetricData" in lst(s["Action"])]
w = [s for s in st if "s3:PutObject" in lst(s["Action"]) and any("backups" in r for r in lst(s["Resource"]))]
s3 = [s["Sid"] + "=" + s.get("Condition", {}).get("StringEquals", {}).get("s3:ResourceAccount", "-")
      for s in st if any(a.startswith("s3:") for a in lst(s["Action"]))]
print("delete:" + ",".join(bad) + " ns:" + ",".join(s["Condition"]["StringEquals"]["cloudwatch:namespace"] for s in m)
      + " put:" + ",".join(s["Sid"] + "=" + s.get("Condition", {}).get("StringEquals", {}).get("s3:if-none-match", "-") for s in w)
      + " owner:" + ",".join(s3))' 2>&1)
assert_eq "$chk" "delete: ns:EDH/acme-prod put:BackupsWrite=* owner:BackupsWrite=123456789012,BackupsRead=123456789012,AppUploads=123456789012" \
  "policy: no delete on backups; backup writes create-only; S3 only in own-account buckets; metrics only in EDH/<name>"
assert_contains "$pol" "repository/edh/acme" "image pulls scoped to the client's ECR repo"
assert_contains "$pol" "sns:ap-southeast-1:123456789012:edh-acme-prod-alerts" "alerts scoped to the client's topic"
for f in backups-lifecycle.json uploads-lifecycle.json dlm-policy.json; do
  out=$(render "$f")
  printf '%s' "$out" | python3 -m json.tool >/dev/null 2>&1 && pass "rendered $f is JSON" || fail "rendered $f invalid"
  assert_not_contains "$out" "__" "no unrendered placeholders in $f"
done
assert_contains "$(render dlm-policy.json)" '"Value": "acme-prod"' "DLM targets this client's data volume"
assert_not_contains "$(render uploads-lifecycle.json)" '"Expiration"' "uploads: current versions never expire"
assert_eq "$(cat "$STUB_LOG" 2>/dev/null)" "" "render_aws uses the cached account (no AWS call)"
out=$(bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$SKILL_DIR/assets/project/deploy.yml'; EDH_ACCOUNT='1#x'; render_aws host-policy.json" 2>&1)
assert_contains "$out" "not a 12-digit" "render_aws refuses a malformed pre-set account"
finish
