#!/usr/bin/env bash
# db.sh tunnel [--port N] [-- command …]
# Open an SSM port-forward from localhost:<port> (default 15432) to this client's Postgres container and, with a
# command, run it with DATABASE_URL=postgres://app:<password>@localhost:<port>/app set for that command only (the
# password is read from SSM <path>/_edh/postgres-password and never printed or logged). The command keeps the
# terminal; the tunnel closes when it ends. Without a command the tunnel stays open until Ctrl-C.
# Needs the AWS Session Manager plugin. Nothing changes on the server (no published port, no security-group rule).
# Exit: the command's exit code · 1 refused or failed (the message says why).
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
usage="usage: db.sh tunnel [--port N] [-- command …]"
[[ "${1:-}" == tunnel ]] || die "$usage"
shift
PORT=15432
CMD=()
while (( $# > 0 )); do
  case "$1" in
    --port)
      [[ "${2:-}" =~ ^[0-9]{1,5}$ ]] && (( 10#$2 >= 1024 && 10#$2 <= 65535 )) || die "--port must be 1024-65535"
      PORT=$((10#$2)); shift 2 ;;
    --) shift; CMD=("$@"); break ;;
    *) die "$usage" ;;
  esac
done

load_config
# the operations log names the command by its first two words only (the rest might carry secrets)
detail=tunnel
if (( ${#CMD[@]} > 0 )); then detail="tunnel → ${CMD[0]}${CMD[1]+ ${CMD[1]}}"; fi
oplog_begin db "$detail"
require aws
require_account
command -v session-manager-plugin >/dev/null \
  || refuse "the AWS Session Manager plugin is not installed (it carries the SSM port-forward): brew install --cask session-manager-plugin"
if (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null; then refuse "port $PORT is already in use on this machine — pass --port N"; fi
require_instance

ip=$(ssm_run "$EDH_IID" 60 "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${EDH_NAME}-postgres-1" 2>/dev/null | tail -n 1) || true
[[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "could not find the Postgres container ${EDH_NAME}-postgres-1 on $EDH_IID — is the app deployed? (status.sh)"

SPID="" slog=""
# stop_tunnel — end the session: its children first (the AWS CLI runs the Session Manager plugin as a child)
stop_tunnel() {
  if [[ -n "$SPID" ]]; then
    pkill -P "$SPID" 2>/dev/null || true
    kill "$SPID" 2>/dev/null || true
    wait "$SPID" 2>/dev/null || true
  fi
  if [[ -n "$slog" ]]; then rm -f "$slog"; fi
}
slog=$(mktemp)
at_exit 'stop_tunnel'
# `aws` itself, not the awsr function: in the background a function runs in a subshell, and then the plugin would
# be a grandchild that stop_tunnel's pkill -P does not reach
aws --region "$EDH_REGION" ssm start-session --target "$EDH_IID" --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$ip\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"$PORT\"]}" >"$slog" 2>&1 &
SPID=$!

i=0
until (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null; do
  i=$((i + 1))
  if ! kill -0 "$SPID" 2>/dev/null || (( i > 60 )); then die "the SSM tunnel did not open: $(tail -3 "$slog")"; fi
  sleep 0.5
done

if (( ${#CMD[@]} == 0 )); then
  ok "tunnel open: localhost:$PORT → Postgres (database app, user app; the password is in SSM $EDH_SSM_PATH/_edh/postgres-password). Ctrl-C to close."
  rc=0
  wait "$SPID" || rc=$?
  exit "$rc"
fi

pw=$(awsr ssm get-parameter --name "$EDH_SSM_PATH/_edh/postgres-password" --with-decryption --query Parameter.Value --output text) \
  || die "cannot read $EDH_SSM_PATH/_edh/postgres-password"
[[ "$pw" =~ ^[A-Za-z0-9]+$ ]] || die "$EDH_SSM_PATH/_edh/postgres-password must be letters and digits only"
rc=0
DATABASE_URL="postgres://app:$pw@localhost:$PORT/app" "${CMD[@]}" || rc=$?
unset pw
exit "$rc"
