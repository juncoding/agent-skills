# tests/ec2-dedicated-host/test_app_env.sh — defaults the server adds to the app's environment (app_env_defaults)
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/edh.env" <<'EOV'
EDH_CLIENT=acme
EDH_ENV=prod
EDH_NAME=acme-prod
EDH_REGION=ap-southeast-1
EDH_ACCOUNT_ID=123456789012
EDH_USES_GOTENBERG=false
EOV
# defaults <app.env lines so far> [VAR=value ...] — what app_env_defaults adds
# (the VAR=value overrides are appended to the env file, which edh-lib.sh sources)
defaults() {
  local lines="$1" kv; shift
  cp "$T/edh.env" "$T/case.env"
  for kv in "$@"; do printf '%s\n' "$kv" >> "$T/case.env"; done
  printf '%s' "$lines" | EDH_ENV_FILE="$T/case.env" EDH_BIN_DIR="$SKILL_DIR/assets/host" \
    /bin/bash -c '. "$EDH_BIN_DIR/edh-lib.sh"; app_env_defaults' 2>&1
}

out=$(defaults $'API_KEY=x\n')
assert_contains "$out" "AWS_REGION=ap-southeast-1" "AWS_REGION from the app region"
assert_contains "$out" "EDH_UPLOADS_BUCKET=edh-acme-prod-uploads-123456789012" "EDH_UPLOADS_BUCKET = edh-<client>-<env>-uploads-<account>"
assert_not_contains "$out" "GOTENBERG_URL" "no GOTENBERG_URL without Gotenberg"
assert_not_contains "$out" "API_KEY" "the app's own lines are not repeated"
out=$(defaults $'API_KEY=x\n' EDH_USES_GOTENBERG=true)
assert_contains "$out" "GOTENBERG_URL=http://gotenberg:3000" "GOTENBERG_URL with Gotenberg"
# a secret of the same name wins: nothing is added for it
out=$(defaults $'AWS_REGION=eu-west-1\nEDH_UPLOADS_BUCKET=my-bucket\nGOTENBERG_URL=http://pdf:3000\n' EDH_USES_GOTENBERG=true)
assert_eq "$out" "" "names the app set through SSM are not overridden"
out=$(defaults $'X=1\nAWS_REGION=eu-west-1\n')
assert_not_contains "$out" "AWS_REGION" "an AWS_REGION secret after other lines is also respected"
assert_contains "$out" "EDH_UPLOADS_BUCKET=" "the other defaults are still added"
# no usable account id: no bucket name rather than a wrong one
out=$(defaults '' EDH_ACCOUNT_ID=)
assert_not_contains "$out" "EDH_UPLOADS_BUCKET=" "no account id: no EDH_UPLOADS_BUCKET"
assert_contains "$out" "AWS_REGION=ap-southeast-1" "no account id: AWS_REGION still added"
# a release (release_flow: tags): APP_VERSION from the tag, unless the app set it itself
out=$(defaults $'X=1\n' EDH_APP_VERSION=v1.2.3)
assert_contains "$out" "APP_VERSION=v1.2.3" "APP_VERSION from the release tag"
out=$(defaults $'X=1\n')
assert_not_contains "$out" "APP_VERSION" "no APP_VERSION outside a release"
out=$(defaults $'APP_VERSION=mine\n' EDH_APP_VERSION=v1.2.3)
assert_not_contains "$out" "APP_VERSION=v1.2.3" "an APP_VERSION secret wins"
finish
