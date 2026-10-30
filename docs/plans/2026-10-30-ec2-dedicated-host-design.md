# ec2-dedicated-host — design

Date: 2026-10-30
Status: implemented; live AWS validation pending

## Purpose

A skill for running **one client's system on one dedicated EC2 server**, from first
creation through continuous deployment, maintenance, backup, restore and monitoring.
Sibling of `ec2-docker-host`, which runs many apps on one shared server.

Target experience: inside a project, the user says "deploy". The skill asks only for
missing parameters (client name, domain, alert emails), sizes the server from the
project, creates everything on the first run, and does an image swap with health check
and rollback on every later run.

## Decisions

| Topic | Decision |
|---|---|
| Provisioning | Idempotent AWS CLI scripts bundled with the skill; resources discovered by tag (`Client=<name>`). No Terraform. |
| Isolation | Same AWS account, one IAM role per server scoped to that client's SSM path, buckets and ECR repo. Separate accounts remain a later option. |
| Shell access | SSM Session Manager / Run Command. No SSH keys, port 22 closed. |
| Maintenance page | Caddy, flag-file toggle, secret bypass cookie (see below). |
| User files | Per-client S3 uploads bucket (versioned). Not on the server disk. |
| Backups | Hourly `pg_dump` while DB < ~2 GB, nightly above that; plus DLM snapshots of `/data`. |
| Monitoring | Optional module, default `cloudwatch`, can be added/removed later. Email only. No Netdata. |
| Image builds | Local build on the user's Mac (native arm64), push to ECR. CI (GitHub Actions + OIDC) can be added later. |
| Server family | Graviton (arm64). t4g by default; suggest m8g when CPU credits keep running out. |

## Server layout

```
Internet :80/:443
   │
 Caddy (container, auto-HTTPS, maintenance + down pages)
   │
 app container(s)  ── postgres ── gotenberg (only if the app uses it)
   │
 /data  (separate EBS volume)
```

One `docker compose` project per server: `caddy`, `app`, `postgres`, plus optional
services the app needs. `docker compose up -d` brings the whole system up.

### Disks

- **Root (20 GB gp3), disposable.** OS, Docker, images, logs. Rebuildable from git + bootstrap.
- **Data (`/data`, gp3, starts at 20 GB), protected.**
  - `postgres/`, `caddy/` (certs), `maint/` (pages + ON flag), `backups/` (last 3 days).
  - DeleteOnTermination=false, tag `Protect=true` (scripts refuse to delete), encrypted,
    mounted by UUID with `nofail`, grown online by `resize disk`.
- Image pruning after each deploy (keep last 3); container logs capped 3 × 10 MB.
- Rebuild: new server in the same AZ, attach the data volume, `compose up`.

## Maintenance page

```caddy
{$DOMAIN} {
    encode zstd gzip

    @maint {
        file { root /srv/maint
               try_files ON }
        not header Cookie *maint_bypass={$MAINT_BYPASS}*
        not path /health
    }
    handle @maint {
        root * /srv/maint
        rewrite * /maintenance.html
        header Retry-After 1800
        file_server { status 503 }
    }

    handle {
        reverse_proxy app:3000
    }

    handle_errors 502 503 504 {
        root * /srv/maint
        rewrite * /down.html
        file_server { status 503 }
    }
}
```

- `maintenance on --message ... --until ...` renders the page, creates `ON`, pauses the uptime alarm.
- `maintenance off` removes `ON`, re-enables the alarm.
- Bypass: a secret link sets the `maint_bypass` cookie.
- Pages live in the project (`deploy/maint/`) so each client has its own branding.
- Unplanned downtime (crash, restart, deploy swap) is covered by `down.html` automatically.
- Limitation: during `resize` (instance stopped) nothing can serve the page.

## Backup and recovery

| Layer | What | Retention |
|---|---|---|
| DB dumps | `pg_dump -Fc` of the client DB to the client's backup bucket, one object per dump (no sync) | Daily 90 days (Glacier IR after 30), monthly 1 year |
| Snapshots | DLM policy on `/data` | 7 daily + 4 weekly |
| Uploads | S3 versioning | Noncurrent versions 30 days |
| Config | Git | Forever |

- The server role can `PutObject` but not delete; only lifecycle rules expire backups.
- Each successful backup publishes a CloudWatch metric; missing for 2 h triggers an alert.
- Commands:
  - `restore db --date D --check` restores into a side database for inspection.
  - `restore db --date D` runs maintenance on, safety dump, restore, health check, maintenance off.
  - `restore disk --snapshot ID` replaces the data volume from a snapshot.
- Monthly automatic restore drill into a throwaway container; failure alerts.

## Monitoring (optional module)

`deploy.yml: monitoring: cloudwatch | none`, with `monitoring add|remove`.

| Check | Alert when |
|---|---|
| Route 53 health check on `https://<domain>/health` (DB-aware) | 3 consecutive failures |
| EC2 status checks | Fail (plus built-in automatic recovery) |
| Disk `/` and `/data` (CloudWatch agent) | > 80 % warn, > 90 % critical |
| Memory | > 90 % for 10 min |
| CPU / credits | > 80 % for 15 min, or t4g credit balance low |
| Backup freshness | No success for 2 h |

- Delivered to an SNS topic `<client>-alerts`, email subscriptions, OK notifications on recovery.
- Roughly $4 per client per month.
- With `monitoring: none`, `status` still flags stale backups.

## Deploy flow

1. Build an arm64 image tagged with the git SHA; push to the client's ECR repo.
2. Pre-deploy dump.
3. Run migrations in a one-off container; maintenance on if the migration is marked risky.
4. `compose up -d app`; wait up to 60 s for `/health`.
5. On failure: restart the previous image and alert. Migrations are not auto-reverted, so
   apps must use backward-compatible migrations; the pre-deploy dump is the escape hatch
   (restored only after asking).
6. Prune to the last 3 images, append to the deploy log.

## Upgrades

- OS: unattended security updates with no auto-reboot; `upgrade os` = snapshot, upgrade, reboot.
- Service images are pinned. `upgrade services` handles minor versions; a major Postgres
  version is a guided dump/restore under maintenance.
- `resize` stops and starts the instance (3–5 minutes of downtime, keeps the Elastic IP).

## Sizing

Estimated need is:
- 768 MB base (OS, Caddy, Postgres)
- plus measured app memory
- plus 900 MB if Gotenberg is used

Choose the smallest instance that keeps ≥ 40 % headroom (need ≤ 60 % of RAM):

| Need | Instance |
|---|---|
| ≤ 1228 MB | t4g.small |
| ≤ 2457 MB | t4g.medium |
| ≤ 4915 MB | t4g.large |
| ≤ 9830 MB | t4g.xlarge |

## App contract

- `GET /health` returns 200 only when the database answers.
- A migration command runnable in a one-off container.
- Config from environment; secrets from SSM `/<client>/prod/*`.
- arm64 image.

## Per-project files

```
deploy/
  deploy.yml      client, domain, region, alert_emails, instance_type (auto), monitoring
  compose.yml
  Caddyfile
  maint/          maintenance.html, down.html
```

## Skill layout

```
skills/ec2-dedicated-host/
  SKILL.md
  references/  provisioning, app-contract, maintenance, backup-restore, monitoring,
               sizing, upgrades, disaster-runbook
  scripts/     provision, deploy, rollback, maint, backup, restore, status, resize,
               upgrade, monitoring, lib
  assets/      compose + Caddyfile templates, maint pages, bootstrap (cloud-init),
               IAM policies, CloudWatch agent config, DLM policy
  evals/
```

## Safety rules

- Never delete resources tagged `Protect=true` (data volume, backup and uploads buckets).
- Show the plan and ask before:
  - first provisioning
  - `resize`
  - restore
  - a major upgrade
  - `monitoring remove`

  Routine deploys run without asking.
- One IAM role per server, least privilege.
- No secrets in git or in container command lines (pass them via env/files, not `docker inspect`-visible CLI args).

## Validation plan

The code is covered by stub-AWS unit tests and Docker integration tests
(`bash tests/ec2-dedicated-host/run.sh`). Live validation on AWS is still pending: follow **Task 20 in
`2026-10-30-ec2-dedicated-host.md`** — the end-to-end run (provision, deploy, maintenance and bypass, failing
deploy with rollback, backup and restore, monitoring and alert delivery, resize, teardown) plus the list of
AWS behaviours the stubs cannot prove (S3 conditional-write policy, SSM isolation, IMDS hop limits, DLM
policy, device paths, …). Record the findings below under "Validation results", then migrate the first
real client.

## Deviations from design

Building and reviewing the skill hardened it well beyond the design. The important differences:

- **Commands.** Scripts are `init`, `provision` (plan by default, `--apply`), `deploy`, `rollback`, `maint`,
  `backup`, `restore`, `status`, `secrets`, `monitoring`, `resize`, `upgrade`, `teardown`. There is no
  `upgrade services`: service images are upgraded by changing the pinned tag in `deploy/compose.yml` and
  deploying (`references/upgrades.md`). `teardown` (server removed, data kept) is new.
- **Naming and discovery.** Every AWS name starts with `edh-<client>-<env>`; resources are found by the
  `edh:client` / `edh:env` tags (plus `edh:role=data` for the volume). The ECR repo `edh/<client>` is shared by
  a client's envs. The SNS topic is `edh-<client>-<env>-alerts`, in the app region and in us-east-1.
- **Account pinning.** `deploy.yml` `account_id`: every mutating script refuses other AWS accounts before any
  other call.
- **Provisioning.** Read-only preflight before any change (bucket ownership, arm64 support, AZ offering,
  duplicate resources); never creates an empty data volume for an existing server; termination protection;
  bootstrap formats only a provably blank device, makes Docker require the `/data` mount, and leaves a
  success/failure marker that provisioning waits for.
- **Per-client IAM isolation.** An explicit Deny on reading any other SSM parameters; metrics only into
  `EDH/<client>-<env>` (host) and `CWAgent/<client>-<env>` (agent, inline policy instead of the managed
  agent policy); `s3:ResourceAccount` and `--expected-bucket-owner` on every bucket access.
  `app_uses_instance_role` chooses IMDS hop limit 2 (app may use the role, for S3 uploads) or 1.
- **Backups.** Uploads are write-once (`If-None-Match`); the host can't overwrite or delete. Every upload is
  recorded in a host-only manifest (key, sha256, S3 VersionId) that no container may mount (enforced by
  `deploy.sh`), and restores fetch exactly that version and check the hash. `--latest`/`--date` are resolved
  from the manifest; `--unverified` (manifest lost) needs an explicit `--key` and sends an alert. Retention:
  hourly 3 days, daily 90 days, monthly 365 days (Glacier IR after 30), safety dumps 30 days; the newest 24
  dumps are also kept locally. The freshness alarm uses a `BackupFresh` heartbeat tied to the last successful
  upload. The monthly drill restores into a side database (not a throwaway container).
- **Restore.** A real database restore loads into a new database while the app serves, then swaps names
  under maintenance and keeps the previous data (`app_pre_restore`). `restore disk` accepts only this
  project's snapshots (`--foreign-snapshot` to override) and prints exact recovery steps if interrupted.
- **Deploy.** The release's compose file and Caddyfile are validated on the server before anything is
  installed (the Caddyfile with the caddy image the release pins); the previous configuration — env files,
  `compose.yml`, Caddyfile, and the Caddy/Postgres containers — is restored on any abort before the switch,
  failed migrations included; rollback restores the env the old image ran with. The app gets `AWS_REGION`,
  `EDH_UPLOADS_BUCKET` and (with Gotenberg) `GOTENBERG_URL` unless it sets them itself. `deploy.sh` refuses compose files that expose `/data`, `/data/backups`, `/`, the Docker socket,
  `..` paths, privileged mode, capabilities, devices, host namespaces, unknown variables, `build:` or the
  skill's own files — one check (`edh-compose-check.py`) on Compose's own normalized config, run on the Mac
  before building and again on the server with the real values before installing.
  **Prod deploys must be exactly `origin/<prod_branch>`** (default `main`) with a clean tree
  (`--allow-non-main` for emergencies, with a warning and confirmation). An aborted deploy also restores
  `/etc/edh/edh.env`; a failed first deploy reports that nothing was serving.
- **Maintenance.** Exact bypass-cookie match, `/health` always reaches the app, `rotate-bypass`, the link goes
  to the terminal rather than logs; `deploy --maint` for risky migrations.
- **Monitoring.** Email subscriptions follow `alert_emails` (removed confirmed addresses are unsubscribed,
  pending ones reported). Route 53 health checks are tracked by tags (including `ManagedBy`), replaced safely
  on a domain change; the CPU-credit alarm exists only on t-family servers. No EC2 auto-recovery action is
  configured by the skill. Known limitation: the CloudWatch agent package's signature is not verified.
- **Secrets** are read from stdin and passed to AWS through 0600 temp files, never on a command line; the
  user enters them with `!`-prefixed commands so values never enter the chat.
- **Operations log** (new): `deploy/OPERATIONS.md`, created by `init.sh`, gets one line per mutating command
  (result and key detail, never secret values) plus human/agent notes; read before any operations work.
- **Teardown** releases the Elastic IP (a rebuilt server gets a new IP; DNS must be updated) unless
  `--keep-ip`.
- **IAM trims.** The host can read backups only by key/version (no `s3:ListBucket`); the agent policy has
  only `ec2:DescribeTags` besides its namespace.
- **Upgrades / resize.** `upgrade os` snapshots first and detects the reboot from SSM ping times; `resize`
  checks arm64 support and AZ availability before stopping and returns to the old type if the new one won't
  start.

## Validation results

Pending (Task 20).

## Out of scope (for now)

- Alert channels other than email (Telegram, Slack).
- Zero-downtime blue/green deploys.
- Continuous WAL archiving / point-in-time recovery.
- Multi-AZ or managed RDS.
- Netdata or other dashboards.
- CI builds (planned as a later add-on).
