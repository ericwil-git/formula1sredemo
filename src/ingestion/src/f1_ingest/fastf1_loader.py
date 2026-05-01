"""FastF1 wrapper. Real implementation goes here in a follow-up prompt."""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from typing import Iterable

LOG = logging.getLogger("f1_ingest.fastf1_loader")


@dataclass(frozen=True)
class FastF1Loader:
    cache_dir: str

    def __post_init__(self) -> None:
        os.makedirs(self.cache_dir, exist_ok=True)
        # TODO(spec §5.1): enable FastF1 cache once package is wired in.
        #   import fastf1
        #   fastf1.Cache.enable_cache(self.cache_dir)
        LOG.info("FastF1 cache directory: %s", self.cache_dir)

    def get_season(self, year: int) -> object:
        """Return a season object for the given year."""
        # TODO(spec §5.1):
        #   import fastf1
        #   return fastf1.get_event_schedule(year, include_testing=False)
        LOG.info("Stub: get_season(%s)", year)
        return {"year": year, "events": []}

    def select_events(self, season: object, events_filter: str) -> Iterable[object]:
        """Filter events by name or round, or return all if events_filter == 'all'."""
        # TODO(spec §5.1): match events_filter against season.EventName / RoundNumber.
        LOG.info("Stub: select_events(filter=%s)", events_filter)
        return []
