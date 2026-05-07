#!/usr/bin/env bash
# heal/slow-query.sh — kill the SLOW_QUERY background job on the demo VM.
set -euo pipefail
RG=rg-f1demo-centeral
VM=vm-f1demo-win

echo "[heal/slow-query] killing SLOW_QUERY background job on $VM ..."
read -r -d '' PS_SCRIPT <<'EOF' || true
$ErrorActionPreference = 'SilentlyContinue'
$jobs = Get-Job -Name 'SLOW_QUERY' -EA SilentlyContinue
if ($jobs) {
    $jobs | Stop-Job -PassThru | Remove-Job -Force
    Write-Output "Stopped $($jobs.Count) SLOW_QUERY job(s)."
} else {
    Write-Output "No SLOW_QUERY job found (already healed?)."
}

# Also kill any lingering dotnet/sqlservr CPU spikes from the cross-join.
# Best-effort: if SLOW_QUERY had finished we don't want to nuke real work.
EOF

az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunPowerShellScript \
  --scripts "$PS_SCRIPT" \
  --query "value[].message" -o tsv

echo "[heal/slow-query] done. p99 will return to normal within ~3-5m as the metric window ages out."
