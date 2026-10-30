#!/usr/bin/env bash
# monitoring.sh add | remove | status
# Optional CloudWatch module: email alerts (SNS) for site down, server checks, disk, memory, CPU, stale backups.
# add is idempotent. remove deletes only the monitoring resources this script creates (exact names), never data.
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config
cmd="${1:-}"
case "$cmd" in add|remove) require_account ;; esac   # status is read-only
ACCT=$(aws_account)
TOPIC="${EDH_PREFIX}-alerts"
ROLE="${EDH_PREFIX}-host"
REF="${EDH_PREFIX}-site"     # Route 53 CallerReference (idempotency key)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

topic_arn() { printf 'arn:aws:sns:%s:%s:%s' "$1" "$ACCT" "$TOPIC"; }

ensure_topic() { # ensure_topic <region>
  local arn e subs
  arn=$(aws --region "$1" sns create-topic --name "$TOPIC" --tags "Key=edh:client,Value=$EDH_CLIENT" --query TopicArn --output text)
  subs=$(aws --region "$1" sns list-subscriptions-by-topic --topic-arn "$arn" --query 'Subscriptions[].Endpoint' --output text)
  for e in $(printf '%s' "$EDH_ALERT_EMAILS" | tr ',' ' '); do
    if [[ " $(printf '%s' "$subs" | tr '\t' ' ') " != *" $e "* ]]; then
      aws --region "$1" sns subscribe --topic-arn "$arn" --protocol email --notification-endpoint "$e" >/dev/null
      warn "$e: AWS sent a 'Subscription Confirmation' email ($1) — click the link to receive alerts"
    fi
  done
}

# alarm <region> <suffix> <description> <namespace> <metric> <dims> <stat> <period> <evals> <threshold> <comparison> <missing>
alarm() {
  local arn; arn=$(topic_arn "$1")
  # shellcheck disable=SC2086  # $6 is a space-separated list of Name=...,Value=... dimensions
  aws --region "$1" cloudwatch put-metric-alarm --alarm-name "${EDH_PREFIX}-$2" --alarm-description "$3" \
    --namespace "$4" --metric-name "$5" --dimensions $6 --statistic "$7" --period "$8" --evaluation-periods "$9" \
    --threshold "${10}" --comparison-operator "${11}" --treat-missing-data "${12}" \
    --alarm-actions "$arn" --ok-actions "$arn"
}

health_check_id() {
  aws route53 list-health-checks --query "HealthChecks[?CallerReference=='$REF'].Id | [0]" --output text
}

# The agent may publish only into this client's namespace CWAgent/<name> (inline policy edh-cwagent). Never the
# managed CloudWatchAgentServerPolicy, which allows PutMetricData into any namespace: a host could publish
# another client's EDH/<name> BackupFresh heartbeat and hide that client's stale backups. Nor one shared agent
# namespace: a host could publish datapoints with another client's InstanceId and hide its disk/memory alarms.
agent_policy() {
  render_aws cwagent-policy.json > "$WORK/cwagent-policy.json"
  aws iam put-role-policy --role-name "$ROLE" --policy-name edh-cwagent --policy-document "file://$WORK/cwagent-policy.json"
}

install_agent() { # the script is visible in SSM history: config only, no secrets
  if [[ "${EDH_SKIP_SSM:-}" == 1 ]]; then return 0; fi
  ssm_run "$EDH_IID" 600 "set -e
cd /tmp
if ! command -v /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl >/dev/null; then
  curl -fsSLo cwa.deb https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/arm64/latest/amazon-cloudwatch-agent.deb
  dpkg -i -E cwa.deb && rm -f cwa.deb
fi
cat > /opt/aws/amazon-cloudwatch-agent/etc/edh.json <<'CWAEOF'
$(render_cwagent)
CWAEOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/edh.json" >/dev/null \
    || die "could not install or start the CloudWatch agent on $EDH_IID"
}

add() {
  local r type disk_dims hc p
  require_instance
  log "monitoring for $EDH_NAME → $EDH_ALERT_EMAILS"
  ensure_topic "$EDH_REGION"
  if [[ "$EDH_REGION" != us-east-1 ]]; then ensure_topic us-east-1; fi
  agent_policy
  install_agent
  r="$EDH_REGION"
  type=$(awsr ec2 describe-instances --instance-ids "$EDH_IID" --query 'Reservations[0].Instances[0].InstanceType' --output text)
  for p in root:/ data:/data; do
    disk_dims="Name=InstanceId,Value=$EDH_IID Name=path,Value=${p#*:} Name=fstype,Value=ext4"
    alarm "$r" "disk-${p%%:*}-warn" "Disk ${p#*:} over 80%" "CWAgent/$EDH_NAME" disk_used_percent "$disk_dims" Maximum 300 1 80 GreaterThanThreshold missing
    alarm "$r" "disk-${p%%:*}-crit" "Disk ${p#*:} over 90%" "CWAgent/$EDH_NAME" disk_used_percent "$disk_dims" Maximum 300 1 90 GreaterThanThreshold missing
  done
  alarm "$r" mem-high "Memory over 90% for 10 min" "CWAgent/$EDH_NAME" mem_used_percent "Name=InstanceId,Value=$EDH_IID" Average 300 2 90 GreaterThanThreshold missing
  alarm "$r" cpu-high "CPU over 80% for 15 min" AWS/EC2 CPUUtilization "Name=InstanceId,Value=$EDH_IID" Average 300 3 80 GreaterThanThreshold missing
  if [[ "$type" == t* ]]; then
    alarm "$r" cpu-credits-low "Burst credits nearly used up — consider a larger or m-family server" AWS/EC2 CPUCreditBalance "Name=InstanceId,Value=$EDH_IID" Minimum 300 1 50 LessThanThreshold missing
  else   # no burst credits outside the t family (e.g. after resize.sh to m7g): drop a stale alarm
    awsr cloudwatch delete-alarms --alarm-names "${EDH_PREFIX}-cpu-credits-low"
  fi
  alarm "$r" status-check "EC2 status check failing" AWS/EC2 StatusCheckFailed "Name=InstanceId,Value=$EDH_IID" Maximum 60 2 1 GreaterThanOrEqualToThreshold breaching
  # edh-backup.sh publishes BackupFresh every hour while the last successful upload is within its schedule
  # window (hourly or daily alike), so the alarm is the same for every schedule
  alarm "$r" backup-stale "Backups are not up to date" "EDH/$EDH_NAME" BackupFresh "Name=Client,Value=$EDH_CLIENT Name=Env,Value=$EDH_ENV" Sum 3600 2 1 LessThanThreshold breaching

  aws route53 create-health-check --caller-reference "$REF" --health-check-config \
    "Type=HTTPS,FullyQualifiedDomainName=$EDH_DOMAIN,Port=443,ResourcePath=/health,RequestInterval=30,FailureThreshold=3,EnableSNI=true" >/dev/null 2>&1 || true
  hc=$(health_check_id)
  [[ -n "$hc" && "$hc" != None ]] || die "could not create or find the Route 53 health check"
  aws route53 change-tags-for-resource --resource-type healthcheck --resource-id "$hc" --add-tags "Key=Name,Value=$EDH_PREFIX" "Key=edh:client,Value=$EDH_CLIENT" >/dev/null
  alarm us-east-1 site-down "https://$EDH_DOMAIN/health failing from outside" AWS/Route53 HealthCheckStatus "Name=HealthCheckId,Value=$hc" Minimum 60 1 1 LessThanThreshold breaching
  ok "monitoring on (about \$4/month). Alerts and recoveries are emailed to $EDH_ALERT_EMAILS"
}

remove() {
  local hc iid
  confirm "Remove all monitoring for $EDH_NAME (alarms, health check, alert emails)?"
  # exact names (alarm_names), never a prefix: edh-acme-prod- also starts client acme-prod's alarm names.
  # Deleting an alarm that doesn't exist is not an error.
  # shellcheck disable=SC2046  # one argument per alarm name
  awsr cloudwatch delete-alarms --alarm-names $(alarm_names regional)
  # shellcheck disable=SC2046
  aws_use1 cloudwatch delete-alarms --alarm-names $(alarm_names global)
  awsr sns delete-topic --topic-arn "$(topic_arn "$EDH_REGION")" || true
  if [[ "$EDH_REGION" != us-east-1 ]]; then aws_use1 sns delete-topic --topic-arn "$(topic_arn us-east-1)" || true; fi
  hc=$(health_check_id)
  if [[ -n "$hc" && "$hc" != None ]]; then aws route53 delete-health-check --health-check-id "$hc"; fi
  iid=$(instance_id) || iid=""
  if [[ "${EDH_SKIP_SSM:-}" != 1 && -n "$iid" && "$iid" != None && "$iid" != *[[:space:]]* ]]; then
    ssm_run "$iid" 120 '/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a stop || true' >/dev/null \
      || warn "could not stop the CloudWatch agent on $iid"
  fi
  aws iam delete-role-policy --role-name "$ROLE" --policy-name edh-cwagent 2>/dev/null || true   # absent is fine
  ok "monitoring removed"
  if [[ "$EDH_MONITORING" == cloudwatch ]]; then warn "set 'monitoring: none' in deploy/deploy.yml and redeploy, so the server stops publishing to the deleted topic"; fi
}

status() {
  # shellcheck disable=SC2046
  awsr cloudwatch describe-alarms --alarm-names $(alarm_names regional) \
    --query 'MetricAlarms[].[AlarmName,StateValue,ActionsEnabled]' --output text
  # shellcheck disable=SC2046
  aws_use1 cloudwatch describe-alarms --alarm-names $(alarm_names global) \
    --query 'MetricAlarms[].[AlarmName,StateValue,ActionsEnabled]' --output text
}

case "$cmd" in add) add ;; remove) remove ;; status) status ;; *) die "usage: monitoring.sh add | remove | status" ;; esac
