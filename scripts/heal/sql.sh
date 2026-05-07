#!/usr/bin/env bash
# heal/sql.sh — start SQL Server on the demo VM.
set -euo pipefail
RG=rg-f1demo-centeral
VM=vm-f1demo-win

echo "[heal/sql] starting MSSQLSERVER on $VM ..."
az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunPowerShellScript \
  --scripts 'Start-Service MSSQLSERVER; Start-Sleep -Seconds 8; Get-Service MSSQLSERVER | Select-Object Name,Status | Format-List' \
  --query "value[].message" -o tsv

echo "[heal/sql] done. Web app should recover within ~10s once FileGen reopens connections."
