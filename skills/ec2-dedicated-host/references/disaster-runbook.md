# Disaster runbook

First, always: **`status.sh`** (read-only). Then the matching section. Anything that stops the site or
touches data: tell the user what you will do and wait for a yes. Server commands below run in a Session
Manager shell (`aws ssm start-session --target <instance-id>`; no SSH). Never print the app's environment.

## Site down right after a deploy

- **Symptom:** deploy says `no healthy version is running — the site may be down`; "SITE DOWN after deploy" email.
- **First:** `status.sh`, then `cd /opt/edh/app && sudo docker compose logs --tail 200 app postgres`.
- **Fix:** if the previous version can run, `rollback.sh` (asks). If the new release broke the database
  schema, fix forward, or restore the pre-deploy dump (`db/safety/…`): `restore.sh db --key … --check`, then
  without `--check` after consent. A failed deploy that left maintenance on: `maint.sh off` once healthy.

## Server unreachable

- **Symptom:** site down and `status.sh` can't reach the server over SSM; `status-check` alarm.
- **First:** `aws ec2 describe-instance-status --instance-ids <id> --include-all-instances` (state, system
  and instance checks).
- **Fix:**
  - instance check failing (OS hung, out of memory): `aws ec2 reboot-instances --instance-ids <id>` (ask).
  - system check failing (AWS hardware): stop and start the instance (ask; moves it to new hardware,
    3–5 min); the Elastic IP and data volume stay.
  - SSM online but the site down: Docker refuses to start without `/data`
    (`mountpoint /data`, `sudo journalctl -b -u docker`); see "Data volume lost" if it is missing.
  - root disk or OS beyond repair: rebuild from the data volume — `EDH_CONFIRM_NAME=<client>-<env>
    teardown.sh --keep-ip` (keeps the volume and the Elastic IP), `provision.sh` → `--apply`, `deploy.sh`.
    Without `--keep-ip` the Elastic IP is released and the rebuilt server gets a **new public IP**: the
    DNS A record must be updated (`provision.sh --apply` prints the new IP; `status.sh` shows it).

## Disk full

- **Symptom:** `disk-data-*` / `disk-root-*` alarm; backups fail; Postgres refuses writes.
- **First:** `status.sh` (disk section), then `sudo du -xh --max-depth=1 /data | sort -h` or
  `sudo docker system df`.
- **Fix:** `/data`: `resize.sh disk <bigger>` (online; asks). Local dumps in `/data/backups` are copies of
  S3 (newest 24 kept); never delete `manifest.tsv`. Root: `sudo journalctl --vacuum-size=200M`,
  `sudo docker image prune -f`. Don't prune all images: the previous one is the rollback target.

## Deploy stuck

- **Symptom:** deploy.sh waits for a long time, or says `still running on the server after the timeout`.
- **First:** `status.sh`; `aws ssm list-commands --instance-id <id> --max-items 5` (status of recent commands).
- **Fix:** another edh operation (backup, restore, drill) holds the server's lock: the deploy waits up to
  10 min, then fails without changing anything. Migrations are cut off after 15 min and the old version keeps
  serving. Don't start a second deploy meanwhile. When it has ended, `status.sh` shows the image running.

## A table or rows lost (user error)

- **Symptom:** "a user deleted records yesterday afternoon".
- **First:** `restore.sh db --date <day before> --check` (or `--key` of a dump from just before the loss).
- **Fix:** copy the rows back from `app_restore_check` (backup-restore.md, "Copying rows back"). A full
  `restore.sh db` loses every write since that dump — only with the user's explicit consent.

## Data volume lost or corrupted

- **Symptom:** `/data` missing or unreadable, Postgres won't start, `find_data_volume` errors.
- **First:** `aws ec2 describe-snapshots --owner-ids self --filters Name=tag:edh:client,Values=<client> Name=tag:edh:env,Values=<env> --query 'sort_by(Snapshots,&StartTime)[].[SnapshotId,StartTime]'`.
- **Fix:** `restore.sh disk --snapshot <newest good>` (asks; the broken volume is kept). Snapshots are at most
  a day old: then restore a newer dump with `restore.sh db --key … --unverified` (backup-restore.md).
  If the volume is gone entirely, follow "Restoring when the server is gone" in backup-restore.md.

## Region outage

- **Symptom:** the whole AWS region is down — and the server, its snapshots and the backup bucket all live in it.
- **First:** wait for AWS status if the outage is short; agree with the user whether to rebuild elsewhere.
- **Fix (by hand, not automated):** backups are **not** copied to another region by default. If the old
  bucket is still readable, in a new region: use a new env name (bucket names are global, so
  `edh-<client>-<env>-backups-<account>` can't be re-created elsewhere), `init.sh`/edit `region` and `env`,
  `provision.sh --apply`, `deploy.sh`, copy the newest dump into the new bucket
  (`aws s3 cp s3://<old>/db/daily/<f> s3://<new>/db/daily/<f>`), `restore.sh db --key … --unverified`,
  then point DNS at the new IP. For real cross-region protection, add S3 replication to the backup bucket.

## Alert emails not arriving

- **Symptom:** an alarm is red in `monitoring.sh status` but nobody got mail; or no "OK" mails.
- **First:** `aws sns list-subscriptions-by-topic --topic-arn arn:aws:sns:<region>:<account>:edh-<client>-<env>-alerts`
  (and the same with `--region us-east-1`).
- **Fix:** `PendingConfirmation` → the address must click the confirmation (two emails, one per topic;
  check spam). Missing → re-run `monitoring.sh add`. `ActionsEnabled False` on site-down → maintenance is
  still on (`maint.sh off`). Test delivery: `aws sns publish --topic-arn … --subject test --message test`.
  With `monitoring: none` the server's own alerts are only logged.

## Backups stale or the drill failed

- **Symptom:** `backup-stale` alarm, "backup failed" or "restore drill FAILED" email; `status.sh` shows `STALE`.
- **First:** `sudo journalctl -u edh-backup -n 100` (or `-u edh-drill`).
- **Fix:** typical causes are a full disk, Postgres down, or S3 refusing (a dump over 5 GB can't be uploaded).
  Fix the cause, then `backup.sh now` and `restore.sh db --latest --check`.
