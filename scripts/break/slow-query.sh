#!/usr/bin/env bash
# break/slow-query.sh — start a background loop hammering SQL with an
# unbounded SELECT * FROM dbo.Telemetry. The intent is to spike FileGen's
# p99 latency without creating outright failures (p50 stays normal — long-tail).
#
# Detection:
#   - alert-f1demo-filegen-p99-high fires within ~3-5m
#   - dependencies table shows SQL spans with high duration for cloud_RoleName="F1.FileGenerator"
#
# Heal: ./heal/slow-query.sh
set -euo pipefail
RG=rg-f1demo-centeral
VM=vm-f1demo-win

# Use the SCM-stored 'sa' password from /tmp/f1demo-secrets/. The script
# never logs the password; it injects it as a parameter to the run-command.
if [[ ! -f /tmp/f1demo-secrets/sqlpwd ]]; then
  echo "ERROR: /tmp/f1demo-secrets/sqlpwd not found." >&2
  echo "       Pull from KV first:" >&2
  echo "       az keyvault secret show --vault-name kv-f1demo-wr4dcd --name sqlServerSaPassword --query value -o tsv > /tmp/f1demo-secrets/sqlpwd" >&2
  exit 1
fi
SQL_PWD=$(cat /tmp/f1demo-secrets/sqlpwd)

echo "[break/slow-query] starting SLOW_QUERY background job on $VM ..."
read -r -d '' PS_SCRIPT <<'EOF' || true
param([string]$SqlSaPassword)
$ErrorActionPreference = 'SilentlyContinue'
Get-Job -Name 'SLOW_QUERY' -EA SilentlyContinue | Stop-Job -PassThru | Remove-Job -Force | Out-Null

Start-Job -Name 'SLOW_QUERY' -ArgumentList $SqlSaPassword -ScriptBlock {
    param($pwd)
    $cs = "Server=localhost,1433;Database=f1demo;User Id=sa;Password=$pwd;TrustServerCertificate=True;Encrypt=True;"
    $sql = "SELECT TOP 250000 * FROM dbo.Telemetry t1 CROSS JOIN dbo.Telemetry t2 OPTION (MAXDOP 1);"
    while ($true) {
        try {
            $c = New-Object System.Data.SqlClient.SqlConnection $cs
            $c.Open()
            $cmd = $c.CreateCommand()
            $cmd.CommandText = $sql
            $cmd.CommandTimeout = 60
            [void]$cmd.ExecuteScalar()
            $c.Close()
        } catch { }
        Start-Sleep -Milliseconds 500
    }
} | Out-Null

# Bust the FileGen response cache so subsequent /files/race calls hit SQL.
Get-ChildItem 'D:\f1-files' -Filter 'race-*.csv','race-*.json' -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue

Write-Output "SLOW_QUERY job started: $((Get-Job SLOW_QUERY).Id)"
EOF

az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunPowerShellScript \
  --scripts "$PS_SCRIPT" \
  --parameters "SqlSaPassword=$SQL_PWD" \
  --query "value[].message" -o tsv

cat <<EOF

[break/slow-query] done. SQL is now under sustained heavy load.
  - drive traffic: for i in 1 2 3 4 5; do curl -sk https://app-f1demo-wr4dcd.azurewebsites.net/race/2026/\$i > /dev/null; done
  - alert-f1demo-filegen-p99-high should fire within 5m
  - heal with: ./scripts/heal/slow-query.sh
EOF
