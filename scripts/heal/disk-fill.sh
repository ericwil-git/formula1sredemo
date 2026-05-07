#!/usr/bin/env bash
# heal/disk-fill.sh — delete the giant file created by break/disk-fill.sh.
# Safe to run any time (no-op if the file is already gone).
set -euo pipefail
RG=rg-f1demo-centeral
VM=vm-f1demo-win

echo "[heal/disk-fill] removing D:\\f1-files\\big.bin on $VM ..."
read -r -d '' PS_SCRIPT <<'EOF' || true
$path = 'D:\f1-files\big.bin'
if (Test-Path $path) {
    Remove-Item $path -Force
    Write-Output "Removed $path"
} else {
    Write-Output "Already gone."
}
Get-PSDrive D | Select-Object Name, @{N='UsedGB';E={[math]::Round($_.Used/1GB,1)}}, @{N='FreeGB';E={[math]::Round($_.Free/1GB,1)}}
EOF

az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunPowerShellScript \
  --scripts "$PS_SCRIPT" \
  --query "value[].message" -o tsv

echo "[heal/disk-fill] done."
