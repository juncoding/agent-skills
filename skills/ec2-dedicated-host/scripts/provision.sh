#!/usr/bin/env bash
# provision.sh [--apply]
# Create, or verify, every AWS resource for this project's dedicated server. Default: plan only (no changes).
# Re-runnable: each step checks for the tagged resource first, and every --apply re-applies the idempotent
# settings (bucket settings, lifecycle policies, security group rules, role policies), so a run that stopped
# half way is completed by the next one. Never deletes anything.
# Order: read-only checks first (bucket ownership, instance type, placement), so a refusal changes nothing.
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
SG_ID="" VOL_ID="" VOL_AZ="" AZ="" SUBNET="" EIP_ALLOC="" EIP_IP="" EDH_IID=""
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT   # temp files (secrets, rendered policies), removed on any exit
IAM_WAIT="${EDH_IAM_WAIT:-15}"                   # seconds for IAM changes to propagate (tests: 0)

# step <description> <check-fn> <create-fn>
step() {
  if "$2"; then ok "$1: exists"; return 0; fi
  if (( APPLY )); then log "$1: creating"; "$3"; ok "$1: created"; else warn "$1: would create"; fi
}
# sync_step <description> <fn> — settings re-applied on every --apply (idempotent)
sync_step() { if (( APPLY )); then "$2"; ok "$1: synced"; else warn "$1: would sync"; fi; }
# std_tags <name> — TAGS=( Key=...,Value=... ) for APIs that take a tag list
std_tags() {
  TAGS=("Key=Name,Value=$1" "Key=edh:client,Value=$EDH_CLIENT" "Key=edh:env,Value=$EDH_ENV"
        "Key=Client,Value=$EDH_CLIENT" "Key=ManagedBy,Value=ec2-dedicated-host")
}
# lines <text> — number of non-empty lines that aren't "None" (CLI text output of a list query)
lines() { printf '%s\n' "$1" | grep -v -e '^None$' -e '^$' | grep -c . || true; }
# words <text> — tabs/newlines to single spaces, padded: " a b c "
words() { printf ' %s ' "$(printf '%s' "$1" | tr -s '\t\n' '  ')"; }

# The checks below may run inside `if`, where set -e is off: a failed describe call must stop the script,
# not read as "missing" (which would create a second data volume, IP or server).

# --- IAM role + instance profile (holding the role)
has_role() {
  aws iam get-role --role-name "$ROLE" >/dev/null 2>&1 || return 1
  [[ "$(aws iam get-instance-profile --instance-profile-name "$ROLE" \
        --query 'InstanceProfile.Roles[0].RoleName' --output text 2>/dev/null)" == "$ROLE" ]]
}
make_role() { # each piece only if missing, so a half-finished earlier run is completed
  local changed=0
  std_tags "$ROLE"
  if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
    aws iam create-role --role-name "$ROLE" --assume-role-policy-document "file://$EDH_SKILL_DIR/assets/aws/ec2-trust.json" \
      --tags "${TAGS[@]}" >/dev/null
  fi
  if ! aws iam get-instance-profile --instance-profile-name "$ROLE" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "$ROLE" --tags "${TAGS[@]}" >/dev/null
    changed=1
  fi
  if [[ "$(aws iam get-instance-profile --instance-profile-name "$ROLE" \
          --query 'InstanceProfile.Roles[0].RoleName' --output text)" != "$ROLE" ]]; then
    aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE"
    changed=1
  fi
  if (( changed )); then sleep "$IAM_WAIT"; fi   # IAM propagation before run-instances can use the profile
}
sync_role_policies() {
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  render_aws host-policy.json > "$WORK/host-policy.json"
  aws iam put-role-policy --role-name "$ROLE" --policy-name edh-host --policy-document "file://$WORK/host-policy.json"
}

# --- security group: web only, no SSH
has_sg() {
  SG_ID=$(awsr ec2 describe-security-groups --filters "Name=group-name,Values=$EDH_PREFIX" "Name=vpc-id,Values=$VPC" \
    --query 'SecurityGroups[0].GroupId' --output text) || die "cannot list security groups"
  [[ -n "$SG_ID" && "$SG_ID" != None ]]
}
make_sg() {
  SG_ID=$(awsr ec2 create-security-group --group-name "$EDH_PREFIX" --vpc-id "$VPC" \
    --description "ec2-dedicated-host $EDH_NAME: web only, no SSH" \
    --tag-specifications "$(tag_spec security-group "$EDH_PREFIX")" --query GroupId --output text)
}
sync_sg_rules() { # one rule per call: a rule that already exists (InvalidPermission.Duplicate) is fine
  local p err
  for p in 'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]' \
           'IpProtocol=tcp,FromPort=80,ToPort=80,Ipv6Ranges=[{CidrIpv6=::/0}]' \
           'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]' \
           'IpProtocol=tcp,FromPort=443,ToPort=443,Ipv6Ranges=[{CidrIpv6=::/0}]' \
           'IpProtocol=udp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]'; do
    if ! err=$(awsr ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions "$p" 2>&1 >/dev/null); then
      case "$err" in *InvalidPermission.Duplicate*) ;; *) die "could not add security group rule $p: $err" ;; esac
    fi
  done
}

# --- buckets
# has_bucket <name> — 0: exists and belongs to this account · 1: does not exist (404) · anything else dies:
# a bucket name is global, so one owned by another account (or unreadable) must never be configured or used.
has_bucket() {
  local err
  if err=$(awsr s3api head-bucket --bucket "$1" --expected-bucket-owner "$ACCT" 2>&1 >/dev/null); then return 0; fi
  case "$err" in *"(404)"*|*"Not Found"*) return 1 ;; esac
  die "bucket $1 exists but is not owned by account $ACCT (or is inaccessible) — refusing"
}
make_bucket() { # make_bucket <name>
  if [[ "$EDH_REGION" == us-east-1 ]]; then awsr s3api create-bucket --bucket "$1" >/dev/null
  else awsr s3api create-bucket --bucket "$1" --create-bucket-configuration "LocationConstraint=$EDH_REGION" >/dev/null; fi
}
sync_bucket() { # sync_bucket <name> <lifecycle-file>
  awsr s3api put-public-access-block --bucket "$1" --expected-bucket-owner "$ACCT" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  awsr s3api put-bucket-versioning --bucket "$1" --expected-bucket-owner "$ACCT" --versioning-configuration Status=Enabled
  awsr s3api put-bucket-tagging --bucket "$1" --expected-bucket-owner "$ACCT" --tagging \
    "TagSet=[{Key=Name,Value=$1},{Key=Protect,Value=true},{Key=edh:client,Value=$EDH_CLIENT},{Key=edh:env,Value=$EDH_ENV},{Key=Client,Value=$EDH_CLIENT},{Key=ManagedBy,Value=ec2-dedicated-host}]"
  render_aws "$2" > "$WORK/$2"
  awsr s3api put-bucket-lifecycle-configuration --bucket "$1" --expected-bucket-owner "$ACCT" --lifecycle-configuration "file://$WORK/$2"
}
HAVE_BACKUP=0 HAVE_UPLOADS=0
has_backup_bucket()   { (( HAVE_BACKUP )); }
make_backup_bucket()  { make_bucket "$B_BACKUP"; HAVE_BACKUP=1; }
sync_backup_bucket()  { sync_bucket "$B_BACKUP" backups-lifecycle.json; }
has_uploads_bucket()  { (( HAVE_UPLOADS )); }
make_uploads_bucket() { make_bucket "$B_UPLOADS"; HAVE_UPLOADS=1; }
sync_uploads_bucket() { sync_bucket "$B_UPLOADS" uploads-lifecycle.json; }

# --- ECR
has_ecr()  { awsr ecr describe-repositories --repository-names "$EDH_ECR_REPO" >/dev/null 2>&1; }
make_ecr() {
  std_tags "$EDH_ECR_REPO"
  awsr ecr create-repository --repository-name "$EDH_ECR_REPO" --image-scanning-configuration scanOnPush=true \
    --tags "${TAGS[@]}" >/dev/null
}
sync_ecr() {
  awsr ecr put-lifecycle-policy --repository-name "$EDH_ECR_REPO" --lifecycle-policy-text \
    '{"rules":[{"rulePriority":1,"description":"keep last 20","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":20},"action":{"type":"expire"}}]}' >/dev/null
}

# --- internal secrets: hex (as the host requires for _edh/*), passed by a 0600 file, never on the command line
has_secret() { awsr ssm get-parameter --name "$EDH_SSM_PATH/_edh/$1" >/dev/null 2>&1; }
has_secrets() { has_secret postgres-password && has_secret maint-bypass; }
make_secrets() {
  local n v f="$WORK/secret"
  for n in postgres-password maint-bypass; do
    if ! has_secret "$n"; then
      v=$(gen_secret 40)
      [[ "$v" =~ ^[0-9a-f]{40}$ ]] || die "gen_secret returned an unexpected value"
      ( umask 077; printf '%s' "$v" > "$f" )   # no trailing newline: the file content is the value
      awsr ssm put-parameter --name "$EDH_SSM_PATH/_edh/$n" --type SecureString --value "file://$f" >/dev/null \
        || die "could not store $EDH_SSM_PATH/_edh/$n"
      rm -f "$f"
    fi
  done
}

# --- data volume, Elastic IP, server (find_* die on more than one match)
find_volume() {
  local out n
  out=$(awsr ec2 describe-volumes --filters "Name=tag:edh:client,Values=$EDH_CLIENT" "Name=tag:edh:env,Values=$EDH_ENV" \
    "Name=tag:edh:role,Values=data" --query 'Volumes[].[VolumeId,AvailabilityZone]' --output text) \
    || die "cannot list volumes"
  n=$(lines "$out")
  (( n <= 1 )) || die "more than one data volume tagged $EDH_NAME: $(printf '%s' "$out" | cut -f1 | tr '\n' ' ')"
  (( n == 1 )) || return 0
  VOL_ID=$(printf '%s' "$out" | cut -f1); VOL_AZ=$(printf '%s' "$out" | cut -f2)
}
has_volume() { [[ -n "$VOL_ID" ]]; }
make_volume() {
  VOL_ID=$(awsr ec2 create-volume --availability-zone "$AZ" --size "$EDH_DATA_GB" --volume-type gp3 --encrypted \
    --tag-specifications "$(tag_spec volume "${EDH_PREFIX}-data" edh:role=data Protect=true "edh:snapshot=$EDH_NAME")" \
    --query VolumeId --output text)
  VOL_AZ="$AZ"
  awsr ec2 wait volume-available --volume-ids "$VOL_ID"
}

has_eip() {
  local out n
  out=$(awsr ec2 describe-addresses --filters "Name=tag:edh:client,Values=$EDH_CLIENT" "Name=tag:edh:env,Values=$EDH_ENV" \
    --query 'Addresses[].[AllocationId,PublicIp]' --output text) || die "cannot list Elastic IPs"
  n=$(lines "$out")
  (( n <= 1 )) || die "more than one Elastic IP tagged $EDH_NAME: $(printf '%s' "$out" | cut -f2 | tr '\n' ' ')"
  (( n == 1 )) || return 1
  EIP_ALLOC=$(printf '%s' "$out" | cut -f1); EIP_IP=$(printf '%s' "$out" | cut -f2)
}
make_eip() {
  local out
  out=$(awsr ec2 allocate-address --domain vpc --tag-specifications "$(tag_spec elastic-ip "$EDH_PREFIX")" \
    --query '[AllocationId,PublicIp]' --output text)
  EIP_ALLOC=$(printf '%s' "$out" | cut -f1); EIP_IP=$(printf '%s' "$out" | cut -f2)
}

find_instance() {
  EDH_IID=$(instance_id) || die "cannot list instances"
  [[ "$EDH_IID" != *[[:space:]]* ]] || die "more than one server tagged $EDH_NAME: $EDH_IID"
  if [[ "$EDH_IID" == None ]]; then EDH_IID=""; fi
}
has_instance() { [[ -n "$EDH_IID" ]]; }
make_instance() {
  local ami
  ami=$(awsr ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id \
    --query Parameter.Value --output text)
  render_bootstrap "$VOL_ID" > "$WORK/user-data"
  EDH_IID=$(awsr ec2 run-instances --image-id "$ami" --instance-type "$TYPE" --subnet-id "$SUBNET" \
    --security-group-ids "$SG_ID" --iam-instance-profile "Name=$ROLE" --user-data "file://$WORK/user-data" \
    --metadata-options HttpTokens=required,HttpPutResponseHopLimit=$HOP,HttpEndpoint=enabled \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}' \
    --disable-api-termination \
    --tag-specifications "$(tag_spec instance "$EDH_PREFIX")" "$(tag_spec volume "${EDH_PREFIX}-root" edh:role=root)" \
    --query 'Instances[0].InstanceId' --output text)
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
  local role
  role=$(aws iam get-role --role-name AWSDataLifecycleManagerDefaultRole --query Role.Arn --output text 2>/dev/null || true)
  if [[ -z "$role" ]]; then
    awsr dlm create-default-role --resource-type snapshot >/dev/null; sleep "$IAM_WAIT"
    role=$(aws iam get-role --role-name AWSDataLifecycleManagerDefaultRole --query Role.Arn --output text)
  fi
  render_aws dlm-policy.json > "$WORK/dlm-policy.json"
  awsr dlm create-lifecycle-policy --description "$EDH_PREFIX data snapshots" --state ENABLED \
    --execution-role-arn "$role" --policy-details "file://$WORK/dlm-policy.json" \
    --tags "Name=${EDH_PREFIX}-snapshots,edh:client=$EDH_CLIENT,edh:env=$EDH_ENV,Client=$EDH_CLIENT,ManagedBy=ec2-dedicated-host" >/dev/null
}

# bootstrap_state — one SSM check of both markers: 0 done · 3 failed (bootstrap-failed) · anything else: not yet
bootstrap_state() {
  ssm_run "$EDH_IID" 60 'if [ -f /var/lib/edh/bootstrap-failed ]; then exit 3; fi; test -f /var/lib/edh/bootstrap-done' >/dev/null
}

log "provision $EDH_NAME — account $ACCT, region $EDH_REGION — $( (( APPLY )) && echo APPLY || echo 'plan only, nothing changes')"
log "server type $TYPE · data disk ${EDH_DATA_GB} GB · domain $EDH_DOMAIN · monitoring $EDH_MONITORING"
if (( HOP == 2 )); then log "instance metadata hop limit 2: the app container may use the server's IAM role"
else log "instance metadata hop limit 1: containers cannot reach instance metadata"; fi

# ---- read-only preflight: nothing below changes anything until every check has passed
if has_bucket "$B_BACKUP"; then HAVE_BACKUP=1; fi
if has_bucket "$B_UPLOADS"; then HAVE_UPLOADS=1; fi
arch=$(awsr ec2 describe-instance-types --instance-types "$TYPE" \
  --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' --output text) || die "cannot describe instance type $TYPE"
[[ "$(words "$arch")" == *" arm64 "* ]] \
  || die "$TYPE does not support arm64 (it supports: $arch); the server runs Ubuntu arm64 — choose a Graviton type such as t4g"
find_instance
find_volume
CUR_TYPE=""
if [[ -n "$EDH_IID" ]]; then   # an existing server fixes the AZ
  cur=$(awsr ec2 describe-instances --instance-ids "$EDH_IID" \
    --query 'Reservations[0].Instances[0].[InstanceType,Placement.AvailabilityZone]' --output text) || die "cannot describe $EDH_IID"
  CUR_TYPE=$(printf '%s' "$cur" | cut -f1); AZ=$(printf '%s' "$cur" | cut -f2)
  if [[ -n "$VOL_ID" && "$VOL_AZ" != "$AZ" ]]; then die "server $EDH_IID is in $AZ but data volume $VOL_ID is in $VOL_AZ"; fi
  if [[ -z "$VOL_ID" ]]; then
    if (( APPLY )); then
      die "server $EDH_IID exists but no data volume tagged $EDH_NAME was found — refusing to create an empty data volume for a running server (find, re-tag or restore the data volume first)"
    fi
    warn "server $EDH_IID has no data volume tagged $EDH_NAME — --apply will refuse rather than create an empty one"
  fi
  if [[ "$CUR_TYPE" != "$TYPE" ]]; then warn "server is $CUR_TYPE, config wants $TYPE — use resize.sh"; fi
else                           # a new server: an AZ that offers the type and has a default subnet (or the volume's)
  offered=$(awsr ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters "Name=instance-type,Values=$TYPE" --query 'InstanceTypeOfferings[].Location' --output text) \
    || die "cannot list where $TYPE is offered"
  offered=$(words "$offered")
  if [[ -n "$VOL_ID" ]]; then
    AZ="$VOL_AZ"
    [[ "$offered" == *" $AZ "* ]] || die "the data volume $VOL_ID is in $AZ, where $TYPE is not offered"
  else
    subnet_azs=$(awsr ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" "Name=default-for-az,Values=true" \
      --query 'Subnets[].AvailabilityZone' --output text) || die "cannot list the default subnets of $VPC"
    subnet_azs=$(words "$subnet_azs")
    for z in $(printf '%s' "$offered" | tr ' ' '\n' | sort); do
      if [[ "$subnet_azs" == *" $z "* ]]; then AZ="$z"; break; fi
    done
    [[ -n "$AZ" ]] || die "no availability zone in $EDH_REGION offers $TYPE and has a default subnet"
  fi
  SUBNET=$(awsr ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" "Name=availability-zone,Values=$AZ" \
    "Name=default-for-az,Values=true" --query 'Subnets[0].SubnetId' --output text) || die "cannot list subnets"
  [[ -n "$SUBNET" && "$SUBNET" != None ]] || die "no default subnet in $AZ (VPC $VPC)"
fi
log "placement: $TYPE in $AZ"

# ---- create what is missing; re-apply settings
step "IAM role $ROLE" has_role make_role
sync_step "IAM role policies" sync_role_policies
step "security group $EDH_PREFIX" has_sg make_sg
sync_step "security group rules" sync_sg_rules
step "backup bucket $B_BACKUP" has_backup_bucket make_backup_bucket
sync_step "backup bucket settings" sync_backup_bucket
step "uploads bucket $B_UPLOADS" has_uploads_bucket make_uploads_bucket
sync_step "uploads bucket settings" sync_uploads_bucket
step "ECR repo $EDH_ECR_REPO" has_ecr make_ecr
sync_step "ECR lifecycle policy" sync_ecr
step "internal secrets $EDH_SSM_PATH/_edh" has_secrets make_secrets
if [[ -n "$EDH_IID" && -z "$VOL_ID" ]]; then   # only reachable in plan mode: --apply died in the preflight
  warn "data volume ${EDH_PREFIX}-data: refused — server $EDH_IID exists without one; an empty volume is never created for it"
else
  step "data volume ${EDH_PREFIX}-data" has_volume make_volume
fi
step "Elastic IP $EDH_PREFIX" has_eip make_eip
step "server $EDH_PREFIX" has_instance make_instance
if [[ -n "$EDH_IID" ]]; then sync_hop; fi

if (( APPLY )); then
  step "data volume attached" is_attached attach
  step "Elastic IP associated" is_associated associate
  step "snapshot policy (DLM)" has_dlm make_dlm
  log "waiting for the server to finish bootstrapping (SSM)"
  wait_ssm "$EDH_IID"
  st=1
  for _ in $(seq 1 60); do
    st=0; bootstrap_state || st=$?
    if (( st == 0 || st == 3 )); then break; fi
    sleep 10
  done
  if (( st == 3 )); then
    die "bootstrap FAILED on $EDH_IID — see /var/log/edh-bootstrap.log (Session Manager: sudo tail -n 100 /var/log/edh-bootstrap.log)"
  fi
  (( st == 0 )) || die "bootstrap did not finish within 10 minutes — check /var/log/edh-bootstrap.log via Session Manager"
  ok "server ready: $EDH_IID at $EIP_IP"
  if [[ "$EDH_MONITORING" == cloudwatch ]]; then "$BASH" "$(dirname "$0")/monitoring.sh" add; fi
  log "DNS: point an A record for $EDH_DOMAIN to $EIP_IP (needed before the first deploy can get HTTPS)"
else
  warn "attach volume, associate IP, snapshot policy, bootstrap wait$( [[ "$EDH_MONITORING" == cloudwatch ]] && echo ', monitoring')"
  log "plan only. Re-run with --apply after the user approves."
fi
