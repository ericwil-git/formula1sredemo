#!/usr/bin/env bash
# Detached launcher for the F1 demo deployment.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -f /tmp/f1demo-deploy.log
nohup bash scripts/deploy-infra.sh > /tmp/f1demo-deploy.log 2>&1 &
PID=$$
DEPLOY_PID=$(jobs -p | tail -1)
disown
echo "Deploy PID: $DEPLOY_PID"
echo "Log: /tmp/f1demo-deploy.log"
sleep 5
echo "--- first lines of log ---"
cat /tmp/f1demo-deploy.log || true
