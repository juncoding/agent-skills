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
# listen <port> — accept and drop connections on 127.0.0.1:<port> until killed
cat > "$T/listen" <<'EOF'
#!/bin/sh
exec python3 -I -c 'import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(5)
while True: c,_=s.accept(); c.close()' "$1"
EOF
# aws wrapper: `ssm start-session` listens on localPortNumber until killed; anything else goes to the shared stub
cat > "$T/bin/aws" <<EOF
#!/bin/bash
if [[ " \$* " == *" ssm start-session "* ]]; then
  echo "aws \$*" >> "$T/log.session"
  echo "aws \$*" >> "\$STUB_LOG"
  port=\$(printf '%s' "\$*" | sed -n 's/.*"localPortNumber":\["\([0-9]*\)"\].*/\1/p')
  exec "$T/listen" "\$port"
fi
exec "$TESTS_DIR/stubs/aws" "\$@"
EOF
chmod +x "$T/bin/"* "$T/plugin/"* "$T/listen"
BASEPATH="$T/bin:$TESTS_DIR/stubs:$PATH"
export PATH="$T/plugin:$BASEPATH" STUB_LOG="$T/log" STUB_MODE=existing EDH_SSM_POLL_SECONDS=0 STUB_SSM_OUT=172.18.0.3
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

mkdir "$T/p"; cd "$T/p" || exit 1
bash "$SKILL_DIR/scripts/init.sh" --client acme --domain app.example.com --emails ops@example.com --account-id 123456789012 >/dev/null 2>&1

newport() { PORT=$((20000 + RANDOM % 20000)); }
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
run() { : > "$T/log"; : > "$T/log.session"; bash "$SKILL_DIR/scripts/db.sh" "$@" 2>&1; }
sessions() { cat "$T/log" "$T/log.session" 2>/dev/null | grep -c start-session; }
lastop() { tail -n 1 deploy/OPERATIONS.md; }

# ============ with a command: it runs with DATABASE_URL set
newport
out=$(run tunnel --port "$PORT" -- sh -c 'echo "URL=$DATABASE_URL"'); rc=$?
assert_status $rc 0 "command: exits 0"
assert_contains "$out" "URL=postgres://app:stub@localhost:$PORT/app" "command: gets DATABASE_URL"

# ============ the port-forward parameters
slog=$(cat "$T/log.session")
assert_contains "$slog" "AWS-StartPortForwardingSessionToRemoteHost" "session: port-forward to a remote host"
assert_contains "$slog" '"host":["172.18.0.3"]' "session: to the Postgres container's IP"
assert_contains "$slog" '"portNumber":["5432"]' "session: to port 5432"
assert_contains "$slog" "\"localPortNumber\":[\"$PORT\"]" "session: from the local port"
assert_contains "$slog" "--target i-" "session: on the server"

# ============ the password never leaks
rest=$(printf '%s\n' "$out" | grep -v '^URL=')
assert_not_contains "$rest" "app:stub@" "password: not in db.sh's own output"
assert_contains "$(lastop)" "db · ok · tunnel → sh -c" "oplog: command and its first two words"
assert_not_contains "$(lastop)" "stub@" "oplog: no password"

# ============ the tunnel is closed when the command ends
if port_open "$PORT"; then fail "after the command: port $PORT still open"; else pass "after the command: port closed"; fi
assert_eq "$(pgrep -f "$PORT")" "" "after the command: no tunnel process left"

# ============ a failing command: its exit code, logged
newport
out=$(run tunnel --port "$PORT" -- sh -c 'exit 7'); rc=$?
assert_status $rc 7 "failing command: its exit code"
assert_contains "$(lastop)" "db · failed (exit 7)" "failing command: oplog says failed (exit 7)"
if port_open "$PORT"; then fail "failing command: port $PORT still open"; else pass "failing command: port closed"; fi

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

# ============ no Postgres container IP
newport
out=$(STUB_SSM_OUT=garbage run tunnel --port "$PORT" -- true); rc=$?
assert_status $rc 1 "bad container IP: fails"
assert_contains "$out" "could not find the Postgres container" "bad container IP: explained"
assert_eq "$(sessions)" "0" "bad container IP: no session started"

# ============ the local port is taken
newport
"$T/listen" "$PORT" & LISTENER=$!
i=0; while ! port_open "$PORT" && (( i < 50 )); do sleep 0.1; i=$((i + 1)); done
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
