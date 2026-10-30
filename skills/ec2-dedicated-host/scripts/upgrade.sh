#!/usr/bin/env bash
# upgrade.sh os [--reboot]   snapshot /data → apt upgrade → (optional) reboot → health check
# The pre-upgrade snapshot is kept until you delete it by hand.
# Service image upgrades (postgres/caddy/gotenberg): edit deploy/compose.yml tags and run deploy.sh — see references/upgrades.md.
# EDH_REBOOT_POLL_SECONDS overrides the 5 s poll while waiting for the server after a reboot (tests).
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config
require_account
require_instance
[[ "${1:-}" == os && ( -z "${2:-}" || "${2:-}" == --reboot ) ]] || die "usage: upgrade.sh os [--reboot]"
REBOOT=0; if [[ "${2:-}" == --reboot ]]; then REBOOT=1; require_python; fi
HEALTH='. /opt/edh/bin/edh-lib.sh; cd /opt/edh/app && docker compose up -d && wait_health 60'
find_data_volume
q="Upgrade OS packages on $EDH_NAME"; if (( REBOOT )); then q="$q and reboot if needed (1-2 min offline)"; fi
confirm "$q?"
snap=$(awsr ec2 create-snapshot --volume-id "$EDH_VOL_ID" --description "$EDH_PREFIX pre-upgrade $(date +%F)" \
  --tag-specifications "$(tag_spec snapshot "${EDH_PREFIX}-pre-upgrade")" --query SnapshotId --output text)
[[ -n "$snap" && "$snap" != None ]] || die "could not take the safety snapshot — nothing upgraded"
ok "safety snapshot $snap (kept until you delete it by hand)"

# ping_epoch <LastPingDateTime> — seconds since the epoch (0 if unreadable)
ping_epoch() {
  python3 -I -c 'import datetime, sys
try:
    print(int(datetime.datetime.fromisoformat(sys.argv[1]).timestamp()))
except ValueError:
    print(0)' "$1"
}
# wait_back <epoch> — after the reboot: SSM must report the server down (anything but Online) and Online again,
# or Online with a ping newer than <epoch> (a quick reboot may never show as down between two polls)
wait_back() {
  local t0="$1" down=0 info st ping _
  for _ in $(seq 1 180); do
    sleep "${EDH_REBOOT_POLL_SECONDS:-5}"
    info=$(awsr ssm describe-instance-information --filters "Key=InstanceIds,Values=$EDH_IID" \
      --query 'InstanceInformationList[0].[PingStatus,LastPingDateTime]' --output text 2>/dev/null || true)
    st=$(printf '%s' "$info" | cut -f1); ping=$(printf '%s' "$info" | cut -f2)
    if [[ "$st" != Online ]]; then down=1; continue; fi
    if (( down )) || (( $(ping_epoch "$ping") > t0 )); then return 0; fi
  done
  die "the server did not come back on SSM within 15 min of the reboot — check it in the EC2 console (safety snapshot $snap)"
}

# DPkg::Lock::Timeout: unattended-upgrades may hold the dpkg lock; --with-new-pkgs: upgrades that need a new
# dependency are installed too, instead of being held back
out=$(ssm_run "$EDH_IID" 1800 'export DEBIAN_FRONTEND=noninteractive; apt-get -o DPkg::Lock::Timeout=600 update -q && apt-get -o DPkg::Lock::Timeout=600 -y -q -o Dpkg::Options::=--force-confold --with-new-pkgs upgrade >/dev/null && { [ -f /var/run/reboot-required ] && echo REBOOT-NEEDED || echo NO-REBOOT; }') \
  || { printf '%s\n' "$out"; die "the OS upgrade failed (safety snapshot $snap) — see the output above"; }
echo "$out"
if printf '%s\n' "$out" | grep -qx REBOOT-NEEDED && (( REBOOT )); then
  ssm_run "$EDH_IID" 60 'nohup sh -c "sleep 3; systemctl reboot" >/dev/null 2>&1 &' || true
  # a ping is "after the reboot" only if newer than this: the reboot starts 3 s after the command
  wait_back $(( $(date +%s) + 10 ))
  ssm_run "$EDH_IID" 300 "$HEALTH" || die "rebooted, but the app is not healthy — run status.sh (safety snapshot $snap)"
  ok "rebooted and healthy"
else
  if printf '%s\n' "$out" | grep -qx REBOOT-NEEDED; then warn "a reboot is needed to finish — run: upgrade.sh os --reboot (at a quiet time)"; fi
  # packages such as docker.io restart services when upgraded: check the app is still serving
  ssm_run "$EDH_IID" 300 "$HEALTH" || die "upgraded, but the app is not healthy — run status.sh (safety snapshot $snap)"
  ok "upgraded and healthy"
fi
log "the safety snapshot $snap is kept until you delete it by hand"
