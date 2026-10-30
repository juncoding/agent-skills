---
name: ec2-dedicated-host
description: >-
  Run one client's web app on its own dedicated AWS EC2 server with Docker — create the server, deploy,
  maintenance page, backups and restore, monitoring, resizing and OS upgrades. Use when the user says
  "deploy", "deploy to prod", "ship it", "push this live" or "put this on its own server" in a project that
  has (or should get) a deploy/deploy.yml; or wants to put the site into maintenance, take, list or restore
  a backup, roll back, check server status, set app secrets, resize the server or disk, add or remove
  monitoring/alerts, upgrade the OS, or tear the server down. One server per client: Caddy (auto-HTTPS) +
  app + Postgres (+ optional Gotenberg) in one Compose project, data on its own EBS volume, no SSH (SSM
  only). NOT for many apps sharing one server (use ec2-docker-host), ECS/EKS/Fargate, Vercel, Kubernetes
  or local development.
---

# EC2 dedicated host — one client, one server

**Prime directive: never lose client data.** The server is disposable; the data volume, the backup bucket
and the uploads bucket are tagged `Protect=true`, and nothing in this skill deletes them. Scripts that change
something check the AWS account first, explain what they will do, and refuse rather than guess.

## How it fits together

```
 Operator's Mac (this skill's scripts/, bash 3.2)                 AWS account (one per deploy.yml account_id)
 ─────────────────────────────────────────────────                ──────────────────────────────────────────
 deploy/deploy.yml ──► provision.sh ──► IAM role, SG, buckets, ECR repo, data volume, Elastic IP, server, DLM
 git HEAD (prod: = origin/main) ──► deploy.sh ──► docker buildx (arm64) ──► ECR  edh/<client>
                                        └─► bundle (deploy/ + host scripts) ──► S3 backups bucket _edh/bundles/
                                        └─► SSM Run Command (no SSH, port 22 closed) ──┐
                                                                                       ▼
   Internet :80/:443 ──► ┌──────────────── EC2 t4g (Ubuntu 24.04 arm64) ── edh-<client>-<env> ────────┐
                         │  caddy (auto-HTTPS, maintenance + down pages, bypass cookie)              │
                         │    └─► app (your image, PORT=app_port, env from SSM)                      │
                         │          ├─► postgres 18 (database "app")                                 │
                         │          └─► gotenberg (only if uses_gotenberg)                           │
                         │  systemd timers: edh-backup (hourly) · edh-drill (monthly restore test)   │
                         └───────────────┬───────────────────────────────────────────────────────────┘
                                         │ /data — separate encrypted EBS volume, Protect=true
                                         │   postgres/  caddy/ (certs)  maint/  backups/ (dumps + manifest)
                                         ├─► DLM snapshots: 7 daily + 4 weekly
                                         └─► S3 edh-<client>-<env>-backups-<account> (write-once dumps)
 Optional monitoring: CloudWatch alarms + Route 53 health check ──► SNS ──► email
```

## Commands

Run from the **project root** (the directory holding `deploy/`): `bash <this-skill>/scripts/<script> …`.

| User says | Run | Key flags / notes |
|---|---|---|
| "set this up" (first time) | `init.sh --client acme --domain app.example.com --emails ops@example.com --account-id 123456789012` | also `--env`, `--region`, `--gotenberg`, `--app-memory MB`, `--app-port N`, `--migrate "CMD"`, `--monitoring none`, `--no-instance-role`. Never overwrites `deploy/`. |
| "create the server" | `provision.sh` (plan) → `provision.sh --apply` | plan is read-only; `--apply` only after the user approved the plan + cost |
| "deploy" / "deploy to prod" | `deploy.sh` | `--maint` (maintenance page during migrations), `--allow-dirty`, `--allow-non-main` (prod emergency only) |
| "roll back" | `rollback.sh` | previous image + its env; database untouched; run again to roll forward. Asks first. |
| "maintenance on/off" | `maint.sh on --message "…" --until "23:00"` / `off` / `status` | `--no-link` hides the bypass link; `rotate-bypass` makes a new token (applied by the next deploy) |
| "back up now" / "list backups" | `backup.sh now` / `backup.sh list [N]` | `now` writes to `db/daily/` |
| "restore" | `restore.sh db --latest\|--date YYYY-MM-DD\|--key db/… [--check]` | `--check` = side database, live data untouched. Without it: replaces live DB (asks first). `--unverified` only with `--key`. |
| "restore the disk" | `restore.sh disk --snapshot snap-…` | app offline minutes; `--foreign-snapshot` for an untagged snapshot. Asks first. |
| "status" | `status.sh` | read-only: server, DNS, site, firing alarms, containers, backups, disk, memory |
| "set a secret" | `printf '%s' "$VALUE" \| secrets.sh set NAME` · `secrets.sh list` · `secrets.sh delete NAME` | value via stdin only; redeploy to apply |
| "monitoring" | `monitoring.sh add` / `remove` / `status` | email alerts via SNS; `remove` asks first |
| "resize" | `resize.sh instance t4g.large` / `resize.sh disk 40` | instance: 3–5 min offline; disk: online, grow only. Ask first. |
| "upgrade the OS" | `upgrade.sh os [--reboot]` | snapshot first; reboots only with `--reboot`. Ask first. |
| "tear down" | `EDH_CONFIRM_NAME=acme-prod teardown.sh` | removes server + plumbing; keeps volume, buckets, ECR, secrets, snapshots |

`EDH_YES=1` answers the scripts' `[y/N]` prompts. Set it **only after the user agreed in chat** to that exact
action. `teardown.sh` ignores it and needs `EDH_CONFIRM_NAME=<client>-<env>` (or typing the name).

## First deploy (the conversation)

1. **Read the project** first: Dockerfile? a `/health` that queries the database? migrations (Prisma,
   TypeORM, Knex…)? PDFs (→ Gotenberg)? memory needs? (`references/app-contract.md`)
2. **Ask once**, in one message, only for what's missing: client name (lowercase, e.g. `acme`), domain
   (`app.example.com`), alert email(s). Region defaults to `ap-southeast-1`. Ask for the AWS account id to
   pin (or read it with `aws sts get-caller-identity` and confirm it with the user).
3. **`init.sh`** with those values (+ `--gotenberg`, `--app-memory`, `--migrate` as the project needs). It
   validates everything and writes `deploy/deploy.yml`, `compose.yml`, `Caddyfile`, `maint/*.html`.
4. **Check the app contract** and fix gaps now: arm64-buildable Dockerfile, listens on `$PORT`, DB-aware
   `GET /health`, backward-compatible migrations. Commit `deploy/` and the fixes, push to `main`.
5. **`provision.sh`** (plan only — it changes nothing). Show the user the plan and the monthly cost
   (`references/provisioning.md`, `references/sizing.md`). **On approval only:** `EDH_YES=1 provision.sh --apply`.
   Expect two AWS confirmation emails per alert address (two SNS topics) — tell the user to click both.
6. **Secrets:** ask the user for each app secret; set it with `secrets.sh set NAME` reading from stdin
   (`printf '%s' "$V" | …` or let the user type it at the prompt). Never echo values back or put them in a
   command line, a file in the repo, or chat output.
7. **DNS:** tell the user to create an A record `app.example.com → <Elastic IP>` (printed by provision).
   Wait until `dig +short app.example.com` returns it — HTTPS certificates need it.
8. **`deploy.sh`**, then **`status.sh`**. Give the user the URL, and mention the maintenance bypass link
   (`references/maintenance.md`) and the monthly restore drill.

## Routine "deploy to prod"

Run `deploy.sh` without asking: it builds the current commit, ships, migrates, health-checks and rolls
back on its own. Before anything is built, for `env: prod` it runs `git fetch origin main` and **refuses
unless the current branch is `main` and HEAD is exactly `origin/main`** (tree clean too):

| Refusal says | Tell the user / do |
|---|---|
| `… N commit(s) behind origin/main` | "Your local main is behind GitHub" → `git pull`, then deploy again |
| `… commit(s) that are not on origin/main (unpushed)` | push (through their review process), then deploy |
| `on branch 'x', not main` / `detached HEAD` | `git checkout main && git pull`; get the work merged first |
| `… have diverged` | reconcile (`git pull --rebase`, push) — ask the user |
| `could not fetch main from origin` | network/remote problem; fix it, don't bypass it |
| `uncommitted changes` | commit (and push) first; `--allow-dirty` only if the user explicitly wants it |

**`--allow-non-main` is for emergencies only** (a hotfix branch while main is broken), and only when the
user asks for it. It prints a red EMERGENCY warning naming the branch, commit and subject and asks for
confirmation (`EDH_YES=1` only after the user said yes). Remind them to merge the fix into main — the next
normal deploy replaces it. Non-prod envs (`env: staging` …) skip the origin/main check.

Every deploy prints the commit being deployed (`deploying <sha> "<subject>"`). Use `--maint` when a
migration is risky or slow: users see the maintenance page while it runs.

## Exit codes and what to tell the user

Every local script exits **0** on success and **1** on any failure, with an `ERROR:` line that says what
happened. Read it; don't retry blindly.

| Script / message | Meaning → what to say |
|---|---|
| deploy: `deploy stopped before the swap — the previous version is still serving` | Nothing changed for users. Show the cause (build, compose/Caddyfile invalid, migrations, backup). |
| deploy: `new version failed its health check — rolled back to the previous version` | Site is up on the old version; an alert email went out. Look at app logs/`/health`; fix, commit, redeploy. |
| deploy: `no healthy version is running — the site may be down` | **Urgent.** Run `status.sh`; see `references/disaster-runbook.md`. |
| deploy/rollback: `still running on the server after the timeout` | Not necessarily failed: run `status.sh` to see how it ended. |
| deploy: compose refusal (`backup manifest` / `access to the server itself`) | `deploy/compose.yml` breaks the rules in `references/app-contract.md`; fix the file. |
| rollback: `previous version is unhealthy … stayed on the current version` | Nothing changed; the old image can't run with today's DB/config. |
| restore: `not in this server's backup manifest` | Possible tampering, or the manifest was lost — read `references/backup-restore.md` before `--unverified`. |
| restore disk: `swap stopped half way` (with commands) | Relay the printed state and put-back commands; ask before running them. |
| any: `AWS credentials are for account X but deploy.yml says Y` | Wrong AWS profile; switch profile, never edit `account_id` to match. |
| any: `refusing: … Protect=true` | By design. Data resources are deleted only by hand, by the user. |
| any: `aborted` | The prompt wasn't confirmed; nothing happened. |

On the server, `edh-deploy.sh` itself exits 0 deployed · 1 failed before the swap · 2 rolled back · 3 no
healthy version; `deploy.sh` turns those into the messages above.

## Safety rules

- **Never delete** anything tagged `Protect=true` (data volume, backup and uploads buckets) and never
  delete snapshots, ECR images or SSM parameters on the user's behalf. Teardown keeps them on purpose.
- **Ask first** (show what will happen, wait for a yes) before: provisioning (`--apply`), `resize.sh`,
  any `restore.sh` without `--check`, `upgrade.sh os --reboot` (and any OS upgrade), `rollback.sh`,
  `monitoring.sh remove`, `teardown.sh`, `secrets.sh delete`, and `deploy.sh --allow-non-main`.
  Routine deploys, `status.sh`, `backup.sh`, `restore.sh … --check` and `maint.sh` on the user's request
  run without asking.
- `EDH_YES=1` / `EDH_CONFIRM_NAME` only after the user agreed **in this conversation** to that action.
- **Never print secrets**: no `docker inspect`, `env`, `printenv`, `cat app.env`, `secrets.sh` values, or
  the bypass token in shared output. Secrets go in via stdin only.
- **Pin `account_id`** in `deploy/deploy.yml` (`init.sh --account-id …`). Without it the scripts only
  warn; with it every mutating script refuses any other AWS account before touching anything.
- Local scripts must stay **bash 3.2** compatible (macOS): no `mapfile`, associative arrays, `${x,,}`.
  If you change a script, run `bash tests/ec2-dedicated-host/run.sh --fast`.
- If something fails, run `status.sh` and read `references/disaster-runbook.md` before anything
  destructive. Prefer `restore.sh db … --check` before a real restore.

## Costs (ap-southeast-1, on demand, approximate — check current AWS pricing)

| Item | Per month |
|---|---|
| Server: t4g.small / medium / large / xlarge | ~$15 / ~$31 / ~$62 / ~$124 |
| Fixed: Elastic IP, 20 GB root + 20 GB data gp3, snapshots, S3 backups | ~$8 |
| Monitoring module (alarms + Route 53 health check) | ~$4 |

t4g runs in **unlimited** CPU-credit mode (the AWS default, left as is): sustained high CPU costs extra
rather than throttling — the `cpu-credits-low` alarm says when to move up (`references/sizing.md`).

## References

| File | Read when |
|---|---|
| `references/provisioning.md` | creating the server: what gets made, names, tags, IAM isolation, costs |
| `references/app-contract.md` | before the first deploy; compose-file rules; secrets → env; health examples |
| `references/maintenance.md` | maintenance window, bypass link, customizing pages |
| `references/backup-restore.md` | backups, retention, restores, `--unverified`, monthly drill, server gone |
| `references/monitoring.md` | alarms, thresholds, alert emails, add/remove |
| `references/sizing.md` | choosing or changing the server/disk size |
| `references/upgrades.md` | OS patches, Postgres/Caddy/Gotenberg upgrades |
| `references/disaster-runbook.md` | something is broken |
