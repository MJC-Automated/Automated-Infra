#!/usr/bin/env python3
"""Generate and optionally email the inventory-driven weekly health report."""

from __future__ import annotations

import argparse
import fcntl
import html
import json
import math
import os
import re
import shutil
import smtplib
import ssl
import subprocess
import sys
import tempfile
from datetime import datetime, time, timedelta
from email.message import EmailMessage
from email.utils import format_datetime, formataddr, make_msgid
from pathlib import Path
from typing import Any
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo


SERVICE_JOB_PATTERN = (
    "blackbox-http|blackbox-http-insecure|blackbox-weblogic-managed|"
    "blackbox-oracle-listener|blackbox-kubernetes-api|"
    "blackbox-kubernetes-etcd"
)
SAFE_ENVIRONMENT = re.compile(r"^[A-Za-z0-9_.-]+$")
SEVERITY_ORDER = {"critical": 0, "warning": 1, "info": 2}


class ReportError(RuntimeError):
    """An expected reporting failure that is safe to log."""


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ReportError(f"Required environment variable {name} is empty")
    return value


def env_bool(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def finite_float(value: Any) -> float | None:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if math.isfinite(parsed) else None


def clamp(value: float, low: float = 0.0, high: float = 100.0) -> float:
    return max(low, min(high, value))


def escape(value: Any) -> str:
    return html.escape(str(value), quote=True)


def slug(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "-", value).strip("-")
    return cleaned or "environment"


def atomic_text(path: Path, content: str, mode: int = 0o600) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(content, encoding="utf-8")
    os.chmod(temporary, mode)
    os.replace(temporary, path)


class PrometheusClient:
    def __init__(self, base_url: str, timeout: int = 20) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def query(self, expression: str, timestamp: datetime) -> list[dict[str, Any]]:
        parameters = urlencode(
            {
                "query": expression,
                "time": f"{timestamp.timestamp():.3f}",
            }
        )
        request = Request(
            f"{self.base_url}/api/v1/query?{parameters}",
            headers={"Accept": "application/json", "User-Agent": "iac-weekly-report/1"},
        )
        try:
            with urlopen(request, timeout=self.timeout) as response:
                payload = json.load(response)
        except Exception as exc:  # urllib exposes several transport exceptions.
            raise ReportError(f"Prometheus query transport failed: {exc}") from exc
        if payload.get("status") != "success":
            error = payload.get("error", "unknown Prometheus API error")
            raise ReportError(f"Prometheus query failed: {error}")
        result = payload.get("data", {}).get("result")
        if not isinstance(result, list):
            raise ReportError("Prometheus returned an invalid result payload")
        return result


def result_value(item: dict[str, Any]) -> float | None:
    value = item.get("value", [None, None])
    if not isinstance(value, list) or len(value) < 2:
        return None
    return finite_float(value[1])


def result_map(
    results: list[dict[str, Any]], key_fields: tuple[str, ...]
) -> dict[tuple[str, ...], float]:
    mapped: dict[tuple[str, ...], float] = {}
    for item in results:
        labels = item.get("metric", {})
        value = result_value(item)
        if value is None:
            continue
        key = tuple(str(labels.get(field, "")) for field in key_fields)
        mapped[key] = value
    return mapped


def latest_completed_window(now: datetime) -> tuple[datetime, datetime]:
    """Return the latest completed Monday 00:00-Friday 16:00 local window."""
    days_since_friday = (now.weekday() - 4) % 7
    friday = now.date() - timedelta(days=days_since_friday)
    end = datetime.combine(friday, time(hour=16), tzinfo=now.tzinfo)
    if now < end:
        end -= timedelta(days=7)
    start = datetime.combine(end.date() - timedelta(days=4), time.min, tzinfo=now.tzinfo)
    return start, end


def parse_end(value: str | None, timezone: ZoneInfo) -> datetime:
    if not value:
        return datetime.now(timezone)
    normalized = value.replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise ReportError("--end must be an ISO-8601 timestamp") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone)
    return parsed.astimezone(timezone)


def human_duration(seconds: float) -> str:
    seconds = max(0.0, seconds)
    if seconds < 60:
        return f"{seconds:.0f}s"
    minutes = seconds / 60
    if minutes < 60:
        return f"{minutes:.1f}m"
    hours = minutes / 60
    if hours < 48:
        return f"{hours:.1f}h"
    return f"{hours / 24:.1f}d"


def mean(values: list[float]) -> float | None:
    return sum(values) / len(values) if values else None


def percent(value: float | None) -> str:
    return "N/A" if value is None else f"{value:.2f}%"


def state_label(value: float | None) -> str:
    if value is None:
        return "NO DATA"
    return "UP" if value >= 0.5 else "DOWN"


def state_css(value: float | None) -> str:
    if value is None:
        return "neutral"
    return "good" if value >= 0.5 else "critical"


def availability_css(value: float | None, warning: float, critical: float) -> str:
    if value is None:
        return "neutral"
    if value >= warning:
        return "good"
    if value >= critical:
        return "warning"
    return "critical"


def build_availability_rows(
    availability: list[dict[str, Any]],
    current: list[dict[str, Any]],
    coverage: list[dict[str, Any]],
    key_fields: tuple[str, ...],
    duration_seconds: float,
    expected_samples: float,
) -> list[dict[str, Any]]:
    current_values = result_map(current, key_fields)
    coverage_values = result_map(coverage, key_fields)
    rows: list[dict[str, Any]] = []
    for item in availability:
        labels = {str(k): str(v) for k, v in item.get("metric", {}).items()}
        value = result_value(item)
        key = tuple(labels.get(field, "") for field in key_fields)
        rows.append(
            {
                **labels,
                "uptime": value,
                "current": current_values.get(key),
                "coverage": clamp(
                    coverage_values.get(key, 0.0) / expected_samples * 100.0
                ),
                "expected": labels.get("expected_up") == "true",
                "downtime_seconds": (
                    duration_seconds * (1.0 - clamp(value) / 100.0)
                    if value is not None
                    else None
                ),
            }
        )
    rows.sort(
        key=lambda row: (
            row["uptime"] is None,
            row["uptime"] if row["uptime"] is not None else 101.0,
            row.get("instance", ""),
            row.get("check", ""),
        )
    )
    return rows


def fetch_report_data(
    client: PrometheusClient,
    environment: str,
    start: datetime,
    end: datetime,
    scrape_interval_seconds: int,
) -> dict[str, Any]:
    duration_seconds = max(1, int((end - start).total_seconds()))
    duration = f"{duration_seconds}s"
    expected_samples = max(1.0, duration_seconds / scrape_interval_seconds)
    host_selector = (
        f'probe_success{{job="blackbox-host",environment="{environment}",'
        'expected_up=~"true|false"}'
    )
    service_selector = (
        f'probe_success{{job=~"{SERVICE_JOB_PATTERN}",environment="{environment}",'
        'expected_up=~"true|false",check=~".+"}'
    )
    host_fields = ("environment", "instance", "role", "target", "expected_up")
    service_fields = (
        "environment",
        "instance",
        "service",
        "check",
        "expected_up",
    )

    host_availability = client.query(
        f"avg by ({','.join(host_fields)}) (avg_over_time({host_selector}[{duration}])) * 100",
        end,
    )
    host_current = client.query(
        f"max by ({','.join(host_fields)}) ({host_selector})", end
    )
    host_coverage = client.query(
        f"max by ({','.join(host_fields)}) "
        f"(count_over_time({host_selector}[{duration}]))",
        end,
    )
    service_availability = client.query(
        f"avg by ({','.join(service_fields)}) (avg_over_time({service_selector}[{duration}])) * 100",
        end,
    )
    service_current = client.query(
        f"max by ({','.join(service_fields)}) ({service_selector})", end
    )
    service_coverage = client.query(
        f"max by ({','.join(service_fields)}) "
        f"(count_over_time({service_selector}[{duration}]))",
        end,
    )

    hosts = build_availability_rows(
        host_availability,
        host_current,
        host_coverage,
        host_fields,
        duration_seconds,
        expected_samples,
    )
    services = build_availability_rows(
        service_availability,
        service_current,
        service_coverage,
        service_fields,
        duration_seconds,
        expected_samples,
    )

    telemetry_sample_results = client.query(
        f'max(count_over_time(up{{job="prometheus"}}[{duration}]))', end
    )
    telemetry_samples = (
        result_value(telemetry_sample_results[0]) if telemetry_sample_results else 0.0
    )
    telemetry_coverage = clamp(
        (telemetry_samples or 0.0) / expected_samples * 100.0
    )

    cpu_results = client.query(
        "100 - (avg by (instance,role) "
        f'(rate(node_cpu_seconds_total{{job="node",environment="{environment}",mode="idle"}}[5m])) * 100)',
        end,
    )
    memory_results = client.query(
        "avg by (instance,role) (100 * (1 - "
        f'node_memory_MemAvailable_bytes{{job="node",environment="{environment}"}} / '
        f'node_memory_MemTotal_bytes{{job="node",environment="{environment}"}}))',
        end,
    )
    disk_results = client.query(
        "avg by (instance,role) (100 * (1 - "
        f'node_filesystem_avail_bytes{{job="node",environment="{environment}",mountpoint="/",fstype!~"tmpfs|overlay"}} / '
        f'node_filesystem_size_bytes{{job="node",environment="{environment}",mountpoint="/",fstype!~"tmpfs|overlay"}}))',
        end,
    )
    cpu = result_map(cpu_results, ("instance",))
    memory = result_map(memory_results, ("instance",))
    disk = result_map(disk_results, ("instance",))
    resource_instances = sorted(set(cpu) | set(memory) | set(disk))
    resources = [
        {
            "instance": instance[0],
            "cpu_used": cpu.get(instance),
            "memory_used": memory.get(instance),
            "disk_used": disk.get(instance),
        }
        for instance in resource_instances
    ]

    cdb_uptime_results = client.query(
        "avg by (instance,cdb,role) (avg_over_time("
        f'iac_oracle_cdb_up{{environment="{environment}"}}[{duration}])) * 100',
        end,
    )
    cdb_current_results = client.query(
        f'max by (instance,cdb,role) (iac_oracle_cdb_up{{environment="{environment}"}})',
        end,
    )
    pdb_count_results = client.query(
        f'max by (instance,cdb) (iac_oracle_pdb_count{{environment="{environment}"}})',
        end,
    )
    pdb_uptime_results = client.query(
        "avg by (instance,cdb,pdb) (avg_over_time("
        f'iac_oracle_pdb_up{{environment="{environment}"}}[{duration}])) * 100',
        end,
    )
    pdb_current_results = client.query(
        f'max by (instance,cdb,pdb) (iac_oracle_pdb_up{{environment="{environment}"}})',
        end,
    )
    cdb_current = result_map(cdb_current_results, ("instance", "cdb"))
    pdb_counts = result_map(pdb_count_results, ("instance", "cdb"))
    pdb_current = result_map(pdb_current_results, ("instance", "cdb", "pdb"))
    oracle_rows: list[dict[str, Any]] = []
    for item in cdb_uptime_results:
        labels = item.get("metric", {})
        instance = str(labels.get("instance", ""))
        cdb = str(labels.get("cdb", ""))
        pdbs: list[dict[str, Any]] = []
        for pdb_item in pdb_uptime_results:
            pdb_labels = pdb_item.get("metric", {})
            if (
                str(pdb_labels.get("instance", "")) == instance
                and str(pdb_labels.get("cdb", "")) == cdb
            ):
                pdb = str(pdb_labels.get("pdb", ""))
                pdbs.append(
                    {
                        "name": pdb,
                        "uptime": result_value(pdb_item),
                        "current": pdb_current.get((instance, cdb, pdb)),
                    }
                )
        pdbs.sort(key=lambda row: row["name"])
        oracle_rows.append(
            {
                "instance": instance,
                "role": str(labels.get("role", "")),
                "cdb": cdb,
                "uptime": result_value(item),
                "current": cdb_current.get((instance, cdb)),
                "pdb_count": pdb_counts.get((instance, cdb)),
                "pdbs": pdbs,
            }
        )
    oracle_rows.sort(key=lambda row: (row["instance"], row["cdb"]))

    alerts: list[dict[str, str]] = []
    for item in client.query('ALERTS{alertstate="firing"}', end):
        labels = {str(k): str(v) for k, v in item.get("metric", {}).items()}
        alert_environment = labels.get("environment", "")
        if alert_environment and alert_environment != environment:
            continue
        alerts.append(labels)
    alerts.sort(
        key=lambda labels: (
            SEVERITY_ORDER.get(labels.get("severity", "info"), 9),
            labels.get("alertname", ""),
            labels.get("instance", ""),
        )
    )

    host_values = [row["uptime"] for row in hosts if row["uptime"] is not None]
    host_expected_values = [
        row["uptime"]
        for row in hosts
        if row["expected"] and row["uptime"] is not None
    ]
    service_values = [
        row["uptime"] for row in services if row["uptime"] is not None
    ]
    service_expected_values = [
        row["uptime"]
        for row in services
        if row["expected"] and row["uptime"] is not None
    ]
    summary = {
        "host_uptime": mean(host_values),
        "host_expected_uptime": mean(host_expected_values),
        "hosts_total": len(hosts),
        "hosts_up": sum(1 for row in hosts if (row["current"] or 0) >= 0.5),
        "hosts_expected": sum(1 for row in hosts if row["expected"]),
        "service_uptime": mean(service_values),
        "service_expected_uptime": mean(service_expected_values),
        "services_total": len(services),
        "services_up": sum(
            1 for row in services if (row["current"] or 0) >= 0.5
        ),
        "services_expected": sum(1 for row in services if row["expected"]),
        "alerts_total": len(alerts),
        "alerts_critical": sum(
            1 for labels in alerts if labels.get("severity") == "critical"
        ),
        "alerts_warning": sum(
            1 for labels in alerts if labels.get("severity") == "warning"
        ),
        "telemetry_coverage": telemetry_coverage,
        "scrape_interval_seconds": scrape_interval_seconds,
    }
    return {
        "summary": summary,
        "hosts": hosts,
        "services": services,
        "resources": resources,
        "oracle": oracle_rows,
        "alerts": alerts,
    }


def progress_bar(value: float | None, warning: float, critical: float) -> str:
    if value is None:
        return '<span class="muted">No data</span>'
    css = availability_css(value, warning, critical)
    width = clamp(value)
    return (
        '<div class="metric"><span class="metric-value">'
        f"{value:.2f}%</span><span class=\"bar\"><span class=\"fill {css}\" "
        f'style="width:{width:.2f}%"></span></span></div>'
    )


def summary_card(
    title: str,
    value: str,
    detail: str,
    css: str,
) -> str:
    return (
        f'<div class="card {css}"><div class="card-title">{escape(title)}</div>'
        f'<div class="card-value">{escape(value)}</div>'
        f'<div class="card-detail">{escape(detail)}</div></div>'
    )


def render_availability_table(
    rows: list[dict[str, Any]],
    kind: str,
    duration_seconds: float,
    warning: float,
    critical: float,
) -> str:
    rendered: list[str] = []
    for row in rows:
        uptime = row["uptime"]
        state = row["current"]
        expected = row["expected"]
        if kind == "host":
            identity = escape(row.get("instance", "unknown"))
            secondary = escape(row.get("role", "unknown"))
            target = escape(row.get("target", ""))
        else:
            identity = escape(row.get("check", row.get("service", "unknown")))
            secondary = escape(row.get("instance", "unknown"))
            target = escape(row.get("service", ""))
        expected_badge = (
            '<span class="badge expected">EXPECTED</span>'
            if expected
            else '<span class="badge informational">INFORMATIONAL</span>'
        )
        downtime = (
            human_duration(row["downtime_seconds"])
            if row["downtime_seconds"] is not None
            else "N/A"
        )
        rendered.append(
            "<tr>"
            f'<td><strong>{identity}</strong><div class="sub">{secondary}</div></td>'
            f'<td>{target}</td>'
            f"<td>{expected_badge}</td>"
            f'<td>{progress_bar(uptime, warning, critical)}</td>'
            f'<td>{progress_bar(row["coverage"], 99.0, 95.0)}</td>'
            f'<td>{escape(downtime)} / {escape(human_duration(duration_seconds))}</td>'
            f'<td><span class="badge {state_css(state)}">{state_label(state)}</span></td>'
            "</tr>"
        )
    if not rendered:
        return '<p class="empty">No matching metrics were present for this period.</p>'
    return (
        '<table><thead><tr><th>Name</th><th>Role / type</th><th>Policy</th>'
        '<th>Observed availability</th><th>Sample coverage</th>'
        '<th>Estimated downtime</th><th>At period end</th>'
        f"</tr></thead><tbody>{''.join(rendered)}</tbody></table>"
    )


def render_resources(rows: list[dict[str, Any]]) -> str:
    rendered: list[str] = []
    for row in rows:
        metrics = []
        for key in ("cpu_used", "memory_used", "disk_used"):
            value = row.get(key)
            css = "neutral"
            if value is not None:
                css = "critical" if value >= 90 else "warning" if value >= 75 else "good"
            metrics.append(
                f'<td><span class="badge {css}">{percent(value)}</span></td>'
            )
        rendered.append(
            f'<tr><td><strong>{escape(row["instance"])}</strong></td>'
            + "".join(metrics)
            + "</tr>"
        )
    if not rendered:
        return '<p class="empty">No node resource series were available at period end.</p>'
    return (
        '<table><thead><tr><th>VM</th><th>CPU used</th><th>Memory used</th>'
        f"<th>Root filesystem used</th></tr></thead><tbody>{''.join(rendered)}</tbody></table>"
    )


def render_oracle(rows: list[dict[str, Any]], warning: float, critical: float) -> str:
    rendered: list[str] = []
    for row in rows:
        if row["pdbs"]:
            pdb_text = ", ".join(
                f'{escape(pdb["name"])} '
                f'<span class="badge {state_css(pdb["current"])}">'
                f'{state_label(pdb["current"])}</span> '
                f'({percent(pdb["uptime"])})'
                for pdb in row["pdbs"]
            )
        else:
            pdb_text = '<span class="muted">No PDB series</span>'
        rendered.append(
            "<tr>"
            f'<td><strong>{escape(row["instance"])}</strong><div class="sub">{escape(row["role"])}</div></td>'
            f'<td>{escape(row["cdb"])}</td>'
            f'<td>{progress_bar(row["uptime"], warning, critical)}</td>'
            f'<td><span class="badge {state_css(row["current"])}">{state_label(row["current"])}</span></td>'
            f'<td>{int(row["pdb_count"]) if row["pdb_count"] is not None else "N/A"}</td>'
            f"<td>{pdb_text}</td>"
            "</tr>"
        )
    if not rendered:
        return '<p class="empty">No Oracle CDB/PDB metrics were available for this period.</p>'
    return (
        '<table><thead><tr><th>Database VM</th><th>CDB</th><th>CDB availability</th>'
        '<th>At period end</th><th>PDB count</th><th>PDB detail</th></tr></thead>'
        f"<tbody>{''.join(rendered)}</tbody></table>"
    )


def render_alerts(alerts: list[dict[str, str]]) -> str:
    if not alerts:
        return '<div class="all-clear">No alerts were firing at the period end.</div>'
    rendered: list[str] = []
    for labels in alerts:
        severity = labels.get("severity", "info")
        css = "critical" if severity == "critical" else "warning" if severity == "warning" else "neutral"
        rendered.append(
            "<tr>"
            f'<td><span class="badge {css}">{escape(severity.upper())}</span></td>'
            f'<td><strong>{escape(labels.get("alertname", "unnamed"))}</strong></td>'
            f'<td>{escape(labels.get("instance", labels.get("job", "central")))}</td>'
            f'<td>{escape(labels.get("service", labels.get("role", "")))}</td>'
            "</tr>"
        )
    return (
        '<table><thead><tr><th>Severity</th><th>Alert</th><th>Instance</th>'
        f"<th>Service / role</th></tr></thead><tbody>{''.join(rendered)}</tbody></table>"
    )


def render_html(
    title: str,
    brand: str,
    environment: str,
    start: datetime,
    end: datetime,
    generated: datetime,
    data: dict[str, Any],
    warning: float,
    critical: float,
) -> str:
    summary = data["summary"]
    host_css = availability_css(summary["host_uptime"], warning, critical)
    service_css = availability_css(summary["service_uptime"], warning, critical)
    expected_host_css = availability_css(
        summary["host_expected_uptime"], warning, critical
    )
    alert_css = "critical" if summary["alerts_critical"] else "warning" if summary["alerts_total"] else "good"
    coverage_css = availability_css(
        summary["telemetry_coverage"], 99.0, 95.0
    )
    cards = "".join(
        [
            summary_card(
                "All VM availability",
                percent(summary["host_uptime"]),
                f'{summary["hosts_up"]}/{summary["hosts_total"]} reachable at period end',
                host_css,
            ),
            summary_card(
                "All service availability",
                percent(summary["service_uptime"]),
                f'{summary["services_up"]}/{summary["services_total"]} endpoints up at period end',
                service_css,
            ),
            summary_card(
                "Expected-up VM SLO",
                percent(summary["host_expected_uptime"]),
                f'{summary["hosts_expected"]} inventory VMs in paging policy',
                expected_host_css,
            ),
            summary_card(
                "Firing alerts",
                str(summary["alerts_total"]),
                f'{summary["alerts_critical"]} critical · {summary["alerts_warning"]} warning',
                alert_css,
            ),
        ]
    )
    duration_seconds = (end - start).total_seconds()
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{escape(title)} — {escape(environment)}</title>
<style>
  @page {{ size: A4 landscape; margin: 12mm; }}
  * {{ box-sizing: border-box; }}
  html {{ color-scheme: light; }}
  body {{ margin: 0; color: #132238; background: #fff; font-family: Inter, Arial, sans-serif; font-size: 9px; line-height: 1.35; -webkit-print-color-adjust: exact; print-color-adjust: exact; }}
  .hero {{ background: linear-gradient(125deg, #0b2545, #0e7490 68%, #14b8a6); color: white; border-radius: 12px; padding: 22px 26px; margin-bottom: 14px; }}
  .eyebrow {{ font-size: 10px; text-transform: uppercase; letter-spacing: 1.8px; opacity: .8; }}
  h1 {{ font-size: 27px; margin: 5px 0 3px; line-height: 1.1; }}
  .period {{ font-size: 11px; opacity: .92; }}
  .brand {{ float: right; padding: 7px 10px; border: 1px solid rgba(255,255,255,.45); border-radius: 8px; font-weight: 700; letter-spacing: .6px; }}
  .cards {{ display: grid; grid-template-columns: repeat(4, 1fr); gap: 9px; margin-bottom: 15px; }}
  .coverage {{ border: 1px solid #cbd5e1; border-left: 5px solid #64748b; border-radius: 8px; padding: 9px 12px; margin: -4px 0 14px; background: #f8fafc; }}
  .coverage.good {{ border-left-color: #16a34a; background: #f0fdf4; }}
  .coverage.warning {{ border-left-color: #d97706; background: #fffbeb; }}
  .coverage.critical {{ border-left-color: #dc2626; background: #fef2f2; }}
  .card {{ border: 1px solid #d8e2ee; border-top: 5px solid #64748b; border-radius: 9px; padding: 11px 12px; background: #f8fafc; min-height: 82px; }}
  .card.good {{ border-top-color: #16a34a; background: #f0fdf4; }}
  .card.warning {{ border-top-color: #d97706; background: #fffbeb; }}
  .card.critical {{ border-top-color: #dc2626; background: #fef2f2; }}
  .card-title {{ color: #52657c; font-weight: 700; text-transform: uppercase; letter-spacing: .5px; }}
  .card-value {{ font-size: 22px; font-weight: 800; margin: 4px 0; }}
  .card-detail {{ color: #52657c; }}
  h2 {{ color: #0b2545; font-size: 15px; margin: 14px 0 7px; border-bottom: 2px solid #ccdae8; padding-bottom: 4px; }}
  h3 {{ color: #0e7490; font-size: 11px; margin: 10px 0 5px; }}
  .section-note {{ color: #52657c; margin: -3px 0 7px; }}
  table {{ width: 100%; border-collapse: collapse; table-layout: fixed; }}
  thead {{ display: table-header-group; }}
  tr {{ break-inside: avoid; }}
  th {{ background: #0b2545; color: white; text-align: left; font-size: 8px; text-transform: uppercase; letter-spacing: .35px; padding: 6px; }}
  td {{ border-bottom: 1px solid #dbe5ef; padding: 5px 6px; vertical-align: middle; overflow-wrap: anywhere; }}
  tbody tr:nth-child(even) {{ background: #f6f9fc; }}
  .sub {{ color: #64748b; font-size: 8px; margin-top: 1px; }}
  .badge {{ display: inline-block; border-radius: 999px; padding: 2px 6px; font-size: 7.5px; font-weight: 800; letter-spacing: .25px; white-space: nowrap; }}
  .badge.good, .fill.good {{ color: #166534; background: #bbf7d0; }}
  .badge.warning, .fill.warning {{ color: #92400e; background: #fde68a; }}
  .badge.critical, .fill.critical {{ color: #991b1b; background: #fecaca; }}
  .badge.neutral {{ color: #475569; background: #e2e8f0; }}
  .badge.expected {{ color: #075985; background: #bae6fd; }}
  .badge.informational {{ color: #475569; background: #e2e8f0; }}
  .metric {{ display: grid; grid-template-columns: 46px 1fr; align-items: center; gap: 5px; }}
  .metric-value {{ font-weight: 700; text-align: right; }}
  .bar {{ display: block; height: 6px; border-radius: 999px; overflow: hidden; background: #e2e8f0; }}
  .fill {{ display: block; height: 100%; border-radius: 999px; }}
  .fill.good {{ background: #22c55e; }} .fill.warning {{ background: #f59e0b; }} .fill.critical {{ background: #ef4444; }}
  .page-break {{ break-before: page; }}
  .all-clear {{ color: #166534; background: #dcfce7; border: 1px solid #86efac; border-radius: 8px; padding: 10px; font-weight: 700; }}
  .empty {{ color: #64748b; background: #f1f5f9; border-radius: 8px; padding: 10px; }}
  .muted {{ color: #64748b; }}
  .method {{ background: #f1f5f9; border-left: 4px solid #0e7490; padding: 9px 12px; margin-top: 12px; }}
  footer {{ margin-top: 12px; color: #64748b; font-size: 7.5px; border-top: 1px solid #dbe5ef; padding-top: 5px; }}
</style>
</head>
<body>
  <header class="hero">
    <div class="brand">{escape(brand)}</div>
    <div class="eyebrow">{escape(environment)} · Inventory-driven monitoring</div>
    <h1>{escape(title)}</h1>
    <div class="period">{escape(start.strftime('%a %d %b %Y %H:%M %Z'))} → {escape(end.strftime('%a %d %b %Y %H:%M %Z'))}</div>
  </header>
  <section class="cards">{cards}</section>
  <div class="coverage {coverage_css}"><strong>Telemetry coverage: {percent(summary['telemetry_coverage'])}</strong> of the selected window at the tracked {summary['scrape_interval_seconds']}-second cadence. Availability percentages use observed samples; missing telemetry is disclosed here and per row, never treated as proven uptime.</div>
  <h2>Virtual machine availability</h2>
  <p class="section-note">Factual ICMP reachability for every current Terraform inventory VM. Informational rows are visible but excluded from paging policy.</p>
  {render_availability_table(data['hosts'], 'host', duration_seconds, warning, critical)}

  <section class="page-break">
    <h2>Application and platform service availability</h2>
    <p class="section-note">HTTP, WebLogic admin/managed server, Oracle listener, Kubernetes API, and etcd probes. Each endpoint keeps a stable check identity.</p>
    {render_availability_table(data['services'], 'service', duration_seconds, warning, critical)}
  </section>

  <section class="page-break">
    <h2>Resource snapshot at period end</h2>
    <p class="section-note">CPU, memory, and root-filesystem consumption from Alloy's node-compatible metrics. Missing rows mean no fresh node series at the report boundary.</p>
    {render_resources(data['resources'])}

    <h2>Oracle CDB and PDB health</h2>
    <p class="section-note">Dynamic database inventory from license-safe V$DATABASE/V$PDBS metrics. PDB additions appear after the database and monitoring playbooks reconcile.</p>
    {render_oracle(data['oracle'], warning, critical)}

    <h2>Firing alerts at period end</h2>
    {render_alerts(data['alerts'])}
  </section>

  <div class="method"><strong>Methodology.</strong> Observed availability is the arithmetic mean of present Prometheus blackbox probe samples over the completed Nairobi business-week window. Sample coverage compares actual samples with the tracked scrape cadence, so monitoring gaps or mid-window additions remain visible rather than becoming implicit uptime. Estimated downtime is window duration × (1 − observed availability) and should be read together with coverage. A powered-off VM remains factual downtime while probes are present even when its expected-up policy is informational. Resource figures and firing alerts are point-in-time values at Friday 16:00 EAT.</div>
  <footer>Generated {escape(generated.strftime('%d %b %Y %H:%M:%S %Z'))} by the repo-managed observability weekly reporter. Report data contains no credentials.</footer>
</body>
</html>
"""


def render_pdf(chrome: Path, report_html: str, destination: Path) -> None:
    if not chrome.is_file() or not os.access(chrome, os.X_OK):
        raise ReportError(f"Pinned Chrome binary is unavailable: {chrome}")
    # Chrome for Testing can stall when its output target is below /var/lib on
    # a hardened guest. Render inside the service's PrivateTmp, validate there,
    # then atomically publish into the root-only persistent report directory.
    with tempfile.TemporaryDirectory(prefix="iac-weekly-report-") as temporary_dir:
        temporary = Path(temporary_dir)
        html_path = temporary / "report.html"
        pdf_path = temporary / "report.pdf"
        html_path.write_text(report_html, encoding="utf-8")
        command = [
            str(chrome),
            "--headless",
            "--no-sandbox",
            "--disable-dev-shm-usage",
            "--disable-gpu",
            "--no-pdf-header-footer",
            # Chrome otherwise waits indefinitely for page-idle signals on
            # some headless Linux guests, even for a self-contained file URL.
            # This is Chrome's capture timeout, not the process guard below.
            "--timeout=5000",
            "--run-all-compositor-stages-before-draw",
            f"--print-to-pdf={pdf_path}",
            html_path.as_uri(),
        ]
        completed = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=120,
            check=False,
            env={**os.environ, "HOME": str(temporary)},
        )
        if completed.returncode != 0:
            detail = completed.stderr.strip().replace("\n", " ")[-600:]
            raise ReportError(
                f"Headless Chrome failed with rc={completed.returncode}: {detail}"
            )
        if not pdf_path.is_file() or pdf_path.stat().st_size < 10_000:
            raise ReportError("Headless Chrome did not create a non-empty PDF")
        with pdf_path.open("rb") as stream:
            if stream.read(5) != b"%PDF-":
                raise ReportError("Generated report does not have a PDF signature")
        publish_path = destination.with_suffix(destination.suffix + ".tmp")
        shutil.copyfile(pdf_path, publish_path)
        os.chmod(publish_path, 0o600)
        os.replace(publish_path, destination)


def send_email(
    pdf_path: Path,
    environment: str,
    start: datetime,
    end: datetime,
    generated: datetime,
    data: dict[str, Any],
) -> str:
    smtp_host = required_env("REPORT_SMTP_HOST")
    smtp_port = int(required_env("REPORT_SMTP_PORT"))
    smtp_username = required_env("REPORT_SMTP_USERNAME")
    smtp_password = required_env("REPORT_SMTP_PASSWORD")
    smtp_helo = os.environ.get("REPORT_SMTP_HELO", "localhost").strip() or "localhost"
    display_name = os.environ.get("REPORT_SMTP_DISPLAY_NAME", "Infrastructure Monitoring").strip()
    recipients = [
        address.strip()
        for address in required_env("REPORT_RECIPIENTS").split(",")
        if address.strip()
    ]
    if not recipients:
        raise ReportError("REPORT_RECIPIENTS contains no addresses")
    summary = data["summary"]
    subject = (
        f"[{environment}] Weekly infrastructure health — "
        f"{end.strftime('%d %b %Y')}"
    )
    plain = f"""Weekly infrastructure health report for {environment}

Window: {start.strftime('%d %b %Y %H:%M %Z')} to {end.strftime('%d %b %Y %H:%M %Z')}
All VM availability: {percent(summary['host_uptime'])} ({summary['hosts_up']}/{summary['hosts_total']} reachable at period end)
All service availability: {percent(summary['service_uptime'])} ({summary['services_up']}/{summary['services_total']} up at period end)
Expected-up VM SLO: {percent(summary['host_expected_uptime'])}
Telemetry sample coverage: {percent(summary['telemetry_coverage'])}
Firing alerts at period end: {summary['alerts_total']} ({summary['alerts_critical']} critical, {summary['alerts_warning']} warning)

The attached color PDF contains per-VM and per-service availability, estimated downtime, resource snapshots, Oracle CDB/PDB health, and firing-alert details.
"""
    color = "#dc2626" if summary["alerts_critical"] else "#d97706" if summary["alerts_total"] else "#16a34a"
    rich = f"""<html><body style="font-family:Arial,sans-serif;color:#132238">
<div style="max-width:680px;margin:auto;border:1px solid #dbe5ef;border-radius:12px;overflow:hidden">
<div style="background:#0b2545;color:white;padding:22px"><h2 style="margin:0">Weekly infrastructure health</h2><div>{escape(environment)} · {escape(end.strftime('%d %b %Y'))}</div></div>
<div style="padding:20px"><p><strong>Window:</strong> {escape(start.strftime('%d %b %Y %H:%M %Z'))} → {escape(end.strftime('%d %b %Y %H:%M %Z'))}</p>
<table style="width:100%;border-collapse:collapse"><tr><td style="padding:10px;background:#f1f5f9"><strong>VM availability</strong><br>{percent(summary['host_uptime'])}</td><td style="padding:10px;background:#f1f5f9"><strong>Service availability</strong><br>{percent(summary['service_uptime'])}</td><td style="padding:10px;background:#f1f5f9"><strong>Telemetry coverage</strong><br>{percent(summary['telemetry_coverage'])}</td><td style="padding:10px;background:#f1f5f9;border-top:4px solid {color}"><strong>Firing alerts</strong><br>{summary['alerts_total']}</td></tr></table>
<p>The attached color PDF contains the full inventory and service detail.</p></div></div></body></html>"""
    message = EmailMessage()
    message["Subject"] = subject
    message["From"] = formataddr((display_name, smtp_username))
    message["To"] = ", ".join(recipients)
    message["Date"] = format_datetime(generated)
    message_id = make_msgid(domain=smtp_username.partition("@")[2] or None)
    message["Message-ID"] = message_id
    message.set_content(plain)
    message.add_alternative(rich, subtype="html")
    message.add_attachment(
        pdf_path.read_bytes(),
        maintype="application",
        subtype="pdf",
        filename=pdf_path.name,
    )
    context = ssl.create_default_context()
    try:
        with smtplib.SMTP(smtp_host, smtp_port, timeout=30) as connection:
            connection.ehlo(smtp_helo)
            connection.starttls(context=context)
            connection.ehlo(smtp_helo)
            connection.login(smtp_username, smtp_password)
            connection.send_message(
                message,
                from_addr=smtp_username,
                to_addrs=recipients,
            )
    except (OSError, smtplib.SMTPException) as exc:
        raise ReportError(f"STARTTLS report delivery failed: {exc}") from exc
    return message_id


def remove_expired_reports(output_dir: Path, retention_days: int, now: datetime) -> None:
    cutoff = now.timestamp() - retention_days * 86400
    for candidate in output_dir.iterdir():
        if candidate.name.startswith("."):
            continue
        if candidate.suffix not in {".pdf", ".json", ".sent"}:
            continue
        try:
            if candidate.stat().st_mtime < cutoff:
                candidate.unlink()
        except FileNotFoundError:
            continue


def metadata_document(
    environment: str,
    start: datetime,
    end: datetime,
    generated: datetime,
    data: dict[str, Any],
) -> str:
    payload = {
        "schema": 1,
        "environment": environment,
        "window_start": start.isoformat(),
        "window_end": end.isoformat(),
        "generated_at": generated.isoformat(),
        "summary": data["summary"],
        "hosts": data["hosts"],
        "services": data["services"],
        "resources": data["resources"],
        "oracle": data["oracle"],
        "alerts": data["alerts"],
    }
    return json.dumps(payload, indent=2, sort_keys=True) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--no-send",
        action="store_true",
        help="Generate and validate the report without sending email.",
    )
    parser.add_argument(
        "--force-send",
        action="store_true",
        help="Send even when this period already has a .sent marker.",
    )
    parser.add_argument(
        "--window-minutes",
        type=int,
        help="Use a trailing test window instead of the completed business week.",
    )
    parser.add_argument(
        "--end",
        help="Override the current time with an ISO-8601 timestamp.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    timezone_name = required_env("REPORT_TIMEZONE")
    try:
        timezone = ZoneInfo(timezone_name)
    except Exception as exc:
        raise ReportError(f"Invalid report timezone {timezone_name}: {exc}") from exc
    environment = required_env("REPORT_ENVIRONMENT")
    if not SAFE_ENVIRONMENT.fullmatch(environment):
        raise ReportError("REPORT_ENVIRONMENT contains unsupported characters")
    now = parse_end(args.end, timezone)
    if args.window_minutes is not None:
        if args.window_minutes < 1 or args.window_minutes > 20160:
            raise ReportError("--window-minutes must be between 1 and 20160")
        end = now
        start = end - timedelta(minutes=args.window_minutes)
        report_suffix = f"sample-{end.strftime('%Y%m%d-%H%M%S')}"
    else:
        start, end = latest_completed_window(now)
        report_suffix = end.strftime("%Y-%m-%d")
    if end <= start:
        raise ReportError("Report window end must be after its start")

    output_dir = Path(required_env("REPORT_OUTPUT_DIR"))
    output_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(output_dir, 0o700)
    retention_days = int(os.environ.get("REPORT_RETENTION_DAYS", "90"))
    warning = float(os.environ.get("REPORT_AVAILABILITY_WARNING", "99"))
    critical = float(os.environ.get("REPORT_AVAILABILITY_CRITICAL", "95"))
    scrape_interval_seconds = int(
        os.environ.get("REPORT_SCRAPE_INTERVAL_SECONDS", "15")
    )
    if not 0 <= critical <= warning <= 100:
        raise ReportError("Availability thresholds must satisfy 0 <= critical <= warning <= 100")
    if not 5 <= scrape_interval_seconds <= 300:
        raise ReportError("REPORT_SCRAPE_INTERVAL_SECONDS must be between 5 and 300")
    chrome = Path(required_env("REPORT_CHROME_BINARY"))
    title = os.environ.get("REPORT_TITLE", "Weekly Infrastructure Health Report")
    brand = os.environ.get("REPORT_BRAND", "Infrastructure Operations")
    prometheus = PrometheusClient(required_env("REPORT_PROMETHEUS_URL"))
    base = f"{slug(environment)}-weekly-{report_suffix}"
    pdf_path = output_dir / f"{base}.pdf"
    json_path = output_dir / f"{base}.json"
    sent_marker = output_dir / f"{base}.sent"

    lock_path = output_dir / ".weekly-report.lock"
    with lock_path.open("w", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ReportError("Another weekly report process is already running") from exc
        data = fetch_report_data(
            prometheus,
            environment,
            start,
            end,
            scrape_interval_seconds,
        )
        generated = datetime.now(timezone)
        report_html = render_html(
            title,
            brand,
            environment,
            start,
            end,
            generated,
            data,
            warning,
            critical,
        )
        render_pdf(chrome, report_html, pdf_path)
        atomic_text(
            json_path,
            metadata_document(environment, start, end, generated, data),
        )
        email_status = "disabled"
        if env_bool("REPORT_EMAIL_ENABLED") and not args.no_send:
            if sent_marker.exists() and not args.force_send:
                email_status = "already-sent"
            else:
                message_id = send_email(
                    pdf_path, environment, start, end, generated, data
                )
                atomic_text(
                    sent_marker,
                    json.dumps(
                        {
                            "sent_at": generated.isoformat(),
                            "message_id": message_id,
                        },
                        sort_keys=True,
                    )
                    + "\n",
                )
                email_status = "sent"
        elif args.no_send:
            email_status = "suppressed-by-cli"
        remove_expired_reports(output_dir, retention_days, generated)

    print(f"report_pdf={pdf_path}")
    print(f"report_pdf_bytes={pdf_path.stat().st_size}")
    print(f"report_window_start={start.isoformat()}")
    print(f"report_window_end={end.isoformat()}")
    print(f"report_email={email_status}")
    print(f"report_hosts={data['summary']['hosts_total']}")
    print(f"report_services={data['summary']['services_total']}")
    print(
        "report_telemetry_coverage="
        f"{data['summary']['telemetry_coverage']:.2f}%"
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ReportError as exc:
        print(f"weekly-report error: {exc}", file=sys.stderr)
        sys.exit(1)
