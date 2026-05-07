# Failure injection scripts

Each pair (`break/X.sh` + `heal/X.sh`) is the trigger for one scripted demo
scenario. They invoke a single PowerShell one-liner on the demo VM via
`az vm run-command invoke`, so they require an active `az login` and the
default subscription set to the demo subscription. No state lives in the
script — they're idempotent.

| Scenario | Break | Heal | Detection time | What the agent should say |
|---|---|---|---|---|
| FileGenerator down | `break/filegen.sh` | `heal/filegen.sh` | ~30s (web 502s)<br>~5m (alerts) | "FileGenerator service is stopped on `vm-f1demo-win`. Restart `F1FileGenerator`." |
| SQL Server down | `break/sql.sh` | `heal/sql.sh` | ~30s (`/health` flips)<br>~5m (sql-errors alert) | "SQL Server is stopped. `/health` returns `unreachable`. Restart `MSSQLSERVER`." |
| Slow query | `break/slow-query.sh` | `heal/slow-query.sh` | ~3m (p99 alert) | "FileGenerator p99 > 2s. SQL query duration is the long-tail. Cancel the offending query loop." |
| Disk filling | `break/disk-fill.sh` | `heal/disk-fill.sh` | ~10m (perf counter) | "`D:` free space < 10%. Look at `D:\f1-files\big.bin`." |
| Stale data | `break/stale-data.sh` | `heal/stale-data.sh` | ~25h on its own; demo path: ~5m | "No `f1_ingest_runs` heartbeat in 24h. Re-run ingestion." |

## Demo flow

```
./break/filegen.sh
# wait 60s, refresh https://app-f1demo-wr4dcd.azurewebsites.net/race/2026/3
# observe 502
# ask the SRE Agent: "what's wrong with the F1 demo?"
# observe diagnosis
./heal/filegen.sh
# wait ~30s, refresh — recovered
```

Full step-by-step in [`docs/sre-demo.md`](../../docs/sre-demo.md).

## Safety

- `break/disk-fill.sh` writes a 50 GB file to `D:\f1-files\big.bin`. Always
  pair with `heal/disk-fill.sh`. The heal script is also safe to run
  proactively.
- `break/slow-query.sh` runs an unbounded `SELECT * FROM dbo.Telemetry` loop
  via `Start-Job`. The heal script kills jobs by name; if it fails, RDP in
  and `Get-Process powershell | Stop-Process -Force` is the nuclear option.
- All scripts target `rg-f1demo-centeral` / `vm-f1demo-win`. Hardcoded on
  purpose — there is exactly one demo environment.
