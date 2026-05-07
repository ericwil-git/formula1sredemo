#!/usr/bin/env bash
# heal/stale-data.sh — kick a heartbeat ingestion run on the demo VM.
# Tiny run: year=2026, events=1, telemetry=false. ~30-60s.
set -euo pipefail
RG=rg-f1demo-centeral
VM=vm-f1demo-win

if [[ ! -f /tmp/f1demo-secrets/sqlpwd ]]; then
  echo "ERROR: /tmp/f1demo-secrets/sqlpwd not found." >&2
  exit 1
fi
SQL_PWD=$(cat /tmp/f1demo-secrets/sqlpwd)

echo "[heal/stale-data] running f1-ingest --year 2026 --events 1 --telemetry false ..."
read -r -d '' PS_SCRIPT <<'EOF' || true
param([string]$SqlSaPassword)
$ProgressPreference = 'SilentlyContinue'
$py = (Get-Command py -EA Stop).Source
$env:F1_SQL_CONNECTION_STRING = "Driver={ODBC Driver 18 for SQL Server};Server=tcp:localhost,1433;Database=f1demo;UID=sa;PWD=$SqlSaPassword;Encrypt=yes;TrustServerCertificate=yes;"
$env:FASTF1_CACHE = 'D:\fastf1-cache'
$env:PYTHONIOENCODING = 'utf-8'
$aiConn = [Environment]::GetEnvironmentVariable('APPLICATIONINSIGHTS_CONNECTION_STRING', 'Machine')
if ($aiConn) { $env:APPLICATIONINSIGHTS_CONNECTION_STRING = $aiConn }

$logPath = 'D:\f1-files\logs\heartbeat-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log'
$cmd = "`"$py`" -3.11 -m f1_ingest.main --year 2026 --events 1 --telemetry false --metrics-port 9101 > `"$logPath`" 2>&1"
& cmd /c $cmd
$rc = $LASTEXITCODE
Write-Output "exit=$rc log=$logPath"
Get-Content $logPath -Tail 5 | ForEach-Object { Write-Output "  $_" }
EOF

az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunPowerShellScript \
  --scripts "$PS_SCRIPT" \
  --parameters "SqlSaPassword=$SQL_PWD" \
  --query "value[].message" -o tsv

echo "[heal/stale-data] done. Heartbeat metric should appear in App Insights customMetrics within ~60s."
