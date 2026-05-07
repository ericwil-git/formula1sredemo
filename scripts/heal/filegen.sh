#!/usr/bin/env bash
# heal/filegen.sh — start the F1FileGenerator Windows service on the demo VM.
set -euo pipefail
RG=rg-f1demo-centeral
VM=vm-f1demo-win

echo "[heal/filegen] starting F1FileGenerator service on $VM ..."
az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunPowerShellScript \
  --scripts 'Start-Service F1FileGenerator; Start-Sleep -Seconds 5; Get-Service F1FileGenerator | Select-Object Name,Status | Format-List' \
  --query "value[].message" -o tsv

echo "[heal/filegen] done. Wait ~30s and refresh the web app — should recover."
