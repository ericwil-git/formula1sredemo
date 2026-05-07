# F1 SRE Demo — Live Runbook

> Use this as the on-stage script. Every command here is idempotent and
> tested. Each scenario is ~5 minutes door-to-door (break → diagnose → heal).

## Pre-flight (before you start the demo)

```bash
# 1. Confirm the demo is healthy.
curl -sk -o /dev/null -w "/         %{http_code}\n" https://app-f1demo-wr4dcd.azurewebsites.net/
curl -sk -o /dev/null -w "/race/3   %{http_code}\n" https://app-f1demo-wr4dcd.azurewebsites.net/race/2026/3
# expect 200 / 200

# 2. Confirm the VM is running.
az vm get-instance-view -g rg-f1demo-centeral -n vm-f1demo-win \
  --query "instanceView.statuses[?starts_with(code, 'PowerState')].displayStatus" -o tsv
# expect: VM running

# 3. Open the workbook in the portal:
#    Application Insights `appi-f1demo` -> Workbooks ->
#      "F1 SRE Demo — Service Overview"
#    Pin to dashboard for the demo.

# 4. Open a second tab to the SRE Agent / Observability Agent in the portal.
```

## Demo arc (~25 min total)

The five scenarios below are independent. Pick 1–3 for any given audience.
The classic 15-minute arc is **#1 (FileGen down)** → **#3 (slow query)** →
**#2 (SQL down)**. Hit `#5 (stale data)` at the end if the audience cares
about data-pipeline reliability.

---

## Scenario 1 — FileGenerator service down  *(the canonical demo)*

**Story:** The middle tier crashed (or a deployment went sideways and the
service won't restart). The web tier is now returning 502s.

```bash
# Break
./scripts/break/filegen.sh

# Wait ~30 seconds. Refresh the page in the browser.
# Browser shows: 502 Bad Gateway (or the exception page if you're already on it).
```

**On stage:**

> "Notice the page is broken. Let me ask the SRE Agent what's wrong."

Open the SRE Agent tab. Ask:

> *"What's wrong with the F1 demo?"*

Expected response shape:

- "The `F1FileGenerator` Windows service on `vm-f1demo-win` is **stopped**."
- Cites `alert-f1demo-filegen-errors` or the recent dependency failures
  in App Insights.
- Suggests `Start-Service F1FileGenerator`.

**Heal:**

```bash
./scripts/heal/filegen.sh
# wait ~30s
curl -sk -o /dev/null -w "%{http_code}\n" https://app-f1demo-wr4dcd.azurewebsites.net/race/2026/3
# expect: 200
```

---

## Scenario 2 — SQL Server down  *(infrastructure-level failure)*

**Story:** The database is unreachable. The middle tier is up but its
upstream dependency is gone.

```bash
# Break
./scripts/break/sql.sh

# Generate failing traffic.
for i in 1 2 3 4 5; do
  curl -sk -o /dev/null -w "%{http_code} " https://app-f1demo-wr4dcd.azurewebsites.net/race/2026/$i
done
echo
# expect: 502 502 502 502 502 (FileGen catches the SqlException)

# Wait ~5 min for alert-f1demo-sql-errors to fire (sev 1).
```

**On stage** (workbook → **Service Health** tab):

> "The `Failures` column on the **per-tier traffic** table jumped. Look at
> the **SQL dependency health** panel — `success=false` rate spiked.
> The **f1_filegen_sql_errors** custom metric ticked. Sev-1 alert is
> firing."

Expected SRE Agent response:

- "SQL Server is stopped on `vm-f1demo-win`."
- "FileGenerator's `/health` endpoint returns `sqlServer: unreachable`."
- Suggests `Start-Service MSSQLSERVER`.

**Heal:**

```bash
./scripts/heal/sql.sh
# wait ~30s
```

---

## Scenario 3 — Slow query  *(p99 / long-tail story)*

**Story:** Someone pushed a bad query plan. The service is up, p50 is
fine, but p99 is climbing. Classic "what's slow, and where".

```bash
# Break — starts an unbounded SELECT * loop that hammers SQL.
./scripts/break/slow-query.sh

# Drive web traffic to mix with the slow path (cache will be busted).
for i in $(seq 1 12); do
  curl -sk -o /dev/null -w "%{http_code} " https://app-f1demo-wr4dcd.azurewebsites.net/race/2026/$((RANDOM % 3 + 1))
  sleep 5
done
echo

# Wait ~5 min for alert-f1demo-filegen-p99-high (sev 2).
```

**On stage** (workbook → **Latency** tab):

> "Volume is normal. Look at the **percentiles** chart — p50 hasn't moved
> but p99 climbed past 2 seconds. Drill into the **SQL query duration from
> FileGenerator** chart at the bottom — that's where the time is being
> spent."

Expected SRE Agent response:

- "FileGenerator p99 is high but p50 is stable — long-tail."
- Cites a slow SQL dependency (the cross-join).
- Suggests inspecting `dependencies | where type=='SQL' and duration > 1s`.

**Heal:**

```bash
./scripts/heal/slow-query.sh
# p99 returns to baseline within ~3-5m as the metric window ages out.
```

---

## Scenario 4 — Disk filling  *(infrastructure / capacity)*

**Story:** Logs piled up, a runaway process wrote a giant file, the
middle-tier disk is about to fill. The agent should spot it before users do.

> ⚠️ **Always pair break ↔ heal.** D: is small.

```bash
# Break — creates a 50 GB file at D:\f1-files\big.bin.
./scripts/break/disk-fill.sh
```

**On stage:**

Open Log Analytics, run:

```kusto
Perf
| where TimeGenerated > ago(15m)
| where ObjectName == "LogicalDisk" and CounterName == "% Free Space"
| where InstanceName == "D:"
| summarize FreePct = avg(CounterValue) by bin(TimeGenerated, 1m)
| render timechart
```

Free-space drops sharply.

**Heal (ALWAYS do this within a couple of minutes):**

```bash
./scripts/heal/disk-fill.sh
```

---

## Scenario 5 — Stale data  *(data-pipeline freshness)*

**Story:** The ingestion job hasn't run in 24h. The web app still works,
but the data is stale. The Observability Agent should care about this even
when nothing is "broken".

```bash
# "Break" — show the live KQL the alert evaluates and the rule fixture.
./scripts/break/stale-data.sh
```

**On stage** (workbook → **Ingestion** tab):

> "The top tile is the data the ingest-stale alert keys off. Right now
> Runs > 0 because we're running heartbeats from the demo. In a real
> outage, that table would be empty for 24h and the sev-3 alert would
> fire — pointing the operator at exactly this dashboard."

**Heal (kick a heartbeat run):**

```bash
./scripts/heal/stale-data.sh
# heartbeat metric appears in customMetrics within ~60s.
```

---

## After the demo

```bash
# 1. Always confirm both apps are healthy.
curl -sk -o /dev/null -w "%{http_code}\n" https://app-f1demo-wr4dcd.azurewebsites.net/race/2026/3

# 2. Confirm no scenario is left "broken".
./scripts/heal/filegen.sh
./scripts/heal/sql.sh
./scripts/heal/slow-query.sh
./scripts/heal/disk-fill.sh

# 3. Stop the VM to save money (~$1.50/day saved).
az vm deallocate -g rg-f1demo-centeral -n vm-f1demo-win
```

---

## Troubleshooting the demo itself

| Symptom | First thing to check |
|---|---|
| Page returns 502 even after `heal/filegen.sh` | RDP to the VM, `Get-ChildItem D:\f1-files\logs\filegen-*.log \| sort LastWriteTime -Desc \| select -First 1 \| Get-Content -Tail 30` — usually KV unreachable or PFX missing |
| `az vm run-command invoke` hangs | The previous run-command is still locked. Wait ~2m or `az vm run-command list -g rg-f1demo-centeral --vm-name vm-f1demo-win` |
| `/tmp/f1demo-secrets/sqlpwd` missing | `az keyvault secret show --vault-name kv-f1demo-wr4dcd --name sqlServerSaPassword --query value -o tsv > /tmp/f1demo-secrets/sqlpwd && chmod 600 /tmp/f1demo-secrets/sqlpwd` |
| KV public access disabled (MCAPS flip) | The PE handles internal traffic. For CLI access: `az keyvault update -n kv-f1demo-wr4dcd --public-network-access Enabled` |
| Workbook empty | App Insights ingestion lag is up to ~3m for `customMetrics`, ~5m for `requests`. Drive traffic and wait. |
