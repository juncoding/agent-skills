#!/usr/bin/env bash
# edh-maint.sh on [--message TEXT] [--until TEXT] | off | status | render
# Planned maintenance: Caddy serves /data/maint/maintenance.html while /data/maint/ON exists.
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh"

TPL="$EDH_APP_DIR/maint-templates/maintenance.html"
OUT="$EDH_DATA_DIR/maint/maintenance.html"
FLAG="$EDH_DATA_DIR/maint/ON"

# render <message> <until> — fill the template; literal replacement, HTML-escaped
render() {
  local tmp; tmp=$(mktemp)
  EDH_M="$(html_escape "$1")" EDH_U="$(html_escape "$2")" awk '
    function repl(s, from, to,   i, out) { out = ""; while ((i = index(s, from)) > 0) { out = out substr(s, 1, i - 1) to; s = substr(s, i + length(from)) } return out s }
    { $0 = repl($0, "{{MESSAGE}}", ENVIRON["EDH_M"]); $0 = repl($0, "{{UNTIL}}", ENVIRON["EDH_U"]); print }' "$TPL" > "$tmp"
  install -m 644 "$tmp" "$OUT"
  rm -f "$tmp"
}

msg="We're carrying out scheduled maintenance to improve the service."; until="shortly"
cmd="${1:-}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --message) msg="$2"; shift 2 ;;
    --until) until="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
case "$cmd" in
  on)     render "$msg" "$until"; touch "$FLAG"; echo "maintenance ON" ;;
  off)    rm -f "$FLAG"; echo "maintenance OFF" ;;
  status) if [[ -f "$FLAG" ]]; then echo on; else echo off; fi ;;
  render) render "$msg" "$until" ;;
  *)      die "usage: edh-maint.sh on [--message T] [--until T] | off | status | render" ;;
esac
