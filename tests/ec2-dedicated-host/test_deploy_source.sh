# tests/ec2-dedicated-host/test_deploy_source.sh — prod deploys must match origin/main (stub `aws`, never real AWS;
# a local bare repository stands in for GitHub)
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/s3"
# (`docker compose … config` runs for real: deploy.sh lints Compose's normalized config; it needs no daemon)
REAL_DOCKER=$(command -v docker)
# (the log path is fixed: deploy.sh runs `docker compose config` under env -i, without STUB_LOG)
printf '#!/bin/bash\necho "docker $*" >> "%s"\ncase "$1" in login) cat >/dev/null ;; esac\nif [[ "$1" == compose && " $* " == *" config "* ]]; then exec "%s" "$@"; fi\nexit 0\n' "$T/log.docker" "$REAL_DOCKER" > "$T/bin/docker"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/curl"
printf '#!/bin/sh\necho 203.0.113.10\n' > "$T/bin/dig"
chmod +x "$T/bin/"*
export PATH="$T/bin:$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/log" STUB_S3="$T/s3" STUB_MODE=existing EDH_SSM_POLL_SECONDS=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

git init -q --bare -b main "$T/origin.git"
mkdir "$T/p"; cd "$T/p" || exit 1
git init -q -b main .
bash "$SKILL_DIR/scripts/init.sh" --client acme --domain app.example.com --emails ops@example.com --account-id 123456789012 >/dev/null 2>&1
git add -A && git commit -qm init
git remote add origin "$T/origin.git"
git push -q origin main
# a second clone, to push commits the project doesn't have yet
git clone -q "$T/origin.git" "$T/other"

run() { : > "$T/log"; : > "$T/log.docker"; bash "$SKILL_DIR/scripts/deploy.sh" "$@" 2>&1; }
shipped() { printf '%s%s' "$(grep -c buildx "$T/log.docker")" "$(grep -c put-object "$T/log")"; }

# ============ equal to origin/main: deploys, naming the commit
out=$(run); rc=$?
assert_status $rc 0 "prod on main = origin/main: deploys"
assert_contains "$out" "deploying $(git rev-parse --short=12 HEAD) \"init\"" "prints the commit SHA and subject"
assert_eq "$(shipped)" "11" "prod on main = origin/main: built and shipped"

# ============ behind origin/main ("forgot to pull")
( cd "$T/other" && echo x > newer && git add newer && git commit -qm newer && git push -q origin main )
out=$(run); rc=$?
assert_status $rc 1 "behind origin/main: refused"
assert_contains "$out" "1 commit(s) behind origin/main" "behind: explained"
assert_contains "$out" "git pull" "behind: says to pull"
assert_contains "$out" "--allow-non-main" "behind: names the emergency override"
assert_eq "$(shipped)" "00" "behind: nothing built or shipped"
git pull -q --ff-only origin main

# ============ ahead of origin/main (unpushed commits)
echo y > local && git add local && git commit -qm "local only"
out=$(run); rc=$?
assert_status $rc 1 "ahead of origin/main: refused"
assert_contains "$out" "1 commit(s) that are not on origin/main" "ahead: explained"
assert_contains "$out" "push them through your usual review" "ahead: says to push (through review)"
assert_eq "$(shipped)" "00" "ahead: nothing built or shipped"
git push -q origin main
out=$(run); rc=$?
assert_status $rc 0 "after pushing: deploys"

# ============ uncommitted changes in prod: --allow-dirty alone is not enough
echo dirty > scratch.txt
out=$(run --allow-dirty); rc=$?
assert_status $rc 1 "prod, dirty tree, --allow-dirty: refused"
assert_contains "$out" "uncommitted changes" "prod, dirty tree: explained"
assert_contains "$out" "--allow-non-main" "prod, dirty tree: names the emergency override"
assert_eq "$(shipped)" "00" "prod, dirty tree: nothing built or shipped"
out=$(run --allow-dirty --allow-non-main </dev/null); rc=$?
assert_status $rc 1 "prod, dirty tree, both flags, no consent: aborted"
assert_eq "$(shipped)" "00" "prod, dirty tree, no consent: nothing built or shipped"
out=$(EDH_YES=1 run --allow-dirty --allow-non-main); rc=$?
assert_status $rc 0 "prod, dirty tree, both flags, consent: deploys"
assert_contains "$out" "EMERGENCY" "prod, dirty tree: EMERGENCY warning"
assert_contains "$out" "with uncommitted changes" "prod, dirty tree: the warning says so"
rm -f scratch.txt

# ============ prod_branch: another branch name for prod
git checkout -q -b release && git push -q origin release
sed 's/^prod_branch: .*/prod_branch: release/' deploy/deploy.yml > "$T/pb.yml" && cp "$T/pb.yml" deploy/deploy.yml
git commit -qam "prod from release" && git push -q origin release
out=$(run); rc=$?
assert_status $rc 0 "prod_branch release: deploying release = origin/release succeeds"
git checkout -q -b feature-z
out=$(run); rc=$?
assert_status $rc 1 "prod_branch release: another branch is refused"
assert_contains "$out" "on branch 'feature-z', not release" "prod_branch release: explained with the branch name"
git checkout -q release
git remote set-url origin "$T/missing.git"
out=$(run); rc=$?
assert_contains "$out" "could not fetch release from origin" "prod_branch: the fetch failure names the branch"
git remote set-url origin "$T/origin.git"
git checkout -q main
sed 's/^prod_branch: .*/prod_branch: -x/' "$T/pb.yml" > deploy/deploy.yml
out=$(run --allow-dirty); rc=$?
assert_contains "$out" "prod_branch must be a git branch name" "an invalid prod_branch is refused"
git checkout -q -- deploy/deploy.yml

# ============ on another branch
git checkout -q -b hotfix-x
out=$(run); rc=$?
assert_status $rc 1 "on another branch: refused"
assert_contains "$out" "on branch 'hotfix-x', not main" "other branch: explained"
assert_contains "$out" "git checkout main" "other branch: says to check out main"
assert_eq "$(shipped)" "00" "other branch: nothing built or shipped"
echo z > fix && git add fix && git commit -qm "urgent fix"
sha=$(git rev-parse --short=12 HEAD)

# ============ --allow-non-main: an emergency deploy, warned, with consent
out=$(run --allow-non-main </dev/null); rc=$?
assert_status $rc 1 "--allow-non-main without consent: aborted"
assert_eq "$(shipped)" "00" "--allow-non-main without consent: nothing built or shipped"
out=$(EDH_YES=1 run --allow-non-main); rc=$?
assert_status $rc 0 "--allow-non-main with EDH_YES=1: deploys"
assert_contains "$out" "EMERGENCY" "--allow-non-main: prominent warning"
assert_contains "$out" "branch 'hotfix-x' at $sha" "--allow-non-main: warning names the branch and commit"
assert_contains "$out" "urgent fix" "--allow-non-main: warning names the commit subject"
assert_eq "$(shipped)" "11" "--allow-non-main: built and shipped"

# ============ detached HEAD counts as another branch
git checkout -q main && git checkout -q --detach HEAD
out=$(run); rc=$?
assert_status $rc 1 "detached HEAD: refused"
assert_contains "$out" "detached HEAD" "detached HEAD: explained"
git checkout -q main

# ============ origin cannot be fetched: refused (the override still works)
git remote set-url origin "$T/missing.git"
out=$(run); rc=$?
assert_status $rc 1 "origin unreachable: refused"
assert_contains "$out" "could not fetch main from origin" "origin unreachable: explained"
git remote set-url origin "$T/origin.git"

# ============ non-prod: no origin/main check
sed 's/^env: .*/env: staging/' deploy/deploy.yml > "$T/staging.yml" && cp "$T/staging.yml" deploy/deploy.yml
git commit -qam "staging env"
git checkout -q -b feature-y
git remote remove origin
out=$(run); rc=$?
assert_status $rc 0 "env staging on a feature branch without origin: deploys"
assert_not_contains "$out" "origin/main" "env staging: no origin/main check"
assert_contains "$out" "deploying $(git rev-parse --short=12 HEAD)" "env staging: still prints the commit"
finish
