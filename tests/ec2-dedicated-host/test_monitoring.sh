# tests/ec2-dedicated-host/test_monitoring.sh — monitoring.sh against the stub `aws` (never real AWS)
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PATH="$TESTS_DIR/stubs:$PATH" STUB_LOG="$T/log" STUB_MODE=existing EDH_YES=1 EDH_SKIP_SSM=1 EDH_SSM_POLL_SECONDS=0
mkdir -p "$T/p/deploy"; cp "$SKILL_DIR/assets/project/deploy.yml" "$T/p/deploy/"; cd "$T/p" || exit 1
mon() { bash "$SKILL_DIR/scripts/monitoring.sh" "$@" 2>&1; }

# ============ remove: only this client's monitoring resources, never data
# the agent is stopped only if it is installed (a server whose bootstrap failed, or monitoring never added, has none)
: > "$T/log"
EDH_SKIP_SSM=0 mon remove >/dev/null
stop=$(grep 'ssm send-command' "$T/log" | sed -n 's/.*echo \([A-Za-z0-9+/=]*\) | base64 -d.*/\1/p' | head -1 | base64 --decode)
assert_contains "$stop" '[ -x "$c" ]' "remove stops the CloudWatch agent only if it is installed"
out=$(EDH_TEARDOWN=1 mon remove); rc=$?
assert_status $rc 0 "remove during teardown succeeds"
assert_not_contains "$out" "redeploy" "remove during teardown: no 'redeploy' advice (the server is going away)"
out=$(mon remove)
assert_contains "$out" "redeploy" "remove on its own: says to set monitoring: none and redeploy"
mon remove >/dev/null
log=$(cat "$T/log")
assert_contains "$log" "delete-alarms" "remove deletes alarms"
assert_contains "$log" "delete-topic" "remove deletes topics"
assert_not_contains "$log" "delete-volume" "remove never deletes volumes"
assert_not_contains "$log" "delete-bucket" "remove never deletes buckets"
assert_contains "$log" "iam delete-role-policy --role-name edh-acme-prod-host --policy-name edh-cwagent" "remove deletes the agent's inline policy"
assert_not_contains "$log" "CloudWatchAgentServerPolicy" "remove never touches CloudWatchAgentServerPolicy"
assert_not_contains "$log" "alarm-name-prefix" "remove names its alarms exactly (a prefix also matches client acme-prod's alarms)"
bad=$(grep 'delete-alarms' "$T/log" | tr ' ' '\n' | grep '^edh-' | grep -vE '^edh-acme-prod-(disk-(root|data)-(warn|crit)|mem-high|cpu-high|cpu-credits-low|status-check|backup-stale|site-down)$' || true)
assert_eq "$bad" "" "remove deletes only the alarms monitoring.sh creates"
assert_contains "$(grep 'delete-alarms' "$T/log" | grep -- '--region us-east-1')" "edh-acme-prod-site-down" "remove deletes the us-east-1 site-down alarm"

# ============ add
: > "$T/log"
mon add >/dev/null
log=$(cat "$T/log")
for a in disk-root-warn disk-data-crit mem-high cpu-high status-check backup-stale site-down; do
  assert_contains "$log" "edh-acme-prod-$a" "add creates alarm $a"
done
assert_contains "$log" "create-health-check" "add creates route53 health check"
# the agent's permissions: an inline policy limited to namespace CWAgent — never the managed
# CloudWatchAgentServerPolicy, which allows PutMetricData in any namespace (a host could fake another
# client's BackupFresh heartbeat)
assert_not_contains "$log" "CloudWatchAgentServerPolicy" "add never attaches CloudWatchAgentServerPolicy"
assert_not_contains "$log" "attach-role-policy" "add attaches no managed policy"
assert_contains "$log" "iam put-role-policy --role-name edh-acme-prod-host --policy-name edh-cwagent --policy-document file://" \
  "add puts the edh-cwagent inline policy"
pol=$(bash -c ". '$SKILL_DIR/scripts/lib.sh'; load_config '$SKILL_DIR/assets/project/deploy.yml'; EDH_ACCOUNT=123456789012; render_aws cwagent-policy.json" 2>&1)
chk=$(printf '%s' "$pol" | python3 -I -c 'import json, sys
lst = lambda v: v if isinstance(v, list) else [v]
out = []
for s in json.load(sys.stdin)["Statement"]:
    out.append("%s:%s:%s:%s" % (s["Effect"], ",".join(sorted(lst(s["Action"]))), ",".join(lst(s["Resource"])),
                                json.dumps(s.get("Condition", {}), sort_keys=True)))
print(" | ".join(sorted(out)))' 2>&1)
assert_eq "$chk" 'Allow:cloudwatch:PutMetricData:*:{"StringEquals": {"cloudwatch:namespace": "CWAgent/acme-prod"}} | Allow:ec2:DescribeTags:*:{}' \
  "cwagent policy: PutMetricData only in namespace CWAgent/acme-prod, plus DescribeTags"
f=$(grep 'policy-name edh-cwagent' "$T/log" | grep -o 'file://[^ ]*' | sed 's#file://##')
[[ -n "$f" && ! -e "$f" ]] && pass "rendered cwagent policy temp file removed" || fail "cwagent policy temp file left: $f"
# backup alarm: BackupFresh heartbeat in the client's own namespace, whatever the backup schedule
b=$(grep 'put-metric-alarm' "$T/log" | grep 'edh-acme-prod-backup-stale')
for want in "--namespace EDH/acme-prod" "--metric-name BackupFresh" "--dimensions Name=Client,Value=acme Name=Env,Value=prod" \
            "--statistic Sum --period 3600 --evaluation-periods 2 --threshold 1 --comparison-operator LessThanThreshold" \
            "--treat-missing-data breaching"; do
  assert_contains "$b" "$want" "backup alarm: $want"
done
assert_contains "$(grep 'put-metric-alarm' "$T/log" | grep 'site-down')" "--region us-east-1" "site-down alarm lives in us-east-1"
# agent metrics live in a per-client namespace: in a shared CWAgent namespace one client's host could publish
# datapoints with another client's InstanceId and hide that client's disk/memory alarms
for a in disk-root-warn disk-root-crit disk-data-warn disk-data-crit mem-high; do
  assert_contains "$(grep 'put-metric-alarm' "$T/log" | grep "edh-acme-prod-$a ")" "--namespace CWAgent/acme-prod " "alarm $a in namespace CWAgent/acme-prod"
done
assert_eq "$(grep -cE 'namespace CWAgent( |$)' "$T/log")" "0" "no alarm uses the shared CWAgent namespace"
# t-family: credit alarm; any other family: no credit alarm, and a stale one is deleted
assert_contains "$(grep 'put-metric-alarm' "$T/log")" "edh-acme-prod-cpu-credits-low" "t4g server: CPU credit alarm"
: > "$T/log"
STUB_ITYPE=m7g.large mon add >/dev/null
assert_not_contains "$(grep 'put-metric-alarm' "$T/log")" "cpu-credits-low" "m7g server: no CPU credit alarm"
assert_contains "$(grep 'delete-alarms' "$T/log")" "edh-acme-prod-cpu-credits-low" "m7g server: a stale CPU credit alarm is deleted"
# the agent install over SSM carries no secrets
: > "$T/log"
EDH_SKIP_SSM='' mon add >/dev/null
s=$(sed -n 's/.*echo \([A-Za-z0-9+/=]*\) | base64 -d.*/\1/p' "$T/log.ssm-params" | base64 --decode)
assert_contains "$s" "amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s" "add installs and starts the CloudWatch agent"
assert_contains "$s" '"namespace": "CWAgent/acme-prod"' "agent config is shipped inline, with the client's namespace"
assert_not_contains "$s" "__NAME__" "agent config is rendered"
assert_contains "$s" '${aws:InstanceId}' "agent config keeps the agent's own \${aws:InstanceId} placeholder"
assert_not_contains "$s" "get-parameter" "agent install reads no secrets"

# ============ Route 53 health check: found by domain, path and this client's tags — never by caller reference,
# which Route 53 refuses to reuse even after the check is deleted
rm -f "$T/log.r53"*; : > "$T/log"
out=$(mon add); rc=$?
assert_status $rc 0 "add creates the health check"
assert_eq "$(cut -f2- "$T/log.r53")" "app.example.com	/health	acme	prod	ec2-dedicated-host" "health check: domain, /health, tagged edh:client, edh:env and ManagedBy"
hc=$(cut -f1 "$T/log.r53")
assert_contains "$(grep put-metric-alarm "$T/log" | grep site-down)" "Name=HealthCheckId,Value=$hc" "site-down alarm watches the health check"
: > "$T/log"
out=$(mon add); rc=$?
assert_eq "$(grep -c create-health-check "$T/log")" "0" "add again: the existing health check is reused"
mon remove >/dev/null
assert_eq "$(grep -c . "$T/log.r53")" "0" "remove deletes the health check"
: > "$T/log"
out=$(mon add); rc=$?
assert_status $rc 0 "add after remove succeeds (a new caller reference)"
assert_eq "$(grep -c . "$T/log.r53")" "1" "add after remove: one health check"
# another client's check for the same domain is neither reused nor deleted
printf 'hc-99\tapp.example.com\t/health\tother\tprod\n' >> "$T/log.r53"
: > "$T/log"
out=$(mon add); rc=$?
assert_eq "$(grep -c 'hc-99' "$T/log.r53")" "1" "another client's health check is left alone"
assert_not_contains "$(grep put-metric-alarm "$T/log" | grep site-down)" "hc-99" "another client's health check is not used"
# a check with this client's tags but not ManagedBy=ec2-dedicated-host (made by hand) is neither used nor deleted
printf 'hc-98\tapp.example.com\t/health\tacme\tprod\tNone\n' >> "$T/log.r53"
: > "$T/log"
out=$(mon add); rc=$?
assert_eq "$(grep -c 'hc-98' "$T/log.r53")" "1" "an unmanaged health check with this client's tags is left alone"
assert_not_contains "$(grep put-metric-alarm "$T/log" | grep site-down)" "hc-98" "an unmanaged health check is not used"
assert_not_contains "$(cat "$T/log")" "delete-health-check --health-check-id hc-98" "an unmanaged health check is not deleted"
# domain changed: this client's old check is replaced — the new one is created first, then the old one deleted
old_hc=$(awk -F'\t' '$4 == "acme" && $6 == "ec2-dedicated-host" { print $1 }' "$T/log.r53")
sed 's/^domain: .*/domain: new.example.com/' "$SKILL_DIR/assets/project/deploy.yml" > deploy/deploy.yml
: > "$T/log"
out=$(mon add); rc=$?
assert_status $rc 0 "domain change: add succeeds"
assert_contains "$out" "app.example.com" "domain change: says which check is replaced"
assert_contains "$(cat "$T/log")" "delete-health-check --health-check-id $old_hc" "domain change: the old check is deleted"
c=$(grep -n create-health-check "$T/log" | head -1 | cut -d: -f1); d=$(grep -n delete-health-check "$T/log" | head -1 | cut -d: -f1)
assert_eq "$(( c > 0 && c < d ))" "1" "domain change: the new check is created before the old one is deleted"
assert_eq "$(awk -F'\t' '$4 == "acme" && $6 == "ec2-dedicated-host" { print $2 }' "$T/log.r53")" "new.example.com" "domain change: one check, for the new domain"
cp "$SKILL_DIR/assets/project/deploy.yml" deploy/deploy.yml
# domain change with a failing create: the old check is kept
sed 's/^domain: .*/domain: other.example.com/' "$SKILL_DIR/assets/project/deploy.yml" > deploy/deploy.yml
: > "$T/log"
out=$(STUB_R53_FAIL=1 mon add); rc=$?
assert_status $rc 1 "domain change, create fails: add fails"
assert_eq "$(grep -c delete-health-check "$T/log")" "0" "domain change, create fails: the old check is not deleted"
cp "$SKILL_DIR/assets/project/deploy.yml" deploy/deploy.yml
# a failing create is not swallowed
rm -f "$T/log.r53"*
out=$(STUB_R53_FAIL=1 mon add); rc=$?
assert_status $rc 1 "a failing health check create fails add"
assert_contains "$out" "could not create the Route 53 health check" "a failing health check create: explained"

# ============ alert emails: unconfirmed subscriptions are reported, not subscribed again
: > "$T/log"
out=$(STUB_SNS_SUBS="email	ops@example.com	PendingConfirmation" mon add); rc=$?
assert_contains "$out" "ops@example.com has not confirmed" "a pending subscription is reported"
assert_eq "$(grep -c 'sns subscribe' "$T/log")" "0" "a pending subscription is not subscribed again"
: > "$T/log"
out=$(STUB_SNS_SUBS="email	ops@example.com	arn:aws:sns:ap-southeast-1:123456789012:edh-acme-prod-alerts:1234" mon add); rc=$?
assert_not_contains "$out" "has not confirmed" "a confirmed subscription is not reported"
assert_eq "$(grep -c 'sns subscribe' "$T/log")" "0" "a confirmed subscription is not subscribed again"
: > "$T/log"
out=$(mon add); rc=$?
assert_eq "$(grep -c 'sns subscribe' "$T/log")" "2" "a new address is subscribed (app region and us-east-1)"

# ============ subscriptions follow alert_emails: confirmed addresses no longer listed are unsubscribed (both
# regions), pending ones can't be (API) and are reported; other protocols are left alone
A=arn:aws:sns:ap-southeast-1:123456789012:edh-acme-prod-alerts
subs="email	ops@example.com	$A:keep
email	old@example.com	$A:old1
email	OPS@EXAMPLE.COM	$A:case
email	gone@example.com	PendingConfirmation
https	https://hooks.example.com/x	$A:hook"
: > "$T/log"
out=$(STUB_SNS_SUBS="$subs" mon add); rc=$?
assert_status $rc 0 "add with a removed address succeeds"
assert_eq "$(grep -c "sns unsubscribe --subscription-arn $A:old1" "$T/log")" "2" "a removed confirmed address is unsubscribed (app region and us-east-1)"
assert_contains "$(grep "sns unsubscribe" "$T/log" | grep -- '--region us-east-1')" "$A:old1" "unsubscribed in us-east-1 too"
assert_contains "$out" "old@example.com" "the unsubscribed address is reported"
assert_eq "$(grep -c "sns unsubscribe --subscription-arn $A:keep" "$T/log")" "0" "a listed address stays subscribed"
assert_eq "$(grep -c "sns unsubscribe --subscription-arn $A:case" "$T/log")" "0" "addresses compare case-insensitively"
assert_eq "$(grep -c "$A:hook" "$T/log")" "0" "non-email subscriptions are left alone"
assert_contains "$out" "gone@example.com" "a removed pending address is reported"
assert_contains "$out" "pending" "a removed pending address: reported as pending"
assert_contains "$out" "expire" "a removed pending address: will expire"
assert_eq "$(grep -c 'sns subscribe ' "$T/log")" "0" "nothing new to subscribe"

# ============ status is read-only; add/remove refuse another account
: > "$T/log"
out=$(STUB_READONLY=1 mon status); rc=$?
assert_status $rc 0 "status is read-only"
sed 's/^account_id: .*/account_id: "111111111111"/' "$SKILL_DIR/assets/project/deploy.yml" > deploy/deploy.yml
for c in add remove; do
  : > "$T/log"
  out=$(STUB_READONLY=1 mon $c); rc=$?
  assert_status $rc 1 "wrong account: monitoring.sh $c refuses"
  assert_contains "$out" "but deploy.yml says 111111111111" "wrong account: monitoring.sh $c explains"
  assert_eq "$(grep -v 'sts get-caller-identity' "$T/log" | grep -c .)" "0" "wrong account: monitoring.sh $c makes no AWS call besides sts"
done
finish
