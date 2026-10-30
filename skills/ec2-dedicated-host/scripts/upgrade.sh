#!/usr/bin/env bash
# upgrade.sh os [--reboot]   snapshot /data → apt upgrade → (optional) reboot → health check
# Service image upgrades (postgres/caddy/gotenberg): edit deploy/compose.yml tags and run deploy.sh — see references/upgrades.md.
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config
require_account
require_instance
[[ "${1:-}" == os && ( -z "${2:-}" || "${2:-}" == --reboot ) ]] || die "usage: upgrade.sh os [--reboot]"
REBOOT=0; if [[ "${2:-}" == --reboot ]]; then REBOOT=1; fi
find_data_volume
q="Upgrade OS packages on $EDH_NAME"; if (( REBOOT )); then q="$q and reboot if needed (1-2 min offline)"; fi
confirm "$q?"
snap=$(awsr ec2 create-snapshot --volume-id "$EDH_VOL_ID" --description "$EDH_PREFIX pre-upgrade $(date +%F)" \
  --tag-specifications "$(tag_spec snapshot "${EDH_PREFIX}-pre-upgrade")" --query SnapshotId --output text)
[[ -n "$snap" && "$snap" != None ]] || die "could not take the safety snapshot — nothing upgraded"
ok "safety snapshot $snap"
# DPkg::Lock::Timeout: unattended-upgrades may hold the dpkg lock
out=$(ssm_run "$EDH_IID" 1800 'export DEBIAN_FRONTEND=noninteractive; apt-get -o DPkg::Lock::Timeout=600 update -q && apt-get -o DPkg::Lock::Timeout=600 -y -q -o Dpkg::Options::=--force-confold upgrade >/dev/null && { [ -f /var/run/reboot-required ] && echo REBOOT-NEEDED || echo NO-REBOOT; }') \
  || { printf '%s\n' "$out"; die "the OS upgrade failed (safety snapshot $snap) — see the output above"; }
echo "$out"
if [[ "$out" == *REBOOT-NEEDED* ]]; then
  if (( REBOOT )); then
    ssm_run "$EDH_IID" 60 'nohup sh -c "sleep 3; systemctl reboot" >/dev/null 2>&1 &' || true
    sleep 45; wait_ssm "$EDH_IID"
    ssm_run "$EDH_IID" 300 '. /opt/edh/bin/edh-lib.sh; cd /opt/edh/app && docker compose up -d && wait_health 60' \
      || die "rebooted, but the app is not healthy — run status.sh"
    ok "rebooted and healthy"
  else warn "a reboot is needed to finish — run: upgrade.sh os --reboot (at a quiet time)"; fi
fi
