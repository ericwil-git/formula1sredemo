# Formula 1 SRE Demo

A three-tier Azure reference application themed around Formula 1, built to demonstrate enterprise patterns and SRE/observability story-telling for **NBCUniversal Sports**.

> **Status:** v0.4 — fully deployed and running real 2026 race data.
> **Owner:** Eric Wilson — Principal Cloud Solution Architect, Microsoft
> **Region:** Central US
> **Live demo:** <https://app-f1demo-wr4dcd.azurewebsites.net>

---

## What this demo shows

A modern web tier (Azure App Service) consuming flat-file / tabular data produced by a Windows Server middle tier (IaaS) backed by **SQL Server 2022 Developer Edition** running on the same VM — instrumented end-to-end with Azure Monitor, managed Prometheus, and the Observability Agent.

The data is real Formula 1 timing and telemetry from the open-source [FastF1](https://docs.fastf1.dev/api_reference/index.html) library — so the demo is grounded in something a sports-media audience will recognize instantly.

```
                                                 Central US
+------------------+   HTTPS (VNet integration)  +-----------------------------+
|  Azure App       |   ------------------------> |  Windows Server 2022 VM     |
|  Service (Linux) |   8443/private IP           |  - F1.FileGenerator (svc)   |
|  ASP.NET Core 8  |                             |  - SQL Server 2022 Dev Ed.  |
|  Blazor Server   |                             |  - F1.Ingestion (Python)    |
|  anonymous       |                             |  - Azure Monitor Agent      |
+--------+---------+                             |  - windows_exporter         |
         |                                       +--+--------------------------+
         | Key Vault refs (private endpoint)        |
         v                                          | localhost:1433 (sa)
+--------+---------+                                v
|  Key Vault        |                       +-------+----------+
|  RBAC, secrets    |                       |  f1demo (SQL DB) |
|  PE in snet-pe    |                       |  3.9 M tele rows |
+-------------------+                       +------------------+
         ^                                          |
         |                                          | diagnostic settings
         +------------------------------------------+
                          |
                          v
                  Log Analytics + Application Insights
                  + Azure Monitor Workspace (managed Prometheus)
                  + Observability Agent (SRE assistant)
```

Full architecture, sequence diagrams, and component contracts live in **[`docs/techspec.md`](docs/techspec.md)**.

> ### Why SQL Server on the VM and not SQL MI?
> The original spec called for Azure SQL Managed Instance. The MCAPS subscription enforces an AAD-only-authentication deny policy on SQL MI that cannot be disabled, and the SQL MI's own MI cannot be granted Entra Directory Readers in this tenant. We pivoted to SQL Server 2022 Developer Edition installed on the VM (free, no licensing) — one less Azure-managed surface to fight, same on-prem-style story for an SRE migration narrative. See `docs/techspec.md` §3.1 for the full record.

---

## Repository layout

```
/infra
  main.bicep                          # subscription scope: creates RG + invokes modules
  modules/
    network.bicep                     # VNet, 4 subnets, NSGs, private DNS zones
    vm.bicep                          # Win Server 2022 + AMA + DCR association
    appservice.bicep                  # plan, app, VNet integration, KV refs
    keyvault.bicep                    # KV with RBAC, role assignments, private endpoint
    monitoring.bicep                  # Log Analytics + AppInsights + Monitor Workspace + DCR + alert
  parameters/
    dev.bicepparam
/src
  /ingestion                          # Python 3.11 — FastF1 → SQL Server (pyodbc + fast_executemany)
  /filegenerator                      # .NET 8 minimal API on the VM (Windows service)
  /web                                # ASP.NET Core 8 Blazor Server app (App Service)
/db
  schema.sql                          # 8 tables + 3 indexes
  seed.sql                            # placeholder seed
/scripts
  deploy-infra.sh                     # one-shot infra deploy (generates secrets, runs az deployment)
  install-vm-deps.ps1                 # bootstraps the VM (Python, .NET runtime, ODBC 18, SQL Server)
  deploy-filegenerator.ps1            # full FileGenerator deploy from scratch on the VM
  finish-filegenerator-deploy.ps1     # publish + service install (when source is already on disk)
  run-ingest.ps1                      # operator wrapper around f1-ingest CLI
/docs
  techspec.md                         # technical spec (source of truth)
/.github/workflows
  infra.yml                           # OIDC login, what-if on PR, deploy on main
  apps.yml                            # build .NET, deploy web via webapps-deploy + copy to VM
```

---

## Tech stack

| Tier | Technology |
|------|------------|
| Web | ASP.NET Core 8 Blazor Server, Chart.js (5 charts incl. lap-time box plot, tyre stint Gantt, Q1→Q3 progression) |
| Middle | Windows Server 2022, .NET 8 minimal API (`F1FileGenerator` service), Python 3.11 + FastF1 |
| Data | **SQL Server 2022 Developer Edition** (on the VM), `f1demo` database, mixed-mode auth |
| Secrets | Key Vault with RBAC + **private endpoint** in `snet-pe` |
| IaC | Bicep |
| CI/CD | GitHub Actions with OIDC federated credentials |
| Observability | Azure Monitor Agent, Azure Monitor Workspace (managed Prometheus), Log Analytics, Application Insights, Observability Agent |

---

## Prerequisites

- Azure subscription with rights to create resource groups, VMs, and App Services in Central US
- Azure CLI ≥ 2.60
- .NET 8 SDK (for local web/filegenerator builds)
- Python 3.11 (for local ingestion testing)
- An OIDC-enabled service principal for the GitHub Actions workflows (optional — manual deploy works too)
- VSCode with the GitHub Copilot extension

---

## Deploy from scratch

> **Warning: irreversible.** This creates a new resource group, VM, App Service, Key Vault, and ~30 supporting resources. Resources are tagged `demo=f1-nbcu` for easy cleanup.

```bash
# 1. Sign in
az login
az account set --subscription <subscription-id>

# 2. Generate secrets and run the deployment.
#    deploy-infra.sh stages secrets in /tmp/f1demo-secrets/ for re-use.
./scripts/deploy-infra.sh

# 3. Bootstrap the VM (installs Python 3.11, .NET 8 runtime, ODBC Driver 18,
#    SQL Server 2022 Developer Edition, applies db/schema.sql).
SQL_SA_PWD=$(cat /tmp/f1demo-secrets/sqlpwd)
az vm run-command invoke \
  -g rg-f1demo-centeral -n vm-f1demo-win \
  --command-id RunPowerShellScript \
  --scripts @scripts/install-vm-deps.ps1 \
  --parameters "SqlSaPassword=$SQL_SA_PWD"

# 4. Deploy the FileGenerator (Windows service, KV-backed config).
KV_URI="https://kv-f1demo-wr4dcd.vault.azure.net/"
az vm run-command invoke \
  -g rg-f1demo-centeral -n vm-f1demo-win \
  --command-id RunPowerShellScript \
  --scripts @scripts/deploy-filegenerator.ps1 \
  --parameters "KeyVaultUri=$KV_URI"

# 5. Build + deploy the web app to App Service.
dotnet publish src/web/Web.csproj -c Release -o publish/web
(cd publish/web && zip -rq ../web.zip .)
az webapp deploy -g rg-f1demo-centeral -n app-f1demo-wr4dcd \
  --src-path publish/web.zip --type zip
```

Detailed parameter shapes are in [`docs/techspec.md`](docs/techspec.md) §8.

---

## Seed the database with race data

```bash
# Trigger ingestion of 2026 rounds 1–3 with full telemetry.
# ~9 minutes, produces ~3.9 M telemetry rows + 7,752 laps.
SQL_SA_PWD=$(cat /tmp/f1demo-secrets/sqlpwd)
az vm run-command invoke \
  -g rg-f1demo-centeral -n vm-f1demo-win \
  --command-id RunPowerShellScript \
  --scripts @scripts/run-ingest-2026.ps1 \
  --parameters "SqlSaPassword=$SQL_SA_PWD"
```

Telemetry off keeps the load to ~1 minute per race. A full season with telemetry is roughly 30 M rows.

---

## What you can browse on the live site

| Page | What it shows |
|---|---|
| `/` | Season picker (default 2026); table of events with race/quali deep links |
| `/race/{year}/{round}` | Position-by-lap line chart, lap-time distribution box plot, tyre stint Gantt, lap-by-lap table; driver dropdown filter |
| `/qualifying/{year}/{round}` | Q1/Q2/Q3 grid, delta-to-pole bars, **Q1 → Q2 → Q3 progression** line chart; driver + session filters |
| `/lap-explorer` | Telemetry overlay (speed, throttle, brake, gear) for any driver/lap |
| `/compare` | Two-driver lap-time overlay across a race |

---

## Demo flow

1. **The architecture** — open `docs/techspec.md` § 2.1; show the three tiers in Central US.
2. **The legacy tier** — RDP to the VM, show the running `F1FileGenerator` service, the local SQL Server install, and the on-disk FastF1 cache + file cache.
3. **Trigger ingestion** — `run-ingest.ps1 --year 2026 --events 1` and watch Prometheus counters (`f1_ingest_rows_total{table=...}`, `f1_ingest_duration_seconds`) climb.
4. **The web app** — open `/race/2026/1` (Australia). Walk through the lap-time distribution (consistency story) and tyre stints (strategy story).
5. **Telemetry deep-dive** — `/lap-explorer` overlay Verstappen vs Norris on Suzuka lap 30; show the speed/throttle traces.
6. **The SRE moment** — stop the FileGenerator service (`Stop-Service F1FileGenerator` from RDP), reload the web app, and ask the **Observability Agent**: *"what's wrong with the F1 demo?"* — it pulls from Log Analytics + Monitor Workspace and points at the failed service.

Full storyline in [`docs/techspec.md`](docs/techspec.md) §9.

---

## Operational notes

| Concern | How it's handled |
|---|---|
| **Key Vault private endpoint** | `pe-kv-f1demo-wr4dcd` in `snet-pe` (10.20.3.4); `publicNetworkAccess: Disabled`. Survives MCAPS auto-disable cycles. |
| **VM secrets** | Mock'd at deploy time, stored in KV; FileGenerator reads via VM MI + `Azure.Extensions.AspNetCore.Configuration.Secrets`. |
| **HTTPS on FileGenerator** | Self-signed PFX at `D:\f1demo\certs\filegen.pfx` (5-year validity). App Service trusts via `WEBSITE_LOAD_ROOT_CERTIFICATES=*`. |
| **Service recovery** | `F1FileGenerator` SCM recovery: restart on failure (30s, 30s, 60s, daily reset). |
| **Cache** | FileGenerator caches CSV/JSON responses to `D:\f1-files\` with 1-hour TTL. Bust by `Get-ChildItem D:\f1-files\*.csv,*.json | Remove-Item`. |
| **Cost guard-rails** | No auto-shutdown by design (operator stops the VM between demos). All resources tagged `auto-stop=manual`. |

---

## Tear down

```bash
# Soft delete (KV + AMA take longest)
az group delete -n rg-f1demo-centeral --yes --no-wait

# Clean up the soft-deleted Key Vault so the name is reusable
az keyvault purge --name kv-f1demo-wr4dcd --location centralus
```

---

## Contributing & Copilot guidance

This repo was built collaboratively with GitHub Copilot. The technical spec is the source of truth — when prompting Copilot for code, point it at the relevant section of `docs/techspec.md`.

When in doubt, prefer:
- **Bicep** over ARM JSON
- **Managed identity** over connection-string auth (with the noted MCAPS exception for SQL Server `sa`)
- **Private endpoints** over public IPs
- **Structured JSON logs** over plain text

---

## Disclaimer

This is a Microsoft-internal customer demo. Formula 1 data is sourced via the [FastF1](https://github.com/theOehrly/Fast-F1) library (MIT license). F1, Formula 1, and team / driver names are trademarks of their respective owners and are used here for non-commercial demonstration purposes only.

---

## Contact

**Eric Wilson** — eric.wilson@microsoft.com
Principal Cloud Solution Architect, Microsoft
