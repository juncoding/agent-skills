# tests/ec2-dedicated-host/test_int_caddy.sh — Caddy maintenance/down/bypass behaviour, against real containers.
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); P=edhcaddytest
cleanup() { docker compose -p $P -f "$T/c.yml" down -v >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
docker build -q -t edh-fixture:good --build-arg HEALTHY=1 "$TESTS_DIR/fixtures/app" >/dev/null
mkdir -p "$T/caddy" "$T/maint"
cp "$SKILL_DIR/assets/project/Caddyfile" "$T/caddy/Caddyfile"
cp "$SKILL_DIR/assets/project/maint/"*.html "$T/maint/"
cat > "$T/c.yml" <<EOC
services:
  caddy:
    image: caddy:2.10-alpine
    environment: { DOMAIN: ":80", MAINT_BYPASS: "tok123", APP_PORT: "3000" }
    ports: ["18080:80"]
    volumes: ["$T/caddy:/etc/caddy:ro", "$T/maint:/srv/maint:ro"]
  app:
    image: edh-fixture:good
EOC
docker compose -p $P -f "$T/c.yml" down -v >/dev/null 2>&1   # leftovers from an interrupted run
docker compose -p $P -f "$T/c.yml" up -d >/dev/null 2>&1
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

# Wait (max 60 s) for Caddy to proxy to the app; stop early with the container logs if it never does.
ready=0
for _ in $(seq 1 60); do
  if [[ "$(curl -s localhost:18080/ 2>/dev/null)" == fixture-ok ]]; then ready=1; break; fi
  sleep 1
done
if (( ready == 0 )); then
  fail "stack did not come up within 60 s"
  docker compose -p $P -f "$T/c.yml" logs --tail 30 2>&1 | sed 's/^/    /'
  finish
fi

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
