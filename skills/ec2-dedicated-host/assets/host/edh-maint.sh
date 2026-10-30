#!/usr/bin/env bash
# edh-maint.sh on [--message TEXT] [--until TEXT] | off | status | render
# Planned maintenance: Caddy serves /data/maint/maintenance.html while /data/maint/ON exists.
# shellcheck source-path=SCRIPTDIR source=edh-lib.sh
. "${EDH_BIN_DIR:-/opt/edh/bin}/edh-lib.sh" || { echo "edh-maint: cannot load edh-lib.sh" >&2; exit 1; }

TPL="$EDH_APP_DIR/maint-templates/maintenance.html"
DIR="$EDH_DATA_DIR/maint"
OUT="$DIR/maintenance.html"
FLAG="$DIR/ON"

# render <message> <until> — fill the template; literal replacement, HTML-escaped.
# {{UNTIL}} goes first, so a message containing "{{UNTIL}}" stays literal.
# Written to a temp file in the same directory and moved over the page, so Caddy never serves half a file.
render() {
  local tmp
  [[ -f "$TPL" ]] || die "maintenance template not found: $TPL"
  [[ -d "$DIR" ]] || die "maintenance directory missing: $DIR"
  tmp=$(mktemp "$DIR/.maintenance.XXXXXX")
  if ! EDH_M="$(html_escape "$1")" EDH_U="$(html_escape "$2")" awk '
    function repl(s, from, to,   i, out) { out = ""; while ((i = index(s, from)) > 0) { out = out substr(s, 1, i - 1) to; s = substr(s, i + length(from)) } return out s }
    { $0 = repl($0, "{{UNTIL}}", ENVIRON["EDH_U"]); $0 = repl($0, "{{MESSAGE}}", ENVIRON["EDH_M"]); print }' "$TPL" > "$tmp"; then
    rm -f "$tmp"; die "could not render $TPL"
  fi
  chmod 644 "$tmp"
  mv -f "$tmp" "$OUT"
}

msg="We're carrying out scheduled maintenance to improve the service."; until_txt="shortly"
cmd="${1:-}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --message) [[ $# -ge 2 ]] || die "$1 needs a value"; msg="$2"; shift 2 ;;
    --until) [[ $# -ge 2 ]] || die "$1 needs a value"; until_txt="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
case "$cmd" in
  on)     render "$msg" "$until_txt"; touch "$FLAG"; echo "maintenance ON" ;;
  off)    rm -f "$FLAG"; echo "maintenance OFF" ;;
  status) if [[ -f "$FLAG" ]]; then echo on; else echo off; fi ;;
  render) render "$msg" "$until_txt" ;;
  *)      die "usage: edh-maint.sh on [--message T] [--until T] | off | status | render" ;;
esac
