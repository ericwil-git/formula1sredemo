#!/usr/bin/env bash
# Local helper to deploy the F1 demo. Generates fresh secrets each run and
# stages them in /tmp/f1demo-secrets/ so follow-up steps (KV reads, SQL user
# creation, etc.) can re-use them.
set -eu

cd "$(dirname "$0")/.."

# Generate passwords that satisfy 4/4 complexity rules and avoid characters
# that misbehave in interactive zsh ('!' history expansion, '$' parameter
# expansion). We deliberately do NOT use `set -o pipefail` here: `tr | head`
# patterns SIGPIPE the upstream and exit 141.
gen_pwd() {
  local raw
  raw="$(LC_ALL=C dd if=/dev/urandom bs=1 count=512 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)"
  printf '%sAa1#' "$raw"
}

gen_hex() {
  local n="$1"
  LC_ALL=C dd if=/dev/urandom bs=1 count=$((n * 2)) 2>/dev/null | LC_ALL=C od -vAn -tx1 | tr -d ' \n' | cut -c1-"$n"
}

SQL_SA_PWD="$(gen_pwd)"
VM_PWD="$(gen_pwd)"
FILEGEN_API_KEY="$(gen_hex 48)"

umask 077
mkdir -p /tmp/f1demo-secrets
printf '%s' "$SQL_SA_PWD"      > /tmp/f1demo-secrets/sqlpwd
printf '%s' "$VM_PWD"          > /tmp/f1demo-secrets/vmpwd
printf '%s' "$FILEGEN_API_KEY" > /tmp/f1demo-secrets/apikey

DEPLOY_NAME="f1demo-$(date +%Y%m%d-%H%M%S)"
printf '%s' "$DEPLOY_NAME" > /tmp/f1demo-secrets/deploy-name

echo "DEPLOY_NAME=$DEPLOY_NAME"
echo "Secrets staged under /tmp/f1demo-secrets/ (chmod 600)"
echo "---"
echo "Starting az deployment sub create..."

export SQL_SA_PWD VM_PWD FILEGEN_API_KEY

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
