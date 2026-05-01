#!/usr/bin/env bash
# Local helper to deploy the F1 demo. Generates fresh secrets each run and
# stages them in /tmp so subsequent commands (kv writes, sql user creation)
# can re-use them without re-prompting.
set -eu

cd "$(dirname "$0")/.."

# Generate secrets that satisfy 4/4 complexity and avoid banned substrings.
# Avoid the literal '!' (zsh history expansion bites in interactive shells)
# and '$' (parameter expansion). Use only [A-Za-z0-9._-] plus enforced
# uppercase/lowercase/digit/special markers.
#
# We deliberately do NOT use `set -o pipefail` here: `tr ... | head -c N`
# closes the pipe early, killing tr with SIGPIPE (exit 141) and aborting the
# script. We use process substitution / dd instead.
gen_pwd() {
  local raw
  raw="$(LC_ALL=C dd if=/dev/urandom bs=1 count=512 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)"
  printf '%sAa1#' "$raw"
}

gen_hex() {
  local n="$1"
  LC_ALL=C dd if=/dev/urandom bs=1 count=$((n*2)) 2>/dev/null | LC_ALL=C od -vAn -tx1 | tr -d ' \n' | cut -c1-$n
}

SQL_MI_PWD="$(gen_pwd)"
VM_PWD="$(gen_pwd)"
FILEGEN_API_KEY="$(gen_hex 48)"
AAD_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv)"
AAD_LOGIN="$(az ad signed-in-user show --query userPrincipalName -o tsv)"

# Persist for re-use (chmod 600).
umask 077
mkdir -p /tmp/f1demo-secrets
printf '%s' "$SQL_MI_PWD"      > /tmp/f1demo-secrets/sqlpwd
printf '%s' "$VM_PWD"          > /tmp/f1demo-secrets/vmpwd
printf '%s' "$FILEGEN_API_KEY" > /tmp/f1demo-secrets/apikey
printf '%s' "$AAD_OBJECT_ID"   > /tmp/f1demo-secrets/aad-oid
printf '%s' "$AAD_LOGIN"       > /tmp/f1demo-secrets/aad-login

DEPLOY_NAME="f1demo-$(date +%Y%m%d-%H%M%S)"
printf '%s' "$DEPLOY_NAME" > /tmp/f1demo-secrets/deploy-name

echo "AAD_LOGIN=$AAD_LOGIN"
echo "AAD_OBJECT_ID=$AAD_OBJECT_ID"
echo "DEPLOY_NAME=$DEPLOY_NAME"
echo "Secrets staged under /tmp/f1demo-secrets/ (chmod 600)"
echo "---"
echo "Starting az deployment sub create..."

export SQL_MI_PWD VM_PWD FILEGEN_API_KEY AAD_OBJECT_ID AAD_LOGIN

az deployment sub create \
  --name "$DEPLOY_NAME" \
  --location centralus \
  --template-file infra/main.bicep \
  --parameters infra/parameters/dev.bicepparam \
  --no-prompt \
  --output json
RC=$?
echo "az exit code: $RC"
exit $RC
