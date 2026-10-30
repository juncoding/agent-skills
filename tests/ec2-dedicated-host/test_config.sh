# tests/ec2-dedicated-host/test_config.sh
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp "$SKILL_DIR/assets/project/deploy.yml" "$T/deploy.yml"

load() { bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$1'; echo \"\$EDH_NAME|\$EDH_PREFIX|\$EDH_SSM_PATH|\$EDH_ECR_REPO|\$EDH_MONITORING|\$EDH_MIGRATE_CMD\"" 2>&1; }

assert_eq "$(load "$T/deploy.yml")" "acme-prod|edh-acme-prod|/acme/prod|edh/acme|cloudwatch|" "derives names from template"

sed -i '' 's/^migrate_cmd: .*/migrate_cmd: "npm run migrate"   # comment/' "$T/deploy.yml"
assert_contains "$(load "$T/deploy.yml")" "|npm run migrate" "strips quotes and trailing comments"

sed 's/^client: .*/client: Acme_Corp/' "$SKILL_DIR/assets/project/deploy.yml" > "$T/bad.yml"
assert_contains "$(load "$T/bad.yml")" "client must be" "rejects invalid client"

sed 's/^alert_emails: .*/alert_emails:/' "$SKILL_DIR/assets/project/deploy.yml" > "$T/bad2.yml"
assert_contains "$(load "$T/bad2.yml")" "alert_emails required" "requires emails with cloudwatch"

sed "s/^migrate_cmd: .*/migrate_cmd: echo 'x'/" "$SKILL_DIR/assets/project/deploy.yml" > "$T/bad3.yml"
assert_contains "$(load "$T/bad3.yml")" "single quotes" "rejects single quotes in migrate_cmd"

assert_contains "$(load "$T/missing.yml")" "config not found" "missing file is reported"
finish
