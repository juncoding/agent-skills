#!/usr/bin/env bash
# provision.sh [--apply]
# Create, or verify, every AWS resource for this project's dedicated server. Default: plan only (no changes).
# Re-runnable: each step checks for the tagged resource first. Never deletes anything.
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source-path=SCRIPTDIR source=sizing.sh
. "$(dirname "$0")/sizing.sh"

APPLY=0; if [[ "${1:-}" == --apply ]]; then APPLY=1; fi
load_config
require aws
require_account
ACCT=$(aws_account)
ROLE="${EDH_PREFIX}-host"
B_BACKUP="${EDH_PREFIX}-backups-${ACCT}"
B_UPLOADS="${EDH_PREFIX}-uploads-${ACCT}"
TYPE="$EDH_INSTANCE_TYPE"
if [[ "$TYPE" == auto ]]; then TYPE=$(recommend_instance "$EDH_APP_MEMORY_MB" "$EDH_USES_GOTENBERG"); fi
# Instance metadata (IMDSv2) hop limit: 2 lets the app container use the server's IAM role (needed for S3
# uploads from the app); 1 keeps every container away from instance metadata. Allowing it is a deliberate
# trade-off: the role is per-client and least-privilege, and what it grants (this client's own secrets, backups
# and uploads) the app holds anyway: its secrets are in app.env, and the database is its own.
if [[ "$EDH_APP_USES_INSTANCE_ROLE" == true ]]; then HOP=2; else HOP=1; fi
VPC=$(awsr ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
[[ -n "$VPC" && "$VPC" != None ]] || die "no default VPC in $EDH_REGION"
SG_ID="" VOL_ID="" AZ="" EIP_ALLOC="" EIP_IP="" EDH_IID=""

# step <description> <check-fn> <create-fn>
step() {
  if "$2"; then ok "$1: exists"; return 0; fi
  if (( APPLY )); then log "$1: creating"; "$3"; ok "$1: created"; else warn "$1: would create"; fi
}

# The checks run inside `if`, where set -e is off: a failed describe call must stop the script,
# not read as "missing" (which would create a second data volume, IP or server).
has_role() { aws iam get-role --role-name "$ROLE" >/dev/null 2>&1 && aws iam get-instance-profile --instance-profile-name "$ROLE" >/dev/null 2>&1; }
make_role() { # each piece only if missing, so a half-finished earlier run is completed
  if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
    aws iam create-role --role-name "$ROLE" --assume-role-policy-document "file://$EDH_SKILL_DIR/assets/aws/ec2-trust.json" \
      --tags "Key=edh:client,Value=$EDH_CLIENT" "Key=edh:env,Value=$EDH_ENV" "Key=ManagedBy,Value=ec2-dedicated-host" >/dev/null
  fi
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  if ! aws iam get-instance-profile --instance-profile-name "$ROLE" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "$ROLE" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE"
    sleep 15   # IAM propagation before run-instances can use the profile
  fi
}
sync_policy() {
  local f; f=$(mktemp); render_aws host-policy.json > "$f"
  aws iam put-role-policy --role-name "$ROLE" --policy-name edh-host --policy-document "file://$f"
  rm -f "$f"
}

has_sg() {
  SG_ID=$(awsr ec2 describe-security-groups --filters "Name=group-name,Values=$EDH_PREFIX" "Name=vpc-id,Values=$VPC" \
    --query 'SecurityGroups[0].GroupId' --output text) || die "cannot list security groups"
  [[ -n "$SG_ID" && "$SG_ID" != None ]]
}
make_sg() {
  SG_ID=$(awsr ec2 create-security-group --group-name "$EDH_PREFIX" --vpc-id "$VPC" \
    --description "ec2-dedicated-host $EDH_NAME: web only, no SSH" \
    --tag-specifications "$(tag_spec security-group "$EDH_PREFIX")" --query GroupId --output text)
  awsr ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions \
    'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}],Ipv6Ranges=[{CidrIpv6=::/0}]' \
    'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}],Ipv6Ranges=[{CidrIpv6=::/0}]' \
    'IpProtocol=udp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]' >/dev/null
}

# has_bucket <name> — 0: exists and belongs to this account · 1: does not exist (404) · anything else dies:
# a bucket name is global, so one owned by another account (or unreadable) must never be configured or used.
has_bucket() {
  local err
  if err=$(aws s3api head-bucket --bucket "$1" --expected-bucket-owner "$ACCT" 2>&1 >/dev/null); then return 0; fi
  case "$err" in *"(404)"*|*"Not Found"*) return 1 ;; esac
  die "bucket $1 exists but is not owned by account $ACCT (or is inaccessible) — refusing"
}
make_bucket() { # make_bucket <name> <lifecycle-file>
  local f
  if [[ "$EDH_REGION" == us-east-1 ]]; then awsr s3api create-bucket --bucket "$1" >/dev/null
  else awsr s3api create-bucket --bucket "$1" --create-bucket-configuration "LocationConstraint=$EDH_REGION" >/dev/null; fi
  awsr s3api put-public-access-block --bucket "$1" --expected-bucket-owner "$ACCT" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  awsr s3api put-bucket-versioning --bucket "$1" --expected-bucket-owner "$ACCT" --versioning-configuration Status=Enabled
  awsr s3api put-bucket-tagging --bucket "$1" --expected-bucket-owner "$ACCT" --tagging \
    "TagSet=[{Key=Protect,Value=true},{Key=edh:client,Value=$EDH_CLIENT},{Key=edh:env,Value=$EDH_ENV},{Key=Client,Value=$EDH_CLIENT},{Key=ManagedBy,Value=ec2-dedicated-host}]"
  f=$(mktemp); render_aws "$2" > "$f"
  awsr s3api put-bucket-lifecycle-configuration --bucket "$1" --expected-bucket-owner "$ACCT" --lifecycle-configuration "file://$f"
  rm -f "$f"
}
has_backup_bucket()  { has_bucket "$B_BACKUP"; }
make_backup_bucket() { make_bucket "$B_BACKUP" backups-lifecycle.json; }
has_uploads_bucket() { has_bucket "$B_UPLOADS"; }
make_uploads_bucket(){ make_bucket "$B_UPLOADS" uploads-lifecycle.json; }

has_ecr()  { awsr ecr describe-repositories --repository-names "$EDH_ECR_REPO" >/dev/null 2>&1; }
make_ecr() {
  awsr ecr create-repository --repository-name "$EDH_ECR_REPO" --image-scanning-configuration scanOnPush=true \
    --tags "Key=edh:client,Value=$EDH_CLIENT" "Key=ManagedBy,Value=ec2-dedicated-host" >/dev/null
  awsr ecr put-lifecycle-policy --repository-name "$EDH_ECR_REPO" --lifecycle-policy-text \
    '{"rules":[{"rulePriority":1,"description":"keep last 20","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":20},"action":{"type":"expire"}}]}' >/dev/null
}

has_secret() { awsr ssm get-parameter --name "$EDH_SSM_PATH/_edh/$1" >/dev/null 2>&1; }
has_secrets() { has_secret postgres-password && has_secret maint-bypass; }
make_secrets() { # hex values (gen_secret), as the host requires for _edh/*; passed by file, never on the command line
  local n f
  for n in postgres-password maint-bypass; do
    if ! has_secret "$n"; then
      f=$(mktemp); chmod 600 "$f"; gen_secret 40 > "$f"
      awsr ssm put-parameter --name "$EDH_SSM_PATH/_edh/$n" --type SecureString --value "file://$f" >/dev/null \
        || { rm -f "$f"; die "could not store $EDH_SSM_PATH/_edh/$n"; }
      rm -f "$f"
    fi
  done
}

has_volume() {
  local out
  out=$(awsr ec2 describe-volumes --filters "Name=tag:edh:client,Values=$EDH_CLIENT" "Name=tag:edh:env,Values=$EDH_ENV" \
    "Name=tag:edh:role,Values=data" --query 'Volumes[0].[VolumeId,AvailabilityZone]' --output text) \
    || die "cannot list volumes"
  VOL_ID=$(printf '%s' "$out" | cut -f1); [[ -n "$VOL_ID" && "$VOL_ID" != None ]] || return 1
  AZ=$(printf '%s' "$out" | cut -f2)
}
make_volume() {
  VOL_ID=$(awsr ec2 create-volume --availability-zone "$AZ" --size "$EDH_DATA_GB" --volume-type gp3 --encrypted \
    --tag-specifications "$(tag_spec volume "${EDH_PREFIX}-data" edh:role=data Protect=true "edh:snapshot=$EDH_NAME")" \
    --query VolumeId --output text)
  awsr ec2 wait volume-available --volume-ids "$VOL_ID"
}

has_eip() {
  local out
  out=$(awsr ec2 describe-addresses --filters "Name=tag:edh:client,Values=$EDH_CLIENT" "Name=tag:edh:env,Values=$EDH_ENV" \
    --query 'Addresses[0].[AllocationId,PublicIp]' --output text) || die "cannot list Elastic IPs"
  EIP_ALLOC=$(printf '%s' "$out" | cut -f1); EIP_IP=$(printf '%s' "$out" | cut -f2)
  [[ -n "$EIP_ALLOC" && "$EIP_ALLOC" != None ]]
}
make_eip() {
  local out
  out=$(awsr ec2 allocate-address --domain vpc --tag-specifications "$(tag_spec elastic-ip "$EDH_PREFIX")" \
    --query '[AllocationId,PublicIp]' --output text)
  EIP_ALLOC=$(printf '%s' "$out" | cut -f1); EIP_IP=$(printf '%s' "$out" | cut -f2)
}

has_instance() {
  EDH_IID=$(instance_id) || die "cannot list instances"
  [[ "$EDH_IID" != *[[:space:]]* ]] || die "more than one server tagged $EDH_NAME: $EDH_IID"
  [[ -n "$EDH_IID" && "$EDH_IID" != None ]]
}
make_instance() {
  local ami subnet ud
  ami=$(awsr ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id \
    --query Parameter.Value --output text)
  subnet=$(awsr ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" "Name=availability-zone,Values=$AZ" \
    "Name=default-for-az,Values=true" --query 'Subnets[0].SubnetId' --output text)
  ud=$(mktemp); render_bootstrap "$VOL_ID" > "$ud"
  EDH_IID=$(awsr ec2 run-instances --image-id "$ami" --instance-type "$TYPE" --subnet-id "$subnet" \
    --security-group-ids "$SG_ID" --iam-instance-profile "Name=$ROLE" --user-data "file://$ud" \
    --metadata-options HttpTokens=required,HttpPutResponseHopLimit=$HOP,HttpEndpoint=enabled \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}' \
    --disable-api-termination \
    --tag-specifications "$(tag_spec instance "$EDH_PREFIX")" "$(tag_spec volume "${EDH_PREFIX}-root" edh:role=root)" \
    --query 'Instances[0].InstanceId' --output text)
  rm -f "$ud"
  awsr ec2 wait instance-running --instance-ids "$EDH_IID"
}

# sync_hop — an existing server gets the configured hop limit (changed on --apply, reported in plan mode)
sync_hop() {
  local cur
  cur=$(awsr ec2 describe-instances --instance-ids "$EDH_IID" \
    --query 'Reservations[0].Instances[0].MetadataOptions.HttpPutResponseHopLimit' --output text) \
    || die "cannot read the metadata options of $EDH_IID"
  if [[ "$cur" == "$HOP" ]]; then ok "instance metadata hop limit $HOP"; return 0; fi
  if (( APPLY )); then
    awsr ec2 modify-instance-metadata-options --instance-id "$EDH_IID" --http-put-response-hop-limit "$HOP" \
      --http-tokens required --http-endpoint enabled >/dev/null
    ok "instance metadata hop limit: $cur -> $HOP"
  else
    warn "instance metadata hop limit: would change $cur -> $HOP"
  fi
}

is_attached()   { [[ $(awsr ec2 describe-volumes --volume-ids "$VOL_ID" --query 'Volumes[0].Attachments[0].InstanceId' --output text) == "$EDH_IID" ]]; }
attach()        { awsr ec2 attach-volume --volume-id "$VOL_ID" --instance-id "$EDH_IID" --device /dev/sdf >/dev/null; awsr ec2 wait volume-in-use --volume-ids "$VOL_ID"; }
is_associated() { [[ $(awsr ec2 describe-addresses --allocation-ids "$EIP_ALLOC" --query 'Addresses[0].InstanceId' --output text) == "$EDH_IID" ]]; }
associate()     { awsr ec2 associate-address --allocation-id "$EIP_ALLOC" --instance-id "$EDH_IID" >/dev/null; }

has_dlm() {
  local id
  id=$(awsr dlm get-lifecycle-policies --target-tags "edh:snapshot=$EDH_NAME" --query 'Policies[0].PolicyId' --output text) \
    || die "cannot list snapshot policies"
  [[ -n "$id" && "$id" != None ]]
}
make_dlm() {
  local role f
  role=$(aws iam get-role --role-name AWSDataLifecycleManagerDefaultRole --query Role.Arn --output text 2>/dev/null || true)
  if [[ -z "$role" ]]; then
    awsr dlm create-default-role --resource-type snapshot >/dev/null; sleep 15
    role=$(aws iam get-role --role-name AWSDataLifecycleManagerDefaultRole --query Role.Arn --output text)
  fi
  f=$(mktemp); render_aws dlm-policy.json > "$f"
  awsr dlm create-lifecycle-policy --description "$EDH_PREFIX data snapshots" --state ENABLED \
    --execution-role-arn "$role" --policy-details "file://$f" \
    --tags "edh:client=$EDH_CLIENT,ManagedBy=ec2-dedicated-host" >/dev/null
  rm -f "$f"
}

bootstrap_done() { ssm_run "$EDH_IID" 60 'test -f /var/lib/edh/bootstrap-done' >/dev/null; }

log "provision $EDH_NAME — account $ACCT, region $EDH_REGION — $( (( APPLY )) && echo APPLY || echo 'plan only, nothing changes')"
log "server type $TYPE · data disk ${EDH_DATA_GB} GB · domain $EDH_DOMAIN · monitoring $EDH_MONITORING"
if (( HOP == 2 )); then log "instance metadata hop limit 2: the app container may use the server's IAM role"
else log "instance metadata hop limit 1: containers cannot reach instance metadata"; fi

step "IAM role $ROLE" has_role make_role
if (( APPLY )); then sync_policy; ok "host policy synced"; else warn "host policy: would sync"; fi
step "security group $EDH_PREFIX" has_sg make_sg
step "backup bucket $B_BACKUP" has_backup_bucket make_backup_bucket
step "uploads bucket $B_UPLOADS" has_uploads_bucket make_uploads_bucket
step "ECR repo $EDH_ECR_REPO" has_ecr make_ecr
step "internal secrets $EDH_SSM_PATH/_edh" has_secrets make_secrets

if ! has_volume; then
  AZ=$(awsr ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters "Name=instance-type,Values=$TYPE" --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' '\n' | sort | head -1)
  [[ -n "$AZ" && "$AZ" != None ]] || die "$TYPE is not offered in any availability zone of $EDH_REGION"
fi
log "placement: $TYPE in $AZ"
step "data volume ${EDH_PREFIX}-data" has_volume make_volume
step "Elastic IP $EDH_PREFIX" has_eip make_eip
step "server $EDH_PREFIX" has_instance make_instance
if [[ -n "$EDH_IID" && "$EDH_IID" != None ]]; then sync_hop; fi

if (( APPLY )); then
  cur=$(awsr ec2 describe-instances --instance-ids "$EDH_IID" --query 'Reservations[0].Instances[0].[InstanceType,Placement.AvailabilityZone]' --output text)
  [[ "$(printf '%s' "$cur" | cut -f2)" == "$AZ" ]] || die "server is in $(printf '%s' "$cur" | cut -f2) but data volume is in $AZ"
  if [[ "$(printf '%s' "$cur" | cut -f1)" != "$TYPE" ]]; then warn "server is $(printf '%s' "$cur" | cut -f1), config wants $TYPE — use resize.sh"; fi
  step "data volume attached" is_attached attach
  step "Elastic IP associated" is_associated associate
  step "snapshot policy (DLM)" has_dlm make_dlm
  log "waiting for the server to finish bootstrapping (SSM)"
  wait_ssm "$EDH_IID"
  for _ in $(seq 1 60); do bootstrap_done && break; sleep 10; done
  bootstrap_done || die "bootstrap did not finish — check /var/log/edh-bootstrap.log via Session Manager"
  ok "server ready: $EDH_IID at $EIP_IP"
  if [[ "$EDH_MONITORING" == cloudwatch ]]; then "$(dirname "$0")/monitoring.sh" add; fi
  log "DNS: point an A record for $EDH_DOMAIN to $EIP_IP (needed before the first deploy can get HTTPS)"
else
  warn "attach volume, associate IP, snapshot policy, bootstrap wait$( [[ "$EDH_MONITORING" == cloudwatch ]] && echo ', monitoring')"
  log "plan only. Re-run with --apply after the user approves."
fi
