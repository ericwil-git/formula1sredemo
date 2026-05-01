"""SQL MI bulk-insert wrapper. Real implementation goes here in a follow-up."""

from __future__ import annotations

import logging
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Iterator, Sequence

LOG = logging.getLogger("f1_ingest.sql_writer")


@dataclass(frozen=True)
class SqlWriter:
    connection_string: str
    telemetry_batch_size: int = 10_000

    @contextmanager
    def _connect(self) -> Iterator[object]:
        # TODO(spec §5.1): real pyodbc connection.
        #   import pyodbc
        #   with pyodbc.connect(self.connection_string, autocommit=False) as conn:
        #       conn.cursor().fast_executemany = True
        #       yield conn
        LOG.info("Stub: _connect()  (would open pyodbc connection)")
        yield None

    def upsert_seasons(self, rows: Sequence[dict]) -> int:
        """MERGE Seasons rows. Returns rows affected."""
        # TODO(spec §5.1): MERGE INTO dbo.Seasons (Year, Name) ...
        return 0

    def upsert_events(self, rows: Sequence[dict]) -> int:
        # TODO(spec §5.1)
        return 0

    def upsert_sessions(self, rows: Sequence[dict]) -> int:
        # TODO(spec §5.1)
        return 0

    def upsert_drivers(self, rows: Sequence[dict]) -> int:
        # TODO(spec §5.1)
        return 0

    def insert_laps(self, rows: Sequence[dict]) -> int:
        # TODO(spec §5.1): INSERT INTO dbo.Laps via fast_executemany.
        return 0

    def bulk_insert_telemetry(self, rows: Sequence[dict]) -> int:
        """Inserts telemetry rows in 10 000-row batches inside a transaction."""
        # TODO(spec §5.1): chunk by self.telemetry_batch_size, fast_executemany insert.
        return 0
