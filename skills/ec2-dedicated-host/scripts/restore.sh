#!/usr/bin/env bash
# restore.sh db (--date YYYY-MM-DD | --key db/... | --latest) [--check]
#     --check  restore into a side database app_restore_check (live data untouched; kept for inspection)
#     without --check: REPLACES the live database (maintenance on, safety dump first)
# restore.sh disk --snapshot snap-...   replace the whole data volume from a snapshot (app offline a few minutes)
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config
require_account
ACCT=$(aws_account)
require_instance
BUCKET="${EDH_PREFIX}-backups-${ACCT}"

# pick_backup <YYYY-MM-DD or ""> [exact-key] — choose a dump by its S3 upload time (LastModified), never by the
# timestamp in its name: the server's role (and an app container using it) can upload any key under db/, e.g.
# db/daily/app-29991231T000000Z.dump, which would win any sort by name. Skipped, with a warning naming them:
# names dated more than 5 min in the future, and names more than 2 h from their upload time (uploads follow the
# dump within minutes). The date filter applies to the upload date. Prints "key<TAB>LastModified<TAB>size".
PICK_PY='import datetime as dt, re, sys
want, exact = sys.argv[1], sys.argv[2]
utc = dt.timezone.utc
now = dt.datetime.now(utc)
pat = re.compile(r"^db/(hourly|daily|monthly|safety)/app-([0-9]{8}T[0-9]{6}Z)[.]dump$")
def skip(key, why):
    sys.stderr.write("\033[1;33m  !\033[0m skipping %s: %s\n" % (key, why))
def uploaded(s):
    m = re.match(r"^([0-9-]{10}T[0-9:]{8})(?:[.][0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?$", s)
    t = dt.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=utc)
    z = m.group(2) or "Z"
    if z != "Z":
        t -= (1 if z[0] == "+" else -1) * dt.timedelta(hours=int(z[1:3]), minutes=int(z[-2:]))
    return t
best = None
for line in sys.stdin.read().splitlines():
    f = line.split("\t")
    if len(f) < 3 or (exact and f[0] != exact):
        continue
    key, lm_text, size = f[0], f[1], f[2]
    m = pat.match(key)
    if not m:
        continue
    try:
        named = dt.datetime.strptime(m.group(2), "%Y%m%dT%H%M%SZ").replace(tzinfo=utc)
        lm = uploaded(lm_text)
    except (ValueError, AttributeError):
        skip(key, "unreadable timestamp (name or upload time %s)" % lm_text); continue
    if named > now + dt.timedelta(minutes=5):
        skip(key, "its name is dated in the future"); continue
    if abs(named - lm) > dt.timedelta(hours=2):
        skip(key, "its name says %s but it was uploaded %s" % (named.strftime("%Y-%m-%d %H:%M"), lm.strftime("%Y-%m-%d %H:%M"))); continue
    if want and lm.strftime("%Y-%m-%d") != want:
        continue
    if best is None or lm > best[0]:
        best = (lm, key, lm_text, size)
if best:
    print("\t".join(best[1:]))'
pick_backup() {
  local rows
  rows=$(awsr s3api list-objects-v2 --bucket "$BUCKET" --prefix "${2:-db/}" --expected-bucket-owner "$ACCT" \
    --query 'Contents[].[Key,LastModified,Size]' --output text) || die "cannot list s3://$BUCKET/db/"
  printf '%s\n' "$rows" | python3 -I -c "$PICK_PY" "${1:-}" "${2:-}"
}

case "${1:-}" in
  db)
    shift; key="" date="" mode="" check=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --date)
          [[ "${2:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--date needs YYYY-MM-DD"
          date="$2"; mode="${mode}d"; shift 2 ;;
        --key) [[ $# -ge 2 ]] || die "--key needs a value"; key="$2"; mode="${mode}k"; shift 2 ;;
        --latest) mode="${mode}l"; shift ;;
        --check) check=1; shift ;;
        *) die "unknown option: $1" ;;
      esac
    done
    [[ ${#mode} == 1 ]] || die "give exactly one of --date, --key or --latest"
    # the key goes into the remote command: only a well-formed dump key is accepted
    if [[ -n "$key" && ! "$key" =~ ^db/(hourly|daily|monthly|safety)/app-[0-9]{8}T[0-9]{6}Z\.dump$ ]]; then
      die "not a backup key: '$key' (expected db/<hourly|daily|monthly|safety>/app-YYYYMMDDTHHMMSSZ.dump)"
    fi
    sel=$(pick_backup "$date" "$key")
    [[ -n "$sel" ]] || die "no matching backup found${key:+ (or $key was skipped: see above)}"
    key=$(printf '%s' "$sel" | cut -f1)
    [[ "$key" =~ ^db/(hourly|daily|monthly|safety)/app-[0-9]{8}T[0-9]{6}Z\.dump$ ]] || die "unexpected backup key: '$key'"
    log "backup $key — uploaded $(printf '%s' "$sel" | cut -f2), $(printf '%s' "$sel" | cut -f3) bytes"
    if (( check )); then
      ssm_run "$EDH_IID" 2400 "/opt/edh/bin/edh-restore.sh check $key --keep" || die "restore check of $key failed (see the output above)"
      ok "restored $key into database app_restore_check (live data untouched)"
    else
      confirm "REPLACE the live database of $EDH_NAME with $key? (maintenance page on, safety dump first)"
      ssm_run "$EDH_IID" 3600 "/opt/edh/bin/edh-restore.sh replace $key --yes" \
        || die "restore of $key failed — see the output above (the alert email says which database the app now uses)"
      ok "live database replaced with $key (previous data kept in database app_pre_restore)"
    fi ;;
  disk)
    [[ "${2:-}" == --snapshot && "${3:-}" =~ ^snap-[0-9a-f]+$ ]] || die "usage: restore.sh disk --snapshot snap-..."
    snap="$3"
    old=$(awsr ec2 describe-volumes --filters "Name=tag:edh:client,Values=$EDH_CLIENT" "Name=tag:edh:env,Values=$EDH_ENV" \
      "Name=tag:edh:role,Values=data" --query 'Volumes[].[VolumeId,AvailabilityZone]' --output text) || die "cannot list volumes"
    old=$(printf '%s\n' "$old" | grep -v -e '^None$' -e '^$' || true)
    [[ -n "$old" ]] || die "no data volume tagged $EDH_NAME"
    [[ "$old" != *$'\n'* ]] || die "more than one data volume tagged $EDH_NAME: $(printf '%s' "$old" | cut -f1 | tr '\n' ' ')"
    old_id=$(printf '%s' "$old" | cut -f1); az=$(printf '%s' "$old" | cut -f2)
    att=$(awsr ec2 describe-volumes --volume-ids "$old_id" --query 'Volumes[0].Attachments[0].InstanceId' --output text)
    [[ "$att" == "$EDH_IID" ]] || die "data volume $old_id is not attached to $EDH_IID (attached to: $att) — refusing"
    confirm "Replace data volume $old_id with a new volume from $snap? (app offline a few minutes; old volume kept)"
    # Tagged data-restoring until the swap is done: provision.sh refuses two volumes tagged edh:role=data.
    new_id=$(awsr ec2 create-volume --availability-zone "$az" --snapshot-id "$snap" --volume-type gp3 --encrypted \
      --tag-specifications "$(tag_spec volume "${EDH_PREFIX}-data" edh:role=data-restoring Protect=true)" \
      --query VolumeId --output text)
    [[ -n "$new_id" && "$new_id" != None ]] || die "could not create a volume from $snap"
    awsr ec2 wait volume-available --volume-ids "$new_id"

    # Docker has RequiresMountsFor=/data (bootstrap.sh), so unmounting /data would stop docker.service anyway —
    # and while docker.socket or the backup/drill timers are active, anything starting docker or edh-backup
    # would mount /data straight back. So: stop the app, the timers and docker (with its socket) first, then
    # unmount. The same order in reverse brings it back.
    up_script="set -e
for _ in \$(seq 1 30); do [ -e /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_VOLID ] && break; sleep 2; done
mount -a && mountpoint -q /data
systemctl start docker
cd /opt/edh/app && docker compose up -d
systemctl start edh-backup.timer edh-drill.timer
. /opt/edh/bin/edh-lib.sh
wait_health 60 || { echo 'the app does not pass /health'; exit 1; }"
    rc=0
    ssm_run "$EDH_IID" 300 'set -e
cd /opt/edh/app && docker compose down
systemctl stop edh-backup.timer edh-drill.timer
systemctl stop docker.socket docker
umount /data' || rc=$?
    if (( rc )); then
      ssm_run "$EDH_IID" 600 "${up_script//VOLID/${old_id//-/}}" || true
      die "could not stop the app and unmount /data (exit $rc) — nothing was swapped; the old volume $old_id stays in use. The new volume $new_id (tagged data-restoring) is unused: delete it by hand."
    fi
    awsr ec2 detach-volume --volume-id "$old_id" >/dev/null
    awsr ec2 wait volume-available --volume-ids "$old_id"
    awsr ec2 create-tags --resources "$old_id" --tags "Key=edh:role,Value=data-replaced-$(date +%Y%m%d)"
    awsr ec2 delete-tags --resources "$old_id" --tags "Key=edh:snapshot"
    awsr ec2 create-tags --resources "$new_id" --tags "Key=edh:role,Value=data" "Key=edh:snapshot,Value=$EDH_NAME"
    awsr ec2 attach-volume --volume-id "$new_id" --instance-id "$EDH_IID" --device /dev/sdf >/dev/null
    awsr ec2 wait volume-in-use --volume-ids "$new_id"
    # A volume restored from a snapshot keeps the filesystem UUID, so the existing fstab entry still matches.
    ssm_run "$EDH_IID" 600 "${up_script//VOLID/${new_id//-/}}" \
      || die "the new data volume $new_id is attached but the app is not healthy — run status.sh. The old volume $old_id is detached and kept (tagged data-replaced)."
    ok "data volume replaced: $new_id (old $old_id kept, tagged data-replaced — delete it by hand once satisfied)" ;;
  *) die "usage: restore.sh db (--date YYYY-MM-DD | --key db/... | --latest) [--check] | disk --snapshot snap-..." ;;
esac
