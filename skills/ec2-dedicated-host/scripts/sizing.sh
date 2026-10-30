#!/usr/bin/env bash
# sizing.sh — pick an instance type. Source after lib.sh.
# Need = 768 MB base (OS, Caddy, Postgres) + app memory + 900 MB if Gotenberg.
# Choose the smallest t4g whose RAM keeps >= 40 % headroom (need <= 60 % of RAM).

EDH_BASE_MB=768
EDH_GOTENBERG_MB=900

# recommend_instance <app_memory_mb> <uses_gotenberg:true|false>
recommend_instance() {
  local app="$1" got="$2" need t mem
  need=$((EDH_BASE_MB + app))
  if [[ "$got" == true ]]; then need=$((need + EDH_GOTENBERG_MB)); fi
  for t in t4g.small:2048 t4g.medium:4096 t4g.large:8192 t4g.xlarge:16384; do
    mem="${t#*:}"
    if (( need * 10 <= mem * 6 )); then echo "${t%%:*}"; return 0; fi
  done
  die "needs ${need} MB, more than t4g.xlarge allows — choose instance_type manually"
}
