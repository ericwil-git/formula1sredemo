# f1_ingest

Python 3.11 service that pulls historical F1 sessions from
[FastF1](https://docs.fastf1.dev/) and bulk-inserts them into Azure SQL MI.
Runs on the Windows Server middle tier (see [`docs/techspec.md`](../../docs/techspec.md) §3.2).

## Install

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -e .
```

## Run

```powershell
$env:F1_SQL_CONNECTION_STRING = "Driver={ODBC Driver 18 for SQL Server};Server=tcp:<mi>.database.windows.net,1433;Database=f1demo;UID=f1adm;PWD=...;Encrypt=yes;TrustServerCertificate=no;"
f1-ingest --year 2024 --events monaco --telemetry true
```

## Status

Argparse, structured-JSON logging, Prometheus counters, and connection-string
plumbing are real. FastF1 calls and pyodbc bulk inserts are stubbed; see the
`# TODO(spec §5.1)` markers in `fastf1_loader.py` and `sql_writer.py`.

## Metrics

Exposed on `:9101/metrics`:

| Metric | Type | Labels |
|--------|------|--------|
| `f1_ingest_rows_total` | counter | `table` |
| `f1_ingest_duration_seconds` | histogram | — |
| `f1_ingest_errors_total` | counter | — |
