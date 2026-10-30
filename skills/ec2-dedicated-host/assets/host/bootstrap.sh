#!/bin/bash
# cloud-init user-data for an ec2-dedicated-host server (Ubuntu 24.04 arm64). Rendered by provision.sh.
# Installs Docker + AWS CLI, mounts the data volume at /data (formats only a blank device), adds 1 GB swap.
# Ends with /var/lib/edh/bootstrap-done, or /var/lib/edh/bootstrap-failed on any failure (provision.sh waits
# for one of the two). Log: /var/log/edh-bootstrap.log
set -euxo pipefail
exec > >(tee -a /var/log/edh-bootstrap.log) 2>&1
# EXIT, not only ERR: the explicit `exit 1` refusals below must leave the marker too
trap 'rc=$?; if [ "$rc" -ne 0 ]; then mkdir -p /var/lib/edh; touch /var/lib/edh/bootstrap-failed; fi' EXIT
VOLUME_ID="__VOLUME_ID__"
export DEBIAN_FRONTEND=noninteractive

# The host scripts need python3, flock (util-linux), timeout (coreutils), curl and docker compose >= 2.30.
# On first boot cloud-init / unattended-upgrades may hold the dpkg lock, and snapd may still be seeding.
apt-get -o DPkg::Lock::Timeout=600 update
apt-get -o DPkg::Lock::Timeout=600 install -y docker.io docker-compose-v2 unattended-upgrades python3 util-linux coreutils curl
snap wait system seed.loaded
snap install aws-cli --classic

# compose.yml uses env_file `format: raw`, which needs Docker Compose 2.30 or later.
need=2.30
have=$(docker compose version --short)
have="${have#v}"
lowest=$(printf '%s\n%s\n' "$need" "$have" | sort -V)
if [[ "${lowest%%$'\n'*}" != "$need" ]]; then
  echo "docker compose $have is too old: ec2-dedicated-host needs $need or later (env_file format: raw)"
  exit 1
fi

# Security updates install automatically; reboots only happen through upgrade.sh.
echo 'Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/52edh-unattended

# Data volume: wait for the attachment, format only a blank device, mount by UUID with nofail.
DEV="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOLUME_ID//-/}"
for _ in $(seq 1 120); do [ -e "$DEV" ] && break; sleep 5; done
[ -e "$DEV" ] || { echo "data volume $VOLUME_ID never attached"; exit 1; }
# blkid -p: 0 = has a filesystem/signature, 2 = nothing found, anything else = probe error. Format only when
# nothing was found AND the first 1 MiB is all zeros; never on a probe error.
rc=0; blkid -p "$DEV" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ] && [ -z "$(head -c 1048576 "$DEV" | tr -d '\0' | head -c 1)" ]; then mkfs.ext4 -L edh-data "$DEV"
elif [ "$rc" -ne 0 ]; then echo "refusing to format $DEV (blkid rc=$rc, not blank)"; exit 1
fi
UUID=$(blkid -s UUID -o value "$DEV")
mkdir -p /data
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /data ext4 defaults,nofail,x-systemd.device-timeout=30s 0 2" >> /etc/fstab
mount -a
mountpoint -q /data
# postgres/ must be 0755: the container's postgres user traverses it (PGDATA below it is 0700, set by the image);
# a root-owned 0700 directory stops Postgres 18 from starting.
install -d -m 755 /data/postgres
install -d -m 755 /data/caddy /data/maint
install -d -m 700 /data/backups   # database dumps are owner-only

# Docker must never start without /data (nofail lets the boot continue without it): otherwise compose would
# create empty bind-mount directories on the root disk and Postgres would init a fresh, empty database there.
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/edh-data.conf <<'UNIT'
[Unit]
RequiresMountsFor=/data
UNIT
cat > /etc/docker/daemon.json <<'JSON'
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" }, "live-restore": true }
JSON
systemctl daemon-reload
systemctl restart docker

if [ ! -f /swapfile ]; then
  fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

mkdir -p /var/lib/edh && touch /var/lib/edh/bootstrap-done
