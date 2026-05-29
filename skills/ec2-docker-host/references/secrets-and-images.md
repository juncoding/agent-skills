# Secrets & images (the pluggable backends)

Four pieces of this platform are the only genuinely cloud-specific parts: the **image registry**, the
**secret store**, **DNS**, and the **off-host backup target**. Everything else (the network, per-app
Compose projects, the proxy, the entrypoint contract) is provider-agnostic. This doc covers the two
that touch every deploy — secrets and images — with a **lightweight default** and an **AWS-native
upgrade** for each. Start lightweight; reach for AWS-native when you want CI to push images and the host
to read secrets with no static credentials anywhere.

## Secrets

The contract (same regardless of backend): the app's **entrypoint pulls its own namespace at boot** and
exports the values as env vars, mapping `kebab-key` → `KEBAB_KEY`. The canonical DB URL is aliased to
whatever the migration tool expects. Secrets are **never baked into the image** and never committed.

### Lightweight default — host-side env files

Keep per-app secrets in a file on the persistent volume, readable only by the deploy user:

```
/data/secrets/<app>-<env>.env      # chmod 600, owner = deploy user
```

The deploy compose passes it in via `env_file:` (or the entrypoint sources it). `db-create.sh` appends
the generated `DATABASE_URL` / password here. To set a secret, append/replace a line and redeploy. Simple,
no extra services, and the file rides along on `/data` (so it survives rebuilds and is captured by
backups — which means **treat backups of `/data/secrets` as sensitive**).

Pros: zero dependencies. Cons: secrets sit in plaintext on the box; rotation is manual; CI can't set them
without SSH. Fine for a solo operator / small host.

### AWS-native upgrade — SSM Parameter Store

Store each secret as a `SecureString` under a per-app path:

```
/apps/<app>/<env>/<key>            # e.g. /apps/myapp/prod/better-auth-secret
```

The host's **IAM instance profile** grants `ssm:GetParametersByPath` on `/apps/*` (read-only, no static
keys on the box). The entrypoint calls `aws ssm get-parameters-by-path --path /apps/<app>/<env> --with-decryption`
at boot and exports each. Set a secret with `aws ssm put-parameter --type SecureString`. CI or any
authorized operator can set secrets without touching the host. This is the recommended upgrade once more
than one person manages the host or you want audited, rotatable secrets.

Other portable options if you outgrow both: Vault, Doppler, SOPS-encrypted files in git, sealed secrets.
The entrypoint contract doesn't change — only where it reads from.

## Images

The contract: build for the **host architecture**, tag **immutably** as `<branch>-<sha>`, and **never
deploy `latest`** for anything you might roll back (a moving tag destroys rollback determinism — the
deploy scripts refuse it). The deploy script always **verifies the tag exists in the registry before
touching the host**, so a typo or an unbuilt commit fails safely.

### Lightweight default — any OCI registry

GHCR, Docker Hub, Harbor, etc. Build and push from CI or locally:

```bash
docker build --platform linux/arm64 -t <registry>/<app>:<branch>-<sha> .
docker push <registry>/<app>:<branch>-<sha>
```

The host pulls with a read-only deploy token (stored like any other host secret). One registry repo per
app keeps things tidy and lets you scope tokens per app.

### AWS-native upgrade — ECR + GitHub OIDC

A per-app ECR repo with scan-on-push and a lifecycle policy (retain last N, expire untagged). CI
authenticates via **GitHub OIDC** assuming an IAM role whose trust policy is **scoped to that one source
repo** — so a compromised app repo can't push to another app's registry, and there are no long-lived
registry credentials in CI. The host pulls via its instance profile. This is the same trust model as
SSM: identity-based, no static secrets.

## The git promotion model (ties images to deploys)

- Pushing to **trunk** (`main`) triggers a build → image tagged `main-<sha>`.
- **Prod advances only by fast-forward**: `git push origin main:prod`. No rebuild — the SHA already has
  an image.
- The deploy script resolves the tag from `origin/prod` (prod) or `origin/main` (staging) and verifies
  it. So "promote to prod" is a git fast-forward, and "roll back" is pointing `origin/prod` at an older
  good SHA and redeploying.
- Watch out: a commit that **never built green** has no image — deploying it fails the existence check
  (correctly). And docs-only commits stacked on a built commit don't get their own image, so deploy the
  built SHA, not the tip, when they differ.
