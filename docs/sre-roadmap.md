# SRE / Observability Demo — Roadmap

> **Goal:** make the Azure SRE Agent and Observability Agent look genuinely impressive when demoed against the F1 SRE Demo. Today the apps run end-to-end (Web → FileGen → SQL Server) and three races of real telemetry are loaded, but we have no end-to-end traces, no useful custom metrics, no triggered alerts, and no controlled failure scenarios. This file is the work plan to fix that, in three phases.
>
> **Author:** Eric Wilson · **Updated:** 2026-05-07 · **Status:** roadmap, no work started.

---

## Where we are right now (state at commit `e42b0ac`)

- **Live URL:** https://app-f1demo-wr4dcd.azurewebsites.net
- **Resource group:** `rg-f1demo-centeral` (Central US)
- **Web tier:** App Service Linux B2, ASP.NET Core 8 Blazor Server (`app-f1demo-wr4dcd`)
- **Middle tier:** Windows Server 2022 VM `vm-f1demo-win` (10.20.2.4), running:
  - `F1FileGenerator` Windows service (.NET 8, Kestrel on `:8443`)
  - SQL Server 2022 Developer Edition (localhost:1433, `sa` auth)
  - Azure Monitor Agent (with DCR `dcr-f1demo-vm`)
  - `windows_exporter` on `:9182`
- **Data tier:** SQL Server `f1demo` DB — 3.9 M telemetry rows, 7,752 laps, 2026 rounds 1–3
- **Secrets:** Key Vault `kv-f1demo-wr4dcd` with private endpoint at 10.20.3.4 (public access **Disabled**)
- **Observability today:**
  - Log Analytics workspace `log-f1demo`
  - Application Insights `appi-f1demo` (wired only to App Service via `APPLICATIONINSIGHTS_CONNECTION_STRING`)
  - Azure Monitor Workspace `amw-f1demo` (managed Prometheus — **not yet scraping anything**)
  - One alert rule `alert-f1demo-filegen-errors` (KQL on `Event` table; never fires because nothing logs there yet)
- **Things that emit telemetry:**
  - FileGen exposes Prometheus `/metrics` on `:8443` (counters: `f1_files_generated_total`, `f1_filegen_sql_errors_total`)
  - Ingestion exposes Prometheus on `:9101` when running (counters: `f1_ingest_rows_total`, `f1_ingest_duration_seconds`, `f1_ingest_errors_total`)
  - FileGen writes structured Serilog JSON to `D:\f1-files\logs\filegen-*.log`
  - AMA on the VM picks up Windows Event Logs + perf counters per the DCR
- **What's missing for a great agent demo:**
  - **No distributed traces** — App Insights sees only Web; FileGen calls and SQL queries are invisible
  - **No custom metrics with useful labels** beyond two counters
  - **No managed Prometheus scrape configs** — `:8443/metrics` and `:9182` are exposed but nothing pulls them
  - **No triggered alerts** the agent can summarize
  - **No Workbook** for the agent to reference visually
  - **No failure-injection scripts** — the SRE moment requires manual flailing in RDP

---

## Working secrets / handles

- All staged secrets live in `/tmp/f1demo-secrets/` (chmod 600):
  - `sqlpwd`, `vmpwd`, `apikey`, `deploy-name`
- KV URI: `https://kv-f1demo-wr4dcd.vault.azure.net/`
- VM public IP: 172.202.21.124 (RDP as `f1demoadmin` with `cat /tmp/f1demo-secrets/vmpwd`)
- Repo path on VM: `D:\f1demo\repo\formula1sredemo-main\formula1sredemo-main\` (note: nested folder is correct)
- dotnet SDK on VM: `D:\f1demo\tools\dotnet\dotnet.exe`

---

# Phase 1 — Distributed tracing end-to-end (~1 hour)

> **The single biggest unlock.** Without this the agent can't tell a story; with it, the agent can answer *"this user request was slow because the SQL query at hop 3 took 4.8s."*

## Outcome
- Open App Insights → Transaction Search → click any web request → see a flame-chart with **Web → FileGen → SQL Server** spans, all sharing one `operation_Id`.
- Both `cloud_RoleName` values present (`F1.Web` and `F1.FileGenerator`) so the application map shows both nodes connected by an arrow.
- Failures (FileGen 502, SQL exceptions) attached to the right span with stack traces.

## Concrete tasks

1. **Add OpenTelemetry to FileGenerator** — `src/filegenerator/FileGenerator.csproj`:
   ```xml
   <PackageReference Include="Azure.Monitor.OpenTelemetry.AspNetCore" Version="1.4.0" />
   ```
2. **Wire it in `Program.cs`** before `var app = builder.Build();`:
   ```csharp
   builder.Services.AddOpenTelemetry().UseAzureMonitor(o =>
   {
       o.ConnectionString = builder.Configuration["ApplicationInsights:ConnectionString"];
   });
   builder.Services.Configure<OpenTelemetryLoggerOptions>(o =>
   {
       o.IncludeFormattedMessage = true;
       o.IncludeScopes = true;
   });
   ```
   The Azure Monitor distro auto-instruments ASP.NET Core, HttpClient, and **Microsoft.Data.SqlClient** — that's exactly what we need.
3. **Push App Insights connection string to FileGen** via the existing KV manager:
   - Add a new KV secret `applicationInsightsConnectionString` (already in `monitoring.bicep` outputs as `appInsightsConnectionString` — pipe it into `keyvault.bicep`).
   - Extend `F1KvSecretManager.Load` + `GetKey` to map `applicationInsightsConnectionString` → `ApplicationInsights:ConnectionString`.
4. **Verify Web side** — App Insights SDK is already added (`Microsoft.ApplicationInsights.AspNetCore` 2.22.0 in `Web.csproj`). Confirm `AddApplicationInsightsTelemetry()` is in `Program.cs` (it should be).
5. **Set `cloud_RoleName`** explicitly on FileGen so the app map labels it:
   ```csharp
   builder.Services.AddSingleton<ITelemetryInitializer>(new RoleNameInitializer("F1.FileGenerator"));
   ```
   (small helper class).
6. **Trigger a few requests**, wait 2–3 min for ingestion, then in Azure Portal:
   - App Insights → **Application Map** — should show `F1.Web` → `F1.FileGenerator` → `MSSQL` nodes
   - Transaction Search → pick one — should be a 3-tier waterfall

## Deploy
```bash
# from Mac
cd /Users/ericwilson/Projects/formula1-sre-demo/formula1sredemo
git pull
# Re-publish FileGen on VM via finish-deploy
KV_URI="https://kv-f1demo-wr4dcd.vault.azure.net/"
az vm run-command invoke -g rg-f1demo-centeral -n vm-f1demo-win \
  --command-id RunPowerShellScript \
  --scripts @scripts/finish-filegenerator-deploy.ps1 \
  --parameters "KeyVaultUri=$KV_URI"
```

## Risk / gotcha
- The OTEL distro on FileGen will try to reach `dc.applicationinsights.azure.com` over the public internet from the VM. Check the snet-app NSG egress rules — should be wide open by default but worth confirming.
- After commit + push, the Bicep change (new KV secret) needs to be deployed — use the targeted `keyvault.bicep` deploy pattern we used last time, not the full `main.bicep` (which still hits the network-intent-policy conflict).

---

# Phase 2 — Custom metrics + alerts (~1 hour)

> **What gives the agent something to summarize.** Today there's nothing the agent can point at and say "look, this metric went sideways at 14:30." After Phase 2 there will be.

## Outcome
- Managed Prometheus (Azure Monitor Workspace) scraping the VM's `:8443/metrics`, `:9182`, `:9101` every 30s.
- ~10 custom metric series with labels useful for cross-correlation.
- Three alert rules that fire on failure injection (Phase 3), each routing to the existing Action Group `ag-f1demo-sre`.

## Concrete tasks

### 2.1 Add new metrics to FileGenerator (`src/filegenerator/Metrics.cs`)
```csharp
public static readonly Histogram RequestDuration = Prometheus.Metrics.CreateHistogram(
    "f1_filegen_request_duration_seconds",
    "FileGenerator request duration.",
    new HistogramConfiguration {
        LabelNames = new[] { "endpoint", "status" },
        Buckets    = Histogram.ExponentialBuckets(0.01, 2, 12)   // 10ms..40s
    });

public static readonly Histogram SqlQueryDuration = Prometheus.Metrics.CreateHistogram(
    "f1_filegen_sql_query_duration_seconds",
    "Time spent in SQL queries per endpoint.",
    new HistogramConfiguration {
        LabelNames = new[] { "endpoint" },
        Buckets    = Histogram.ExponentialBuckets(0.01, 2, 12)
    });

public static readonly Counter CacheHits   = Prometheus.Metrics.CreateCounter(
    "f1_filegen_cache_hits_total",   "FileGen cache hits.",
    new CounterConfiguration { LabelNames = new[] { "endpoint" } });
public static readonly Counter CacheMisses = Prometheus.Metrics.CreateCounter(
    "f1_filegen_cache_misses_total", "FileGen cache misses.",
    new CounterConfiguration { LabelNames = new[] { "endpoint" } });
```
Then thread them through each endpoint in `Endpoints/*.cs`:
- Wrap the SQL call in `using (Metrics.SqlQueryDuration.WithLabels("race").NewTimer()) { ... }`.
- Increment `CacheHits` / `CacheMisses` inside the cache-check branch.
- Add a top-level middleware (`Program.cs`) that records `RequestDuration{endpoint, status}` for every `/files/*` call.

### 2.2 Add ingestion freshness gauge (`src/ingestion/src/f1_ingest/metrics.py`)
```python
last_run_timestamp = Gauge(
    "f1_ingest_last_run_timestamp_seconds",
    "Unix timestamp when ingestion last completed successfully.",
    labelnames=("year",),
)
```
Set it at the end of `main.run()` if `rc == 0`.

### 2.3 Wire managed Prometheus scrape configs

This needs an **Azure Monitor data collection rule (DCR) of kind `PrometheusForwarder`** plus a ConfigMap-style scrape config. For VMs (not AKS) it's done via a custom DCR + AMA's Prometheus collector.

Add to `infra/modules/monitoring.bicep`:
```bicep
resource promDcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-${namePrefix}-prom'
  location: location
  tags: tags
  kind: 'Linux'   // works on Windows too despite the name; the AMA Prometheus
                  // collector uses the same DCR shape
  properties: {
    dataCollectionEndpointId: dce.id
    dataSources: {
      prometheusForwarder: [{
        name: 'f1-scrape'
        streams: ['Microsoft-PrometheusMetrics']
        labelIncludeFilter: {}
      }]
    }
    destinations: {
      monitoringAccounts: [{
        accountResourceId: amw.id
        name: 'amwDestination'
      }]
    }
    dataFlows: [{
      streams: ['Microsoft-PrometheusMetrics']
      destinations: ['amwDestination']
    }]
  }
}
```
And separately create a **ConfigMap on the VM** at `C:\AzureData\prometheus.yml`:
```yaml
scrape_configs:
  - job_name: 'filegen'
    scrape_interval: 30s
    scheme: https
    tls_config: { insecure_skip_verify: true }
    static_configs: [{ targets: ['localhost:8443'] }]
  - job_name: 'windows_exporter'
    scrape_interval: 30s
    static_configs: [{ targets: ['localhost:9182'] }]
  - job_name: 'ingestion'
    scrape_interval: 30s
    static_configs: [{ targets: ['localhost:9101'] }]
```
Then point AMA at it. Reference: <https://learn.microsoft.com/azure/azure-monitor/containers/prometheus-metrics-from-arc-enabled-cluster> (the VM pattern is similar — the Azure docs are confusingly AKS-centric but the DCR is the same).

> **Heads up:** the managed-Prometheus-on-VM story is messier than on AKS and may take more than an hour. **Fallback:** stand up a tiny Prometheus container on the VM, scrape locally, and use `Remote Write` to ship metrics to AMW. Or skip AMW entirely for v1 and let the agent query App Insights `customMetrics` (which OTEL emits automatically).

### 2.4 Three alert rules
In `infra/modules/monitoring.bicep` (alongside the existing `sampleAlert`):

| Alert | Source | Condition | Severity |
|---|---|---|---|
| `alert-${namePrefix}-filegen-p99-high` | log-search | App Insights `requests` with `cloud_RoleName="F1.FileGenerator"` p99 > 2000 ms over 5 min | 2 |
| `alert-${namePrefix}-sql-errors` | log-search | `customMetrics` where `name = "f1_filegen_sql_errors_total"` rate > 0 over 5 min | 1 |
| `alert-${namePrefix}-ingest-stale` | log-search | App Insights `customMetrics` `f1_ingest_last_run_timestamp_seconds` older than 24h | 3 |

All three target the existing `actionGroup` (`ag-f1demo-sre`).

## Deploy
```bash
# Apps: same finish-deploy as Phase 1
# Bicep: targeted monitoring module redeploy
az deployment group create -g rg-f1demo-centeral \
  --name monitoring-$(date +%H%M%S) \
  --template-file infra/modules/monitoring.bicep \
  --parameters location=centralus namePrefix=f1demo \
  --parameters tags='{"demo":"f1-nbcu","owner":"eric.wilson@microsoft.com","auto-stop":"manual"}' \
  --no-prompt
```

## Risk / gotcha
- **Managed Prometheus on VMs is the riskiest piece.** Time-box to 90 minutes; if it's still fighting you, fall back to Plan B (App Insights `customMetrics` from OTEL, which "just works" once Phase 1 lands).
- Alert rules for `customMetrics` count toward LAW ingestion cost — fine for a demo.

---

# Phase 3 — Failure injection + workbook + runbook (~2 hours)

> **What makes the demo memorable.** A scripted, repeatable failure → the agent diagnoses it → you remediate. With a real workbook and a clear runbook, this becomes a 5-minute set piece you can run live.

## Outcome
- Five named failure scenarios you can trigger from your Mac with one command each.
- One Azure Monitor Workbook the agent can reference.
- A `docs/sre-demo.md` runbook with the exact patter for the demo.

## Concrete tasks

### 3.1 Failure-injection scripts (in `scripts/break/` and `scripts/heal/`)

| Scenario | Break command | What the agent should detect | Heal |
|---|---|---|---|
| **FileGen down** | `Stop-Service F1FileGenerator` on VM | Web 502s, FileGen scrape failures, alert: p99 high (degenerate to timeout) | `Start-Service F1FileGenerator` |
| **SQL Server down** | `Stop-Service MSSQLSERVER` | `/health` returns `sqlServer: unreachable`, sql-errors alert fires | `Start-Service MSSQLSERVER` |
| **Slow query** | Insert a `SELECT * FROM telemetry` no-WHERE-clause spike with `Invoke-Sqlcmd` in a loop for 5 min | p99 spikes, p50 stays normal — long-tail | kill the loop |
| **Disk filling** | `fsutil file createnew D:\f1-files\big.bin 50000000000` (50 GB) | AMA `LogicalDisk(% Free Space)` < 10% alert, FileGen log writes start failing | `Remove-Item D:\f1-files\big.bin` |
| **Stale data** | Don't run ingestion for 25h (or fudge clock by setting `f1_ingest_last_run_timestamp_seconds` 25h in the past via a one-shot Python) | ingest-stale alert fires | run `run-ingest-2026.ps1` |

Each script is a thin `az vm run-command invoke -g rg-f1demo-centeral -n vm-f1demo-win --command-id RunPowerShellScript --scripts "<one-liner>"`.

Pattern:
```bash
# scripts/break/filegen.sh
#!/usr/bin/env bash
az vm run-command invoke -g rg-f1demo-centeral -n vm-f1demo-win \
  --command-id RunPowerShellScript \
  --scripts 'Stop-Service F1FileGenerator -Force' \
  --query 'value[0].message' -o tsv
echo "FileGen stopped — wait ~5 min for alerts to fire."
```

### 3.2 Workbook

Create `infra/modules/workbook.bicep` with `Microsoft.Insights/workbooks@2023-06-01`. Embed the JSON in a Bicep `var workbookData` (workbook JSON is verbose — author it in the portal first, then export). Three tabs:

1. **Service Health** — three big tiles (Web / FileGen / SQL) with current state, color-coded by latest alert
2. **Latency drill-down** — App Insights `requests` histogram by `cloud_RoleName`, then SQL query duration overlay
3. **Ingestion freshness** — `f1_ingest_rows_total` over time, last-run timestamp, anomaly band

Workbook deployment scope: same RG. Pin to dashboard for the demo.

### 3.3 Runbook (`docs/sre-demo.md`)

Markdown step-by-step:

```
1. Open https://app-f1demo-wr4dcd.azurewebsites.net/race/2026/3 — works fine.
2. Run: ./scripts/break/filegen.sh
3. Wait 90 seconds, refresh the page → 502 banner appears.
4. Open Azure Portal → SRE Agent / Observability Agent.
5. Ask: "What's wrong with the F1 demo?"
6. Expected response: agent identifies the FileGenerator service is
   down, points at the alert, references the workbook.
7. Run: ./scripts/heal/filegen.sh
8. Refresh — page recovers in ~30s.
```

One section per scenario.

## Deploy
- Scripts: just commit and chmod +x.
- Workbook: targeted Bicep deploy of the new module.
- Runbook: pure docs.

## Risk / gotcha
- The "fill the disk" scenario is genuinely destructive on a small VM — make sure the heal script always runs in `try/finally` style.
- The agent's quality depends on what's in Azure today — if the SRE Agent / Observability Agent isn't yet GA in our subscription/region, swap step 5 for opening Application Insights → Smart Detection.

---

# How to start the next session

```bash
# 1. Re-stage secrets if /tmp/f1demo-secrets/ got cleared
ls /tmp/f1demo-secrets/ || (cd /Users/ericwilson/Projects/formula1-sre-demo/formula1sredemo \
                           && ./scripts/deploy-infra.sh)
# 2. Sanity-check the demo is live
curl -sk -o /dev/null -w "%{http_code}\n" https://app-f1demo-wr4dcd.azurewebsites.net/race/2026/3
#    expect: 200; if not, jump to "If KV public access got disabled" below.

# 3. Pick a phase and start.
#    Recommended order: Phase 1 → Phase 2 → Phase 3.
```

## If KV public access got disabled by MCAPS again
We have the private endpoint now so this should be a non-issue, but if for some reason an Azure public-access flip breaks things:
```bash
az keyvault update -n kv-f1demo-wr4dcd --public-network-access Enabled
az webapp config appsettings set -g rg-f1demo-centeral -n app-f1demo-wr4dcd \
  --settings "FileGenerator__ApiKey=@Microsoft.KeyVault(VaultName=kv-f1demo-wr4dcd;SecretName=fileGeneratorApiKey)"
az webapp restart -g rg-f1demo-centeral -n app-f1demo-wr4dcd
```

## If the FileGen service won't start after a redeploy
Almost always cause: `D:\f1demo\certs\filegen.pfx` got deleted, or KV is unreachable from the VM. Check with:
```powershell
# RDP'd in
Get-Service F1FileGenerator
Get-ChildItem D:\f1-files\logs\filegen-*.log | sort LastWriteTime -Desc | select -First 1 | Get-Content -Tail 30
```

---

# What NOT to touch

- **`infra/modules/network.bicep`** — full Bicep redeploys hit the SQL-MI network-intent-policy conflict (orphaned policy from the deleted SQL MI). Do NOT redeploy `network.bicep` — use targeted module deploys for everything else (`keyvault.bicep`, `monitoring.bicep`).
- **The `repo/formula1sredemo-main/formula1sredemo-main` nested folder** on the VM — that's the layout `finish-filegenerator-deploy.ps1` expects. Don't "fix" it.
- **The `sa` SQL auth path** — yes, MI-based auth would be cleaner; no, MCAPS won't let us.

---

# Quick cost note

While paused: stop the VM (`az vm deallocate -g rg-f1demo-centeral -n vm-f1demo-win`) — saves ~$1.50/day. App Service B2 + KV + Log Analytics keep running ($0.30/day combined).
