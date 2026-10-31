#!/usr/bin/env bash
# release.sh vX.Y.Z [--maint] — release_flow: tags only. Fast-forward origin/<prod_branch> (the release branch) to
# the commit of tag vX.Y.Z, then deploy it (deploy.sh, which builds origin/<prod_branch> from a clean worktree).
# Refuses unless the tag is on origin and its commit is on origin/main (only reviewed code ships). Never moves the
# release branch backwards and never force-pushes: going back is rollback.sh (the previous image) or a new fix tag.
#   --maint  passed to deploy.sh (maintenance page during migrations)
# Exit: 0 released and live · 1 refused or failed (the message says whether origin/<prod_branch> moved).
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
TAG="" MAINT=""
for a in "$@"; do
  case "$a" in
    --maint) MAINT=--maint ;;
    -*) die "unknown option: $a" ;;
    *) [[ -z "$TAG" ]] || die "usage: release.sh vX.Y.Z [--maint]"; TAG="$a" ;;
  esac
done
load_config
oplog_begin release "$TAG"
[[ -n "$TAG" ]] || refuse "usage: release.sh vX.Y.Z [--maint]"
[[ "$TAG" =~ ^v[0-9][A-Za-z0-9._-]*$ ]] || refuse "the release must be a v* tag like v1.2.3, not '$TAG'"
[[ "$EDH_RELEASE_FLOW" == tags ]] \
  || refuse "release.sh needs release_flow: tags (and prod_branch: release) in deploy/deploy.yml; with release_flow: branch, deploy with deploy.sh"
require git
PB="$EDH_PROD_BRANCH"

# ref_sha <ls-remote output> <ref> — the sha of exactly <ref> (empty if absent)
ref_sha() { printf '%s\n' "$1" | awk -v r="$2" '$2 == r { print $1; exit }'; }

# never wait for a credential prompt: an agent can't answer it
refs=$(GIT_TERMINAL_PROMPT=0 git ls-remote origin refs/heads/main "refs/heads/$PB" "refs/tags/$TAG" "refs/tags/$TAG^{}") \
  || refuse "could not reach origin — check 'git remote -v', your network and your GitHub access"
COMMIT=$(ref_sha "$refs" "refs/tags/$TAG^{}")                      # an annotated tag, peeled to its commit
[[ -n "$COMMIT" ]] || COMMIT=$(ref_sha "$refs" "refs/tags/$TAG")    # a lightweight tag
[[ -n "$COMMIT" ]] || refuse "$TAG is not on origin — push it first: git push origin $TAG"
MAIN=$(ref_sha "$refs" refs/heads/main)
[[ -n "$MAIN" ]] || refuse "origin has no main branch"
REL=$(ref_sha "$refs" "refs/heads/$PB")
SHORT="${COMMIT:0:12}"
OPLOG_DETAIL="$TAG ($SHORT)"

# the objects, without touching local branches or tags
fetch=(refs/heads/main "refs/tags/$TAG")
if [[ -n "$REL" ]]; then fetch+=("refs/heads/$PB"); fi
GIT_TERMINAL_PROMPT=0 git fetch --quiet --no-tags origin "${fetch[@]}" || die "could not fetch from origin"
git cat-file -e "$COMMIT^{commit}" 2>/dev/null || die "$TAG does not point at a commit"

git merge-base --is-ancestor "$COMMIT" "$MAIN" \
  || refuse "$TAG ($SHORT) is not on origin/main — only reviewed code ships: merge it into main and tag a commit on main"
if [[ "$REL" == "$COMMIT" ]]; then
  log "origin/$PB is already at $TAG ($SHORT) — deploying it again"
elif [[ -n "$REL" ]] && git merge-base --is-ancestor "$COMMIT" "$REL"; then
  refuse "$TAG ($SHORT) is older than origin/$PB (${REL:0:12}): a release never moves backwards.
  To go back: rollback.sh (switches to the previous image), or fix forward with a new tag on main"
elif [[ -n "$REL" ]] && ! git merge-base --is-ancestor "$REL" "$COMMIT"; then
  refuse "moving origin/$PB (${REL:0:12}) to $TAG ($SHORT) is not a fast-forward: origin/$PB has commits $TAG doesn't contain.
  A release never force-pushes: get those commits into main, tag again and release that tag"
else
  log "release: origin/$PB ${REL:+${REL:0:12} }→ $TAG ($SHORT)"
  # a plain push: the server refuses anything but a fast-forward (or the creation of the branch)
  GIT_TERMINAL_PROMPT=0 git push --quiet origin "$COMMIT:refs/heads/$PB" \
    || die "could not push $TAG to origin/$PB (it did not move) — check your GitHub access and that $PB isn't protected against you"
  ok "origin/$PB is at $TAG"
fi

rc=0
EDH_OPLOG_SKIP=1 EDH_RELEASE_TAG="$TAG" EDH_RELEASE_COMMIT="$COMMIT" \
  bash "$(dirname "$0")/deploy.sh" ${MAINT:+"$MAINT"} || rc=$?
if (( rc != 0 )); then
  die "origin/$PB is at $TAG, but its deploy failed (see above) — fix and run deploy.sh to deploy origin/$PB again"
fi
ok "released $TAG"
