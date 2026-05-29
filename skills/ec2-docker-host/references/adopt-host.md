# Adopting an existing host

Use this the first time you touch a host — whether it's one this skill provisioned, or someone else's
box that already has apps running. The goal is to build an accurate picture of what's there **before**
you change anything, so a later deploy slots in without collisions. Adoption is read-only.

## What to get from the user

You need just enough to connect and to know the conventions:

- **How to reach it**: an instance ID *or* a public IP/hostname, plus the SSH user (often `ubuntu` or
  `ec2-user`) and the path to the private key. From an instance ID you can resolve the public IP with
  `aws ec2 describe-instances --instance-ids <id> --query 'Reservations[].Instances[].PublicIpAddress'`.
- **Region** (if using any AWS CLI calls).
- Optionally, where they keep connection config (`assets/host.example.yml` shows the shape). If they
  don't have one, offer to create it after discovery so next time is a one-liner.

If they only give an instance ID, that's fine — resolve the rest. Confirm you can SSH in before going
further; a failed connection now saves a confusing failure mid-deploy.

## A cheap safety net first: snapshot the volumes

On a box you didn't build and don't fully understand, take an **EBS snapshot of its attached volume(s)
before you make any change** — it's cheap insurance and the thing people skip and regret. The snapshot
is a background AWS operation that does **not** touch or interrupt the running workload (so it's safe to
do during discovery), and it gives you a clean rollback point if a later change goes wrong.

```bash
# find the volumes attached to the instance, then snapshot each
aws ec2 describe-instances --instance-ids <id> --region <region> \
  --query 'Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId' --output text
aws ec2 create-snapshot --volume-id <vol-id> --region <region> \
  --description "pre-adoption $(date -u +%Y%m%dT%H%M%SZ)" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=purpose,Value=pre-adoption}]'
```

This is only needed once, at adoption time. A host this skill provisioned already has scheduled volume
snapshots (see `references/backups-and-maintenance.md`); an inherited box may have none, which is exactly
why you take one now.

## Run discovery

```bash
scripts/discover-host.sh <ssh-target>
```

It reports, all read-only:

- **Running containers** — names, images, status, and **published host ports**. This is your port map.
- **Docker networks** — is there a shared bridge (`infra_net` or similar) that apps join?
- **Shared backing services** — is there a `postgres` / `mongo` / `redis` container, and on what
  internal/host ports? Are there per-app databases already?
- **The reverse proxy** — Caddy (systemd or container)? nginx? Traefik? none? Where's its config? Which
  vhosts/domains are already served?
- **`/data` (or equivalent persistent volume)** — is there a dedicated data volume, how full is it, what
  lives under it (db data, certs, backups, secrets)?
- **Backups** — any backup cron, any dump files, any off-host sync configured?

## Turn the inventory into a conformance read

Compare what you found to the model in `SKILL.md`. Three outcomes:

1. **Conforms** — shared network, shared DBs bound to localhost, a reverse proxy with additive vhosts,
   a data volume. Great: you can deploy with the standard flow. Record the conventions you observed
   (network name, proxy type + config path, port scheme in use, DB container name) so the deploy step
   uses the right names.

2. **Partially conforms** — e.g. apps are running but there's no shared network, or the proxy is nginx
   instead of Caddy, or there's no separate data volume. You can still deploy; adapt the approach to what
   exists (join/extend the existing network, add an nginx server block instead of a Caddy vhost) rather
   than imposing a parallel stack. Note the deltas for the user — they may want to converge later.

3. **Empty / fresh** — Docker installed but nothing meaningful running, or Docker not installed at all.
   This is effectively greenfield-on-an-existing-instance: bring up the shared stack and proxy per
   `references/provision-host.md` (skip the instance-creation steps), then deploy.

## The cardinal rule of adoption

**Anything you don't recognize is a neighbor until proven otherwise.** An unfamiliar container, a port
you didn't expect, a vhost for a domain you don't know — treat it as someone's running workload and do
not stop, remove, restart, or reconfigure it. If your plan would touch it, stop and ask the user. The
whole value of this skill is adding to a host without disturbing what's there; adoption is where you earn
that by looking before you leap.

## Hand off to deploy

Once you have a clean inventory and know the conventions, proceed to `references/deploy-project.md`. Carry
forward: the network name, the proxy type + config location, the DB container name + how to create a DB
on it, the set of host ports already in use (so allocation avoids them), and the secret backend in use.
