#!/usr/bin/env bash
# rollback.sh [--allow-incompatible] — switch back to the previously deployed image (no rebuild). Database is not
# touched. Running it again rolls forward. Refuses an image the rollback guard lists (a later --no-rollback
# deploy's migrations changed the schema it ran on); --allow-incompatible switches anyway, only after the
# database was restored to a schema that image runs on. Exit: 0 rolled back · 1 not rolled back (the message
# says why).
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
ALLOW=""
for a in "$@"; do
  case "$a" in --allow-incompatible) ALLOW=--allow-incompatible ;; *) die "usage: rollback.sh [--allow-incompatible]" ;; esac
done
load_config
oplog_begin rollback
require_account
require_instance
if [[ -n "$ALLOW" ]]; then
  OPLOG_DETAIL="--allow-incompatible"
  warn "--allow-incompatible switches to the previous image even if a later migration changed the schema it ran on."
  warn "Only do this after the database was restored to a schema that image runs on (restore.sh db)."
  confirm "Roll $EDH_NAME back to the previous version, ALTHOUGH it may not run on today's database schema?"
else
  confirm "Roll $EDH_NAME back to the previous version?"
fi
rc=0
# edh-rollback.sh waits up to 10 min for the edh lock, then up to two health checks: allow for all of it
ssm_run "$EDH_IID" 1200 "/opt/edh/bin/edh-rollback.sh${ALLOW:+ $ALLOW}" || rc=$?
case $rc in
  0) ok "rolled back to the previous version (run rollback.sh again to roll forward)" ;;
  1) die "not rolled back: the previous version is unhealthy (or none is recorded) — stayed on the current version (see the output above)" ;;
  4) die "not rolled back: the previous version can't run on today's database schema (the rollback guard, see the output above) — nothing changed. Fix forward with a new release; going back needs the database restored first (restore.sh db, ask the user), then rollback.sh --allow-incompatible" ;;
  3) die "rollback failed and the site may be down: neither the previous nor the current version passes /health — run status.sh" ;;
  124) die "the rollback is still running on the server after the timeout — run status.sh to see how it ended" ;;
  *) die "rollback failed (exit $rc) — the site may be down; run status.sh" ;;
esac
