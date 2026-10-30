# tests/ec2-dedicated-host/test_maint_render.sh
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/app/maint-templates" "$T/data/maint"
cp "$SKILL_DIR/assets/project/maint/"*.html "$T/app/maint-templates/"
: > "$T/edh.env"
export EDH_ENV_FILE="$T/edh.env" EDH_APP_DIR="$T/app" EDH_DATA_DIR="$T/data" EDH_BIN_DIR="$SKILL_DIR/assets/host"
M="$SKILL_DIR/assets/host/edh-maint.sh"

bash "$M" on --message 'Upgrade <b>& "fix"' --until '22:00 SGT' >/dev/null
page=$(cat "$T/data/maint/maintenance.html")
assert_contains "$page" 'Upgrade &lt;b&gt;&amp; &quot;fix&quot;' "message is HTML-escaped"
assert_contains "$page" '22:00 SGT' "until is filled"
assert_eq "$(bash "$M" status)" "on" "status on"
bash "$M" off >/dev/null
assert_eq "$(bash "$M" status)" "off" "status off"
bash "$M" render >/dev/null
assert_contains "$(cat "$T/data/maint/maintenance.html")" "scheduled maintenance" "render writes default page"
finish
