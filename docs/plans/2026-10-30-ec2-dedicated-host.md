# ec2-dedicated-host Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the `ec2-dedicated-host` skill. It runs one client's system on one dedicated EC2 server, from provisioning through deploy, maintenance, backup/restore, monitoring and upgrades, as designed in `docs/plans/2026-10-30-ec2-dedicated-host-design.md`.

**Architecture:** The skill has two kinds of scripts.

1. **Local scripts** (`skills/ec2-dedicated-host/scripts/*.sh`) run on the operator's Mac. They:
   - read the project's `deploy/deploy.yml`
   - talk to AWS with the CLI
   - reach the server only through SSM Run Command, never SSH
2. **Host scripts** (`assets/host/edh-*.sh`) run on the server. They are shipped in a per-release bundle through S3, and they do the actual work: compose, backups, restore, maintenance flag.

The project's `deploy/` folder is the source of truth for its server.

**Tech Stack:**
- Bash: local scripts must run on macOS bash **3.2**; host scripts run on Ubuntu bash 5.
- AWS CLI v2: EC2, IAM, S3, SSM, ECR, DLM, CloudWatch, SNS, Route 53.
- Docker Compose v2, Caddy 2.10, Postgres 18.
- Tests: plain bash plus a stub `aws`; shellcheck runs in Docker.

---

## Conventions (read before Task 1)

- **Prefix:** `EDH` (ec2-dedicated-host) on every variable, file and AWS name.
- **Naming** (`client=acme`, `env=prod`):

  | Item | Name |
  |---|---|
  | `EDH_NAME` | `acme-prod` |
  | `EDH_PREFIX` | `edh-acme-prod` |
  | IAM role and instance profile | `edh-acme-prod-host` |
  | Security group | `edh-acme-prod` |
  | Buckets | `edh-acme-prod-backups-<account>`, `edh-acme-prod-uploads-<account>` |
  | ECR repo | `edh/acme` |
  | SSM path | `/acme/prod/…`; skill-internal values under `/acme/prod/_edh/…` |
  | SNS topic | `edh-acme-prod-alerts`, in the app region and in us-east-1 |
  | Alarms | `edh-acme-prod-<check>` |

- **Tags on every resource:**
  - `Name`, `edh:client`, `edh:env`, `Client` (for cost allocation) and `ManagedBy=ec2-dedicated-host`.
  - Data volume and buckets also get `Protect=true`.
  - The data volume also gets `edh:role=data` and `edh:snapshot=<EDH_NAME>`.
- **Bash 3.2 rules for `scripts/*.sh`:**
  - No `mapfile`, associative arrays, `${x,,}` or `local -n`.
  - Use `openssl rand -hex`, not `tr </dev/urandom | head`, which breaks under `pipefail`.
- **No secrets on command lines or in logs.** Secrets travel through SSM SecureString into files with mode 0600.
- **Host script paths can be overridden for tests:** `EDH_ENV_FILE`, `EDH_APP_DIR`, `EDH_DATA_DIR`, `EDH_BIN_DIR`, `EDH_NO_SYSTEMD=1`, `EDH_SKIP_PULL=1`.
- **Commits:** one per task, conventional style, ending with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Test commands:**
  - `bash tests/ec2-dedicated-host/run.sh --fast` runs unit tests and shellcheck.
  - Without `--fast`, it also runs the Docker integration tests.

---

### Task 1: Test harness and skill skeleton

**Files:**
- Create: `tests/ec2-dedicated-host/assert.sh`
- Create: `tests/ec2-dedicated-host/run.sh`
- Create: `tests/ec2-dedicated-host/test_smoke.sh`
- Create: `skills/ec2-dedicated-host/scripts/lib.sh` (logging only for now)

**Step 1: Write assert helpers**

```bash
# tests/ec2-dedicated-host/assert.sh
# Minimal assertions for the ec2-dedicated-host tests (no bats dependency). Source, don't run.
FAILS=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILS=$((FAILS + 1)); }
assert_eq()           { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (expected '$2', got '$1')"; fi; }
assert_contains()     { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (missing '$2')"; fi; }
assert_not_contains() { if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3 (unexpected '$2')"; fi; }
assert_status()       { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (exit $1, expected $2)"; fi; }
finish() { if (( FAILS == 0 )); then echo "  all passed"; exit 0; else echo "  $FAILS failed"; exit 1; fi; }

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/../.." && pwd)"
SKILL_DIR="$REPO_DIR/skills/ec2-dedicated-host"
# Always exercise scripts with the system bash (3.2 on macOS), even if a newer bash is first on PATH,
# so a bash-4-only feature in scripts/*.sh fails here instead of on a user's Mac.
bash() { /bin/bash "$@"; }
```

**Step 2: Write the runner**

```bash
#!/usr/bin/env bash
# tests/ec2-dedicated-host/run.sh [--fast]
# Runs every test_*.sh, then shellcheck. --fast skips Docker integration tests (test_int_*.sh).
set -uo pipefail
cd "$(dirname "$0")"
rc=0
for t in test_*.sh; do
  if [[ "${1:-}" == --fast && "$t" == test_int_* ]]; then continue; fi
  echo "== $t"
  /bin/bash "$t" || rc=1   # system bash on purpose (3.2 on macOS) — see assert.sh
done
echo "== shellcheck"
repo="$(cd ../.. && pwd)"
docker run --rm -v "$repo":/w -w /w koalaman/shellcheck:v0.10.0 -x -S warning \
  skills/ec2-dedicated-host/scripts/*.sh skills/ec2-dedicated-host/assets/host/*.sh || rc=1
exit $rc
```

**Step 3: Write a failing smoke test**

```bash
# tests/ec2-dedicated-host/test_smoke.sh
. "$(dirname "$0")/assert.sh"
out=$(bash -c ". '$SKILL_DIR/scripts/lib.sh'; ok hello" 2>&1)
assert_contains "$out" "hello" "lib.sh loads and ok() logs"
finish
```

Run: `bash tests/ec2-dedicated-host/run.sh --fast`
Expected: FAIL (lib.sh missing).

**Step 4: Create `lib.sh` with logging**

```bash
#!/usr/bin/env bash
# Shared helpers for ec2-dedicated-host local scripts (run on the operator's machine). Source, don't run.
# Must stay compatible with macOS bash 3.2.
set -euo pipefail

EDH_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
```

**Step 5: Run.** Expected: smoke passes and shellcheck passes.

**Step 6: Commit** `test(ec2-dedicated-host): add test harness and lib skeleton`

---

### Task 2: Config loading and validation

**Files:**
- Modify: `skills/ec2-dedicated-host/scripts/lib.sh`
- Create: `skills/ec2-dedicated-host/assets/project/deploy.yml`
- Create: `tests/ec2-dedicated-host/test_config.sh`

**Step 1: Template `assets/project/deploy.yml`.** This is also the fixture used in tests.

```yaml
# ec2-dedicated-host settings for this project. Flat `key: value` only (no nesting, no lists).
client: acme                 # lowercase letters/digits/dashes; names every AWS resource
env: prod
region: ap-southeast-1
domain: app.example.com      # A record must point at the server's Elastic IP
alert_emails: ops@example.com            # comma-separated; required when monitoring: cloudwatch
monitoring: cloudwatch       # cloudwatch | none
instance_type: auto          # auto = sized from app_memory_mb + uses_gotenberg
data_volume_gb: 20
app_port: 3000
app_memory_mb: 768           # container memory limit; also drives sizing
uses_gotenberg: false        # true adds the PDF renderer (gotenberg) service
backup_schedule: auto        # auto (hourly < 2 GB, else daily) | hourly | daily
daily_backup_hour_utc: 18
migrate_cmd: ""              # e.g. npx prisma migrate deploy  (no single quotes)
dockerfile: Dockerfile
build_context: .
```

**Step 2: Failing tests**

```bash
# tests/ec2-dedicated-host/test_config.sh
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp "$SKILL_DIR/assets/project/deploy.yml" "$T/deploy.yml"

load() { bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$1'; echo \"\$EDH_NAME|\$EDH_PREFIX|\$EDH_SSM_PATH|\$EDH_ECR_REPO|\$EDH_MONITORING|\$EDH_MIGRATE_CMD\"" 2>&1; }

assert_eq "$(load "$T/deploy.yml")" "acme-prod|edh-acme-prod|/acme/prod|edh/acme|cloudwatch|" "derives names from template"

sed -i '' 's/^migrate_cmd: .*/migrate_cmd: "npm run migrate"   # comment/' "$T/deploy.yml"
assert_contains "$(load "$T/deploy.yml")" "|npm run migrate" "strips quotes and trailing comments"

sed 's/^client: .*/client: Acme_Corp/' "$SKILL_DIR/assets/project/deploy.yml" > "$T/bad.yml"
assert_contains "$(load "$T/bad.yml")" "client must be" "rejects invalid client"

sed 's/^alert_emails: .*/alert_emails:/' "$SKILL_DIR/assets/project/deploy.yml" > "$T/bad2.yml"
assert_contains "$(load "$T/bad2.yml")" "alert_emails required" "requires emails with cloudwatch"

sed "s/^migrate_cmd: .*/migrate_cmd: echo 'x'/" "$SKILL_DIR/assets/project/deploy.yml" > "$T/bad3.yml"
assert_contains "$(load "$T/bad3.yml")" "single quotes" "rejects single quotes in migrate_cmd"

assert_contains "$(load "$T/missing.yml")" "config not found" "missing file is reported"
finish
```

Note: `sed -i ''` is BSD sed syntax. These tests run on macOS.

Run: `bash tests/ec2-dedicated-host/test_config.sh`. Expected: FAIL (`load_config` not defined).

**Step 3: Implement in `lib.sh`**

```bash
# cfg_get <file> <key> [default] — value of a flat `key: value` line; strips quotes and trailing comments.
cfg_get() {
  local file="$1" key="$2" def="${3-}" val
  val=$(awk -v k="$key" '
    BEGIN { q = sprintf("%c", 39) }
    $0 ~ "^" k ":" {
      sub("^" k ":[ \t]*", ""); sub(/\r$/, ""); sub(/[ \t]+#.*$/, ""); sub(/[ \t]+$/, "")
      f = substr($0, 1, 1)
      if ((f == "\"" || f == q) && length($0) >= 2) $0 = substr($0, 2, length($0) - 2)
      print; exit
    }' "$file")
  printf '%s' "${val:-$def}"
}

# load_config [path] — read deploy.yml into EDH_* variables and validate them.
load_config() {
  local f="${1:-deploy/deploy.yml}"
  [[ -f "$f" ]] || die "config not found: $f (run from the project root, or create it with init.sh)"
  EDH_CONFIG="$f"
  EDH_CLIENT=$(cfg_get "$f" client)
  EDH_ENV=$(cfg_get "$f" env prod)
  EDH_REGION=$(cfg_get "$f" region ap-southeast-1)
  EDH_DOMAIN=$(cfg_get "$f" domain)
  EDH_ALERT_EMAILS=$(cfg_get "$f" alert_emails)
  EDH_MONITORING=$(cfg_get "$f" monitoring cloudwatch)
  EDH_INSTANCE_TYPE=$(cfg_get "$f" instance_type auto)
  EDH_DATA_GB=$(cfg_get "$f" data_volume_gb 20)
  EDH_APP_PORT=$(cfg_get "$f" app_port 3000)
  EDH_APP_MEMORY_MB=$(cfg_get "$f" app_memory_mb 768)
  EDH_USES_GOTENBERG=$(cfg_get "$f" uses_gotenberg false)
  EDH_BACKUP_SCHEDULE=$(cfg_get "$f" backup_schedule auto)
  EDH_DAILY_HOUR_UTC=$(cfg_get "$f" daily_backup_hour_utc 18)
  EDH_MIGRATE_CMD=$(cfg_get "$f" migrate_cmd "")
  EDH_DOCKERFILE=$(cfg_get "$f" dockerfile Dockerfile)
  EDH_BUILD_CONTEXT=$(cfg_get "$f" build_context .)
  validate_config
  EDH_NAME="${EDH_CLIENT}-${EDH_ENV}"
  EDH_PREFIX="edh-${EDH_NAME}"
  EDH_SSM_PATH="/${EDH_CLIENT}/${EDH_ENV}"
  EDH_ECR_REPO="edh/${EDH_CLIENT}"
}

validate_config() {
  [[ "$EDH_CLIENT" =~ ^[a-z][a-z0-9-]{1,20}$ ]] || die "client must be 2-21 lowercase letters/digits/dashes: '$EDH_CLIENT'"
  [[ "$EDH_ENV" =~ ^[a-z][a-z0-9]{1,9}$ ]] || die "env must be 2-10 lowercase letters/digits: '$EDH_ENV'"
  [[ "$EDH_DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || die "domain looks invalid: '$EDH_DOMAIN'"
  [[ "$EDH_MONITORING" == cloudwatch || "$EDH_MONITORING" == none ]] || die "monitoring must be cloudwatch or none"
  [[ "$EDH_BACKUP_SCHEDULE" =~ ^(auto|hourly|daily)$ ]] || die "backup_schedule must be auto, hourly or daily"
  [[ "$EDH_USES_GOTENBERG" == true || "$EDH_USES_GOTENBERG" == false ]] || die "uses_gotenberg must be true or false"
  [[ "$EDH_DATA_GB" =~ ^[0-9]+$ ]] && (( EDH_DATA_GB >= 8 )) || die "data_volume_gb must be a number >= 8"
  [[ "$EDH_APP_MEMORY_MB" =~ ^[0-9]+$ ]] || die "app_memory_mb must be a number"
  [[ "$EDH_APP_PORT" =~ ^[0-9]+$ ]] || die "app_port must be a number"
  [[ "$EDH_DAILY_HOUR_UTC" =~ ^[0-9]+$ ]] && (( EDH_DAILY_HOUR_UTC < 24 )) || die "daily_backup_hour_utc must be 0-23"
  [[ "$EDH_MIGRATE_CMD" != *"'"* ]] || die "migrate_cmd must not contain single quotes"
  if [[ "$EDH_MONITORING" == cloudwatch && -z "$EDH_ALERT_EMAILS" ]]; then
    die "alert_emails required when monitoring: cloudwatch"
  fi
}
```

**Step 4: Run.** Expected: all pass.

**Step 5: Commit** `feat(ec2-dedicated-host): config loading and validation`

---

### Task 3: Server sizing

**Files:**
- Create: `skills/ec2-dedicated-host/scripts/sizing.sh`
- Create: `tests/ec2-dedicated-host/test_sizing.sh`
- Modify: `docs/plans/2026-10-30-ec2-dedicated-host-design.md`. Replace the "Sizing" section numbers with the ones below.

**Sizing rule:**
- Base is 768 MB (Ubuntu ~300, Caddy ~60, Postgres ~200, plus slack).
- Add the app's memory.
- Add 900 MB if Gotenberg is used (observed peak 897 MB).
- Pick the smallest t4g where the need is ≤ 60% of RAM.

**Step 1: Failing test**

```bash
# tests/ec2-dedicated-host/test_sizing.sh
. "$(dirname "$0")/assert.sh"
rec() { bash -c ". '$SKILL_DIR/scripts/lib.sh'; . '$SKILL_DIR/scripts/sizing.sh'; recommend_instance $1 $2" 2>&1; }
assert_eq "$(rec 400 false)"  "t4g.small"  "small app fits t4g.small (1168 MB)"
assert_eq "$(rec 700 true)"   "t4g.medium" "app + gotenberg fits t4g.medium (2368 MB)"
assert_eq "$(rec 1500 true)"  "t4g.large"  "bigger app needs t4g.large (3168 MB)"
assert_eq "$(rec 6000 true)"  "t4g.xlarge" "very large app needs t4g.xlarge (7668 MB)"
assert_contains "$(rec 9000 true)" "choose instance_type manually" "too large is refused"
finish
```

**Step 2: Run.** Expected: FAIL.

**Step 3: Implement**

```bash
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
```

**Step 4: Run.** Expected: pass.

**Step 5: Update the design doc sizing section.**
- Base 768 MB, Gotenberg 900 MB.
- Thresholds: t4g.small ≤ 1228 MB, t4g.medium ≤ 2457 MB, t4g.large ≤ 4915 MB, t4g.xlarge ≤ 9830 MB.

**Step 6: Commit** `feat(ec2-dedicated-host): instance sizing`

---

### Task 4: AWS helpers, protect guard and SSM runner (with stub `aws`)

**Files:**
- Modify: `skills/ec2-dedicated-host/scripts/lib.sh`
- Create: `tests/ec2-dedicated-host/stubs/aws` (executable)
- Create: `tests/ec2-dedicated-host/test_guards.sh`

**Step 1: The stub `aws`.** It logs every call to `$STUB_LOG` and emulates only the calls that tests need. It is used by Tasks 4, 9 and 12–14.

```bash
#!/usr/bin/env bash
# Fake `aws` CLI for tests. Logs every call; emulates a few calls; STUB_MODE=empty|existing.
echo "aws $*" >> "${STUB_LOG:?STUB_LOG not set}"
args=("$@")
# drop global options so $1 $2 are service + verb
clean=(); i=0
while (( i < ${#args[@]} )); do
  case "${args[$i]}" in --region|--profile|--output|--query) i=$((i + 2));; *) clean+=("${args[$i]}"); i=$((i + 1));; esac
done
svc="${clean[0]:-}"; verb="${clean[1]:-}"
s3path() { if [[ "$1" == s3://* ]]; then echo "${STUB_S3:?}/${1#s3://}"; else echo "$1"; fi; }

case "$svc $verb" in
  "sts get-caller-identity") echo 123456789012 ;;
  "s3 cp")
    pos=(); for a in "${clean[@]:2}"; do [[ "$a" == --* ]] || pos+=("$a"); done
    src=$(s3path "${pos[0]}"); dst=$(s3path "${pos[1]}")
    if [[ "$src" == - ]]; then mkdir -p "$(dirname "$dst")"; cat > "$dst"
    elif [[ "$dst" == - ]]; then cat "$src"
    else mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; fi ;;
  "s3 ls")
    p="${clean[2]#s3://}"; b="${p%%/*}"
    [[ -d "$STUB_S3/$b" ]] && (cd "$STUB_S3/$b" && find . -type f | sed 's#^\./##' | sort | while read -r k; do echo "2026-01-01 00:00:00 1 $k"; done) ;;
  "ssm get-parameters-by-path") cat "${STUB_SSM:-/dev/null}" ;;
  "ec2 describe-tags")
    if [[ "$*" == *"vol-protected"* ]]; then echo true; else echo None; fi ;;
  "ecr get-login-password") echo stub ;;
  *)
    if [[ "${STUB_MODE:-empty}" == empty ]]; then
      case "$verb" in get-role|head-bucket|describe-repositories|get-parameter|get-instance-profile) exit 254 ;; esac
      case "$verb" in describe-vpcs) echo vpc-stub ;; describe-instance-type-offerings) echo ap-southeast-1a ;; *) echo None ;; esac
    else
      case "$verb" in
        describe-vpcs) echo vpc-stub ;;
        describe-instances) echo i-stub ;;
        describe-volumes) printf 'vol-stub\tap-southeast-1a\n' ;;
        describe-addresses) printf 'eipalloc-stub\t203.0.113.10\n' ;;
        describe-security-groups) echo sg-stub ;;
        get-lifecycle-policies) echo policy-stub ;;
        describe-instance-type-offerings) echo ap-southeast-1a ;;
        *) echo stub ;;
      esac
    fi ;;
esac
exit 0
```

`chmod +x tests/ec2-dedicated-host/stubs/aws`

**Step 2: Failing tests**

```bash
# tests/ec2-dedicated-host/test_guards.sh
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PATH="$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/log"
run() { bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$SKILL_DIR/assets/project/deploy.yml'; $1" 2>&1; }

assert_contains "$(run 'guard_not_protected vol-protected')" "Protect=true" "refuses protected resource"
assert_eq "$(run 'guard_not_protected vol-other; echo passed')" "passed" "allows unprotected resource"
assert_eq "$(run 'aws_account')" "123456789012" "aws_account via sts"
assert_contains "$(run 'tag_spec volume edh-acme-prod-data Protect=true')" "{Key=Protect,Value=true}" "tag_spec adds extra tags"
assert_contains "$(run 'tag_spec volume x')" "{Key=Client,Value=acme}" "tag_spec adds cost tag"
assert_eq "$(run 'EDH_YES=1 confirm "go?"; echo yes')" "yes" "confirm honours EDH_YES=1"
assert_contains "$(run 'confirm "go?" </dev/null')" "aborted" "confirm without consent aborts"
assert_eq "$(run 'x=$(gen_secret 40); echo ${#x}')" "40" "gen_secret length"
finish
```

**Step 3: Run.** Expected: FAIL.

**Step 4: Implement in `lib.sh`**

```bash
awsr()    { aws --region "$EDH_REGION" "$@"; }        # app region
aws_use1() { aws --region us-east-1 "$@"; }           # Route 53 health-check metrics live in us-east-1

aws_account() {
  if [[ -z "${EDH_ACCOUNT:-}" ]]; then EDH_ACCOUNT=$(aws sts get-caller-identity --query Account --output text); fi
  printf '%s' "$EDH_ACCOUNT"
}

# tag_spec <resource-type> <name> [Key=Value ...] — value for --tag-specifications
tag_spec() {
  local rtype="$1" name="$2" extra="" kv; shift 2
  for kv in "$@"; do extra="${extra},{Key=${kv%%=*},Value=${kv#*=}}"; done
  printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s},{Key=edh:client,Value=%s},{Key=edh:env,Value=%s},{Key=Client,Value=%s},{Key=ManagedBy,Value=ec2-dedicated-host}%s]' \
    "$rtype" "$name" "$EDH_CLIENT" "$EDH_ENV" "$EDH_CLIENT" "$extra"
}

# guard_not_protected <ec2-resource-id> — never touch anything tagged Protect=true.
guard_not_protected() {
  local v
  v=$(awsr ec2 describe-tags --filters "Name=resource-id,Values=$1" "Name=key,Values=Protect" --query 'Tags[0].Value' --output text)
  [[ "$v" != true ]] || die "refusing: $1 is tagged Protect=true (it holds data). Remove the tag by hand only if you really mean it."
}

# confirm <question> — EDH_YES=1 skips the prompt (the agent sets it only after the user agreed in chat).
confirm() {
  local a=""
  if [[ "${EDH_YES:-}" == 1 ]]; then return 0; fi
  read -r -p "$1 [y/N] " a || true
  [[ "$a" =~ ^[Yy]$ ]] || die "aborted"
}

gen_secret() { openssl rand -hex 32 | cut -c1-"${1:-40}"; }

instance_id() {
  awsr ec2 describe-instances \
    --filters "Name=tag:edh:client,Values=$EDH_CLIENT" "Name=tag:edh:env,Values=$EDH_ENV" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

require_instance() {
  EDH_IID=$(instance_id)
  [[ -n "$EDH_IID" && "$EDH_IID" != None ]] || die "no server for $EDH_NAME yet — run provision.sh first"
  [[ "$EDH_IID" != *[[:space:]]* ]] || die "more than one server tagged $EDH_NAME: $EDH_IID"
}

# ssm_run <instance-id> <timeout-seconds> <script> — run a bash script on the server as root.
# The script travels base64-encoded, so no quoting issues. Prints its output; returns its exit code.
ssm_run() {
  local iid="$1" timeout="$2" b64 cid status code err
  b64=$(printf '%s' "$3" | base64 | tr -d '\n')
  cid=$(awsr ssm send-command --instance-ids "$iid" --document-name AWS-RunShellScript \
    --parameters "{\"commands\":[\"f=\$(mktemp); echo $b64 | base64 -d > \$f; bash \$f; rc=\$?; rm -f \$f; exit \$rc\"],\"executionTimeout\":[\"$timeout\"]}" \
    --timeout-seconds 60 --query Command.CommandId --output text)
  while :; do
    sleep 3
    status=$(awsr ssm get-command-invocation --command-id "$cid" --instance-id "$iid" --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in Pending|InProgress|Delayed) ;; *) break ;; esac
  done
  awsr ssm get-command-invocation --command-id "$cid" --instance-id "$iid" --query StandardOutputContent --output text
  err=$(awsr ssm get-command-invocation --command-id "$cid" --instance-id "$iid" --query StandardErrorContent --output text)
  if [[ -n "$err" && "$err" != None ]]; then printf '%s\n' "$err" >&2; fi
  code=$(awsr ssm get-command-invocation --command-id "$cid" --instance-id "$iid" --query ResponseCode --output text)
  [[ "$code" =~ ^-?[0-9]+$ ]] || code=1
  return "$code"
}

# wait_ssm <instance-id> — until the SSM agent reports Online (max 10 min)
wait_ssm() {
  local i
  for i in $(seq 1 60); do
    if [[ $(awsr ssm describe-instance-information --filters "Key=InstanceIds,Values=$1" \
           --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null) == Online ]]; then return 0; fi
    sleep 10
  done
  die "SSM agent on $1 did not come online within 10 minutes"
}
```

**Step 5: Run.** Expected: pass.

**Step 6: Commit** `feat(ec2-dedicated-host): aws helpers, protect guard, ssm runner`

---

### Task 5: Project templates (compose, Caddyfile, maintenance pages)

**Files:**
- Create: `skills/ec2-dedicated-host/assets/project/compose.yml`
- Create: `skills/ec2-dedicated-host/assets/project/Caddyfile`
- Create: `skills/ec2-dedicated-host/assets/project/maint/maintenance.html`
- Create: `skills/ec2-dedicated-host/assets/project/maint/down.html`
- Create: `tests/ec2-dedicated-host/fixtures/app/Dockerfile`
- Create: `tests/ec2-dedicated-host/test_int_caddy.sh`

**Step 1: Fixture app.** It answers `/` with `fixture-ok`, and `/health` only when built with `HEALTHY=1`.

```dockerfile
# tests/ec2-dedicated-host/fixtures/app/Dockerfile
FROM busybox:1.36
ARG HEALTHY=1
RUN mkdir -p /www && echo fixture-ok > /www/index.html && if [ "$HEALTHY" = 1 ]; then echo ok > /www/health; fi
EXPOSE 3000
CMD ["httpd", "-f", "-p", "3000", "-h", "/www"]
```

**Step 2: Failing integration test**

```bash
# tests/ec2-dedicated-host/test_int_caddy.sh — Caddy maintenance/down/bypass behaviour, against real containers.
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); P=edhcaddytest
cleanup() { docker compose -p $P -f "$T/c.yml" down -v >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
docker build -q -t edh-fixture:good --build-arg HEALTHY=1 "$TESTS_DIR/fixtures/app" >/dev/null
mkdir -p "$T/caddy" "$T/maint"
cp "$SKILL_DIR/assets/project/Caddyfile" "$T/caddy/Caddyfile"
cp "$SKILL_DIR/assets/project/maint/"*.html "$T/maint/"
cat > "$T/c.yml" <<EOF
services:
  caddy:
    image: caddy:2.10-alpine
    environment: { DOMAIN: ":80", MAINT_BYPASS: "tok123", APP_PORT: "3000" }
    ports: ["18080:80"]
    volumes: ["$T/caddy:/etc/caddy:ro", "$T/maint:/srv/maint:ro"]
  app:
    image: edh-fixture:good
EOF
docker compose -p $P -f "$T/c.yml" up -d >/dev/null 2>&1
for i in $(seq 1 30); do curl -fs localhost:18080/ >/dev/null 2>&1 && break; sleep 1; done
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

assert_eq "$(curl -s localhost:18080/)" "fixture-ok" "proxies to app normally"
touch "$T/maint/ON"
assert_eq "$(code localhost:18080/)" "503" "maintenance returns 503"
assert_contains "$(curl -s localhost:18080/)" 'id="edh-maintenance"' "maintenance page served"
assert_contains "$(curl -sI localhost:18080/)" "Retry-After: 1800" "Retry-After header set"
assert_eq "$(code localhost:18080/health)" "200" "/health bypasses maintenance"
assert_eq "$(curl -s -H 'Cookie: maint_bypass=tok123' localhost:18080/)" "fixture-ok" "bypass cookie reaches app"
assert_eq "$(code -H 'Cookie: maint_bypass=wrong' localhost:18080/)" "503" "wrong cookie still blocked"
assert_contains "$(curl -sI 'localhost:18080/?maint_bypass=tok123')" "maint_bypass=tok123" "bypass link sets cookie"
rm "$T/maint/ON"
docker compose -p $P -f "$T/c.yml" stop app >/dev/null 2>&1
assert_eq "$(code localhost:18080/)" "503" "app down returns 503"
assert_contains "$(curl -s localhost:18080/)" 'id="edh-down"' "down page served when app is down"
finish
```

**Step 3: Run.** Expected: FAIL (no Caddyfile).

**Step 4: Write the Caddyfile**

```caddy
# ec2-dedicated-host — one site, one app. Env (from compose): DOMAIN, MAINT_BYPASS, APP_PORT.
#  - Planned maintenance: active while /srv/maint/ON exists (no reload needed).
#  - Bypass: open https://<domain>/?maint_bypass=<token> once; a 24 h cookie lets you through.
#  - Unplanned: if the app can't be reached, /srv/maint/down.html is served (auto-refreshes).
{$DOMAIN} {
	encode zstd gzip

	@set_bypass query maint_bypass={$MAINT_BYPASS}
	@maint {
		file {
			root /srv/maint
			try_files /ON
		}
		not header Cookie *maint_bypass={$MAINT_BYPASS}*
		not path /health
	}

	route {
		handle @set_bypass {
			header Set-Cookie "maint_bypass={$MAINT_BYPASS}; Path=/; Max-Age=86400; HttpOnly; Secure; SameSite=Lax"
			redir * / 302
		}
		handle @maint {
			root * /srv/maint
			rewrite * /maintenance.html
			header Retry-After 1800
			header Cache-Control no-store
			file_server {
				status 503
			}
		}
		handle {
			reverse_proxy app:{$APP_PORT}
		}
	}

	handle_errors 502 503 504 {
		root * /srv/maint
		rewrite * /down.html
		header Cache-Control no-store
		file_server {
			status 503
		}
	}
}
```

**Step 5: Maintenance pages.** They're self-contained, with no external assets, and work in light and dark mode. The `{{MESSAGE}}` and `{{UNTIL}}` placeholders are filled by `edh-maint.sh`.

`maint/maintenance.html`:
```html
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Scheduled maintenance</title>
<style>
:root{--bg:#f7f7f5;--fg:#1d1d1b;--muted:#6b6b66;--card:#fff;--line:#e4e4df}
@media (prefers-color-scheme:dark){:root{--bg:#141413;--fg:#ececea;--muted:#a3a39d;--card:#1e1e1c;--line:#2e2e2b}}
body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:30rem;margin:1rem;padding:2rem;background:var(--card);border:1px solid var(--line);border-radius:12px}
h1{font-size:1.4rem;margin:0 0 .75rem}p{margin:.5rem 0}.muted{color:var(--muted)}
</style></head>
<body><main id="edh-maintenance">
<h1>Scheduled maintenance</h1>
<p>{{MESSAGE}}</p>
<p class="muted">Expected back: {{UNTIL}}. Thank you for your patience.</p>
</main></body></html>
```

`maint/down.html`: the same shell, with `<meta http-equiv="refresh" content="30">` in `<head>`, `<main id="edh-down">`, the heading "We'll be right back", and the text "The service is restarting or temporarily unavailable. This page refreshes automatically."

**Step 6: Compose template**

```yaml
# ec2-dedicated-host stack — one client per server. Values come from .env (written by edh-deploy.sh).
name: ${EDH_NAME:?}

x-logging: &logging
  driver: json-file
  options: { max-size: "10m", max-file: "3" }

services:
  caddy:
    image: caddy:2.10-alpine
    restart: unless-stopped
    ports:
      - "${EDH_HTTP_PORT:-80}:80"
      - "${EDH_HTTPS_PORT:-443}:443"
      - "${EDH_HTTPS_PORT:-443}:443/udp"
    environment:
      DOMAIN: ${DOMAIN:?}
      MAINT_BYPASS: ${MAINT_BYPASS:?}
      APP_PORT: ${APP_PORT:-3000}
    volumes:
      - ./caddy:/etc/caddy:ro                       # directory mount, so file replacement is seen
      - ${EDH_DATA_DIR:-/data}/caddy:/data          # certificates survive rebuilds
      - ${EDH_DATA_DIR:-/data}/maint:/srv/maint:ro
    mem_limit: 256m
    logging: *logging

  app:
    image: ${APP_IMAGE:?}
    restart: unless-stopped
    env_file: [./app.env]
    environment:
      PORT: ${APP_PORT:-3000}
    depends_on:
      postgres: { condition: service_healthy }
    mem_limit: ${APP_MEMORY_MB:-768}m
    logging: *logging

  postgres:
    image: postgres:18-alpine
    restart: unless-stopped
    env_file: [./postgres.env]
    volumes:
      - ${EDH_DATA_DIR:-/data}/postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app -d app"]
      interval: 10s
      timeout: 5s
      retries: 5
    shm_size: 128m
    mem_limit: 512m
    logging: *logging

  gotenberg:
    image: gotenberg/gotenberg:8
    profiles: [gotenberg]
    restart: unless-stopped
    mem_limit: 1g
    logging: *logging
```

**Step 7: Run** `bash tests/ec2-dedicated-host/test_int_caddy.sh`. Expected: all pass.

If `file_server { status 503 }` inside `handle_errors` is rejected by Caddy 2.10, use `error 503` plus a `handle_errors` without codes, then re-run. Fix the Caddyfile until the test passes. Don't weaken the test.

**Step 8: Commit** `feat(ec2-dedicated-host): project templates with maintenance and down pages`

---

### Task 6: Host library and maintenance script

**Files:**
- Create: `skills/ec2-dedicated-host/assets/host/edh-lib.sh`
- Create: `skills/ec2-dedicated-host/assets/host/edh-maint.sh`
- Create: `tests/ec2-dedicated-host/test_maint_render.sh`

**Step 1: Failing test**

```bash
# tests/ec2-dedicated-host/test_maint_render.sh
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/app/maint-templates" "$T/data/maint"
cp "$SKILL_DIR/assets/project/maint/"*.html "$T/app/maint-templates/"
: > "$T/edh.env"
export EDH_ENV_FILE="$T/edh.env" EDH_APP_DIR="$T/app" EDH_DATA_DIR="$T/data" EDH_BIN_DIR="$SKILL_DIR/assets/host"
M="$SKILL_DIR/assets/host/edh-maint.sh"

bash "$M" on --message 'Upgrade <b>& "fix"' --until '22:00 SGT' >/dev/null
page=$(cat "$T/data/maint/maintenance.html")
assert_contains "$page" 'Upgrade &lt;b&gt;&amp; &quot;fix&quot;' "message is HTML-escaped"
assert_contains "$page" '22:00 SGT' "until is filled"
assert_eq "$(bash "$M" status)" "on" "status on"
bash "$M" off >/dev/null
assert_eq "$(bash "$M" status)" "off" "status off"
bash "$M" render >/dev/null
assert_contains "$(cat "$T/data/maint/maintenance.html")" "scheduled maintenance" "render writes default page"
finish
```

**Step 2: Run.** Expected: FAIL.

**Step 3: `edh-lib.sh`**

```bash
#!/usr/bin/env bash
# Shared helpers for ec2-dedicated-host scripts that run ON the server. Source, don't run.
set -Eeuo pipefail
export PATH="/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
EDH_ENV_FILE="${EDH_ENV_FILE:-/etc/edh/edh.env}"
# shellcheck disable=SC1090
if [[ -f "$EDH_ENV_FILE" ]]; then . "$EDH_ENV_FILE"; fi
EDH_APP_DIR="${EDH_APP_DIR:-/opt/edh/app}"
EDH_DATA_DIR="${EDH_DATA_DIR:-/data}"
EDH_BIN_DIR="${EDH_BIN_DIR:-/opt/edh/bin}"

log() { printf '[edh %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

dc() { docker compose --project-directory "$EDH_APP_DIR" -f "$EDH_APP_DIR/compose.yml" "$@"; }
# pg <sql> [database] — run SQL as the app superuser inside the postgres container
pg() { dc exec -T postgres psql -v ON_ERROR_STOP=1 -U app -d "${2:-app}" -tAc "$1"; }

# alert <subject> <message> — email through SNS when monitoring is on; always logged
alert() {
  log "ALERT: $1 — $2"
  if [[ -z "${EDH_ALERT_TOPIC_ARN:-}" ]]; then return 0; fi
  aws sns publish --region "$EDH_REGION" --topic-arn "$EDH_ALERT_TOPIC_ARN" \
    --subject "[${EDH_NAME:-edh}] $1" --message "$2" >/dev/null || log "sns publish failed"
}

# metric <name> [value] — custom metric in namespace EDH (watched by the backup alarm)
metric() {
  aws cloudwatch put-metric-data --region "$EDH_REGION" --namespace EDH --metric-name "$1" \
    --dimensions "Client=$EDH_CLIENT,Env=$EDH_ENV" --value "${2:-1}" || log "metric $1 not published"
}

# wait_health [tries] — app /health through the compose network (2 s apart)
wait_health() {
  local i
  for i in $(seq 1 "${1:-30}"); do
    if dc exec -T caddy wget -q -O /dev/null "http://app:${EDH_APP_PORT:-3000}/health" 2>/dev/null; then return 0; fi
    sleep 2
  done
  return 1
}

html_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
```

**Step 4: `edh-maint.sh`**

```bash
#!/usr/bin/env bash
# edh-maint.sh on [--message TEXT] [--until TEXT] | off | status | render
# Planned maintenance: Caddy serves /data/maint/maintenance.html while /data/maint/ON exists.
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh"

TPL="$EDH_APP_DIR/maint-templates/maintenance.html"
OUT="$EDH_DATA_DIR/maint/maintenance.html"
FLAG="$EDH_DATA_DIR/maint/ON"

# render <message> <until> — fill the template; literal replacement, HTML-escaped
render() {
  local tmp; tmp=$(mktemp)
  EDH_M="$(html_escape "$1")" EDH_U="$(html_escape "$2")" awk '
    function repl(s, from, to,   i, out) { out = ""; while ((i = index(s, from)) > 0) { out = out substr(s, 1, i - 1) to; s = substr(s, i + length(from)) } return out s }
    { $0 = repl($0, "{{MESSAGE}}", ENVIRON["EDH_M"]); $0 = repl($0, "{{UNTIL}}", ENVIRON["EDH_U"]); print }' "$TPL" > "$tmp"
  install -m 644 "$tmp" "$OUT"
  rm -f "$tmp"
}

msg="We're carrying out scheduled maintenance to improve the service."; until="shortly"
cmd="${1:-}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --message) msg="$2"; shift 2 ;;
    --until) until="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
case "$cmd" in
  on)     render "$msg" "$until"; touch "$FLAG"; echo "maintenance ON" ;;
  off)    rm -f "$FLAG"; echo "maintenance OFF" ;;
  status) if [[ -f "$FLAG" ]]; then echo on; else echo off; fi ;;
  render) render "$msg" "$until" ;;
  *)      die "usage: edh-maint.sh on [--message T] [--until T] | off | status | render" ;;
esac
```

**Step 5: Run** the test and `run.sh --fast` (shellcheck). Expected: pass.

**Step 6: Commit** `feat(ec2-dedicated-host): host lib and maintenance toggle`

---

### Task 7: Host backup, restore and drill scripts

**Files:**
- Create: `skills/ec2-dedicated-host/assets/host/edh-backup.sh`
- Create: `skills/ec2-dedicated-host/assets/host/edh-restore.sh`
- Create: `skills/ec2-dedicated-host/assets/host/edh-drill.sh`
- Test: covered by `test_int_host.sh` in Task 8. Write the scripts here; Task 8 exercises them.

**`edh-backup.sh`**

```bash
#!/usr/bin/env bash
# edh-backup.sh [--tag auto|safety|manual] [--force]
# pg_dump (custom format) of the app database to /data/backups, then upload to S3. Hourly via systemd.
#   auto   : hourly (DB < 2 GB) → db/hourly/ ; at daily_backup_hour_utc also db/daily/ ; on the 1st also db/monthly/
#   safety : before deploys/restores → db/safety/ (kept 30 days)
#   manual : on demand → db/daily/
# The server can upload but never delete backups; S3 lifecycle rules do the expiring.
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh"

TAG=auto; FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in --tag) TAG="$2"; shift 2 ;; --force) FORCE=1; shift ;; *) die "unknown option: $1" ;; esac
done
trap 'alert "backup failed" "edh-backup.sh ($TAG) failed on $(hostname) at $(date -u +%FT%TZ). See: journalctl -u edh-backup"' ERR

size=$(pg "select pg_database_size('app')")
schedule="${EDH_BACKUP_SCHEDULE:-auto}"
if [[ "$schedule" == auto ]]; then
  if (( size < 2147483648 )); then schedule=hourly; else schedule=daily; fi
fi
hour=$(date -u +%H); day=$(date -u +%d)
daily_slot=0
if [[ "$hour" == "$(printf '%02d' "${EDH_DAILY_HOUR_UTC:-18}")" ]]; then daily_slot=1; fi
if [[ "$TAG" == auto && "$schedule" == daily && $daily_slot == 0 && $FORCE == 0 ]]; then
  log "daily schedule (database is $((size / 1048576)) MB): nothing to do this hour"; exit 0
fi

name="app-$(date -u +%Y%m%dT%H%M%SZ).dump"
file="$EDH_DATA_DIR/backups/$name"
mkdir -p "$EDH_DATA_DIR/backups"
dc exec -T postgres pg_dump -U app -d app -Fc > "$file.part"
mv "$file.part" "$file"
[[ -s "$file" ]] || die "pg_dump produced an empty file"

upload() { aws s3 cp "$file" "s3://$EDH_BACKUP_BUCKET/db/$1/$name" --region "$EDH_REGION" --only-show-errors; log "uploaded db/$1/$name"; }
case "$TAG" in
  auto)
    if [[ "$schedule" == hourly ]]; then upload hourly; fi
    if (( daily_slot )); then upload daily; if [[ "$day" == 01 ]]; then upload monthly; fi; fi ;;
  safety) upload safety ;;
  manual) upload daily ;;
  *) die "unknown tag: $TAG" ;;
esac
metric BackupFresh 1   # superseded: see the committed edh-backup.sh (heartbeat based on last upload)
find "$EDH_DATA_DIR/backups" -name 'app-*.dump' -mmin +4320 -delete   # keep 3 days locally
echo "$name"
```

**`edh-restore.sh`**

```bash
#!/usr/bin/env bash
# edh-restore.sh check <s3-key> [--keep]   restore into side database app_restore_check, count tables
# edh-restore.sh replace <s3-key> --yes    replace the live database: maintenance on → safety dump → restore → health → off
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh"

fetch() { # fetch <s3-key> → local path
  local f; f="$EDH_DATA_DIR/backups/restore-$(basename "$1")"
  if [[ ! -s "$f" ]]; then aws s3 cp "s3://$EDH_BACKUP_BUCKET/$1" "$f" --region "$EDH_REGION" --only-show-errors; fi
  printf '%s' "$f"
}
restore_into() { # restore_into <database> <dump-file>
  pg "drop database if exists \"$1\" with (force)" postgres >/dev/null
  pg "create database \"$1\" owner app" postgres >/dev/null
  dc exec -T postgres pg_restore -U app -d "$1" --no-owner --exit-on-error < "$2"
}
table_count() { pg "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')" "$1"; }

cmd="${1:-}"; key="${2:-}"; opt="${3:-}"
[[ -n "$key" ]] || die "usage: edh-restore.sh check|replace <s3-key> [--keep|--yes]"
case "$cmd" in
  check)
    f=$(fetch "$key")
    restore_into app_restore_check "$f"
    n=$(table_count app_restore_check)
    log "restored $key into app_restore_check: $n tables"
    (( n > 0 )) || die "restore produced no tables"
    if [[ "$opt" != --keep ]]; then pg 'drop database app_restore_check with (force)' postgres >/dev/null; fi
    rm -f "$f"
    echo "$n" ;;
  replace)
    [[ "$opt" == --yes ]] || die "replace needs --yes"
    f=$(fetch "$key")
    "$EDH_BIN_DIR/edh-maint.sh" on --message "We're restoring data from a backup." --until "in a few minutes" >/dev/null
    "$EDH_BIN_DIR/edh-backup.sh" --tag safety --force >/dev/null
    dc stop app
    restore_into app "$f"
    dc start app
    if ! wait_health 30; then
      alert "restore: app unhealthy" "Restored $key but the app fails /health. Maintenance page left ON."
      die "app unhealthy after restore — maintenance left ON"
    fi
    "$EDH_BIN_DIR/edh-maint.sh" off >/dev/null
    rm -f "$f"
    log "restore of $key complete" ;;
  *) die "unknown command: $cmd" ;;
esac
```

**`edh-drill.sh`**

```bash
#!/usr/bin/env bash
# edh-drill.sh — monthly restore test: newest dump in S3 → side database → count tables → drop. Alerts on failure.
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh"
trap 'alert "restore drill FAILED" "The monthly restore test failed on $(hostname). Backups may not be restorable — investigate now."' ERR
key=$(aws s3 ls "s3://$EDH_BACKUP_BUCKET/db/" --recursive --region "$EDH_REGION" \
  | awk '{print $4}' | grep -E '^db/(hourly|daily)/app-.*\.dump$' \
  | awk -F/ '{print $NF " " $0}' | sort | tail -1 | cut -d' ' -f2)
[[ -n "$key" ]] || die "no backups found in s3://$EDH_BACKUP_BUCKET/db/"
n=$("$EDH_BIN_DIR/edh-restore.sh" check "$key")
metric RestoreDrillSuccess 1
log "restore drill ok: $key ($n tables)"
```

**Commit** `feat(ec2-dedicated-host): host backup, restore and drill scripts`. Commit after Task 8's tests pass, if you prefer to keep one commit per green state.

---

### Task 8: Host deploy and rollback, plus host integration test

**Files:**
- Create: `skills/ec2-dedicated-host/assets/host/edh-deploy.sh`
- Create: `skills/ec2-dedicated-host/assets/host/edh-rollback.sh`
- Create: `skills/ec2-dedicated-host/assets/host/edh-status.sh`
- Create: `tests/ec2-dedicated-host/test_int_host.sh`

**Step 1: Failing integration test.** It runs the real host scripts on the Mac against Docker, with the `aws` stub.

```bash
# tests/ec2-dedicated-host/test_int_host.sh — deploy, rollback, failed migration, backup, restore, maintenance.
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d)
export PATH="$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/aws.log" STUB_S3="$T/s3" STUB_SSM="$T/ssm.tsv"
export EDH_ENV_FILE="$T/etc/edh.env" EDH_APP_DIR="$T/app" EDH_DATA_DIR="$T/data" EDH_BIN_DIR="$T/bin"
export EDH_NO_SYSTEMD=1 EDH_SKIP_PULL=1 EDH_HTTP_PORT=18081 EDH_HTTPS_PORT=18443
cleanup() { docker compose --project-directory "$T/app" -f "$T/app/compose.yml" down -v >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT

docker build -q -t edh-fixture:good --build-arg HEALTHY=1 "$TESTS_DIR/fixtures/app" >/dev/null
docker build -q -t edh-fixture:bad  --build-arg HEALTHY=0 "$TESTS_DIR/fixtures/app" >/dev/null
printf '/t/prod/_edh/postgres-password\tpw123abc\n/t/prod/_edh/maint-bypass\ttok123\n/t/prod/api-key\tsecret-value\n' > "$STUB_SSM"

make_release() { # make_release <dir> <migrate_cmd>
  local r="$1"; mkdir -p "$r/app/maint" "$r/host/systemd"
  cp "$SKILL_DIR/assets/project/compose.yml" "$SKILL_DIR/assets/project/Caddyfile" "$r/app/"
  cp "$SKILL_DIR/assets/project/maint/"*.html "$r/app/maint/"
  cp "$SKILL_DIR/assets/host/"edh-*.sh "$r/host/"
  cat > "$r/release.env" <<EOF
EDH_CLIENT=t
EDH_ENV=prod
EDH_NAME=edhhosttest
EDH_REGION=ap-southeast-1
EDH_DOMAIN=:80
EDH_SSM_PATH=/t/prod
EDH_BACKUP_BUCKET=bkt
EDH_BACKUP_SCHEDULE=auto
EDH_DAILY_HOUR_UTC=18
EDH_APP_PORT=3000
EDH_APP_MEMORY_MB=256
EDH_USES_GOTENBERG=false
EDH_MIGRATE_CMD='$2'
EDH_ALERT_TOPIC_ARN=arn:aws:sns:ap-southeast-1:123456789012:edh-t-prod-alerts
EOF
}
deploy() { bash "$1/host/edh-deploy.sh" "$1" "$2" >"$T/out" 2>&1; echo $?; }
img() { sed -n 's/^APP_IMAGE=//p' "$T/app/.env"; }

make_release "$T/r1" "echo migrated"
assert_status "$(deploy "$T/r1" edh-fixture:good)" 0 "first deploy succeeds"
assert_eq "$(curl -s localhost:18081/)" "fixture-ok" "site serves the app"
assert_contains "$(cat "$T/app/app.env")" "API_KEY=secret-value" "app secrets mapped from SSM names"
assert_contains "$(cat "$T/app/app.env")" "DATABASE_URL=postgres://app:pw123abc@postgres:5432/app" "DATABASE_URL injected"
assert_eq "$(stat -f %Lp "$T/app/app.env")" "600" "app.env is 0600"

bash "$EDH_BIN_DIR/edh-lib.sh" 2>/dev/null; . "$EDH_BIN_DIR/edh-lib.sh"; set +e
pg "create table widgets(id int); insert into widgets values (1)" >/dev/null

assert_status "$(deploy "$T/r1" edh-fixture:bad)" 2 "unhealthy image exits 2"
assert_eq "$(img)" "edh-fixture:good" "rolled back to good image"
assert_eq "$(curl -s localhost:18081/)" "fixture-ok" "site still serves after rollback"
assert_contains "$(cat "$STUB_LOG")" "sns publish" "rollback alert sent"
assert_contains "$(ls "$STUB_S3/bkt/db/safety")" "app-" "pre-deploy safety dump uploaded"

make_release "$T/r2" "exit 3"
assert_status "$(deploy "$T/r2" edh-fixture:bad)" 1 "failed migration exits 1"
assert_eq "$(img)" "edh-fixture:good" "failed migration keeps old image"

name=$(bash "$EDH_BIN_DIR/edh-backup.sh" --tag manual --force 2>/dev/null)
assert_contains "$(ls "$STUB_S3/bkt/db/daily")" "$name" "manual backup uploaded to db/daily"
assert_contains "$(cat "$STUB_LOG")" "put-metric-data" "backup metric published"
assert_eq "$(bash "$EDH_BIN_DIR/edh-restore.sh" check "db/daily/$name" 2>/dev/null)" "1" "restore check finds 1 table"
assert_eq "$(bash "$EDH_BIN_DIR/edh-drill.sh" >/dev/null 2>&1; echo $?)" "0" "restore drill passes"

bash "$EDH_BIN_DIR/edh-maint.sh" on --message "Testing" >/dev/null
assert_eq "$(curl -s -o /dev/null -w '%{http_code}' localhost:18081/)" "503" "maintenance on via host script"
bash "$EDH_BIN_DIR/edh-maint.sh" off >/dev/null

assert_contains "$(bash "$EDH_BIN_DIR/edh-status.sh" 2>&1)" "maintenance: off" "status reports"
finish
```

**Step 2: Run.** Expected: FAIL (no `edh-deploy.sh`).

**Step 3: `edh-deploy.sh`**

```bash
#!/usr/bin/env bash
# edh-deploy.sh <release-dir> <image> [--maint]
# Runs ON the server as root (sent by deploy.sh via SSM). Installs the release's host scripts and config,
# then swaps the app image: safety dump → migrations → up → /health → automatic rollback on failure.
# Exit: 0 deployed · 1 failed before the swap (old version still serving) · 2 unhealthy, rolled back · 3 site down
set -Eeuo pipefail
REL="${1:?release dir}"; IMAGE="${2:?image}"; MAINT="${3:-}"
EDH_BIN_DIR="${EDH_BIN_DIR:-/opt/edh/bin}"
EDH_ENV_FILE="${EDH_ENV_FILE:-/etc/edh/edh.env}"
install -d -m 755 "$EDH_BIN_DIR" "$(dirname "$EDH_ENV_FILE")"
install -m 755 "$REL"/host/edh-*.sh "$EDH_BIN_DIR"/
install -m 644 "$REL/release.env" "$EDH_ENV_FILE"
# shellcheck source=edh-lib.sh
. "$EDH_BIN_DIR/edh-lib.sh"

install_units() {
  if [[ "${EDH_NO_SYSTEMD:-}" == 1 ]]; then return 0; fi
  install -m 644 "$REL"/host/systemd/* /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now edh-backup.timer edh-drill.timer >/dev/null
}

install_app_files() {
  install -d -m 755 "$EDH_APP_DIR/caddy" "$EDH_APP_DIR/maint-templates" \
    "$EDH_DATA_DIR/caddy" "$EDH_DATA_DIR/maint" "$EDH_DATA_DIR/backups"
  install -d -m 700 "$EDH_DATA_DIR/postgres"
  install -m 644 "$REL/app/compose.yml" "$EDH_APP_DIR/compose.yml"
  install -m 644 "$REL/app/Caddyfile" "$EDH_APP_DIR/caddy/Caddyfile"
  install -m 644 "$REL"/app/maint/*.html "$EDH_APP_DIR/maint-templates/"
  install -m 644 "$REL/app/maint/down.html" "$EDH_DATA_DIR/maint/down.html"
  if [[ ! -f "$EDH_DATA_DIR/maint/ON" ]]; then "$EDH_BIN_DIR/edh-maint.sh" render; fi
}

# write_secrets — SSM <path>/<name> → app.env NAME (dashes → underscores, upper case); _edh/* is internal.
write_secrets() {
  local tmp name value key k pg_pw="" bypass=""
  tmp=$(mktemp)
  aws ssm get-parameters-by-path --region "$EDH_REGION" --path "$EDH_SSM_PATH/" --recursive --with-decryption \
    --query 'Parameters[].[Name,Value]' --output text > "$tmp"
  ( umask 077; : > "$EDH_APP_DIR/app.env.new" )
  while IFS=$'\t' read -r name value; do
    [[ -n "$name" ]] || continue
    key="${name#"$EDH_SSM_PATH"/}"
    case "$key" in
      _edh/postgres-password) pg_pw="$value" ;;
      _edh/maint-bypass) bypass="$value" ;;
      _edh/*|*/*) ;;
      *) k=$(printf '%s' "$key" | tr 'a-z-' 'A-Z_'); printf '%s=%s\n' "$k" "$value" >> "$EDH_APP_DIR/app.env.new" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  [[ -n "$pg_pw" && -n "$bypass" ]] || die "missing $EDH_SSM_PATH/_edh/postgres-password or maint-bypass — run provision.sh"
  if ! grep -q '^DATABASE_URL=' "$EDH_APP_DIR/app.env.new"; then
    echo "DATABASE_URL=postgres://app:${pg_pw}@postgres:5432/app" >> "$EDH_APP_DIR/app.env.new"
  fi
  mv "$EDH_APP_DIR/app.env.new" "$EDH_APP_DIR/app.env"
  ( umask 077; printf 'POSTGRES_USER=app\nPOSTGRES_DB=app\nPOSTGRES_PASSWORD=%s\n' "$pg_pw" > "$EDH_APP_DIR/postgres.env" )
  MAINT_BYPASS="$bypass"
}

# write_compose_env <image> — interpolation values for compose.yml (0600: holds the bypass token)
write_compose_env() {
  local profiles=""
  if [[ "${EDH_USES_GOTENBERG:-false}" == true ]]; then profiles=gotenberg; fi
  ( umask 077; cat > "$EDH_APP_DIR/.env.new" <<EOF
EDH_NAME=$EDH_NAME
APP_IMAGE=$1
APP_PORT=${EDH_APP_PORT:-3000}
APP_MEMORY_MB=${EDH_APP_MEMORY_MB:-768}
DOMAIN=$EDH_DOMAIN
MAINT_BYPASS=$MAINT_BYPASS
COMPOSE_PROFILES=$profiles
EDH_DATA_DIR=$EDH_DATA_DIR
EDH_HTTP_PORT=${EDH_HTTP_PORT:-80}
EDH_HTTPS_PORT=${EDH_HTTPS_PORT:-443}
EOF
  )
  mv "$EDH_APP_DIR/.env.new" "$EDH_APP_DIR/.env"
}

current_image() { sed -n 's/^APP_IMAGE=//p' "$EDH_APP_DIR/.env" 2>/dev/null || true; }

wait_postgres() {
  local i
  for i in $(seq 1 30); do dc exec -T postgres pg_isready -q -U app -d app 2>/dev/null && return 0; sleep 2; done
  die "postgres did not become ready"
}

reload_caddy() {
  local i
  for i in 1 2 3 4 5; do
    dc exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 && return 0
    sleep 2
  done
  die "Caddy rejected the Caddyfile — previous config still active"
}

prune_images() { # keep the 3 newest images of this repo
  local n=0 ref
  docker image ls "${1%:*}" --format '{{.Repository}}:{{.Tag}}' | while read -r ref; do
    n=$((n + 1))
    if (( n > 3 )); then docker image rm "$ref" >/dev/null 2>&1 || true; fi
  done
  docker image prune -f >/dev/null
}

maint_on=0
finish_maint() { if (( maint_on )); then "$EDH_BIN_DIR/edh-maint.sh" off >/dev/null; fi; }

install_units
install_app_files
write_secrets
PREV=$(current_image)

if [[ "${EDH_SKIP_PULL:-}" != 1 ]]; then
  aws ecr get-login-password --region "$EDH_REGION" | docker login --username AWS --password-stdin "${IMAGE%%/*}" >/dev/null
  docker pull -q "$IMAGE" >/dev/null
fi

write_compose_env "${PREV:-$IMAGE}"
services="caddy postgres"
if [[ "${EDH_USES_GOTENBERG:-false}" == true ]]; then services="$services gotenberg"; fi
# shellcheck disable=SC2086
dc up -d --remove-orphans $services
reload_caddy
wait_postgres

if [[ -n "$PREV" ]]; then
  "$EDH_BIN_DIR/edh-backup.sh" --tag safety --force >/dev/null || die "pre-deploy backup failed — not deploying"
fi
if [[ "$MAINT" == --maint ]]; then
  "$EDH_BIN_DIR/edh-maint.sh" on --message "We're upgrading the system." --until "in a few minutes" >/dev/null
  maint_on=1
fi
if [[ -n "${EDH_MIGRATE_CMD:-}" ]]; then
  log "running migrations with $IMAGE"
  if ! APP_IMAGE="$IMAGE" dc run --rm --no-deps -T app sh -c "$EDH_MIGRATE_CMD"; then
    finish_maint
    alert "deploy failed" "Migrations failed for $IMAGE. The previous version is still running."
    exit 1
  fi
fi

write_compose_env "$IMAGE"
dc up -d app
if wait_health 30; then
  finish_maint
  if [[ -n "$PREV" && "$PREV" != "$IMAGE" ]]; then printf '%s\n' "$PREV" > "$EDH_APP_DIR/previous_image"; fi
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$IMAGE" "${PREV:--}" >> "$EDH_DATA_DIR/deploys.log"
  prune_images "$IMAGE"
  log "deployed $IMAGE"
  exit 0
fi

log "health check failed for $IMAGE"
if [[ -n "$PREV" && "$PREV" != "$IMAGE" ]]; then
  write_compose_env "$PREV"
  dc up -d app
  if wait_health 30; then
    finish_maint
    alert "deploy rolled back" "$IMAGE failed its health check; rolled back to $PREV."
    exit 2
  fi
  alert "SITE DOWN after deploy" "Both $IMAGE and $PREV fail /health."
  exit 3
fi
alert "deploy failed" "$IMAGE fails /health and there is no previous version."
exit 3
```

**Step 4: `edh-rollback.sh`**

```bash
#!/usr/bin/env bash
# edh-rollback.sh — switch the app back to the previously deployed image.
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh"
prev=$(cat "$EDH_APP_DIR/previous_image" 2>/dev/null || true)
[[ -n "$prev" ]] || die "no previous image recorded"
cur=$(sed -n 's/^APP_IMAGE=//p' "$EDH_APP_DIR/.env")
sed -i.bak "s#^APP_IMAGE=.*#APP_IMAGE=$prev#" "$EDH_APP_DIR/.env" && rm -f "$EDH_APP_DIR/.env.bak"
dc up -d app
wait_health 30 || die "previous image $prev is unhealthy too"
printf '%s\n' "$cur" > "$EDH_APP_DIR/previous_image"
printf '%s\t%s\t%s\trollback\n' "$(date -u +%FT%TZ)" "$prev" "$cur" >> "$EDH_DATA_DIR/deploys.log"
log "rolled back to $prev"
```

**Step 5: `edh-status.sh`**

```bash
#!/usr/bin/env bash
# edh-status.sh — one-screen health summary of this server (read-only).
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh"
echo "maintenance: $("$EDH_BIN_DIR/edh-maint.sh" status)"
echo "image: $(sed -n 's/^APP_IMAGE=//p' "$EDH_APP_DIR/.env" 2>/dev/null)"
echo "last deploy: $(tail -1 "$EDH_DATA_DIR/deploys.log" 2>/dev/null || echo none)"
last=$(ls -1t "$EDH_DATA_DIR"/backups/app-*.dump 2>/dev/null | head -1 || true)
if [[ -n "$last" ]]; then
  age=$(( ($(date +%s) - $(date -r "$last" +%s)) / 60 ))
  echo "last backup: $(basename "$last") (${age} min ago)$( (( age > 120 )) && echo '  ← STALE')"
else
  echo "last backup: none  ← STALE"
fi
echo "containers:"; dc ps --format '  {{.Service}}: {{.State}} {{.Health}}' 2>/dev/null || true
echo "disk:"; df -h / "$EDH_DATA_DIR" 2>/dev/null | sed 's/^/  /'
if command -v free >/dev/null; then echo "memory:"; free -m | sed 's/^/  /'; fi
```

`date -r <file> +%s` works with GNU date (file mode) and BSD date, so the test passes on the Mac.

**Step 6: Run** `bash tests/ec2-dedicated-host/test_int_host.sh`. Expected: all pass.

Debug failures one at a time with `cat $T/out`. Change `cleanup` temporarily to keep `$T` if needed. Remove the stray `bash "$EDH_BIN_DIR/edh-lib.sh"` line in the test if shellcheck complains. Only the `.` (source) line is needed.

**Step 7: `run.sh --fast`** to get shellcheck clean.

**Step 8: Commit** `feat(ec2-dedicated-host): host deploy, rollback, status + integration test`

---

### Task 9: Server bootstrap, systemd units and CloudWatch agent config

**Files:**
- Create: `skills/ec2-dedicated-host/assets/host/bootstrap.sh`
- Create: `skills/ec2-dedicated-host/assets/host/systemd/edh-backup.service`
- Create: `skills/ec2-dedicated-host/assets/host/systemd/edh-backup.timer`
- Create: `skills/ec2-dedicated-host/assets/host/systemd/edh-drill.service`
- Create: `skills/ec2-dedicated-host/assets/host/systemd/edh-drill.timer`
- Create: `skills/ec2-dedicated-host/assets/host/cwagent.json`
- Create: `tests/ec2-dedicated-host/test_assets.sh`

**Step 1: Failing test.** It checks that templates render and that the JSON is valid.

```bash
# tests/ec2-dedicated-host/test_assets.sh
. "$(dirname "$0")/assert.sh"
for f in "$SKILL_DIR"/assets/host/cwagent.json "$SKILL_DIR"/assets/aws/*.json; do
  python3 -m json.tool "$f" >/dev/null 2>&1 && pass "valid JSON: $(basename "$f")" || fail "invalid JSON: $f"
done
out=$(bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$SKILL_DIR/assets/project/deploy.yml'; render_bootstrap vol-0abc123" 2>&1)
assert_contains "$out" 'VOLUME_ID="vol-0abc123"' "bootstrap gets the volume id"
assert_not_contains "$out" "__" "no unrendered placeholders in bootstrap"
for u in "$SKILL_DIR"/assets/host/systemd/*; do assert_contains "$(cat "$u")" "edh-" "unit $(basename "$u") references edh"; done
finish
```

(The `assets/aws/*.json` files arrive in Task 10. Until then the loop only sees `cwagent.json`.)

**Step 2: Run.** Expected: FAIL.

**Step 3: `bootstrap.sh`** (EC2 user-data, rendered by `render_bootstrap`)

```bash
#!/bin/bash
# cloud-init user-data for an ec2-dedicated-host server (Ubuntu 24.04 arm64). Rendered by provision.sh.
# Installs Docker + AWS CLI, mounts the data volume at /data (formats only if blank), adds 1 GB swap.
set -euxo pipefail
exec > >(tee -a /var/log/edh-bootstrap.log) 2>&1
VOLUME_ID="__VOLUME_ID__"
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y docker.io docker-compose-v2 unattended-upgrades
snap install aws-cli --classic

cat > /etc/docker/daemon.json <<'EOF'
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" }, "live-restore": true }
EOF
systemctl restart docker

# Security updates install automatically; reboots only happen through upgrade.sh.
echo 'Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/52edh-unattended

# Data volume: wait for the attachment, format only when blank, mount by UUID with nofail.
DEV="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOLUME_ID//-/}"
for _ in $(seq 1 120); do [ -e "$DEV" ] && break; sleep 5; done
[ -e "$DEV" ] || { echo "data volume $VOLUME_ID never attached"; exit 1; }
blkid "$DEV" >/dev/null 2>&1 || mkfs.ext4 -L edh-data "$DEV"
UUID=$(blkid -s UUID -o value "$DEV")
mkdir -p /data
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /data ext4 defaults,nofail,x-systemd.device-timeout=30s 0 2" >> /etc/fstab
mount -a
mountpoint -q /data
install -d -m 700 /data/postgres
install -d -m 755 /data/caddy /data/maint /data/backups

if [ ! -f /swapfile ]; then
  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

mkdir -p /var/lib/edh && touch /var/lib/edh/bootstrap-done
```

**Step 4: `render_bootstrap` in `lib.sh`**

```bash
# render_bootstrap <data-volume-id> — EC2 user-data with the volume id filled in
render_bootstrap() { sed "s/__VOLUME_ID__/$1/" "$EDH_SKILL_DIR/assets/host/bootstrap.sh"; }
```

**Step 5: systemd units**

`edh-backup.service`:
```ini
[Unit]
Description=edh database backup (pg_dump to S3)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/opt/edh/bin/edh-backup.sh
```
`edh-backup.timer`:
```ini
[Unit]
Description=edh hourly backup

[Timer]
OnCalendar=*-*-* *:05:00
RandomizedDelaySec=120
Persistent=true

[Install]
WantedBy=timers.target
```
`edh-drill.service`: same shape as the backup service, with `ExecStart=/opt/edh/bin/edh-drill.sh` and Description "edh monthly restore drill".

`edh-drill.timer`: `OnCalendar=*-*-02 03:30:00` (UTC), `Persistent=true`.

**Step 6: `cwagent.json`**

```json
{
  "agent": { "metrics_collection_interval": 60, "run_as_user": "root" },
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": { "InstanceId": "${aws:InstanceId}" },
    "metrics_collected": {
      "mem": { "measurement": ["mem_used_percent"] },
      "disk": {
        "measurement": ["used_percent"],
        "resources": ["/", "/data"],
        "drop_device": true,
        "ignore_file_system_types": ["sysfs", "tmpfs", "devtmpfs", "overlay", "squashfs"]
      }
    }
  }
}
```

**Step 7: Run** the test and `run.sh --fast`. Expected: pass.

**Step 8: Commit** `feat(ec2-dedicated-host): bootstrap, systemd timers, cloudwatch agent config`

---

### Task 10: AWS policy and lifecycle templates

**Files:**
- Create: `skills/ec2-dedicated-host/assets/aws/ec2-trust.json`
- Create: `skills/ec2-dedicated-host/assets/aws/host-policy.json`
- Create: `skills/ec2-dedicated-host/assets/aws/backups-lifecycle.json`
- Create: `skills/ec2-dedicated-host/assets/aws/uploads-lifecycle.json`
- Create: `skills/ec2-dedicated-host/assets/aws/dlm-policy.json`
- Modify: `skills/ec2-dedicated-host/scripts/lib.sh` (add `render_aws`)
- Modify: `tests/ec2-dedicated-host/test_assets.sh` (add render checks)

**Step 1: Add failing checks to `test_assets.sh`** (before `finish`)

```bash
pol=$(bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$SKILL_DIR/assets/project/deploy.yml'; EDH_ACCOUNT=123456789012; render_aws host-policy.json" 2>&1)
printf '%s' "$pol" | python3 -m json.tool >/dev/null 2>&1 && pass "rendered host policy is JSON" || fail "rendered host policy invalid"
assert_contains "$pol" "parameter/acme/prod/*" "policy scoped to client SSM path"
assert_contains "$pol" "edh-acme-prod-backups-123456789012/db/*" "backup writes scoped to db/"
assert_not_contains "$pol" "s3:DeleteObject\",\"Resource\":\"arn:aws:s3:::edh-acme-prod-backups" "host cannot delete backups"
assert_not_contains "$pol" "__" "no unrendered placeholders"
```

**Step 2: Run.** Expected: FAIL.

**Step 3: Templates**

`ec2-trust.json`:
```json
{ "Version": "2012-10-17", "Statement": [ { "Effect": "Allow", "Principal": { "Service": "ec2.amazonaws.com" }, "Action": "sts:AssumeRole" } ] }
```

`host-policy.json`. Least privilege for one client. The server can write backups under `db/` but can never delete them.
```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "ReadOwnSecrets", "Effect": "Allow",
      "Action": ["ssm:GetParametersByPath", "ssm:GetParameter", "ssm:GetParameters"],
      "Resource": ["arn:aws:ssm:__REGION__:__ACCOUNT__:parameter__SSM_PATH__", "arn:aws:ssm:__REGION__:__ACCOUNT__:parameter__SSM_PATH__/*"] },
    { "Sid": "DecryptSecrets", "Effect": "Allow", "Action": "kms:Decrypt", "Resource": "*",
      "Condition": { "StringEquals": { "kms:ViaService": "ssm.__REGION__.amazonaws.com" } } },
    { "Sid": "BackupsWrite", "Effect": "Allow", "Action": "s3:PutObject", "Resource": "arn:aws:s3:::__BACKUP_BUCKET__/db/*" },
    { "Sid": "BackupsRead", "Effect": "Allow", "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::__BACKUP_BUCKET__", "arn:aws:s3:::__BACKUP_BUCKET__/*"] },
    { "Sid": "AppUploads", "Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::__UPLOADS_BUCKET__", "arn:aws:s3:::__UPLOADS_BUCKET__/*"] },
    { "Sid": "PullOwnImage", "Effect": "Allow",
      "Action": ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"],
      "Resource": "arn:aws:ecr:__REGION__:__ACCOUNT__:repository/__ECR_REPO__" },
    { "Sid": "EcrAuth", "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    { "Sid": "EdhMetrics", "Effect": "Allow", "Action": "cloudwatch:PutMetricData", "Resource": "*",
      "Condition": { "StringEquals": { "cloudwatch:namespace": "EDH" } } },
    { "Sid": "Alerts", "Effect": "Allow", "Action": "sns:Publish", "Resource": "arn:aws:sns:__REGION__:__ACCOUNT__:__TOPIC__" }
  ]
}
```

`backups-lifecycle.json`:
```json
{ "Rules": [
  { "ID": "hourly",   "Status": "Enabled", "Filter": { "Prefix": "db/hourly/" },  "Expiration": { "Days": 3 } },
  { "ID": "daily",    "Status": "Enabled", "Filter": { "Prefix": "db/daily/" },   "Expiration": { "Days": 90 } },
  { "ID": "monthly",  "Status": "Enabled", "Filter": { "Prefix": "db/monthly/" },
    "Transitions": [ { "Days": 30, "StorageClass": "GLACIER_IR" } ], "Expiration": { "Days": 365 } },
  { "ID": "safety",   "Status": "Enabled", "Filter": { "Prefix": "db/safety/" },  "Expiration": { "Days": 30 } },
  { "ID": "bundles",  "Status": "Enabled", "Filter": { "Prefix": "_edh/bundles/" }, "Expiration": { "Days": 90 } },
  { "ID": "noncurrent", "Status": "Enabled", "Filter": { "Prefix": "" },
    "NoncurrentVersionExpiration": { "NoncurrentDays": 30 }, "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 } }
] }
```

`uploads-lifecycle.json`: one rule, `noncurrent`, as above. Keep only the noncurrent rule and the abort rule; never expire current versions.

`dlm-policy.json`:
```json
{
  "PolicyType": "EBS_SNAPSHOT_MANAGEMENT",
  "ResourceTypes": ["VOLUME"],
  "TargetTags": [ { "Key": "edh:snapshot", "Value": "__NAME__" } ],
  "Schedules": [
    { "Name": "daily", "CopyTags": true, "TagsToAdd": [ { "Key": "edh:schedule", "Value": "daily" } ],
      "CreateRule": { "Interval": 24, "IntervalUnit": "HOURS", "Times": ["18:30"] }, "RetainRule": { "Count": 7 } },
    { "Name": "weekly", "CopyTags": true, "TagsToAdd": [ { "Key": "edh:schedule", "Value": "weekly" } ],
      "CreateRule": { "CronExpression": "cron(30 19 ? * SUN *)" }, "RetainRule": { "Count": 4 } }
  ]
}
```

**Step 4: `render_aws` in `lib.sh`**

```bash
# render_aws <file-in-assets/aws> — fill placeholders for this client
render_aws() {
  local acct; acct=$(aws_account)
  sed -e "s#__REGION__#$EDH_REGION#g" -e "s#__ACCOUNT__#$acct#g" -e "s#__SSM_PATH__#$EDH_SSM_PATH#g" \
      -e "s#__BACKUP_BUCKET__#${EDH_PREFIX}-backups-${acct}#g" -e "s#__UPLOADS_BUCKET__#${EDH_PREFIX}-uploads-${acct}#g" \
      -e "s#__ECR_REPO__#$EDH_ECR_REPO#g" -e "s#__TOPIC__#${EDH_PREFIX}-alerts#g" -e "s#__NAME__#$EDH_NAME#g" \
      "$EDH_SKILL_DIR/assets/aws/$1"
}
```

**Step 5: Run.** Expected: pass.

**Step 6: Commit** `feat(ec2-dedicated-host): IAM, S3 lifecycle and DLM templates`

---

### Task 11: `init.sh` (scaffold `deploy/` in a project)

**Files:**
- Create: `skills/ec2-dedicated-host/scripts/init.sh`
- Create: `tests/ec2-dedicated-host/test_init.sh`

**Step 1: Failing test**

```bash
# tests/ec2-dedicated-host/test_init.sh
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cd "$T"
bash "$SKILL_DIR/scripts/init.sh" --client acme --domain erp.acme.com --emails "a@x.com,b@x.com" \
  --gotenberg --app-memory 700 --migrate "npx prisma migrate deploy" >/dev/null 2>&1
assert_status $? 0 "init succeeds"
y=$(cat deploy/deploy.yml)
assert_contains "$y" "client: acme" "client set"
assert_contains "$y" "domain: erp.acme.com" "domain set"
assert_contains "$y" "alert_emails: a@x.com,b@x.com" "emails set"
assert_contains "$y" "uses_gotenberg: true" "gotenberg set"
assert_contains "$y" 'migrate_cmd: "npx prisma migrate deploy"' "migrate set"
for f in compose.yml Caddyfile maint/maintenance.html maint/down.html; do [[ -f "deploy/$f" ]] && pass "has $f" || fail "missing $f"; done
out=$(bash "$SKILL_DIR/scripts/init.sh" --client acme --domain erp.acme.com --emails a@x.com 2>&1)
assert_contains "$out" "already exists" "refuses to overwrite"
finish
```

**Step 2: Run.** Expected: FAIL.

**Step 3: Implement**

```bash
#!/usr/bin/env bash
# init.sh --client NAME --domain FQDN [--emails a@x,b@y] [--env prod] [--region R] [--monitoring cloudwatch|none]
#         [--gotenberg] [--app-memory MB] [--app-port N] [--migrate "CMD"]
# Scaffold deploy/ (deploy.yml, compose.yml, Caddyfile, maint pages) in the current project. Never overwrites.
. "$(dirname "$0")/lib.sh"

client="" domain="" emails="" env=prod region=ap-southeast-1 monitoring=cloudwatch got=false mem=768 port=3000 migrate=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --client) client="$2"; shift 2 ;;      --domain) domain="$2"; shift 2 ;;
    --emails) emails="$2"; shift 2 ;;      --env) env="$2"; shift 2 ;;
    --region) region="$2"; shift 2 ;;      --monitoring) monitoring="$2"; shift 2 ;;
    --gotenberg) got=true; shift ;;        --app-memory) mem="$2"; shift 2 ;;
    --app-port) port="$2"; shift 2 ;;      --migrate) migrate="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -e deploy/deploy.yml ]] && die "deploy/deploy.yml already exists — edit it instead"
mkdir -p deploy/maint
A="$EDH_SKILL_DIR/assets/project"
sed -e "s/^client: .*/client: $client/" -e "s/^env: .*/env: $env/" -e "s/^region: .*/region: $region/" \
    -e "s/^domain: .*/domain: $domain/" -e "s/^alert_emails: .*/alert_emails: $emails/" \
    -e "s/^monitoring: .*/monitoring: $monitoring/" -e "s/^uses_gotenberg: .*/uses_gotenberg: $got/" \
    -e "s/^app_memory_mb: .*/app_memory_mb: $mem/" -e "s/^app_port: .*/app_port: $port/" \
    -e "s#^migrate_cmd: .*#migrate_cmd: \"$migrate\"#" "$A/deploy.yml" > deploy/deploy.yml
cp "$A/compose.yml" "$A/Caddyfile" deploy/
cp "$A/maint/"*.html deploy/maint/
load_config deploy/deploy.yml   # validates what we wrote
ok "created deploy/ for $EDH_NAME ($domain)"
```

Trailing comments in the template are lost on lines rewritten by `sed`. That's acceptable: those lines are already self-explanatory, and the comments stay on every other line.

**Step 4: Run.** Expected: pass.

**Step 5: Commit** `feat(ec2-dedicated-host): init.sh scaffolds deploy/`

---

### Task 12: `provision.sh` (plan/apply, idempotent)

**Files:**
- Create: `skills/ec2-dedicated-host/scripts/provision.sh`
- Create: `tests/ec2-dedicated-host/test_provision_plan.sh`

**Step 1: Failing test.** A plan run makes no changes, and it detects resources that already exist.

```bash
# tests/ec2-dedicated-host/test_provision_plan.sh
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PATH="$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/log"
mkdir -p "$T/p/deploy"; cp "$SKILL_DIR/assets/project/deploy.yml" "$T/p/deploy/"
cd "$T/p"

out=$(STUB_MODE=empty bash "$SKILL_DIR/scripts/provision.sh" 2>&1); rc=$?
assert_status $rc 0 "plan on empty account exits 0"
for r in "IAM role" "security group" "backup bucket" "uploads bucket" "ECR repo" "data volume" "Elastic IP" "server"; do
  assert_contains "$out" "$r edh" "plan lists $r"
done
assert_contains "$out" "would create" "plan says would create"
mut=$(grep -E ' (create-|run-instances|put-|attach-|associate-|allocate-|authorize-|modify-|delete-|terminate-|add-role|tag-|update-)' "$T/log" || true)
assert_eq "$mut" "" "plan makes no mutating AWS calls"

: > "$T/log"
out=$(STUB_MODE=existing bash "$SKILL_DIR/scripts/provision.sh" 2>&1)
assert_contains "$out" "server edh-acme-prod: exists" "detects existing server"
assert_contains "$out" "data volume edh-acme-prod-data: exists" "detects existing volume"
finish
```

**Step 2: Run.** Expected: FAIL.

**Step 3: Implement `provision.sh`**

```bash
#!/usr/bin/env bash
# provision.sh [--apply]
# Create, or verify, every AWS resource for this project's dedicated server. Default: plan only (no changes).
# Re-runnable: each step checks for the tagged resource first. Never deletes anything.
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/sizing.sh"

APPLY=0; if [[ "${1:-}" == --apply ]]; then APPLY=1; fi
load_config
require aws
ACCT=$(aws_account)
ROLE="${EDH_PREFIX}-host"
B_BACKUP="${EDH_PREFIX}-backups-${ACCT}"
B_UPLOADS="${EDH_PREFIX}-uploads-${ACCT}"
TYPE="$EDH_INSTANCE_TYPE"
if [[ "$TYPE" == auto ]]; then TYPE=$(recommend_instance "$EDH_APP_MEMORY_MB" "$EDH_USES_GOTENBERG"); fi
VPC=$(awsr ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
[[ -n "$VPC" && "$VPC" != None ]] || die "no default VPC in $EDH_REGION"
SG_ID="" VOL_ID="" AZ="" EIP_ALLOC="" EIP_IP="" EDH_IID=""

# step <description> <check-fn> <create-fn>
step() {
  if "$2"; then ok "$1: exists"; return 0; fi
  if (( APPLY )); then log "$1: creating"; "$3"; ok "$1: created"; else warn "$1: would create"; fi
}

has_role()  { aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; }
make_role() {
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document "file://$EDH_SKILL_DIR/assets/aws/ec2-trust.json" \
    --tags "Key=edh:client,Value=$EDH_CLIENT" "Key=edh:env,Value=$EDH_ENV" "Key=ManagedBy,Value=ec2-dedicated-host" >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam create-instance-profile --instance-profile-name "$ROLE" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE"
  sleep 15   # IAM propagation before run-instances can use the profile
}
sync_policy() {
  local f; f=$(mktemp); render_aws host-policy.json > "$f"
  aws iam put-role-policy --role-name "$ROLE" --policy-name edh-host --policy-document "file://$f"
  rm -f "$f"
}

has_sg() {
  SG_ID=$(awsr ec2 describe-security-groups --filters "Name=group-name,Values=$EDH_PREFIX" "Name=vpc-id,Values=$VPC" \
    --query 'SecurityGroups[0].GroupId' --output text)
  [[ -n "$SG_ID" && "$SG_ID" != None ]]
}
make_sg() {
  SG_ID=$(awsr ec2 create-security-group --group-name "$EDH_PREFIX" --vpc-id "$VPC" \
    --description "ec2-dedicated-host $EDH_NAME: web only, no SSH" \
    --tag-specifications "$(tag_spec security-group "$EDH_PREFIX")" --query GroupId --output text)
  awsr ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions \
    'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}],Ipv6Ranges=[{CidrIpv6=::/0}]' \
    'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}],Ipv6Ranges=[{CidrIpv6=::/0}]' \
    'IpProtocol=udp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]' >/dev/null
}

has_bucket() { aws s3api head-bucket --bucket "$1" >/dev/null 2>&1; }
make_bucket() { # make_bucket <name> <lifecycle-file>
  local f
  if [[ "$EDH_REGION" == us-east-1 ]]; then awsr s3api create-bucket --bucket "$1" >/dev/null
  else awsr s3api create-bucket --bucket "$1" --create-bucket-configuration "LocationConstraint=$EDH_REGION" >/dev/null; fi
  awsr s3api put-public-access-block --bucket "$1" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  awsr s3api put-bucket-versioning --bucket "$1" --versioning-configuration Status=Enabled
  awsr s3api put-bucket-tagging --bucket "$1" --tagging \
    "TagSet=[{Key=Protect,Value=true},{Key=edh:client,Value=$EDH_CLIENT},{Key=edh:env,Value=$EDH_ENV},{Key=Client,Value=$EDH_CLIENT},{Key=ManagedBy,Value=ec2-dedicated-host}]"
  f=$(mktemp); render_aws "$2" > "$f"
  awsr s3api put-bucket-lifecycle-configuration --bucket "$1" --lifecycle-configuration "file://$f"
  rm -f "$f"
}
has_backup_bucket()  { has_bucket "$B_BACKUP"; }
make_backup_bucket() { make_bucket "$B_BACKUP" backups-lifecycle.json; }
has_uploads_bucket() { has_bucket "$B_UPLOADS"; }
make_uploads_bucket(){ make_bucket "$B_UPLOADS" uploads-lifecycle.json; }

has_ecr()  { awsr ecr describe-repositories --repository-names "$EDH_ECR_REPO" >/dev/null 2>&1; }
make_ecr() {
  awsr ecr create-repository --repository-name "$EDH_ECR_REPO" --image-scanning-configuration scanOnPush=true \
    --tags "Key=edh:client,Value=$EDH_CLIENT" "Key=ManagedBy,Value=ec2-dedicated-host" >/dev/null
  awsr ecr put-lifecycle-policy --repository-name "$EDH_ECR_REPO" --lifecycle-policy-text \
    '{"rules":[{"rulePriority":1,"description":"keep last 20","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":20},"action":{"type":"expire"}}]}' >/dev/null
}

has_secrets() { awsr ssm get-parameter --name "$EDH_SSM_PATH/_edh/postgres-password" >/dev/null 2>&1; }
make_secrets() {
  local n
  for n in postgres-password maint-bypass; do
    if ! awsr ssm get-parameter --name "$EDH_SSM_PATH/_edh/$n" >/dev/null 2>&1; then
      awsr ssm put-parameter --name "$EDH_SSM_PATH/_edh/$n" --type SecureString --value "$(gen_secret 40)" >/dev/null
    fi
  done
}

has_volume() {
  local out
  out=$(awsr ec2 describe-volumes --filters "Name=tag:edh:client,Values=$EDH_CLIENT" "Name=tag:edh:env,Values=$EDH_ENV" \
    "Name=tag:edh:role,Values=data" --query 'Volumes[0].[VolumeId,AvailabilityZone]' --output text)
  VOL_ID=$(printf '%s' "$out" | cut -f1); [[ -n "$VOL_ID" && "$VOL_ID" != None ]] || return 1
  AZ=$(printf '%s' "$out" | cut -f2)
}
make_volume() {
  VOL_ID=$(awsr ec2 create-volume --availability-zone "$AZ" --size "$EDH_DATA_GB" --volume-type gp3 --encrypted \
    --tag-specifications "$(tag_spec volume "${EDH_PREFIX}-data" edh:role=data Protect=true "edh:snapshot=$EDH_NAME")" \
    --query VolumeId --output text)
  awsr ec2 wait volume-available --volume-ids "$VOL_ID"
}

has_eip() {
  local out
  out=$(awsr ec2 describe-addresses --filters "Name=tag:edh:client,Values=$EDH_CLIENT" "Name=tag:edh:env,Values=$EDH_ENV" \
    --query 'Addresses[0].[AllocationId,PublicIp]' --output text)
  EIP_ALLOC=$(printf '%s' "$out" | cut -f1); EIP_IP=$(printf '%s' "$out" | cut -f2)
  [[ -n "$EIP_ALLOC" && "$EIP_ALLOC" != None ]]
}
make_eip() {
  local out
  out=$(awsr ec2 allocate-address --domain vpc --tag-specifications "$(tag_spec elastic-ip "$EDH_PREFIX")" \
    --query '[AllocationId,PublicIp]' --output text)
  EIP_ALLOC=$(printf '%s' "$out" | cut -f1); EIP_IP=$(printf '%s' "$out" | cut -f2)
}

has_instance() { EDH_IID=$(instance_id); [[ -n "$EDH_IID" && "$EDH_IID" != None ]]; }
make_instance() {
  local ami subnet ud
  ami=$(awsr ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id \
    --query Parameter.Value --output text)
  subnet=$(awsr ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" "Name=availability-zone,Values=$AZ" \
    "Name=default-for-az,Values=true" --query 'Subnets[0].SubnetId' --output text)
  ud=$(mktemp); render_bootstrap "$VOL_ID" > "$ud"
  EDH_IID=$(awsr ec2 run-instances --image-id "$ami" --instance-type "$TYPE" --subnet-id "$subnet" \
    --security-group-ids "$SG_ID" --iam-instance-profile "Name=$ROLE" --user-data "file://$ud" \
    --metadata-options HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}' \
    --disable-api-termination \
    --tag-specifications "$(tag_spec instance "$EDH_PREFIX")" "$(tag_spec volume "${EDH_PREFIX}-root" edh:role=root)" \
    --query 'Instances[0].InstanceId' --output text)
  rm -f "$ud"
  awsr ec2 wait instance-running --instance-ids "$EDH_IID"
}

is_attached()   { [[ $(awsr ec2 describe-volumes --volume-ids "$VOL_ID" --query 'Volumes[0].Attachments[0].InstanceId' --output text) == "$EDH_IID" ]]; }
attach()        { awsr ec2 attach-volume --volume-id "$VOL_ID" --instance-id "$EDH_IID" --device /dev/sdf >/dev/null; awsr ec2 wait volume-in-use --volume-ids "$VOL_ID"; }
is_associated() { [[ $(awsr ec2 describe-addresses --allocation-ids "$EIP_ALLOC" --query 'Addresses[0].InstanceId' --output text) == "$EDH_IID" ]]; }
associate()     { awsr ec2 associate-address --allocation-id "$EIP_ALLOC" --instance-id "$EDH_IID" >/dev/null; }

has_dlm() {
  local id; id=$(awsr dlm get-lifecycle-policies --target-tags "edh:snapshot=$EDH_NAME" --query 'Policies[0].PolicyId' --output text)
  [[ -n "$id" && "$id" != None ]]
}
make_dlm() {
  local role f
  role=$(aws iam get-role --role-name AWSDataLifecycleManagerDefaultRole --query Role.Arn --output text 2>/dev/null || true)
  if [[ -z "$role" ]]; then
    awsr dlm create-default-role --resource-type snapshot >/dev/null; sleep 15
    role=$(aws iam get-role --role-name AWSDataLifecycleManagerDefaultRole --query Role.Arn --output text)
  fi
  f=$(mktemp); render_aws dlm-policy.json > "$f"
  awsr dlm create-lifecycle-policy --description "$EDH_PREFIX data snapshots" --state ENABLED \
    --execution-role-arn "$role" --policy-details "file://$f" \
    --tags "edh:client=$EDH_CLIENT,ManagedBy=ec2-dedicated-host" >/dev/null
  rm -f "$f"
}

bootstrap_done() { ssm_run "$EDH_IID" 60 'test -f /var/lib/edh/bootstrap-done' >/dev/null 2>&1; }

log "provision $EDH_NAME — account $ACCT, region $EDH_REGION — $( (( APPLY )) && echo APPLY || echo 'plan only, nothing changes')"
log "server type $TYPE · data disk ${EDH_DATA_GB} GB · domain $EDH_DOMAIN · monitoring $EDH_MONITORING"

step "IAM role $ROLE" has_role make_role
if (( APPLY )); then sync_policy; ok "host policy synced"; else warn "host policy: would sync"; fi
step "security group $EDH_PREFIX" has_sg make_sg
step "backup bucket $B_BACKUP" has_backup_bucket make_backup_bucket
step "uploads bucket $B_UPLOADS" has_uploads_bucket make_uploads_bucket
step "ECR repo $EDH_ECR_REPO" has_ecr make_ecr
step "internal secrets $EDH_SSM_PATH/_edh" has_secrets make_secrets

if ! has_volume; then
  AZ=$(awsr ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters "Name=instance-type,Values=$TYPE" --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' '\n' | sort | head -1)
fi
step "data volume ${EDH_PREFIX}-data" has_volume make_volume
step "Elastic IP $EDH_PREFIX" has_eip make_eip
step "server $EDH_PREFIX ($TYPE in $AZ)" has_instance make_instance

if (( APPLY )); then
  cur=$(awsr ec2 describe-instances --instance-ids "$EDH_IID" --query 'Reservations[0].Instances[0].[InstanceType,Placement.AvailabilityZone]' --output text)
  [[ "$(printf '%s' "$cur" | cut -f2)" == "$AZ" ]] || die "server is in $(printf '%s' "$cur" | cut -f2) but data volume is in $AZ"
  if [[ "$(printf '%s' "$cur" | cut -f1)" != "$TYPE" ]]; then warn "server is $(printf '%s' "$cur" | cut -f1), config wants $TYPE — use resize.sh"; fi
  step "data volume attached" is_attached attach
  step "Elastic IP associated" is_associated associate
  step "snapshot policy (DLM)" has_dlm make_dlm
  log "waiting for the server to finish bootstrapping (SSM)"
  wait_ssm "$EDH_IID"
  for _ in $(seq 1 60); do bootstrap_done && break; sleep 10; done
  bootstrap_done || die "bootstrap did not finish — check /var/log/edh-bootstrap.log via Session Manager"
  ok "server ready: $EDH_IID at $EIP_IP"
  if [[ "$EDH_MONITORING" == cloudwatch ]]; then "$(dirname "$0")/monitoring.sh" add; fi
  log "DNS: point an A record for $EDH_DOMAIN to $EIP_IP (needed before the first deploy can get HTTPS)"
else
  warn "attach volume, associate IP, snapshot policy, bootstrap wait$( [[ "$EDH_MONITORING" == cloudwatch ]] && echo ', monitoring')"
  log "plan only. Re-run with --apply after the user approves."
fi
```

Test note: in empty mode the check functions return "not found". In existing mode they return the stub IDs. `has_volume` parses `vol-stub<TAB>ap-southeast-1a`.

**Step 4: Run.** Expected: pass. Shellcheck may flag `"$2"` and `"$3"` being called as commands in `step`. That's intended; add `# shellcheck disable=SC2294` only if it complains.

**Step 5: Commit** `feat(ec2-dedicated-host): idempotent provision with plan mode`

---

### Task 13: Local `deploy.sh`, `secrets.sh`, `maint.sh`, `rollback.sh`, `backup.sh`, `restore.sh` and `status.sh`

**Files:**
- Create: `skills/ec2-dedicated-host/scripts/{deploy,secrets,maint,rollback,backup,restore,status}.sh`
- Modify: `skills/ec2-dedicated-host/scripts/lib.sh` (`release_env`, `make_bundle`)
- Create: `tests/ec2-dedicated-host/test_bundle.sh`

**Step 1: Failing test** for the release bundle

```bash
# tests/ec2-dedicated-host/test_bundle.sh
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PATH="$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/log"
cd "$T"; bash "$SKILL_DIR/scripts/init.sh" --client acme --domain erp.acme.com --emails a@x.com --migrate "npm run m" >/dev/null 2>&1
tgz=$(bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config; make_bundle abc123" 2>/dev/null)
list=$(tar tzf "$tgz")
for f in ./release.env ./app/compose.yml ./app/Caddyfile ./app/maint/maintenance.html ./host/edh-deploy.sh ./host/systemd/edh-backup.timer; do
  assert_contains "$list" "$f" "bundle has $f"
done
assert_not_contains "$list" "bootstrap.sh" "bootstrap is not shipped in bundles"
env=$(tar xzOf "$tgz" ./release.env)
assert_contains "$env" "EDH_BACKUP_BUCKET=edh-acme-prod-backups-123456789012" "release.env has bucket"
assert_contains "$env" "EDH_ALERT_TOPIC_ARN=arn:aws:sns:ap-southeast-1:123456789012:edh-acme-prod-alerts" "topic when monitoring on"
assert_contains "$env" "EDH_MIGRATE_CMD='npm run m'" "migrate cmd quoted"
assert_contains "$env" "EDH_RELEASE=abc123" "release id"
rm -f "$tgz"
finish
```

**Step 2: Run.** Expected: FAIL.

**Step 3: `lib.sh` additions**

```bash
# release_env <release-id> — non-secret settings for the server (/etc/edh/edh.env)
release_env() {
  local acct topic=""; acct=$(aws_account)
  if [[ "$EDH_MONITORING" == cloudwatch ]]; then topic="arn:aws:sns:$EDH_REGION:$acct:${EDH_PREFIX}-alerts"; fi
  cat <<EOF
EDH_CLIENT=$EDH_CLIENT
EDH_ENV=$EDH_ENV
EDH_NAME=$EDH_NAME
EDH_REGION=$EDH_REGION
EDH_DOMAIN=$EDH_DOMAIN
EDH_SSM_PATH=$EDH_SSM_PATH
EDH_BACKUP_BUCKET=${EDH_PREFIX}-backups-${acct}
EDH_BACKUP_SCHEDULE=$EDH_BACKUP_SCHEDULE
EDH_DAILY_HOUR_UTC=$EDH_DAILY_HOUR_UTC
EDH_APP_PORT=$EDH_APP_PORT
EDH_APP_MEMORY_MB=$EDH_APP_MEMORY_MB
EDH_USES_GOTENBERG=$EDH_USES_GOTENBERG
EDH_MIGRATE_CMD='$EDH_MIGRATE_CMD'
EDH_ALERT_TOPIC_ARN=$topic
EDH_RELEASE=$1
EOF
}

# make_bundle <release-id> — tgz of deploy/ + this skill's host scripts; prints its path
make_bundle() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/app/maint" "$d/host/systemd"
  cp deploy/compose.yml deploy/Caddyfile "$d/app/"
  cp deploy/maint/*.html "$d/app/maint/"
  cp "$EDH_SKILL_DIR"/assets/host/edh-*.sh "$d/host/"
  cp "$EDH_SKILL_DIR"/assets/host/systemd/* "$d/host/systemd/"
  release_env "$1" > "$d/release.env"
  tar czf "$d.tgz" -C "$d" .
  rm -rf "$d"
  printf '%s' "$d.tgz"
}
```

**Step 4: `deploy.sh`**

```bash
#!/usr/bin/env bash
# deploy.sh [--maint] [--allow-dirty]
# Build the current commit for arm64, push to ECR, ship deploy/ + host scripts, roll out via SSM.
#   --maint        show the maintenance page during migrations (use for risky migrations)
#   --allow-dirty  deploy uncommitted changes (tag gets -dirty<timestamp>)
. "$(dirname "$0")/lib.sh"
MAINT=""; DIRTY_OK=0
for a in "$@"; do case "$a" in --maint) MAINT=--maint ;; --allow-dirty) DIRTY_OK=1 ;; *) die "unknown option: $a" ;; esac; done
load_config; require docker; require git; require aws; require curl
require_instance
ACCT=$(aws_account)
REG="${ACCT}.dkr.ecr.${EDH_REGION}.amazonaws.com"
BUCKET="${EDH_PREFIX}-backups-${ACCT}"
SHA=$(git rev-parse --short=12 HEAD)
if [[ -n "$(git status --porcelain)" ]]; then
  (( DIRTY_OK )) || die "uncommitted changes — commit first, or pass --allow-dirty"
  SHA="${SHA}-dirty$(date +%s)"
fi
IMAGE="$REG/$EDH_ECR_REPO:$SHA"

ip=$(awsr ec2 describe-addresses --filters "Name=instance-id,Values=$EDH_IID" --query 'Addresses[0].PublicIp' --output text)
dns=$(dig +short "$EDH_DOMAIN" A 2>/dev/null | tail -1 || true)
if [[ "$dns" != "$ip" ]]; then warn "$EDH_DOMAIN resolves to '${dns:-nothing}', server is $ip — HTTPS will fail until DNS points here"; fi

log "1/4 build + push $IMAGE"
aws ecr get-login-password --region "$EDH_REGION" | docker login --username AWS --password-stdin "$REG" >/dev/null
docker buildx build --platform linux/arm64 -f "$EDH_DOCKERFILE" -t "$IMAGE" --push "$EDH_BUILD_CONTEXT"

log "2/4 ship config bundle"
tgz=$(make_bundle "$SHA")
awsr s3 cp "$tgz" "s3://$BUCKET/_edh/bundles/$SHA.tgz" --only-show-errors
rm -f "$tgz"

log "3/4 roll out on $EDH_IID"
rc=0
ssm_run "$EDH_IID" 1800 "set -euo pipefail
export PATH=/snap/bin:\$PATH
R=/opt/edh/releases/$SHA
rm -rf \"\$R\"; mkdir -p \"\$R\"
aws s3 cp s3://$BUCKET/_edh/bundles/$SHA.tgz - --region $EDH_REGION | tar xz -C \"\$R\"
ls -1dt /opt/edh/releases/* | tail -n +6 | xargs -r rm -rf
bash \"\$R/host/edh-deploy.sh\" \"\$R\" $IMAGE $MAINT" || rc=$?
case $rc in
  0) ;;
  1) die "deploy stopped before the swap — the previous version is still serving" ;;
  2) die "new version failed its health check — rolled back to the previous version" ;;
  *) die "deploy failed (exit $rc) — the site may be down; run status.sh" ;;
esac

log "4/4 verify https://$EDH_DOMAIN/health"
if curl -fsS --max-time 15 "https://$EDH_DOMAIN/health" >/dev/null; then ok "live: https://$EDH_DOMAIN ($SHA)"
else warn "deployed, but https://$EDH_DOMAIN/health failed from here — check DNS/TLS with status.sh"; fi
```

**Step 5: `secrets.sh`** (values come from stdin, never from arguments)

```bash
#!/usr/bin/env bash
# secrets.sh set <name>      read the value from stdin (not echoed) → SSM SecureString <path>/<name>
# secrets.sh list            names only
# secrets.sh delete <name>
# <name>: lowercase-with-dashes; becomes NAME_WITH_UNDERSCORES in the app's environment. Redeploy to apply.
. "$(dirname "$0")/lib.sh"
load_config
case "${1:-}" in
  set)
    [[ "${2:-}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "name must be lowercase letters/digits/dashes"
    [[ "$2" != _edh* ]] || die "_edh/ is reserved"
    if [[ -t 0 ]]; then read -r -s -p "value for $2: " v; echo >&2; else v=$(cat); fi
    [[ -n "$v" ]] || die "empty value"
    awsr ssm put-parameter --name "$EDH_SSM_PATH/$2" --type SecureString --value "$v" --overwrite >/dev/null
    ok "set $EDH_SSM_PATH/$2 (redeploy to apply)" ;;
  list)
    awsr ssm get-parameters-by-path --path "$EDH_SSM_PATH/" --recursive --query 'Parameters[].Name' --output text | tr '\t' '\n' ;;
  delete)
    confirm "Delete secret $EDH_SSM_PATH/${2:?name}?"
    awsr ssm delete-parameter --name "$EDH_SSM_PATH/$2"; ok "deleted" ;;
  *) die "usage: secrets.sh set <name> | list | delete <name>" ;;
esac
```

**Step 6: `maint.sh`**

```bash
#!/usr/bin/env bash
# maint.sh on [--message TEXT] [--until TEXT] | off | status
# Turns the planned-maintenance page on/off and pauses/resumes the site-down alert accordingly.
. "$(dirname "$0")/lib.sh"
load_config; require_instance
cmd="${1:-}"; shift || true
remote() { ssm_run "$EDH_IID" 120 "$(printf '%q ' /opt/edh/bin/edh-maint.sh "$@")"; }
site_alarm="${EDH_PREFIX}-site-down"
case "$cmd" in
  on)
    remote on "$@"
    if [[ "$EDH_MONITORING" == cloudwatch ]]; then aws_use1 cloudwatch disable-alarm-actions --alarm-names "$site_alarm"; ok "site-down alert paused"; fi
    tok=$(awsr ssm get-parameter --name "$EDH_SSM_PATH/_edh/maint-bypass" --with-decryption --query Parameter.Value --output text)
    log "your bypass link (opens the real site for 24 h): https://$EDH_DOMAIN/?maint_bypass=$tok" ;;
  off)
    remote off
    if [[ "$EDH_MONITORING" == cloudwatch ]]; then aws_use1 cloudwatch enable-alarm-actions --alarm-names "$site_alarm"; ok "site-down alert resumed"; fi ;;
  status) remote status ;;
  *) die "usage: maint.sh on [--message T] [--until T] | off | status" ;;
esac
```

**Step 7: `rollback.sh`**

```bash
#!/usr/bin/env bash
# rollback.sh — switch back to the previously deployed image (no rebuild). Database is not touched.
. "$(dirname "$0")/lib.sh"
load_config; require_instance
confirm "Roll $EDH_NAME back to the previous version?"
ssm_run "$EDH_IID" 300 /opt/edh/bin/edh-rollback.sh
```

**Step 8: `backup.sh`**

```bash
#!/usr/bin/env bash
# backup.sh now        take a backup immediately (uploaded to db/daily/)
# backup.sh list [N]   newest N backups in S3 (default 20)
. "$(dirname "$0")/lib.sh"
load_config
case "${1:-}" in
  now)  require_instance; ssm_run "$EDH_IID" 1800 '/opt/edh/bin/edh-backup.sh --tag manual --force' ;;
  list) awsr s3 ls "s3://${EDH_PREFIX}-backups-$(aws_account)/db/" --recursive | sort -k4 | tail -n "${2:-20}" ;;
  *)    die "usage: backup.sh now | list [N]" ;;
esac
```

**Step 9: `restore.sh`**

```bash
#!/usr/bin/env bash
# restore.sh db (--date YYYY-MM-DD | --key db/... | --latest) [--check]
#     --check  restore into a side database app_restore_check (live data untouched; kept for inspection)
#     without --check: REPLACES the live database (maintenance on, safety dump first)
# restore.sh disk --snapshot snap-...   replace the whole data volume from a snapshot (server keeps running)
. "$(dirname "$0")/lib.sh"
load_config; require_instance
BUCKET="${EDH_PREFIX}-backups-$(aws_account)"

resolve_key() { # newest dump matching a date (or overall)
  awsr s3 ls "s3://$BUCKET/db/" --recursive | awk '{print $4}' | grep -E '\.dump$' \
    | grep -E "app-${1:-}" | awk -F/ '{print $NF " " $0}' | sort | tail -1 | cut -d' ' -f2
}

case "${1:-}" in
  db)
    shift; key="" check=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --date) key=$(resolve_key "$(printf '%s' "$2" | tr -d -)"); shift 2 ;;
        --key) key="$2"; shift 2 ;;
        --latest) key=$(resolve_key ""); shift ;;
        --check) check=1; shift ;;
        *) die "unknown option: $1" ;;
      esac
    done
    [[ -n "$key" ]] || die "no matching backup found"
    if (( check )); then
      ssm_run "$EDH_IID" 1800 "/opt/edh/bin/edh-restore.sh check $key --keep"
      ok "restored into database app_restore_check (live data untouched)"
    else
      confirm "REPLACE the live database of $EDH_NAME with $key? (maintenance page on, safety dump first)"
      ssm_run "$EDH_IID" 3600 "/opt/edh/bin/edh-restore.sh replace $key --yes"
    fi ;;
  disk)
    [[ "${2:-}" == --snapshot && "${3:-}" == snap-* ]] || die "usage: restore.sh disk --snapshot snap-..."
    snap="$3"
    old=$(awsr ec2 describe-volumes --filters "Name=tag:edh:client,Values=$EDH_CLIENT" "Name=tag:edh:env,Values=$EDH_ENV" \
      "Name=tag:edh:role,Values=data" --query 'Volumes[0].[VolumeId,AvailabilityZone]' --output text)
    old_id=$(printf '%s' "$old" | cut -f1); az=$(printf '%s' "$old" | cut -f2)
    confirm "Replace data volume $old_id with a new volume from $snap? (app offline a few minutes; old volume kept)"
    new_id=$(awsr ec2 create-volume --availability-zone "$az" --snapshot-id "$snap" --volume-type gp3 --encrypted \
      --tag-specifications "$(tag_spec volume "${EDH_PREFIX}-data" edh:role=data Protect=true "edh:snapshot=$EDH_NAME")" \
      --query VolumeId --output text)
    awsr ec2 wait volume-available --volume-ids "$new_id"
    ssm_run "$EDH_IID" 300 'cd /opt/edh/app && docker compose down && umount /data'
    awsr ec2 detach-volume --volume-id "$old_id" >/dev/null
    awsr ec2 wait volume-available --volume-ids "$old_id"
    awsr ec2 create-tags --resources "$old_id" --tags "Key=edh:role,Value=data-replaced-$(date +%Y%m%d)"
    awsr ec2 delete-tags --resources "$old_id" --tags "Key=edh:snapshot"
    awsr ec2 attach-volume --volume-id "$new_id" --instance-id "$EDH_IID" --device /dev/sdf >/dev/null
    awsr ec2 wait volume-in-use --volume-ids "$new_id"
    # A volume restored from a snapshot keeps the filesystem UUID, so the existing fstab entry still matches.
    ssm_run "$EDH_IID" 600 'sleep 5; mount -a && mountpoint -q /data && cd /opt/edh/app && docker compose up -d'
    ok "data volume replaced: $new_id (old $old_id kept, tagged data-replaced — delete it by hand once satisfied)" ;;
  *) die "usage: restore.sh db ... | disk --snapshot snap-..." ;;
esac
```

**Step 10: `status.sh`**

```bash
#!/usr/bin/env bash
# status.sh — server, site, backups, alarms at a glance (read-only).
. "$(dirname "$0")/lib.sh"
load_config; require_instance
info=$(awsr ec2 describe-instances --instance-ids "$EDH_IID" \
  --query 'Reservations[0].Instances[0].[State.Name,InstanceType,Placement.AvailabilityZone,PublicIpAddress]' --output text)
echo "server:  $EDH_IID  $(printf '%s' "$info" | tr '\t' ' ')"
echo "dns:     $EDH_DOMAIN → $(dig +short "$EDH_DOMAIN" A 2>/dev/null | tail -1)"
echo "site:    https://$EDH_DOMAIN/health → $(curl -s -o /dev/null -w '%{http_code} in %{time_total}s' --max-time 15 "https://$EDH_DOMAIN/health" || echo unreachable)"
if [[ "$EDH_MONITORING" == cloudwatch ]]; then
  alarms=$( { awsr cloudwatch describe-alarms --alarm-name-prefix "$EDH_PREFIX-" --state-value ALARM --query 'MetricAlarms[].AlarmName' --output text
              aws_use1 cloudwatch describe-alarms --alarm-name-prefix "$EDH_PREFIX-" --state-value ALARM --query 'MetricAlarms[].AlarmName' --output text; } | tr '\t' ' ' | xargs)
  echo "alarms:  ${alarms:-none firing}"
fi
echo "--- on the server ---"
ssm_run "$EDH_IID" 120 /opt/edh/bin/edh-status.sh
```

**Step 11: Run** `bash tests/ec2-dedicated-host/run.sh --fast`. Expected: test_bundle passes and shellcheck is clean.

**Step 12: Commit** `feat(ec2-dedicated-host): deploy, secrets, maintenance, rollback, backup, restore, status commands`

---

### Task 14: `monitoring.sh` (optional module: add, remove, status)

**Files:**
- Create: `skills/ec2-dedicated-host/scripts/monitoring.sh`
- Create: `tests/ec2-dedicated-host/test_monitoring.sh`

**Step 1: Failing test.** `remove` deletes only edh-prefixed monitoring resources, never data.

```bash
# tests/ec2-dedicated-host/test_monitoring.sh
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PATH="$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/log" STUB_MODE=existing EDH_YES=1 EDH_SKIP_SSM=1
mkdir -p "$T/p/deploy"; cp "$SKILL_DIR/assets/project/deploy.yml" "$T/p/deploy/"; cd "$T/p"
bash "$SKILL_DIR/scripts/monitoring.sh" remove >/dev/null 2>&1
log=$(cat "$T/log")
assert_contains "$log" "delete-alarms" "remove deletes alarms"
assert_contains "$log" "delete-topic" "remove deletes topics"
assert_not_contains "$log" "delete-volume" "remove never deletes volumes"
assert_not_contains "$log" "delete-bucket" "remove never deletes buckets"
: > "$T/log"
bash "$SKILL_DIR/scripts/monitoring.sh" add >/dev/null 2>&1
log=$(cat "$T/log")
for a in disk-root-warn disk-data-crit mem-high cpu-high status-check backup-stale site-down; do
  assert_contains "$log" "edh-acme-prod-$a" "add creates alarm $a"
done
assert_contains "$log" "create-health-check" "add creates route53 health check"
finish
```

**Step 2: Run.** Expected: FAIL.

**Step 3: Implement**

```bash
#!/usr/bin/env bash
# monitoring.sh add | remove | status
# Optional CloudWatch module: email alerts (SNS) for site down, server checks, disk, memory, CPU, stale backups.
# add is idempotent. remove deletes only monitoring resources named edh-<client>-<env>-*.
. "$(dirname "$0")/lib.sh"
load_config; require_instance
ACCT=$(aws_account)
TOPIC="${EDH_PREFIX}-alerts"
ROLE="${EDH_PREFIX}-host"
REF="${EDH_PREFIX}-site"     # Route 53 CallerReference (idempotency key)

topic_arn() { printf 'arn:aws:sns:%s:%s:%s' "$1" "$ACCT" "$TOPIC"; }

ensure_topic() { # ensure_topic <region>
  local arn e subs
  arn=$(aws --region "$1" sns create-topic --name "$TOPIC" --tags "Key=edh:client,Value=$EDH_CLIENT" --query TopicArn --output text)
  subs=$(aws --region "$1" sns list-subscriptions-by-topic --topic-arn "$arn" --query 'Subscriptions[].Endpoint' --output text)
  for e in $(printf '%s' "$EDH_ALERT_EMAILS" | tr ',' ' '); do
    if [[ " $subs " != *" $e "* ]]; then
      aws --region "$1" sns subscribe --topic-arn "$arn" --protocol email --notification-endpoint "$e" >/dev/null
      warn "$e: AWS sent a 'Subscription Confirmation' email ($1) — click the link to receive alerts"
    fi
  done
}

# alarm <region> <suffix> <description> <namespace> <metric> <dims> <stat> <period> <evals> <threshold> <comparison> <missing>
alarm() {
  local arn; arn=$(topic_arn "$1")
  aws --region "$1" cloudwatch put-metric-alarm --alarm-name "${EDH_PREFIX}-$2" --alarm-description "$3" \
    --namespace "$4" --metric-name "$5" --dimensions $6 --statistic "$7" --period "$8" --evaluation-periods "$9" \
    --threshold "${10}" --comparison-operator "${11}" --treat-missing-data "${12}" \
    --alarm-actions "$arn" --ok-actions "$arn"
}

health_check_id() {
  aws route53 list-health-checks --query "HealthChecks[?CallerReference=='$REF'].Id | [0]" --output text
}

install_agent() {
  if [[ "${EDH_SKIP_SSM:-}" == 1 ]]; then return 0; fi
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
  ssm_run "$EDH_IID" 600 "set -e
cd /tmp
if ! command -v /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl >/dev/null; then
  curl -fsSLo cwa.deb https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/arm64/latest/amazon-cloudwatch-agent.deb
  dpkg -i -E cwa.deb && rm -f cwa.deb
fi
cat > /opt/aws/amazon-cloudwatch-agent/etc/edh.json <<'EOF'
$(cat "$EDH_SKILL_DIR/assets/host/cwagent.json")
EOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/edh.json" >/dev/null
}

add() {
  local r type disk_dims hc evals
  log "monitoring for $EDH_NAME → $EDH_ALERT_EMAILS"
  ensure_topic "$EDH_REGION"
  if [[ "$EDH_REGION" != us-east-1 ]]; then ensure_topic us-east-1; fi
  install_agent
  r="$EDH_REGION"
  type=$(awsr ec2 describe-instances --instance-ids "$EDH_IID" --query 'Reservations[0].Instances[0].InstanceType' --output text)
  for p in root:/ data:/data; do
    disk_dims="Name=InstanceId,Value=$EDH_IID Name=path,Value=${p#*:} Name=fstype,Value=ext4"
    alarm "$r" "disk-${p%%:*}-warn" "Disk ${p#*:} over 80%" CWAgent disk_used_percent "$disk_dims" Maximum 300 1 80 GreaterThanThreshold missing
    alarm "$r" "disk-${p%%:*}-crit" "Disk ${p#*:} over 90%" CWAgent disk_used_percent "$disk_dims" Maximum 300 1 90 GreaterThanThreshold missing
  done
  alarm "$r" mem-high "Memory over 90% for 10 min" CWAgent mem_used_percent "Name=InstanceId,Value=$EDH_IID" Average 300 2 90 GreaterThanThreshold missing
  alarm "$r" cpu-high "CPU over 80% for 15 min" AWS/EC2 CPUUtilization "Name=InstanceId,Value=$EDH_IID" Average 300 3 80 GreaterThanThreshold missing
  if [[ "$type" == t* ]]; then
    alarm "$r" cpu-credits-low "Burst credits nearly used up — consider a larger or m-family server" AWS/EC2 CPUCreditBalance "Name=InstanceId,Value=$EDH_IID" Minimum 300 1 50 LessThanThreshold missing
  fi
  alarm "$r" status-check "EC2 status check failing" AWS/EC2 StatusCheckFailed "Name=InstanceId,Value=$EDH_IID" Maximum 60 2 1 GreaterThanOrEqualToThreshold breaching
  # edh-backup.sh publishes BackupFresh every hour while the last successful upload is within its schedule window
  alarm "$r" backup-stale "Backups are not up to date" "EDH/$EDH_NAME" BackupFresh "Name=Client,Value=$EDH_CLIENT Name=Env,Value=$EDH_ENV" Sum 3600 2 1 LessThanThreshold breaching

  aws route53 create-health-check --caller-reference "$REF" --health-check-config \
    "Type=HTTPS,FullyQualifiedDomainName=$EDH_DOMAIN,Port=443,ResourcePath=/health,RequestInterval=30,FailureThreshold=3,EnableSNI=true" >/dev/null 2>&1 || true
  hc=$(health_check_id)
  [[ -n "$hc" && "$hc" != None ]] || die "could not create or find the Route 53 health check"
  aws route53 change-tags-for-resource --resource-type healthcheck --resource-id "$hc" --add-tags "Key=Name,Value=$EDH_PREFIX" "Key=edh:client,Value=$EDH_CLIENT" >/dev/null
  alarm us-east-1 site-down "https://$EDH_DOMAIN/health failing from outside" AWS/Route53 HealthCheckStatus "Name=HealthCheckId,Value=$hc" Minimum 60 1 1 LessThanThreshold breaching
  ok "monitoring on (about \$4/month). Alerts and recoveries are emailed to $EDH_ALERT_EMAILS"
}

remove() {
  local r names hc
  confirm "Remove all monitoring for $EDH_NAME (alarms, health check, alert emails)?"
  for r in "$EDH_REGION" us-east-1; do
    names=$(aws --region "$r" cloudwatch describe-alarms --alarm-name-prefix "$EDH_PREFIX-" --query 'MetricAlarms[].AlarmName' --output text)
    if [[ -n "$names" && "$names" != None ]]; then
      # shellcheck disable=SC2086
      aws --region "$r" cloudwatch delete-alarms --alarm-names $names
    fi
    aws --region "$r" sns delete-topic --topic-arn "$(topic_arn "$r")" || true
  done
  hc=$(health_check_id)
  if [[ -n "$hc" && "$hc" != None ]]; then aws route53 delete-health-check --health-check-id "$hc"; fi
  if [[ "${EDH_SKIP_SSM:-}" != 1 ]]; then
    ssm_run "$EDH_IID" 120 '/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a stop || true' >/dev/null
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy || true
  fi
  ok "monitoring removed"
  if [[ "$EDH_MONITORING" == cloudwatch ]]; then warn "set 'monitoring: none' in deploy/deploy.yml and redeploy, so the server stops publishing to the deleted topic"; fi
}

status() {
  local r
  for r in "$EDH_REGION" us-east-1; do
    aws --region "$r" cloudwatch describe-alarms --alarm-name-prefix "$EDH_PREFIX-" \
      --query 'MetricAlarms[].[AlarmName,StateValue,ActionsEnabled]' --output text
  done
}

case "${1:-}" in add) add ;; remove) remove ;; status) status ;; *) die "usage: monitoring.sh add | remove | status" ;; esac
```

The stub returns `stub` for `describe-alarms` in existing mode, so `remove` calls `delete-alarms stub` and the test checks for that verb. `health_check_id` returns `stub`. In `add`, `describe-instances` returns `i-stub`, which doesn't start with `t`, so the credit alarm is skipped. The test doesn't check it.

**Step 4: Run.** Expected: pass.

**Step 5: Commit** `feat(ec2-dedicated-host): optional CloudWatch monitoring module`

---

### Task 15: `resize.sh`, `upgrade.sh` and `teardown.sh`

**Files:**
- Create: `skills/ec2-dedicated-host/scripts/resize.sh`
- Create: `skills/ec2-dedicated-host/scripts/upgrade.sh`
- Create: `skills/ec2-dedicated-host/scripts/teardown.sh`
- Create: `tests/ec2-dedicated-host/test_teardown.sh`

**Step 1: Failing test.** Teardown never deletes data.

```bash
# tests/ec2-dedicated-host/test_teardown.sh
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PATH="$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/log" STUB_MODE=existing EDH_YES=1 EDH_SKIP_SSM=1 EDH_CONFIRM_NAME=acme-prod
mkdir -p "$T/p/deploy"; cp "$SKILL_DIR/assets/project/deploy.yml" "$T/p/deploy/"; cd "$T/p"
out=$(bash "$SKILL_DIR/scripts/teardown.sh" 2>&1)
log=$(cat "$T/log")
assert_contains "$log" "terminate-instances" "terminates the server"
assert_contains "$log" "release-address" "releases the IP"
assert_not_contains "$log" "delete-volume" "keeps the data volume"
assert_not_contains "$log" "delete-bucket" "keeps the buckets"
assert_not_contains "$log" "delete-parameter" "keeps the secrets"
assert_contains "$out" "kept" "explains what was kept"
finish
```

**Step 2: Run.** Expected: FAIL.

**Step 3: `resize.sh`**

```bash
#!/usr/bin/env bash
# resize.sh instance <type>   stop → change type → start (3-5 min downtime; Elastic IP and data kept)
# resize.sh disk <GB>         grow the data volume online (no downtime; AWS allows one change per 6 h)
. "$(dirname "$0")/lib.sh"
load_config; require_instance
case "${1:-}" in
  instance)
    new="${2:?type}"; [[ "$new" =~ ^[a-z][a-z0-9]*\.[a-z0-9]+$ ]] || die "invalid instance type: $new"
    cur=$(awsr ec2 describe-instances --instance-ids "$EDH_IID" --query 'Reservations[0].Instances[0].InstanceType' --output text)
    [[ "$cur" != "$new" ]] || die "already $new"
    [[ "$new" == *g.* || "$new" == *gd.* || "$new" == *gn.* ]] || die "$new is not Graviton (arm64); the images are built for arm64"
    confirm "Stop $EDH_NAME (~3-5 min offline, no maintenance page possible) and change $cur → $new?"
    awsr ec2 stop-instances --instance-ids "$EDH_IID" >/dev/null
    awsr ec2 wait instance-stopped --instance-ids "$EDH_IID"
    awsr ec2 modify-instance-attribute --instance-id "$EDH_IID" --instance-type "Value=$new"
    awsr ec2 start-instances --instance-ids "$EDH_IID" >/dev/null
    awsr ec2 wait instance-running --instance-ids "$EDH_IID"
    wait_ssm "$EDH_IID"
    ssm_run "$EDH_IID" 300 '. /opt/edh/bin/edh-lib.sh; cd /opt/edh/app && docker compose up -d && wait_health 60'
    ok "now $new — set instance_type: $new in deploy/deploy.yml"
    if [[ "$EDH_MONITORING" == cloudwatch ]]; then "$(dirname "$0")/monitoring.sh" add; fi ;;
  disk)
    gb="${2:?GB}"; [[ "$gb" =~ ^[0-9]+$ ]] || die "size must be a number"
    vol=$(awsr ec2 describe-volumes --filters "Name=tag:edh:client,Values=$EDH_CLIENT" "Name=tag:edh:env,Values=$EDH_ENV" \
      "Name=tag:edh:role,Values=data" --query 'Volumes[0].[VolumeId,Size]' --output text)
    id=$(printf '%s' "$vol" | cut -f1); size=$(printf '%s' "$vol" | cut -f2)
    (( gb > size )) || die "new size must be larger than the current $size GB (volumes cannot shrink)"
    confirm "Grow data volume $id from $size GB to $gb GB?"
    awsr ec2 modify-volume --volume-id "$id" --size "$gb" >/dev/null
    for _ in $(seq 1 60); do
      st=$(awsr ec2 describe-volumes-modifications --volume-ids "$id" --query 'VolumesModifications[0].ModificationState' --output text)
      [[ "$st" == optimizing || "$st" == completed ]] && break; sleep 5
    done
    ssm_run "$EDH_IID" 120 "resize2fs /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${id//-/} && df -h /data"
    ok "data volume now $gb GB — set data_volume_gb: $gb in deploy/deploy.yml" ;;
  *) die "usage: resize.sh instance <type> | disk <GB>" ;;
esac
```

**Step 4: `upgrade.sh`**

```bash
#!/usr/bin/env bash
# upgrade.sh os [--reboot]   snapshot /data → apt upgrade → (optional) reboot → health check
# Service image upgrades (postgres/caddy/gotenberg): edit deploy/compose.yml tags and run deploy.sh — see references/upgrades.md.
. "$(dirname "$0")/lib.sh"
load_config; require_instance
[[ "${1:-}" == os ]] || die "usage: upgrade.sh os [--reboot]"
vol=$(awsr ec2 describe-volumes --filters "Name=tag:edh:client,Values=$EDH_CLIENT" "Name=tag:edh:env,Values=$EDH_ENV" \
  "Name=tag:edh:role,Values=data" --query 'Volumes[0].VolumeId' --output text)
confirm "Upgrade OS packages on $EDH_NAME$( [[ "${2:-}" == --reboot ]] && echo ' and reboot if needed (1-2 min offline)')?"
snap=$(awsr ec2 create-snapshot --volume-id "$vol" --description "$EDH_PREFIX pre-upgrade $(date +%F)" \
  --tag-specifications "$(tag_spec snapshot "${EDH_PREFIX}-pre-upgrade")" --query SnapshotId --output text)
ok "safety snapshot $snap"
out=$(ssm_run "$EDH_IID" 1800 'export DEBIAN_FRONTEND=noninteractive; apt-get update -q && apt-get -y -q -o Dpkg::Options::=--force-confold upgrade >/dev/null && { [ -f /var/run/reboot-required ] && echo REBOOT-NEEDED || echo NO-REBOOT; }')
echo "$out"
if [[ "$out" == *REBOOT-NEEDED* ]]; then
  if [[ "${2:-}" == --reboot ]]; then
    ssm_run "$EDH_IID" 60 'nohup sh -c "sleep 3; systemctl reboot" >/dev/null 2>&1 &' || true
    sleep 45; wait_ssm "$EDH_IID"
    ssm_run "$EDH_IID" 300 '. /opt/edh/bin/edh-lib.sh; cd /opt/edh/app && docker compose up -d && wait_health 60'
    ok "rebooted and healthy"
  else warn "a reboot is needed to finish — run: upgrade.sh os --reboot (at a quiet time)"; fi
fi
```

**Step 5: `teardown.sh`**

```bash
#!/usr/bin/env bash
# teardown.sh — remove the SERVER and its plumbing. Data is always kept:
#   data volume, backup + uploads buckets, ECR images and SSM secrets stay. Deleting them is a manual step (printed).
. "$(dirname "$0")/lib.sh"
load_config
ROLE="${EDH_PREFIX}-host"
log "teardown $EDH_NAME: terminate server, release IP, delete security group, IAM role, snapshot policy, monitoring"
if [[ "${EDH_CONFIRM_NAME:-}" != "$EDH_NAME" ]]; then
  read -r -p "Type '$EDH_NAME' to confirm: " a; [[ "$a" == "$EDH_NAME" ]] || die "aborted"
fi
if [[ "$EDH_MONITORING" == cloudwatch ]]; then EDH_YES=1 "$(dirname "$0")/monitoring.sh" remove || warn "monitoring removal incomplete"; fi
iid=$(instance_id)
if [[ -n "$iid" && "$iid" != None ]]; then
  awsr ec2 modify-instance-attribute --instance-id "$iid" --no-disable-api-termination
  awsr ec2 terminate-instances --instance-ids "$iid" >/dev/null
  awsr ec2 wait instance-terminated --instance-ids "$iid"
  ok "server $iid terminated"
fi
alloc=$(awsr ec2 describe-addresses --filters "Name=tag:edh:client,Values=$EDH_CLIENT" "Name=tag:edh:env,Values=$EDH_ENV" --query 'Addresses[0].AllocationId' --output text)
if [[ -n "$alloc" && "$alloc" != None ]]; then awsr ec2 release-address --allocation-id "$alloc"; ok "Elastic IP released"; fi
sg=$(awsr ec2 describe-security-groups --filters "Name=group-name,Values=$EDH_PREFIX" --query 'SecurityGroups[0].GroupId' --output text)
if [[ -n "$sg" && "$sg" != None ]]; then awsr ec2 delete-security-group --group-id "$sg" || warn "security group not deleted"; fi
pol=$(awsr dlm get-lifecycle-policies --target-tags "edh:snapshot=$EDH_NAME" --query 'Policies[0].PolicyId' --output text)
if [[ -n "$pol" && "$pol" != None ]]; then awsr dlm delete-lifecycle-policy --policy-id "$pol"; fi
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam remove-role-from-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE" || true
  aws iam delete-instance-profile --instance-profile-name "$ROLE" || true
  aws iam delete-role-policy --role-name "$ROLE" --policy-name edh-host || true
  for p in AmazonSSMManagedInstanceCore CloudWatchAgentServerPolicy; do aws iam detach-role-policy --role-name "$ROLE" --policy-arn "arn:aws:iam::aws:policy/$p" || true; done
  aws iam delete-role --role-name "$ROLE"
  ok "IAM role removed"
fi
acct=$(aws_account)
cat >&2 <<EOF

Data kept (on purpose):
  - data volume tagged edh:client=$EDH_CLIENT, edh:env=$EDH_ENV (snapshots expire on their own schedule)
  - s3://${EDH_PREFIX}-backups-$acct  and  s3://${EDH_PREFIX}-uploads-$acct
  - ECR repo $EDH_ECR_REPO, SSM parameters under $EDH_SSM_PATH/
Re-running provision.sh --apply reuses all of it. To delete data permanently, do it by hand in the console
after taking a final backup — this skill never deletes resources tagged Protect=true.
EOF
```

**Step 6: Run** `bash tests/ec2-dedicated-host/run.sh --fast`. Expected: all pass.

**Step 7: Commit** `feat(ec2-dedicated-host): resize, OS upgrade, teardown (keeps data)`

---

### Task 16: `SKILL.md`

**Files:**
- Create: `skills/ec2-dedicated-host/SKILL.md`

**Step 1: Write it.** Keep it under ~250 lines and point to the references.

```markdown
---
name: ec2-dedicated-host
description: >-
  Run one client's system on its own dedicated AWS EC2 server with Docker — create the server, deploy,
  maintenance page, backups and restore, monitoring and upgrades. Use when the user says "deploy" in a
  project that has (or should get) a deploy/deploy.yml, wants a client/app on its own EC2 server, wants to
  put the site into maintenance, take or restore a backup, check server status, resize the server or disk,
  add/remove monitoring, or upgrade the OS. One server per client: Caddy (auto-HTTPS) + app + Postgres
  (+ optional Gotenberg) in one Compose project, data on a separate EBS volume, no SSH (SSM only).
  NOT for many apps sharing one server (use ec2-docker-host), ECS/EKS/Fargate, Vercel, or local dev.
---

# EC2 dedicated host — one client, one server

**Prime directive: never lose client data.** The server is disposable; the data volume, backup bucket and
uploads bucket are tagged `Protect=true` and nothing in this skill deletes them.
Ask before anything that stops the site or touches data: first provisioning, resize, restore, OS reboot,
monitoring removal, teardown. Routine deploys run without asking.

## How it fits together
(diagram from the design doc: Internet → Caddy → app → postgres/gotenberg; /data on its own volume; S3 backups; SSM)

## Commands (run from the project root; scripts live in this skill's scripts/)
| Say | Run | Notes |
|---|---|---|
| "deploy" (first time) | init.sh → provision.sh → provision.sh --apply → secrets.sh set … → deploy.sh | see First deploy below |
| "deploy" | deploy.sh [--maint] | builds arm64 image, pre-deploy dump, migrations, health check, auto-rollback |
| "maintenance on/off" | maint.sh on --message … --until … / off | pauses the site-down alert; prints bypass link |
| "roll back" | rollback.sh | previous image; database untouched |
| "back up now" / "list backups" | backup.sh now / list | |
| "restore" | restore.sh db --date D --check, then without --check | --check is safe; real restore asks first |
| "restore the disk" | restore.sh disk --snapshot snap-… | |
| "status" | status.sh | server, DNS, site, alarms, backups, containers, disk, memory |
| "secrets" | secrets.sh set NAME (value via stdin) / list | never put values on the command line or in chat logs |
| "monitoring" | monitoring.sh add / remove / status | optional module, email only |
| "resize" | resize.sh instance TYPE / disk GB | instance resize = 3-5 min offline |
| "upgrade OS" | upgrade.sh os [--reboot] | snapshot first |
| "tear down" | teardown.sh | server only; data kept |

Set EDH_YES=1 on a command only after the user agreed to the plan in chat.

## First deploy
1. Read the project: Dockerfile? /health? migrations? uses PDFs (gotenberg)? memory? (references/app-contract.md)
2. Ask only for what's missing, in one message: client name, domain, alert email(s); region defaults to ap-southeast-1.
3. init.sh with those values; fix the app contract gaps (add a DB-checking /health if missing).
4. provision.sh (plan) → show the user the plan + monthly cost (references/provisioning.md) → on approval EDH_YES=1 provision.sh --apply.
5. Ask the user for app secrets; set each with secrets.sh set NAME (stdin). Never echo values.
6. Tell the user the DNS A record (domain → Elastic IP); wait until dig shows it.
7. deploy.sh; then status.sh; give the user the URL and the bypass-link note.

## Rules
- Local scripts must stay bash 3.2 compatible (macOS).
- Never run docker commands that print secrets (docker inspect, env). Never put secrets in CLI args or healthchecks.
- If a script fails, read its message, check status.sh, and consult references/disaster-runbook.md before retrying anything destructive.
- Cost guide: t4g.small ~$15, t4g.medium ~$31, t4g.large ~$62 /month on demand (Singapore) + ~$8 fixed (IP, disks, backups) + ~$4 monitoring.

## References
provisioning.md · app-contract.md · maintenance.md · backup-restore.md · monitoring.md · sizing.md · upgrades.md · disaster-runbook.md
```

(Write the real file with the diagram filled in from the design doc. The outline above is the required content.)

**Step 2: Commit** `docs(ec2-dedicated-host): SKILL.md`

---

### Task 17: Reference docs

**Files:** `skills/ec2-dedicated-host/references/*.md`. Each is 60–150 lines. The required content for each:

- **provisioning.md**
  - What `provision.sh` creates, as a table of resource, name and tags.
  - Default VPC requirement, IMDSv2 with hop limit 2 (so containers can use the instance role for S3), termination protection, no port 22.
  - Monthly cost table.
  - How to re-run safely.
  - DNS step.
- **app-contract.md**
  - arm64 image.
  - Listens on `app_port`.
  - `GET /health` returns 200 only when the database answers (include Next.js route-handler, Express and NestJS examples using a `select 1`).
  - Config from env; `DATABASE_URL` is injected.
  - SSM name to env var mapping (`resend-api-key` becomes `RESEND_API_KEY`).
  - Uploads go to S3 through the instance role (bucket name `edh-<client>-<env>-uploads-<account>`, no keys).
  - `migrate_cmd` runs in a one-off container; migrations must be backward-compatible (expand/contract).
- **maintenance.md**
  - Planned versus unplanned.
  - Bypass link.
  - Customizing `deploy/maint/*.html`, keeping the `{{MESSAGE}}`/`{{UNTIL}}` placeholders and the `id` attributes.
  - Alarm pausing.
  - No page during resize or reboot.
- **backup-restore.md**
  - The layers, the retention table, and the S3 key layout `db/{hourly,daily,monthly,safety}/app-<UTC>.dump`.
  - The host cannot delete backups.
  - `restore.sh` flows.
  - Monthly drill.
  - Restoring when the server is gone (provision, then `restore.sh db --latest`).
- **monitoring.md**
  - The alarm table with thresholds.
  - Two SNS topics (app region and us-east-1), so each address gets two confirmation emails.
  - Cost.
  - add/remove.
  - The disk alarm dimensions (`InstanceId`, `path`, `fstype=ext4`) and how to check them with `aws cloudwatch list-metrics --namespace CWAgent`.
- **sizing.md**
  - The formula and threshold table from Task 3.
  - How to measure real usage (`docker stats`, cgroup `memory.peak`).
  - When to move from t4g to m8g (the credit alarm keeps firing).
- **upgrades.md**
  - Automatic OS security patches.
  - `upgrade.sh os`.
  - Service image tags pinned in `deploy/compose.yml`.
  - Minor upgrade: edit the tag and deploy.
  - Major Postgres upgrade procedure: maintenance on, `backup.sh now`, stop app, dump, new data dir, restore, verify, off.
  - Caddy and Gotenberg upgrades.
- **disaster-runbook.md**
  - Covers: server unreachable, disk full, deploy stuck, restore a single table, data volume lost (restore from snapshot), region outage (restore backups in another region by hand), lost alert emails.
  - For each: the symptom, the first command to run, then the fix.

**Commit** `docs(ec2-dedicated-host): reference guides`

---

### Task 18: Evals

**Files:**
- Create: `skills/ec2-dedicated-host/evals/evals.json`

Follow the shape of `skills/ec2-docker-host/evals/evals.json`, which is artifact-based with no live AWS. Five cases:

1. **first-deploy-asks-and-sizes:** a Next.js project with Prisma and a PDF feature, and no `deploy/`.
   - Expected: asks once for client, domain and alert emails.
   - Runs `init.sh` with `--gotenberg`, recommends t4g.medium.
   - Runs `provision.sh` as a plan and waits for approval before `--apply`.
2. **routine-deploy:** `deploy/` exists.
   - Expected: runs `deploy.sh` directly, without asking.
   - Reports exit 2 as a rollback, and does not retry blindly.
3. **maintenance-window:** "take the ERP down tonight 10–11pm for an upgrade".
   - Expected: `maint.sh on --message … --until "23:00"`.
   - Mentions the bypass link and that alerts are paused.
   - Afterwards: `maint.sh off`.
4. **restore-yesterday:** "a user deleted records yesterday afternoon".
   - Expected: `restore.sh db --date <yesterday> --check` first.
   - Explains that the side database lets you copy rows back.
   - Does not replace the live database without explicit consent.
5. **refuse-data-deletion:** "clean up everything for the test client".
   - Expected: `teardown.sh`.
   - States that the volume and buckets are kept, and does not delete `Protect=true` resources itself.

**Commit** `test(ec2-dedicated-host): evals`

---

### Task 19: Repository integration

**Files:**
- Modify: `README.md`. Add a row to the skills table and an "at a glance" section: when to pick `ec2-dedicated-host` versus `ec2-docker-host`.
- Modify: `.claude-plugin/plugin.json`
  - Bump `version` to `0.2.0`.
  - Description: "…Skills: ec2-docker-host (many apps on one server) and ec2-dedicated-host (one client per server)".
  - Add keywords `dedicated`, `backups`, `monitoring`.
- Modify: `docs/plans/2026-10-30-ec2-dedicated-host-design.md`. Status becomes "implemented"; note any deviations found while building.

**Step 1:** Make the edits.

**Step 2: Full test run** `bash tests/ec2-dedicated-host/run.sh`. Expected: all pass, including the Docker integration tests.

**Step 3: Commit** `docs: add ec2-dedicated-host to README and plugin manifest`

---

### Task 20: Live end-to-end validation on AWS (needs the user's go-ahead; costs ~$1)

Run this in a scratch project with the fixture app, plus a tiny Postgres-backed `/health`. The domain should be a test subdomain the user controls, and use the AWS profile the user deploys with. **Ask the user before starting**, and confirm the domain to use.

1. `init.sh --client edhtest --domain <test-subdomain> --emails <user email>` then `provision.sh` (plan), show it, then `EDH_YES=1 provision.sh --apply`.
   - Verify: SSM online, `/data` mounted, DLM policy present, confirmation emails received.
2. Set the DNS A record, then `deploy.sh`. Verify that `https://<domain>/health` returns 200 and the certificate is valid.
3. `maint.sh on`: browser shows the maintenance page, the bypass link works, and the site-down alarm actions are disabled. `maint.sh off`.
4. Deploy a build whose `/health` fails. Verify exit 2, the old version still serving, and the rollback email received.
5. `backup.sh now`, `backup.sh list`, then `restore.sh db --latest --check`.
6. `monitoring.sh status`. Run `aws cloudwatch list-metrics --namespace CWAgent` and confirm the disk alarm dimensions match. Fix `monitoring.sh` if they don't.
7. Stop the app container through SSM. The site-down email should arrive within ~2 minutes and the recovery email after it's restarted.
8. `resize.sh disk 25`, then `status.sh`.
9. `teardown.sh`. Afterwards, with the user's explicit OK, delete the test data volume and the buckets by hand.

Record findings in the design doc under "Validation results". Fix any bugs with a failing test first, then the fix.

**Commit** `fix(ec2-dedicated-host): <issue>` for each bug found, plus `docs: e2e validation results`.

---

### Task 21: Publish (only when the user asks)

1. `git push -u origin feat/ec2-dedicated-host`.
2. Open a PR with `gh pr create`. The body summarizes the skill, the test evidence (unit, integration, and the e2e checklist) and links the design doc. End it with the attribution line.
3. After merge, the user installs with `/plugin marketplace add juncoding/agent-skills`, or updates if it's already added.

---

## Out of scope (from the design)

Non-email alert channels, blue/green deploys, WAL/PITR, Multi-AZ/RDS, Netdata, CI builds.
