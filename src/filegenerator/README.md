# F1.FileGenerator

.NET 8 minimal API that runs on the Windows Server middle tier. Implements the
contract in [`docs/techspec.md`](../../docs/techspec.md) §6.

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/files/race` | Lap-by-lap race results (CSV/JSON). |
| GET | `/files/qualifying` | Q1/Q2/Q3 with delta-to-pole. |
| GET | `/files/lap-detail` | Telemetry samples for a single lap. |
| GET | `/files/season` | Event calendar. |
| GET | `/health` | Liveness + SQL MI reachability. |
| GET | `/metrics` | Prometheus exposition. |

All `/files/*` endpoints require `X-Api-Key` header. `/health` and `/metrics`
are unauthenticated (assumed reachable only from inside the VNet).

## Configuration

| Key | Default | Source |
|-----|---------|--------|
| `FileGenerator:ApiKey` | — | Key Vault `fileGeneratorApiKey` |
| `FileGenerator:SqlConnectionString` | — | Key Vault `sqlConnectionString` |
| `CacheDirectory` | `D:\f1-files` | appsettings.json |
| `LogDirectory` | `D:\f1-files\logs` | appsettings.json (picked up by AMA) |

## Build & run

```bash
dotnet build
dotnet run --project src/filegenerator
```

The service listens on `https://0.0.0.0:8443` with the ASP.NET Core dev cert
locally and a self-signed cert on the VM.

## Status

Endpoints currently return shaped placeholder data so the web tier can render
end-to-end. The SQL queries are documented inline as `// TODO(spec §6)` blocks
ready to be filled in.
