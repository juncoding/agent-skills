# tests/ec2-dedicated-host/test_release.sh — release_flow: tags. release.sh fast-forwards the release branch to a
# v* tag that is on main, and deploy.sh builds exactly origin/<release branch> from a clean worktree, whatever the
# operator has checked out (stub `aws`, never real AWS; a local bare repository stands in for GitHub)
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/s3"
REAL_DOCKER=$(command -v docker)
# fake docker: logs every call; on `buildx build` it records the build context's marker file (what was built) and
# the GIT_SHA build arg. `compose … config` runs for real (deploy.sh lints Compose's normalized config).
cat > "$T/bin/docker" <<EOS
#!/bin/bash
echo "docker \$*" >> "$T/log.docker"
if [[ "\$1" == compose && " \$* " == *" config "* ]]; then exec "$REAL_DOCKER" "\$@"; fi
if [[ "\$1" == buildx ]]; then
  ctx="\${@: -1}"; cat "\$ctx/marker.txt" >> "$T/log.built" 2>/dev/null || echo "no marker" >> "$T/log.built"
fi
EOS
cat >> "$T/bin/docker" <<'EOS'
case "$1" in login) cat >/dev/null ;; esac
exit 0
EOS
printf '#!/bin/sh\nexit 0\n' > "$T/bin/curl"
printf '#!/bin/sh\necho 203.0.113.10\n' > "$T/bin/dig"
chmod +x "$T/bin/"*
export PATH="$T/bin:$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/log" STUB_S3="$T/s3" STUB_MODE=existing EDH_SSM_POLL_SECONDS=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

git init -q --bare -b main "$T/origin.git"
mkdir "$T/p"; cd "$T/p" || exit 1
git init -q -b main .
out=$(bash "$SKILL_DIR/scripts/init.sh" --client acme --domain app.example.com --emails ops@example.com \
  --account-id 123456789012 --release-flow tags 2>&1); rc=$?
assert_status $rc 0 "init --release-flow tags succeeds"
y=$(cat deploy/deploy.yml)
assert_contains "$y" "release_flow: tags" "init --release-flow tags: release_flow set"
assert_contains "$y" "prod_branch: release" "init --release-flow tags: prod_branch is release"
echo v1 > marker.txt
git add -A && git commit -qm "one"
git remote add origin "$T/origin.git"
git push -q origin main
git tag -a v1.0.0 -m "release one" && git push -q origin v1.0.0
SHA1=$(git rev-parse HEAD)
# a second clone, to push commits and tags the project doesn't have yet
git clone -q "$T/origin.git" "$T/other"

reset_logs() { : > "$T/log"; : > "$T/log.docker"; : > "$T/log.built"; }
release() { reset_logs; bash "$SKILL_DIR/scripts/release.sh" "$@" 2>&1; }
deploy() { reset_logs; bash "$SKILL_DIR/scripts/deploy.sh" "$@" 2>&1; }
origin_release() { git --git-dir="$T/origin.git" rev-parse -q --verify refs/heads/release || echo none; }
built() { cat "$T/log.built"; }
shipped() { printf '%s%s' "$(grep -c buildx "$T/log.docker")" "$(grep -c put-object "$T/log")"; }
# the release.env inside the config bundle the deploy uploaded
bundle_env() {
  local f; f=$(find "$T/s3" -name '*.tgz' -exec ls -t {} + | head -1)
  tar xzf "$f" -O ./release.env 2>/dev/null
}
oplog_tail() { tail -n 1 deploy/OPERATIONS.md; }

# ============ the first release creates origin/release and deploys that commit
out=$(release v1.0.0); rc=$?
assert_status $rc 0 "first release: ok"
assert_eq "$(origin_release)" "$SHA1" "first release: origin/release created at the tag's commit"
assert_eq "$(built)" "v1" "first release: built the tag's commit"
assert_contains "$(grep buildx "$T/log.docker")" "--build-arg GIT_SHA=$SHA1" "first release: GIT_SHA build arg is the full commit"
assert_contains "$(bundle_env)" "EDH_APP_VERSION=v1.0.0" "first release: release.env carries the version tag"
assert_contains "$(oplog_tail)" "release · ok · v1.0.0 (${SHA1:0:12})" "first release: one oplog line, release · ok"
assert_eq "$(grep -c ' · deploy · ' deploy/OPERATIONS.md)" "0" "release logs once (no separate deploy line)"
git checkout -q -- deploy/OPERATIONS.md

# ============ the build ignores the working copy: another branch, uncommitted edits
git checkout -q -b feature-a
echo "wip" > marker.txt; echo junk > scratch.txt
( cd "$T/other" && git pull -q && echo v2 > marker.txt && git commit -qam "two" && git push -q origin main \
  && git tag -a v1.1.0 -m "release two" && git push -q origin v1.1.0 )
SHA2=$(git --git-dir="$T/origin.git" rev-parse 'v1.1.0^{commit}')
out=$(release v1.1.0); rc=$?
assert_status $rc 0 "release from a dirty feature branch: ok"
assert_eq "$(origin_release)" "$SHA2" "release v1.1.0: origin/release fast-forwarded"
assert_eq "$(built)" "v2" "release from a dirty feature branch: built the release commit, not the working copy"
assert_eq "$(cat marker.txt)" "wip" "the working copy is untouched"
assert_eq "$(git symbolic-ref --short HEAD)" "feature-a" "still on the operator's branch"
assert_eq "$(git worktree list | wc -l | tr -d ' ')" "1" "the temporary worktree is removed"
assert_contains "$(bundle_env)" "EDH_APP_VERSION=v1.1.0" "release v1.1.0: version tag in release.env"

# ============ plain deploy.sh in release mode redeploys origin/release, naming its tag
out=$(deploy); rc=$?
assert_status $rc 0 "deploy.sh in release mode on a dirty feature branch: ok"
assert_eq "$(built)" "v2" "deploy.sh in release mode: builds origin/release"
assert_contains "$out" "v1.1.0" "deploy.sh in release mode: names the version"
assert_contains "$(bundle_env)" "EDH_APP_VERSION=v1.1.0" "deploy.sh in release mode: version from the tag at origin/release"
git checkout -q -- deploy/OPERATIONS.md

# ============ deploy.sh re-checks provenance: a commit pushed straight to origin/release doesn't deploy
( cd "$T/other" && git fetch -q origin && git checkout -q -B rogue origin/release && echo rogue > marker.txt \
  && git commit -qam rogue && git push -q origin rogue:release )
out=$(deploy); rc=$?
assert_status $rc 1 "release branch holding a commit not on main: deploy refused"
assert_contains "$out" "not on origin/main" "commit not on main: explained"
assert_eq "$(shipped)" "00" "commit not on main: nothing built or shipped"
( cd "$T/other" && git checkout -q main && git pull -q && echo v2b > marker.txt && git commit -qam untagged \
  && git push -q origin main && git push -q -f origin main:release )
out=$(deploy); rc=$?
assert_status $rc 1 "release branch at an untagged commit on main: deploy refused"
assert_contains "$out" "no v* tag on origin" "untagged commit: explained"
assert_eq "$(shipped)" "00" "untagged commit: nothing built or shipped"
( cd "$T/other" && git push -q -f origin "$SHA2:refs/heads/release" )   # (the test puts release back by hand)
git checkout -q -- deploy/OPERATIONS.md

# ============ refused: a tag that isn't on main
git stash -q -u
git checkout -q -b side "$SHA2" && echo side > marker.txt && git commit -qam side
git tag -a v9.0.0 -m side && git push -q origin v9.0.0
out=$(release v9.0.0); rc=$?
assert_status $rc 1 "tag not on main: refused"
assert_contains "$out" "not on origin/main" "tag not on main: explained"
assert_eq "$(origin_release)" "$SHA2" "tag not on main: origin/release unchanged"
assert_eq "$(shipped)" "00" "tag not on main: nothing built or shipped"
assert_contains "$(oplog_tail)" "release · refused" "tag not on main: oplog says refused"
git checkout -q -- deploy/OPERATIONS.md

# ============ refused: a tag that only exists locally
git tag -a v9.1.0 -m local
out=$(release v9.1.0); rc=$?
assert_status $rc 1 "tag not on origin: refused"
assert_contains "$out" "v9.1.0 is not on origin" "tag not on origin: explained"
git checkout -q -- deploy/OPERATIONS.md

# ============ refused: moving release backwards (an older tag)
out=$(release v1.0.0); rc=$?
assert_status $rc 1 "older tag: refused"
assert_contains "$out" "never moves backwards" "older tag: explained"
assert_contains "$out" "rollback.sh" "older tag: points at rollback.sh"
assert_eq "$(origin_release)" "$SHA2" "older tag: origin/release unchanged"
assert_eq "$(shipped)" "00" "older tag: nothing built or shipped"
git checkout -q -- deploy/OPERATIONS.md

# ============ refused: a non-fast-forward (release has a commit main's tag doesn't contain)
( cd "$T/other" && git fetch -q origin && git checkout -q -b release origin/release && echo hot > marker.txt \
  && git commit -qam hotfix && git push -q origin release && git checkout -q main && git pull -q \
  && echo v3 > marker.txt && git commit -qam three && git push -q origin main \
  && git tag -a v1.2.0 -m three && git push -q origin v1.2.0 )
before=$(origin_release)
out=$(release v1.2.0); rc=$?
assert_status $rc 1 "non-fast-forward: refused"
assert_contains "$out" "not a fast-forward" "non-fast-forward: explained"
assert_eq "$(origin_release)" "$before" "non-fast-forward: origin/release unchanged (never forced)"
git checkout -q -- deploy/OPERATIONS.md

# ============ releasing the tag release already points at: deploys it again
( cd "$T/other" && git push -q -f origin "$SHA2:refs/heads/release" )   # (the test resets the hotfix by hand)
out=$(release v1.1.0); rc=$?
assert_status $rc 0 "same tag again: ok"
assert_contains "$out" "already at v1.1.0" "same tag again: says release is already there"
assert_eq "$(built)" "v2" "same tag again: deploys it"
git checkout -q -- deploy/OPERATIONS.md

# ============ bad input
out=$(release); rc=$?
assert_status $rc 1 "no tag: refused"
assert_contains "$out" "usage" "no tag: usage"
out=$(release 'v1;rm -rf /'); rc=$?
assert_status $rc 1 "a tag with odd characters: refused"
out=$(release main); rc=$?
assert_status $rc 1 "a branch name instead of a v* tag: refused"

# ============ release.sh needs release_flow: tags
sed 's/^release_flow: .*/release_flow: branch/' deploy/deploy.yml > "$T/b.yml" && cp "$T/b.yml" deploy/deploy.yml
out=$(release v1.1.0); rc=$?
assert_status $rc 1 "release_flow branch: release.sh refused"
assert_contains "$out" "release_flow: tags" "release_flow branch: says how to turn it on"
git checkout -q -- deploy/deploy.yml

# ============ config: release_flow is validated, and tags needs a release branch other than main
sed 's/^release_flow: .*/release_flow: banana/' deploy/deploy.yml > "$T/x.yml"
out=$(bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$T/x.yml'" 2>&1)
assert_contains "$out" "release_flow must be branch or tags" "an invalid release_flow is refused"
sed 's/^prod_branch: .*/prod_branch: main/' deploy/deploy.yml > "$T/x.yml"
out=$(bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$T/x.yml'" 2>&1)
assert_contains "$out" "prod_branch must not be main" "release_flow tags with prod_branch main is refused"
grep -v '^release_flow:' deploy/deploy.yml > "$T/x.yml"
out=$(bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$T/x.yml'; echo \$EDH_RELEASE_FLOW" 2>&1)
assert_eq "$out" "branch" "release_flow defaults to branch (older deploy.yml files)"

# ============ the emergency override still builds the working copy, with a warning
git checkout -q side
out=$(EDH_YES=1 deploy --allow-non-main); rc=$?
assert_status $rc 0 "release mode --allow-non-main: deploys"
assert_contains "$out" "EMERGENCY" "release mode --allow-non-main: warned"
assert_eq "$(built)" "side" "release mode --allow-non-main: builds the working copy"
finish
