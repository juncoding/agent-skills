# tests/ec2-dedicated-host/test_manifest.sh — the backup manifest: edh-backup.sh records key, sha256 and S3 version;
# edh-restore.sh and edh-drill.sh only use what it records. A fake `docker` stands in for Postgres, the stub `aws`
# for S3 (never real AWS).
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/s3" "$T/etc" "$T/app" "$T/data/backups" "$T/edh-bin"
H="$T/edh-bin"   # installed like edh-deploy.sh does: executable, so the scripts can call each other
install -m 755 "$SKILL_DIR"/assets/host/edh-*.sh "$H/"
# docker: pg_dump prints a fake archive, pg_restore swallows its input, psql answers 1
cat > "$T/bin/docker" <<'EOS'
#!/bin/bash
case "$*" in
  *pg_dump*) printf 'PGDMP fake dump %s\n' "${FAKE_DUMP:-one}" ;;
  *pg_restore*) cat >/dev/null ;;
  *psql*) echo 1 ;;
esac
exit 0
EOS
chmod +x "$T/bin/docker"
export PATH="$T/bin:$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/aws.log" STUB_S3="$T/s3"
export EDH_ENV_FILE="$T/etc/edh.env" EDH_APP_DIR="$T/app" EDH_DATA_DIR="$T/data" EDH_BIN_DIR="$H" EDH_LOCK_FILE="$T/edh.lock"
cat > "$EDH_ENV_FILE" <<'EOF'
EDH_CLIENT=t
EDH_ENV=prod
EDH_NAME=t-prod
EDH_REGION=ap-southeast-1
EDH_BACKUP_BUCKET=bkt
EDH_BACKUP_SCHEDULE=hourly
EDH_ALERT_TOPIC_ARN=arn:aws:sns:ap-southeast-1:123456789012:edh-t-prod-alerts
EDH_ACCOUNT_ID=123456789012
EOF
M="$T/data/backups/manifest.tsv"
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
alerted() { if grep -qF -- "--subject [t-prod] $1" "$STUB_LOG"; then echo yes; else echo no; fi; }
restore() { bash "$H/edh-restore.sh" "$@" 2>&1; }

# ============ backup: one manifest line per upload — key, sha256, VersionId, time
: > "$STUB_LOG"
name=$(bash "$H/edh-backup.sh" --tag manual 2>/dev/null); rc=$?
assert_status $rc 0 "backup succeeds"
line=$(tail -1 "$M" 2>/dev/null)
IFS=$'\t' read -r k s v when <<< "$line"
assert_eq "$k" "db/daily/$name" "manifest: the S3 key"
assert_eq "$s" "$(sha "$T/data/backups/$name")" "manifest: the dump's sha256"
assert_eq "$v" "v1" "manifest: the VersionId S3 returned"
assert_eq "$([[ "$when" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] && echo utc)" "utc" "manifest: the UTC time"
assert_eq "$(mode "$M")" "600" "manifest is 0600"
assert_contains "$(grep put-object "$STUB_LOG")" "--query VersionId" "backup asks S3 for the VersionId"
# only the newest 2000 lines are kept
for i in $(seq 1 2100); do printf 'db/old/app-%05d.dump\tx\tv1\t2020-01-01T00:00:00Z\n' "$i"; done > "$M"
FAKE_DUMP=two name=$(bash "$H/edh-backup.sh" --tag manual 2>/dev/null)
assert_eq "$(wc -l < "$M" | tr -d ' ')" "2000" "manifest rotated to the newest 2000 lines"
assert_eq "$(tail -1 "$M" | cut -f1)" "db/daily/$name" "rotation keeps the new entry"

# ============ restore: a manifest key is fetched by its version and its sha256 checked
: > "$STUB_LOG"
out=$(restore check "db/daily/$name"); rc=$?
assert_status $rc 0 "restore check of a manifest key succeeds"
assert_contains "$out" "verified db/daily/$name" "restore says the backup was verified"
assert_contains "$(grep get-object "$STUB_LOG")" "--key db/daily/$name --version-id v1" "restore fetches the exact version in the manifest"
assert_contains "$(grep get-object "$STUB_LOG")" "--expected-bucket-owner 123456789012" "restore checks the bucket owner"
assert_eq "$(ls "$T/data/backups" | grep -c '^restore-')" "0" "downloaded dump removed after the check"

# a correctly named dump planted straight into S3 (as a compromised app could): refused unless --unverified
planted="db/daily/app-20991231T000000Z.dump"
mkdir -p "$T/s3/bkt/db/daily"; cp "$T/data/backups/$name" "$T/s3/bkt/$planted"
: > "$STUB_LOG"
out=$(restore check "$planted"); rc=$?
assert_status $rc 1 "a key not in the manifest is refused"
assert_contains "$out" "backup $planted is not in this server's backup manifest" "refusal names the key"
assert_contains "$out" "Re-run with --unverified only if you are sure" "refusal mentions --unverified"
assert_eq "$(grep -c get-object "$STUB_LOG")" "0" "refused key is not downloaded"
: > "$STUB_LOG"
out=$(restore check "$planted" --unverified); rc=$?
assert_status $rc 0 "--unverified restores a key that is not in the manifest"
assert_contains "$out" "UNVERIFIED" "--unverified is logged"
assert_eq "$(alerted 'unverified backup restored')" "yes" "--unverified sends an alert"
out=$(bash "$H/edh-restore.sh" replace "$planted" 2>&1); rc=$?
assert_contains "$out" "replace needs --yes" "replace still needs --yes"
out=$(restore check "$planted" --bogus); rc=$?
assert_contains "$out" "unknown option: --bogus" "unknown restore options are refused"

# the recorded version altered (sha256 mismatch): refused
v="$T/s3/.versions/bkt/db/daily/$name/v1"
cp "$v" "$T/v1.orig"; printf 'tampered' >> "$v"
: > "$STUB_LOG"
out=$(restore check "db/daily/$name"); rc=$?
assert_status $rc 1 "a dump that doesn't match its manifest sha256 is refused"
assert_contains "$out" "does not match the sha256" "sha256 mismatch: explained"
assert_eq "$(ls "$T/data/backups" | grep -c '^restore-')" "0" "sha256 mismatch: the download is removed"
cp "$T/v1.orig" "$v"

# ============ drill: only manifest keys, never a listing of the bucket
: > "$STUB_LOG"
out=$(bash "$H/edh-drill.sh" 2>&1); rc=$?
assert_status $rc 0 "drill passes"
assert_contains "$(grep get-object "$STUB_LOG")" "--key db/daily/$name --version-id v1" "drill restores the newest manifest backup"
assert_not_contains "$(cat "$STUB_LOG")" "$planted" "drill ignores a newer key planted in S3"
assert_eq "$(grep -cE 's3 ls|list-objects' "$STUB_LOG")" "0" "drill does not list the bucket"
: > "$M"; : > "$STUB_LOG"
out=$(bash "$H/edh-drill.sh" 2>&1); rc=$?
assert_status $rc 1 "drill with an empty manifest fails"
assert_contains "$out" "no backups in this server's backup manifest" "drill with an empty manifest: explained"
assert_eq "$(alerted 'restore drill FAILED')" "yes" "drill with an empty manifest alerts"
finish
