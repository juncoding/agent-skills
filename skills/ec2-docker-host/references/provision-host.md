# Provisioning a new host (greenfield)

Stand up a fresh EC2 instance as a shared Docker platform. The path here uses the **AWS CLI** so it's
self-contained (no Terraform/state to manage); the steps are idempotent — re-running skips what already
exists. If the instance already exists but is bare, skip to "Bootstrap the host."

The crown-jewel safety property of provisioning is the **separate data volume**: app data must never
live on the root disk, so the instance can be rebuilt without losing databases. Build everything around
that.

## Decide the inputs first

- **Region** and **AZ** (the data volume and instance must share an AZ).
- **Instance type + architecture.** Arm (Graviton, e.g. `m8g`/`t4g`) is cheap and capable; if you pick
  arm, **all app images must be arm64** (see the contract). Pick the AMI to match (e.g. Ubuntu LTS arm64).
- **Root disk** size (small; OS only) and **data volume** size (sized for DB growth).
- **Operator IP/CIDR** for SSH access.
- **A stable hostname strategy** — you'll attach an Elastic IP and point DNS at it.

## 1. Networking + identity (one-time per account, reuse after)

- A **key pair** (or import your public key).
- A **security group** with exactly: inbound 22 from your operator CIDR only, 80 + 443 from anywhere,
  everything else denied. **Never open database ports** (5432/27017/6379) — the DBs bind to localhost
  and are reached over the Docker network, so they need no inbound rule. Egress open.
- An **IAM instance profile** if you'll use AWS-native secrets/registry (lets the box read SSM + pull
  from ECR without static keys). Skip for the lightweight path.

## 2. The data volume (the part that must outlive the instance)

Create a dedicated EBS volume in the instance's AZ and **enable deletion protection / termination
safety** on it (don't let it be deleted with the instance). Attach it at a stable device name. Do **not**
format it blindly on every run — format only if the volume is blank; this single check is what prevents a
re-provision from wiping data. The bootstrap script enforces "format only if no filesystem present."

## 3. The instance + Elastic IP

- Launch the instance into the security group with the instance profile and key pair, root volume sized
  small.
- Allocate and associate an **Elastic IP**. The EIP is the stable target everything points at — it
  survives stop/start and instance replacement, so DNS never has to change when you rebuild the box.
- Point DNS at the EIP: at minimum a **wildcard A record** (`*.example.com` → EIP) so future apps need
  no DNS change, plus an apex/`infra` record. (DNS provider is pluggable — Route 53 or any registrar.)

## 4. Bootstrap the host

Over SSH, idempotently:

1. System update, base packages, set the **timezone explicitly** (so cron and logs read in your local
   time; keep backup *filenames* in UTC to avoid DST ambiguity).
2. **Mount the data volume** at `/data` — format **only if blank**, add to `/etc/fstab` by UUID so it
   remounts on reboot.
3. Install **Docker Engine + compose plugin**; configure the daemon with **log rotation** (so logs can't
   fill the disk), `live-restore: true` (containers keep running across daemon restarts), and a fixed
   address pool. Add the SSH user to the `docker` group.
4. Create the **shared external network**: `docker network create infra_net`.
5. Create `/data` subdirectories: `postgres/ mongo/ redis/ caddy/ backups/ secrets/`.
6. Install the **reverse proxy** (Caddy as a host systemd service) with its certificate/state directory
   redirected onto `/data/caddy`, so TLS certs persist across rebuilds.
7. Host firewall (ufw/nftables) mirroring the security group as defense in depth.

## 5. Bring up the shared stack

Generate the shared-DB passwords **once** into `/data/secrets` (never commit them), then bring up a
single Compose project containing Postgres, Mongo, Redis — each **binding only to `127.0.0.1`**, each
bind-mounting its data dir under `/data`, all on `infra_net`. This stack is long-lived and is *not*
touched by app deploys.

## 6. Install backups

Set up the backup scripts + cron per `references/backups-and-maintenance.md` (nightly logical dumps,
volume snapshots, off-host sync). Do this at provision time, not "later" — an un-backed-up host is one
bad day from data loss. Then do one **restore drill** to prove the backups work.

## Verify

- `docker ps` shows postgres/mongo/redis healthy and the proxy answering on 80/443.
- The data volume is mounted at `/data` and in `/etc/fstab`.
- A throwaway request to the proxy gets a valid TLS cert for a test subdomain (proves DNS + Let's
  Encrypt + EIP all line up).
- Backups have run once and a restore drill succeeded.

After that, the host is ready and you onboard apps with `references/deploy-project.md`.
