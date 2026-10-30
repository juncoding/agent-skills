#!/usr/bin/env bash
# Shared helpers for ec2-dedicated-host local scripts (run on the operator's machine). Source, don't run.
# Must stay compatible with macOS bash 3.2.
set -euo pipefail

# shellcheck disable=SC2034  # read by the scripts that source this file
EDH_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
# die <message> — print it and exit 1; its first line also goes into the operations-log entry (oplog_finish)
die()  {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  OPLOG_REASON=$(printf '%s\n' "$*" | head -n 1 | cut -c1-200)
  exit 1
}
# refuse <message> — die, logged as "refused" (the request breaks a rule) rather than "failed"
refuse() { OPLOG_RESULT=refused; die "$@"; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# ---- operations log (deploy/OPERATIONS.md) and the EXIT handling around it
# A mutating command calls oplog_begin <command> [detail]; when the script exits — however it exits — one line
# is appended: "- <date> UTC · <command> · <result> · <detail> · <who>". Result: ok, failed (exit N), refused,
# aborted, or what the script put in OPLOG_RESULT (e.g. "rolled back"); a die message's first line is added.
# Scripts register their own cleanup with at_exit (not trap … EXIT), which runs first.
# NEVER put a secret value or the bypass token into a detail.
OPLOG_CMD="" OPLOG_DETAIL="" OPLOG_RESULT="" OPLOG_REASON="" OPLOG_DONE=0 EDH_AT_EXIT="" EDH_RC=0
oplog_begin() { OPLOG_CMD="$1"; OPLOG_DETAIL="${2:-}"; }
at_exit() { EDH_AT_EXIT="$1"; }   # at_exit <code> — cleanup to run on exit ($EDH_RC holds the exit code)
oplog_finish() {
  local rc="$1" res
  [[ -n "$OPLOG_CMD" && "$OPLOG_DONE" != 1 ]] || return 0
  OPLOG_DONE=1
  if [[ -n "$OPLOG_RESULT" ]]; then res="$OPLOG_RESULT"; elif (( rc == 0 )); then res=ok; else res="failed (exit $rc)"; fi
  if [[ "$OPLOG_REASON" == "$res" ]]; then OPLOG_REASON=""; fi   # "aborted · aborted"
  oplog "$OPLOG_CMD" "$res" "$OPLOG_DETAIL${OPLOG_REASON:+${OPLOG_DETAIL:+ — }$OPLOG_REASON}"
}
edh_on_exit() {
  local rc=$?
  trap - EXIT
  # shellcheck disable=SC2034  # read by at_exit handlers
  EDH_RC=$rc
  if [[ -n "$EDH_AT_EXIT" ]]; then eval "$EDH_AT_EXIT" || true; fi
  oplog_finish "$rc" || true
  exit "$rc"
}
trap edh_on_exit EXIT

# oplog <command> <result> [detail…] — append one line under "## Log" in deploy/OPERATIONS.md (run from the
# project root), creating the file from the template if it is missing. Never fails the caller: a write error
# only warns. EDH_OPLOG_SKIP=1 turns it off (scripts calling another script set it, so one action logs once).
oplog() {
  [[ "${EDH_OPLOG_SKIP:-}" != 1 ]] || return 0
  local cmd="$1" res="$2" detail="" who line
  shift 2
  detail="$*"
  who=$(git config user.name 2>/dev/null || true)
  who="${who:-${USER:-unknown}}"
  line="- $(date -u '+%Y-%m-%d %H:%M') UTC · $cmd · $res${detail:+ · $detail} · $who"
  line=$(printf '%s' "$line" | tr '\r\n\t' '   ')
  oplog_write "$line" 2>/dev/null || warn "could not write the operations log deploy/OPERATIONS.md"
  return 0
}
oplog_write() {
  local f=deploy/OPERATIONS.md last
  [[ -d deploy && ! -d "$f" ]] || return 1
  if [[ ! -f "$f" ]]; then cp "$EDH_SKILL_DIR/assets/project/OPERATIONS.md" "$f" || return 1; fi
  if ! grep -q '^## Log' "$f"; then printf '\n## Log\n' >> "$f" || return 1; fi
  if [[ -n "$(tail -c 1 "$f")" ]]; then printf '\n' >> "$f" || return 1; fi
  last=$(tail -n 1 "$f")
  if [[ -n "$last" && "$last" != "- "* ]]; then printf '\n' >> "$f" || return 1; fi   # a list after the heading text
  printf '%s\n' "$1" >> "$f"
}

# cfg_get <file> <key> [default] — value of a flat `key: value` line; strips quotes and trailing comments.
cfg_get() {
  local file="$1" key="$2" def="${3-}" val
  val=$(awk -v k="$key" '
    BEGIN { q = sprintf("%c", 39) }
    $0 ~ "^" k ":" {
      sub("^" k ":[ \t]*", ""); sub(/\r$/, "")
      if (substr($0, 1, 1) == "#") $0 = ""          # `key:   # comment` means empty
      sub(/[ \t]+#.*$/, ""); sub(/[ \t]+$/, "")
      f = substr($0, 1, 1); l = substr($0, length($0), 1)
      if ((f == "\"" || f == q) && f == l && length($0) >= 2) $0 = substr($0, 2, length($0) - 2)
      print; exit
    }' "$file")
  printf '%s' "${val:-$def}"
}

# load_config [path] — read deploy.yml into EDH_* variables and validate them.
# shellcheck disable=SC2034  # EDH_* globals set here are read by the scripts that source this file.
load_config() {
  local f="${1:-deploy/deploy.yml}"
  [[ -f "$f" ]] || die "config not found: $f (run from the project root, or create it with init.sh)"
  EDH_CONFIG="$f"
  EDH_CLIENT=$(cfg_get "$f" client)
  EDH_ENV=$(cfg_get "$f" env prod)
  EDH_REGION=$(cfg_get "$f" region ap-southeast-1)
  EDH_ACCOUNT_ID=$(cfg_get "$f" account_id "")
  EDH_DOMAIN=$(cfg_get "$f" domain)
  EDH_ALERT_EMAILS=$(cfg_get "$f" alert_emails)
  EDH_MONITORING=$(cfg_get "$f" monitoring cloudwatch)
  EDH_INSTANCE_TYPE=$(cfg_get "$f" instance_type auto)
  EDH_DATA_GB=$(cfg_get "$f" data_volume_gb 20)
  EDH_APP_PORT=$(cfg_get "$f" app_port 3000)
  EDH_APP_MEMORY_MB=$(cfg_get "$f" app_memory_mb 768)
  EDH_USES_GOTENBERG=$(cfg_get "$f" uses_gotenberg false)
  EDH_APP_USES_INSTANCE_ROLE=$(cfg_get "$f" app_uses_instance_role true)
  EDH_BACKUP_SCHEDULE=$(cfg_get "$f" backup_schedule auto)
  EDH_DAILY_HOUR_UTC=$(cfg_get "$f" daily_backup_hour_utc 18)
  EDH_MIGRATE_CMD=$(cfg_get "$f" migrate_cmd "")
  EDH_DOCKERFILE=$(cfg_get "$f" dockerfile Dockerfile)
  EDH_BUILD_CONTEXT=$(cfg_get "$f" build_context .)
  EDH_PROD_BRANCH=$(cfg_get "$f" prod_branch main)
  # cfg_get strips matched quotes only, so a value still starting with a quote was never closed.
  local kv var
  for kv in client:EDH_CLIENT env:EDH_ENV region:EDH_REGION account_id:EDH_ACCOUNT_ID domain:EDH_DOMAIN \
            alert_emails:EDH_ALERT_EMAILS monitoring:EDH_MONITORING instance_type:EDH_INSTANCE_TYPE \
            data_volume_gb:EDH_DATA_GB app_port:EDH_APP_PORT app_memory_mb:EDH_APP_MEMORY_MB \
            uses_gotenberg:EDH_USES_GOTENBERG app_uses_instance_role:EDH_APP_USES_INSTANCE_ROLE \
            backup_schedule:EDH_BACKUP_SCHEDULE \
            daily_backup_hour_utc:EDH_DAILY_HOUR_UTC migrate_cmd:EDH_MIGRATE_CMD dockerfile:EDH_DOCKERFILE \
            build_context:EDH_BUILD_CONTEXT prod_branch:EDH_PROD_BRANCH; do
    var="${kv#*:}"
    case "${!var}" in \"*|\'*) die "unclosed quote in ${kv%%:*}" ;; esac
  done
  validate_config
  EDH_NAME="${EDH_CLIENT}-${EDH_ENV}"
  EDH_PREFIX="edh-${EDH_NAME}"
  EDH_SSM_PATH="/${EDH_CLIENT}/${EDH_ENV}"
  EDH_ECR_REPO="edh/${EDH_CLIENT}"
}

validate_config() {
  [[ "$EDH_CLIENT" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]] && (( ${#EDH_CLIENT} >= 2 && ${#EDH_CLIENT} <= 21 )) \
    || die "client must be 2-21 lowercase letters/digits, single dashes between them: '$EDH_CLIENT'"
  [[ "$EDH_ENV" =~ ^[a-z][a-z0-9]{1,9}$ ]] || die "env must be 2-10 lowercase letters/digits: '$EDH_ENV'"
  # anchored: the region is substituted into IAM policy JSON by render_aws
  [[ "$EDH_REGION" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || die "region must be an AWS region like ap-southeast-1: '$EDH_REGION'"
  [[ -z "$EDH_ACCOUNT_ID" || "$EDH_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die "account_id must be empty or a 12-digit AWS account id: '$EDH_ACCOUNT_ID'"
  [[ "$EDH_DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || die "domain looks invalid: '$EDH_DOMAIN'"
  [[ "$EDH_MONITORING" == cloudwatch || "$EDH_MONITORING" == none ]] || die "monitoring must be cloudwatch or none"
  [[ "$EDH_BACKUP_SCHEDULE" =~ ^(auto|hourly|daily)$ ]] || die "backup_schedule must be auto, hourly or daily"
  [[ "$EDH_USES_GOTENBERG" == true || "$EDH_USES_GOTENBERG" == false ]] || die "uses_gotenberg must be true or false"
  [[ "$EDH_APP_USES_INSTANCE_ROLE" == true || "$EDH_APP_USES_INSTANCE_ROLE" == false ]] \
    || die "app_uses_instance_role must be true or false"
  [[ "$EDH_INSTANCE_TYPE" == auto || "$EDH_INSTANCE_TYPE" =~ ^[a-z][a-z0-9-]*\.[a-z0-9]+$ ]] \
    || die "instance_type must be auto or an EC2 type like t4g.small: '$EDH_INSTANCE_TYPE'"
  [[ "$EDH_DATA_GB" =~ ^[0-9]+$ ]] && (( 10#$EDH_DATA_GB >= 8 )) || die "data_volume_gb must be a number >= 8"
  [[ "$EDH_APP_MEMORY_MB" =~ ^[0-9]+$ ]] && (( 10#$EDH_APP_MEMORY_MB > 0 )) || die "app_memory_mb must be a number > 0"
  [[ "$EDH_APP_PORT" =~ ^[0-9]{1,5}$ ]] && (( 10#$EDH_APP_PORT >= 1 && 10#$EDH_APP_PORT <= 65535 )) || die "app_port must be 1-65535"
  [[ "$EDH_DAILY_HOUR_UTC" =~ ^[0-9]{1,2}$ ]] && (( 10#$EDH_DAILY_HOUR_UTC < 24 )) || die "daily_backup_hour_utc must be 0-23"
  # normalise numbers now they are known to be valid: "09" -> 9, "0768" -> 768
  EDH_DATA_GB=$((10#$EDH_DATA_GB))
  EDH_APP_MEMORY_MB=$((10#$EDH_APP_MEMORY_MB))
  EDH_APP_PORT=$((10#$EDH_APP_PORT))
  EDH_DAILY_HOUR_UTC=$((10#$EDH_DAILY_HOUR_UTC))
  [[ "$EDH_MIGRATE_CMD" != *"'"* ]] || die "migrate_cmd must not contain single quotes"
  # a plain git branch name (it goes to git fetch): no leading dash or dot, no "..", "//", "@{", or trailing "/" / ".lock"
  [[ "$EDH_PROD_BRANCH" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ && "$EDH_PROD_BRANCH" != *..* && "$EDH_PROD_BRANCH" != *//* \
     && "$EDH_PROD_BRANCH" != */ && "$EDH_PROD_BRANCH" != *.lock && "$EDH_PROD_BRANCH" != */.* ]] \
    || die "prod_branch must be a git branch name like main: '$EDH_PROD_BRANCH'"
  if [[ "$EDH_MONITORING" == cloudwatch && -z "$EDH_ALERT_EMAILS" ]]; then
    die "alert_emails required when monitoring: cloudwatch"
  fi
}

awsr()    { aws --region "$EDH_REGION" "$@"; }        # app region
aws_use1() { aws --region us-east-1 "$@"; }           # Route 53 health-check metrics live in us-east-1

# aws_account — 12-digit account id of the current credentials; dies if it can't be read.
# Cached in EDH_ACCOUNT, but the cache only lives in the shell that calls it: do ACCT=$(aws_account) once
# at top level and reuse $ACCT. Never inline $(aws_account) inside another command's arguments, where a
# failure would not stop the script.
aws_account() {
  if [[ -z "${EDH_ACCOUNT:-}" ]]; then
    EDH_ACCOUNT=$(aws sts get-caller-identity --query Account --output text) || die "cannot read AWS account (check credentials/profile)"
    [[ "$EDH_ACCOUNT" =~ ^[0-9]{12}$ ]] || die "AWS account is not a 12-digit id: '$EDH_ACCOUNT'"
  fi
  printf '%s' "$EDH_ACCOUNT"
}

# require_account — refuse to run against any account but deploy.yml's account_id (warns once if unset).
require_account() {
  EDH_ACCOUNT=""           # always ask STS: a pre-set EDH_ACCOUNT must not get past this check
  aws_account >/dev/null   # in this shell, so EDH_ACCOUNT is cached
  if [[ -z "$EDH_ACCOUNT_ID" ]]; then
    if [[ -z "${EDH_ACCOUNT_WARNED:-}" ]]; then
      warn "deploy.yml has no account_id; set account_id: $EDH_ACCOUNT so scripts refuse any other AWS account"
      EDH_ACCOUNT_WARNED=1
    fi
    return 0
  fi
  [[ "$EDH_ACCOUNT" == "$EDH_ACCOUNT_ID" ]] || refuse "AWS credentials are for account $EDH_ACCOUNT but deploy.yml says $EDH_ACCOUNT_ID"
}

# tag_spec <resource-type> <name> [Key=Value ...] — value for --tag-specifications
tag_spec() {
  local rtype="$1" name="$2" extra="" kv; shift 2
  for kv in "$@"; do extra="${extra},{Key=${kv%%=*},Value=${kv#*=}}"; done
  printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s},{Key=edh:client,Value=%s},{Key=edh:env,Value=%s},{Key=Client,Value=%s},{Key=ManagedBy,Value=ec2-dedicated-host}%s]' \
    "$rtype" "$name" "$EDH_CLIENT" "$EDH_ENV" "$EDH_CLIENT" "$extra"
}

# guard_not_protected <ec2-resource-id> — never touch anything tagged Protect=true (any case).
# Refuses as well when the tags can't be read.
guard_not_protected() {
  local v
  v=$(awsr ec2 describe-tags --filters "Name=resource-id,Values=$1" "Name=key,Values=Protect" --query 'Tags[0].Value' --output text) \
    || die "refusing: cannot read tags of $1 to check Protect=true"
  v=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
  [[ "$v" != true ]] || refuse "refusing: $1 is tagged Protect=true (it holds data). Remove the tag by hand only if you really mean it."
}

# confirm <question> — EDH_YES=1 skips the prompt (the agent sets it only after the user agreed in chat).
confirm() {
  local a=""
  if [[ "${EDH_YES:-}" == 1 ]]; then return 0; fi
  read -r -p "$1 [y/N] " a || true
  a=$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')
  [[ "$a" == y || "$a" == yes ]] || { OPLOG_RESULT=aborted; die "aborted"; }
}

# gen_secret [length] — random hex string, 1-64 characters (default 40).
gen_secret() {
  local n="${1:-40}"
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 64 )) || die "gen_secret: length must be 1-64, got '$n'"
  openssl rand -hex 32 | cut -c1-"$n"
}

instance_id() {
  awsr ec2 describe-instances \
    --filters "Name=tag:edh:client,Values=$EDH_CLIENT" "Name=tag:edh:env,Values=$EDH_ENV" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

require_instance() {
  EDH_IID=$(instance_id)
  [[ -n "$EDH_IID" && "$EDH_IID" != None ]] || die "no server for $EDH_NAME yet — run provision.sh first"
  [[ "$EDH_IID" != *[[:space:]]* ]] || die "more than one server tagged $EDH_NAME: $EDH_IID"
}

# find_data_volume — EDH_VOL_ID / EDH_VOL_AZ of this client's one data volume (tag edh:role=data); dies on
# none or more than one.
# shellcheck disable=SC2034  # EDH_VOL_* are read by the scripts that call this
find_data_volume() {
  local out
  out=$(awsr ec2 describe-volumes --filters "Name=tag:edh:client,Values=$EDH_CLIENT" "Name=tag:edh:env,Values=$EDH_ENV" \
    "Name=tag:edh:role,Values=data" --query 'Volumes[].[VolumeId,AvailabilityZone]' --output text) || die "cannot list volumes"
  out=$(printf '%s\n' "$out" | grep -v -e '^None$' -e '^$' || true)
  [[ -n "$out" ]] || die "no data volume tagged $EDH_NAME"
  [[ "$out" != *$'\n'* ]] || die "more than one data volume tagged $EDH_NAME: $(printf '%s' "$out" | cut -f1 | tr '\n' ' ')"
  EDH_VOL_ID=$(printf '%s' "$out" | cut -f1); EDH_VOL_AZ=$(printf '%s' "$out" | cut -f2)
  [[ "$EDH_VOL_ID" =~ ^vol-[0-9a-z]+$ ]] || die "unexpected volume id: '$EDH_VOL_ID'"
}

# ssm_run <instance-id> <timeout-seconds> <script> — run a bash script on the server as root.
# The script travels base64-encoded, so no quoting issues. Prints its output; returns its exit code,
# or 124 if the command hasn't finished by timeout + 120 s.
# The script body is visible in SSM command history: never put secrets in it (have it read them from SSM).
# SSM keeps only the first 24,000 characters of output; write anything longer to a file.
# EDH_SSM_POLL_SECONDS overrides the 3 s poll interval (tests).
# Dies if polling fails 10 times in a row (other than InvocationDoesNotExist, which just means "not yet").
ssm_run() {
  local iid="$1" timeout="$2" b64 cid status code err errf fails=0
  local deadline=$((SECONDS + timeout + 120))
  b64=$(printf '%s' "$3" | base64 | tr -d '\n')
  cid=$(awsr ssm send-command --instance-ids "$iid" --document-name AWS-RunShellScript \
    --parameters "{\"commands\":[\"f=\$(mktemp); echo $b64 | base64 -d > \$f; bash \$f; rc=\$?; rm -f \$f; exit \$rc\"],\"executionTimeout\":[\"$timeout\"]}" \
    --timeout-seconds 60 --query Command.CommandId --output text) || die "send-command to $iid failed"
  [[ -n "$cid" && "$cid" != None ]] || die "send-command to $iid returned no command id"
  errf=$(mktemp)
  while :; do
    sleep "${EDH_SSM_POLL_SECONDS:-3}"
    if status=$(awsr ssm get-command-invocation --command-id "$cid" --instance-id "$iid" --query Status --output text 2>"$errf"); then
      fails=0
    else
      status=Pending
      if grep -q InvocationDoesNotExist "$errf"; then
        fails=0
      else
        fails=$((fails + 1))
        if (( fails >= 10 )); then
          err=$(cat "$errf"); rm -f "$errf"
          die "polling SSM command $cid on $iid failed 10 times in a row; last error: $err"
        fi
      fi
    fi
    case "$status" in Pending|InProgress|Delayed|Cancelling) ;; *) break ;; esac
    if (( SECONDS > deadline )); then
      rm -f "$errf"
      warn "SSM command $cid on $iid is still $status after $((timeout + 120)) s; giving up waiting"
      return 124
    fi
  done
  rm -f "$errf"
  awsr ssm get-command-invocation --command-id "$cid" --instance-id "$iid" --query StandardOutputContent --output text
  err=$(awsr ssm get-command-invocation --command-id "$cid" --instance-id "$iid" --query StandardErrorContent --output text)
  if [[ -n "$err" && "$err" != None ]]; then printf '%s\n' "$err" >&2; fi
  code=$(awsr ssm get-command-invocation --command-id "$cid" --instance-id "$iid" --query ResponseCode --output text)
  [[ "$code" =~ ^-?[0-9]+$ ]] || code=1
  return "$code"
}

# render_bootstrap <data-volume-id> — EC2 user-data with the volume id filled in
render_bootstrap() {
  [[ "$1" =~ ^vol-[0-9a-f]+$ ]] || die "render_bootstrap: not a volume id: '$1'"
  sed "s/__VOLUME_ID__/$1/" "$EDH_SKILL_DIR/assets/host/bootstrap.sh"
}

# render_aws <file-in-assets/aws> — fill placeholders for this client.
# Every substituted value is validated, so nothing can break out of the JSON: the region (validate_config),
# the account (12 digits, checked here too in case EDH_ACCOUNT was pre-set), and the SSM path, prefix,
# ECR repo, topic and name, all derived from the validated client and env.
# TODO(e2e): verify s3:if-none-match condition key (host-policy.json BackupsWrite) during the live AWS test (Task 20).
# TODO(e2e): verify that the host (and its app container) cannot read another client's SSM parameter
#            (host-policy.json NoOtherParameters overrides AmazonSSMManagedInstanceCore's ssm:GetParameter* on *).
render_aws() {
  local acct; acct=$(aws_account)
  [[ "$acct" =~ ^[0-9]{12}$ ]] || die "render_aws: AWS account is not a 12-digit id: '$acct'"
  sed -e "s#__REGION__#$EDH_REGION#g" -e "s#__ACCOUNT__#$acct#g" -e "s#__SSM_PATH__#$EDH_SSM_PATH#g" \
      -e "s#__BACKUP_BUCKET__#${EDH_PREFIX}-backups-${acct}#g" -e "s#__UPLOADS_BUCKET__#${EDH_PREFIX}-uploads-${acct}#g" \
      -e "s#__ECR_REPO__#$EDH_ECR_REPO#g" -e "s#__TOPIC__#${EDH_PREFIX}-alerts#g" -e "s#__NAME__#$EDH_NAME#g" \
      "$EDH_SKILL_DIR/assets/aws/$1"
}

# require_python — a python3 that really runs (on a Mac without the Command Line Tools, python3 is only a stub)
require_python() {
  require python3
  python3 -c '' >/dev/null 2>&1 || die "python3 does not run (on macOS install the Command Line Tools: xcode-select --install)"
}

# render_cwagent — the CloudWatch agent config for this client: it publishes into namespace CWAgent/<name>
# (EDH_NAME is derived from the validated client and env). The agent's own ${aws:InstanceId} stays as it is.
render_cwagent() { sed "s#__NAME__#$EDH_NAME#g" "$EDH_SKILL_DIR/assets/host/cwagent.json"; }

# wait_ssm <instance-id> — until the SSM agent reports Online (max 10 min)
wait_ssm() {
  local _
  for _ in $(seq 1 60); do
    if [[ $(awsr ssm describe-instance-information --filters "Key=InstanceIds,Values=$1" \
           --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null) == Online ]]; then return 0; fi
    sleep 10
  done
  die "SSM agent on $1 did not come online within 10 minutes"
}

# release_env <release-id> — non-secret settings for the server (installed as /etc/edh/edh.env, sourced by bash).
# Holds every EDH_* value the host scripts read (tests/ec2-dedicated-host/test_bundle.sh checks this).
# EDH_ACCOUNT_ID is the STS-verified account (aws_account), not deploy.yml's account_id, which may be empty:
# edh-backup.sh refuses to upload without it. Every value is validated by load_config (migrate_cmd has no
# single quote), so nothing here can break out of its line.
release_env() {
  local acct topic=""
  acct=$(aws_account) || return 1
  [[ "$acct" =~ ^[0-9]{12}$ ]] || die "release_env: AWS account is not a 12-digit id: '$acct'"
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || die "release_env: invalid release id: '$1'"
  if [[ "$EDH_MONITORING" == cloudwatch ]]; then topic="arn:aws:sns:$EDH_REGION:$acct:${EDH_PREFIX}-alerts"; fi
  cat <<EOV
EDH_CLIENT=$EDH_CLIENT
EDH_ENV=$EDH_ENV
EDH_NAME=$EDH_NAME
EDH_REGION=$EDH_REGION
EDH_ACCOUNT_ID=$acct
EDH_DOMAIN=$EDH_DOMAIN
EDH_SSM_PATH=$EDH_SSM_PATH
EDH_BACKUP_BUCKET=${EDH_PREFIX}-backups-${acct}
EDH_BACKUP_SCHEDULE=$EDH_BACKUP_SCHEDULE
EDH_DAILY_HOUR_UTC=$EDH_DAILY_HOUR_UTC
EDH_APP_PORT=$EDH_APP_PORT
EDH_APP_MEMORY_MB=$EDH_APP_MEMORY_MB
EDH_USES_GOTENBERG=$EDH_USES_GOTENBERG
EDH_MIGRATE_CMD='$EDH_MIGRATE_CMD'
EDH_ALERT_TOPIC_ARN=$topic
EDH_RELEASE=$1
EOV
}

# make_bundle <release-id> — tgz of deploy/ (compose.yml, Caddyfile, maint pages) + this skill's host scripts
# (every edh-*.sh, edh-*.py and systemd unit; never bootstrap.sh) + release.env; prints its path.
# Usually called as tgz=$(make_bundle ...), where set -e is off: every step checks its own result.
make_bundle() {
  local d
  d=$(mktemp -d) || die "make_bundle: mktemp failed"
  mkdir -p "$d/app/maint" "$d/host/systemd" || die "make_bundle: cannot create $d"
  cp deploy/compose.yml deploy/Caddyfile "$d/app/" || die "make_bundle: deploy/compose.yml or deploy/Caddyfile missing"
  cp deploy/maint/maintenance.html deploy/maint/down.html "$d/app/maint/" || die "make_bundle: deploy/maint/*.html missing"
  cp "$EDH_SKILL_DIR"/assets/host/edh-*.sh "$EDH_SKILL_DIR"/assets/host/edh-*.py "$d/host/" \
    || die "make_bundle: cannot copy the host scripts"
  cp "$EDH_SKILL_DIR"/assets/host/systemd/* "$d/host/systemd/" || die "make_bundle: cannot copy the systemd units"
  ( release_env "$1" ) > "$d/release.env" || { rm -rf "$d"; die "make_bundle: cannot write release.env"; }
  # COPYFILE_DISABLE: no macOS ._* metadata files in the archive (the server's GNU tar would extract them)
  COPYFILE_DISABLE=1 tar czf "$d.tgz" -C "$d" . || { rm -rf "$d" "$d.tgz"; die "make_bundle: tar failed"; }
  rm -rf "$d"
  printf '%s' "$d.tgz"
}

# alarm_names regional|global — the CloudWatch alarms monitoring.sh manages: regional ones live in the app
# region, the site-down alarm (Route 53 health check metric) in us-east-1. Always exact names, never a name
# prefix: edh-acme-prod- is also the start of client "acme-prod"'s alarms (edh-acme-prod-staging-...).
alarm_names() {
  local s
  if [[ "$1" == global ]]; then printf '%s\n' "${EDH_PREFIX}-site-down"; return 0; fi
  for s in disk-root-warn disk-root-crit disk-data-warn disk-data-crit mem-high cpu-high cpu-credits-low \
           status-check backup-stale; do
    printf '%s\n' "${EDH_PREFIX}-$s"
  done
}
