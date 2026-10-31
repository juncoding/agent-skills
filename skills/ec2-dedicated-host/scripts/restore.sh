#!/usr/bin/env bash
# restore.sh db (--date YYYY-MM-DD | --key db/... | --latest) [--check] [--unverified]
#     --check       restore into a side database app_restore_check (live data untouched; kept for inspection)
#     without --check: REPLACES the live database (maintenance on, safety dump first)
#     The server restores only backups in its own backup manifest (/data/backups/manifest.tsv, written by its
#     backup job): that exact S3 version, checked against its sha256. A compromised app can add objects to the
#     bucket, but not to the manifest. --latest and --date are resolved from the manifest by the server.
#     --unverified  also restore a backup that is not in the manifest (warned and alerted). Needs --key: nothing
#                   unverified is ever chosen automatically (backup.sh list shows the keys). The key is still checked
#                   against its S3 upload time. Only for when the manifest is gone (it lives on the data volume, so
#                   normally it survives a rebuilt server) — see references/backup-restore.md.
# restore.sh disk --snapshot snap-... [--foreign-snapshot]
#     replace the whole data volume from a snapshot (app offline a few minutes). Only snapshots tagged
#     edh:client/edh:env of this project; --foreign-snapshot (with a confirmation) allows any other.
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config
oplog_begin restore "$*"   # refined below to "db check|replace <key>" / "disk <snapshot>"
require_account
ACCT=$(aws_account)
require_instance
BUCKET="${EDH_PREFIX}-backups-${ACCT}"

# pick_backup <YYYY-MM-DD or ""> [exact-key] — (--unverified --key only, called with an exact key) choose a
# dump by its S3 upload time (LastModified), never by the timestamp in its name: the server's role (and an app container using it) can upload any key under db/, e.g.
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

KEY_RE='^db/(hourly|daily|monthly|safety)/app-[0-9]{8}T[0-9]{6}Z\.dump$'

case "${1:-}" in
  db)
    shift; key="" date="" mode="" check=0 unv=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --date)
          [[ "${2:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--date needs YYYY-MM-DD"
          date="$2"; mode="${mode}d"; shift 2 ;;
        --key) [[ $# -ge 2 ]] || die "--key needs a value"; key="$2"; mode="${mode}k"; shift 2 ;;
        --latest) mode="${mode}l"; shift ;;
        --check) check=1; shift ;;
        --unverified) unv=" --unverified"; shift ;;
        *) die "unknown option: $1" ;;
      esac
    done
    [[ ${#mode} == 1 ]] || die "give exactly one of --date, --key or --latest"
    # an unverified backup is never chosen automatically: the operator names the exact key
    if [[ -n "$unv" && "$mode" != k ]]; then
      die "--unverified needs --key db/<tier>/app-YYYYMMDDTHHMMSSZ.dump (not --latest or --date): name the exact backup (backup.sh list shows them) — see references/backup-restore.md"
    fi
    # the key goes into the remote command: only a well-formed dump key is accepted
    if [[ -n "$key" && ! "$key" =~ $KEY_RE ]]; then
      die "not a backup key: '$key' (expected db/<hourly|daily|monthly|safety>/app-YYYYMMDDTHHMMSSZ.dump)"
    fi
    if [[ -n "$unv" ]]; then
      # not verified by the server: the named key must exist, with the timestamp sanity checks on its upload time
      require_python
      sel=$(pick_backup "" "$key")
      [[ -n "$sel" ]] || die "backup $key not found in s3://$BUCKET (or skipped: see above)"
      key=$(printf '%s' "$sel" | cut -f1)
      [[ "$key" =~ $KEY_RE ]] || die "unexpected backup key: '$key'"
      log "backup $key — uploaded $(printf '%s' "$sel" | cut -f2), $(printf '%s' "$sel" | cut -f3) bytes (NOT verified against the server's backup manifest)"
    elif [[ -z "$key" ]]; then
      # --latest / --date: the server picks from its own backup manifest (by upload date)
      out=$(ssm_run "$EDH_IID" 120 "/opt/edh/bin/edh-restore.sh pick${date:+ $(printf '%s' "$date" | tr -d -)}") \
        || die "could not read the backup manifest on $EDH_IID"
      sel=$(printf '%s\n' "$out" | awk -F'\t' 'NF == 2 && $1 ~ /^db\// { l = $0 } END { print l }')
      [[ -n "$sel" ]] || die "no matching backup found in the server's backup manifest${date:+ for $date}"
      key=$(printf '%s' "$sel" | cut -f1)
      [[ "$key" =~ $KEY_RE ]] || die "unexpected backup key from the server: '$key'"
      log "backup $key — uploaded $(printf '%s' "$sel" | cut -f2) (from the server's backup manifest)"
    else
      log "backup $key (the server verifies it against its backup manifest)"
    fi
    OPLOG_DETAIL="db $( (( check )) && echo check || echo replace) $key${unv}"
    if (( check )); then
      # stdout is only the table count (for the drill); the server's log lines arrive on stderr
      ssm_run "$EDH_IID" 2400 "/opt/edh/bin/edh-restore.sh check $key --keep$unv" >/dev/null || die "restore check of $key failed (see the output above)"
      ok "restored $key into database app_restore_check (live data untouched)"
    else
      if [[ -n "$unv" ]]; then warn "--unverified: the server restores $key even if its own backup job did not make it"; fi
      confirm "REPLACE the live database of $EDH_NAME with $key$unv? (maintenance page on, safety dump first)"
      ssm_run "$EDH_IID" 3600 "/opt/edh/bin/edh-restore.sh replace $key --yes$unv" \
        || die "restore of $key failed — see the output above (the alert email says which database the app now uses)"
      ok "live database replaced with $key (previous data kept in database app_pre_restore)"
    fi ;;
  disk)
    [[ "${2:-}" == --snapshot && "${3:-}" =~ ^snap-[0-9a-f]+$ ]] || die "usage: restore.sh disk --snapshot snap-... [--foreign-snapshot]"
    snap="$3"; foreign=0; OPLOG_DETAIL="disk $snap"
    case "${4:-}" in "") ;; --foreign-snapshot) foreign=1 ;; *) die "unknown option: $4" ;; esac
    # only this project's snapshots (DLM copies the volume's tags; upgrade.sh tags its own)
    stags=$(awsr ec2 describe-snapshots --snapshot-ids "$snap" \
      --query 'Snapshots[0].[Tags[?Key==`edh:client`]|[0].Value,Tags[?Key==`edh:env`]|[0].Value]' --output text) \
      || die "cannot describe snapshot $snap"
    if [[ "$stags" != "$EDH_CLIENT"$'\t'"$EDH_ENV" ]]; then
      shown=$(printf '%s' "$stags" | tr '\t' ' ')
      if (( ! foreign )); then
        die "snapshot $snap is not tagged as $EDH_NAME's (edh:client/edh:env: $shown) — refusing. Pass --foreign-snapshot to use it anyway."
      fi
      warn "snapshot $snap is not tagged as $EDH_NAME's (edh:client/edh:env: $shown)"
      confirm "Use snapshot $snap, which is not tagged as $EDH_NAME's, for $EDH_NAME's data volume?"
    fi
    find_data_volume
    old_id="$EDH_VOL_ID"; az="$EDH_VOL_AZ"
    att=$(awsr ec2 describe-volumes --volume-ids "$old_id" --query 'Volumes[0].Attachments[0].InstanceId' --output text)
    [[ "$att" == "$EDH_IID" ]] || die "data volume $old_id is not attached to $EDH_IID (attached to: $att) — refusing"
    confirm "Replace data volume $old_id with a new volume from $snap? (app offline a few minutes; old volume kept)"
    # Tagged data-restoring until the swap is done: provision.sh refuses two volumes tagged edh:role=data.
    new_id=$(awsr ec2 create-volume --availability-zone "$az" --snapshot-id "$snap" --volume-type gp3 --encrypted \
      --tag-specifications "$(tag_spec volume "${EDH_PREFIX}-data" edh:role=data-restoring Protect=true)" \
      --query VolumeId --output text)
    [[ "$new_id" =~ ^vol-[0-9a-z]+$ ]] || die "could not create a volume from $snap"
    awsr ec2 wait volume-available --volume-ids "$new_id"

    # Docker has RequiresMountsFor=/data (bootstrap.sh), so unmounting /data would stop docker.service anyway —
    # and while docker.socket or the backup/drill timers are active, anything starting docker or edh-backup
    # would mount /data straight back. So: stop the timers, wait for any running edh operation (the edh lock, so
    # a backup in progress is not killed), stop the app and docker (with its socket), then unmount. The reverse
    # order brings it back.
    up_script="set -e
for _ in \$(seq 1 30); do [ -e /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_VOLID ] && break; sleep 2; done
mount -a || true
mountpoint -q /data || { echo '/data not mounted'; exit 1; }
systemctl start docker
cd /opt/edh/app && docker compose up -d
systemctl start edh-backup.timer edh-drill.timer
. /opt/edh/bin/edh-lib.sh
wait_health 60 || { echo 'the app does not pass /health'; exit 4; }"   # 4: everything is up but the app is unhealthy
    rc=0
    ssm_run "$EDH_IID" 900 'set -e
. /opt/edh/bin/edh-lib.sh
systemctl stop edh-backup.timer edh-drill.timer
edh_lock   # waits (up to 10 min) for a running backup, deploy or restore; held until this script ends
cd /opt/edh/app && docker compose down
systemctl stop docker.socket docker
umount /data' || rc=$?
    if (( rc )); then
      ssm_run "$EDH_IID" 600 "${up_script//VOLID/${old_id//-/}}" || true
      die "could not stop the app and unmount /data (exit $rc) — nothing was swapped; the old volume $old_id stays in use. The new volume $new_id (tagged data-restoring) is unused: delete it by hand."
    fi
    # from here on, any failure prints where both volumes are and how to put the old one back
    swap_recovery() {   # at_exit: runs on any exit; $EDH_RC is the exit code
      local rc="$EDH_RC"
      if (( rc == 0 )); then return 0; fi
      printf '\n\033[1;31mThe data volume swap stopped half way (exit %s).\033[0m\n' "$rc" >&2
      printf '  old data volume: %s\n  new volume:      %s\n  current state (id, state, attached to, edh:role):\n' "$old_id" "$new_id" >&2
      awsr ec2 describe-volumes --volume-ids "$old_id" "$new_id" \
        --query 'Volumes[].[VolumeId,State,Attachments[0].InstanceId,Tags[?Key==`edh:role`]|[0].Value]' --output text 2>&1 \
        | sed 's/^/    /' >&2 || true
      cat >&2 <<EOR
To put the old volume back (skip the steps that are already the case):
  aws --region $EDH_REGION ec2 detach-volume --volume-id $new_id
  aws --region $EDH_REGION ec2 create-tags --resources $new_id --tags Key=edh:role,Value=data-restoring
  aws --region $EDH_REGION ec2 delete-tags --resources $new_id --tags Key=edh:snapshot
  aws --region $EDH_REGION ec2 create-tags --resources $old_id --tags Key=edh:role,Value=data Key=edh:snapshot,Value=$EDH_NAME
  aws --region $EDH_REGION ec2 attach-volume --volume-id $old_id --instance-id $EDH_IID --device /dev/sdf
then on the server (Session Manager):
  sudo mount -a && sudo systemctl start docker && cd /opt/edh/app && sudo docker compose up -d && sudo systemctl start edh-backup.timer edh-drill.timer
EOR
    }
    at_exit swap_recovery
    awsr ec2 detach-volume --volume-id "$old_id" >/dev/null
    awsr ec2 wait volume-available --volume-ids "$old_id"
    awsr ec2 create-tags --resources "$old_id" --tags "Key=edh:role,Value=data-replaced-$(date +%Y%m%d)"
    awsr ec2 delete-tags --resources "$old_id" --tags "Key=edh:snapshot"
    awsr ec2 create-tags --resources "$new_id" --tags "Key=edh:role,Value=data" "Key=edh:snapshot,Value=$EDH_NAME"
    awsr ec2 attach-volume --volume-id "$new_id" --instance-id "$EDH_IID" --device /dev/sdf >/dev/null
    awsr ec2 wait volume-in-use --volume-ids "$new_id"
    # A volume restored from a snapshot keeps the filesystem UUID, so the existing fstab entry still matches.
    rc=0
    ssm_run "$EDH_IID" 600 "${up_script//VOLID/${new_id//-/}}" || rc=$?
    if (( rc == 4 )); then
      # the swap itself completed: the half-way recovery guidance would mislead
      at_exit ""
      die "the data volume swap completed ($new_id is attached and mounted at /data, the app was started), but the app is unhealthy — run status.sh and check the app's logs. The old volume $old_id is detached and kept (tagged data-replaced)."
    fi
    (( rc == 0 )) || die "bringing the server back on the new data volume $new_id failed (exit $rc) — see the output above"
    at_exit ""
    ok "data volume replaced: $new_id (old $old_id kept, tagged data-replaced — delete it by hand once satisfied)" ;;
  *) die "usage: restore.sh db (--date YYYY-MM-DD | --key db/... | --latest) [--check] [--unverified] | disk --snapshot snap-... [--foreign-snapshot]" ;;
esac
