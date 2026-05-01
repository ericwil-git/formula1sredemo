# F1 Insights Web

ASP.NET Core 8 Blazor Server app, deployed to Azure App Service Linux B2.
**Anonymous** — no authentication.

Reads from the FileGenerator over the VNet (`https://<vm-private-ip>:8443`)
using a static API key sourced from Key Vault.

## Pages

| Route | Component |
|-------|-----------|
| `/` | Season browser (default 2024) |
| `/race/{year}/{round}` | Race results table + position chart |
| `/qualifying/{year}/{round}` | Q1/Q2/Q3 grid + delta-to-pole |
| `/lap-explorer` | Telemetry overlay for one lap |
| `/compare` | Two-driver lap-time overlay |

## Configuration

App settings (Key Vault references in production):

| Key | Source |
|-----|--------|
| `FileGenerator__BaseUrl` | App setting (set by Bicep to VM private IP) |
| `FileGenerator__ApiKey` | `@Microsoft.KeyVault(VaultName=...;SecretName=fileGeneratorApiKey)` |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | App setting (from monitoring module output) |

## Build & run

```bash
dotnet build
dotnet run --project src/web
```

## Status

Pages render placeholder data returned by the FileGenerator endpoints. Real
table layout / Chart.js bindings are marked `<!-- TODO(spec §7) -->`.
