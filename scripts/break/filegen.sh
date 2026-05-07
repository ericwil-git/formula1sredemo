#!/usr/bin/env bash
# break/filegen.sh — stop the F1FileGenerator Windows service on the demo VM.
#
# Detection:
#   - Web app /race/{year}/{round} returns 502 within ~30s
#   - alert-f1demo-filegen-p99-high may fire (request timeouts spike duration)
#   - alert-f1demo-filegen-errors fires once SCM logs the service stop event
#
# Heal: ./heal/filegen.sh
set -euo pipefail
RG=rg-f1demo-centeral
VM=vm-f1demo-win

echo "[break/filegen] stopping F1FileGenerator service on $VM ..."
az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunPowerShellScript \
  --scripts 'Stop-Service F1FileGenerator -Force; Get-Service F1FileGenerator | Select-Object Name,Status | Format-List' \
  --query "value[].message" -o tsv

cat <<EOF

[break/filegen] done. Wait ~30s, then:
  - refresh https://app-f1demo-wr4dcd.azurewebsites.net/race/2026/3 (expect 502)
  - ask the SRE / Observability Agent: "what's wrong with the F1 demo?"
  - heal with: ./scripts/heal/filegen.sh
EOF
