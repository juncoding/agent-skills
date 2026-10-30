#!/usr/bin/env bash
# deploy.sh [--maint] [--allow-dirty] [--allow-non-main]
# Build the current commit for arm64, push to ECR, ship deploy/ + host scripts, roll out via SSM.
#   --maint           show the maintenance page during migrations (use for risky migrations)
#   --allow-dirty     deploy uncommitted changes (tag gets -dirty<timestamp>)
#   --allow-non-main  env prod only: deploy although HEAD is not exactly origin/main (emergency hotfix; warns and
#                     asks for confirmation — EDH_YES=1 only after the user agreed)
# env prod: refuses unless the current branch is main and HEAD equals origin/main (after git fetch origin main).
# Exit: 0 live · 1 on any failure (the message says whether the previous version is still serving).
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
# No container may mount the backups directory or the whole data directory: /data/backups holds the backup
# manifest, which restores trust because the app cannot reach it.
check_compose_mounts() {
  local q="'" hits
  hits=$(grep -v '^[[:space:]]*#' deploy/compose.yml | grep -nE \
    -e "(^|[[:space:]\"$q-])/data/?[\"$q]?:" \
    -e '\$\{EDH_DATA_DIR[^}]*\}/?["'"$q"']?:' \
    -e '(/data|\})/backups' \
    -e "source:[[:space:]]*[\"$q]?(/data|\\\$\\{EDH_DATA_DIR[^}]*\\})/?[\"$q]?[[:space:]]*\$" || true)
  [[ -z "$hits" ]] || die "deploy/compose.yml mounts the data directory or /data/backups into a container — refusing: that would put the backup manifest within the app's reach. Mount only subdirectories such as \${EDH_DATA_DIR:-/data}/caddy:
$hits"
}
# check_prod_source — prod runs only what is on GitHub main: the current branch is main and HEAD is exactly
# origin/main (catches "forgot to pull", unpushed commits and the wrong branch). --allow-non-main deploys anyway,
# after a prominent warning and a confirmation.
check_prod_source() {
  local branch head subject origin counts ahead behind why fix
  branch=$(git symbolic-ref --short -q HEAD || true)
  head=$(git rev-parse --short=12 HEAD) || die "cannot read HEAD"
  subject=$(git log -1 --format=%s HEAD)
  if ! git fetch origin main --quiet; then
    why="could not fetch main from origin, so it cannot be checked that this is what GitHub main holds"
    fix="check 'git remote -v', your network and your GitHub access, then deploy again"
  elif ! origin=$(git rev-parse -q --verify 'FETCH_HEAD^{commit}'); then
    why="git fetch origin main returned no commit"
    fix="check 'git remote -v' and that origin has a main branch"
  elif [[ -z "$branch" ]]; then
    why="detached HEAD (not on a branch)"
    fix="git checkout main && git pull"
  elif [[ "$branch" != main ]]; then
    why="on branch '$branch', not main"
    fix="git checkout main && git pull (merge the work into main on GitHub first)"
  else
    counts=$(git rev-list --left-right --count "HEAD...$origin") || die "cannot compare HEAD with origin/main"
    ahead=$(printf '%s' "$counts" | cut -f1); behind=$(printf '%s' "$counts" | cut -f2)
    if (( ahead > 0 && behind > 0 )); then
      why="local main and origin/main have diverged ($ahead local commit(s) not on origin/main, $behind on origin/main not here)"
      fix="git pull --rebase, then git push (or reconcile by hand)"
    elif (( behind > 0 )); then
      why="local main is $behind commit(s) behind origin/main"
      fix="git pull"
    elif (( ahead > 0 )); then
      why="local main has $ahead commit(s) that are not on origin/main (unpushed)"
      fix="git push (through your usual review), then deploy again"
    else
      return 0
    fi
  fi
  if (( ! NON_MAIN_OK )); then
    die "prod deploys must be exactly origin/main: $why.
  Fix: $fix
  (Emergency hotfix only, and only if the user asks: deploy.sh --allow-non-main)"
  fi
  printf '\n\033[1;41;37m EMERGENCY DEPLOY TO PROD — NOT origin/main \033[0m\n' >&2
  warn "$why"
  warn "deploying branch '${branch:-detached HEAD}' at $head \"$subject\" to $EDH_NAME"
  warn "the next normal deploy from main replaces it: merge this fix into main on GitHub"
  confirm "Deploy branch '${branch:-detached HEAD}' at $head (not origin/main) to PROD $EDH_NAME?"
}

# Nor may a container get at the host itself: the root directory, the Docker socket, paths with "..", privileged
# mode, or the host's process or network namespace. A best-effort lint of the file as written (values hidden in
# variables are not resolved), not a sandbox.
check_compose_host_access() {
  local q="'" hits
  hits=$(grep -v '^[[:space:]]*#' deploy/compose.yml | grep -nE \
    -e "(^|[[:space:]\"$q-])/[\"$q]?:" \
    -e "source:[[:space:]]*[\"$q]?/[\"$q]?[[:space:]]*(#.*)?\$" \
    -e 'docker\.sock' \
    -e '(\.\./|/\.\.([/"'"$q"':[:space:]]|$)|(^|[[:space:]"'"$q"'])\.\.["'"$q"']?(:|[[:space:]]*$))' \
    -e "^[[:space:]]*privileged:[[:space:]]*[\"$q]?([Tt]rue|TRUE|[Yy]es|YES|on|ON)" \
    -e "^[[:space:]]*(pid|network_mode):[[:space:]]*[\"$q]?host" || true)
  [[ -z "$hits" ]] || die "deploy/compose.yml gives a container access to the server itself — refusing. Not allowed: mounting / or the Docker socket, paths containing '..', privileged: true, pid: host, network_mode: host (see references/app-contract.md):
$hits"
}
check_compose_mounts
check_compose_host_access
SHA=$(git rev-parse --short=12 HEAD) || die "not a git repository (run from the project root)"
if [[ -n "$(git status --porcelain)" ]]; then
  (( DIRTY_OK )) || die "uncommitted changes — commit first, or pass --allow-dirty"
  SHA="${SHA}-dirty$(date +%s)"
fi
[[ "$SHA" =~ ^[0-9a-f]+(-dirty[0-9]+)?$ ]] || die "unexpected commit id: '$SHA'"   # goes into the remote script
if [[ "$EDH_ENV" == prod ]]; then check_prod_source; fi
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
aws s3 cp s3://$BUCKET/_edh/bundles/$SHA.tgz - --region $EDH_REGION | tar xz --no-same-owner -C \"\$R\"
ls -1dt /opt/edh/releases/* | tail -n +6 | xargs -r rm -rf
bash \"\$R/host/edh-deploy.sh\" \"\$R\" $IMAGE $MAINT" || rc=$?
case $rc in
  0) ;;
  1) die "deploy stopped before the swap — the previous version is still serving (see the output above)" ;;
  2) die "new version failed its health check — rolled back to the previous version" ;;
  3) die "deploy failed and no healthy version is running — the site may be down; run status.sh" ;;
  124) die "the deploy is still running on the server after the timeout — run status.sh to see how it ended" ;;
  *) die "deploy failed (exit $rc) — the site may be down; run status.sh" ;;
esac

log "4/4 verify https://$EDH_DOMAIN/health"
if curl -fsS --max-time 15 "https://$EDH_DOMAIN/health" >/dev/null; then ok "live: https://$EDH_DOMAIN ($SHA)"
else warn "deployed, but https://$EDH_DOMAIN/health failed from here — check DNS/TLS with status.sh"; fi
