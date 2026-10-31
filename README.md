# agent-skills

Open-source [agent skills](https://github.com/vercel-labs/skills) for shipping and operating real
infrastructure. Each skill is a self-contained `SKILL.md` plus the references, scripts, and templates an
agent needs to do the job well. They trigger on intent — you describe what you want, the relevant skill
fires.

Cross-agent (Claude Code, Cursor, Codex, OpenCode, …) via the `npx skills` CLI, and installable as a
full Claude Code plugin.

## Skills in this collection

| Skill | What it does |
|---|---|
| [`ec2-docker-host`](skills/ec2-docker-host/) | Run many independent apps side-by-side on **one AWS EC2 box** with Docker — a shared reverse proxy (Caddy + auto-TLS) and shared Postgres/Mongo/Redis, with each app getting its own container, host port, database, and secret namespace. Provision a new host, adopt an existing one, deploy a project (monorepo or polyrepo), and run backups — **without disturbing the apps already running there.** |
| [`ec2-dedicated-host`](skills/ec2-dedicated-host/) | Run **one client's web app on its own dedicated EC2 server** — from provisioning through deploy, maintenance page, backups and verified restores, monitoring, resizing and OS upgrades. Caddy + app + Postgres (+ optional Gotenberg) in one Compose project, data on a protected EBS volume, no SSH (SSM only), and prod deploys only from `origin/main` (or, opted in, from a release branch moved to `v*` tags). |

More to come.

### Which one?

| You have… | Use |
|---|---|
| One server you already run, several apps/clients sharing it, SSH access | `ec2-docker-host` |
| One client (or app) that should get its own server, created and operated end to end from the project's `deploy/` folder | `ec2-dedicated-host` |

Both are single-server Docker setups with Caddy; neither is for ECS/EKS/Fargate or Kubernetes.

### `ec2-docker-host` at a glance

Treats one EC2 instance as a small self-hosting platform. Four modes:

- **Provision** a new host from nothing (AWS CLI: instance, Elastic IP, security group, a dedicated data
  volume, Docker, the shared DB + proxy stack, backups).
- **Adopt** an existing host — read-only discovery first, then a conformance read, so you never overwrite
  a neighbor's workload.
- **Deploy** a project (monorepo or polyrepo) as its own isolated unit: unique host port, own Compose
  project, own database + role, own secret namespace, an additive proxy vhost, validate-then-reload.
- **Maintain** — logical DB dumps + volume snapshots + off-host sync, restore drills, deliberate upgrades.

Defaults are lightweight (any OCI registry + host-side env files); an AWS-native path (ECR + SSM +
GitHub OIDC) is documented as an opt-in upgrade.

### `ec2-dedicated-host` at a glance

One client, one server, everything driven from the project's `deploy/deploy.yml`:

- **Provision** with a read-only plan first (the agent states the monthly cost from the skill's
  provisioning reference), then `--apply`: IAM role scoped to that client,
  security group without SSH, backup + uploads buckets, ECR repo, an encrypted data volume, Elastic IP,
  snapshot policy. Idempotent and re-runnable; nothing tagged `Protect=true` is ever deleted.
- **Deploy** builds the current commit for arm64, ships it over SSM, takes a safety dump, runs migrations,
  health-checks and **rolls back automatically**. Prod deploys refuse anything but exactly `origin/main` — or, with `release_flow: tags`, `release.sh vX.Y.Z` fast-forwards a release branch to a tag on main and deploys exactly that commit.
- **Maintain**: a branded maintenance page with a bypass link, rollback, secrets from SSM via stdin,
  resizing, OS upgrades with a safety snapshot.
- **Backups you can trust**: hourly/daily/monthly `pg_dump` to write-once S3, daily/weekly volume snapshots,
  restores verified against a host-only manifest (S3 VersionId + sha256), a monthly automatic restore drill.
- **Monitoring** (optional): CloudWatch alarms + a Route 53 health check, emailed via SNS.
- **Database access** without SSH: `db.sh tunnel -- <command>` runs a local command (a seed script, `psql`)
  against the server's Postgres over an SSM port-forward, with `DATABASE_URL` and the `PG*` variables set and the
  password left in SSM.
- **Operations log**: `deploy/OPERATIONS.md` in the project gets one line per command that changed the server
  (deploys, rollbacks, maintenance, restores, resizes, … — success or failure, never secret values), and a
  Notes section for decisions and incidents. The agent reads it before working on the server; you commit it.

## Installation

Two install paths — pick what fits.

| Path | What gets installed | Best for |
|---|---|---|
| **A. `npx skills` CLI** ([vercel-labs/skills](https://github.com/vercel-labs/skills)) | Skills only (`SKILL.md` + references/scripts/assets) | Fastest install, cross-agent (Claude Code, Cursor, Codex, OpenCode, …) |
| **B. Claude Code plugin** (`/plugin` or `settings.json`) | Skills **+** the plugin manifest | Full experience inside Claude Code |

### Path A — `npx skills add` (recommended for quick install)

```bash
# Install every skill in this repo to ~/.claude/skills/ for Claude Code, globally
npx skills add juncoding/agent-skills -g -a claude-code

# Browse what's in the repo without installing
npx skills add juncoding/agent-skills --list

# Install just one specific skill
npx skills add juncoding/agent-skills --skill ec2-docker-host -g -a claude-code
npx skills add juncoding/agent-skills --skill ec2-dedicated-host -g -a claude-code
```

### Path B — install as a Claude Code plugin

Inside Claude Code, run `/plugin` and add this source:

```
github:juncoding/agent-skills
```

Or edit `~/.claude/settings.json` (user-level) / `.claude/settings.json` (project-level) directly:

```json
{
  "plugins": {
    "agent-skills": {
      "source": "github:juncoding/agent-skills"
    }
  }
}
```

Restart Claude Code; the skills become available and trigger on intent.

### Path C — clone locally (for iterating on the skills themselves)

```bash
git clone git@github.com:juncoding/agent-skills.git ~/Dev/agent-skills
```

Then point a plugin `source` at the local path:

```json
{
  "plugins": {
    "agent-skills": {
      "source": "/Users/you/Dev/agent-skills"
    }
  }
}
```

## ⚠️ Safety

`ec2-docker-host` bundles shell scripts that **SSH into a host and run `docker`, `psql`, and `caddy`
with `sudo`.** They are written to be additive and neighbor-safe (validate-then-reload the proxy, pull
images before swapping, scope `--remove-orphans` per app), but they act on **real infrastructure**.

- **Read a script before you run it** the first time on a host.
- **Test against a throwaway host** before pointing them at production.
- The skill always discovers live host state before changing anything, and re-verifies neighbors after —
  trust that flow, and stop if discovery shows something unexpected.

`ec2-dedicated-host` bundles scripts that **create, change and remove AWS resources** with the AWS CLI
(EC2, IAM, S3, SSM, ECR, DLM, CloudWatch, SNS, Route 53) and run commands as root on the server through SSM.
Every mutating script checks the AWS account against the pinned `account_id`; provisioning shows a plan
first; scripts ask before anything that stops the site or touches data, and never deletes resources tagged `Protect=true`.
It costs money (roughly $20–75 per client per month, depending on the server size and monitoring).

- Provided **as is, without warranty** (see [LICENSE](LICENSE)). You are responsible for what runs against
  your servers.

## Repository layout

```
.claude-plugin/plugin.json   # Claude Code plugin manifest
skills/
  ec2-docker-host/
    SKILL.md                 # the skill (router + safety doctrine + isolation invariants)
    references/              # per-mode deep dives
    scripts/                 # idempotent, neighbor-safe ops scripts
    assets/                  # fill-in templates (compose, vhost, entrypoint, host config)
    evals/                   # scenario test cases
  ec2-dedicated-host/
    SKILL.md                 # the skill (commands, first-deploy flow, safety rules)
    references/              # provisioning, app contract, maintenance, backups, monitoring, sizing, upgrades, runbook
    scripts/                 # local scripts (macOS bash 3.2): provision, deploy, restore, …
    assets/                  # host scripts, systemd units, IAM/S3/DLM templates, project templates
    evals/                   # scenario test cases
tests/ec2-dedicated-host/    # stub-AWS unit tests + Docker integration tests: bash tests/ec2-dedicated-host/run.sh
docs/plans/                  # design and implementation plans
```

## Contributing

Add a skill as a new directory under `skills/<name>/` with a `SKILL.md` (a `name` + a specific,
trigger-rich `description` in the frontmatter) and any references/scripts/assets it needs. Keep skills
self-contained and intent-triggered. PRs welcome.

## License

[MIT](LICENSE) © Bill Zhou
