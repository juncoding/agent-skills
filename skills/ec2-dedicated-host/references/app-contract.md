# App contract — what the app must provide

Check these before the first deploy and fix gaps in the project (not on the server).

## 1. An arm64 image

`deploy.sh` runs `docker buildx build --platform linux/arm64 -f <dockerfile> <build_context>` on the
operator's Mac and pushes `…/edh/<client>:<12-char git sha>` to ECR. `dockerfile` (default `Dockerfile`)
and `build_context` (default `.`) are set in `deploy.yml`. The image must contain `sh` (migrations run
through `sh -c`). Native modules must build for arm64.

## 2. Listens on `$PORT`

Compose sets `PORT=<app_port>` (default 3000). Caddy proxies `app:<app_port>`. Don't publish ports
yourself; only Caddy is reachable from outside.

## 3. `GET /health` → 200 only when the database answers

Used three ways: the deploy and rollback health checks (from the Caddy container, `http://app:<port>/health`,
up to ~60 s), the Route 53 site-down check (`https://<domain>/health`, every 30 s), and maintenance mode
(`/health` always reaches the app, even while the maintenance page is on). Keep it cheap and unauthenticated.

```ts
// Next.js (app router): app/health/route.ts
import { prisma } from "@/server/db";
export const dynamic = "force-dynamic";
export async function GET() {
  try { await prisma.$queryRaw`select 1`; return Response.json({ ok: true }); }
  catch { return Response.json({ ok: false }, { status: 503 }); }
}
```

```js
// Express + pg
app.get("/health", async (_req, res) => {
  try { await pool.query("select 1"); res.json({ ok: true }); }
  catch { res.status(503).json({ ok: false }); }
});
```

```ts
// NestJS (TypeORM DataSource)
@Controller("health")
export class HealthController {
  constructor(private readonly db: DataSource) {}
  @Get() async check() {
    try { await this.db.query("select 1"); return { ok: true }; }
    catch { throw new ServiceUnavailableException(); }
  }
}
```

## 4. Configuration from the environment

The app's environment is `app.env` on the server (mode 0600), rebuilt from SSM on every deploy:

- Every parameter `/<client>/<env>/<name>` becomes `NAME` with dashes → underscores, upper case:
  `secrets.sh set resend-api-key` → `RESEND_API_KEY`. Names are lowercase letters, digits and dashes.
  Nested names (`a/b`) and the internal `_edh/*` parameters are not passed.
- `DATABASE_URL=postgres://app:<generated password>@postgres:5432/app` is injected unless you set a
  `database-url` parameter yourself.
- Values must not contain a newline or tab (refused). They are passed literally (`format: raw`): no `$`
  interpolation or quote handling.
- A changed secret takes effect on the **next deploy**.
- **Defaults your app reads** — each added only when the app hasn't set the same name; override any by
  setting a secret with that name (e.g. `secrets.sh set aws-region` → `AWS_REGION`):

  | Variable | Value |
  |---|---|
  | `AWS_REGION` | the app region from `deploy.yml` (e.g. `ap-southeast-1`) |
  | `EDH_UPLOADS_BUCKET` | `edh-<client>-<env>-uploads-<account>`, e.g. `edh-acme-prod-uploads-123456789012` |
  | `GOTENBERG_URL` | `http://gotenberg:3000` — only with `uses_gotenberg: true` |

- Any other non-secret setting the app needs (public base URL, feature flags…) is set the same way, e.g.
  `printf '%s' https://app.example.com | secrets.sh set public-url` → `PUBLIC_URL`.

Never print the environment (`docker inspect`, `env`, `printenv`, `cat app.env`): it holds the secrets.

## 5. File uploads go to S3, not the disk

Bucket `edh-<client>-<env>-uploads-<account>` (versioned; deleted/overwritten versions kept 30 days).
With `app_uses_instance_role: true` (default) the app container uses the server's IAM role through
instance metadata — **no access keys**: the AWS SDK default credential chain finds it. Give the SDK the
region and bucket from `AWS_REGION` and `EDH_UPLOADS_BUCKET` (see 4). With `false`, containers can't reach
the role. Gotenberg (if `uses_gotenberg: true`) is at `GOTENBERG_URL` (`http://gotenberg:3000`) inside the
Compose network.

## 6. Migrations: `migrate_cmd`, backward compatible

`migrate_cmd` (e.g. `npx prisma migrate deploy`; no single quotes) runs once per deploy in a one-off
container of the **new** image, with the app's environment, after the pre-deploy safety dump and before the
switch (15-minute limit). If it fails, the deploy stops and the old version keeps serving. Migrations are
**never reverted automatically**, and the old version keeps running against the migrated schema during the
deploy and after a rollback — so use expand/contract: add columns/tables first, deploy code that uses
them, drop old ones in a later release. For a risky or slow migration, `deploy.sh --maint`.

## 7. Memory

`app_memory_mb` (default 768) is the container's hard memory limit and drives the server size
(sizing.md). An app killed for memory restarts and shows the down page meanwhile.

## 8. `deploy/compose.yml` rules (enforced by `deploy.sh` before anything is built)

The scaffolded `compose.yml` is the template to keep. You may add services, environment and settings, but:

- **Bind mounts only from inside the compose directory or a `/data/<dir>`**: `./<dir>` (next to
  compose.yml; on the server `/opt/edh/app/<dir>`), `/data/<dir>` or `${EDH_DATA_DIR:-/data}/<dir>`. Never the
  compose directory itself, never `/data` itself and never `/data/backups` — it holds the backup manifest,
  which restores trust because the app can't reach it. Named, anonymous and tmpfs volumes are fine.
- **Top-level volumes** may not use `driver_opts` (e.g. a `local` volume binding a host `device`) or be
  `external`.
- **No access to the server itself**: no `privileged: true`; no `cap_add`, `devices`, `device_cgroup_rules`
  or `volumes_from`; no `pid`, `ipc`, `userns_mode`, `network_mode` or `cgroup` set to `host`; no `security_opt`
  with `unconfined`; no network named `host` or using the `host` driver; `secrets`/`configs` files only from
  inside the compose directory.
- Keep the service names `caddy`, `app`, `postgres` (the host scripts use them), `name: ${EDH_NAME:?}`,
  and `env_file` with `format: raw` (needs Compose ≥ 2.30 — on the server, installed by bootstrap, and on the
  operator's Mac for the check below).

**How it is checked:** not by matching the file's text, but on Compose's own **normalized** configuration —
`deploy.sh` runs `docker compose config --format json` on a copy of `compose.yml` (alone in a temp directory
with empty `app.env`/`postgres.env`, dummy values for the variables the server sets, and the `gotenberg`
profile enabled), so anchors and aliases, every list style, interpolation, `..` and `.` path segments are
already resolved; paths are compared after normalization. If Compose itself rejects the file, deploy refuses
with Compose's error (the server would too). Each violation is reported with its service and key. On the
server, `docker compose config` and `caddy validate` (with the caddy image `compose.yml` uses) must also
pass before anything is installed.

**Only `deploy/compose.yml`, `deploy/Caddyfile` and `deploy/maint/*.html` are shipped to the server.** Any
other file `compose.yml` refers to (a config file, an extra `env_file`, a `build:` context) does not reach it:
bake such files into an image, or pass the settings as environment through `secrets.sh`.

## Test-only switches

The scripts read a few environment switches meant **only for the test suite** — `EDH_SKIP_SSM`,
`EDH_SKIP_PULL`, `EDH_SKIP_PRUNE`, `EDH_NO_SYSTEMD`, `EDH_SSM_POLL_SECONDS`, `EDH_REBOOT_POLL_SECONDS`,
`EDH_IAM_WAIT`, `EDH_HEALTH_TRIES`, `EDH_HTTP_PORT`, `EDH_HTTPS_PORT`, and the path overrides `EDH_ENV_FILE`,
`EDH_APP_DIR`, `EDH_DATA_DIR`, `EDH_BIN_DIR`, `EDH_LOCK_FILE`, `EDH_MANIFEST`. Don't set them in real use. The
only switches for real use are `EDH_YES=1` and `EDH_CONFIRM_NAME` (after the user agreed).
