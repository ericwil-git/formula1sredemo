#!/usr/bin/env bash
# break/sql.sh — stop SQL Server on the demo VM.
#
# Detection:
#   - https://localhost:8443/health on the VM returns sqlServer="unreachable"
#   - alert-f1demo-sql-errors fires within 5m once endpoints throw SqlException
#   - dependencies table in App Insights shows SQL spans with success=false
#
# Heal: ./heal/sql.sh
set -euo pipefail
RG=rg-f1demo-centeral
VM=vm-f1demo-win

echo "[break/sql] stopping MSSQLSERVER on $VM ..."
az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunPowerShellScript \
  --scripts 'Stop-Service MSSQLSERVER -Force; Get-Service MSSQLSERVER | Select-Object Name,Status | Format-List' \
  --query "value[].message" -o tsv

cat <<EOF

[break/sql] done. Wait ~30s, then:
  - hit https://app-f1demo-wr4dcd.azurewebsites.net/race/2026/3 a few times
  - the FileGen catch-block returns 502 with "SQL Server unreachable" detail
  - alert-f1demo-sql-errors will fire within ~5m
  - heal with: ./scripts/heal/sql.sh
EOF
