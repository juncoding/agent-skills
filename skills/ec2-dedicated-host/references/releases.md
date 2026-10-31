# Releases by tag (`release_flow: tags`)

The default flow deploys the current checkout of `prod_branch` (main). Projects that cut versioned releases
opt in to a release branch instead:

```yaml
prod_branch: release   # the branch prod runs; release.sh is the only thing that moves it
release_flow: tags
```

(`init.sh --release-flow tags` writes both. `prod_branch` must not be `main` in this mode.)

## Releasing

1. Merge to `main` through review as usual.
2. Tag a commit on main and push the tag: `git tag -a v1.2.3 -m "release: …" && git push origin v1.2.3`.
3. `release.sh v1.2.3` (add `--maint` for a risky migration).

`release.sh`:

- reads origin's refs (`git ls-remote`) and refuses unless the tag is **on origin** and its commit is an
  ancestor of **`origin/main`** — only reviewed code ships;
- **fast-forwards** `origin/<prod_branch>` to that commit with a plain `git push` (creating the branch on the
  first release). It never force-pushes and never moves the branch backwards: an older tag or a release
  branch holding commits the tag doesn't contain is refused;
- runs `deploy.sh`, and logs one line: `release · ok · v1.2.3 (<sha>)`. If the push succeeded but the
  deploy failed, the message says so: fix it and run `deploy.sh` to deploy `origin/<prod_branch>` again.

Releasing the tag the branch already points at just deploys it again.

## What `deploy.sh` builds

In this mode `deploy.sh` (alone or from `release.sh`) fetches `origin/<prod_branch>` and builds it from a
**temporary clean `git worktree`** — the operator may be on any branch with uncommitted work; none of it
reaches the image or the config bundle. The release commit's own `deploy/deploy.yml`, `compose.yml`,
`Caddyfile` and maintenance pages are used, and it must still say `release_flow: tags`.

Version information reaching the app:

| | How | Where |
|---|---|---|
| `GIT_SHA` | `--build-arg GIT_SHA=<full sha>` (every deploy, both modes) | declare `ARG GIT_SHA` + `ENV GIT_SHA=$GIT_SHA` in the Dockerfile to use it |
| `APP_VERSION` | the highest `v*` tag on origin at the release commit | the app's environment (app.env); a secret named `app-version` overrides it |

A rollback restores the previous app.env too, so `APP_VERSION` goes back with the image.

## Going back, hotfixes

- **Back to the previous version:** `rollback.sh` (previous image + env; the branch stays where it is, so
  the next `deploy.sh` brings the release back).
- **A fix:** merge it into main, tag `v1.2.4`, `release.sh v1.2.4`.
- **Emergency** (main is broken): `deploy.sh --allow-non-main` still builds the working copy, with the red
  warning and a confirmation, exactly as in the default flow.
