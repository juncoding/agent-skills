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
assert_eq "$(ls -l "$T/data/maint/maintenance.html" | cut -c1-10)" "-rw-r--r--" "page is world-readable (644)"
assert_eq "$(ls -A "$T/data/maint")" "maintenance.html" "render leaves no temp files behind"

bash "$M" render --message "it's {{UNTIL}}" --until noon >/dev/null
page=$(cat "$T/data/maint/maintenance.html")
assert_contains "$page" "it&#39;s {{UNTIL}}" "{{UNTIL}} inside the message stays literal; ' is escaped"
assert_contains "$page" "Expected back: noon" "until still filled"

# --- argument and setup errors
out=$(bash "$M" on --message 2>&1); rc=$?
assert_status "$rc" "1" "--message without a value fails"
assert_contains "$out" "--message needs a value" "--message without a value is explained"
assert_contains "$(bash "$M" on --until 2>&1)" "--until needs a value" "--until without a value is explained"
assert_eq "$(bash "$M" status)" "off" "failed 'on' does not switch maintenance on"

mv "$T/app/maint-templates/maintenance.html" "$T/tpl.bak"
out=$(bash "$M" on 2>&1); rc=$?
assert_status "$rc" "1" "missing template fails"
assert_contains "$out" "template not found" "missing template is explained"
assert_eq "$(bash "$M" status)" "off" "missing template does not switch maintenance on"
mv "$T/tpl.bak" "$T/app/maint-templates/maintenance.html"

out=$(EDH_DATA_DIR="$T/nodata" bash "$M" on 2>&1); rc=$?
assert_status "$rc" "1" "missing maint dir fails"
assert_contains "$out" "$T/nodata/maint" "missing maint dir is named"

out=$(EDH_BIN_DIR="$T/nobin" bash "$M" on 2>&1); rc=$?
assert_eq "$(( rc != 0 ))" "1" "unloadable edh-lib.sh stops edh-maint.sh"
assert_contains "$out" "cannot load edh-lib.sh" "unloadable edh-lib.sh is explained"
assert_eq "$([[ -e "$T/data/maint/ON" ]] && echo yes || echo no)" "no" "unloadable edh-lib.sh does not create ON"

# --- edh-lib.sh: alert/metric never abort under set -u when settings are missing
out=$(EDH_ALERT_TOPIC_ARN=arn:stub bash -c "unset EDH_REGION EDH_CLIENT EDH_ENV
  . '$SKILL_DIR/assets/host/edh-lib.sh'; alert subj msg; metric m 1; echo continued" 2>&1)
assert_contains "$out" "continued" "alert/metric with missing settings do not abort"
assert_contains "$out" "alert not sent" "alert explains why it was not sent"
assert_contains "$out" "metric m not published" "metric explains why it was not published"
assert_eq "$(bash -c ". '$SKILL_DIR/assets/host/edh-lib.sh'; html_escape \"a'b\"")" "a&#39;b" "html_escape escapes single quotes"
finish
