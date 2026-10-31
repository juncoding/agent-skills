# ec2-dedicated-host — design

Date: 2026-10-30
Status: implemented; validated live on AWS 2026-10-31 (see Validation results)

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
| CPU / credits | > 80 % for 15 min, or t4g surplus credits charged (see Validation results) |
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

Live run on 2026-10-31 in ap-southeast-1: a throwaway project (`client: edhtest`, `env: prod`, t4g.small)
with a small Node app whose `/health` queries Postgres. A local bare git repository stood in for
GitHub, so the prod "must equal origin/main" rule applied as normal.

### Bugs found and fixed (each with a failing test first)

1. **A new data volume was never formatted** (provisioning failed on every new server). A freshly
   created encrypted gp3 volume returned non-zero bytes, so the bootstrap's "first 1 MiB is all zeros"
   check refused it. Now provision tags a volume it creates `edh:fs=new`, and only for that volume
   the bootstrap formats when `blkid` finds no signature. Every other volume still needs the all-zeros
   check. After a successful bootstrap the tag becomes `edh:fs=ext4`. (`fd73e57`)
2. **False CPU-credit alarm on every new server.** A t4g in unlimited mode starts with 0 credits, so
   `cpu-credits-low` (balance < 50) fired at once, and a low balance doesn't throttle in unlimited
   mode anyway. It was replaced by `cpu-surplus-charged` (`CPUSurplusCreditsCharged` > 0 in 1 h), which
   fires only when AWS actually bills the surplus. (`00b01a1`)
3. **status-check flapped.** With 1-minute periods, one late datapoint counted as breaching. Missing
   data now keeps the state; a dead server still trips site-down. (`00b01a1`)
4. **Output noise that would confuse the operator or the agent:**
   - the JSON results of `put-bucket-lifecycle-configuration` and `delete-security-group`
   - SSM's `failed to run commands: exit status 1` on every not-yet-done bootstrap poll
   - systemd's `Created symlink` from the agent install
   - `restore --check` echoing a bare table count
   - a psql `NOTICE`
   - teardown running `amazon-cloudwatch-agent-ctl` on a server without the agent
   - teardown telling the user to redeploy a server it was removing

   (`fd73e57`, `6fe4f86`, `2f3e694`)

### Main checklist

| # | Check | Result |
|---|---|---|
| 1 | init → plan → `--apply`: SSM online, `/data` mounted, DLM policy, confirmation emails | ✅ after fix 1. Emails sent and status reported as pending until clicked |
| 2 | DNS, deploy, `https://<domain>/health` 200, valid certificate | ✅ Let's Encrypt certificate issued on the first deploy |
| 3 | `maint.sh on`: page, bypass link, site-down actions off; `off` | ✅ 503 page with the message, `/health` still 200, bypass sets a cookie (302), alarm actions false → true |
| 4 | Deploy with failing `/health`: exit 2 → rolled back, old version serving, alert | ✅ server exit 2, local "rolled back", site 200 throughout |
| 5 | `backup.sh now`, `list`, `restore.sh db --latest --check` | ✅ verified against the manifest (sha256 + VersionId), live data untouched |
| 6 | `monitoring.sh status`; CWAgent disk dimensions match the alarms | ✅ `InstanceId`, `path`, `fstype=ext4` in `CWAgent/<name>` |
| 7 | Stop the app: site-down alarm, then recovery | ✅ ALARM after ~3.2 min, OK ~4 min after restart (docs said ~2 min, now corrected) |
| 8 | `resize.sh disk 25`, `status.sh` | ✅ online grow, 25 GB visible |
| 9 | `teardown.sh`, then manual cleanup | ✅ (twice, with `--keep-ip`) |

### Items the stubs couldn't prove

| # | Item | Result |
|---|---|---|
| 1 | `s3:if-none-match` | ✅ PUT without the header is AccessDenied, with it OK, and a repeat returns 412 PreconditionFailed. Delete is denied |
| 2 | `s3:ResourceAccount` | ✅ no unexpected denies in any run |
| 3 | Generated secrets are 40 characters | ✅ |
| 4 | Another client's SSM parameter, from the host and from the app container | ✅ AccessDenied from both. `/aws/service/*` resolves; SSM and Run Command work |
| 5 | Ubuntu 24.04 `docker-compose-v2` ≥ 2.30 | ✅ 2.40.3 |
| 6 | snap AWS CLI: `--if-none-match`, `/snap/bin` on PATH for systemd and SSM | ✅ the hourly timer uploaded and published BackupFresh |
| 7 | `/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol…` on t4g | ✅ |
| 8 | `head-bucket` error text | ✅ `(404)` for a missing bucket, `(403)` for a foreign one |
| 9 | DLM policy: cron and tag keys with a colon | ✅ accepted. Snapshot creation (daily 18:30 UTC) falls outside the test window, not observed |
| 10 | `run-instances` right after `create-instance-profile` | ✅ |
| 11 | Hop limit 1 vs 2 | ✅ hop 1: the app's SDK gets `CredentialsProviderError`. Hop 2: an S3 round trip works |
| 12 | A replacement server reuses the data volume without reformatting | ✅ teardown then provision: no mkfs, earlier rows intact |
| 13 | Metric namespaces | ✅ the host may write only `EDH/<name>` and `CWAgent/<name>`. `CWAgent`, `EDH/<other>` and `CWAgent/<other>` are denied |
| 14 | Lifecycle configurations accepted | ✅ six rules on backups, noncurrent rule on uploads |
| 15 | Boot without the data volume: Docker stays down | ✅ docker inactive, `/data` empty, nothing on the root disk |
| 16, 20 | `restore.sh disk --snapshot` | ✅ swap, remount, Docker back, `/health` 200. A row added after the snapshot is gone. The old volume is kept as `data-replaced-<date>`. The new volume keeps `edh:snapshot`, so DLM still covers it |
| 17 | Forced bootstrap failure | ✅ (real, see fix 1) `bootstrap-failed` marker. Provision failed on the first poll. dpkg lock and snap seed waits fine on first boot |
| 18 | `describe-instance-types` arm64, default subnets | ✅ |
| 19 | `upgrade.sh os --reboot` | ✅ no reboot when none is needed. With `/var/run/reboot-required` present: rebooted, detected, healthy |
| 21 | Rebuild after teardown, `--keep-ip` | ✅ same IP reused, DNS unchanged |
| 22 | App SDK uses the injected `AWS_REGION` and `EDH_UPLOADS_BUCKET` with the role | ✅ |
| 23 | `docker compose config --format json` and a pinned caddy for `caddy validate` | ✅ (every deploy validated) |
| 24 | SNS `PendingConfirmation` reporting | ✅ in both regions. Unsubscribing a removed address was not exercised live (stub-tested) |
| 25 | Route 53 health check | ✅ HTTPS, 30 s, failure threshold 3, no latency measurement (standard pricing) |
| 26 | `memory.peak` path | ✅ `/sys/fs/cgroup/system.slice/docker-<id>.scope/memory.peak` |
| 27 | Bypass link without a TTY | prints the link on stdout (the operator needs it). Treat it as a secret in shared output |
| 28 | Missing backup key under the no-ListBucket policy | ✅ S3 answers 403, as designed |
| 29 | Server-side compose check under `env -i` | ✅ `config --variables` works locally and on Ubuntu, so no fallback scan was needed |
| 30 | Ownership checks on later deploys | ✅ (five deploys) |
| 31 | OPERATIONS.md: one line per command | ✅ including a failed provision, a failed build and a rolled-back deploy |

### Observations (not bugs)

- Teardown deletes the SNS topics, so a rebuild sends new confirmation emails, and the old
  confirmations no longer apply.
- On a new server, `site-down` and `backup-stale` are in ALARM until the first deploy and the first
  hourly backup after it. `monitoring.sh add` now says so.
- The deploy output includes Docker's "credentials are stored unencrypted" warning from `docker login`
  on the server. That 12-hour ECR token sits in `/root/.docker/config.json`.
- Not verified by email in this run: alert emails need the subscription confirmed by the recipient.

## Out of scope (for now)

- Alert channels other than email (Telegram, Slack).
- Zero-downtime blue/green deploys.
- Continuous WAL archiving / point-in-time recovery.
- Multi-AZ or managed RDS.
- Netdata or other dashboards.
- CI builds (planned as a later add-on).
