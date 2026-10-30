# tests/ec2-dedicated-host/test_bundle.sh — the per-release bundle (make_bundle / release_env)
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PATH="$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/log"
cd "$T" || exit 1
bash "$SKILL_DIR/scripts/init.sh" --client acme --domain erp.acme.com --emails a@x.com --migrate "npm run m" >/dev/null 2>&1
tgz=$(bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config; make_bundle abc123" 2>/dev/null)
[[ -n "$tgz" && -f "$tgz" ]] && pass "make_bundle prints the path of the bundle" || { fail "make_bundle made no bundle"; finish; }
list=$(tar tzf "$tgz")
for f in ./release.env ./app/compose.yml ./app/Caddyfile ./app/maint/maintenance.html ./app/maint/down.html \
         ./host/systemd/edh-backup.timer; do
  assert_contains "$list" "$f" "bundle has $f"
done
for f in "$SKILL_DIR"/assets/host/edh-*.sh; do assert_contains "$list" "./host/$(basename "$f")" "bundle has host/$(basename "$f")"; done
for f in "$SKILL_DIR"/assets/host/systemd/*; do assert_contains "$list" "./host/systemd/$(basename "$f")" "bundle has host/systemd/$(basename "$f")"; done
assert_not_contains "$list" "bootstrap.sh" "bootstrap is not shipped in bundles"
assert_not_contains "$list" "._" "no macOS AppleDouble files in the bundle"
env=$(tar xzOf "$tgz" ./release.env)
assert_contains "$env" "EDH_BACKUP_BUCKET=edh-acme-prod-backups-123456789012" "release.env has bucket"
assert_contains "$env" "EDH_ALERT_TOPIC_ARN=arn:aws:sns:ap-southeast-1:123456789012:edh-acme-prod-alerts" "topic when monitoring on"
assert_contains "$env" "EDH_MIGRATE_CMD='npm run m'" "migrate cmd quoted"
assert_contains "$env" "EDH_RELEASE=abc123" "release id"
# deploy.yml's account_id is empty here: the account comes from STS (edh-backup.sh refuses to run without it)
assert_contains "$env" "EDH_ACCOUNT_ID=123456789012" "release.env has the STS-verified account id"
rm -f "$tgz"

# every EDH_* variable a host script reads either comes from release.env or has a default / is a test override
set_vars=$(printf '%s\n' "$env" | sed -n 's/^\(EDH_[A-Z_]*\)=.*/\1/p' | sort -u)
# defaults in edh-lib.sh or the script itself, script-internal names, and test-only overrides
defaulted=" EDH_ENV_FILE EDH_APP_DIR EDH_DATA_DIR EDH_BIN_DIR EDH_DIE_LINE EDH_LOCK_FILE EDH_LOCK_HELD EDH_HEALTH_TRIES"
defaulted="$defaulted EDH_HTTP_PORT EDH_HTTPS_PORT EDH_NO_SYSTEMD EDH_SKIP_PULL EDH_SKIP_PRUNE EDH_M EDH_U EDH_MANIFEST "
defaulted="$defaulted EDH_UPLOADS_BUCKET "   # written into app.env for the app (app_env_defaults), never read
missing=""
for v in $(grep -ho 'EDH_[A-Z_]*' "$SKILL_DIR"/assets/host/edh-*.sh | sort -u); do
  if ! printf '%s\n' "$set_vars" | grep -qx "$v" && [[ "$defaulted" != *" $v "* ]]; then
    missing="$missing $v"
  fi
done
assert_eq "$missing" "" "every EDH_* variable the host scripts read is in release.env (or has a default)"
# the file is sourced by bash on the server: it must parse, and give back exactly the configured values
printf '%s\n' "$env" > "$T/release.env"
vals=$(env -i /bin/bash -c "set -eu; . '$T/release.env'; printf '%s|' \"\$EDH_NAME\" \"\$EDH_SSM_PATH\" \"\$EDH_MIGRATE_CMD\" \"\$EDH_DAILY_HOUR_UTC\"")
assert_eq "$vals" "acme-prod|/acme/prod|npm run m|18|" "release.env sources cleanly in bash"

# monitoring off: no topic; account still set
sed 's/^monitoring: .*/monitoring: none/' deploy/deploy.yml > "$T/nomon.yml"
env=$(bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$T/nomon.yml'; release_env r1" 2>/dev/null)
assert_contains "$env" "EDH_ALERT_TOPIC_ARN=
" "no topic when monitoring is off"
assert_contains "$env" "EDH_ACCOUNT_ID=123456789012" "account id also without monitoring"
# STS failure: no bundle
out=$(STUB_STS_FAIL=1 bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config; make_bundle r2 && echo made" 2>&1)
assert_not_contains "$out" "made" "no bundle without a verified account"
finish
