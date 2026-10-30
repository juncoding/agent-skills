#!/usr/bin/env bash
# resize.sh instance <type>   stop → change type → start (3-5 min downtime; Elastic IP and data kept)
# resize.sh disk <GB>         grow the data volume online (no downtime; AWS allows one change per 6 h)
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config
require_account
require_instance

# start_as <type> — set the (stopped) server's type and start it; returns non-zero if either step fails
start_as() {
  awsr ec2 modify-instance-attribute --instance-id "$EDH_IID" --instance-type "Value=$1" || return 1
  awsr ec2 start-instances --instance-ids "$EDH_IID" >/dev/null || return 1
  awsr ec2 wait instance-running --instance-ids "$EDH_IID"
}

case "${1:-}" in
  instance)
    new="${2:-}"; [[ "$new" =~ ^[a-z][a-z0-9-]*\.[a-z0-9]+$ ]] || die "usage: resize.sh instance <type> (e.g. t4g.large)"
    cur=$(awsr ec2 describe-instances --instance-ids "$EDH_IID" \
      --query 'Reservations[0].Instances[0].[InstanceType,Placement.AvailabilityZone]' --output text)
    az=$(printf '%s' "$cur" | cut -f2); cur=$(printf '%s' "$cur" | cut -f1)
    [[ "$cur" != "$new" ]] || die "already $new"
    # the images are built for arm64 (Graviton): ask EC2 rather than guess from the name
    arch=$(awsr ec2 describe-instance-types --instance-types "$new" \
      --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' --output text) || die "cannot describe instance type $new"
    [[ " $(printf '%s' "$arch" | tr '\t\n' '  ') " == *" arm64 "* ]] || die "$new does not support arm64 (it supports: $arch); the images are built for arm64"
    # the server can't move: the type must be offered in its availability zone
    offered=$(awsr ec2 describe-instance-type-offerings --location-type availability-zone \
      --filters "Name=instance-type,Values=$new" "Name=location,Values=$az" --query 'InstanceTypeOfferings[].Location' --output text) \
      || die "cannot list where $new is offered"
    [[ " $(printf '%s' "$offered" | tr '\t\n' '  ') " == *" $az "* ]] || die "$new is not offered in $az, where the server runs — choose another type"
    confirm "Stop $EDH_NAME (~3-5 min offline, no maintenance page possible) and change $cur → $new?"
    awsr ec2 stop-instances --instance-ids "$EDH_IID" >/dev/null
    awsr ec2 wait instance-stopped --instance-ids "$EDH_IID"
    if ! start_as "$new"; then
      warn "could not change to or start as $new: going back to $cur"
      # the type can only be changed while the server is stopped (a failed start may leave it pending or stopping)
      awsr ec2 wait instance-stopped --instance-ids "$EDH_IID" \
        || die "the server did not settle in the stopped state after the failed start as $new — check it in the EC2 console (it is $cur or $new)"
      start_as "$cur" || die "the server is STOPPED: it could not be started as $new nor as $cur — start it in the console"
      die "EC2 refused $new (type change or start, e.g. no capacity) — the server is back on $cur and running"
    fi
    wait_ssm "$EDH_IID"
    ssm_run "$EDH_IID" 300 '. /opt/edh/bin/edh-lib.sh; cd /opt/edh/app && docker compose up -d && wait_health 60' \
      || die "the server is now $new but the app is not healthy — run status.sh"
    ok "now $new — set instance_type: $new in deploy/deploy.yml"
    # the alarms depend on the type (the CPU credit alarm exists only for t-family servers): monitoring.sh add
    # re-creates them, and deletes a stale credit alarm
    if [[ "$EDH_MONITORING" == cloudwatch ]]; then "$(dirname "$0")/monitoring.sh" add; fi ;;
  disk)
    gb="${2:-}"; [[ "$gb" =~ ^[0-9]+$ ]] || die "usage: resize.sh disk <GB>"
    gb=$((10#$gb))
    find_data_volume
    id="$EDH_VOL_ID"
    size=$(awsr ec2 describe-volumes --volume-ids "$id" --query 'Volumes[0].Size' --output text)
    [[ "$size" =~ ^[0-9]+$ ]] || die "cannot read the size of $id"
    (( gb > size )) || die "new size must be larger than the current $size GB (volumes cannot shrink)"
    confirm "Grow data volume $id from $size GB to $gb GB?"
    awsr ec2 modify-volume --volume-id "$id" --size "$gb" >/dev/null
    st=""
    for _ in $(seq 1 60); do
      st=$(awsr ec2 describe-volumes-modifications --volume-ids "$id" --query 'VolumesModifications[0].ModificationState' --output text)
      if [[ "$st" == optimizing || "$st" == completed ]]; then break; fi
      sleep 5
    done
    [[ "$st" == optimizing || "$st" == completed ]] || die "the volume change is still '$st' after 5 min — once it is optimizing, grow the filesystem on the server: sudo resize2fs /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${id//-/}"
    ssm_run "$EDH_IID" 120 "resize2fs /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${id//-/} && df -h /data" \
      || die "the volume is $gb GB but growing the filesystem failed — see the output above"
    ok "data volume now $gb GB — set data_volume_gb: $gb in deploy/deploy.yml" ;;
  *) die "usage: resize.sh instance <type> | disk <GB>" ;;
esac
