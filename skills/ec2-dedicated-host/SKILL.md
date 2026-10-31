---
name: ec2-dedicated-host
description: >-
  Run one client's web app on its own dedicated AWS EC2 server with Docker — create the server, deploy,
  maintenance page, backups and restore, monitoring, resizing and OS upgrades. Use in a project whose
  deploy/deploy.yml was made by this skill's init.sh (it has client: and domain: keys) when the user says
  "deploy", "deploy to prod", "ship it" or "push this live", or wants maintenance mode, a backup or
  restore, a rollback, server status, app secrets, a resize, monitoring/alerts, an OS upgrade or a teardown;
  or when the user wants a client or app on its own NEW EC2 server. One server per client: Caddy
  (auto-HTTPS) + app + Postgres (+ optional Gotenberg) in one Compose project, data on its own EBS volume,
  no SSH (SSM only). If the user names an existing shared server (IP, SSH target or instance ID), use
  ec2-docker-host instead. NOT for many apps sharing one server (ec2-docker-host), ECS/EKS/Fargate,
  Vercel, Kubernetes or local development.
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

## Operations log: `deploy/OPERATIONS.md`

**Before any DevOps work on a project, read `deploy/OPERATIONS.md`**: earlier decisions, incidents and every
command that changed the server, with its result. Every mutating command appends one line under `## Log`
automatically (success or failure; plan and read-only runs don't; secret *names* only, never values or the
bypass token). **After anything notable** — an incident, a decision, a one-off operation done by hand — add a
dated note under `## Notes` (e.g. `- 2026-10-31 — restored orders from the 18:00 backup after a bad import`).
The skill never commits or pushes the file: suggest the user commit it. It doesn't count as a dirty tree for
deploys. `init.sh` creates it; an older project gets it on the first logged command.

## Commands

Run from the **project root** (the directory holding `deploy/`): `bash <this-skill>/scripts/<script> …`.

| User says | Run | Key flags / notes |
|---|---|---|
| "set this up" (first time) | `init.sh --client acme --domain app.example.com --emails ops@example.com --account-id 123456789012` | also `--env`, `--region`, `--gotenberg`, `--app-memory MB`, `--app-port N`, `--migrate "CMD"`, `--monitoring none`, `--no-instance-role`, `--release-flow tags` (releases by v* tag, below). Never overwrites `deploy/`. |
| "create the server" | `provision.sh` (plan) → `provision.sh --apply` | plan is read-only; `--apply` only after the user approved the plan + cost |
| "deploy" / "deploy to prod" | `deploy.sh` | `--maint` (maintenance page during migrations), `--allow-dirty` (in prod only with `--allow-non-main`), `--allow-non-main` (prod emergency only) |
| "release v1.2.3" (only with `release_flow: tags`) | `release.sh v1.2.3` | `--maint`. Fast-forwards the release branch to the tag, then deploys it. `references/releases.md` |
| "roll back" | `rollback.sh` | previous image + its env; database untouched; run again to roll forward. Asks first. |
| "maintenance on/off" | `maint.sh on --message "…" --until "23:00"` / `off` / `status` | `--no-link` hides the bypass link; `rotate-bypass` makes a new token (applied by the next deploy) |
| "back up now" / "list backups" | `backup.sh now` / `backup.sh list [N]` | `now` writes to `db/daily/` |
| "restore" | `restore.sh db --latest\|--date YYYY-MM-DD\|--key db/… [--check]` | `--check` = side database, live data untouched. Without it: replaces live DB (asks first). `--unverified` only with `--key`. |
| "restore the disk" | `restore.sh disk --snapshot snap-…` | app offline minutes; `--foreign-snapshot` for an untagged snapshot. Asks first. |
| "connect to the database" / "run X against prod's DB" | `db.sh tunnel [--port N] [-- command]` | SSM port-forward to Postgres on localhost (default 15432); the command gets `DATABASE_URL` (password read from SSM, never shown). Needs the Session Manager plugin (`brew install --cask session-manager-plugin`). The command keeps the terminal: if it asks for a typed confirmation, the user runs it in their own terminal (`! …` in Claude Code may have no interactive prompt) |
| "status" | `status.sh` | read-only: server, DNS, site, firing alarms, containers, backups, disk, memory |
| "set a secret" | the user runs `! pbpaste \| bash <this-skill>/scripts/secrets.sh set NAME` · `secrets.sh list` · `secrets.sh delete NAME` | value via the prompt/stdin only, never in chat or argv. The NAME is stored and logged in plain text — never pass a value as the name. Redeploy to apply |
| "monitoring" | `monitoring.sh add` / `remove` / `status` | email alerts via SNS; `remove` asks first |
| "resize" | `resize.sh instance t4g.large` / `resize.sh disk 40` | instance: 3–5 min offline; disk: online, grow only. Ask first. |
| "upgrade the OS" | `upgrade.sh os [--reboot]` | snapshot first; reboots only with `--reboot`. Ask first. |
| "tear down" | `EDH_CONFIRM_NAME=acme-prod teardown.sh [--keep-ip]` | removes server + plumbing; keeps volume, buckets, ECR, secrets, snapshots. Releases the Elastic IP (a rebuild gets a new IP → update DNS) unless `--keep-ip` |

`EDH_YES=1` answers the scripts' `[y/N]` prompts. Set it **only after the user agreed in chat** to that exact
action. `teardown.sh` ignores it and needs `EDH_CONFIRM_NAME=<client>-<env>` (or typing the name).

## First deploy (the conversation)

1. **Read the project** first: Dockerfile? a `/health` that queries the database? migrations (Prisma,
   TypeORM, Knex…)? PDFs (→ Gotenberg)? memory needs? (`references/app-contract.md`)
2. **Ask once**, in one message, only for what's missing: client name (lowercase, e.g. `acme`), domain
   (`app.example.com`), alert email(s). Region defaults to `ap-southeast-1`. Ask for the AWS account id to
   pin (or read it with `aws sts get-caller-identity` and confirm it with the user).
3. **`init.sh`** with those values (+ `--gotenberg`, `--app-memory`, `--migrate` as the project needs). It
   validates everything and writes `deploy/deploy.yml`, `compose.yml`, `Caddyfile`, `maint/*.html` and
   `OPERATIONS.md`.
4. **Check the app contract** and fix gaps now: arm64-buildable Dockerfile, listens on `$PORT`, DB-aware
   `GET /health`, backward-compatible migrations. Commit `deploy/` and the fixes; ask the user to push or
   merge them into `main` through their own review process (or push only if they ask you to).
5. **`provision.sh`** (plan only — it changes nothing). Show the user the plan and the monthly cost
   (`references/provisioning.md`, `references/sizing.md`). **On approval only:** `EDH_YES=1 provision.sh --apply`.
   Each alert address gets an AWS confirmation email per SNS topic — two when the region isn't us-east-1
   (one there for the site-down alarm) — tell the user to click every one.
6. **Secrets:** the user sets each one **themselves**, so values never enter the chat. In Claude Code they
   run it with the `!` prefix; as a `!` command may get no interactive prompt, piping from the clipboard is
   safest: copy the value, then `! pbpaste | bash <this-skill>/scripts/secrets.sh set NAME`. (In their own
   terminal, `bash <this-skill>/scripts/secrets.sh set NAME` prompts without echoing.) Only if the user has
   already pasted a value into the chat, pipe it with the shell builtin —
   `printf '%s' '<value>' | bash <this-skill>/scripts/secrets.sh set NAME` — never repeat it back, and never
   pass it as an argument to any other command.
7. **DNS:** tell the user to create an A record `app.example.com → <Elastic IP>` (printed by provision).
   Wait until `dig +short app.example.com` returns it — HTTPS certificates need it.
8. **`deploy.sh`**, then **`status.sh`**. Give the user the URL, and mention the maintenance bypass link
   (`references/maintenance.md`) and the monthly restore drill.

## Routine "deploy to prod"

Run `deploy.sh` without asking: it builds the current commit, ships, migrates, health-checks and rolls
back on its own. Before anything is built, for `env: prod` it runs `git fetch origin main` and **refuses
unless the current branch is `main`, HEAD is exactly `origin/main` and the working tree is clean**
(`prod_branch:` in deploy.yml names another branch than `main`; changes to `deploy/OPERATIONS.md` don't count):

| Refusal says | Tell the user / do |
|---|---|
| `… N commit(s) behind origin/main` | "Your local main is behind GitHub" → `git pull`, then deploy again |
| `… commit(s) that are not on origin/main (unpushed)` | ask the user to push/merge through their review, then deploy |
| `on branch 'x', not main` / `detached HEAD` | `git checkout main && git pull`; the work must be merged first (the user's review) |
| `… have diverged` | ask the user how to reconcile; don't push for them |
| `could not fetch main from origin` | network/remote problem; fix it, don't bypass it |
| `uncommitted changes` / `the working tree has uncommitted changes` | commit, and get it into main. In prod `--allow-dirty` works only together with `--allow-non-main` (emergency) |

**`--allow-non-main` is for emergencies only** (a hotfix branch while main is broken), and only when the
user asks for it (with uncommitted changes, also `--allow-dirty`). It prints a red EMERGENCY warning naming
the branch, commit and subject and asks for confirmation (`EDH_YES=1` only after the user said yes). Remind
them to get the fix into main through their review — the next normal deploy replaces it. Non-prod envs (`env: staging` …) skip the origin/main check.

**With `release_flow: tags`** (`references/releases.md`) the rules above don't apply: prod runs the release
branch (`prod_branch`, normally `release`), and "release v1.2.3" means `release.sh v1.2.3`. It refuses a tag
that isn't on origin or isn't on `origin/main`, never moves the release branch backwards and never
force-pushes; tell the user the refusal and its fix, don't work around it. `deploy.sh` then always builds
exactly `origin/<prod_branch>` from a clean temporary worktree — the operator's branch and uncommitted work
don't matter — and refuses unless that commit is on `origin/main` with a `v*` tag on origin (the tag becomes the app's `APP_VERSION`). Going back is `rollback.sh` or a new fix tag.

Every deploy prints the commit being deployed (`deploying <sha> "<subject>"`). Use `--maint` when a
migration is risky or slow: users see the maintenance page while it runs.

## Exit codes and what to tell the user

Every local script exits **0** on success and non-zero on failure: **1** with an `ERROR:` line for every
handled case, or the AWS CLI's own code (with its error text) for an unexpected AWS error. Read the
message; don't retry blindly.

| Script / message | Meaning → what to say |
|---|---|
| deploy: `deploy stopped before the swap — the previous version is still serving` | Nothing changed for users. Show the cause (build, compose/Caddyfile invalid, migrations, backup). |
| deploy: `new version failed its health check — rolled back to the previous version` | Site is up on the old version; an alert email went out. Look at app logs/`/health`; fix, commit, redeploy. |
| deploy: `no healthy version is running — the site may be down` | **Urgent.** Run `status.sh`; see `references/disaster-runbook.md`. |
| deploy/rollback: `still running on the server after the timeout` | Not necessarily failed: run `status.sh` to see how it ended. |
| deploy: compose refusal (`backup manifest` / `access to the server itself` / `breaks the compose rules`) | `deploy/compose.yml` breaks the rules in `references/app-contract.md` (checked on the Mac and again on the server); fix the file. |
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
  (Contributor note: the tests live only in the skill's source repository, not in an installed skill —
  there, run `bash tests/ec2-dedicated-host/run.sh --fast` after changing a script.)
- If something fails, run `status.sh` and read `references/disaster-runbook.md` before anything
  destructive. Prefer `restore.sh db … --check` before a real restore.

## Costs (ap-southeast-1, on demand, approximate — check current AWS pricing)

| Item | Per month |
|---|---|
| Server: t4g.small / medium / large / xlarge | ~$15 / ~$31 / ~$62 / ~$124 |
| Fixed: Elastic IP, 20 GB root + 20 GB data gp3, snapshots, S3 backups | ~$8 |
| Monitoring module (alarms + Route 53 health check) | ~$4 |

t4g runs in **unlimited** CPU-credit mode (the AWS default, left as is): sustained high CPU costs extra
rather than throttling — the `cpu-surplus-charged` alarm says when to move up (`references/sizing.md`).

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
