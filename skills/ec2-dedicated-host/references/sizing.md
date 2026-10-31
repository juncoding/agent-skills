# Sizing the server and the disk

## The formula (`scripts/sizing.sh`, used when `instance_type: auto`)

```
need = 768 MB base (Caddy 256 MB limit + Postgres 512 MB limit) + app_memory_mb + 900 MB if uses_gotenberg
choose the smallest t4g with need ≤ 60 % of its RAM (≥ 40 % headroom for the OS, page cache, spikes)
```

| need | Server | RAM | e.g. |
|---|---|---|---|
| ≤ 1228 MB | t4g.small | 2 GB | default app (768 MB) → 1536 MB → **t4g.medium**; a 384 MB app → 1152 MB → t4g.small |
| ≤ 2457 MB | t4g.medium | 4 GB | 768 MB app + Gotenberg → 2436 MB → t4g.medium |
| ≤ 4915 MB | t4g.large | 8 GB | 1.5 GB app + Gotenberg |
| ≤ 9830 MB | t4g.xlarge | 16 GB | |
| more | — | — | refused: set `instance_type` by hand |

`app_memory_mb` is also the app container's hard memory limit, so measure before lowering it.
`provision.sh` prints the chosen type in the plan; `instance_type: t4g.large` (any arm64 type) overrides it.
The images are arm64-only: non-Graviton types are refused.

## Measure real usage

On the server (Session Manager), never with commands that print the environment:

```bash
sudo docker stats --no-stream                                  # current memory per container
cid=$(sudo docker compose --project-directory /opt/edh/app ps -q app)
cat /sys/fs/cgroup/system.slice/docker-$cid.scope/memory.peak  # app's peak since it started (bytes)
free -m                                                        # whole server (status.sh shows it too)
```

Run it after a busy day. Set `app_memory_mb` to roughly peak × 1.3, then compare the formula with the
current server.

## When to change size

| Signal | Action |
|---|---|
| `mem-high` alarms, app restarts (OOM) | larger t4g (`resize.sh instance t4g.large`), or raise `app_memory_mb` if the server has room |
| `cpu-surplus-charged` keeps firing, `cpu-high` during normal hours | the load is not bursty: move to **m8g** (`resize.sh instance m8g.large`), which has no credit limits; unlimited-mode surplus credits on a busy t4g can cost more than m8g |
| `disk-data-warn` (80 %) | `resize.sh disk <GB>` — online, no downtime |
| `disk-root-warn` | usually images/logs: images are pruned to 3 per deploy and logs capped at 3 × 10 MB; check `sudo docker system df` |

## Resizing

```bash
resize.sh instance t4g.large   # asks; stop → change type → start → app up + /health; 3–5 min offline
resize.sh disk 40              # asks; grows the data volume and its filesystem online
```

- Instance: the type must support arm64 and be offered in the server's AZ (checked before stopping). The
  Elastic IP, data volume and everything on it stay. No maintenance page is possible while stopped. If EC2
  refuses the new type (e.g. no capacity), the server is started again on the old type. Afterwards set
  `instance_type:` in `deploy.yml`; with monitoring on, the alarms are re-created for the new type.
- Disk: grow only (EBS can't shrink), at most one change per volume every 6 hours (AWS limit). Afterwards set
  `data_volume_gb:` in `deploy.yml`.
- Both: ask the user first, and pick a quiet time for the instance resize.
