#!/usr/bin/env bash
# teardown.sh [--keep-ip] — remove the SERVER and its plumbing. Data is always kept:
#   data volume, backup + uploads buckets, ECR images, SSM secrets and existing snapshots stay.
#   Deleting them is a manual step (printed). This script never deletes a volume, bucket, ECR repo or parameter.
# Removes: monitoring (if on), the server, its Elastic IP, security group, snapshot policy, IAM role + profile.
#   --keep-ip  keep the Elastic IP (about $3.60/month unattached): a server rebuilt with provision.sh --apply gets
#              the same public IP, so DNS needs no change. Without it a rebuilt server gets a NEW IP.
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
KEEP_IP=0
case "${1:-}" in "") ;; --keep-ip) KEEP_IP=1 ;; *) die "usage: teardown.sh [--keep-ip]" ;; esac
load_config
require_account
ACCT=$(aws_account)
ROLE="${EDH_PREFIX}-host"
# the kept-data summary is printed however teardown ends (also after a failure half way)
kept_message() {
  local rc=$? ipline
  trap - EXIT
  if (( KEEP_IP )); then
    ipline="  - the Elastic IP (--keep-ip): a rebuilt server gets the same public IP; DNS needs no change"
  else
    ipline="The Elastic IP was released: a rebuilt server gets a NEW public IP — update the DNS A record for $EDH_DOMAIN
(provision.sh --apply prints the new IP; status.sh shows it)."
  fi
  cat >&2 <<EOF

Data kept (on purpose):
  - data volume tagged edh:client=$EDH_CLIENT, edh:env=$EDH_ENV
  - its snapshots: with the snapshot policy gone they no longer expire on their own — delete them by hand when done
  - s3://${EDH_PREFIX}-backups-$ACCT  and  s3://${EDH_PREFIX}-uploads-$ACCT
  - ECR repo $EDH_ECR_REPO, SSM parameters under $EDH_SSM_PATH/
$ipline
Re-running provision.sh --apply reuses all of it. To delete data permanently, do it by hand in the console
after taking a final backup — this skill never deletes resources tagged Protect=true.
EOF
  exit "$rc"
}
trap kept_message EXIT
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

# whatever deploy.yml says now (monitoring may have been switched off since): remove uses exact names and is idempotent
EDH_YES=1 "$BASH" "$(dirname "$0")/monitoring.sh" remove || warn "monitoring removal incomplete"
if [[ -n "$iid" ]]; then
  awsr ec2 modify-instance-attribute --instance-id "$iid" --no-disable-api-termination
  awsr ec2 terminate-instances --instance-ids "$iid" >/dev/null
  awsr ec2 wait instance-terminated --instance-ids "$iid"
  ok "server $iid terminated"
fi
eips=$(awsr ec2 describe-addresses --filters "Name=tag:edh:client,Values=$EDH_CLIENT" "Name=tag:edh:env,Values=$EDH_ENV" \
  --query 'Addresses[].[AllocationId,PublicIp]' --output text)
for alloc in $(printf '%s\n' "$eips" | cut -f1); do
  [[ "$alloc" == eipalloc-* ]] || continue
  if (( KEEP_IP )); then
    ok "Elastic IP $alloc ($(printf '%s\n' "$eips" | awk -F'\t' -v a="$alloc" '$1 == a { print $2 }')) kept (--keep-ip): provision.sh --apply reuses it"
  else
    awsr ec2 release-address --allocation-id "$alloc"; ok "Elastic IP $alloc released"
  fi
done
sg=$(awsr ec2 describe-security-groups --filters "Name=group-name,Values=$EDH_PREFIX" --query 'SecurityGroups[0].GroupId' --output text)
if [[ -n "$sg" && "$sg" != None ]]; then
  guard_not_protected "$sg"
  awsr ec2 delete-security-group --group-id "$sg" || warn "security group $sg not deleted (it may still be in use for a minute — re-run teardown.sh)"
fi
pol=$(awsr dlm get-lifecycle-policies --target-tags "edh:snapshot=$EDH_NAME" --query 'Policies[0].PolicyId' --output text)
if [[ -n "$pol" && "$pol" != None ]]; then awsr dlm delete-lifecycle-policy --policy-id "$pol"; ok "snapshot policy removed"; fi
# IAM: inline policies, every attached managed policy, the instance profile (also when the role is already gone,
# e.g. after a run that stopped half way), then the role
role=0
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  role=1
  for p in edh-host edh-cwagent; do aws iam delete-role-policy --role-name "$ROLE" --policy-name "$p" 2>/dev/null || true; done
  attached=$(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text) \
    || die "cannot list the policies attached to $ROLE"
  for arn in $attached; do
    if [[ "$arn" == arn:aws:iam::* ]]; then aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$arn"; fi
  done
fi
if aws iam get-instance-profile --instance-profile-name "$ROLE" >/dev/null 2>&1; then
  for r in $(aws iam get-instance-profile --instance-profile-name "$ROLE" --query 'InstanceProfile.Roles[].RoleName' --output text); do
    if [[ "$r" != None ]]; then aws iam remove-role-from-instance-profile --instance-profile-name "$ROLE" --role-name "$r"; fi
  done
  aws iam delete-instance-profile --instance-profile-name "$ROLE"
  ok "instance profile $ROLE removed"
fi
if (( role )); then aws iam delete-role --role-name "$ROLE"; ok "IAM role $ROLE removed"; fi
