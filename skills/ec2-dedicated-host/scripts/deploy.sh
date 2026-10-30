#!/usr/bin/env bash
# deploy.sh [--maint] [--allow-dirty]
# Build the current commit for arm64, push to ECR, ship deploy/ + host scripts, roll out via SSM.
#   --maint        show the maintenance page during migrations (use for risky migrations)
#   --allow-dirty  deploy uncommitted changes (tag gets -dirty<timestamp>)
# Exit: 0 live · 1 on any failure (the message says whether the previous version is still serving).
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
MAINT=""; DIRTY_OK=0
for a in "$@"; do case "$a" in --maint) MAINT=--maint ;; --allow-dirty) DIRTY_OK=1 ;; *) die "unknown option: $a" ;; esac; done
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
check_compose_mounts
ACCT=$(aws_account)
require_instance
REG="${ACCT}.dkr.ecr.${EDH_REGION}.amazonaws.com"
BUCKET="${EDH_PREFIX}-backups-${ACCT}"
SHA=$(git rev-parse --short=12 HEAD)
if [[ -n "$(git status --porcelain)" ]]; then
  (( DIRTY_OK )) || die "uncommitted changes — commit first, or pass --allow-dirty"
  SHA="${SHA}-dirty$(date +%s)"
fi
[[ "$SHA" =~ ^[0-9a-f]+(-dirty[0-9]+)?$ ]] || die "unexpected commit id: '$SHA'"   # goes into the remote script
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
