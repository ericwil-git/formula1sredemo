# Formula 1 SRE Demo

A three-tier Azure reference application themed around Formula 1, built to demonstrate enterprise patterns for **NBCUniversal Sports**.

> **Status:** in development — Bicep + app code being scaffolded with VSCode + GitHub Copilot.
> **Owner:** Eric Wilson — Principal Cloud Solution Architect, Microsoft
> **Region:** Central US

---

## What this demo shows

A modern web tier (Azure App Service) consuming flat-file / tabular data produced by a Windows Server middle tier (IaaS) backed by Azure SQL Managed Instance — instrumented end-to-end with Azure Monitor, managed Prometheus, and the Observability Agent.

The data is real Formula 1 timing and telemetry from the open-source [FastF1](https://docs.fastf1.dev/api_reference/index.html) library — so the demo is grounded in something a sports-media audience will recognize instantly.

```
+------------------+        HTTPS         +-------------------------+
|  Azure App       |  -- pulls files -->  |  Windows Server (VM)    |
|  Service         |                      |  - File Generator Svc   |
|  (anonymous)     |                      |  - FastF1 Ingestion Svc |
+------------------+                      +-----------+-------------+
                                                      |
                                                      v
                                          +-------------------------+
                                          |  Azure SQL Managed      |
                                          |  Instance               |
                                          +-------------------------+
                                                      |
                                                      v
                                  Azure Monitor Workspace + Log Analytics
                                  + Observability Agent
```

Full architecture, sequence diagrams, and component contracts live in **[`docs/techspec.md`](docs/techspec.md)**.

---

## Repository layout

```
/infra              Bicep templates (network, SQL MI, VM, App Service, monitoring, Key Vault)
/src
  /ingestion        Python — FastF1 → SQL MI
  /filegenerator    .NET 8 minimal API on the Windows Server VM
  /web              ASP.NET Core 8 Blazor Server app (App Service)
/db                 SQL DDL and seed data
/scripts            Operator scripts (run-ingest.ps1, install-vm-deps.ps1)
/docs               Technical spec, diagrams, demo runbook
/.github/workflows  infra.yml (Bicep what-if + deploy), apps.yml (build + deploy)
```

---

## Tech stack

| Tier | Technology |
|------|------------|
| Web | ASP.NET Core 8, Blazor Server, Chart.js |
| Middle | Windows Server 2022, .NET 8 minimal API, Python 3.11 + FastF1 |
| Data | Azure SQL Managed Instance (General Purpose, 4 vCore) |
| IaC | Bicep |
| CI/CD | GitHub Actions with OIDC federated credentials |
| Observability | Azure Monitor Agent, Azure Monitor Workspace (managed Prometheus), Log Analytics, Observability Agent |

---

## Prerequisites

- Azure subscription with rights to create resource groups, SQL MI, and VMs in Central US
- Azure CLI ≥ 2.60
- .NET 8 SDK
- Python 3.11
- An OIDC-enabled service principal for the GitHub Actions workflows
- VSCode with the GitHub Copilot extension (Opus or Sonnet)

---

## Deploy

> One command from a clean subscription. Resources are tagged `demo=f1-nbcu` for easy cleanup.

```bash
# 1. Sign in
az login
az account set --subscription <subscription-id>

# 2. Create the resource group
az group create -n rg-f1demo-cus -l centralus

# 3. Deploy infrastructure
az deployment group create \
  -g rg-f1demo-cus \
  -f infra/main.bicep \
  -p infra/parameters/dev.bicepparam

# 4. Deploy applications (or push to main and let GitHub Actions do it)
gh workflow run apps.yml
```

Detailed deployment, parameter shapes, and post-deploy steps are in [`docs/techspec.md`](docs/techspec.md) §8.

---

## Seed the database

After infrastructure is up, RDP to the Windows Server VM and run:

```powershell
cd D:\f1demo
.\run-ingest.ps1 --year 2024 --events all --telemetry true
```

A single season with telemetry is roughly 28M rows and lands in under ~30 minutes on the default sizing.

---

## Demo flow

1. Open the architecture diagram — explain the three tiers.
2. RDP to the VM, show the FileGenerator console and the Scheduled Task for ingestion.
3. Trigger an ingestion for a single race and watch Prometheus counters climb in Grafana.
4. Open the web app, navigate to **Race → 2024 → Monaco** — show the network call hitting the VM and the cached CSV on `D:\f1-files\`.
5. Open the **Lap Explorer** — overlay Verstappen vs Leclerc telemetry.
6. **The SRE moment** — stop the FileGenerator service, reload the page, and ask the **Observability Agent** *"what's wrong with the F1 demo?"* — it pulls from Log Analytics and Monitor Workspace and points at the failed service.

Full storyline in [`docs/techspec.md`](docs/techspec.md) §9.

---

## Tear down

There is no auto-shutdown — the operator stops resources between demos. To remove everything:

```bash
az group delete -n rg-f1demo-cus --yes --no-wait
```

---

## Contributing & Copilot guidance

This repo is intended to be built collaboratively with GitHub Copilot. The technical spec is the source of truth — when prompting Copilot for code, point it at the relevant section of `docs/techspec.md` (e.g. *"implement the Bicep module described in §8 for SQL MI"* or *"scaffold the FileGenerator endpoints from §6"*).

When in doubt, prefer:
- **Bicep** over ARM JSON
- **Managed identity** over connection-string auth
- **Private endpoints** over public IPs
- **Structured JSON logs** over plain text

---

## Disclaimer

This is a Microsoft-internal customer demo. Formula 1 data is sourced via the [FastF1](https://github.com/theOehrly/Fast-F1) library (MIT license). F1, Formula 1, and team / driver names are trademarks of their respective owners and are used here for non-commercial demonstration purposes only.

---

## Contact

**Eric Wilson** — eric.wilson@microsoft.com
Principal Cloud Solution Architect, Microsoft
