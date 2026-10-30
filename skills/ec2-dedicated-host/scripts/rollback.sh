#!/usr/bin/env bash
# rollback.sh — switch back to the previously deployed image (no rebuild). Database is not touched.
# Running it again rolls forward. Exit: 0 rolled back · 1 not rolled back (the message says why).
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config
require_account
require_instance
confirm "Roll $EDH_NAME back to the previous version?"
rc=0
# edh-rollback.sh waits up to 10 min for the edh lock, then up to two health checks: allow for all of it
ssm_run "$EDH_IID" 1200 /opt/edh/bin/edh-rollback.sh || rc=$?
case $rc in
  0) ok "rolled back to the previous version (run rollback.sh again to roll forward)" ;;
  1) die "not rolled back: the previous version is unhealthy (or none is recorded) — stayed on the current version (see the output above)" ;;
  3) die "rollback failed and the site may be down: neither the previous nor the current version passes /health — run status.sh" ;;
  124) die "the rollback is still running on the server after the timeout — run status.sh to see how it ended" ;;
  *) die "rollback failed (exit $rc) — the site may be down; run status.sh" ;;
esac
