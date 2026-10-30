# tests/ec2-dedicated-host/test_commands.sh — the local day-2 commands against the stub `aws` (never real AWS)
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/s3"
# fake docker / curl / dig: no image is built, no network is used
printf '#!/bin/sh\necho "docker $*" >> "$STUB_LOG.docker"\ncase "$1" in login) cat >/dev/null ;; esac\nexit 0\n' > "$T/bin/docker"
# curl: like the real one, -w still prints "000 ..." when the request fails
printf '#!/bin/sh\nif [ "${FAKE_CURL_RC:-0}" != 0 ]; then printf "000 in 0.001s"; fi\nexit ${FAKE_CURL_RC:-0}\n' > "$T/bin/curl"
printf '#!/bin/sh\necho 203.0.113.10\n' > "$T/bin/dig"
chmod +x "$T/bin/"*
export PATH="$T/bin:$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/log" STUB_S3="$T/s3" STUB_MODE=existing EDH_SSM_POLL_SECONDS=0
BUCKET="edh-acme-prod-backups-123456789012"

mkdir "$T/p"; cd "$T/p" || exit 1
bash "$SKILL_DIR/scripts/init.sh" --client acme --domain erp.example.com --emails a@example.com --account-id 123456789012 >/dev/null 2>&1
git init -q -b main . && git add -A && git -c user.email=t@example.com -c user.name=t commit -qm init
# env prod deploys only origin/main: a local bare repository stands in for GitHub
git init -q --bare -b main "$T/origin.git" && git remote add origin "$T/origin.git" && git push -q origin main

run() { local s="$1"; shift; bash "$SKILL_DIR/scripts/$s" "$@" 2>&1; }
calls() { grep -c -- "$1" "$T/log" || true; }
line_of() { grep -n -- "$1" "$T/log" | sed -n "${2:-1}p" | cut -d: -f1; }   # line_of <pattern> [nth]
# scripts — every script sent through SSM in this run, decoded, each followed by a "----" line
scripts() {
  grep 'ssm send-command' "$T/log" | sed -n 's/.*echo \([A-Za-z0-9+/=]*\) | base64 -d.*/\1/p' \
    | while read -r b; do printf '%s' "$b" | base64 --decode; printf '\n----\n'; done
}
script_n() { scripts | awk -v n="$1" 'BEGIN { RS = "\n----\n" } NR == n'; }
pos() { local pre="${1%%"$2"*}"; if [[ "$pre" == "$1" ]]; then echo -1; else echo "${#pre}"; fi; }
# in_order <text> <a> <b> ... — each piece occurs, after the one before it
in_order() {
  local text="$1" last=-1 p s; shift
  for s in "$@"; do p=$(pos "$text" "$s"); if (( p <= last )); then echo "out of order or missing: $s"; return; fi; last=$p; done
  echo ok
}

# ============ every mutating command refuses another AWS account before any other AWS call
mkdir "$T/q"; mkdir -p "$T/q/deploy"
sed 's/^account_id: .*/account_id: "111111111111"/' deploy/deploy.yml > "$T/q/deploy/deploy.yml"
cd "$T/q" || exit 1
while IFS= read -r c; do
  : > "$T/log"
  # shellcheck disable=SC2086
  out=$(printf 'value' | STUB_READONLY=1 EDH_YES=1 run $c); rc=$?
  assert_status $rc 1 "wrong account: $c refuses"
  assert_contains "$out" "but deploy.yml says 111111111111" "wrong account: $c explains"
  assert_eq "$(grep -v 'sts get-caller-identity' "$T/log" | grep -c .)" "0" "wrong account: $c makes no AWS call besides sts"
done <<'EOF'
deploy.sh
secrets.sh set db-pass
secrets.sh delete db-pass
maint.sh on
maint.sh off
maint.sh rotate-bypass
rollback.sh
backup.sh now
restore.sh db --latest
restore.sh disk --snapshot snap-0123abcd
monitoring.sh add
monitoring.sh remove
resize.sh instance m7g.large
resize.sh disk 40
upgrade.sh os
teardown.sh
EOF
cd "$T/p" || exit 1

# ============ deploy
: > "$T/log"; : > "$T/log.docker"
out=$(run deploy.sh); rc=$?
sha=$(git rev-parse --short=12 HEAD)
img="123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/edh/acme:$sha"
assert_status $rc 0 "deploy succeeds"
assert_contains "$out" "live: https://erp.example.com ($sha)" "deploy reports the live site"
assert_contains "$(cat "$T/log.docker")" "buildx build --platform linux/arm64 -f Dockerfile -t $img --push ." "deploy builds and pushes arm64"
assert_eq "$(calls 'sts get-caller-identity')" "1" "deploy checks the account once"
b="$T/s3/$BUCKET/_edh/bundles/$sha.tgz"
[[ -f "$b" ]] && pass "bundle uploaded to _edh/bundles/" || fail "bundle not uploaded"
assert_contains "$(tar tzf "$b" 2>/dev/null)" "./host/edh-deploy.sh" "uploaded bundle has the host scripts"
assert_contains "$(tar xzOf "$b" ./release.env 2>/dev/null)" "EDH_ACCOUNT_ID=123456789012" "uploaded bundle has the account id"
assert_contains "$(grep 'put-object' "$T/log")" "--expected-bucket-owner 123456789012" "bundle upload checks the bucket owner"
body=$(grep -o -- '--body [^ ]*' "$T/log" | cut -d' ' -f2)
[[ -n "$body" && ! -e "$body" ]] && pass "local bundle removed" || fail "local bundle left behind: $body"
s=$(script_n 1)
assert_contains "$s" "bash \"\$R/host/edh-deploy.sh\" \"\$R\" $img" "remote runs edh-deploy.sh with the image"
assert_contains "$s" "s3api get-object --bucket $BUCKET --key _edh/bundles/$sha.tgz --expected-bucket-owner 123456789012" \
  "remote fetches the bundle from this account's bucket only"
assert_contains "$s" "--no-same-owner" "remote extracts without the Mac's file owners"
assert_not_contains "$s" "with-decryption" "remote deploy command holds no secrets"
: > "$T/log"
out=$(run deploy.sh --maint); rc=$?
assert_contains "$(script_n 1)" "$img --maint" "--maint is passed to edh-deploy.sh"
for c in "1:previous version is still serving" "2:rolled back to the previous version" "3:no healthy version is running" \
         "3:site may be down" "7:site may be down"; do
  out=$(STUB_SSM_RC=${c%%:*} run deploy.sh); rc=$?
  assert_status $rc 1 "edh-deploy exit ${c%%:*}: deploy fails"
  assert_contains "$out" "${c#*:}" "edh-deploy exit ${c%%:*}: '${c#*:}'"
  assert_not_contains "$out" "live:" "edh-deploy exit ${c%%:*}: not reported live"
done
# compose_with <after-regex> <line>... — deploy/compose.yml with the lines inserted after the first match
# (saved in $T/compose.save first); prints the line number of the first inserted line
compose_with() {
  local re="$1" n; shift
  cp deploy/compose.yml "$T/compose.save"
  n=$(grep -nE -m1 -- "$re" "$T/compose.save" | cut -d: -f1)
  { head -n "$n" "$T/compose.save"; printf '%s\n' "$@"; tail -n +"$((n + 1))" "$T/compose.save"; } > deploy/compose.yml
  echo $((n + 1))
}
VOL='/srv/maint:ro'                    # the last entry of caddy's volumes: list
SVC='^    restart: unless-stopped'     # a key of the first service (caddy)
# compose_refused <after-regex> <expected text> <line>... — deploy refuses, explains, names the line, ships nothing
compose_refused() {
  local re="$1" want="$2" n; shift 2
  n=$(compose_with "$re" "$@")
  : > "$T/log"; : > "$T/log.docker"
  out=$(run deploy.sh --allow-dirty); rc=$?
  assert_status $rc 1 "compose '$*' refused"
  assert_contains "$out" "$want" "compose '$*': explained"
  n=$((n + ${LINE_OFF:-0}))   # LINE_OFF: which inserted line is the offending one
  assert_contains "$out" "line $n:" "compose '$*': names line $n of the file"
  assert_eq "$(grep -c buildx "$T/log.docker")$(calls put-object)" "00" "compose '$*': nothing built or shipped"
  cp "$T/compose.save" deploy/compose.yml
}
# no container may mount the backups directory (the backup manifest) or the whole data directory
for m in '- /data:/hostdata' '- "/data/:/hostdata"' '- ${EDH_DATA_DIR:-/data}:/d' '- ${EDH_DATA_DIR:-/data}/backups:/b:ro' \
         '- /data/backups:/b' '- /data//backups/x:/b'; do
  compose_refused "$VOL" "backup manifest" "      $m"
done
LINE_OFF=1 compose_refused "$VOL" "backup manifest" "      - type: bind" "        source: /data" "        target: /x"
LINE_OFF=1 compose_refused "$VOL" "backup manifest" "      - type: bind" "        source: '\${EDH_DATA_DIR:-/data}'" "        target: /x"
# bind mounts only from ./<dir>, /data/<dir> or ${EDH_DATA_DIR}/<dir>; nothing else that reaches the server
for m in '- /:/host' '- "/:/host:ro"' '- /var/run/docker.sock:/var/run/docker.sock' '- /etc:/hostetc:ro' '- ~/x:/x' \
         '- ${HOME}/x:/x' '- ./:/app' '- .:/app' '- ../secrets:/s' '- ${EDH_DATA_DIR:-/data}/caddy/../backups:/b' '- "..:/up"' \
         '- { type: bind, source: /, target: /host }'; do
  compose_refused "$VOL" "access to the server itself" "      $m"
done
LINE_OFF=1 compose_refused "$VOL" "access to the server itself" "      - type: bind" "        source: /" "        target: /host"
cp deploy/compose.yml "$T/compose.save"
sed 's#^    volumes:$#    volumes: ["/:/host"]#' "$T/compose.save" > "$T/flow.yml"   # flow-style list (first service)
awk 'NR == 1, /^    volumes:/' "$T/flow.yml" | grep -q '"/:/host"' && cp "$T/flow.yml" deploy/compose.yml
out=$(run deploy.sh --allow-dirty); rc=$?
assert_status $rc 1 "compose: a flow-style volumes list is checked too"
cp "$T/compose.save" deploy/compose.yml
for k in 'privileged: true' 'privileged: "true"' 'pid: host' 'ipc: host' 'userns_mode: host' 'network_mode: host' \
         'network_mode: "host"' 'cap_add: [SYS_ADMIN]' 'devices: ["/dev/sda:/dev/sda"]'; do
  compose_refused "$SVC" "access to the server itself" "    $k"
done
compose_refused "$SVC" "access to the server itself" "    cap_add:" "      - NET_ADMIN"
# ordinary settings still pass, and comment lines are ignored
n=$(compose_with "$VOL" '      - "${EDH_DATA_DIR:-/data}/uploads:/uploads"' '      - ./extra:/extra:ro' '      - appdata:/var/lib/x' \
  '      - /tmp/anonymous' '      # - /var/run/docker.sock:/x (a comment)')
cp deploy/compose.yml "$T/c2" && { head -n 12 "$T/c2"; printf '%s\n' '    privileged: false' '    network_mode: bridge' \
  '    command: ["echo", "Loading..."]'; tail -n +13 "$T/c2"; } > deploy/compose.yml
: > "$T/log"
out=$(EDH_YES=1 run deploy.sh --allow-dirty --allow-non-main); rc=$?   # prod + dirty tree: emergency flags
[[ $rc == 0 ]] || printf '%s\n' "$out" | grep -A5 ERROR
assert_status $rc 0 "compose with ordinary settings (data subdirectory, ./dir, named and anonymous volumes, a comment) deploys"
cp "$T/compose.save" deploy/compose.yml
rm -f "$T/c2" "$T/flow.yml"
out=$(run deploy.sh); rc=$?
assert_status $rc 0 "the scaffolded compose.yml passes the lint"
assert_eq "$(git status --porcelain)" "" "compose.yml restored after the mount tests"
touch untracked
out=$(run deploy.sh); rc=$?
assert_status $rc 1 "uncommitted changes: deploy refuses"
assert_contains "$out" "uncommitted changes" "uncommitted changes: explained"
rm -f untracked

# ============ secrets
: > "$T/log"
out=$(printf 'p@ss w0rd$x\n' | run secrets.sh set db-pass); rc=$?
assert_status $rc 0 "secrets set succeeds"
f="$T/log.params/_acme_prod_db-pass"
assert_eq "$(cat "$f" 2>/dev/null)" 'p@ss w0rd$x' "secret value stored as given"
assert_eq "$(wc -c < "$f" 2>/dev/null | tr -d ' ')" "11" "secret value has no trailing newline"
assert_not_contains "$(cat "$T/log")" "w0rd" "secret value never on the command line"
assert_contains "$(grep put-parameter "$T/log")" "--type SecureString --value file://" "secret passed by file, as SecureString"
assert_contains "$(grep put-parameter "$T/log")" "--overwrite" "secret set overwrites"
tmpf=$(grep -o 'file://[^ ]*' "$T/log" | sed 's#file://##')
[[ -n "$tmpf" && ! -e "$tmpf" ]] && pass "secret temp file removed" || fail "secret temp file left: $tmpf"
for v in 'a\nb' 'a\tb' 'a\rb'; do
  : > "$T/log"
  out=$(printf "$v" | run secrets.sh set x); rc=$?
  assert_status $rc 1 "secret with $v refused"
  assert_contains "$out" "newline or tab" "secret with $v: explained"
  assert_eq "$(calls put-parameter)" "0" "secret with $v: nothing stored"
done
out=$(printf '' | run secrets.sh set x); rc=$?
assert_contains "$out" "empty value" "empty secret refused"
for n in _edh/postgres-password ../x Upper; do
  : > "$T/log"
  out=$(printf 'v' | run secrets.sh set "$n"); rc=$?
  assert_status $rc 1 "secret name $n refused (set)"
  out=$(EDH_YES=1 run secrets.sh delete "$n"); rc=$?
  assert_status $rc 1 "secret name $n refused (delete)"
  assert_eq "$(grep -cE 'put-parameter|delete-parameter' "$T/log")" "0" "secret name $n: nothing changed"
done
: > "$T/log"
out=$(EDH_YES=1 run secrets.sh delete db-pass); rc=$?
assert_contains "$(cat "$T/log")" "ssm delete-parameter --name /acme/prod/db-pass" "secrets delete removes the parameter"
out=$(run secrets.sh delete db-pass </dev/null); rc=$?
assert_status $rc 1 "secrets delete without consent aborts"

# ============ maintenance
: > "$T/log"
out=$(run maint.sh on --message "Back soon"); rc=$?
assert_status $rc 0 "maint on succeeds"
assert_contains "$(script_n 1)" "/opt/edh/bin/edh-maint.sh on --message Back\\ soon" "maint on runs edh-maint.sh with the message"
assert_contains "$(grep disable-alarm-actions "$T/log")" "--region us-east-1 cloudwatch disable-alarm-actions --alarm-names edh-acme-prod-site-down" "maint on pauses the site-down alarm"
# the link goes to the terminal when there is one (else stderr), so it doesn't end up in captured output
assert_contains "$(grep get-parameter "$T/log")" "--name /acme/prod/_edh/maint-bypass --with-decryption" "maint on reads the bypass token for the link"
: > "$T/log"
out=$(run maint.sh on --no-link); rc=$?
assert_status $rc 0 "maint on --no-link succeeds"
assert_eq "$(calls 'get-parameter')" "0" "maint on --no-link does not read the bypass token"
assert_not_contains "$out" "maint_bypass=" "maint on --no-link shows no link"
assert_eq "$(script_n 1)" "/opt/edh/bin/edh-maint.sh on " "--no-link is not passed to the server"
# the message reaches the server as one literal argument: no expansion, no extra commands
msg=$'a $(touch '"$T"$'/pwned1) `touch '"$T"$'/pwned2`; touch '"$T"$'/pwned3\nline2 "dq" \'sq\' \\ end'
: > "$T/log"
out=$(run maint.sh on --message "$msg" --no-link); rc=$?
s=$(script_n 1)
lit=$(S="$s" M="$msg" /bin/bash -c 'eval "set -- $S"; if [[ $# == 4 && "$1" == /opt/edh/bin/edh-maint.sh && "$2" == on && "$3" == --message && "$4" == "$M" ]]; then echo literal; fi' 2>&1)
assert_eq "$lit" "literal" "maint message with \$(), backticks, ;, newline and quotes decodes to a literal argv"
assert_eq "$(ls "$T" | grep -c pwned)" "0" "maint message: nothing in it was executed"
: > "$T/log"
out=$(run maint.sh rotate-bypass); rc=$?
assert_status $rc 0 "maint rotate-bypass succeeds"
f="$T/log.params/_acme_prod__edh_maint-bypass"
assert_eq "$([[ "$(cat "$f" 2>/dev/null)" =~ ^[0-9a-f]{40}$ ]] && echo hex40)" "hex40" "rotate-bypass stores a new 40-hex token"
assert_eq "$(wc -c < "$f" 2>/dev/null | tr -d ' ')" "40" "rotate-bypass: no trailing newline"
assert_not_contains "$(cat "$T/log")" "$(cat "$f" 2>/dev/null)" "rotate-bypass: the token is not on the command line"
assert_contains "$(grep put-parameter "$T/log")" "--type SecureString --value file://" "rotate-bypass: passed by file"
assert_contains "$(grep put-parameter "$T/log")" "--overwrite" "rotate-bypass overwrites the old token"
assert_contains "$out" "deploy.sh" "rotate-bypass says to deploy to apply it"
assert_eq "$(calls 'ssm send-command')" "0" "rotate-bypass sends nothing to the server"
: > "$T/log"
out=$(run maint.sh off); rc=$?
assert_contains "$(grep enable-alarm-actions "$T/log")" "edh-acme-prod-site-down" "maint off resumes the site-down alarm"

# ============ rollback
: > "$T/log"
out=$(EDH_YES=1 run rollback.sh); rc=$?
assert_status $rc 0 "rollback succeeds"
assert_contains "$(script_n 1)" "/opt/edh/bin/edh-rollback.sh" "rollback runs edh-rollback.sh"
out=$(EDH_YES=1 STUB_SSM_RC=1 run rollback.sh); rc=$?
assert_status $rc 1 "edh-rollback exit 1: rollback fails"
assert_contains "$out" "previous version is unhealthy" "edh-rollback exit 1: previous version unhealthy"
assert_contains "$out" "stayed on the current version" "edh-rollback exit 1: stayed on current"
out=$(EDH_YES=1 STUB_SSM_RC=3 run rollback.sh); rc=$?
assert_status $rc 1 "edh-rollback exit 3: rollback fails"
assert_contains "$out" "site may be down" "edh-rollback exit 3: site may be down"
: > "$T/log"
out=$(run rollback.sh </dev/null); rc=$?
assert_eq "$(calls 'ssm send-command')" "0" "rollback without consent sends nothing"

# ============ backup
: > "$T/log"
out=$(run backup.sh now); rc=$?
assert_status $rc 0 "backup now succeeds"
assert_contains "$(script_n 1)" "/opt/edh/bin/edh-backup.sh --tag manual --force" "backup now runs a manual backup"
printf 'db/hourly/app-20261030T010000Z.dump\t2026-10-30T01:00:05+00:00\t10\ndb/daily/app-20261029T180000Z.dump\t2026-10-29T18:00:09+00:00\t9\n' > "$T/list.tsv"
: > "$T/log"
out=$(STUB_S3_LIST="$T/list.tsv" run backup.sh list); rc=$?
assert_status $rc 0 "backup list succeeds"
assert_contains "$out" "db/hourly/app-20261030T010000Z.dump" "backup list shows the backups"
assert_contains "$(grep list-objects-v2 "$T/log")" "--expected-bucket-owner 123456789012" "backup list reads only this account's bucket"
out=$(run backup.sh list); rc=$?
assert_status $rc 0 "backup list of an empty bucket succeeds"

# ============ restore db: backups are chosen by S3 upload time (LastModified), never by the name's timestamp —
# the host role (and an app container using it) can upload any key under db/, e.g. app-29991231T000000Z.dump
# rows: A genuine, named 23:30 on day X but uploaded 00:30 on day X+1 · B genuine, the newest · C future-named
# · D named 10 h before its upload · E not a dump
read -r KEY_A KEY_B KEY_C KEY_D DATE_X DATE_X1 < <(python3 -I - "$T/objects" <<'PY'
import datetime as dt, sys
u = dt.timezone.utc; now = dt.datetime.now(u).replace(microsecond=0); h = dt.timedelta(hours=1); m = dt.timedelta(minutes=1)
x = (now - 72 * h).replace(hour=23, minute=30, second=0)
name = lambda folder, t: "db/%s/app-%s.dump" % (folder, t.strftime("%Y%m%dT%H%M%SZ"))
iso = lambda t: t.strftime("%Y-%m-%dT%H:%M:%S+00:00")
a, b = name("daily", x), name("hourly", now - 2 * h)
c, d = name("daily", dt.datetime(2999, 12, 31, tzinfo=u)), name("hourly", now - 10 * h)
rows = [(a, x + h, 2000), (b, now - 2 * h + m, 3000), (c, now - 10 * m, 9), (d, now - 5 * m, 9), ("db/daily/notes.txt", now, 1)]
open(sys.argv[1], "w").write("".join("%s\t%s\t%d\n" % (k, iso(t), n) for k, t, n in rows))
print(a, b, c, d, x.strftime("%Y-%m-%d"), (x + h).strftime("%Y-%m-%d"))
PY
)
# --latest / --date: the server picks from its own backup manifest (edh-restore.sh pick); the bucket is not listed
: > "$T/log"
out=$(STUB_SSM_OUT="db/hourly/app-20261030T010000Z.dump	2026-10-30T01:00:05Z" run restore.sh db --latest --check); rc=$?
assert_status $rc 0 "restore --latest --check succeeds"
assert_eq "$(script_n 1)" "/opt/edh/bin/edh-restore.sh pick" "restore --latest asks the server's manifest"
assert_eq "$(script_n 2)" "/opt/edh/bin/edh-restore.sh check db/hourly/app-20261030T010000Z.dump --keep" "restore --latest restores the manifest's newest"
assert_contains "$out" "backup db/hourly/app-20261030T010000Z.dump — uploaded 2026-10-30T01:00:05Z" "restore prints the chosen key and its upload time"
assert_eq "$(calls list-objects-v2)" "0" "restore --latest does not list the bucket"
: > "$T/log"
out=$(EDH_YES=1 STUB_SSM_OUT="db/daily/app-20261029T180000Z.dump	2026-10-29T18:00:09Z" run restore.sh db --date 2026-10-29); rc=$?
assert_eq "$(script_n 1)" "/opt/edh/bin/edh-restore.sh pick 20261029" "restore --date asks the manifest for that day"
assert_eq "$(script_n 2)" "/opt/edh/bin/edh-restore.sh replace db/daily/app-20261029T180000Z.dump --yes" "restore --date replaces with that day's backup"
: > "$T/log"
out=$(STUB_SSM_OUT="" run restore.sh db --date 2026-01-01 --check); rc=$?
assert_status $rc 1 "restore --date without a backup that day fails"
assert_contains "$out" "no matching backup found" "restore --date without a backup that day: explained"
assert_eq "$(calls 'ssm send-command')" "1" "restore --date without a match: nothing restored"
: > "$T/log"
out=$(STUB_SSM_OUT="db/daily/x; reboot	2026-10-29T18:00:09Z" run restore.sh db --latest --check); rc=$?
assert_status $rc 1 "a malformed key from the server is refused"
assert_eq "$(calls 'ssm send-command')" "1" "a malformed key from the server: nothing restored"
# --key: the server verifies it against its manifest; nothing is listed here
: > "$T/log"
out=$(run restore.sh db --key "$KEY_C" --check); rc=$?
assert_eq "$(script_n 1)" "/opt/edh/bin/edh-restore.sh check $KEY_C --keep" "restore --key goes to the server, which verifies it"
assert_eq "$(calls list-objects-v2)" "0" "restore --key does not list the bucket"
: > "$T/log"
out=$(EDH_YES=1 run restore.sh db --key 'db/daily/app-20261029T180000Z.dump; reboot'); rc=$?
assert_status $rc 1 "restore --key with shell syntax refused"
assert_eq "$(calls 'ssm send-command')" "0" "restore --key with shell syntax: nothing sent"
out=$(EDH_YES=1 STUB_SSM_RC=1 run restore.sh db --key "$KEY_A"); rc=$?
assert_status $rc 1 "edh-restore failure: restore fails"
assert_contains "$out" "failed" "edh-restore failure: explained"

# --unverified needs --key: an unverified backup is never chosen automatically (no --latest / --date)
export STUB_S3_LIST="$T/objects"
for sel in "--latest" "--date $DATE_X1"; do
  : > "$T/log"
  # shellcheck disable=SC2086
  out=$(EDH_YES=1 run restore.sh db $sel --check --unverified); rc=$?
  assert_status $rc 1 "--unverified with $sel refused"
  assert_contains "$out" "--unverified needs --key" "--unverified with $sel: explained"
  assert_eq "$(grep -v 'sts get-caller-identity' "$T/log" | grep -cE 'send-command|list-objects-v2')" "0" "--unverified with $sel: nothing listed or sent"
done
# --unverified --key: the named key is still checked against its S3 upload time
: > "$T/log"
out=$(run restore.sh db --key "$KEY_B" --check --unverified); rc=$?
assert_status $rc 0 "restore --key --unverified succeeds"
assert_eq "$(script_n 1)" "/opt/edh/bin/edh-restore.sh check $KEY_B --keep --unverified" "--unverified --key: that key, flag passed through"
assert_contains "$out" "backup $KEY_B" "--unverified: prints the chosen key"
assert_contains "$out" "3000 bytes" "--unverified: prints the chosen dump's size"
assert_contains "$out" "NOT verified" "--unverified: says it is not verified"
assert_contains "$(grep list-objects-v2 "$T/log")" "--expected-bucket-owner 123456789012" "--unverified lists only this account's bucket"
: > "$T/log"
out=$(EDH_YES=1 run restore.sh db --key "$KEY_B" --unverified); rc=$?
assert_eq "$(script_n 1)" "/opt/edh/bin/edh-restore.sh replace $KEY_B --yes --unverified" "--unverified passed through (replace)"
assert_contains "$out" "--unverified" "--unverified is warned about before the confirmation"
for k in "$KEY_C:its name is dated in the future" "$KEY_D:its name says"; do
  : > "$T/log"
  out=$(EDH_YES=1 run restore.sh db --key "${k%%:*}" --unverified); rc=$?
  assert_status $rc 1 "--unverified --key ${k%%:*} refused"
  assert_contains "$out" "skipping ${k%%:*}: ${k#*:}" "--unverified --key ${k%%:*}: explained"
  assert_eq "$(calls 'ssm send-command')" "0" "--unverified --key ${k%%:*}: nothing sent"
done
: > "$T/log"
out=$(run restore.sh db --key "db/daily/app-20200101T000000Z.dump" --check --unverified); rc=$?
assert_status $rc 1 "--unverified --key of a key not in the bucket refused"
assert_contains "$out" "not found" "--unverified --key not in the bucket: explained"
# python3 must really run (on a Mac without the Command Line Tools, python3 is only a stub)
mkdir -p "$T/nopy"; printf '#!/bin/sh\necho "xcode-select: note: no developer tools were found" >&2\nexit 1\n' > "$T/nopy/python3"; chmod +x "$T/nopy/python3"
: > "$T/log"
out=$(PATH="$T/nopy:$PATH" run restore.sh db --key "$KEY_A" --check --unverified); rc=$?
assert_status $rc 1 "--unverified without a working python3 fails"
assert_contains "$out" "python3" "--unverified without a working python3: explained"
assert_eq "$(calls 'ssm send-command')" "0" "--unverified without a working python3: nothing sent"
unset STUB_S3_LIST

# ============ restore disk: only this client's snapshots; lock, timers, app, docker (RequiresMountsFor=/data)
# stopped → umount → swap → mount → start
: > "$T/log"
out=$(EDH_YES=1 STUB_VOL_ATTACHED=i-stub run restore.sh disk --snapshot snap-0123abcd); rc=$?
assert_status $rc 0 "restore disk succeeds"
assert_eq "$(in_order "$(script_n 1)" "systemctl stop edh-backup.timer edh-drill.timer" "edh_lock" "docker compose down" \
  "systemctl stop docker.socket docker" "umount /data")" ok "restore disk: timers, the edh lock, compose down, docker, then umount"
assert_eq "$(in_order "$(script_n 2)" "mount -a || true" "mountpoint -q /data || { echo '/data not mounted'; exit 1; }" \
  "systemctl start docker" "docker compose up -d" "systemctl start edh-backup.timer edh-drill.timer" "wait_health")" ok \
  "restore disk: mount (checked), docker, compose up, timers, health check"
s1=$(line_of 'ssm send-command' 1); s2=$(line_of 'ssm send-command' 2)
d=$(line_of 'detach-volume --volume-id vol-stub'); a=$(line_of 'attach-volume')
assert_eq "$(( s1 < d && d < a && a < s2 ))" "1" "restore disk: volumes are swapped between unmount and mount"
assert_contains "$(cat "$T/log")" "describe-snapshots --snapshot-ids snap-0123abcd" "restore disk: the snapshot's tags are checked"
assert_contains "$(grep create-volume "$T/log")" "--snapshot-id snap-0123abcd" "restore disk: new volume from the snapshot"
assert_contains "$(grep create-volume "$T/log")" "{Key=edh:role,Value=data-restoring},{Key=Protect,Value=true}" \
  "restore disk: new volume is protected and not yet tagged as the data volume"
assert_contains "$(cat "$T/log")" "create-tags --resources vol-stub --tags Key=edh:role,Value=data-replaced-" "restore disk: old volume re-tagged"
assert_contains "$(cat "$T/log")" "create-tags --resources vol-new --tags Key=edh:role,Value=data Key=edh:snapshot,Value=acme-prod" \
  "restore disk: new volume becomes the data volume"
assert_eq "$(calls delete-volume)" "0" "restore disk never deletes a volume"
for tags in "other	prod" "acme	staging" "None	None"; do
  : > "$T/log"
  out=$(EDH_YES=1 STUB_VOL_ATTACHED=i-stub STUB_SNAP_TAGS="$tags" run restore.sh disk --snapshot snap-0123abcd); rc=$?
  assert_status $rc 1 "restore disk: snapshot tagged '$tags' refused"
  assert_contains "$out" "--foreign-snapshot" "restore disk: snapshot tagged '$tags': explained"
  assert_eq "$(calls create-volume)" "0" "restore disk: snapshot tagged '$tags': nothing created"
done
: > "$T/log"
out=$(EDH_YES=1 STUB_VOL_ATTACHED=i-stub STUB_SNAP_TAGS="other	prod" run restore.sh disk --snapshot snap-0123abcd --foreign-snapshot); rc=$?
assert_status $rc 0 "restore disk --foreign-snapshot uses another client's snapshot"
assert_contains "$out" "not tagged as $(printf 'acme-prod')" "restore disk --foreign-snapshot: warned"
: > "$T/log"
out=$(STUB_VOL_ATTACHED=i-stub STUB_SNAP_TAGS="other	prod" run restore.sh disk --snapshot snap-0123abcd --foreign-snapshot </dev/null); rc=$?
assert_eq "$(calls create-volume)" "0" "restore disk --foreign-snapshot still needs consent"
: > "$T/log"
out=$(EDH_YES=1 run restore.sh disk --snapshot snap-0123abcd); rc=$?
assert_status $rc 1 "restore disk: data volume not attached to the server: refuses"
assert_eq "$(calls create-volume)" "0" "restore disk: not attached: nothing created"
: > "$T/log"
out=$(EDH_YES=1 STUB_VOL_ATTACHED=i-stub STUB_SSM_RC=1 run restore.sh disk --snapshot snap-0123abcd); rc=$?
assert_status $rc 1 "restore disk: unmount fails: stops"
assert_contains "$out" "nothing was swapped" "restore disk: unmount fails: explained"
assert_eq "$(calls detach-volume)" "0" "restore disk: unmount fails: old volume stays attached"
assert_contains "$(script_n 2)" "systemctl start docker" "restore disk: unmount fails: the app is started again"
# a failure after the unmount prints both volumes and how to put the old one back
: > "$T/log"
out=$(EDH_YES=1 STUB_VOL_ATTACHED=i-stub STUB_ATTACH_FAIL=1 run restore.sh disk --snapshot snap-0123abcd); rc=$?
assert_eq "$(( rc != 0 ))" "1" "restore disk: attach fails: stops"
assert_contains "$(cat "$T/log")" "describe-volumes --volume-ids vol-stub vol-new" "restore disk: attach fails: both volumes' state shown"
assert_contains "$out" "old data volume: vol-stub" "restore disk: attach fails: names the old volume"
assert_contains "$out" "new volume:      vol-new" "restore disk: attach fails: names the new volume"
assert_contains "$out" "aws --region ap-southeast-1 ec2 attach-volume --volume-id vol-stub --instance-id i-stub --device /dev/sdf" \
  "restore disk: attach fails: the command to re-attach the old volume"
assert_contains "$out" "aws --region ap-southeast-1 ec2 create-tags --resources vol-stub --tags Key=edh:role,Value=data Key=edh:snapshot,Value=acme-prod" \
  "restore disk: attach fails: the command to re-tag the old volume"
assert_contains "$out" "sudo mount -a && sudo systemctl start docker" "restore disk: attach fails: how to bring the app back"
# the swap completed but the app fails /health: no misleading "stopped half way" guidance
: > "$T/log"; rm -f "$T/log.rcn"
out=$(EDH_YES=1 STUB_VOL_ATTACHED=i-stub STUB_SSM_RCS="0 4" run restore.sh disk --snapshot snap-0123abcd); rc=$?
assert_status $rc 1 "restore disk: unhealthy after the swap: fails"
assert_contains "$out" "swap completed" "restore disk: unhealthy after the swap: says the swap completed"
assert_contains "$out" "app is unhealthy" "restore disk: unhealthy after the swap: says the app is unhealthy"
assert_not_contains "$out" "stopped half way" "restore disk: unhealthy after the swap: no half-way recovery guidance"
assert_not_contains "$out" "To put the old volume back" "restore disk: unhealthy after the swap: no put-back commands"
assert_contains "$(script_n 2)" "exit 4" "restore disk: the health check failure has its own exit code"
# anything else failing on the way back up still prints the recovery guidance
: > "$T/log"; rm -f "$T/log.rcn"
out=$(EDH_YES=1 STUB_VOL_ATTACHED=i-stub STUB_SSM_RCS="0 1" run restore.sh disk --snapshot snap-0123abcd); rc=$?
assert_status $rc 1 "restore disk: /data not mounted after the swap: fails"
assert_contains "$out" "stopped half way" "restore disk: /data not mounted after the swap: recovery guidance"
rm -f "$T/log.rcn"

# ============ resize
: > "$T/log"
out=$(STUB_ARCH=x86_64 STUB_READONLY=1 EDH_YES=1 run resize.sh instance c7i.large); rc=$?
assert_status $rc 1 "resize to a non-arm64 type refused"
assert_contains "$out" "does not support arm64" "resize to a non-arm64 type: explained"
assert_eq "$(grep -c 'STUB_READONLY refused' "$T/log")" "0" "resize to a non-arm64 type: nothing changed"
out=$(STUB_READONLY=1 EDH_YES=1 run resize.sh instance t4g.medium); rc=$?
assert_contains "$out" "already t4g.medium" "resize to the current type refused"
: > "$T/log"
out=$(EDH_YES=1 run resize.sh instance m7g.large); rc=$?
assert_status $rc 0 "resize instance succeeds"
assert_eq "$(( $(line_of stop-instances) < $(line_of 'modify-instance-attribute') && $(line_of 'modify-instance-attribute') < $(line_of start-instances) ))" "1" \
  "resize: stop, change type, start"
assert_contains "$(grep modify-instance-attribute "$T/log")" "--instance-type Value=m7g.large" "resize sets the new type"
assert_contains "$(scripts)" "docker compose up -d && wait_health 60" "resize brings the app up and checks health"
assert_contains "$(cat "$T/log")" "put-metric-alarm" "resize re-runs monitoring.sh add (monitoring: cloudwatch)"
: > "$T/log"
out=$(STUB_OFFERED_AZS="ap-southeast-1b	ap-southeast-1c" EDH_YES=1 run resize.sh instance m7g.large); rc=$?
assert_status $rc 1 "resize to a type not offered in the server's AZ refused"
assert_contains "$out" "m7g.large is not offered in ap-southeast-1a" "resize to a type not offered in the AZ: explained"
assert_eq "$(calls stop-instances)" "0" "resize to a type not offered in the AZ: the server is not stopped"
assert_contains "$(grep describe-instance-type-offerings "$T/log")" "Name=instance-type,Values=m7g.large Name=location,Values=ap-southeast-1a" \
  "resize checks the offering in the server's AZ"
# the new type does not start: back to the old type, started again
: > "$T/log"; rm -f "$T/log.starts"
out=$(STUB_START_FAIL=1 EDH_YES=1 run resize.sh instance m7g.large); rc=$?
assert_status $rc 1 "resize: the new type does not start: fails"
assert_contains "$out" "back on t4g.medium" "resize: the new type does not start: explained"
assert_eq "$(grep modify-instance-attribute "$T/log" | sed -n 's/.*--instance-type Value=\([^ ]*\).*/\1/p' | tr '\n' ' ')" "m7g.large t4g.medium " \
  "resize: the new type does not start: the old type is set back"
assert_eq "$(calls start-instances)" "2" "resize: the new type does not start: started again on the old type"
assert_eq "$(( $(line_of 'wait instance-stopped' 2) > $(line_of start-instances 1) && $(line_of 'wait instance-stopped' 2) < $(line_of modify-instance-attribute 2) ))" "1" \
  "resize: the new type does not start: waits for the server to be stopped before setting the old type back"
assert_eq "$(calls 'ssm send-command')" "0" "resize: the new type does not start: no health check on a half-done resize"
sed 's/^monitoring: .*/monitoring: none/' deploy/deploy.yml > "$T/nomon.yml"; cp deploy/deploy.yml "$T/mon.yml"; cp "$T/nomon.yml" deploy/deploy.yml
: > "$T/log"
out=$(EDH_YES=1 run resize.sh instance m7g.large); rc=$?
assert_eq "$(calls put-metric-alarm)" "0" "resize without monitoring: no alarms touched"
cp "$T/mon.yml" deploy/deploy.yml
: > "$T/log"
out=$(STUB_VOL_SIZE=20 STUB_READONLY=1 EDH_YES=1 run resize.sh disk 10); rc=$?
assert_status $rc 1 "resize disk smaller refused"
assert_contains "$out" "must be larger than the current 20 GB" "resize disk smaller: explained"
: > "$T/log"
out=$(STUB_VOL_SIZE=20 EDH_YES=1 run resize.sh disk 40); rc=$?
assert_status $rc 0 "resize disk succeeds"
assert_contains "$(cat "$T/log")" "modify-volume --volume-id vol-stub --size 40" "resize disk grows the volume"
assert_contains "$(script_n 1)" "resize2fs /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_volstub" "resize disk grows the filesystem"

# ============ upgrade: safety snapshot before any package changes; health check after
: > "$T/log"
out=$(EDH_YES=1 STUB_SSM_OUT=NO-REBOOT run upgrade.sh os); rc=$?
assert_status $rc 0 "upgrade os succeeds"
assert_eq "$(( $(line_of 'create-snapshot --volume-id vol-stub') < $(line_of 'ssm send-command') ))" "1" "upgrade: safety snapshot first"
assert_contains "$(script_n 1)" "apt-get -o DPkg::Lock::Timeout=600" "upgrade waits for the dpkg lock"
assert_contains "$(script_n 1)" "--with-new-pkgs upgrade" "upgrade installs new dependencies (--with-new-pkgs)"
assert_contains "$(script_n 2)" "wait_health" "upgrade without a reboot: health check"
assert_contains "$out" "kept until you delete it" "upgrade says the snapshot is kept"
: > "$T/log"
out=$(EDH_YES=1 STUB_SSM_OUT=REBOOT-NEEDED run upgrade.sh os); rc=$?
assert_contains "$out" "a reboot is needed" "upgrade: a needed reboot is reported"
assert_not_contains "$(scripts)" "systemctl reboot" "upgrade without --reboot never reboots"
: > "$T/log"; rm -f "$T/log.pingn"
# the reboot is detected by a ping newer than the one recorded just before it — never by the Mac's clock: these
# pings are from the year 2000, so comparing them with the Mac's clock would never see the server back
printf 'Online\t2000-01-01T00:00:00.000000+00:00\nOnline\t2000-01-01T00:00:00.000000+00:00\nOnline\t2000-01-01T00:06:00.000000+00:00\n' > "$T/pings"
out=$(EDH_YES=1 STUB_SSM_OUT=REBOOT-NEEDED EDH_REBOOT_POLL_SECONDS=0 STUB_PINGS="$T/pings" run upgrade.sh os --reboot); rc=$?
assert_status $rc 0 "upgrade --reboot succeeds"
assert_eq "$(in_order "$(scripts)" "systemctl reboot" "wait_health")" ok "upgrade --reboot: reboot, then health check"
assert_contains "$(grep describe-instance-information "$T/log")" "LastPingDateTime" "upgrade --reboot waits for a fresh SSM ping"
assert_eq "$(( $(line_of describe-instance-information 1) < $(line_of 'ssm send-command' 2) ))" "1" \
  "upgrade --reboot: the last ping is recorded before the reboot command"
assert_eq "$(cat "$T/log.pingn")" "3" "upgrade --reboot: back on the first newer ping"
assert_contains "$out" "rebooted and healthy" "upgrade --reboot: reported"
# a quick reboot that is seen offline, then Online with an unchanged ping, also counts
: > "$T/log"; rm -f "$T/log.pingn"
printf 'Online\t2026-10-30T10:00:00.123+00:00\nConnectionLost\t2026-10-30T10:00:00.123+00:00\nOnline\t2026-10-30T10:00:00.123+00:00\n' > "$T/pings"
out=$(EDH_YES=1 STUB_SSM_OUT=REBOOT-NEEDED EDH_REBOOT_POLL_SECONDS=0 STUB_PINGS="$T/pings" run upgrade.sh os --reboot); rc=$?
assert_status $rc 0 "upgrade --reboot: offline then Online counts as back"
# the ping never moves on and the server never goes offline: not back
: > "$T/log"; rm -f "$T/log.pingn"
out=$(EDH_YES=1 STUB_SSM_OUT=REBOOT-NEEDED EDH_REBOOT_POLL_SECONDS=0 STUB_PING="Online	2099-01-01T00:00:00.000000+00:00" \
  run upgrade.sh os --reboot); rc=$?
assert_status $rc 1 "upgrade --reboot: a ping no newer than before the reboot never counts as back"
assert_contains "$out" "did not come back" "upgrade --reboot: not back: explained"
assert_not_contains "$(scripts)" "wait_health" "upgrade --reboot: not back: no health check sent"
rm -f "$T/log.pingn"
: > "$T/log"
out=$(run upgrade.sh os </dev/null); rc=$?
assert_eq "$(grep -cE 'create-snapshot|send-command' "$T/log")" "0" "upgrade without consent changes nothing"

# ============ status (read-only)
: > "$T/log"
out=$(FAKE_CURL_RC=7 run status.sh); rc=$?
assert_contains "$out" "site:    https://erp.example.com/health → unreachable" "status: an unreachable site is just 'unreachable'"
assert_not_contains "$out" "000 in" "status: no curl noise for an unreachable site"
: > "$T/log"
out=$(run status.sh); rc=$?
assert_status $rc 0 "status succeeds"
assert_contains "$out" "server:  i-stub" "status shows the server"
assert_contains "$(script_n 1)" "/opt/edh/bin/edh-status.sh" "status runs edh-status.sh"
assert_not_contains "$(cat "$T/log")" "alarm-name-prefix" "status asks for exact alarm names (a prefix also matches other clients)"
assert_contains "$(cat "$T/log")" "--alarm-names edh-acme-prod-disk-root-warn" "status asks for this client's alarms"
finish
