#!/usr/bin/env bash
# teardown.sh — remove the SERVER and its plumbing. Data is always kept:
#   data volume, backup + uploads buckets, ECR images, SSM secrets and existing snapshots stay.
#   Deleting them is a manual step (printed). This script never deletes a volume, bucket, ECR repo or parameter.
# Removes: monitoring (if on), the server, its Elastic IP, security group, snapshot policy, IAM role + profile.
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config
require_account
ACCT=$(aws_account)
ROLE="${EDH_PREFIX}-host"
log "teardown $EDH_NAME (account $ACCT): terminate server, release IP, delete security group, IAM role, snapshot policy, monitoring"
if [[ "${EDH_CONFIRM_NAME:-}" != "$EDH_NAME" ]]; then
  a=""; read -r -p "Type '$EDH_NAME' to confirm: " a || true
  [[ "$a" == "$EDH_NAME" ]] || die "aborted"
fi

iid=$(instance_id)
if [[ "$iid" == None ]]; then iid=""; fi
[[ "$iid" != *[[:space:]]* ]] || die "more than one server tagged $EDH_NAME: $iid — refusing"
if [[ -n "$iid" ]]; then
  # belt and braces: terminating deletes every volume with DeleteOnTermination=true — refuse if one is protected
  # (the data volume is attached by attach-volume, so it normally isn't)
  dot=$(awsr ec2 describe-instances --instance-ids "$iid" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[?Ebs.DeleteOnTermination==`true`].Ebs.VolumeId' --output text) \
    || die "cannot read the volumes of $iid"
  for v in $dot; do
    if [[ "$v" != None ]]; then guard_not_protected "$v"; fi
  done
fi

if [[ "$EDH_MONITORING" == cloudwatch ]]; then EDH_YES=1 "$(dirname "$0")/monitoring.sh" remove || warn "monitoring removal incomplete"; fi
if [[ -n "$iid" ]]; then
  awsr ec2 modify-instance-attribute --instance-id "$iid" --no-disable-api-termination
  awsr ec2 terminate-instances --instance-ids "$iid" >/dev/null
  awsr ec2 wait instance-terminated --instance-ids "$iid"
  ok "server $iid terminated"
fi
eips=$(awsr ec2 describe-addresses --filters "Name=tag:edh:client,Values=$EDH_CLIENT" "Name=tag:edh:env,Values=$EDH_ENV" \
  --query 'Addresses[].[AllocationId,PublicIp]' --output text)
for alloc in $(printf '%s\n' "$eips" | cut -f1); do
  if [[ "$alloc" == eipalloc-* ]]; then awsr ec2 release-address --allocation-id "$alloc"; ok "Elastic IP $alloc released"; fi
done
sg=$(awsr ec2 describe-security-groups --filters "Name=group-name,Values=$EDH_PREFIX" --query 'SecurityGroups[0].GroupId' --output text)
if [[ -n "$sg" && "$sg" != None ]]; then
  guard_not_protected "$sg"
  awsr ec2 delete-security-group --group-id "$sg" || warn "security group $sg not deleted (it may still be in use for a minute — re-run teardown.sh)"
fi
pol=$(awsr dlm get-lifecycle-policies --target-tags "edh:snapshot=$EDH_NAME" --query 'Policies[0].PolicyId' --output text)
if [[ -n "$pol" && "$pol" != None ]]; then awsr dlm delete-lifecycle-policy --policy-id "$pol"; ok "snapshot policy removed"; fi
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  for p in edh-host edh-cwagent; do aws iam delete-role-policy --role-name "$ROLE" --policy-name "$p" 2>/dev/null || true; done
  aws iam detach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  aws iam remove-role-from-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$ROLE" 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE"
  ok "IAM role and instance profile $ROLE removed"
fi
cat >&2 <<EOF

Data kept (on purpose):
  - data volume tagged edh:client=$EDH_CLIENT, edh:env=$EDH_ENV
  - its snapshots: with the snapshot policy gone they no longer expire on their own — delete them by hand when done
  - s3://${EDH_PREFIX}-backups-$ACCT  and  s3://${EDH_PREFIX}-uploads-$ACCT
  - ECR repo $EDH_ECR_REPO, SSM parameters under $EDH_SSM_PATH/
Re-running provision.sh --apply reuses all of it. To delete data permanently, do it by hand in the console
after taking a final backup — this skill never deletes resources tagged Protect=true.
EOF
