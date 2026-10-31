# Upgrades

## Operating system

- **Security patches install automatically** (unattended-upgrades, configured by bootstrap). The server
  **never reboots on its own**; `status.sh` doesn't show pending reboots, `upgrade.sh os` does.
- **`upgrade.sh os`** (ask the user first): takes a snapshot of the data volume (tagged
  `edh-<client>-<env>-pre-upgrade`, **kept until deleted by hand**), runs `apt-get upgrade` (waits for the
  dpkg lock, keeps existing config files, installs new dependencies), then checks the app's `/health`
  (package upgrades such as `docker.io` restart services; Docker's live-restore keeps containers running).
  It reports `a reboot is needed` when the kernel or core libraries changed.
- **`upgrade.sh os --reboot`**: the same, and if a reboot is needed it reboots (1–2 min offline, no
  maintenance page possible), waits until SSM reports the server back — offline then online, or a newer
  agent ping than the one recorded just before the reboot — and checks `/health`. Pick a quiet time.
- Docker and the AWS CLI are OS packages (apt / snap) and are upgraded the same way.
- A new Ubuntu release is not an in-place upgrade: servers are built from the Ubuntu 24.04 arm64 image
  (`provision.sh`). Moving to a newer release means changing that image and rebuilding the server from the
  kept data volume (`teardown.sh --keep-ip` + `provision.sh --apply`), which is outside this skill's commands.
  Without `--keep-ip` the rebuilt server gets a new public IP and the DNS A record must be updated
  (`provision.sh --apply` prints it; `status.sh` shows it).

## Service images (Postgres, Caddy, Gotenberg)

The tags are pinned in `deploy/compose.yml`: `postgres:18-alpine`, `caddy:2.10-alpine`,
`gotenberg/gotenberg:8`. An upgrade is: **edit the tag, commit, get it into main (ask the user to push or merge it
through their review), `deploy.sh`.**

- Compose downloads an image only when that tag isn't on the server yet. A floating tag (`18-alpine`) is
  therefore **not** refreshed by later deploys — changing the tag is what upgrades. Use a more specific tag
  to move on (`postgres:18.1-alpine`, `caddy:2.10.2-alpine`, `gotenberg/gotenberg:8.20`).
- Deploy restarts the changed service before its pre-deploy dump, so take a backup first: `backup.sh now`.
- If the deploy aborts before the switch — including a failed migration — the previous configuration
  (`compose.yml`, Caddyfile, env files) is put back and Caddy/Postgres are restarted with it, so the old
  service tags run again next to the old app version.

**Postgres minor** (18.x → 18.y): tag change + deploy. Postgres restarts in seconds; the app reconnects.

**Caddy**: tag change + deploy; certificates live in `/data/caddy` and survive. The deploy validates the
Caddyfile with the caddy image that the release's `compose.yml` uses (falling back to `caddy:2.10-alpine`
only if it can't read it, which it logs), so a new tag and a Caddyfile using its features ship together.

**Gotenberg**: stateless; tag change + deploy, then test a PDF.

## Postgres major version (e.g. 18 → 19)

Since the 18 image, Postgres keeps its data in a version-named directory under the mount
(`/data/postgres/18/docker`), so a new major version starts an **empty** cluster next to the old one. The
upgrade is a dump and restore under maintenance; the old cluster stays untouched as the way back.

1. Agree a window with the user; check `/data` has room for a second copy of the database (`status.sh`).
2. `maint.sh on --message "We're upgrading the database." --until "…"`.
3. Stop writes (Session Manager): `cd /opt/edh/app && sudo docker compose stop app`.
4. `backup.sh now` — note the key it reports (`db/daily/app-<UTC>.dump`; also in `backup.sh list`).
5. Change `postgres:18-alpine` → `postgres:19-alpine` in `deploy/compose.yml`; commit; ask the user to push or
   merge it into main through their review (prod deploys only exactly `origin/main`).
6. `deploy.sh`. Postgres 19 initialises an empty database; migrations create the schema; the maintenance
   page stays on (deploy only switches off maintenance it switched on itself).
7. `restore.sh db --key <key> --check` — the dump restores into Postgres 19; look at it with the user.
8. `restore.sh db --key <key>` (asks; `EDH_YES=1` after consent). It swaps the restored data in, checks
   `/health`, and **switches maintenance off** — the site is live on 19.
9. Verify with the user. After a few days, delete the old cluster: `sudo rm -rf /data/postgres/18` (ask).

**Way back** (before users write to 19): tag back to `18-alpine`, commit, have it pushed/merged, `deploy.sh` — the old
cluster (as of step 3) serves again; `maint.sh off`. After users wrote to 19, going back loses those writes.
