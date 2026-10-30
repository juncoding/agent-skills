# tests/ec2-dedicated-host/test_config.sh
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
TPL="$SKILL_DIR/assets/project/deploy.yml"
cp "$TPL" "$T/deploy.yml"

load() { bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$1'; echo \"\$EDH_NAME|\$EDH_PREFIX|\$EDH_SSM_PATH|\$EDH_ECR_REPO|\$EDH_MONITORING|\$EDH_MIGRATE_CMD\"" 2>&1; }
# loadv <file> <VAR> — print one EDH_* variable after load_config
loadv() { bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$1'; echo \"\${$2}\"" 2>&1; }
# with <key> <value> — template with one key replaced, written to $T/m.yml; prints the path
with() { sed "s/^$1: .*/$1: $2/" "$TPL" > "$T/m.yml"; echo "$T/m.yml"; }
cg() { bash -c ". '$SKILL_DIR/scripts/lib.sh'; cfg_get '$1' '$2' '${3-}'" 2>&1; }

assert_eq "$(load "$T/deploy.yml")" "acme-prod|edh-acme-prod|/acme/prod|edh/acme|cloudwatch|" "derives names from template"

sed -i '' 's/^migrate_cmd: .*/migrate_cmd: "npm run migrate"   # comment/' "$T/deploy.yml"
assert_eq "$(load "$T/deploy.yml")" "acme-prod|edh-acme-prod|/acme/prod|edh/acme|cloudwatch|npm run migrate" "strips quotes and trailing comments"

sed 's/^client: .*/client: Acme_Corp/' "$TPL" > "$T/bad.yml"
assert_contains "$(load "$T/bad.yml")" "client must be" "rejects invalid client"

sed 's/^alert_emails: .*/alert_emails:/' "$TPL" > "$T/bad2.yml"
assert_contains "$(load "$T/bad2.yml")" "alert_emails required" "requires emails with cloudwatch"

sed "s/^migrate_cmd: .*/migrate_cmd: echo 'x'/" "$TPL" > "$T/bad3.yml"
assert_contains "$(load "$T/bad3.yml")" "single quotes" "rejects single quotes in migrate_cmd"

assert_contains "$(load "$T/missing.yml")" "config not found" "missing file is reported"

# --- cfg_get edge cases
printf '%s\n' 'a:    # just a comment' 'b: "unclosed' "c: 'mixed\"" 'd: "x"   # c' > "$T/edge.yml"
printf 'e: plain\r\nf: "q"\r\ng: val   # c\r\n' >> "$T/edge.yml"
assert_eq "$(cg "$T/edge.yml" a)" "" "value starting with # is empty"
assert_eq "$(cg "$T/edge.yml" a dflt)" "dflt" "comment-only value falls back to default"
assert_eq "$(cg "$T/edge.yml" b)" '"unclosed' "unclosed quote kept verbatim"
assert_eq "$(cg "$T/edge.yml" c)" "'mixed\"" "mismatched quotes kept verbatim"
assert_eq "$(cg "$T/edge.yml" d)" "x" "matched quotes stripped"
assert_eq "$(cg "$T/edge.yml" e)" "plain" "CRLF: plain value"
assert_eq "$(cg "$T/edge.yml" f)" "q" "CRLF: quoted value"
assert_eq "$(cg "$T/edge.yml" g)" "val" "CRLF: value with trailing comment"
awk '{ printf "%s\r\n", $0 }' "$TPL" > "$T/crlf.yml"
assert_eq "$(load "$T/crlf.yml")" "acme-prod|edh-acme-prod|/acme/prod|edh/acme|cloudwatch|" "whole template with CRLF line endings"

# --- client
assert_contains "$(load "$(with client acme-)")" "client must be" "rejects trailing dash in client"
assert_contains "$(load "$(with client a--b)")" "client must be" "rejects double dash in client"
assert_contains "$(load "$(with client a)")" "client must be" "rejects 1-char client"
assert_contains "$(load "$(with client abcdefghijklmnopqrstuv)")" "client must be" "rejects 22-char client"
assert_contains "$(load "$(with client my-co2)")" "my-co2-prod|" "accepts dashed client"

# --- instance_type, app_port, app_memory_mb
assert_eq "$(loadv "$(with instance_type t4g.large)" EDH_INSTANCE_TYPE)" "t4g.large" "accepts explicit instance_type"
assert_contains "$(load "$(with instance_type big)")" "instance_type must be" "rejects malformed instance_type"
assert_contains "$(load "$(with app_port 0)")" "app_port must be" "rejects port 0"
assert_contains "$(load "$(with app_port 70000)")" "app_port must be" "rejects port > 65535"
assert_contains "$(load "$(with app_memory_mb 0)")" "app_memory_mb must be" "rejects zero memory"

# --- daily_backup_hour_utc
assert_eq "$(loadv "$(with daily_backup_hour_utc 09)" EDH_DAILY_HOUR_UTC)" "9" "hour 09 normalised to 9"
assert_contains "$(load "$(with daily_backup_hour_utc 24)")" "daily_backup_hour_utc must be" "rejects hour 24"

# --- account_id
assert_eq "$(loadv "$TPL" EDH_ACCOUNT_ID)" "" "account_id empty by default"
assert_eq "$(loadv "$(with account_id 123456789012)" EDH_ACCOUNT_ID)" "123456789012" "reads account_id"
assert_contains "$(load "$(with account_id 12345)")" "account_id must be" "rejects short account_id"
finish
