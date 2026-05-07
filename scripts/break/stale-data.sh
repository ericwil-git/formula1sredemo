#!/usr/bin/env bash
# break/stale-data.sh — simulate ingestion gone stale.
#
# The alert-f1demo-ingest-stale rule has a 24h window, so a true "no
# heartbeat for 25h" can only be triggered by leaving the demo paused for
# a day. For a live demo we instead:
#
#   1. show the live KQL query the alert evaluates,
#   2. show the alert rule fixture (severity, scope, query),
#   3. clear the FileGen response cache so the next /race hit reads SQL
#      and the agent has fresh dependencies to inspect.
#
# Heal: ./heal/stale-data.sh (re-runs ingestion to refresh the heartbeat)
set -euo pipefail
RG=rg-f1demo-centeral

cat <<EOF
[break/stale-data] simulating ingestion-stale demo path.

The alert-f1demo-ingest-stale rule is on a 24h window. To demo it without
waiting a day, point the agent at the alert rule and the live KQL query.

EOF

echo "--- alert rule (fixture) ---"
az monitor scheduled-query show -g "$RG" -n alert-f1demo-ingest-stale \
  --query "{name:name, severity:severity, window:windowSize, freq:evaluationFrequency, query:criteria.allOf[0].query}" \
  -o yaml

echo ""
echo "--- live KQL: f1_ingest_runs sum (last 24h) ---"
AI_APPID=$(az monitor app-insights component show -g "$RG" --app appi-f1demo --query "appId" -o tsv)
az monitor app-insights query --app "$AI_APPID" \
  --analytics-query "customMetrics | where timestamp > ago(24h) | where name == 'f1_ingest_runs' | summarize Runs = sum(valueSum), LastRun = max(timestamp) by tostring(customDimensions.year)" \
  --query "tables[0].rows" -o tsv

cat <<EOF

[break/stale-data] done.
  - Talk track: "the alert evaluates this exact query every hour. If Runs == 0
    over the 24h window, sev-3 fires and pages the on-call rotation."
  - To demonstrate recovery: ./scripts/heal/stale-data.sh (runs a tiny ingest
    that emits the f1_ingest_runs heartbeat).
EOF
