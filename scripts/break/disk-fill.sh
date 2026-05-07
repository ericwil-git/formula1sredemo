#!/usr/bin/env bash
# break/disk-fill.sh — create a 50 GB file on D:\ to trigger free-space alerts.
#
# Detection:
#   - AMA Perf counter \LogicalDisk(_Total)\% Free Space drops in ~10m
#   - filegen log writes start failing once D: < ~1 GB
#
# Heal: ./heal/disk-fill.sh (always pair these — D: is small)
set -euo pipefail
RG=rg-f1demo-centeral
VM=vm-f1demo-win

echo "[break/disk-fill] creating D:\\f1-files\\big.bin (50 GB sparse-style) on $VM ..."
read -r -d '' PS_SCRIPT <<'EOF' || true
$path = 'D:\f1-files\big.bin'
New-Item -ItemType Directory -Force -Path 'D:\f1-files' | Out-Null
fsutil file createnew $path 50000000000
Write-Output "Created $path"
Get-PSDrive D | Select-Object Name, @{N='UsedGB';E={[math]::Round($_.Used/1GB,1)}}, @{N='FreeGB';E={[math]::Round($_.Free/1GB,1)}}
EOF

az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunPowerShellScript \
  --scripts "$PS_SCRIPT" \
  --query "value[].message" -o tsv

cat <<EOF

[break/disk-fill] done. D: is now mostly full.
  - in 5-10m the AMA Perf counter shows the drop in Log Analytics
  - heal AS SOON as the demo moment is over: ./scripts/heal/disk-fill.sh
EOF
