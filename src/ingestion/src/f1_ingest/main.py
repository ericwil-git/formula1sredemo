"""Entry point for the F1 ingestion service.

Usage:
    f1-ingest --year 2024 --events all --telemetry true
    f1-ingest --year 2024 --events monaco --telemetry false
"""

from __future__ import annotations

import argparse
import json
import logging
import math
import os
import sys
import time
from dataclasses import dataclass
from typing import Iterator, Sequence

import pandas as pd

from . import metrics
from .fastf1_loader import FastF1Loader
from .sql_writer import SqlWriter

LOG = logging.getLogger("f1_ingest")


@dataclass(frozen=True)
class IngestionConfig:
    year: int
    events: str
    telemetry: bool
    cache_dir: str
    sql_connection_string: str
    metrics_port: int


# ---------------------------------------------------------------------------
# argparse / logging
# ---------------------------------------------------------------------------

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
                        help="ODBC connection string to SQL Server (or set F1_SQL_CONNECTION_STRING).")
    parser.add_argument("--metrics-port", type=int,
                        default=int(os.environ.get("F1_METRICS_PORT", "9101")),
                        help="Prometheus exposition port.")
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


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _td_to_ms(td) -> int | None:
    """pandas.Timedelta -> int milliseconds, or None for NaT."""
    if td is None or pd.isna(td):
        return None
    return int(td.total_seconds() * 1000)


def _safe_int(v) -> int | None:
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return None
    try:
        return int(v)
    except (ValueError, TypeError):
        return None


def _safe_float(v) -> float | None:
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return None
    try:
        return float(v)
    except (ValueError, TypeError):
        return None


def _safe_str(v) -> str | None:
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return None
    s = str(v).strip()
    return s if s else None


# ---------------------------------------------------------------------------
# core ingestion
# ---------------------------------------------------------------------------

def _telemetry_iter(lap_id_by_pair: dict, session) -> Iterator[dict]:
    """Yield telemetry sample dicts across every lap of the session.

    Streams one row at a time; the writer batches into 10k-row chunks before
    committing. Skips laps with no car-data.
    """
    laps = session.laps
    for _, lap in laps.iterrows():
        try:
            tel = lap.get_car_data()
        except Exception:
            continue
        if tel is None or tel.empty:
            continue

        # Driver number/code lookup via session.get_driver
        try:
            d_info = session.get_driver(lap["Driver"])
            code = d_info.get("Abbreviation") or lap["Driver"]
        except Exception:
            code = lap["Driver"]

        driver_id = lap_id_by_pair.get("__drivers__", {}).get(str(code))
        if driver_id is None:
            continue
        lap_number = _safe_int(lap.get("LapNumber"))
        if lap_number is None:
            continue
        lap_id = lap_id_by_pair.get((driver_id, lap_number))
        if lap_id is None:
            continue

        # FastF1 normalizes a Time column (Timedelta from session start).
        for _, row in tel.iterrows():
            t = row.get("Time")
            sample_ms = _td_to_ms(t)
            if sample_ms is None:
                continue
            yield {
                "lap_id": lap_id,
                "sample_time_ms": sample_ms,
                "speed_kph": _safe_int(row.get("Speed")),
                "rpm": _safe_int(row.get("RPM")),
                "throttle": _safe_int(row.get("Throttle")),
                "brake": bool(row.get("Brake")) if row.get("Brake") is not None else None,
                "gear": _safe_int(row.get("nGear") if "nGear" in row else row.get("Gear")),
                "drs": _safe_int(row.get("DRS")),
            }


def _ingest_session(session, season_id: int, event_id: int,
                    writer: SqlWriter, telemetry: bool) -> None:
    db_type = getattr(session, "_db_session_type", None)
    if db_type is None:
        return

    LOG.info("session %s start_utc=%s laps=%s",
             db_type, session.date, getattr(session, "total_laps", None))

    # 1. drivers (per session, idempotent across the season)
    drivers_in_session: list[dict] = []
    seen_codes: set[str] = set()
    for drv in session.drivers:
        try:
            info = session.get_driver(drv)
        except Exception:
            continue
        code = (info.get("Abbreviation") or "").strip()
        if not code or code in seen_codes:
            continue
        seen_codes.add(code)
        drivers_in_session.append({
            "code": code,
            "full_name": (
                f"{info.get('FirstName', '').strip()} {info.get('LastName', '').strip()}".strip()
                or info.get("FullName") or code
            ),
            "team": info.get("TeamName") or "",
        })
    drivers_by_code = writer.upsert_drivers(season_id, drivers_in_session)
    metrics.rows_total.labels(table="Drivers").inc(len(drivers_in_session))

    # 2. session row (clears children)
    session_id = writer.replace_session(
        event_id=event_id,
        session_type=db_type,
        start_time_utc=session.date,
        total_laps=_safe_int(getattr(session, "total_laps", None)),
    )

    # 3. laps
    lap_rows: list[dict] = []
    for _, l in session.laps.iterrows():
        code = _safe_str(l.get("Driver"))
        if code is None:
            continue
        driver_id = drivers_by_code.get(code)
        if driver_id is None:
            continue
        lap_rows.append({
            "driver_id": driver_id,
            "lap_number": _safe_int(l.get("LapNumber")),
            "lap_time_ms": _td_to_ms(l.get("LapTime")),
            "sector1_ms": _td_to_ms(l.get("Sector1Time")),
            "sector2_ms": _td_to_ms(l.get("Sector2Time")),
            "sector3_ms": _td_to_ms(l.get("Sector3Time")),
            "compound": _safe_str(l.get("Compound")),
            "tyre_life": _safe_int(l.get("TyreLife")),
            "position": _safe_int(l.get("Position")),
            "is_personal_best": bool(l.get("IsPersonalBest"))
                if l.get("IsPersonalBest") is not None else False,
        })
    lap_id_by_pair = writer.insert_laps(session_id, lap_rows)
    lap_id_by_pair["__drivers__"] = drivers_by_code   # type: ignore[index]
    metrics.rows_total.labels(table="Laps").inc(len(lap_rows))
    LOG.info("inserted %d laps", len(lap_rows))

    # 4. results
    if db_type == "Q":
        rows = []
        for _, r in session.results.iterrows():
            code = _safe_str(r.get("Abbreviation"))
            d = drivers_by_code.get(code) if code else None
            if d is None:
                continue
            rows.append({
                "driver_id": d,
                "position": _safe_int(r.get("Position")),
                "q1_ms": _td_to_ms(r.get("Q1")),
                "q2_ms": _td_to_ms(r.get("Q2")),
                "q3_ms": _td_to_ms(r.get("Q3")),
            })
        n = writer.insert_quali_results(session_id, rows)
        metrics.rows_total.labels(table="QualiResults").inc(n)
    elif db_type in ("R", "Sprint"):
        rows = []
        for _, r in session.results.iterrows():
            code = _safe_str(r.get("Abbreviation"))
            d = drivers_by_code.get(code) if code else None
            if d is None:
                continue
            rows.append({
                "driver_id": d,
                "position": _safe_int(r.get("Position")),
                "grid_position": _safe_int(r.get("GridPosition")),
                "status": _safe_str(r.get("Status")),
                "points": _safe_float(r.get("Points")),
                "fastest_lap_ms": None,  # FastF1 doesn't provide this directly here
            })
        n = writer.insert_race_results(session_id, rows)
        metrics.rows_total.labels(table="RaceResults").inc(n)

    # 5. telemetry (optional, big)
    if telemetry:
        n = writer.bulk_insert_telemetry(_telemetry_iter(lap_id_by_pair, session))
        metrics.rows_total.labels(table="Telemetry").inc(n)
        LOG.info("inserted %d telemetry samples", n)


# ---------------------------------------------------------------------------
# orchestration
# ---------------------------------------------------------------------------

def run(config: IngestionConfig) -> int:
    LOG.info("Starting ingestion year=%s events=%s telemetry=%s",
             config.year, config.events, config.telemetry)

    metrics.start_server(config.metrics_port)
    started = time.monotonic()

    loader = FastF1Loader(cache_dir=config.cache_dir)
    writer = SqlWriter(connection_string=config.sql_connection_string)

    try:
        with metrics.duration_seconds.time():
            schedule = loader.get_schedule(config.year)
            schedule = loader.select_events(schedule, config.events)
            LOG.info("processing %d event(s)", len(schedule))

            season_id = writer.get_season_id(config.year)

            for _, event in schedule.iterrows():
                round_no = int(event["RoundNumber"])
                event_id = writer.get_event_id(
                    season_id=season_id,
                    round_number=round_no,
                    country=str(event.get("Country", "")),
                    location=str(event.get("Location", "")),
                    event_name=str(event["EventName"]),
                    event_date=event["EventDate"].to_pydatetime().date()
                        if hasattr(event["EventDate"], "to_pydatetime") else event["EventDate"],
                )
                LOG.info("event round=%d %s (EventId=%d)",
                         round_no, event["EventName"], event_id)

                for session in loader.iter_sessions(config.year, round_no, config.telemetry):
                    try:
                        _ingest_session(session, season_id, event_id, writer, config.telemetry)
                    except Exception:
                        metrics.errors_total.inc()
                        LOG.exception("session failed; continuing")

        elapsed = time.monotonic() - started
        LOG.info("Ingestion finished in %.2fs.", elapsed)
        return 0
    except Exception:
        metrics.errors_total.inc()
        LOG.exception("Ingestion failed.")
        return 1
    finally:
        writer.close()


def cli() -> None:
    _configure_logging()
    config = _parse_args()
    sys.exit(run(config))


if __name__ == "__main__":
    cli()
