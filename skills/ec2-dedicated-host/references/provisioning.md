# Provisioning — `provision.sh`

`provision.sh` creates (or verifies) every AWS resource for one client's server. It reads
`deploy/deploy.yml`, finds existing resources **by tag**, and creates only what is missing.

```bash
bash <skill>/scripts/provision.sh            # plan: read-only, changes nothing
EDH_YES=1 bash <skill>/scripts/provision.sh --apply   # after the user approved the plan and the cost
```

(`--apply` itself does not prompt; the approval happens in the conversation.)

## Plan, then apply

1. **Account check.** The STS account must equal `account_id` (if set). Pin it: `init.sh --account-id`.
2. **Read-only preflight** — nothing is changed until all of these pass:
   - both bucket names: missing (404) is fine, owned by this account is fine; **owned by anyone else, or
     unreadable → refuse** (`head-bucket --expected-bucket-owner`). Bucket names are global.
   - the instance type supports **arm64** (`describe-instance-types`), else refuse.
   - at most one server, one data volume and one Elastic IP carry this client's tags; more → refuse.
   - placement: an existing server fixes the AZ (data volume must be in the same AZ). A new server goes to
     the data volume's AZ if one exists, else the first AZ (sorted) that offers the type **and** has a
     default subnet. **A default VPC is required.**
   - a server without a tagged data volume: the plan warns, `--apply` refuses — it never creates an empty
     data volume for a running server (find, re-tag or restore the old one first).
3. **Plan output**: one line per resource — `exists`, `would create`, `would sync` — plus the server type,
   disk size, domain, monitoring, and the instance-metadata hop limit. Show it to the user with the cost.
4. **`--apply`** creates what is missing, re-applies the idempotent settings (bucket settings, lifecycle,
   security-group rules, role policies, hop limit), attaches the volume, associates the IP, creates the
   snapshot policy, waits for bootstrap, runs `monitoring.sh add` (if `monitoring: cloudwatch`) and prints
   the DNS record to create.

Re-running is always safe: a run that stopped half way is completed by the next one. Nothing is deleted.
If the configured `instance_type` differs from the running server's, provision only warns — use `resize.sh`.

## What gets created (client `acme`, env `prod`, account `123456789012`)

| Resource | Name | Notes |
|---|---|---|
| IAM role + instance profile | `edh-acme-prod-host` | `AmazonSSMManagedInstanceCore` + inline `edh-host` (and `edh-cwagent` with monitoring) |
| Security group | `edh-acme-prod` | TCP 80/443 (IPv4+IPv6), UDP 443 (IPv4, HTTP/3). **No port 22.** |
| Backup bucket | `edh-acme-prod-backups-123456789012` | versioned, public access blocked, lifecycle (see backup-restore.md), `Protect=true` |
| Uploads bucket | `edh-acme-prod-uploads-123456789012` | versioned, public access blocked, noncurrent versions kept 30 days, `Protect=true` |
| ECR repository | `edh/acme` | scan on push, keeps the last 20 images; shared by all envs of client `acme` |
| Internal secrets | `/acme/prod/_edh/postgres-password`, `/acme/prod/_edh/maint-bypass` | 40 hex chars, SecureString, never overwritten |
| Data volume | `edh-acme-prod-data` | gp3, encrypted, `data_volume_gb` (default 20), `edh:role=data`, `edh:snapshot=acme-prod`, `Protect=true` |
| Elastic IP | `edh-acme-prod` | stable address for DNS |
| Server | `edh-acme-prod` | Ubuntu 24.04 arm64 (latest AMI via SSM public parameter), 20 GB gp3 encrypted root (deleted with the server), IMDSv2 required, termination protection on |
| Snapshot policy (DLM) | `edh-acme-prod-snapshots` | targets `edh:snapshot=acme-prod`: daily 18:30 UTC ×7, weekly Sun 19:30 UTC ×4 (creates `AWSDataLifecycleManagerDefaultRole` if the account has none) |

**Tags on everything:** `Name`, `edh:client`, `edh:env`, `Client` (activate it as a cost-allocation tag
to see per-client cost), `ManagedBy=ec2-dedicated-host`.

The server boots with `assets/host/bootstrap.sh` (cloud-init): Docker + Compose ≥ 2.30, AWS CLI (snap),
unattended security upgrades without automatic reboot, the data volume mounted at `/data` by UUID with
`nofail` (formatted **only** if the device is blank — never on a probe error), Docker made to require the
`/data` mount, 1 GB swap. It ends with `/var/lib/edh/bootstrap-done` or `bootstrap-failed`; on failure
provision stops and points at `/var/log/edh-bootstrap.log` (read it with Session Manager).

## Instance metadata: `app_uses_instance_role`

| Value | Hop limit | Effect |
|---|---|---|
| `true` (default) | 2 | The **app container** can use the server's IAM role — needed for S3 uploads without keys. |
| `false` (`init.sh --no-instance-role`) | 1 | No container can reach instance metadata; only the host itself uses the role. |

Trade-off: with hop limit 2, a compromised app holds the role's permissions. The role is per client and
least-privilege, and what it grants (this client's own secrets, backups and uploads) the app largely has
already — its secrets are in its environment and the database is its own. What it **cannot** do even with
the role: read other clients' parameters, overwrite or delete backups, or touch the backup manifest (see
backup-restore.md). Changing the value and re-running `provision.sh --apply` updates a running server.

## Per-client IAM isolation (inline policy `edh-host`)

- **SSM**: read only `/<client>/<env>` and below; an explicit **Deny** on reading any other parameter
  (except AWS public `/aws/service/*`), so the managed SSM policy can't widen it. Decrypt only via SSM.
- **Backups**: `s3:PutObject` only under `db/*`, only with `If-None-Match: *` (create-only, **write-once**)
  and only in this account (`s3:ResourceAccount`); read (by version) of the backup bucket's objects, no listing; **no delete**.
- **Uploads**: get/put/delete/list on the uploads bucket only.
- **ECR**: pull from `edh/<client>` only.
- **CloudWatch**: `PutMetricData` only into namespace `EDH/<client>-<env>` (the backup heartbeat); the agent
  (monitoring module) only into `CWAgent/<client>-<env>`. One client's server can't fake another's metrics.
- **SNS**: publish to this client's alert topic only.
- Every local S3 call passes `--expected-bucket-owner <account>`.

## Costs (ap-southeast-1, on demand, approximate)

| Item | ~USD / month |
|---|---|
| t4g.small (2 GB) / t4g.medium (4 GB) / t4g.large (8 GB) / t4g.xlarge (16 GB) | 15 / 31 / 62 / 124 |
| Public IPv4 (Elastic IP) | 3.6 |
| Root 20 GB + data 20 GB gp3 | 4 |
| Snapshots, S3 backups/uploads, ECR | ~1 (grows with data) |
| Monitoring module | ~4 |

t4g instances run in **unlimited** credit mode (AWS default; provision does not change it): sustained CPU
above the baseline is billed as surplus credits instead of being throttled. See sizing.md.

## DNS (after `--apply`)

Provision prints: `point an A record for app.example.com to <Elastic IP>`. The user creates it at their
DNS provider. Check with `dig +short app.example.com`; deploy warns (but continues) while it doesn't match,
and Caddy can only obtain the HTTPS certificate once it does.

## Removing it again

`teardown.sh` removes the server, Elastic IP, security group, DLM policy, IAM role/profile and monitoring.
It **keeps** the data volume, both buckets, the ECR repo, SSM parameters and existing snapshots (which no
longer expire once the policy is gone). Re-running `provision.sh --apply` reuses all of it. A rebuilt server
gets a **new public IP** (update the DNS A record) — unless `teardown.sh --keep-ip` kept the Elastic IP
(~$3.60/month while unattached), which provision then reuses.
