"""FastF1 wrapper: loads the season schedule + per-session race data."""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from typing import Iterable, Iterator

import fastf1
import fastf1.core
import pandas as pd

LOG = logging.getLogger("f1_ingest.fastf1_loader")


# Map FastF1 session name -> our SessionType column value (CHECK constraint).
_SESSION_TYPE_MAP = {
    "Practice 1":     "FP1",
    "Practice 2":     "FP2",
    "Practice 3":     "FP3",
    "Qualifying":     "Q",
    "Sprint":         "Sprint",
    "Sprint Shootout": "Sprint",   # 2023+ Sprint quali; collapse for the demo
    "Sprint Qualifying": "Sprint",
    "Race":           "R",
}


@dataclass
class FastF1Loader:
    cache_dir: str
    _enabled: bool = field(default=False, init=False)

    def __post_init__(self) -> None:
        os.makedirs(self.cache_dir, exist_ok=True)
        if not self._enabled:
            fastf1.Cache.enable_cache(self.cache_dir)
            self._enabled = True
            LOG.info("FastF1 cache enabled at %s", self.cache_dir)

    # -------- schedule --------------------------------------------------

    def get_schedule(self, year: int) -> pd.DataFrame:
        """Return the event schedule for the year (testing rounds excluded)."""
        return fastf1.get_event_schedule(year, include_testing=False)

    def select_events(self, schedule: pd.DataFrame, events_filter: str) -> pd.DataFrame:
        """Filter the schedule by 'all', round numbers, or substrings of EventName."""
        if events_filter.strip().lower() == "all":
            return schedule

        wanted = [s.strip().lower() for s in events_filter.split(",") if s.strip()]
        keep = []
        for _, row in schedule.iterrows():
            r = int(row["RoundNumber"])
            name = str(row["EventName"]).lower()
            country = str(row.get("Country", "")).lower()
            for w in wanted:
                if w.isdigit() and int(w) == r:
                    keep.append(row.name)
                    break
                if w in name or w in country:
                    keep.append(row.name)
                    break
        return schedule.loc[keep]

    # -------- per-event sessions ---------------------------------------

    def iter_sessions(self, year: int, event_round: int,
                      load_telemetry: bool) -> Iterator[fastf1.core.Session]:
        """Yield every available session for the event, fully loaded."""
        for session_name, db_type in _SESSION_TYPE_MAP.items():
            try:
                session = fastf1.get_session(year, event_round, session_name)
            except (KeyError, ValueError) as ex:  # session doesn't exist for this event
                LOG.debug("skip %d/%s/%s: %s", year, event_round, session_name, ex)
                continue
            try:
                session.load(laps=True, telemetry=load_telemetry, weather=False, messages=False)
            except Exception:
                LOG.exception("load failed for %d/%s/%s", year, event_round, session_name)
                continue
            session._db_session_type = db_type   # type: ignore[attr-defined]
            yield session
