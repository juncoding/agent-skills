#!/usr/bin/env bash
# secrets.sh set <name>      read the value from stdin (not echoed) → SSM SecureString <path>/<name>
# secrets.sh list            names only
# secrets.sh delete <name>
# <name>: lowercase-with-dashes; becomes NAME_WITH_UNDERSCORES in the app's environment. Redeploy to apply.
#   The NAME is stored and logged in plain text (deploy/OPERATIONS.md) — never pass a value as the name. A rejected
#   name is neither echoed nor logged (logged as "<invalid name>").
# Values never appear on a command line: they go to AWS through a 0600 temp file (--value file://).
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config
cmd="${1:-}"
# valid_name <name> — lowercase letters/digits/dashes; also keeps the reserved _edh/ parameters out of reach
valid_name() { [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; }
# check_name <name> — the name is checked BEFORE anything is logged, and a rejected one is never echoed: it might
# be a value pasted in the wrong place
check_name() {
  valid_name "${1:-}" || refuse "the name must be lowercase letters, digits and dashes (it is stored and logged in plain text — never pass a value as the name)"
}
case "$cmd" in
  set|delete)   # list is read-only; the log gets the NAME only
    if valid_name "${2:-}"; then oplog_begin secrets "$cmd $2"; else oplog_begin secrets "$cmd <invalid name>"; fi
    check_name "${2:-}"
    require_account ;;
esac

case "$cmd" in
  set)
    check_name "${2:-}"
    v=""
    if [[ -t 0 ]]; then IFS= read -r -s -p "value for $2: " v || true; echo >&2; else v=$(cat); fi
    [[ -n "$v" ]] || die "empty value"
    # the server refuses values with a newline or tab when it writes app.env: refuse them here already
    case "$v" in *$'\n'*|*$'\r'*|*$'\t'*) die "the value must not contain a newline or tab" ;; esac
    WORK=$(mktemp -d); at_exit 'rm -rf "$WORK"'
    ( umask 077; printf '%s' "$v" > "$WORK/value" )   # no trailing newline: the file content is the value
    awsr ssm put-parameter --name "$EDH_SSM_PATH/$2" --type SecureString --value "file://$WORK/value" --overwrite >/dev/null \
      || die "could not store $EDH_SSM_PATH/$2"
    rm -f "$WORK/value"
    ok "set $EDH_SSM_PATH/$2 (redeploy to apply)" ;;
  list)
    awsr ssm get-parameters-by-path --path "$EDH_SSM_PATH/" --recursive --query 'Parameters[].Name' --output text | tr '\t' '\n' ;;
  delete)
    check_name "${2:-}"
    confirm "Delete secret $EDH_SSM_PATH/$2?"
    awsr ssm delete-parameter --name "$EDH_SSM_PATH/$2"; ok "deleted (redeploy to apply)" ;;
  *) die "usage: secrets.sh set <name> | list | delete <name>" ;;
esac
