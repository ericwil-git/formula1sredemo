"""Prometheus metrics for the ingestion service.

Exposed on an HTTP endpoint scraped by Azure Monitor managed Prometheus
(via the windows_exporter textfile collector or a direct scrape config).
"""

from __future__ import annotations

import logging

from prometheus_client import Counter, Histogram, start_http_server

LOG = logging.getLogger("f1_ingest.metrics")

rows_total = Counter(
    "f1_ingest_rows_total",
    "Total rows written to SQL MI by the ingestion service.",
    labelnames=("table",),
)

duration_seconds = Histogram(
    "f1_ingest_duration_seconds",
    "End-to-end duration of an ingestion run.",
    buckets=(1, 5, 10, 30, 60, 120, 300, 600, 1200, 1800, 3600),
)

errors_total = Counter(
    "f1_ingest_errors_total",
    "Total ingestion errors.",
)


def start_server(port: int) -> None:
    """Start the Prometheus exposition HTTP server."""
    start_http_server(port)
    LOG.info("Prometheus metrics available on :%d/metrics", port)
