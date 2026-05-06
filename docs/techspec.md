# Technical Specification — F1 Insights Demo

**Customer:** Mike Donoghue, NBCU Sports
**Author:** Eric Wilson, Microsoft (Prin Cloud Solution Architect)
**Repository:** https://github.com/ericwil-git/formula1sredemo
**Status:** v0.4 — deployed and serving live 2026 race data
**Live demo:** <https://app-f1demo-wr4dcd.azurewebsites.net>

> **Change log**
> - **v0.4 (2026-05-06):** five Blazor pages live with filters; lap-time
>   distribution box plot, tyre stint Gantt, Q1→Q2→Q3 progression charts;
>   Key Vault private endpoint in `snet-pe` with `publicNetworkAccess=Disabled`;
>   FileGenerator running as a Windows service with KV-backed config via the
>   VM managed identity; `f1-ingest` orchestration loop populated 2026
>   rounds 1–3 with telemetry (3.9 M telemetry rows in 9 minutes).
> - **v0.3 (2026-05-01):** data tier pivoted from Azure SQL Managed Instance
>   to SQL Server 2022 Developer Edition on the VM (MCAPS deny policy +
>   Entra Directory Readers blocker; see §3.1).
> - **v0.2 (2026-04):** original Copilot-implementation draft.
**Region:** Central US

---

## 1. Goals & Non-Goals

### Goals
- Demonstrate a realistic enterprise three-tier pattern: cloud-native web tier consuming data produced by a Windows Server (IaaS) middle tier backed by SQL Server installed on the same VM. (Originally specified as Azure SQL Managed Instance — see §3.1 for why this changed.)
- Use real, recognizable Formula 1 data (sessions, laps, drivers, **telemetry**) sourced from the open-source [FastF1](https://docs.fastf1.dev/api_reference/index.html) library.
- Showcase first-class observability: Azure Monitor Agent on the VM, Azure Monitor Workspace for managed Prometheus metrics, and the Observability Agent for end-to-end SRE storytelling.
- Deployable end-to-end via Bicep + GitHub Actions in under 30 minutes; tear-down friendly (no auto-shutdown — operator stops resources between demos).

### Non-Goals
- Live timing during active F1 sessions. Demo uses historical race / qualifying data only.
- Multi-region HA, DR, or production-grade hardening.
- Authentication. Web app is **anonymous**; FileGenerator API uses a static API key only.
- Active Directory / domain join.

---

## 2. Architecture

### 2.1 Component Diagram

```
                                    Central US
+-------------------+                              +-----------------------------+
|  Azure App        |   HTTPS (private endpoint)   |  Windows Server 2022 VM     |
|  Service          | ---------------------------> |  - F1.IngestionService (Py) |
|  (ASP.NET Core 8) |                              |  - F1.FileGenerator (.NET 8)|
|  anonymous        |                              |  - Azure Monitor Agent      |
+--------+----------+                              |  - Prometheus exporter      |
         ^                                         +-------------+---------------+
         |                                                       |
         |                                                       | T-SQL (private endpoint)
         |                                                       v
         |                                         +-----------------------------+
         |                                         |  SQL Server 2022 Dev Ed.    |
         |                                         |  (on the same VM, port 1433)|
         |                                         |  General Purpose, 4 vCore   |
         |                                         +-------------+---------------+
         |                                                       |
         |                                                       | diagnostic settings
         v                                                       v
+-----------------------------------------------------------------------------+
|  Azure Monitor Workspace  +  Log Analytics  +  Observability Agent          |
|  (managed Prometheus)        (logs, KQL)       (SRE / incident assistant)   |
+-----------------------------------------------------------------------------+
```

### 2.2 Networking
- One VNet (`vnet-f1demo-cus`) with three subnets:
  - `snet-app`   — Windows Server VM (also hosts SQL Server)
  - `snet-pe`    — private endpoints (App Service → Key Vault)
  - `snet-appsvc-int` — App Service VNet integration
- App Service uses regional VNet integration to call the VM over its private IP.
- SQL Server is bound to the VM's private NIC and only reachable from inside
  the VNet via NSG rule on `snet-app:1433`. FileGenerator and Ingestion
  connect to `localhost,1433` from on-box, so the VNet path is unused at
  runtime but available for ad-hoc admin from another VNet-attached host.
- Private DNS zones for `privatelink.vaultcore.azure.net` and `privatelink.azurewebsites.net`.

### 2.3 Identity
- System-assigned managed identities on App Service and Windows Server VM.
- SQL Server: SQL authentication (mixed mode), `sa` account; password stored
  in Key Vault and read by FileGenerator/Ingestion at startup.
- Secrets (SQL `sa` password, FileGenerator API key, FastF1 cache path) in
  Key Vault; consumed via managed identity.

---

## 3. Components

### 3.1 SQL Server 2022 Developer Edition (on the VM)

> **Design change v0.3 (2026-05):** the data tier was originally specified as
> Azure SQL Managed Instance. The MCAPS subscription enforces an
> AAD-only-authentication deny policy on SQL MI that cannot be disabled (even
> with `SecurityControl=Ignore`), and the SQL MI MI cannot be granted
> Directory Readers in this tenant without a Privileged Role Administrator —
> blocking `CREATE USER ... FROM EXTERNAL PROVIDER` for the VM/App Service
> identities. SQL Server installed locally on the VM is fully under our
> control, free under the Developer SKU, and tells the same on-prem-style
> story for an SRE demo.

- **Edition:** SQL Server 2022 Developer Edition (free, full-featured, not for production).
- **Install host:** the Windows Server VM (`vm-f1demo-win`).
- **Auth mode:** mixed (SQL + Windows). FileGenerator and Ingestion both run on the
  VM and connect via `Server=localhost,1433` with the `sa` account; the password
  lives in Key Vault as `sqlServerSaPassword` and is read at service startup.
- **Storage:** data + log files on the `D:\sqldata` directory of the VM's data disk.
- **Collation:** `SQL_Latin1_General_CP1_CI_AS` (database-level, set when `db/schema.sql` runs).
- **Backup:** native SQL Server backup to `D:\sqldata\backup` (out of scope for v1).
- **Diagnostic data:** SQL Server error log + AMA-collected Windows Event Log →
  Log Analytics. The `windows_exporter` MSSQL collector exposes per-database
  metrics on `:9182/metrics` (scraped by Azure Monitor managed Prometheus).

### 3.2 Windows Server VM
- **OS:** Windows Server 2022 Datacenter Azure Edition.
- **Size:** `Standard_D2s_v5`.
- **Disks:** OS (P10), data disk `D:` (P10) for FastF1 cache and generated flat files.
- **Installed software (provisioned via Bicep `runCommand` or DSC):**
  - Python 3.11 + `fastf1`, `pandas`, `pyodbc`, `prometheus_client`
  - .NET 8 Hosting Bundle
  - Microsoft ODBC Driver 18 for SQL Server
  - **Azure Monitor Agent (AMA)** with a Data Collection Rule for Windows Event Logs, Performance Counters, and custom logs from `D:\f1-files\logs\`
  - **windows_exporter** (or .NET `prometheus-net`) scraped by Azure Monitor managed Prometheus
- **Two services run on the VM:**

#### `F1.IngestionService` (Python)
- Pulls historical F1 sessions from FastF1; populates the local SQL Server.
- Triggered manually (`run-ingest.ps1 --year 2024 --events all --telemetry true`) and on a daily Scheduled Task for incremental loads.
- Caches FastF1 raw data to `D:\fastf1-cache\` to respect FastF1 rate limits across re-runs.
- Bulk insert via `pyodbc` `fast_executemany=True`; telemetry rows batched at 10 000.
- Emits Prometheus metrics: `f1_ingest_rows_total{table=...}`, `f1_ingest_duration_seconds`, `f1_ingest_errors_total`.

#### `F1.FileGenerator` (.NET 8 Minimal API)
- Listens on `https://0.0.0.0:8443` with self-signed cert (trusted via App Service `WEBSITE_LOAD_ROOT_CERTIFICATES`).
- Queries the local SQL Server on demand; materializes CSV or JSON; caches to `D:\f1-files\` (key = querystring hash).
- Adds `prometheus-net` middleware for HTTP request metrics, plus custom counters `f1_files_generated_total{endpoint=...,format=...}`.
- Logs structured JSON to `D:\f1-files\logs\filegen-YYYYMMDD.log`, picked up by AMA.

### 3.3 Azure App Service (Web Tier)
- **Stack:** ASP.NET Core 8, Linux, **B2** plan.
- **Auth:** anonymous (no Entra ID, no API gateway).
- **UI:** Blazor Server with Chart.js for telemetry visualizations.
- **Outbound:** calls Windows Server FileGenerator endpoints; API key from Key Vault.
- **App Insights:** connected to the same Log Analytics workspace as the VM.

### 3.4 Observability Stack
- **Log Analytics Workspace** — single workspace, all sources.
- **Azure Monitor Workspace** — managed Prometheus; scrapes:
  - VM `windows_exporter` on `:9182`
  - `F1.FileGenerator` `/metrics` on `:8443`
  - `F1.IngestionService` pushgateway (or textfile collector via windows_exporter)
- **Azure Managed Grafana** (optional, recommended) — dashboards for ingestion throughput, file generation latency, SQL Server CPU/IO, lap-data freshness.
- **Observability Agent** — connected to the workspace; used live during the demo to answer SRE-style questions ("why did the last ingestion take 12 minutes?", "are there errors in the FileGenerator logs in the last hour?").

---

## 4. Data Model (SQL Server `f1demo`)

```sql
Seasons        (SeasonId PK, Year, Name)
Events         (EventId PK, SeasonId FK, Round, Country, Location,
                EventName, EventDate)
Sessions       (SessionId PK, EventId FK, SessionType, -- FP1/FP2/FP3/Q/Sprint/R
                StartTimeUtc, TotalLaps)
Drivers        (DriverId PK, Code, FullName, TeamName, SeasonId FK)
Laps           (LapId PK, SessionId FK, DriverId FK, LapNumber, LapTimeMs,
                Sector1Ms, Sector2Ms, Sector3Ms, Compound, TyreLife,
                Position, IsPersonalBest)
Telemetry      (TelemetryId PK, LapId FK, SampleTimeMs, SpeedKph, RPM,
                Throttle, Brake, Gear, DRS)
QualiResults   (SessionId FK, DriverId FK, Position, Q1Ms, Q2Ms, Q3Ms)
RaceResults    (SessionId FK, DriverId FK, Position, GridPosition, Status,
                Points, FastestLapMs)
```

**Indexes**
- `IX_Laps_Session_Driver_Lap` on `Laps(SessionId, DriverId, LapNumber)`
- `IX_Telemetry_Lap_Time` on `Telemetry(LapId, SampleTimeMs)`
- `IX_Sessions_Event_Type` on `Sessions(EventId, SessionType)`

**Volume estimate (full 2024 season, telemetry on):** ~24 events × ~5 sessions × ~20 drivers × ~60 laps × ~200 telemetry samples ≈ 28M telemetry rows. Comfortable on the VM's 128 GB Premium SSD data disk.

---

## 5. Data Flow

### 5.1 Ingestion (one-time + on-demand)
1. Operator runs `D:\f1demo\run-ingest.ps1 --year 2024 --events all`.
2. `F1.IngestionService` iterates events, loads each session via FastF1.
3. FastF1 caches to `D:\fastf1-cache\`.
4. Service transforms FastF1 dataframes → bulk inserts into SQL Server.
5. Telemetry inserted in 10 000-row batches; each batch wrapped in a transaction.
6. Prometheus counters incremented; success/failure logged for AMA pickup.

### 5.2 Read Path (per user request)
1. User opens `https://<app>.azurewebsites.net/race/2024/8` (Monaco).
2. App Service Blazor component calls `https://winsrv.internal:8443/files/race?year=2024&round=8&format=csv` with `X-Api-Key`.
3. FileGenerator checks `D:\f1-files\` cache; if miss, queries the local SQL Server and writes CSV.
4. CSV streamed back to App Service; parsed; Chart.js renders the table and charts.
5. Telemetry overlay view (`/lap-detail`) calls a separate JSON endpoint and plots speed/throttle/brake/gear.

### 5.3 Sequence Diagram

```mermaid
sequenceDiagram
    autonumber
    actor User as Browser (anonymous)
    participant App as Azure App Service
    participant VM as Windows Server VM
    participant FG as F1.FileGenerator
    participant ING as F1.IngestionService
    participant FF1 as FastF1 (public)
    participant SQL as SQL Server (on VM)
    participant AMW as Azure Monitor Workspace
    participant LAW as Log Analytics
    participant OBS as Observability Agent

    Note over ING,SQL: Phase 1 — Ingestion (one-time / scheduled)
    ING->>FF1: Load season, events, sessions, telemetry
    FF1-->>ING: DataFrames (cached to D:\fastf1-cache)
    ING->>SQL: BULK INSERT Sessions, Laps, Telemetry, Results
    SQL-->>ING: rowcount, status
    ING->>AMW: Prometheus metrics (rows/sec, duration, errors)
    ING->>LAW: structured logs via Azure Monitor Agent

    Note over User,SQL: Phase 2 — User browses a race
    User->>App: GET /race/2024/8
    App->>VM: GET https://winsrv:8443/files/race?year=2024&round=8&format=csv
    VM->>FG: route to FileGenerator
    FG->>FG: check D:\f1-files cache
    alt cache miss
        FG->>SQL: SELECT laps + results JOIN drivers
        SQL-->>FG: result set
        FG->>FG: write CSV to D:\f1-files
    end
    FG-->>App: CSV (Content-Disposition: attachment)
    App-->>User: rendered race results + charts

    Note over User,FG: Phase 3 — Telemetry deep-dive
    User->>App: GET /lap-detail?driver=VER&lap=42
    App->>FG: GET /files/lap-detail?...&format=json
    FG->>SQL: SELECT telemetry samples for LapId
    SQL-->>FG: ~200 rows
    FG-->>App: JSON
    App-->>User: speed/throttle/brake/gear chart

    Note over AMW,OBS: Phase 4 — SRE walk-through
    FG->>AMW: f1_files_generated_total, http_request_duration_seconds
    VM->>LAW: Windows events, IIS logs, FileGen logs
    SQL->>LAW: diagnostic settings (audit, errors, resource usage)
    OBS->>LAW: KQL queries on demand
    OBS->>AMW: PromQL queries on demand
    OBS-->>User: "Last ingestion took 11m42s; 3 retries on Telemetry batch 87"
```

---

## 6. Windows Server API Contract (FileGenerator)

All endpoints require header `X-Api-Key: <key>`. All return `Content-Type` matching the `format` parameter.

| Method | Path                  | Query                                            | Returns |
|--------|-----------------------|--------------------------------------------------|---------|
| GET    | `/files/race`         | `year`, `round`, `format` (`csv`\|`json`)         | Lap-by-lap race results joined with driver/team, sector times, compound, position. |
| GET    | `/files/qualifying`   | `year`, `round`, `format`                         | Q1/Q2/Q3 times per driver with delta-to-pole. |
| GET    | `/files/lap-detail`   | `year`, `round`, `session`, `driver`, `lap`, `format` | Per-sample telemetry for one lap. |
| GET    | `/files/season`       | `year`, `format`                                  | Event calendar with rounds, dates, locations. |
| GET    | `/health`             | —                                                | `{"status":"ok","sqlServer":"reachable","cacheSizeMb":N}` |
| GET    | `/metrics`            | —                                                | Prometheus exposition (no API key required from VNet). |

**Error model:** RFC 7807 problem+json. `404` for unknown race, `502` for SQL Server unreachable, `401` for bad API key.

---

## 7. UI Scenarios (App Service)

All five pages are implemented and reachable from the live site
(<https://app-f1demo-wr4dcd.azurewebsites.net>):

1. **Season browser** (`/`) — year picker (default 2026, range 2018–2030);
   table of events with race / quali deep links per round.
2. **Race results** (`/race/{year}/{round}`):
   - **Driver dropdown** filter applied to every chart and the table.
   - **Position-by-lap** line chart, one line per driver.
   - **Lap-time distribution** box plot per driver. Outlier laps slower than
     110% of the driver's median (pit stops, safety-car laps) are trimmed so
     the IQR boxes are readable; drivers sorted by median ascending.
   - **Tyre stint Gantt** — horizontal bars colored by compound
     (SOFT/MEDIUM/HARD/INTERMEDIATE/WET); multiple stints per driver.
   - Lap-by-lap table (capped at 200 rows when viewing all drivers).
3. **Qualifying** (`/qualifying/{year}/{round}`):
   - **Session selector** — All (Q1+Q2+Q3) | Q1 | Q2 | Q3.
   - **Driver dropdown** filter.
   - When session = All: the existing Q1/Q2/Q3 grid + delta-to-pole bar chart.
   - When session = Qx: filtered to drivers who set a time in that session,
     sorted fastest-first, chart switched to raw QxMs.
   - **Q1 → Q2 → Q3 progression** line chart — always visible; one line per
     driver across the three sessions, with gaps where they were eliminated.
4. **Lap explorer** (`/lap-explorer`) — telemetry overlay (speed line chart
   + throttle/brake/gear chart) for any driver/lap.
5. **Driver compare** (`/compare`) — lap-time overlay for two drivers across
   a race.
6. **Ops dashboard** (link out to Grafana) — ingestion freshness, FileGen
   latency, SQL Server health. *(Pending; see §10.)*

---

## 8. Infrastructure as Code (Bicep)

Actual layout (matches HEAD of `main`):

```
/infra
  main.bicep                       # subscription scope: creates RG + invokes modules
  modules/
    network.bicep                  # vnet, 4 subnets, NSGs, route table, 2 private DNS zones
    vm.bicep                       # Win Server 2022 + AMA + DCR association
    appservice.bicep               # plan, app, VNet integration, KV refs
    monitoring.bicep               # Log Analytics + AppInsights + AMW + DCR + alerts
    keyvault.bicep                 # KV with RBAC + private endpoint
  parameters/
    dev.bicepparam
/src
  ingestion/                       # Python 3.11 — FastF1 → SQL Server (pyodbc)
  filegenerator/                   # .NET 8 minimal API, Windows service
  web/                             # ASP.NET Core 8 Blazor Server
/scripts
  deploy-infra.sh                  # one-shot infra deploy from Mac (generates secrets)
  install-vm-deps.ps1              # bootstraps the VM (Python, .NET runtime, ODBC 18, SQL Server install)
  deploy-filegenerator.ps1         # full FileGenerator deploy from scratch on the VM
  finish-filegenerator-deploy.ps1  # publish + service install (when source is already on disk)
  run-ingest.ps1                   # operator wrapper around f1-ingest CLI
/db
  schema.sql                       # 8 tables + 3 indexes
  seed.sql                         # placeholder
/.github/workflows
  infra.yml                        # Bicep what-if + deploy (OIDC)
  apps.yml                         # build & deploy apps
```

### 8.1 Pipelines
- **`infra.yml`** — `az deployment sub create --location centralus --template-file infra/main.bicep` with `what-if` gate on PR.
- **`apps.yml`** — builds .NET artifacts, publishes web app via `azure/webapps-deploy@v3`, copies FileGenerator + ingestion to VM via `az vm run-command invoke`.
- **OIDC federated credential** to a service principal scoped to the resource group.

### 8.2 Cost Guardrails
- No auto-shutdown (per customer direction). Operator stops the VM between demos
  (SQL Server stops with it).
- Tag all resources `demo=f1-nbcu`, `owner=eric.wilson@microsoft.com`, `auto-stop=manual`.

### 8.3 Key Vault hardening (added v0.4)
- `pe-kv-f1demo-wr4dcd` private endpoint in `snet-pe` (10.20.3.4).
- `publicNetworkAccess: Disabled`, `networkAcls.defaultAction: Deny`.
- App Service reaches KV via VNet integration → `snet-appsvc-int` → `snet-pe`.
- VM reaches KV via direct VNet route → `snet-pe`.
- DNS A record `kv-f1demo-wr4dcd.privatelink.vaultcore.azure.net` → 10.20.3.4
  resolves correctly from both consumers (verified).
- This survives MCAPS auto-disable cycles that previously broke the demo.

---

## 9. Demo Storyline (for Mike)

1. **The architecture** — open the Bicep module map; show how an enterprise three-tier looks in Central US.
2. **The legacy tier** — RDP to the Windows Server, show the running
   `F1FileGenerator` Windows service and the local SQL Server install.
3. **Trigger ingestion** — run `run-ingest.ps1 --year 2026 --events 1`;
   watch Prometheus counters climb in Grafana.
4. **The web app** — open `/race/2026/1` (Australia). Walk the
   lap-time distribution (consistency story) and the tyre stint Gantt
   (strategy story) together — these tell more than the position chart
   does on its own.
5. **Telemetry deep-dive** — `/lap-explorer` overlay Verstappen vs Norris
   on Suzuka lap 30; show the speed/throttle traces.
6. **The SRE moment** — break something (`Stop-Service F1FileGenerator`
   from RDP), refresh the web app, ask the **Observability Agent** *"what's
   wrong with the F1 demo?"* — it pulls from Log Analytics + Monitor
   Workspace and points at the failed service.

---

## 10. Acceptance Criteria

- [x] `scripts/deploy-infra.sh` provisions every resource in Central US from a clean subscription.
- [x] Ingestion of 2026 rounds 1–3 with telemetry completes in <10 minutes (achieved: ~9 minutes, 3.9 M rows).
- [x] Web app loads `/race/2026/1` in < 5 seconds (cold cache) and < 500 ms (warm cache).
- [x] FileGenerator + Web both connect to KV via the private endpoint (verified after `publicNetworkAccess=Disabled`).
- [x] Tear-down: `az group delete` + `az keyvault purge` removes everything.
- [ ] **All three tiers emit metrics visible in the Azure Monitor Workspace** — partial; FileGen exposes `/metrics`, ingestion exposes `:9101`, but managed Prometheus scrape configs not yet wired.
- [ ] **Observability Agent can answer "show me FileGenerator errors in the last hour"** — demo-ready storyline; needs Phase 1–3 work in §11.

---

## 11. Open Items / Roadmap

Resolved since v0.2:
- ~~**FastF1 license**~~ — confirmed MIT, attribution in README.
- ~~**Self-signed cert vs Let's Encrypt** for FileGenerator~~ — self-signed PFX
  generated by `deploy-filegenerator.ps1` at `D:\f1demo\certs\filegen.pfx`
  (5-year validity); App Service trusts via `WEBSITE_LOAD_ROOT_CERTIFICATES=*`.
- ~~**Telemetry sampling**~~ — ingesting at full rate; 3.9 M rows for 3 races
  is well under storage limits.

Still open / next phases:
- **OpenTelemetry tracing end-to-end** (Web → FileGen → SQL with shared
  `traceparent`); biggest unlock for the Observability Agent demo.
- **Custom Prometheus metrics + alerts**: per-endpoint p50/p95/p99 latency,
  SQL query duration, cache hit/miss ratio, ingestion freshness gauge.
- **Failure-injection scripts** (`scripts/break-service.ps1`,
  `heal-service.ps1`) to make the SRE moment repeatable on demand.
- **Azure Monitor Workbook** with three-tier health + latency drill-down +
  ingestion freshness panels.
- **Grafana** — Azure Managed Grafana for the polish; deferred until OTEL
  metrics land.

---

## 12. Glossary

| Term | Meaning |
|------|---------|
| FastF1 | Open-source Python library exposing the official F1 timing API and telemetry. |
| SQL Server (Dev Edition) | Free, full-featured SQL Server SKU for non-production use. Installed on the demo VM as the data tier. |
| AMA | Azure Monitor Agent — unified data collection agent for VMs. |
| DCR | Data Collection Rule — declarative config for AMA. |
| AMW | Azure Monitor Workspace — managed Prometheus backend. |
| Observability Agent | Microsoft's SRE/incident assistant grounded in Monitor + Log Analytics. |
