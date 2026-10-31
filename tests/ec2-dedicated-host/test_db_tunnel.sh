# tests/ec2-dedicated-host/test_db_tunnel.sh — db.sh tunnel: SSM port-forward to Postgres, DATABASE_URL for one command
# (stub `aws`, never real AWS; a local python listener stands in for the port-forward session)
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d)
LISTENER=""
cleanup() {
  if [[ -n "$LISTENER" ]]; then kill "$LISTENER" 2>/dev/null; wait "$LISTENER" 2>/dev/null; fi
  pkill -f "$T/listen" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/bin" "$T/plugin"
printf '#!/bin/sh\nexit 0\n' > "$T/plugin/session-manager-plugin"
# listen <port> — accept and drop connections on 127.0.0.1:<port> until killed (its command line names $T/listen,
# so pgrep -f "$T/listen" finds every one)
cat > "$T/listen" <<'EOF'
#!/usr/bin/env python3
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(5)
while True:
    c, _ = s.accept(); c.close()
EOF
# sigdfl <command…> — run it in its own process group with SIGINT at its default (a background job of this script
# would start with SIGINT ignored, and a shell cannot trap a signal ignored on entry), like a command typed at a terminal
cat > "$T/sigdfl" <<'EOF'
#!/usr/bin/env python3
import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.setpgrp()
os.execvp(sys.argv[1], sys.argv[1:])
EOF
# aws wrapper: `ssm start-session` runs the listener on localPortNumber as a child (like the real CLI runs the
# Session Manager plugin) until killed; STUB_SESSION_FAIL=1: the session fails at once. Anything else: the shared stub
cat > "$T/bin/aws" <<EOF
#!/bin/bash
if [[ " \$* " == *" ssm start-session "* ]]; then
  echo "aws \$*" >> "$T/log.session"
  echo "aws \$*" >> "\$STUB_LOG"
  if [[ "\${STUB_SESSION_FAIL:-}" == 1 ]]; then
    echo "An error occurred (TargetNotConnected) when calling the StartSession operation: i-stub is not connected." >&2
    exit 1
  fi
  port=\$(printf '%s' "\$*" | sed -n 's/.*"localPortNumber":\["\([0-9]*\)"\].*/\1/p')
  "$T/listen" "\$port" &
  wait
  exit 0
fi
exec "$TESTS_DIR/stubs/aws" "\$@"
EOF
chmod +x "$T/bin/"* "$T/plugin/"* "$T/listen" "$T/sigdfl"
# the host PATH minus any dir holding a real session-manager-plugin, so "no plugin" means none (other tools
# from such a dir are linked into $T/host)
mkdir -p "$T/host"; HOSTPATH=""
IFS=: read -ra _dirs <<<"$PATH"
for _d in "${_dirs[@]}"; do
  if [[ -x "$_d/session-manager-plugin" ]]; then
    for _f in "$_d"/*; do [[ "${_f##*/}" == session-manager-plugin || -e "$T/host/${_f##*/}" ]] || ln -s "$_f" "$T/host/"; done
  else HOSTPATH="${HOSTPATH:+$HOSTPATH:}$_d"; fi
done
BASEPATH="$T/bin:$TESTS_DIR/stubs:$T/host:$HOSTPATH"
export PATH="$T/plugin:$BASEPATH" STUB_LOG="$T/log" STUB_MODE=existing EDH_SSM_POLL_SECONDS=0 STUB_SSM_OUT=172.18.0.3
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

mkdir "$T/p"; cd "$T/p" || exit 1
bash "$SKILL_DIR/scripts/init.sh" --client acme --domain app.example.com --emails ops@example.com --account-id 123456789012 >/dev/null 2>&1

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
# newport — a free high port in PORT
newport() { while :; do PORT=$((20000 + RANDOM % 20000)); port_open "$PORT" || break; done; }
# port_closed <port> — nothing listens on it within ~2 s
port_closed() { local i; for i in $(seq 1 20); do port_open "$1" || return 0; sleep 0.1; done; return 1; }
# wait_open <port> — until something listens on it (~10 s)
wait_open() { local i; for i in $(seq 1 100); do port_open "$1" && return 0; sleep 0.1; done; return 1; }
listeners() { pgrep -f "$T/listen"; }
run() { : > "$T/log"; : > "$T/log.session"; bash "$SKILL_DIR/scripts/db.sh" "$@" 2>&1; }
sessions() { cat "$T/log" "$T/log.session" 2>/dev/null | grep -c start-session; }
lastop() { tail -n 1 deploy/OPERATIONS.md; }

# ============ with a command: it runs with DATABASE_URL and the libpq variables set
newport
out=$(PGSERVICE=mine run tunnel --port "$PORT" -- sh -c 'echo "URL=$DATABASE_URL"; echo "PG=$PGHOST $PGPORT $PGUSER $PGDATABASE"; echo "PGPASSWORD=$PGPASSWORD"; echo "SVC=[${PGSERVICE-unset}] SSL=$PGSSLMODE"'); rc=$?
assert_status $rc 0 "command: exits 0"
assert_contains "$out" "URL=postgres://app:stub@127.0.0.1:$PORT/app" "command: gets DATABASE_URL (127.0.0.1)"
assert_contains "$out" "PG=127.0.0.1 $PORT app app" "command: gets PGHOST PGPORT PGUSER PGDATABASE"
assert_contains "$out" "PGPASSWORD=stub" "command: gets PGPASSWORD"
assert_contains "$out" "SVC=[unset] SSL=prefer" "command: PGSERVICE unset (libpq 18 reads an empty one as a service name), PGSSLMODE=prefer"

# ============ the port-forward parameters
slog=$(cat "$T/log.session")
assert_contains "$slog" "AWS-StartPortForwardingSessionToRemoteHost" "session: port-forward to a remote host"
assert_contains "$slog" '"host":["172.18.0.3"]' "session: to the Postgres container's IP"
assert_contains "$slog" '"portNumber":["5432"]' "session: to port 5432"
assert_contains "$slog" "\"localPortNumber\":[\"$PORT\"]" "session: from the local port"
assert_contains "$slog" "--target i-" "session: on the server"

# ============ the password never leaks
rest=$(printf '%s\n' "$out" | grep -v -e '^URL=' -e '^PGPASSWORD=')
assert_not_contains "$rest" "stub" "password: not in db.sh's own output"
assert_contains "$(lastop)" "db · ok · tunnel → sh -c" "oplog: command and its first two words"
assert_not_contains "$(lastop)" "stub@" "oplog: no password"

# ============ the tunnel is closed when the command ends (the session's child, too)
if port_closed "$PORT"; then pass "after the command: port closed"; else fail "after the command: port $PORT still open"; fi
assert_eq "$(listeners)" "" "after the command: no tunnel process left"

# ============ oplog: a second word that may be a credential is dropped
newport
out=$(run tunnel --port "$PORT" -- true postgres://u:secret@h/db); rc=$?
assert_contains "$(lastop)" "db · ok · tunnel → true ·" "oplog: a URL as second word is dropped"
assert_not_contains "$(lastop)" "secret" "oplog: no URL credential"
newport
out=$(run tunnel --port "$PORT" -- true PASSWORD=secret); rc=$?
assert_contains "$(lastop)" "db · ok · tunnel → true ·" "oplog: a NAME=value second word is dropped"
assert_not_contains "$(lastop)" "secret" "oplog: no assignment value"

# ============ more than one container network: the first IP
newport
out=$(STUB_SSM_OUT="172.18.0.3 172.19.0.4 " run tunnel --port "$PORT" -- true); rc=$?
assert_status $rc 0 "two networks: works"
assert_contains "$(cat "$T/log.session")" '"host":["172.18.0.3"]' "two networks: the first IP"

# ============ SSM output ends with a blank line (as the real server's does): still the IP
newport
out=$(STUB_SSM_OUT=$'172.18.0.3 \n' run tunnel --port "$PORT" -- true); rc=$?
assert_status $rc 0 "trailing blank line: works"
assert_contains "$(cat "$T/log.session")" '"host":["172.18.0.3"]' "trailing blank line: the IP"

# ============ a failing command: its exit code, logged
newport
out=$(run tunnel --port "$PORT" -- sh -c 'exit 7'); rc=$?
assert_status $rc 7 "failing command: its exit code"
assert_contains "$(lastop)" "db · failed (exit 7)" "failing command: oplog says failed (exit 7)"
if port_closed "$PORT"; then pass "failing command: port closed"; else fail "failing command: port $PORT still open"; fi

# ============ Ctrl-C while the command runs: exit 130, logged as failed
newport
: > "$T/log.session"
"$T/sigdfl" /bin/bash "$SKILL_DIR/scripts/db.sh" tunnel --port "$PORT" -- sleep 30 >"$T/out.int" 2>&1 &
pid=$!
if wait_open "$PORT"; then pass "Ctrl-C (command): tunnel opened"; else fail "Ctrl-C (command): tunnel never opened"; fi
sleep 0.3
kill -INT -- "-$pid" 2>/dev/null
wait "$pid"; rc=$?
assert_status $rc 130 "Ctrl-C (command): exit 130"
assert_contains "$(lastop)" "db · failed (exit 130) · tunnel → sleep 30" "Ctrl-C (command): oplog failed (exit 130)"
if port_closed "$PORT"; then pass "Ctrl-C (command): port closed"; else fail "Ctrl-C (command): port $PORT still open"; fi
assert_eq "$(listeners)" "" "Ctrl-C (command): no tunnel process left"

# ============ Ctrl-C before the tunnel opens (the server lookup is slow): exit 130, logged as failed
newport
: > "$T/log"; : > "$T/log.session"
EDH_SSM_POLL_SECONDS=3 "$T/sigdfl" /bin/bash "$SKILL_DIR/scripts/db.sh" tunnel --port "$PORT" -- true >"$T/out.early" 2>&1 &
pid=$!
sleep 1
kill -INT -- "-$pid" 2>/dev/null
wait "$pid"; rc=$?
assert_status $rc 130 "Ctrl-C (early): exit 130"
assert_contains "$(lastop)" "db · failed (exit 130) · tunnel → true" "Ctrl-C (early): oplog failed (exit 130)"
assert_eq "$(sessions)" "0" "Ctrl-C (early): no session started"

# ============ hold mode (no command): Ctrl-C is the normal way to close, logged ok
newport
"$T/sigdfl" /bin/bash "$SKILL_DIR/scripts/db.sh" tunnel --port "$PORT" >"$T/out.hold" 2>&1 &
pid=$!
if wait_open "$PORT"; then pass "hold: tunnel opened"; else fail "hold: tunnel never opened"; fi
i=0; while ! grep -q "tunnel open" "$T/out.hold" && (( i < 50 )); do sleep 0.1; i=$((i + 1)); done   # now in wait
kill -INT -- "-$pid" 2>/dev/null
wait "$pid"; rc=$?
assert_status $rc 0 "hold: Ctrl-C exits 0"
assert_contains "$(cat "$T/out.hold")" "tunnel open: 127.0.0.1:$PORT" "hold: says where the tunnel is"
assert_contains "$(lastop)" "db · ok · tunnel ·" "hold: oplog ok"
if port_closed "$PORT"; then pass "hold: port closed"; else fail "hold: port $PORT still open"; fi
assert_eq "$(listeners)" "" "hold: no tunnel process left"

# ============ the session dies before the port opens
newport
out=$(STUB_SESSION_FAIL=1 run tunnel --port "$PORT" -- true); rc=$?
assert_status $rc 1 "session fails: exit 1"
assert_contains "$out" "the SSM tunnel did not open" "session fails: explained"
assert_contains "$out" "TargetNotConnected" "session fails: the session's own error"

# ============ the Session Manager plugin is missing
newport
out=$(PATH="$BASEPATH" run tunnel --port "$PORT" -- true); rc=$?
assert_status $rc 1 "no plugin: refused"
assert_contains "$out" "session-manager-plugin" "no plugin: named"
assert_contains "$out" "brew install --cask session-manager-plugin" "no plugin: how to install"
assert_eq "$(sessions)" "0" "no plugin: no session started"

# ============ the wrong AWS account
cp deploy/deploy.yml "$T/deploy.yml.orig"
sed 's/^account_id: .*/account_id: "999999999999"/' "$T/deploy.yml.orig" > deploy/deploy.yml
newport
out=$(run tunnel --port "$PORT" -- true); rc=$?
assert_status $rc 1 "wrong account: refused"
assert_contains "$out" "AWS credentials are for account" "wrong account: explained"
assert_eq "$(sessions)" "0" "wrong account: no session started"
cp "$T/deploy.yml.orig" deploy/deploy.yml

# ============ no Postgres container IP: the server's own error is shown too
newport
out=$(STUB_SSM_OUT=garbage STUB_SSM_ERR="Error: No such object: acme-prod-postgres-1" STUB_SSM_RC=1 run tunnel --port "$PORT" -- true); rc=$?
assert_status $rc 1 "bad container IP: fails"
assert_contains "$out" "could not find the Postgres container" "bad container IP: explained"
assert_contains "$out" "No such object" "bad container IP: the server's error is shown"
assert_eq "$(sessions)" "0" "bad container IP: no session started"

# ============ the password can't be read: no tunnel is opened
newport
out=$(STUB_NO_SECRETS=1 run tunnel --port "$PORT" -- true); rc=$?
assert_status $rc 1 "no password: fails"
assert_contains "$out" "cannot read /acme/prod/_edh/postgres-password" "no password: explained"
assert_eq "$(sessions)" "0" "no password: no session started"

# ============ the local port is taken
newport
"$T/listen" "$PORT" & LISTENER=$!
wait_open "$PORT"
out=$(run tunnel --port "$PORT" -- true); rc=$?
assert_status $rc 1 "port in use: refused"
assert_contains "$out" "port $PORT is already in use" "port in use: explained"
assert_eq "$(sessions)" "0" "port in use: no session started"
kill "$LISTENER" 2>/dev/null; wait "$LISTENER" 2>/dev/null; LISTENER=""

# ============ usage
out=$(run); rc=$?
assert_status $rc 1 "no arguments: usage"
assert_contains "$out" "usage: db.sh tunnel" "no arguments: prints usage"
out=$(run nonsense); rc=$?
assert_status $rc 1 "unknown subcommand: usage"
assert_contains "$out" "usage: db.sh tunnel" "unknown subcommand: prints usage"
out=$(run tunnel --port 80 -- true); rc=$?
assert_status $rc 1 "port below 1024: refused"
finish
