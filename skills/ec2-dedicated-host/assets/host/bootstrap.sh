#!/bin/bash
# cloud-init user-data for an ec2-dedicated-host server (Ubuntu 24.04 arm64). Rendered by provision.sh.
# Installs Docker + AWS CLI, mounts the data volume at /data (formats only if blank), adds 1 GB swap.
set -euxo pipefail
exec > >(tee -a /var/log/edh-bootstrap.log) 2>&1
VOLUME_ID="__VOLUME_ID__"
export DEBIAN_FRONTEND=noninteractive

# The host scripts need python3, flock (util-linux), timeout (coreutils), curl and docker compose >= 2.30.
apt-get update
apt-get install -y docker.io docker-compose-v2 unattended-upgrades python3 util-linux coreutils curl
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

cat > /etc/docker/daemon.json <<'JSON'
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" }, "live-restore": true }
JSON
systemctl restart docker

# Security updates install automatically; reboots only happen through upgrade.sh.
echo 'Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/52edh-unattended

# Data volume: wait for the attachment, format only when blank, mount by UUID with nofail.
DEV="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOLUME_ID//-/}"
for _ in $(seq 1 120); do [ -e "$DEV" ] && break; sleep 5; done
[ -e "$DEV" ] || { echo "data volume $VOLUME_ID never attached"; exit 1; }
blkid "$DEV" >/dev/null 2>&1 || mkfs.ext4 -L edh-data "$DEV"
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

if [ ! -f /swapfile ]; then
  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

mkdir -p /var/lib/edh && touch /var/lib/edh/bootstrap-done
