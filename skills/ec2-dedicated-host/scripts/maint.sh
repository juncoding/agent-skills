#!/usr/bin/env bash
# maint.sh on [--message TEXT] [--until TEXT] [--no-link] | off | status | rotate-bypass
# Turns the planned-maintenance page on/off and pauses/resumes the site-down alert accordingly.
#   on             also shows your bypass link (to the terminal if there is one, else stderr); --no-link: don't
#   rotate-bypass  store a new bypass token (old links stop working once deploy.sh has applied it)
# The message is visible in SSM command history (like every remote command): never put secrets in it.
# It travels as one literal argument (printf %q), so nothing in it is expanded on the server.
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config
cmd="${1:-}"; shift || true
case "$cmd" in on|off|rotate-bypass) require_account ;; esac   # status is read-only
link=1; args=()
for a in "$@"; do if [[ "$a" == --no-link ]]; then link=0; else args+=("$a"); fi; done
remote() { ssm_run "$EDH_IID" 120 "$(printf '%q ' /opt/edh/bin/edh-maint.sh "$@")"; }
site_alarm="${EDH_PREFIX}-site-down"

# show_link — the bypass link, for the operator only: to the terminal when there is one, so it doesn't end up in
# captured output or logs; stderr otherwise
show_link() {
  local tok msg
  tok=$(awsr ssm get-parameter --name "$EDH_SSM_PATH/_edh/maint-bypass" --with-decryption --query Parameter.Value --output text) \
    || { warn "could not read the bypass token"; return 0; }
  msg="your bypass link (opens the real site for 24 h): https://$EDH_DOMAIN/?maint_bypass=$tok"
  if { true >/dev/tty; } 2>/dev/null; then printf '%s\n' "$msg" >/dev/tty; else log "$msg"; fi
}

case "$cmd" in
  on)
    require_instance
    remote on ${args[@]+"${args[@]}"} || die "could not switch maintenance on (see the output above)"
    if [[ "$EDH_MONITORING" == cloudwatch ]]; then aws_use1 cloudwatch disable-alarm-actions --alarm-names "$site_alarm"; ok "site-down alert paused"; fi
    if (( link )); then show_link; fi ;;
  off)
    require_instance
    remote off || die "could not switch maintenance off (see the output above)"
    if [[ "$EDH_MONITORING" == cloudwatch ]]; then aws_use1 cloudwatch enable-alarm-actions --alarm-names "$site_alarm"; ok "site-down alert resumed"; fi ;;
  status) require_instance; remote status ;;
  rotate-bypass)
    v=$(gen_secret 40)
    [[ "$v" =~ ^[0-9a-f]{40}$ ]] || die "gen_secret returned an unexpected value"
    WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
    ( umask 077; printf '%s' "$v" > "$WORK/token" )   # by file, never on the command line
    awsr ssm put-parameter --name "$EDH_SSM_PATH/_edh/maint-bypass" --type SecureString --value "file://$WORK/token" \
      --overwrite >/dev/null || die "could not store the new bypass token"
    ok "new maintenance bypass token stored — run deploy.sh to apply it (the old link keeps working until then)" ;;
  *) die "usage: maint.sh on [--message T] [--until T] [--no-link] | off | status | rotate-bypass" ;;
esac
