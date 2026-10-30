#!/usr/bin/env bash
# status.sh — server, site, backups, alarms at a glance (read-only).
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config; require_instance
info=$(awsr ec2 describe-instances --instance-ids "$EDH_IID" \
  --query 'Reservations[0].Instances[0].[State.Name,InstanceType,Placement.AvailabilityZone,PublicIpAddress]' --output text)
echo "server:  $EDH_IID  $(printf '%s' "$info" | tr '\t' ' ')"
echo "dns:     $EDH_DOMAIN → $(dig +short "$EDH_DOMAIN" A 2>/dev/null | tail -1)"
echo "site:    https://$EDH_DOMAIN/health → $(curl -s -o /dev/null -w '%{http_code} in %{time_total}s' --max-time 15 "https://$EDH_DOMAIN/health" || echo unreachable)"
if [[ "$EDH_MONITORING" == cloudwatch ]]; then
  # exact alarm names, never a name prefix (see alarm_names)
  # shellcheck disable=SC2046  # one argument per alarm name (names have no spaces)
  alarms=$( { awsr cloudwatch describe-alarms --alarm-names $(alarm_names regional) --state-value ALARM --query 'MetricAlarms[].AlarmName' --output text
              aws_use1 cloudwatch describe-alarms --alarm-names $(alarm_names global) --state-value ALARM --query 'MetricAlarms[].AlarmName' --output text; } \
            | tr '\t' '\n' | { grep -v -e '^None$' -e '^$' || true; } | xargs)
  echo "alarms:  ${alarms:-none firing}"
fi
echo "--- on the server ---"
ssm_run "$EDH_IID" 120 /opt/edh/bin/edh-status.sh || warn "could not read the status from the server"
