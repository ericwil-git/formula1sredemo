"""SQL Server bulk-insert wrapper using pyodbc + fast_executemany.

Idempotent: re-running ingestion for the same year/event/session is safe.
- Seasons / Events / Drivers use MERGE
- Sessions / Laps / Telemetry / *Results are deleted and re-inserted per session
"""

from __future__ import annotations

import logging
from contextlib import contextmanager
from dataclasses import dataclass, field
from typing import Iterable, Iterator, Sequence

import pyodbc

LOG = logging.getLogger("f1_ingest.sql_writer")


@dataclass
class SqlWriter:
    connection_string: str
    telemetry_batch_size: int = 10_000
    _conn: pyodbc.Connection | None = field(default=None, init=False, repr=False)

    @contextmanager
    def _connect(self) -> Iterator[pyodbc.Connection]:
        if self._conn is None:
            self._conn = pyodbc.connect(self.connection_string, autocommit=False)
        try:
            yield self._conn
        except Exception:
            self._conn.rollback()
            raise

    def close(self) -> None:
        if self._conn is not None:
            self._conn.close()
            self._conn = None

    # -------- ID lookup helpers ----------------------------------------

    def get_season_id(self, year: int) -> int:
        with self._connect() as c:
            cur = c.cursor()
            row = cur.execute("SELECT SeasonId FROM dbo.Seasons WHERE [Year] = ?", year).fetchone()
            if row:
                return int(row[0])
            cur.execute(
                "INSERT INTO dbo.Seasons ([Year], [Name]) OUTPUT INSERTED.SeasonId VALUES (?, ?)",
                year, f"{year} FIA Formula One World Championship",
            )
            new_id = int(cur.fetchone()[0])
            c.commit()
            return new_id

    def get_event_id(self, season_id: int, round_number: int, country: str,
                     location: str, event_name: str, event_date) -> int:
        with self._connect() as c:
            cur = c.cursor()
            row = cur.execute(
                "SELECT EventId FROM dbo.Events WHERE SeasonId = ? AND Round = ?",
                season_id, round_number,
            ).fetchone()
            if row:
                return int(row[0])
            cur.execute(
                """INSERT INTO dbo.Events
                       (SeasonId, Round, Country, Location, EventName, EventDate)
                   OUTPUT INSERTED.EventId
                   VALUES (?, ?, ?, ?, ?, ?)""",
                season_id, round_number, country, location, event_name, event_date,
            )
            new_id = int(cur.fetchone()[0])
            c.commit()
            return new_id

    def upsert_drivers(self, season_id: int, drivers: Sequence[dict]) -> dict[str, int]:
        """Upsert drivers by (season, code). Returns {code: DriverId}."""
        if not drivers:
            return {}
        with self._connect() as c:
            cur = c.cursor()
            for d in drivers:
                cur.execute(
                    """MERGE dbo.Drivers AS tgt
                       USING (SELECT ? AS Code, ? AS FullName, ? AS TeamName, ? AS SeasonId) AS src
                          ON tgt.SeasonId = src.SeasonId AND tgt.Code = src.Code
                       WHEN MATCHED THEN UPDATE SET FullName = src.FullName, TeamName = src.TeamName
                       WHEN NOT MATCHED THEN INSERT (Code, FullName, TeamName, SeasonId)
                            VALUES (src.Code, src.FullName, src.TeamName, src.SeasonId);""",
                    d["code"], d["full_name"], d["team"], season_id,
                )
            c.commit()
            cur.execute(
                "SELECT Code, DriverId FROM dbo.Drivers WHERE SeasonId = ?", season_id,
            )
            return {str(row[0]): int(row[1]) for row in cur.fetchall()}

    def replace_session(self, event_id: int, session_type: str,
                        start_time_utc, total_laps: int | None) -> int:
        """Delete + re-insert the session row + cascading children. Returns SessionId."""
        with self._connect() as c:
            cur = c.cursor()
            row = cur.execute(
                "SELECT SessionId FROM dbo.Sessions WHERE EventId = ? AND SessionType = ?",
                event_id, session_type,
            ).fetchone()
            if row:
                old = int(row[0])
                # Children with FKs; order matters.
                cur.execute(
                    "DELETE FROM dbo.Telemetry WHERE LapId IN "
                    "(SELECT LapId FROM dbo.Laps WHERE SessionId = ?)", old)
                cur.execute("DELETE FROM dbo.Laps WHERE SessionId = ?", old)
                cur.execute("DELETE FROM dbo.QualiResults WHERE SessionId = ?", old)
                cur.execute("DELETE FROM dbo.RaceResults WHERE SessionId = ?", old)
                cur.execute("DELETE FROM dbo.Sessions WHERE SessionId = ?", old)
            cur.execute(
                """INSERT INTO dbo.Sessions (EventId, SessionType, StartTimeUtc, TotalLaps)
                   OUTPUT INSERTED.SessionId
                   VALUES (?, ?, ?, ?)""",
                event_id, session_type, start_time_utc, total_laps,
            )
            new_id = int(cur.fetchone()[0])
            c.commit()
            return new_id

    # -------- bulk inserts ---------------------------------------------

    def insert_laps(self, session_id: int, laps: Sequence[dict]) -> dict[tuple[int, int], int]:
        """Insert laps; return {(driver_id, lap_number): LapId}."""
        if not laps:
            return {}
        with self._connect() as c:
            cur = c.cursor()
            cur.fast_executemany = True
            params = [
                (session_id, l["driver_id"], l["lap_number"], l.get("lap_time_ms"),
                 l.get("sector1_ms"), l.get("sector2_ms"), l.get("sector3_ms"),
                 l.get("compound"), l.get("tyre_life"), l.get("position"),
                 1 if l.get("is_personal_best") else 0)
                for l in laps
            ]
            cur.executemany(
                """INSERT INTO dbo.Laps
                   (SessionId, DriverId, LapNumber, LapTimeMs,
                    Sector1Ms, Sector2Ms, Sector3Ms, Compound, TyreLife,
                    Position, IsPersonalBest)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                params,
            )
            c.commit()
            cur.execute(
                "SELECT DriverId, LapNumber, LapId FROM dbo.Laps WHERE SessionId = ?",
                session_id,
            )
            return {(int(r[0]), int(r[1])): int(r[2]) for r in cur.fetchall()}

    def bulk_insert_telemetry(self, samples: Iterable[dict]) -> int:
        """Insert telemetry in 10 000-row batches inside transactions."""
        total = 0
        batch: list[tuple] = []
        with self._connect() as c:
            cur = c.cursor()
            cur.fast_executemany = True
            for s in samples:
                batch.append((
                    s["lap_id"], s["sample_time_ms"],
                    s.get("speed_kph"), s.get("rpm"), s.get("throttle"),
                    1 if s.get("brake") else 0 if s.get("brake") is not None else None,
                    s.get("gear"), s.get("drs"),
                ))
                if len(batch) >= self.telemetry_batch_size:
                    self._flush_telemetry(cur, batch)
                    c.commit()
                    total += len(batch)
                    batch.clear()
            if batch:
                self._flush_telemetry(cur, batch)
                c.commit()
                total += len(batch)
        return total

    @staticmethod
    def _flush_telemetry(cur: pyodbc.Cursor, batch: list[tuple]) -> None:
        cur.executemany(
            """INSERT INTO dbo.Telemetry
               (LapId, SampleTimeMs, SpeedKph, RPM, Throttle, Brake, Gear, DRS)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            batch,
        )

    def insert_quali_results(self, session_id: int, rows: Sequence[dict]) -> int:
        if not rows:
            return 0
        with self._connect() as c:
            cur = c.cursor()
            cur.fast_executemany = True
            params = [
                (session_id, r["driver_id"], r.get("position"),
                 r.get("q1_ms"), r.get("q2_ms"), r.get("q3_ms"))
                for r in rows
            ]
            cur.executemany(
                """INSERT INTO dbo.QualiResults
                   (SessionId, DriverId, Position, Q1Ms, Q2Ms, Q3Ms)
                   VALUES (?, ?, ?, ?, ?, ?)""", params,
            )
            c.commit()
            return len(params)

    def insert_race_results(self, session_id: int, rows: Sequence[dict]) -> int:
        if not rows:
            return 0
        with self._connect() as c:
            cur = c.cursor()
            cur.fast_executemany = True
            params = [
                (session_id, r["driver_id"], r.get("position"), r.get("grid_position"),
                 r.get("status"), r.get("points"), r.get("fastest_lap_ms"))
                for r in rows
            ]
            cur.executemany(
                """INSERT INTO dbo.RaceResults
                   (SessionId, DriverId, Position, GridPosition, [Status], Points, FastestLapMs)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""", params,
            )
            c.commit()
            return len(params)
