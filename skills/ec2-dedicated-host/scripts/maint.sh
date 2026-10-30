#!/usr/bin/env bash
# maint.sh on [--message TEXT] [--until TEXT] | off | status
# Turns the planned-maintenance page on/off and pauses/resumes the site-down alert accordingly.
# The message is visible in SSM command history (like every remote command): never put secrets in it.
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config
cmd="${1:-}"; shift || true
case "$cmd" in on|off) require_account ;; esac   # status is read-only
require_instance
remote() { ssm_run "$EDH_IID" 120 "$(printf '%q ' /opt/edh/bin/edh-maint.sh "$@")"; }
site_alarm="${EDH_PREFIX}-site-down"
case "$cmd" in
  on)
    remote on "$@" || die "could not switch maintenance on (see the output above)"
    if [[ "$EDH_MONITORING" == cloudwatch ]]; then aws_use1 cloudwatch disable-alarm-actions --alarm-names "$site_alarm"; ok "site-down alert paused"; fi
    # shown to the operator only (never sent to the server or logged elsewhere)
    tok=$(awsr ssm get-parameter --name "$EDH_SSM_PATH/_edh/maint-bypass" --with-decryption --query Parameter.Value --output text)
    log "your bypass link (opens the real site for 24 h): https://$EDH_DOMAIN/?maint_bypass=$tok" ;;
  off)
    remote off || die "could not switch maintenance off (see the output above)"
    if [[ "$EDH_MONITORING" == cloudwatch ]]; then aws_use1 cloudwatch enable-alarm-actions --alarm-names "$site_alarm"; ok "site-down alert resumed"; fi ;;
  status) remote status ;;
  *) die "usage: maint.sh on [--message T] [--until T] | off | status" ;;
esac
