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

# compose_env <var=value>... — run the rest of the line under `env -i`: only PATH, HOME and the Docker client
# settings pass through, so the operator's shell can't change what compose.yml renders to
compose_env() {
  local keep=() v
  for v in PATH HOME DOCKER_HOST DOCKER_CONFIG DOCKER_CONTEXT; do
    if [[ -n "${!v:-}" ]]; then keep+=("$v=${!v}"); fi
  done
  env -i ${keep[@]+"${keep[@]}"} "$@"
}

# check_compose — deploy/compose.yml against the skill's compose rules (assets/host/edh-compose-check.py, the same
# check edh-deploy.sh runs on the server with the real values). It works on Compose's own normalized config
# (docker compose config --format json: anchors, aliases, list styles, interpolation and paths resolved), rendered
# as the server would: compose.yml alone in a directory with empty app.env/postgres.env, placeholder values for
# the variables the server sets, the gotenberg profile on.
check_compose() {
  local d out vargs
  require_python
  d=$(mktemp -d) || die "mktemp failed"
  mkdir "$d/app"
  cp deploy/compose.yml "$d/app/compose.yml" || { rm -rf "$d"; die "deploy/compose.yml missing"; }
  : > "$d/app/app.env"; : > "$d/app/postgres.env"
  set -- EDH_NAME=lintcheck APP_IMAGE=lint:check DOMAIN=lint.example.com MAINT_BYPASS=lint EDH_DATA_DIR=/data \
         APP_PORT=3000 APP_MEMORY_MB=512 COMPOSE_PROFILES=gotenberg
  if ! compose_env "$@" docker compose --project-directory "$d/app" -f "$d/app/compose.yml" \
       config --no-env-resolution --format json > "$d/cfg.json" 2>"$d/err"; then
    out=$(cat "$d/err"); rm -rf "$d"
    refuse "deploy/compose.yml is not valid for Compose (docker compose config failed; the server would refuse it too):
$out"
  fi
  if compose_env "$@" docker compose --project-directory "$d/app" -f "$d/app/compose.yml" \
       config --variables --format json > "$d/vars.json" 2>/dev/null; then
    vargs="--variables $d/vars.json"
  else
    warn "this Docker Compose can't list variables (config --variables): scanning deploy/compose.yml for them instead"
    vargs="--scan $d/app/compose.yml"
  fi
  # shellcheck disable=SC2086  # vargs is "--option path" (mktemp paths have no spaces)
  out=$(python3 -I "$EDH_SKILL_DIR/assets/host/edh-compose-check.py" "$d/cfg.json" "$d/app" $vargs 2>&1) || {
    local rc=$?; rm -rf "$d"
    if (( rc == 1 )); then refuse "deploy/$out"; fi
    die "could not check deploy/compose.yml: $out"
  }
  rm -rf "$d"
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
