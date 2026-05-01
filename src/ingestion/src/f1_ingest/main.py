"""Entry point for the F1 ingestion service.

Usage:
    f1-ingest --year 2024 --events all --telemetry true
    f1-ingest --year 2024 --events monaco --telemetry false
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
from dataclasses import dataclass
from typing import Sequence

from . import metrics
from .fastf1_loader import FastF1Loader
from .sql_writer import SqlWriter

LOG = logging.getLogger("f1_ingest")


@dataclass(frozen=True)
class IngestionConfig:
    year: int
    events: str           # "all" or comma-separated event names / rounds
    telemetry: bool
    cache_dir: str
    sql_connection_string: str
    metrics_port: int


def _configure_logging() -> None:
    """Structured-JSON logs to stdout — picked up by AMA on the VM."""
    handler = logging.StreamHandler(sys.stdout)

    class _JsonFormatter(logging.Formatter):
        def format(self, record: logging.LogRecord) -> str:  # noqa: D401
            payload = {
                "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
                "level": record.levelname,
                "logger": record.name,
                "message": record.getMessage(),
            }
            if record.exc_info:
                payload["exc"] = self.formatException(record.exc_info)
            return json.dumps(payload)

    handler.setFormatter(_JsonFormatter())
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(logging.INFO)


def _parse_args(argv: Sequence[str] | None = None) -> IngestionConfig:
    parser = argparse.ArgumentParser(prog="f1-ingest")
    parser.add_argument("--year", type=int, required=True, help="Season year, e.g. 2024.")
    parser.add_argument("--events", type=str, default="all",
                        help='"all" or comma-separated event names / rounds (e.g. "monaco,8").')
    parser.add_argument("--telemetry", type=str, default="true",
                        help="true/false — include per-sample telemetry.")
    parser.add_argument("--cache-dir", type=str,
                        default=os.environ.get("FASTF1_CACHE", r"D:\fastf1-cache"),
                        help="FastF1 cache directory.")
    parser.add_argument("--sql-connection-string", type=str,
                        default=os.environ.get("F1_SQL_CONNECTION_STRING", ""),
                        help="ODBC connection string to SQL MI (or set F1_SQL_CONNECTION_STRING).")
    parser.add_argument("--metrics-port", type=int,
                        default=int(os.environ.get("F1_METRICS_PORT", "9101")),
                        help="Prometheus exposition port (textfile collector also supported).")
    args = parser.parse_args(argv)

    if not args.sql_connection_string:
        parser.error("--sql-connection-string (or env F1_SQL_CONNECTION_STRING) is required.")

    return IngestionConfig(
        year=args.year,
        events=args.events,
        telemetry=str(args.telemetry).lower() in ("1", "true", "yes"),
        cache_dir=args.cache_dir,
        sql_connection_string=args.sql_connection_string,
        metrics_port=args.metrics_port,
    )


def run(config: IngestionConfig) -> int:
    """Run the ingestion. Returns process exit code."""
    LOG.info("Starting ingestion for year=%s events=%s telemetry=%s",
             config.year, config.events, config.telemetry)

    metrics.start_server(config.metrics_port)

    started = time.monotonic()
    try:
        loader = FastF1Loader(cache_dir=config.cache_dir)
        writer = SqlWriter(connection_string=config.sql_connection_string)

        # TODO(spec §5.1): implement event/session iteration.
        #   1. season = loader.get_season(config.year)
        #   2. events = loader.select_events(season, config.events)
        #   3. for each event, for each session:
        #        load laps, drivers, results
        #        if config.telemetry: load per-lap telemetry
        #        writer.upsert_seasons / events / sessions / drivers / laps
        #        if telemetry: writer.bulk_insert_telemetry (10 000-row batches)
        #   4. on each batch, increment metrics.rows_total and metrics.duration_seconds.

        with metrics.duration_seconds.time():
            LOG.info("Ingestion stub complete (no data written; see TODOs in main.run).")
            metrics.rows_total.labels(table="stub").inc(0)

        elapsed = time.monotonic() - started
        LOG.info("Ingestion finished in %.2fs.", elapsed)
        return 0
    except Exception:
        metrics.errors_total.inc()
        LOG.exception("Ingestion failed.")
        return 1


def cli() -> None:
    _configure_logging()
    config = _parse_args()
    sys.exit(run(config))


if __name__ == "__main__":
    cli()
