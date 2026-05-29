# Backups & maintenance

A shared host concentrates risk: one volume holds several apps' databases. Backups are not optional, and
a backup you have never restored is a hope, not a backup. This doc covers the three backup layers, how to
verify and restore, and why upgrades are deliberate, separate actions.

## Three layers, defense in depth

Run nightly via cron, **staggered** so they don't contend for I/O. Server timezone is local, but keep
backup **filenames in UTC** to avoid DST-induced ambiguity/collisions.

1. **Logical database dumps** — the portable, granular layer. Postgres: `pg_dumpall` (captures roles +
   all per-app DBs) with portable flags. Mongo: `mongodump --gzip --archive`. Write to
   `/data/backups/` using **atomic write** (`.tmp` then rename, so a half-written dump is never mistaken
   for a good one). Prune local copies after ~14 days (off-host keeps the long tail).

2. **Volume snapshots** — the fast, whole-disk layer. Snapshot the entire data EBS volume (tagged,
   self-pruning by age). Restores the whole host's data state quickly; coarser than logical dumps.
   (Portable equivalent: filesystem/LVM snapshots, or `restic`.)

3. **Off-host sync** — the disaster layer. Sync `/data/backups/` to an object store (S3 or any
   equivalent) with a **lifecycle policy** (e.g. transition to cold storage after 30 days, expire after
   365, versioned). This is what survives the instance, the volume, and the AZ. Because dumps can include
   `/data/secrets`, treat the bucket as sensitive (encryption + tight access).

`scripts/backup.sh` performs the logical-dump + off-host-sync layers; volume snapshots are an AWS-CLI
(or provider) call on a schedule.

## Verify and actually restore

- **Check freshness**: the newest dump is from last night, is non-trivial in size, and isn't a `.tmp`.
  Alert if a night is missing.
- **Restore drill (do this on a schedule, e.g. quarterly)**: restore the latest dump into a throwaway
  database (or a scratch instance) and confirm the data is intact. This is the only thing that proves the
  whole chain works end to end. Document the restore steps so a 3am restore isn't improvised.
- **Restore path**: pull the dump from off-host → restore into the target DB → run the app's migrations
  if needed → point the app at it. For a full-host loss: rebuild the instance, attach (or restore a
  snapshot of) the data volume, bring up the shared stack, redeploy apps from their immutable image tags.
  Because data is on the volume and apps are reproducible from tags, recovery is mechanical.

## Upgrades are deliberate and separated

Keep **host upgrades** and **image upgrades** as distinct actions — never let a routine deploy silently
roll a database onto a new upstream digest:

- **App image upgrade**: just deploy a newer immutable tag for that one app. Scoped, reversible.
- **Shared-service / base-image upgrade** (e.g. a new Postgres minor): a separate, intentional step.
  Record digests before and after, recreate only the changed service, and verify health + a backup
  immediately before doing it. `live-restore: true` keeps app containers running across a Docker daemon
  restart, but a database major-version bump is a planned migration, not an upgrade-in-place.
- **OS patching**: routine `apt upgrade` is fine; a kernel/reboot is a planned window — the EIP and the
  data volume mean the box comes back at the same address with the same data, but confirm the shared
  stack and all apps are `Up` afterward.

## Routine health checks

- `scripts/discover-host.sh` for a quick "is everyone Up, what's using the ports, how full is `/data`".
- Watch **disk on `/data`** — logical dumps + DB growth are the usual culprits; the 14-day local prune
  and log rotation keep it bounded, but check.
- Per app: `curl https://<fqdn>/health` and `docker inspect -f '{{.State.Health.Status}}' <app>-<env>`.
- After *any* maintenance, the closing step is always the same as after a deploy: **prove the neighbors
  are still up.**
