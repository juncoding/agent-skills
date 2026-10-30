#!/usr/bin/env bash
# secrets.sh set <name>      read the value from stdin (not echoed) → SSM SecureString <path>/<name>
# secrets.sh list            names only
# secrets.sh delete <name>
# <name>: lowercase-with-dashes; becomes NAME_WITH_UNDERSCORES in the app's environment. Redeploy to apply.
# Values never appear on a command line: they go to AWS through a 0600 temp file (--value file://).
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config
cmd="${1:-}"
case "$cmd" in set|delete) require_account ;; esac   # list is read-only

# check_name <name> — also keeps the reserved _edh/ parameters out of reach
check_name() {
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "name must be lowercase letters/digits/dashes (got '${1:-}')"
}

case "$cmd" in
  set)
    check_name "${2:-}"
    v=""
    if [[ -t 0 ]]; then IFS= read -r -s -p "value for $2: " v || true; echo >&2; else v=$(cat); fi
    [[ -n "$v" ]] || die "empty value"
    # the server refuses values with a newline or tab when it writes app.env: refuse them here already
    case "$v" in *$'\n'*|*$'\r'*|*$'\t'*) die "the value must not contain a newline or tab" ;; esac
    WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
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
