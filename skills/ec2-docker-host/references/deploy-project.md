# Deploying a project

The common case: a host already exists and you want to put an app on it. This walks the whole flow,
including how monorepos and polyrepos differ, the project shapes, and first-deploy vs redeploy.

## Step 0 — classify the repo

**Polyrepo / single app.** One repo → one deployable (a standalone Next.js app, a single backend
service). Simplest case: one container, one port, one vhost, usually one database.

**Monorepo.** One repo holds several deployables — say a frontend app and one or more backend services,
or several services. **Each deployable is its own app under the isolation invariants**: its own host
port, its own Compose project/container, and — depending on the design — its own database and secret
namespace, or a shared one across the monorepo's services. Do not deploy a monorepo as a single opaque
blob unless it genuinely ships as one container. Walk the workspace (e.g. `apps/*`, `services/*`,
`packages/*`, the `pnpm-workspace.yaml` / `turbo.json` / root `package.json` workspaces) to enumerate
the deployables, then decide per unit how it's built and served.

A monorepo deploy is just N single-app deploys that you plan together so their ports, names, DBs, and
vhosts don't collide. Share a database across services only when they're genuinely one logical app;
otherwise give each service its own, so one service's migration can't break another.

## Step 1 — pick a serving shape per deployable

| Shape | What it is | Proxy treatment |
|---|---|---|
| **Combined container** | One container serves both UI and API (e.g. a fullstack Next.js app) | One vhost → the app's host port |
| **Backend only** | API container on the host; frontend hosted elsewhere (Vercel/CDN) | One vhost on an `api.` FQDN → host port; frontend points its API base at that URL (CORS) |
| **Host-served static** | Built static frontend served by the proxy from a release dir | `file_server` from the release dir; atomic symlink flip for releases, keep last N for rollback |

Frontends do **not** have to live on the host — backend-only with an external frontend is a perfectly
good shape and keeps the host lean. Choose per project; the user may already have a preference.

## Step 2 — discover + check the contract

Run `scripts/discover-host.sh <ssh-target>` for the live inventory. Confirm each deployable meets
`references/app-contract.md` (health endpoint, deploy compose, entrypoint, runtime env, arch). Generate
any missing pieces from `assets/` (`docker-compose.app.yml`, `entrypoint.sh`) and adapt them to the app
— e.g. wire the real migration command into the entrypoint.

## Step 3 — write the deploy plan (show the user before applying)

Per deployable, state:

- **Host port** — from `scripts/allocate-port.sh`, verified free against the live inventory.
- **Compose project + container name** — `<app>-<env>`.
- **Database + role** — create (`db-create.sh`) on first deploy, or reuse if it already exists. Note the
  name (`myapp` prod / `myapp_staging` staging) and that the role is scoped to just that DB.
- **Secret namespace + keys** — the path/prefix and which keys the app needs (DB URL is set
  automatically by `db-create.sh`; the rest you set).
- **Vhost(s) + FQDN(s)** — what hostnames route here. Wildcard DNS covers `*.example.com` subdomains
  with no DNS change; a custom apex (`someapp.com`) needs an A record at the registrar and a dedicated
  vhost — call that out.
- **Image reference** — registry repo + tag.
- **First deploy vs redeploy** — first deploy creates DB/secrets/vhost; redeploy is an image swap only.

Deploying to a live, shared host is a production action. Get explicit agreement on the plan before
applying anything non-additive (new DB role, new vhost, anything touching DNS).

## Step 4 — build & push the image

Default (lightweight): build for the host arch and push to any OCI registry (GHCR, Docker Hub, ECR…)
with an **immutable tag** — `<branch>-<sha>`. **Refuse `latest`** for anything you might need to roll
back: `latest` is a moving target and destroys rollback determinism. CI is the usual place this happens;
the deploy script later *verifies the tag exists* in the registry before touching the host.

AWS-native upgrade (ECR + GitHub OIDC, no static keys): see `references/secrets-and-images.md`.

Git promotion model: trunk (`main`) auto-builds images; **prod advances only by fast-forward**
(`git push origin main:prod`). The deploy script resolves the tag from `origin/prod` (prod) or
`origin/main` (staging), so promotion needs no rebuild — that SHA already has an image. A consequence
worth remembering: if `origin/prod` points at a commit that never got a successful build, the deploy
will (correctly) fail the image-exists check. Point prod at a commit that actually built green, and
don't assume docs-only commits on top of a built commit have their own image.

## Step 5 — apply in neighbor-safe order

```bash
# First deploy only: create the database + role (generates + stores the DB URL/password)
scripts/db-create.sh <app> <env> <ssh-target>

# First deploy only: set the app's other secrets (see secrets reference for the backend in use)
#   e.g. lightweight: append to the host env file; AWS: ssm put-parameter under /apps/<app>/<env>/

# Deploy the container (idempotent; this is also the redeploy command).
# <image-ref> is the full immutable reference, e.g. ghcr.io/<you>/<app>:main-<sha>.
# <host-port> comes from allocate-port.sh. [compose-file] defaults to deploy/docker-compose.yml.
scripts/deploy-app.sh <app> <env> <image-ref> <host-port> <ssh-target> [compose-file]

# First deploy only: add the vhost + validate-then-reload the proxy
scripts/add-vhost.sh <fqdn> <host-port> <ssh-target>
```

`deploy-app.sh` does: `mkdir ~/apps/<app>-<env>` → copy the compose file → write the deploy-time `.env`
(APP/ENV/IMAGE/HOST_PORT) → `docker pull` the image **first** (and abort before swapping if the pull
fails, so a bad tag can't take the running container down) → `docker compose up -d --remove-orphans` →
poll `/health`. Because it's a self-contained Compose project, `--remove-orphans` is scoped to this app
only. Registry login is assumed already configured on the host (a deploy token, or an instance profile
for ECR — see `references/secrets-and-images.md`).

## Step 6 — verify, and prove the neighbors are fine

- App health green over HTTPS: `curl https://<fqdn>/health`.
- TLS cert issued (the proxy gets it automatically on first request after the vhost is added).
- Container reports healthy: `docker inspect -f '{{.State.Health.Status}}' <app>-<env>`.
- **Re-run `discover-host.sh`** and confirm every other app is still `Up` and nothing else changed. This
  is the step people skip; it's the one that catches a port clash or an accidental restart.

Then report: the URL, and any manual follow-ups the app needs — first-admin grant
(`docker exec <app>-<env> <grant-script> <email>`), DNS for a custom apex, transactional-email domain
verification, etc.

## Rollback

Redeploy a previous immutable image: `scripts/deploy-app.sh <app> <env> <previous-image-ref> <host-port> <ssh-target>`.
Or, in the git-promotion model, point `origin/prod` back at a known-good SHA and redeploy. Because tags
are immutable and images are retained, the previous version is always exactly reproducible.
