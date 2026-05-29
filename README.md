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

More to come.

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
```

## Contributing

Add a skill as a new directory under `skills/<name>/` with a `SKILL.md` (a `name` + a specific,
trigger-rich `description` in the frontmatter) and any references/scripts/assets it needs. Keep skills
self-contained and intent-triggered. PRs welcome.

## License

[MIT](LICENSE) © Bill Zhou
