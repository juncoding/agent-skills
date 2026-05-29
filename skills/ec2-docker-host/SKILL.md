---
name: ec2-docker-host
description: >-
  Run multiple independent app projects side-by-side on ONE AWS EC2 instance using Docker, without
  them interfering with each other. Use this skill whenever the user wants to deploy an app or service
  to an EC2 instance, set up a new EC2 host as a Docker server, adopt/connect to an existing EC2 box
  and deploy onto it, add a project to a shared server without breaking the apps already running there,
  self-host a Next.js / Node / backend app on a single instance with a reverse proxy and TLS, or manage
  that host's databases, secrets, and backups. Trigger this even when the user just says "deploy to my
  server", "put this on my EC2", "set up my VPS", "I have an instance running other stuff, add this one",
  or asks about Caddy + Docker, per-app isolation, database backups on a box, or restoring a host. Treats
  the EC2 instance as a small self-hosting platform: shared Postgres/Mongo/Redis + reverse proxy, with
  each app getting its own container, port, database, and secret namespace.
---

# EC2 as a single-host Docker platform

This skill turns one EC2 instance into a small multi-tenant platform: a handful of **shared backing
services** (Postgres, Mongo, Redis), **one reverse proxy** that terminates TLS, and **N independent
app containers** living alongside each other. You can stand up a fresh host, adopt one that already
has apps running, deploy a new project in a few commands, and keep the data backed up.

**The prime directive: never disturb a neighbor.** Apps already running on the host pay the rent. A
new deploy, a proxy reload, a `compose up` — none of it may interrupt, restart, or reconfigure another
app. Every instruction here exists to protect that guarantee. When in doubt, choose the additive,
reversible, neighbor-safe option, and discover the live state before you change it.

## How the pieces fit

```
                          Internet (:80/:443)
                                 │
                    ┌────────────▼────────────┐
                    │  Reverse proxy (Caddy)   │  host systemd service, auto-TLS
                    │  one vhost block per app │  per-FQDN Let's Encrypt
                    └─────┬─────────┬──────────┘
        127.0.0.1:3001    │         │   127.0.0.1:3002 ...   (unique host port per app)
              ┌───────────▼──┐   ┌──▼───────────┐
              │ app-a (cntr) │   │ app-b (cntr) │   each its own Compose project
              └──────┬───────┘   └──────┬───────┘
                     └──────┬───────────┘
              ┌─────────────▼──────────────┐   shared Docker bridge network "infra_net"
              │  postgres   mongo   redis   │   bind only to 127.0.0.1, never public
              └─────────────┬──────────────┘
                            │
                   /data  (separate EBS volume, bind-mounted)
              postgres/  mongo/  redis/  caddy/  backups/  secrets/
```

Two facts make the whole thing safe and cheap to operate:

- **Data lives on a separate volume** (`/data`, a dedicated EBS volume) via **bind mounts**, not on the
  root disk and not in named volumes. Containers, images, even the whole instance can be rebuilt and the
  data survives, because the volume is independent. Treat `/data` as sacred.
- **The shared services bind only to `127.0.0.1`.** Database ports are never exposed to the internet;
  apps reach them over the private `infra_net` Docker network by service name (`postgres`, `mongo`,
  `redis`). The only things the security group opens to the world are 80/443 (and SSH from your IP).

## The four modes — route first

Figure out which situation you're in, then read the matching reference. Most sessions are **Deploy**.

| Mode | When | Read |
|---|---|---|
| **Deploy a project** | Host exists; you want to put an app on it (the common case) | `references/deploy-project.md` |
| **Adopt an existing host** | First time touching a host (yours or one with apps already running) | `references/adopt-host.md` |
| **Provision a new host** | No host yet; stand one up from nothing | `references/provision-host.md` |
| **Maintain** | Backups, restore, upgrades, health checks, disk pressure | `references/backups-and-maintenance.md` |

Cross-cutting references you'll reach for from several modes:
- `references/app-contract.md` — what an app must provide to be hostable (health endpoint, deploy compose, entrypoint, env model). Read before deploying any app that hasn't been deployed here before.
- `references/reverse-proxy-tls.md` — how vhosts and TLS work; the validate-then-reload safety dance.
- `references/secrets-and-images.md` — the pluggable backends. Default is **lightweight** (any registry + host-side env files); **AWS-native** (ECR + SSM + GitHub OIDC) is an opt-in upgrade.

## Always discover before you act

The live host is the source of truth — not a local file, not your memory, not this skill. Before any
change to an existing host, take an inventory so your decisions (which port is free, does this DB
already exist, what vhosts are live) are grounded in reality:

```bash
scripts/discover-host.sh <ssh-target>     # read-only; prints containers, used ports, networks,
                                          # volumes, proxy type, shared DBs, /data usage
```

Feed that inventory into every decision below. If discovery shows something you didn't expect (an app
you don't recognize, a port you were about to use, a proxy that isn't Caddy), **stop and tell the user**
rather than plowing ahead — unexpected state usually means in-progress work or a different setup, and
overwriting it is how neighbors get hurt.

## The isolation invariants (the part that protects neighbors)

Every shared resource is namespaced by app + environment. Honor all of these on every deploy; they are
the mechanism behind the prime directive. The reasoning is given so you can handle edge cases sensibly.

1. **Unique host port per app+env.** Containers all listen on the *same* internal port (3000); only the
   host-side mapping `127.0.0.1:<host-port>:3000` differs. Allocate from a deterministic scheme
   (`3000+offset` for prod, `4000+offset` for staging) and **verify the port is actually free in the
   live inventory** before claiming it — `scripts/allocate-port.sh` does both. Two apps on one port is
   the most common way to take down a neighbor.
2. **Its own Compose project + container names.** Each app+env is a separate Compose project in its own
   host directory (`~/apps/<app>-<env>/`) with explicit `name:` and `container_name`. This is what makes
   `docker compose up -d --remove-orphans` safe: `--remove-orphans` only prunes orphans *within that one
   project*, so it can never touch another app or the shared DB stack.
3. **Its own database + dedicated role.** A per-app Postgres database and a role that can touch only that
   database. Prod uses the bare name (`myapp`), staging a suffix (`myapp_staging`). Never reuse a role
   across apps.
4. **Its own secret namespace.** Secrets live under a per-app path/prefix; the app's entrypoint pulls
   only its own namespace. One app can never read another's secrets.
5. **Its own Redis key prefix** (`<app>:<env>:`) when it uses the shared Redis. This is convention-only
   (shared instance, no per-app ACL), so it must be enforced in the app's config, not assumed.
6. **Additive-only proxy vhosts.** Adding an app contributes a *new* server block; it never edits
   another app's block. A wildcard DNS record pointing at the host's stable IP means a new app needs no
   DNS change at all (custom apex domains are the exception — see the proxy reference).
7. **Validate, then reload — never restart — the proxy.** Validate the new config (locally and on the
   host into a `.new` file) and only swap + hot-reload if it passes. A malformed vhost must never be able
   to interrupt the vhosts already serving traffic.

If a requested change can't be made additively (e.g., two apps genuinely need the same port, or an app
wants to claim a domain another app serves), that's a real conflict — surface it to the user with the
options, don't silently resolve it.

## Deploying a project — the workflow

This is the spine of the skill. Full detail (including monorepo vs polyrepo, first-deploy vs redeploy,
the image build/push step) is in `references/deploy-project.md`; the shape is:

**1. Identify the project's shape.** A repo is one of:
- **Polyrepo / single app** — e.g. a standalone Next.js or backend repo → one deployable unit.
- **Monorepo** — one repo, several deployables (frontend app(s) + backend service(s)). Each deployable
  is treated as its *own* app under these invariants: its own port, container, possibly its own DB/secrets.
  Don't deploy a monorepo as one blob unless it genuinely ships as one container.

Decide how each unit is served (combined frontend+backend in one container, backend-only with the
frontend hosted elsewhere, or host-served static frontend) — see the shapes table in
`references/deploy-project.md`.

**2. Discover the host** (above) and confirm the app meets the contract (`references/app-contract.md`):
a `GET /health` endpoint, a deploy compose file of the standard shape, an entrypoint that pulls secrets
+ runs migrations, config from runtime env. If it doesn't, generate the missing pieces from
`assets/` templates before going further.

**3. Produce a deploy plan and show it to the user before applying.** The plan states, per deployable:
the allocated host port, the container/project name, the database + role to create (or reuse), the
secret namespace + which keys are needed, the proxy vhost(s) + FQDN(s), the image reference, and whether
this is a first deploy (creates DB/secrets/vhost) or a redeploy (image swap only). Deploying to a live
host is a production action — get a nod on the plan first, especially for anything non-additive.

**4. Apply, in the neighbor-safe order:**
   - First deploy only: `scripts/db-create.sh` (DB + role + generated password), then set the app's
     secrets (see secrets reference).
   - Build + push the image to the registry (lightweight default: any OCI registry, immutable
     `<branch>-<sha>` tag — refuse `latest` so rollback is deterministic). See deploy reference.
   - `scripts/deploy-app.sh <app> <env> <image-ref> <host-port> <ssh-target>` — verifies/pulls the
     image, copies the compose file, writes the deploy-time `.env`, `compose up -d`, waits for `/health`.
   - First deploy only: add the vhost and reload the proxy — `scripts/add-vhost.sh` (additive,
     validate-then-reload).

**5. Verify and report.** Health endpoint green over HTTPS, TLS cert issued, container healthy, and
**the neighbors are still up** (re-run discovery; nothing else changed). Report the URL plus any manual
follow-ups (first-admin grant, DNS for a custom apex, email-domain verification).

## Provisioning a new host (brief)

When there's no host yet, `references/provision-host.md` walks the AWS-CLI path: create the instance
(pinned AMI matching your build architecture), an Elastic IP (stable target for DNS, survives stop/start),
a security group (22 from your IP, 80/443 world, DB ports never open), and a **dedicated data EBS volume
with deletion protection**; then bootstrap the host (install Docker, create `infra_net`, mount `/data`
formatting only if blank, bring up the shared DB + proxy stack, install backups). The provisioning
scripts are idempotent — safe to re-run.

## Maintenance & backups (brief)

`references/backups-and-maintenance.md` covers the three backup layers (logical DB dumps with
`pg_dumpall` / `mongodump`, volume snapshots, off-host object-store sync with lifecycle), how to verify
and actually restore (do a restore drill — a backup you've never restored is a hope, not a backup), and
why host upgrades and image upgrades are kept as separate deliberate actions rather than silent rolls.

## Bundled scripts

All scripts are idempotent and take an SSH target + app/host config; they encode the safety logic above
so you don't reinvent it each time. Read a script before running it the first time on a host so you know
exactly what it will do.

| Script | Does | Mutates host? |
|---|---|---|
| `scripts/discover-host.sh` | Inventory: containers, ports, networks, volumes, proxy, DBs, `/data` | no (read-only) |
| `scripts/allocate-port.sh` | Pick + verify a free host port against the live inventory | no |
| `scripts/db-create.sh` | Create per-app DB + role + random password | yes (additive) |
| `scripts/deploy-app.sh` | Copy compose, write `.env`, pull image, `compose up -d`, health-check | yes (one project) |
| `scripts/add-vhost.sh` | Append a vhost, validate, hot-reload the proxy | yes (additive) |
| `scripts/backup.sh` | DB dumps + off-host sync | yes (writes to `/data/backups`) |
| `scripts/lib.sh` | Shared helpers (SSH wrapper, logging) — sourced by the others | n/a |

**Exact signatures** (this table is the source of truth — the scripts validate their own args, so match these and don't paraphrase). An SSH target is `<user>@<host>` (e.g. `ubuntu@<ip>`); set `SSH_KEY=<path>` in the env if a key is needed:

```
scripts/discover-host.sh  <ssh-target>
scripts/allocate-port.sh  <ssh-target> <prod|staging> [desired-offset]   # prints OFFSET= and HOST_PORT=
scripts/db-create.sh      <app> <env> <ssh-target>
scripts/deploy-app.sh     <app> <env> <image-ref> <host-port> <ssh-target> [compose-file]   # refuses :latest
scripts/add-vhost.sh      <fqdn> <host-port> <ssh-target> [reverse_proxy|static:<dir>]
scripts/backup.sh         <ssh-target>                                   # env: BACKUP_S3=s3://bucket/prefix
```

## Assets (fill-in templates)

- `assets/docker-compose.app.yml` — the standard per-app deploy compose (variable substitution).
- `assets/Caddyfile.vhost` — one additive vhost block (reverse-proxy / combined / static variants).
- `assets/entrypoint.sh` — pulls secrets, aliases the DB URL, runs migrations, execs the app.
- `assets/host.example.yml` — connection + backend config for a host (ssh target, data dir, network
  name, proxy type, registry, secret backend). Connection details only — live state is discovered.

## A note on portability

The isolation core (shared network, per-app Compose project + port offsets, additive validate-then-reload
proxy, entrypoint secret-pull, immutable SHA tags, branch-based promotion) is provider-agnostic. Only
four pieces are genuinely AWS-bound and are kept pluggable: the **image registry**, the **secret store**,
**DNS**, and the **off-host backup/snapshot target**. `references/secrets-and-images.md` documents the
lightweight default and the AWS-native upgrade for each.
