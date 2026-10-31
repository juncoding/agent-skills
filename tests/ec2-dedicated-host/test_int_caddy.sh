# tests/ec2-dedicated-host/test_int_caddy.sh — Caddy maintenance/down/bypass behaviour, against real containers.
. "$(dirname "$0")/assert.sh"
T=$(mktemp -d); P=edhcaddytest
cleanup() { docker compose -p $P -f "$T/c.yml" down -v >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
# bail <message> [output] — fail, show the output, stop
bail() { fail "$1"; if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" | tail -30 | sed 's/^/    /'; fi; finish; }

out=$(docker build -q -t edh-fixture:good --build-arg HEALTHY=1 "$TESTS_DIR/fixtures/app" 2>&1) || bail "docker build failed" "$out"
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
out=$(docker compose -p $P -f "$T/c.yml" up -d 2>&1) || bail "docker compose up failed" "$out"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

# Wait (max 60 s) for Caddy to proxy to the app; stop early with the container logs if it never does.
ready=0
for _ in $(seq 1 60); do
  if [[ "$(curl -s localhost:18080/ 2>/dev/null)" == fixture-ok ]]; then ready=1; break; fi
  sleep 1
done
if (( ready == 0 )); then bail "stack did not come up within 60 s" "$(docker compose -p $P -f "$T/c.yml" logs 2>&1)"; fi

assert_eq "$(curl -s localhost:18080/)" "fixture-ok" "proxies to app normally"
assert_eq "$(code localhost:18080/cgi-bin/boom)" "500" "app's own 500 passes through"
out=$(curl -s localhost:18080/cgi-bin/boom)
assert_contains "$out" "app-error" "app's own 500 body passes through"
assert_not_contains "$out" 'id="edh-down"' "app's own 500 is not replaced by the down page"

# --- planned maintenance
touch "$T/maint/ON"
assert_eq "$(code localhost:18080/)" "503" "maintenance returns 503"
assert_contains "$(curl -s localhost:18080/)" 'id="edh-maintenance"' "maintenance page served"
hdr=$(curl -sI localhost:18080/)
assert_contains "$hdr" "Retry-After: 1800" "Retry-After header set"
assert_contains "$hdr" "Cache-Control: no-store" "maintenance page is not cached"
assert_eq "$(code -X POST localhost:18080/x)" "503" "POST during maintenance gets 503"
assert_contains "$(curl -s -X POST localhost:18080/x)" 'id="edh-maintenance"' "POST during maintenance gets the maintenance page"
assert_eq "$(code localhost:18080/health)" "200" "/health bypasses maintenance"

# --- bypass
assert_eq "$(curl -s -H 'Cookie: maint_bypass=tok123' localhost:18080/)" "fixture-ok" "bypass cookie reaches app"
assert_eq "$(curl -s -H 'Cookie: a=1; maint_bypass=tok123' localhost:18080/)" "fixture-ok" "bypass cookie among others reaches app"
assert_eq "$(code -H 'Cookie: maint_bypass=wrong' localhost:18080/)" "503" "wrong cookie still blocked"
assert_eq "$(code -H 'Cookie: x_maint_bypass=tok123' localhost:18080/)" "503" "cookie with a longer name is blocked"
assert_eq "$(code -H 'Cookie: maint_bypass=tok1234' localhost:18080/)" "503" "token with extra characters is blocked"
assert_eq "$(code -H 'Cookie: maint_bypass=' localhost:18080/)" "503" "empty token is blocked"
hdr=$(curl -sI 'localhost:18080/?maint_bypass=tok123')
assert_contains "$hdr" " 302" "bypass link redirects"
assert_contains "$hdr" "Set-Cookie: maint_bypass=tok123;" "bypass link sets cookie"
assert_contains "$hdr" "HttpOnly" "bypass cookie is HttpOnly"
assert_contains "$hdr" "Secure" "bypass cookie is Secure"

# --- app down
docker compose -p $P -f "$T/c.yml" stop app >/dev/null 2>&1
assert_eq "$(code localhost:18080/)" "503" "maintenance + app down returns 503"
out=$(curl -s localhost:18080/)
assert_contains "$out" 'id="edh-maintenance"' "maintenance + app down shows the maintenance page"
assert_not_contains "$out" 'id="edh-down"' "maintenance + app down does not show the down page"
rm "$T/maint/ON"
assert_eq "$(code localhost:18080/)" "503" "app down returns 503"
assert_contains "$(curl -s localhost:18080/)" 'id="edh-down"' "down page served when app is down"
hdr=$(curl -sI localhost:18080/)
assert_contains "$hdr" "Cache-Control: no-store" "down page is not cached"
assert_contains "$hdr" "Retry-After: 30" "down page sets Retry-After: 30"
finish
