"""Metrics for the ingestion service.

Two backends:
 1. prometheus-client (existing): exposed at :9101/metrics for any
    Prometheus-style scrape (managed Prometheus, future).
 2. Azure Monitor OpenTelemetry distro (new in Phase 2 of the SRE
    roadmap): when APPLICATIONINSIGHTS_CONNECTION_STRING is set in
    the env, configure_azure_monitor() wires up an OTel meter that
    publishes to App Insights -> customMetrics. This is what the
    "ingest stale" alert in monitoring.bicep queries against.
"""

from __future__ import annotations

import logging
import os
from typing import Optional

from prometheus_client import Counter, Histogram, start_http_server

LOG = logging.getLogger("f1_ingest.metrics")

# ---------- prometheus-client (-> :9101/metrics) ----------------------------

rows_total = Counter(
    "f1_ingest_rows_total",
    "Total rows written to SQL by the ingestion service.",
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


# ---------- OpenTelemetry / App Insights -> customMetrics --------------------

# Module-level so we initialize at most once per process.
_otel_runs_counter = None
_otel_initialized = False


def configure_app_insights(service_name: str = "F1.Ingestion") -> None:
    """Configure the Azure Monitor OTel distro if the connection string env
    var is present. Safe to call multiple times — only configures once.
    """
    global _otel_runs_counter, _otel_initialized
    if _otel_initialized:
        return
    _otel_initialized = True

    conn = os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING")
    if not conn:
        LOG.info("APPLICATIONINSIGHTS_CONNECTION_STRING not set; "
                 "skipping App Insights export.")
        return

    try:
        from azure.monitor.opentelemetry import configure_azure_monitor
        from opentelemetry import metrics as otel_metrics
        from opentelemetry.sdk.resources import Resource

        # service.name = cloud_RoleName on the App Insights side, so the
        # ingestion job shows up as "F1.Ingestion" on the App Map alongside
        # F1.Web and F1.FileGenerator.
        configure_azure_monitor(
            connection_string=conn,
            resource=Resource.create({"service.name": service_name}),
        )
        meter = otel_metrics.get_meter("f1_ingest")
        _otel_runs_counter = meter.create_counter(
            name="f1_ingest_runs",
            description="Successful ingestion runs (by year). Drives the "
                        "'ingest stale' alert in monitoring.bicep.",
            unit="1",
        )
        LOG.info("Azure Monitor OTel exporter configured (service=%s).",
                 service_name)
    except Exception:
        LOG.exception("Failed to configure Azure Monitor OTel exporter.")


def record_successful_run(year: int) -> None:
    """Increment the f1_ingest_runs OTel counter for a given year. No-op if
    OTel was not configured (e.g. running locally without an AI conn string).
    """
    global _otel_runs_counter
    if _otel_runs_counter is None:
        return
    try:
        _otel_runs_counter.add(1, {"year": str(year)})
    except Exception:
        LOG.exception("Failed to record f1_ingest_runs metric.")


def shutdown_otel(timeout_ms: int = 10_000) -> None:
    """Force-flush and shut down the OTel SDK so a short-lived script
    doesn't exit before the metric is exported. Best-effort.
    """
    if not _otel_initialized:
        return
    try:
        from opentelemetry import metrics as otel_metrics
        provider = otel_metrics.get_meter_provider()
        force_flush = getattr(provider, "force_flush", None)
        if callable(force_flush):
            force_flush(timeout_ms)
        shutdown = getattr(provider, "shutdown", None)
        if callable(shutdown):
            shutdown()
    except Exception:
        LOG.exception("OTel shutdown failed (non-fatal).")
