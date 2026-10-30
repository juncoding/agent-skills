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
# I4: format only a blank device (blkid -p rc 2 AND first 1 MiB all zeros); refuse anything else
assert_contains "$out" 'blkid -p "$DEV"' "bootstrap probes the device with blkid -p"
assert_contains "$out" "head -c 1048576" "bootstrap checks the first 1 MiB is zeros"
assert_contains "$out" "refusing to format" "bootstrap refuses a device that isn't blank"
assert_not_contains "$out" "|| mkfs" "no bare '|| mkfs'"
# I5: docker (and the backup/drill units) never start without /data
assert_contains "$out" "/etc/systemd/system/docker.service.d/edh-data.conf" "bootstrap adds a docker drop-in"
assert_contains "$out" "RequiresMountsFor=/data" "docker requires the /data mount"
assert_contains "$out" "systemctl daemon-reload" "bootstrap reloads systemd after the drop-in"
for u in edh-backup.service edh-drill.service; do
  assert_contains "$(cat "$SKILL_DIR/assets/host/systemd/$u")" "RequiresMountsFor=/data" "$u requires the /data mount"
  assert_contains "$(cat "$SKILL_DIR/assets/host/systemd/$u")" "TimeoutStartSec=2h" "$u has a 2 h start timeout"
done
# I6: first-boot races and failure marker
assert_eq "$(printf '%s\n' "$out" | grep -c 'apt-get -o DPkg::Lock::Timeout=600')" "2" "both apt-get calls wait for the dpkg lock"
assert_eq "$(printf '%s\n' "$out" | grep -n -e 'snap wait system seed.loaded' -e 'snap install' | cut -d: -f2- | head -1)" \
  "snap wait system seed.loaded" "snap waits for seeding before installing"
assert_contains "$out" "/var/lib/edh/bootstrap-failed" "a failed bootstrap leaves a marker"
# a manual re-run clears a stale failure marker before doing anything else
assert_eq "$(printf '%s\n' "$out" | grep -n -e 'rm -f /var/lib/edh/bootstrap-failed' -e 'apt-get' | head -1 | cut -d: -f2-)" \
  "rm -f /var/lib/edh/bootstrap-failed" "bootstrap clears a stale failure marker before installing anything"
# the UUID is read with a low-level probe (blkid's cache may not know a filesystem made a moment ago)
assert_contains "$out" 'UUID=$(blkid -p -s UUID -o value "$DEV")' "bootstrap reads the UUID with blkid -p"
assert_not_contains "$out" "fallocate -l 1G /swapfile &&" "swap setup is not an && chain"

# the format check itself, with fake blkid / mkfs.ext4 and a file as the device
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fmt=$(sed -n '/^rc=0; blkid -p/,/^fi$/p' "$SKILL_DIR/assets/host/bootstrap.sh")
printf '#!/bin/sh\nexit ${FAKE_BLKID_RC:-0}\n' > "$T/blkid"; printf '#!/bin/sh\necho "mkfs $*" >> "%s/mkfs.log"\n' "$T" > "$T/mkfs.ext4"
chmod +x "$T/blkid" "$T/mkfs.ext4"
head -c 2097152 /dev/zero > "$T/blank"; { head -c 4096 /dev/zero; printf 'x'; } > "$T/dirty"
for c in 2:blank:0:mkfs 2:dirty:1:- 0:dirty:0:- 4:blank:1:- 8:blank:1:-; do
  IFS=: read -r brc dev want mk <<< "$c"
  rm -f "$T/mkfs.log"
  o=$(PATH="$T:$PATH" FAKE_BLKID_RC=$brc DEV="$T/$dev" bash -c "set -euo pipefail; $fmt" 2>&1); r=$?
  got=$([[ -f "$T/mkfs.log" ]] && echo mkfs || echo -)
  assert_eq "$r $got" "$want $mk" "format check: blkid rc $brc on a $dev device -> exit $want, mkfs: $mk"
done
assert_contains "$o" "refusing to format" "format check explains a refusal"

# the compose version check on its own, with a fake `docker` reporting each version
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

# --- CloudWatch agent config: rendered per client (namespace CWAgent/<name>), still valid JSON
cwa=$(bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$SKILL_DIR/assets/project/deploy.yml'; render_cwagent" 2>&1)
printf '%s' "$cwa" | python3 -m json.tool >/dev/null 2>&1 && pass "rendered cwagent.json is JSON" || fail "rendered cwagent.json invalid"
assert_eq "$(printf '%s' "$cwa" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["metrics"]["namespace"])' 2>&1)" \
  "CWAgent/acme-prod" "agent publishes into namespace CWAgent/<name>"
assert_not_contains "$cwa" "__" "no unrendered placeholders in cwagent.json"
# nothing in the skill uses the shared, bare CWAgent namespace any more
bare=$(grep -rnE 'CWAgent([^/]|$)' "$SKILL_DIR" | grep -v 'CWAgent/' || true)
assert_eq "$bare" "" "no reference to the bare CWAgent namespace"

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
# C1: AmazonSSMManagedInstanceCore allows ssm:GetParameter* on *: an explicit Deny keeps other clients' parameters out
deny=$(printf '%s' "$pol" | python3 -I -c 'import json, sys
st = [s for s in json.load(sys.stdin)["Statement"] if s.get("Sid") == "NoOtherParameters"]
if len(st) != 1: print("missing"); sys.exit()
s = st[0]
print(s["Effect"], ",".join(sorted(s["Action"])), "|".join(s["NotResource"]), "Resource" in s)' 2>&1)
assert_eq "$deny" "Deny ssm:GetParameter,ssm:GetParameterHistory,ssm:GetParameters,ssm:GetParametersByPath arn:aws:ssm:ap-southeast-1:123456789012:parameter/acme/prod|arn:aws:ssm:ap-southeast-1:123456789012:parameter/acme/prod/*|arn:aws:ssm:*::parameter/aws/service/* False" \
  "policy denies reading any SSM parameter outside /acme/prod (and public /aws/service)"
assert_eq "$(printf '%s' "$pol" | python3 -I -c 'import json, sys
s = [s for s in json.load(sys.stdin)["Statement"] if s.get("Sid") == "BackupsRead"][0]
print(",".join(sorted(s["Action"])), s["Resource"])' 2>&1)" "s3:GetObject,s3:GetObjectVersion arn:aws:s3:::edh-acme-prod-backups-123456789012/*" \
  "backups readable by version (restores fetch the exact version in the backup manifest); no listing"
assert_contains "$pol" "repository/edh/acme" "image pulls scoped to the client's ECR repo"
assert_contains "$pol" "sns:ap-southeast-1:123456789012:edh-acme-prod-alerts" "alerts scoped to the client's topic"
for f in backups-lifecycle.json uploads-lifecycle.json dlm-policy.json; do
  out=$(render "$f")
  printf '%s' "$out" | python3 -m json.tool >/dev/null 2>&1 && pass "rendered $f is JSON" || fail "rendered $f invalid"
  assert_not_contains "$out" "__" "no unrendered placeholders in $f"
done
assert_contains "$(render dlm-policy.json)" '"Value": "acme-prod"' "DLM targets this client's data volume"
# I9: lifecycle under versioning: noncurrent versions expire per prefix; expired delete markers are removed
lc=$(render backups-lifecycle.json | python3 -I -c 'import json, sys
rules = json.load(sys.stdin)["Rules"]
out = []
for r in rules:
    p = r["Filter"]["Prefix"]
    e = r.get("Expiration", {})
    if "Days" in e and "ExpiredObjectDeleteMarker" in e: out.append("BAD:" + r["ID"])
    out.append("%s=%s%s" % (p or "*", r.get("NoncurrentVersionExpiration", {}).get("NoncurrentDays", "-"),
                            "+dm" if e.get("ExpiredObjectDeleteMarker") else ""))
print(" ".join(out))' 2>&1)
assert_eq "$lc" "db/hourly/=1 db/daily/=7 db/monthly/=30 db/safety/=7 _edh/bundles/=1 *=30+dm" \
  "backups lifecycle: noncurrent days per prefix, delete markers cleaned, no Days+DeleteMarker rule"
lc=$(render uploads-lifecycle.json | python3 -I -c 'import json, sys
r = json.load(sys.stdin)["Rules"]
print(len(r), r[0]["NoncurrentVersionExpiration"]["NoncurrentDays"], r[0]["Expiration"], r[0]["AbortIncompleteMultipartUpload"]["DaysAfterInitiation"])' 2>&1)
assert_eq "$lc" "1 30 {'ExpiredObjectDeleteMarker': True} 7" "uploads lifecycle: noncurrent 30 days, delete markers cleaned, never expires current"
assert_not_contains "$(render uploads-lifecycle.json)" '"Days"' "uploads: current versions never expire (no Expiration Days)"
assert_eq "$(cat "$STUB_LOG" 2>/dev/null)" "" "render_aws uses the cached account (no AWS call)"
out=$(bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$SKILL_DIR/assets/project/deploy.yml'; EDH_ACCOUNT='1#x'; render_aws host-policy.json" 2>&1)
assert_contains "$out" "not a 12-digit" "render_aws refuses a malformed pre-set account"
finish
