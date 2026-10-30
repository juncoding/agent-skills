#!/usr/bin/env bash
# init.sh --client NAME --domain FQDN [--emails a@x,b@y] [--env prod] [--region R] [--account-id 123456789012]
#         [--monitoring cloudwatch|none] [--gotenberg] [--no-instance-role] [--app-memory MB] [--app-port N]
#         [--migrate "CMD"]
# Scaffold deploy/ (deploy.yml, compose.yml, Caddyfile, maint pages, OPERATIONS.md) in the current project.
# Never overwrites.
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

client="" domain="" emails="" env=prod region=ap-southeast-1 acct="" monitoring=cloudwatch got=false mem=768 port=3000 migrate="" role=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gotenberg) got=true; shift; continue ;;
    --no-instance-role) role=false; shift; continue ;;
    --client|--domain|--emails|--env|--region|--account-id|--monitoring|--app-memory|--app-port|--migrate)
      [[ $# -ge 2 ]] || die "$1 needs a value" ;;
    *) die "unknown option: $1" ;;
  esac
  case "$1" in
    --client) client="$2" ;;       --domain) domain="$2" ;;
    --emails) emails="$2" ;;       --env) env="$2" ;;
    --region) region="$2" ;;       --account-id) acct="$2" ;;
    --monitoring) monitoring="$2" ;; --app-memory) mem="$2" ;;
    --app-port) port="$2" ;;       --migrate) migrate="$2" ;;
  esac
  shift 2
done
A="$EDH_SKILL_DIR/assets/project"
for f in deploy.yml compose.yml Caddyfile maint/maintenance.html maint/down.html OPERATIONS.md; do
  [[ ! -e "deploy/$f" ]] || die "deploy/$f already exists — edit it instead"
done

# esc <value> — safe as sed replacement text with # as the delimiter
esc() { printf '%s' "$1" | sed -e 's/[\\&#]/\\&/g'; }
tmp=$(mktemp); at_exit 'rm -f "$tmp"'
args=(-e "s#^client: .*#client: $(esc "$client")#" -e "s#^env: .*#env: $(esc "$env")#"
      -e "s#^region: .*#region: $(esc "$region")#" -e "s#^domain: .*#domain: $(esc "$domain")#"
      -e "s#^alert_emails: .*#alert_emails: $(esc "$emails")#" -e "s#^monitoring: .*#monitoring: $(esc "$monitoring")#"
      -e "s#^uses_gotenberg: .*#uses_gotenberg: $got#" -e "s#^app_uses_instance_role: .*#app_uses_instance_role: $role#"
      -e "s#^app_memory_mb: .*#app_memory_mb: $(esc "$mem")#"
      -e "s#^app_port: .*#app_port: $(esc "$port")#" -e "s#^migrate_cmd: .*#migrate_cmd: \"$(esc "$migrate")\"#")
if [[ -n "$acct" ]]; then args+=(-e "s#^account_id: .*#account_id: \"$(esc "$acct")\"#"); fi
sed "${args[@]}" "$A/deploy.yml" > "$tmp"
load_config "$tmp"   # validate before anything is created
mkdir -p deploy/maint
cp "$tmp" deploy/deploy.yml
cp "$A/compose.yml" "$A/Caddyfile" deploy/
cp "$A/maint/"*.html deploy/maint/
cp "$A/OPERATIONS.md" deploy/OPERATIONS.md   # the operations log (see oplog in lib.sh)
ok "created deploy/ for $EDH_NAME ($domain)"
