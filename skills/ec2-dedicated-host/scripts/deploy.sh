#!/usr/bin/env bash
# deploy.sh [--maint] [--allow-dirty] [--allow-non-main]
# Build the current commit for arm64, push to ECR, ship deploy/ + host scripts, roll out via SSM.
#   --maint           show the maintenance page during migrations (use for risky migrations)
#   --allow-dirty     deploy uncommitted changes (tag gets -dirty<timestamp>); for env prod only together with
#                     --allow-non-main
#   --allow-non-main  env prod only: deploy although HEAD is not exactly origin/<prod_branch> or the tree is dirty
#                     (emergency hotfix; warns and asks for confirmation — EDH_YES=1 only after the user agreed)
# env prod: refuses unless the current branch is prod_branch (default main), HEAD equals origin/<prod_branch>
# (after git fetch) and the working tree is clean.
# Exit: 0 live · non-zero on failure: 1 with an ERROR: line for every handled case (the message says whether the
# previous version is still serving); an unexpected AWS CLI error exits with the CLI's own code.
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
MAINT=""; DIRTY_OK=0; NON_MAIN_OK=0
for a in "$@"; do
  case "$a" in --maint) MAINT=--maint ;; --allow-dirty) DIRTY_OK=1 ;; --allow-non-main) NON_MAIN_OK=1 ;; *) die "unknown option: $a" ;; esac
done
load_config
require aws
require_account
require docker; require git; require curl

# check_compose — a lint of deploy/compose.yml as written (comment lines ignored; values hidden in variables are
# not resolved), not a sandbox. Bind-mount sources are an allowlist: ./<dir>, /data/<dir> or
# ${EDH_DATA_DIR…}/<dir>, never the data directory itself or /data/backups (the backup manifest, which restores
# trust because the app can't reach it), never a path with "..". Named volumes are fine. Also refused:
# privileged mode, cap_add, devices, the Docker socket, and the host's pid/ipc/user/network namespace.
# Prints "<line><TAB>data|host<TAB><reason>: <text>" per problem, with the file's own line numbers.
COMPOSE_LINT='
BEGIN { q = sprintf("%c", 39); vi = -1 }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function unq(s,  f) {
  s = trim(s); f = substr(s, 1, 1)
  if ((f == "\"" || f == q) && length(s) >= 2 && substr(s, length(s), 1) == f) s = substr(s, 2, length(s) - 2)
  return s
}
function hit(kind, why) { if (last != NR) printf "%d\t%s\t%s: %s\n", NR, kind, why, trim($0); last = NR }
function srcof(v,  i, j, rest) {   # host side of a short-syntax volume ("" for an anonymous volume)
  v = unq(v)
  if (substr(v, 1, 2) == "${") {
    i = index(v, "}"); if (i == 0) return v
    rest = substr(v, i + 1); j = index(rest, ":"); return j ? substr(v, 1, i + j - 1) : ""
  }
  i = index(v, ":"); return i ? substr(v, 1, i - 1) : ""
}
function check(src,  s) {
  src = unq(src)
  if (src == "") return
  if (src ~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/) return                       # named volume
  if (src ~ /(^|\/)\.\.(\/|$)/) { hit("host", "path with \"..\""); return }
  s = src
  if (sub(/^\$\{EDH_DATA_DIR(:?-[^}]*)?\}/, "/data", s) || s ~ /^\/data(\/|$)/) {
    if (s ~ /^\/data\/*$/) hit("data", "the whole data directory")
    else if (s ~ /^\/data\/+backups(\/|$)/) hit("data", "/data/backups (the backup manifest)")
    return
  }
  if (src ~ /^\.\/+[^\/]/) return                                         # ./<dir>
  hit("host", "bind mount from " src " (allowed: ./<dir>, /data/<dir>, ${EDH_DATA_DIR:-/data}/<dir>)")
}
{
  line = $0
  if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) next
  sub(/[ \t]+#.*$/, "", line)
  match(line, /^[ \t]*/); ind = RLENGTH
  if (vi >= 0 && ind <= vi) vi = -1
  if (vi >= 0 && line ~ /^[ \t]*-/) {
    item = line; sub(/^[ \t]*-[ \t]*/, "", item)
    if (item ~ /^\{/) {
      if (match(item, /source:[ \t]*[^,}]+/)) { s = substr(item, RSTART, RLENGTH); sub(/^source:[ \t]*/, "", s); check(s) }
    } else if (item !~ /^[A-Za-z_]+:([ \t]|$)/) check(srcof(item))
  }
  if (line ~ /^[ \t]+volumes:[ \t]*$/) vi = ind
  else if (line ~ /^[ \t]+volumes:[ \t]*\[/) {
    s = line; sub(/^[^\[]*\[/, "", s); sub(/\][ \t]*$/, "", s); n = split(s, parts, ",")
    for (k = 1; k <= n; k++) check(srcof(parts[k]))
  }
  if (line ~ /^[ \t]*(-[ \t]*)?source:/) { s = line; sub(/^[ \t]*(-[ \t]*)?source:[ \t]*/, "", s); check(s) }
  if (line ~ /docker\.sock/) hit("host", "the Docker socket")
  if (line ~ /^[ \t]*privileged:[ \t]*["\047]?(true|True|TRUE|yes|Yes|YES|on|On|ON)["\047]?[ \t]*$/) hit("host", "privileged mode")
  if (line ~ /^[ \t]*(pid|ipc|userns_mode|network_mode):[ \t]*["\047]?host["\047]?[ \t]*$/) hit("host", "a host namespace")
  if (line ~ /^[ \t]*(cap_add|devices):/) hit("host", "extra capabilities or devices")
}'
check_compose() {
  local hits data host
  hits=$(awk "$COMPOSE_LINT" deploy/compose.yml) || die "could not read deploy/compose.yml"
  data=$(printf '%s\n' "$hits" | awk -F'\t' '$2 == "data" { print "  line " $1 ": " $3 }')
  host=$(printf '%s\n' "$hits" | awk -F'\t' '$2 == "host" { print "  line " $1 ": " $3 }')
  [[ -z "$data" ]] || die "deploy/compose.yml mounts the data directory or /data/backups into a container — refusing: that would put the backup manifest within the app's reach. Mount only subdirectories such as \${EDH_DATA_DIR:-/data}/caddy:
$data${host:+
$host}"
  [[ -z "$host" ]] || die "deploy/compose.yml gives a container access to the server itself — refusing. Bind mounts may only come from ./<dir>, /data/<dir> or \${EDH_DATA_DIR:-/data}/<dir> (no '..'); not allowed: the Docker socket, privileged, cap_add, devices, pid/ipc/userns_mode/network_mode: host (see references/app-contract.md):
$host"
}

# check_prod_source <dirty:0|1> — prod runs only what is on GitHub's prod branch: the current branch is
# prod_branch, HEAD is exactly origin/<prod_branch> and the tree is clean (catches "forgot to pull", unpushed
# commits, the wrong branch and uncommitted edits). --allow-non-main deploys anyway, after a prominent warning
# and a confirmation.
check_prod_source() {
  local dirty="$1" pb="$EDH_PROD_BRANCH" branch head subject origin counts ahead behind why="" fix=""
  branch=$(git symbolic-ref --short -q HEAD || true)
  head=$(git rev-parse --short=12 HEAD) || die "cannot read HEAD"
  subject=$(git log -1 --format=%s HEAD)
  # never wait for a credential prompt: an agent can't answer it
  if ! GIT_TERMINAL_PROMPT=0 git fetch origin "$pb" --quiet; then
    why="could not fetch $pb from origin, so it cannot be checked that this is what origin/$pb holds"
    fix="check 'git remote -v', your network and your GitHub access, then deploy again"
  elif ! origin=$(git rev-parse -q --verify 'FETCH_HEAD^{commit}'); then
    why="git fetch origin $pb returned no commit"
    fix="check 'git remote -v' and that origin has a $pb branch"
  elif [[ -z "$branch" ]]; then
    why="detached HEAD (not on a branch)"
    fix="git checkout $pb && git pull"
  elif [[ "$branch" != "$pb" ]]; then
    why="on branch '$branch', not $pb"
    fix="git checkout $pb && git pull (get the work merged into $pb through your review first)"
  else
    counts=$(git rev-list --left-right --count "HEAD...$origin") || die "cannot compare HEAD with origin/$pb"
    ahead=$(printf '%s' "$counts" | cut -f1); behind=$(printf '%s' "$counts" | cut -f2)
    if (( ahead > 0 && behind > 0 )); then
      why="local $pb and origin/$pb have diverged ($ahead local commit(s) not on origin/$pb, $behind on origin/$pb not here)"
      fix="reconcile them (e.g. git pull --rebase) and push through your review"
    elif (( behind > 0 )); then
      why="local $pb is $behind commit(s) behind origin/$pb"
      fix="git pull"
    elif (( ahead > 0 )); then
      why="local $pb has $ahead commit(s) that are not on origin/$pb (unpushed)"
      fix="push them through your usual review, then deploy again"
    fi
  fi
  if (( dirty )); then
    why="${why:+$why; }the working tree has uncommitted changes"
    fix="${fix:+$fix; }commit them and push through your review"
  fi
  [[ -n "$why" ]] || return 0
  if (( ! NON_MAIN_OK )); then
    die "prod deploys must be exactly origin/$pb: $why.
  Fix: $fix
  (Emergency hotfix only, and only if the user asks: deploy.sh --allow-non-main)"
  fi
  printf '\n\033[1;41;37m EMERGENCY DEPLOY TO PROD — NOT origin/%s \033[0m\n' "$pb" >&2
  warn "$why"
  warn "deploying branch '${branch:-detached HEAD}' at $head \"$subject\"$( (( dirty )) && echo ' with uncommitted changes') to $EDH_NAME"
  warn "the next normal deploy from $pb replaces it: get this fix into $pb through your review"
  confirm "Deploy branch '${branch:-detached HEAD}' at $head (not origin/$pb) to PROD $EDH_NAME?"
}

check_compose
SHA=$(git rev-parse --short=12 HEAD) || die "not a git repository (run from the project root)"
DIRTY=0
if [[ -n "$(git status --porcelain)" ]]; then
  (( DIRTY_OK )) || die "uncommitted changes — commit first, or pass --allow-dirty"
  DIRTY=1; SHA="${SHA}-dirty$(date +%s)"
fi
[[ "$SHA" =~ ^[0-9a-f]+(-dirty[0-9]+)?$ ]] || die "unexpected commit id: '$SHA'"   # goes into the remote script
if [[ "$EDH_ENV" == prod ]]; then check_prod_source "$DIRTY"; fi
log "deploying ${SHA%%-dirty*} \"$(git log -1 --format=%s HEAD)\" to $EDH_NAME$( [[ "$SHA" == *-dirty* ]] && echo ' (with uncommitted changes)')"
ACCT=$(aws_account)
require_instance
REG="${ACCT}.dkr.ecr.${EDH_REGION}.amazonaws.com"
BUCKET="${EDH_PREFIX}-backups-${ACCT}"
IMAGE="$REG/$EDH_ECR_REPO:$SHA"

ip=$(awsr ec2 describe-addresses --filters "Name=instance-id,Values=$EDH_IID" --query 'Addresses[0].PublicIp' --output text)
dns=$(dig +short "$EDH_DOMAIN" A 2>/dev/null | tail -1 || true)
if [[ "$dns" != "$ip" ]]; then warn "$EDH_DOMAIN resolves to '${dns:-nothing}', server is $ip — HTTPS will fail until DNS points here"; fi

log "1/4 build + push $IMAGE"
aws ecr get-login-password --region "$EDH_REGION" | docker login --username AWS --password-stdin "$REG" >/dev/null
docker buildx build --platform linux/arm64 -f "$EDH_DOCKERFILE" -t "$IMAGE" --push "$EDH_BUILD_CONTEXT"

log "2/4 ship config bundle"
tgz=$(make_bundle "$SHA")
trap 'rm -f "$tgz"' EXIT
# s3api with --expected-bucket-owner: bucket names are global, the bundle only goes to this account's bucket
awsr s3api put-object --bucket "$BUCKET" --key "_edh/bundles/$SHA.tgz" --body "$tgz" --expected-bucket-owner "$ACCT" >/dev/null

log "3/4 roll out on $EDH_IID"
# Non-secret by design (SSM keeps the command): the host reads secrets from SSM itself.
# --no-same-owner: as root, tar would otherwise keep the Mac user's uid on the extracted files.
rc=0
ssm_run "$EDH_IID" 2400 "set -euo pipefail
export PATH=/snap/bin:\$PATH
R=/opt/edh/releases/$SHA
rm -rf \"\$R\"; mkdir -p \"\$R\"
t=\$(mktemp)
aws s3api get-object --bucket $BUCKET --key _edh/bundles/$SHA.tgz --expected-bucket-owner $ACCT --region $EDH_REGION \"\$t\" >/dev/null
tar xzf \"\$t\" --no-same-owner -C \"\$R\"; rm -f \"\$t\"
ls -1dt /opt/edh/releases/* | tail -n +6 | xargs -r rm -rf
bash \"\$R/host/edh-deploy.sh\" \"\$R\" $IMAGE $MAINT" || rc=$?
case $rc in
  0) ;;
  1) die "deploy stopped before the swap — the previous version is still serving, with its previous configuration (on a first deploy: nothing was serving yet). See the output above." ;;
  2) die "new version failed its health check — rolled back to the previous version" ;;
  3) die "deploy failed and no healthy version is running — the site may be down; run status.sh" ;;
  124) die "the deploy is still running on the server after the timeout — run status.sh to see how it ended" ;;
  *) die "deploy failed (exit $rc) — the site may be down; run status.sh" ;;
esac

log "4/4 verify https://$EDH_DOMAIN/health"
if curl -fsS --max-time 15 "https://$EDH_DOMAIN/health" >/dev/null; then ok "live: https://$EDH_DOMAIN ($SHA)"
else warn "deployed, but https://$EDH_DOMAIN/health failed from here — check DNS/TLS with status.sh"; fi
