# Backups and restore

## Layers

| Layer | What | Where |
|---|---|---|
| Database dumps | `pg_dump -Fc` of database `app`, checked readable before upload | S3 backup bucket, `db/<tier>/app-<YYYYMMDDTHHMMSSZ>.dump`; newest 24 also in `/data/backups` |
| Safety dumps | before every deploy and every database restore | `db/safety/` |
| Volume snapshots | the whole `/data` volume (DLM) | daily 18:30 UTC ×7, weekly Sunday 19:30 UTC ×4; `upgrade.sh` adds a pre-upgrade one |
| Uploads | the app's S3 uploads bucket, versioned | overwritten/deleted versions kept 30 days |
| Config | `deploy/` in git | forever |

**Schedule.** `edh-backup.timer` runs every hour at :05. With `backup_schedule: auto` (default) the dump goes
to `db/hourly/` while the database is under 2 GB, and only daily above that; `hourly`/`daily` force it.
At `daily_backup_hour_utc` (default 18) the dump also goes to `db/daily/`, and on the 1st of the month to
`db/monthly/`. `backup.sh now` uploads to `db/daily/`. A single dump is limited to 5 GB (single PUT).
Until the first successful deploy there is no app to back up: the hourly job logs "no app deployed yet" and
exits quietly (no "backup failed" email; the `backup-stale` alarm, if monitoring is on, can still fire then),
while `backup.sh now` fails with that message.

## Retention (S3 lifecycle on the backup bucket)

| Prefix | Kept | Old versions kept |
|---|---|---|
| `db/hourly/` | 3 days | 1 day |
| `db/daily/` (incl. `backup.sh now`) | 90 days | 7 days |
| `db/monthly/` | 365 days (Glacier Instant Retrieval after 30) | 30 days |
| `db/safety/` | 30 days | 7 days |
| `_edh/bundles/` (deploy bundles) | 90 days | 1 day |
| anything else | — | 30 days |

Only these lifecycle rules ever remove backups. Snapshots: 7 daily + 4 weekly (while the DLM policy exists —
after `teardown.sh` they stay until deleted by hand).

## Threat model: why restores trust only the manifest

**A compromised app can add, but not alter or delete, backups; restores verify against a host-only manifest
pinned by VersionId and sha256.**

- The server's IAM role (which the app container can use with `app_uses_instance_role: true`) may only
  *create* objects under `db/` (`If-None-Match: *`): no overwrite, no delete. It could still upload a
  fake `db/daily/app-….dump`.
- Every upload by the backup job is recorded in `/data/backups/manifest.tsv` — key, sha256, S3 VersionId,
  UTC upload time. `/data/backups` is root-only (0700) and `deploy.sh` refuses any compose file that mounts
  it (or the whole data directory) into a container. Entries are dropped once S3 has expired the object.
- `edh-restore.sh` restores **only** keys in the manifest: it downloads that exact VersionId and checks the
  sha256. Anything else is refused ("not in this server's backup manifest") with an alert email — treat
  it as a possible tamper signal.

## Restoring the database

```bash
restore.sh db --latest --check                     # newest backup → side database app_restore_check
restore.sh db --date 2026-10-29 --check            # newest backup uploaded that day (UTC)
restore.sh db --key db/daily/app-20261029T180012Z.dump --check
restore.sh db --date 2026-10-29                    # REPLACE the live database (asks; EDH_YES=1 after consent)
```

- **`--latest` and `--date` are resolved by the server from its manifest** (`edh-restore.sh pick`): the
  newest entry, any tier including `safety`, by recorded upload time; `--date` matches the UTC upload day.
  The bucket is never listed for this. The chosen key and upload time are printed.
- **`--check`** (always do this first): restores into `app_restore_check` while the app keeps serving, counts
  tables, and keeps the database for inspection. Needs free space on `/data` of more than twice the dump.
- **Without `--check`**: dump validated → restored into `app_restore_new` while the app serves → maintenance
  on → safety dump → app stopped → `app` renamed to `app_pre_restore`, `app_restore_new` to `app` →
  app started → `/health` → maintenance off. Any failure alerts and says which database the app now uses.
  The previous data stays in `app_pre_restore` (dropped by the *next* restore, or by hand).

**Copying rows back instead of a full restore** (e.g. "a user deleted records yesterday afternoon"): restore
a dump from before the deletion with `--check`, then on the server (Session Manager):

```bash
cd /opt/edh/app
sudo docker compose exec -T postgres psql -U app -d app_restore_check -c \
  "create table rescued as select * from orders where customer_id = 42"
sudo docker compose exec -T postgres sh -c 'pg_dump -U app -d app_restore_check -t rescued | psql -U app -d app'
sudo docker compose exec -T postgres psql -U app -d app -c \
  "insert into orders select * from rescued on conflict do nothing; drop table rescued"
sudo docker compose exec -T postgres psql -U app -d postgres -c "drop database app_restore_check"
```

Agree the exact rows with the user first; this writes to the live database.

## `--unverified` (manifest lost)

Appropriate only when the manifest cannot know the backup you need:

- the data volume was lost and the server rebuilt with a new, empty volume (empty manifest);
- the volume was restored from a snapshot (`restore.sh disk`) and you need a dump uploaded after that
  snapshot was taken (the manifest is the snapshot's copy).

Not appropriate when a restore was refused for no known reason — that is the tamper signal; investigate.

```bash
backup.sh list 50                                          # what is in the bucket, by upload time (unverified)
restore.sh db --key db/hourly/app-20261030T010512Z.dump --check --unverified
```

- **Requires `--key`**: `--latest`/`--date` are refused with `--unverified` — nothing unverified is ever
  chosen automatically. Pick the key with the user.
- Locally the key must exist in this account's bucket, its name may not be dated in the future, and the
  name must be within 2 h of its S3 upload time (genuine dumps upload within minutes).
- The server downloads the current version without a checksum, logs a warning and **sends an alert**
  ("unverified backup restored"). Ask the user before using it, and `--check` first.

## Restoring the whole data volume

```bash
restore.sh disk --snapshot snap-0123456789abcdef0
```

Creates a volume from the snapshot (same AZ, encrypted, `Protect=true`), stops timers, waits for any
backup/deploy (the server's edh lock), stops the stack, swaps volumes, starts everything and checks
`/health`. The app is offline for a few minutes (no maintenance page possible). The old volume is detached
and **kept**, tagged `edh:role=data-replaced-YYYYMMDD` — delete it by hand once satisfied. If it stops half
way it prints both volumes' state and the exact commands to put the old one back.

Only snapshots tagged with this project's `edh:client`/`edh:env` are accepted (DLM copies the volume's
tags; upgrade.sh tags its own). **`--foreign-snapshot`** accepts any other snapshot — e.g. one made by hand
without tags or copied from elsewhere — after a warning and a confirmation. Make sure it really holds this
client's data.

## Reaching the database

Postgres is not published on the server and there is no SSH. `db.sh tunnel` opens an SSM port-forward from
127.0.0.1 (default port 15432, `--port N`) to the Postgres container; nothing changes on the server (no
published port, no security-group rule). With a command after `--`, the command runs with
`DATABASE_URL=postgres://app:…@127.0.0.1:<port>/app` and the libpq variables (`PGHOST`, `PGPORT`, `PGUSER`,
`PGDATABASE`, `PGPASSWORD`; `PGSERVICE` emptied and `PGSSLMODE=prefer` so your own libpq settings can't redirect it) set
for it alone, and the tunnel closes when it ends; the password is read from SSM
`<path>/_edh/postgres-password` and never printed or logged. Without a command the tunnel stays open until
Ctrl-C. Needs the AWS Session Manager plugin.

```bash
db.sh tunnel -- psql -c 'select 1'      # needs a local psql
```

## Monthly restore drill

- **Automatic**: `edh-drill.timer`, the 2nd of each month at 03:30 UTC. It restores the newest hourly/daily
  manifest entry into a side database, counts tables, drops it, and publishes `RestoreDrillSuccess` (namespace
  `EDH/<client>-<env>`). A failure emails "restore drill FAILED". (No alarm fires if the drill doesn't run.)
- **By hand, monthly** (recommended): `restore.sh db --latest --check`, look at a few key tables in
  `app_restore_check` with the user, then drop it. A backup never restored is a hope, not a backup.

## Restoring when the server is gone

1. **Server gone, data volume intact** (most cases): `provision.sh` — the plan shows the volume `exists` and
   the server `would create` — then `--apply`. The new server goes to the volume's AZ and mounts it without
   formatting. `deploy.sh`, `status.sh`. Database, manifest and certificates are all there. The tagged
   Elastic IP is reused if it still exists (e.g. after `teardown.sh --keep-ip`); otherwise the new server gets
   a new public IP — update the DNS A record (provision prints the IP).
2. **Data volume gone too**: find the newest snapshot
   (`aws ec2 describe-snapshots --owner-ids self --filters Name=tag:edh:client,Values=acme Name=tag:edh:env,Values=prod`).
   `provision.sh --apply` (creates an empty volume), `deploy.sh`, then `restore.sh disk --snapshot snap-…`.
   For data newer than the snapshot, restore a later dump with `--key … --unverified` (see above).
   Without usable snapshots: `deploy.sh`, then `restore.sh db --key <newest dump> --unverified`.
3. **Region down**: see disaster-runbook.md.
