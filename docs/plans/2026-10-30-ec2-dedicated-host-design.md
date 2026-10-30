# ec2-dedicated-host — design

Date: 2026-10-30
Status: design validated, not yet implemented

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
- ~1 GB base (OS, Caddy, Postgres)
- plus measured app memory
- plus 1 GB if Gotenberg is used

Choose the smallest instance that keeps ≥ 40 % headroom:

| Need | Instance |
|---|---|
| ≤ 1.2 GB | t4g.small |
| ≤ 2.4 GB | t4g.medium |
| ≤ 4.8 GB | t4g.large |

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

1. Deploy a test app to a fresh t4g.small with the skill.
2. Exercise everything:
   - maintenance on/off and the bypass cookie
   - a failing deploy with automatic rollback
   - `restore db --check` and a real restore
   - a server rebuild from the data volume
   - alert delivery
3. Tear down the test server (data volume deleted explicitly).
4. Migrate the first real client.

## Out of scope (for now)

- Alert channels other than email (Telegram, Slack).
- Zero-downtime blue/green deploys.
- Continuous WAL archiving / point-in-time recovery.
- Multi-AZ or managed RDS.
- Netdata or other dashboards.
- CI builds (planned as a later add-on).
