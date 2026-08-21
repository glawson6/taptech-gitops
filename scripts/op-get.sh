#!/usr/bin/env bash
# op-get.sh - fetch a single field from a 1Password item.
#
# Signature:
#   ./scripts/op-get.sh <item> <field> [vault]
#
# Vault resolution (first match wins):
#   1. positional `[vault]` argument
#   2. $OP_VAULT env var
#   3. hardcoded default `taptech-mgmt` (matches the ClusterSecretStore
#      in platform/external-secrets/stores/mgmt/clustersecretstore.yaml,
#      so scripts don't need to know which vault a secret lives in --
#      the same "mgmt vault" convention applies everywhere).
#
# Prints only the field value to stdout. Nothing else. Diagnostic messages
# go to stderr so shell substitution stays clean:
#
#   PW=$(./scripts/op-get.sh argocd password)
#
# Exits non-zero if the 1Password desktop app is locked, the item is
# missing, the field is missing, or the CLI isn't installed. On failure
# it prints a specific message to stderr; capture it with `2>&1` if you
# need to see it inside a subshell.
#
# Prereqs (one-time):
#   * `brew install 1password-cli` (installed as /opt/homebrew/bin/op).
#   * 1Password desktop app running, Settings -> Developer ->
#     "Integrate with 1Password CLI" enabled. Once on, `op` unlocks
#     silently whenever the desktop app is unlocked -- no password
#     prompt on every call.
#
# Examples:
#   ./scripts/op-get.sh argocd password
#   ./scripts/op-get.sh jenkins-admin username
#   ./scripts/op-get.sh some-personal-item password Personal
#   OP_VAULT=Personal ./scripts/op-get.sh some-personal-item password
set -euo pipefail

usage() {
  cat <<USAGE >&2
usage: op-get.sh <item> <field> [vault]

  <item>   1Password item title (e.g. argocd, jenkins-admin)
  <field>  field name to fetch (e.g. password, username, token)
  [vault]  vault name; default \$OP_VAULT or 'taptech-mgmt'

Prints the field value to stdout.
USAGE
  exit 2
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage

ITEM="$1"
FIELD="$2"
VAULT="${3:-${OP_VAULT:-taptech-mgmt}}"

command -v op >/dev/null 2>&1 || {
  echo "op-get.sh: 1Password CLI 'op' not found. Install with: brew install 1password-cli" >&2
  exit 3
}

# `op read` returns the raw value on stdout. Suppress its own errors and
# emit a friendlier one on failure so callers know exactly what to fix.
if ! VALUE=$(op read "op://${VAULT}/${ITEM}/${FIELD}" 2>/tmp/op-get.err); then
  ERR=$(cat /tmp/op-get.err 2>/dev/null || true)
  rm -f /tmp/op-get.err
  echo "op-get.sh: failed reading op://${VAULT}/${ITEM}/${FIELD}" >&2
  [ -n "$ERR" ] && echo "  underlying error: $ERR" >&2
  echo "  hints: is 1Password desktop unlocked? is CLI integration enabled?" >&2
  echo "         does the item exist in vault '${VAULT}'?" >&2
  exit 1
fi
rm -f /tmp/op-get.err

printf '%s' "$VALUE"
