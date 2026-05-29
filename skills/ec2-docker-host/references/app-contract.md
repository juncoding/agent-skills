# The per-app contract

For the host to run an app *blindly* — the same deploy script, the same health probe, the same proxy
pattern for every app — each app must conform to a small contract. The contract is what lets a new app
slot in without bespoke per-app handling, and it's what keeps deploys boring. If an app you're about to
deploy doesn't meet a point below, generate the missing piece from `assets/` before deploying; don't
special-case the host.

## What every app must provide

1. **Built for the host's CPU architecture.** If the host is arm64 (e.g. Graviton), the image must be
   arm64. A wrong-arch image either won't run or runs slowly under emulation. Build with the right
   `--platform`, or use a multi-arch image.

2. **Listens on a fixed internal port, bound to `0.0.0.0`.** The convention is **3000**. The host maps
   `127.0.0.1:<unique-host-port>:3000`. Binding to `0.0.0.0` inside the container (not `127.0.0.1`) is
   required or the port mapping can't reach it.

3. **A health endpoint: `GET /health` returning 200.** It should check what "ready" really means —
   typically a cheap DB round-trip — so the deploy script and the container healthcheck can both use one
   uniform probe. A health check that returns 200 while the DB is unreachable defeats the purpose.

4. **A deploy compose file of the standard shape** (`assets/docker-compose.app.yml`). It references
   `${IMAGE}`, `${HOST_PORT}`, `${APP}`, `${ENV}` which the deploy script supplies via a generated
   `.env`. It joins the external `infra_net` network and sets a healthcheck. Never hard-code the host
   port in the compose file — that's the one value that must stay unique per app, so it comes from the
   deploy script, not the repo.

5. **An entrypoint that, in order:** pulls the app's secrets from the secret store by namespace and
   exports them as env vars; aliases the canonical database URL to whatever the migration tool expects
   (e.g. `POSTGRES_URL` → `DATABASE_URL`); runs migrations (gated by a `SKIP_MIGRATIONS` flag so you can
   run them out-of-band before flipping traffic); then `exec`s the app so signals reach it. Use an init
   like `tini` so SIGTERM is forwarded and the container stops cleanly within the grace window. See
   `assets/entrypoint.sh`.

6. **All config from runtime environment variables**, never baked at build time — with one important
   exception below. Shared DB URLs, secret values, feature flags: all read from env at boot. This keeps
   one image promotable across environments.

7. **Logs JSON to stdout/stderr only**, runs as a **non-root** user, and handles SIGTERM. No writing logs
   to files inside the container; the host collects stdout.

## The two environment variables that are easy to confuse

- **`NODE_ENV` is always `production`** for any deployed container — even staging. Staging is a
  *production build* pointed at staging backends, not a dev build. Setting `NODE_ENV=development` in
  staging silently changes framework behavior and dependency trees and will burn you.
- **`ENV` (`prod` | `staging`)** is the *deployment* environment. It drives the secret namespace, the
  database name, the vhost/FQDN, and the Redis key prefix. The entrypoint reads `ENV`, not `NODE_ENV`,
  to decide which secrets to pull.

## The build-time exception: client-inlined variables

Most config is runtime, but some frameworks **inline certain variables into the client bundle at build
time** — anything a browser must see. Next.js `NEXT_PUBLIC_*` is the classic case (e.g. a public app URL
or a client-visible auth URL). These cannot be injected by the entrypoint at boot; they're already
frozen into the JS that was built. So they must be passed as **build args at `docker build` time** (in
the Dockerfile and in CI).

Consequence: an image that bakes a `NEXT_PUBLIC_*` value is **environment-specific** — a staging build
and a prod build are different images. Plan for that: either build per-environment, or keep client-side
config truly dynamic. When a deployed frontend's login/redirects break but the server seems fine, a
stale or wrong build-time public URL is the first thing to check.

## Declare needs centrally, not by talking to neighbors

An app states what it needs — a port, a database, secret keys, a domain — through *its own* registration
and config, never by coordinating with whatever else is on the box. Ports come from the allocation
scheme, the DB from `db-create.sh`, secrets from the app's namespace. This is why two people can add two
apps to the same host without a meeting: the invariants make their choices non-colliding by construction.
