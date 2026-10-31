# tests/ec2-dedicated-host/test_compose_check.sh — assets/host/edh-compose-check.py on its own: the rules that
# depend on the compose directory's contents, the variable scan fallback, and the server's data directory
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
CHK="$SKILL_DIR/assets/host/edh-compose-check.py"
D="$T/app"; mkdir -p "$D/caddy" "$D/conf"; : > "$D/notes.txt"; : > "$D/compose.yml"
echo '{}' > "$T/novars.json"
# check <services-json> [extra args] — run the check on {"services": <json>}; prints output, then "rc=N"
check() {
  printf '{"services": %s}' "$1" > "$T/cfg.json"; shift
  local o r; o=$(python3 -I "$CHK" "$T/cfg.json" "$D" "$@" 2>&1); r=$?; echo "$o"; echo "rc=$r"
}
bind() { printf '{"%s": {"image": "x", "volumes": [{"type": "bind", "source": "%s", "target": "/x"}]}}' "$1" "$2"; }

assert_contains "$(check "$(bind probe "$D/caddy")" --variables "$T/novars.json")" "rc=0" "a subdirectory next to compose.yml is allowed"
out=$(check "$(bind probe "$D/notes.txt")" --variables "$T/novars.json")
assert_contains "$out" "rc=1" "a top-level file next to compose.yml is refused"
assert_contains "$out" "only subdirectories may be mounted" "a top-level file: explained"
out=$(check "$(bind probe "$D/conf/x.txt")" --variables "$T/novars.json")
assert_contains "$out" "rc=1" "a nested path next to compose.yml is refused (one level only)"
assert_contains "$out" "one level" "a nested path: explained"
# --mount-root: on the server each bind source is checked where it will really be mounted
M="$T/installed"; mkdir -p "$M/extra" "$T/data/uploads" "$T/data/backups" "$T/elsewhere"
ln -s "$T/data/backups" "$T/data/linked"
ln -s "$T/elsewhere" "$M/planted"
out=$(check "$(bind probe "$T/data/linked")" --data-dir "$T/data" --mount-root "$M" --variables "$T/novars.json")
assert_contains "$out" "rc=1" "--mount-root: a symlink at <data>/<dir> is refused"
assert_contains "$out" "symlink" "--mount-root: <data> symlink explained"
out=$(check "$(bind probe "$D/planted")" --mount-root "$M" --variables "$T/novars.json")
assert_contains "$out" "rc=1" "--mount-root: a symlink at <installed app dir>/<dir> is refused"
assert_contains "$out" "$M/planted" "--mount-root: the installed path is named"
assert_contains "$(check "$(bind probe "$D/extra")" --mount-root "$M" --variables "$T/novars.json")" "rc=0" \
  "--mount-root: a real directory passes"
assert_contains "$(check "$(bind probe "$D/newdir")" --mount-root "$M" --variables "$T/novars.json")" "rc=0" \
  "--mount-root: a path that doesn't exist yet passes (Docker creates it)"
: > "$M/afile"
assert_contains "$(check "$(bind probe "$D/afile")" --mount-root "$M" --variables "$T/novars.json")" "not a directory" \
  "--mount-root: an existing file where a directory is mounted is refused"
# the server's data directory comes from --data-dir
out=$(check "$(bind probe "$T/data/backups")" --data-dir "$T/data" --variables "$T/novars.json")
assert_contains "$out" "backup manifest" "--data-dir: <data>/backups refused"
assert_contains "$(check "$(bind caddy "$T/data/caddy")" --data-dir "$T/data" --variables "$T/novars.json")" "rc=0" \
  "--data-dir: <data>/caddy allowed for caddy"
assert_contains "$(check "$(bind postgres "$T/data/postgres")" --data-dir "$T/data" --variables "$T/novars.json")" "rc=0" \
  "--data-dir: <data>/postgres allowed for postgres"
# a symlinked compose directory: both spellings count as inside
ln -s "$D" "$T/link"
printf '{"services": %s}' "$(bind probe "$D/caddy")" > "$T/cfg.json"
out=$(python3 -I "$CHK" "$T/cfg.json" "$T/link" --variables "$T/novars.json" 2>&1); rc=$?
assert_status $rc 0 "a symlinked compose directory: its real path counts as inside"
# variables: from config --variables, or (older Compose) a scan of the file
echo '{"APP_IMAGE": {}, "SECRET_DIR": {}}' > "$T/vars.json"
out=$(check '{}' --variables "$T/vars.json")
assert_contains "$out" 'variable ${SECRET_DIR}' "--variables: a variable outside the allowlist is refused"
assert_not_contains "$out" 'APP_IMAGE}' "--variables: allowed variables pass"
printf 'services:\n  a:\n    image: ${APP_IMAGE}\n    command: echo $$HOME $OTHER_VAR\n' > "$T/raw.yml"
out=$(check '{}' --scan "$T/raw.yml")
assert_contains "$out" 'variable ${OTHER_VAR}' "--scan: an unknown variable is refused"
assert_not_contains "$out" 'variable ${HOME}' "--scan: an escaped \$\$HOME is not a variable"
assert_contains "$(check '{}' 2>&1)" "rc=2" "no variables input: usage error"
finish
