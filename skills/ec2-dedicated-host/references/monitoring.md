# Monitoring (optional module)

`monitoring: cloudwatch` (default) or `none` in `deploy.yml`. With `cloudwatch`, `provision.sh --apply`
runs `monitoring.sh add`; it can be added or removed any time. About **$4/month** per client. Email only.

```bash
monitoring.sh add       # idempotent: topics, subscriptions, agent, alarms, health check
monitoring.sh status    # each alarm: name, state, actions enabled (False while maintenance pauses it)
monitoring.sh remove    # asks first; deletes only what add creates (exact names), never data
```

## Alarms (client `acme`, env `prod`)

Every alarm emails on ALARM **and** on recovery (OK).

| Alarm | Metric | Fires when | Missing data |
|---|---|---|---|
| `edh-acme-prod-site-down` (us-east-1) | Route 53 health check of `https://<domain>/health` (HTTPS, SNI, every 30 s, unhealthy after 3 failures) | `HealthCheckStatus` minimum < 1 in a 1-minute period | breaching |
| `edh-acme-prod-disk-root-warn` / `-crit` | `CWAgent/acme-prod` `disk_used_percent`, `path=/` | max > 80 % / > 90 % over 5 min | missing |
| `edh-acme-prod-disk-data-warn` / `-crit` | same, `path=/data` | max > 80 % / > 90 % over 5 min | missing |
| `edh-acme-prod-mem-high` | `CWAgent/acme-prod` `mem_used_percent` | average > 90 % for 2 × 5 min | missing |
| `edh-acme-prod-cpu-high` | `AWS/EC2` `CPUUtilization` | average > 80 % for 3 × 5 min | missing |
| `edh-acme-prod-cpu-surplus-charged` (t-family only) | `AWS/EC2` `CPUSurplusCreditsCharged` | sum > 0 in 1 h (unlimited mode is billing CPU above the baseline) | not breaching |
| `edh-acme-prod-status-check` | `AWS/EC2` `StatusCheckFailed` | max ≥ 1 for 2 × 1 min | missing (a late datapoint is no failure; a dead server trips site-down) |
| `edh-acme-prod-backup-stale` | `EDH/acme-prod` `BackupFresh` (dims `Client=acme`, `Env=prod`) | sum < 1 for 2 × 1 h | breaching |

- Disk alarms use the dimensions `InstanceId`, `path`, `fstype=ext4`. To see what the agent really
  publishes: `aws cloudwatch list-metrics --namespace CWAgent/acme-prod --metric-name disk_used_percent`.
- On a non-t server (e.g. after `resize.sh instance m8g.large`) there are no burst credits: `add` skips the
  credit alarm and deletes a stale one. `resize.sh instance` re-runs `add` for you.
- Alarm names are always exact, never a prefix (`edh-acme-prod-` is also the start of a client named
  `acme-prod`'s names).
- Expect site-down and status-check emails during `resize.sh instance` and reboots (the server is off).
- On a new server, site-down and backup-stale are in ALARM until the first deploy and the first hourly backup
  after it (the emails arrive once the subscriptions are confirmed); both send a recovery email then.
- The CPU credit alarm watches the cost, not the balance: t4g runs in unlimited mode and starts with 0
  credits, so a low balance means nothing by itself. `cpu-surplus-charged` fires when AWS bills surplus credits.

## BackupFresh — stale backups

Every hourly run of the backup job publishes `BackupFresh=1` while the **last successful upload** is younger
than the schedule allows (2 h for hourly, 26 h for daily backups) — also in the hours a daily schedule
uploads nothing. When uploads stop (failing dumps, S3 refused, timer dead, server down), the heartbeat stops
and `backup-stale` fires within about two hours. A failed backup also emails "backup failed" at once. Even
with `monitoring: none`, `status.sh` shows `last upload: … ← STALE`.

## Alert emails: two SNS topics

Topic `edh-acme-prod-alerts` exists in the app region (alarms, and alerts the server sends itself) **and in
us-east-1** (the site-down alarm: Route 53 health-check metrics live there). So when the app region is not
us-east-1, **each address receives two "AWS Notification - Subscription Confirmation" emails** and must
click both links (in us-east-1 itself there is one topic and one email); until then it gets nothing from
that topic.

- `add` reports every unconfirmed address ("has not confirmed … check that inbox (and spam)") and doesn't
  subscribe it again. AWS deletes unconfirmed subscriptions after a few days; then `add` subscribes the address again.
- `add` keeps the subscriptions in step with `alert_emails`, in both regions: new addresses are subscribed,
  and **any** confirmed email subscription whose address is not in `alert_emails` is unsubscribed and
  reported — including one added by hand in the console. A **pending** one can't be removed through the API:
  `add` reports it as pending; it expires unconfirmed. Addresses compare case-insensitively; non-email
  subscriptions (e.g. an HTTPS endpoint added by hand) are left alone.

Messages the server sends itself (app-region topic; with `monitoring: none` they are only logged): backup
failed, deploy rolled back / failed / aborted, SITE DOWN after deploy or rollback, rollback failed, restore
failed / app unhealthy, restore refused (backup not in manifest — sent by `restore.sh db … --check`; a real
restore of such a key sends "restore failed" instead), unverified backup restored, restore drill FAILED.

## Maintenance pauses the site alarm

`maint.sh on` disables the actions of `edh-acme-prod-site-down`; `maint.sh off` re-enables them. The alarm
still changes state, it just doesn't email. Other alarms are not paused. Maintenance switched on by the
server itself (`deploy.sh --maint`, a database restore) does not pause it; `/health` keeps answering.

## The CloudWatch agent

`add` installs the agent over SSM if missing (the `.deb` from `amazoncloudwatch-agent.s3.amazonaws.com`) and
configures it from `assets/host/cwagent.json`: memory and disk (`/`, `/data`) every 60 s, into namespace
`CWAgent/<client>-<env>`. Its permissions are the inline policy `edh-cwagent`: `PutMetricData` only into that
namespace, plus `ec2:DescribeTags` — never the managed `CloudWatchAgentServerPolicy`, which
would let one client's server publish into another client's namespaces and hide its alarms.

**Known limitation:** the agent `.deb` is downloaded over HTTPS but its signature is **not verified**
before `dpkg -i`.

## Removing it

`remove` (asks first) deletes the 10 alarms by name in both regions, both topics (and their subscriptions),
this client's Route 53 health checks (tagged `edh:client`/`edh:env` **and** `ManagedBy=ec2-dedicated-host`),
stops the agent and deletes the `edh-cwagent` policy. Then set `monitoring: none` in `deploy.yml`, commit,
get it into main and redeploy, so the server stops publishing to the deleted topic. Data is never touched.

Changing the domain: re-run `add` — it creates the new health check first, then deletes the old one.
