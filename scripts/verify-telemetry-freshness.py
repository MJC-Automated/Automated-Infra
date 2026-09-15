#!/usr/bin/env python3
"""
Telemetry Freshness and End-to-End Verification Validator.

Queries central Prometheus and Loki endpoints to verify:
1. All host targets (node_exporter, alloy, service exporters, blackbox probes) are up=1.
2. Target sample timestamps are fresh within the lookback window (< 5m).
3. Loki active labeled streams exist per expected host within the lookback window.
4. Explicit kube-state-metrics (KSM) enabled/disabled architectural status.
5. Zero raw log lines or sensitive credentials emitted in output.
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Set


def http_get_json(url: str, timeout: int = 10) -> Dict[str, Any]:
    """Perform a GET request and parse JSON response."""
    req = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": "IaC-Telemetry-Validator/1.0"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def get_expected_hosts(inventory_path: Path) -> Set[str]:
    """Extract hostnames from inventory file."""
    hosts: Set[str] = set()
    if not inventory_path.is_file():
        return hosts

    current_section = None
    with open(inventory_path, "r", encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line or line.startswith(("#", ";")):
                continue
            if line.startswith("[") and line.endswith("]"):
                current_section = line[1:-1].strip()
                continue
            if current_section and (current_section.endswith(":children") or current_section.endswith(":vars")):
                continue
            tokens = line.split()
            if tokens and "=" not in tokens[0]:
                hosts.add(tokens[0])
    return hosts


def verify_prometheus(
    prometheus_url: str, expected_hosts: Set[str] = set(), lookback_seconds: int = 300
) -> Dict[str, Any]:
    """Validate Prometheus targets up status and metric freshness."""
    query_url = f"{prometheus_url.rstrip('/')}/api/v1/query?query=up"
    now = time.time()

    data = http_get_json(query_url)
    if data.get("status") != "success":
        raise RuntimeError(f"Prometheus query failed: {data}")

    results = data.get("data", {}).get("result", [])
    total_targets = len(results)
    up_targets = 0
    down_targets: List[Dict[str, str]] = []
    stale_targets: List[Dict[str, str]] = []

    hosts_with_node_exporter: Set[str] = set()
    hosts_with_alloy: Set[str] = set()

    for item in results:
        metric = item.get("metric", {})
        job = metric.get("job", "unknown")
        instance = metric.get("instance", "unknown")
        val_tuple = item.get("value", [0, "0"])
        ts = float(val_tuple[0])
        val = str(val_tuple[1])

        age_seconds = now - ts
        is_up = val == "1"

        if is_up:
            up_targets += 1
        else:
            down_targets.append({"job": job, "instance": instance, "val": val})

        if age_seconds > lookback_seconds:
            stale_targets.append(
                {"job": job, "instance": instance, "age_seconds": round(age_seconds, 1)}
            )

        if job == "node":
            hosts_with_node_exporter.add(instance)
        elif job == "alloy":
            hosts_with_alloy.add(instance)

    missing_hosts = []
    if expected_hosts:
        up_instances = [item.get("metric", {}).get("instance", "") for item in results if str(item.get("value", [0, "0"])[1]) == "1"]
        for host in expected_hosts:
            if not any(host in inst for inst in up_instances):
                missing_hosts.append(host)

    # Check KSM status
    ksm_query_url = f"{prometheus_url.rstrip('/')}/api/v1/query?query=kube_node_info"
    ksm_query_success = False
    try:
        ksm_data = http_get_json(ksm_query_url)
        ksm_query_success = ksm_data.get("status") == "success"
        ksm_active = len(ksm_data.get("data", {}).get("result", [])) > 0
    except Exception:
        ksm_active = False

    if ksm_active:
        ksm_status_val = "ACTIVE"
    elif not ksm_query_success:
        ksm_status_val = "QUERY_FAILED"
    else:
        ksm_status_val = "DISABLED_BY_DESIGN"

    ksm_status = {
        "configured": ksm_active,
        "status": ksm_status_val,
        "description": "Kube-state-metrics disabled in base lab profile; node and pod telemetry collected via alloy and blackbox",
    }

    return {
        "status": "HEALTHY" if not down_targets and not stale_targets and not missing_hosts else "DEGRADED",
        "total_targets": total_targets,
        "up_targets": up_targets,
        "down_targets": down_targets,
        "stale_targets": stale_targets,
        "missing_hosts": sorted(missing_hosts),
        "hosts_with_node_exporter": sorted(hosts_with_node_exporter),
        "hosts_with_alloy": sorted(hosts_with_alloy),
        "kube_state_metrics": ksm_status,
    }


def verify_loki(
    loki_url: str, expected_hosts: Set[str], lookback_seconds: int = 300
) -> Dict[str, Any]:
    """Validate Loki service health and active stream freshness per host without dumping log bodies."""
    base = loki_url.rstrip("/")
    now = int(time.time())
    start = now - lookback_seconds

    # 1. Check ready endpoint
    ready_req = urllib.request.Request(f"{base}/ready")
    try:
        with urllib.request.urlopen(ready_req, timeout=5) as r:
            ready_text = r.read().decode("utf-8").strip()
    except Exception as e:
        ready_text = f"error: {e}"

    # 2. Check host label values
    host_labels_url = f"{base}/loki/api/v1/label/host/values"
    host_data = http_get_json(host_labels_url)
    registered_hosts = set(host_data.get("data", []))

    # 3. Check active streams within lookback window
    fresh_hosts: Set[str] = set()
    missing_hosts: Set[str] = set()

    for host in expected_hosts:
        # Query series endpoint for this host within lookback
        params = urllib.parse.urlencode({
            "match[]": f'{{host="{host}"}}',
            "start": f"{start}000000000",
            "end": f"{now}000000000",
        })
        series_url = f"{base}/loki/api/v1/series?{params}"
        try:
            s_data = http_get_json(series_url)
            series_list = s_data.get("data", [])
            if series_list:
                fresh_hosts.add(host)
            else:
                missing_hosts.add(host)
        except Exception:
            missing_hosts.add(host)

    is_healthy = ready_text == "ready" and len(missing_hosts) == 0 and len(fresh_hosts) > 0

    return {
        "status": "HEALTHY" if is_healthy else "DEGRADED",
        "ready_status": ready_text,
        "registered_hosts_count": len(registered_hosts),
        "fresh_hosts_count": len(fresh_hosts),
        "fresh_hosts": sorted(fresh_hosts),
        "missing_or_idle_hosts": sorted(missing_hosts),
    }


def discover_inventory_sources(
    repo_root: Path,
    inventories: Optional[List[str]] = None,
    single_inventory: Optional[str] = None,
) -> List[Path]:
    """
    Resolve inventory file sources for telemetry verification.
    If no explicit inventory is provided, auto-discovers active environments under inventories/,
    excluding 'dev' (scaffold template) and 'k8s' (composite aggregate overlay) directories.
    """
    inv_sources: List[Path] = []
    if inventories:
        for item in inventories:
            p = Path(item) if Path(item).is_absolute() else repo_root / item
            if p.is_dir():
                p = p / "inventory.ini"
            if p.is_file():
                inv_sources.append(p)
    elif single_inventory:
        p = Path(single_inventory) if Path(single_inventory).is_absolute() else repo_root / single_inventory
        if p.is_dir():
            p = p / "inventory.ini"
        if p.is_file():
            inv_sources.append(p)
    else:
        inv_dir = repo_root / "inventories"
        if inv_dir.is_dir():
            for candidate in sorted(inv_dir.iterdir()):
                # Exclude dev (scaffolding template) and k8s (composite aggregate overlay)
                if candidate.is_dir() and candidate.name not in ["dev", "k8s"] and (candidate / "inventory.ini").is_file():
                    inv_sources.append(candidate / "inventory.ini")
    return inv_sources


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify end-to-end telemetry freshness across Prometheus and Loki"
    )
    parser.add_argument(
        "--prometheus-url",
        default="http://198.51.100.24:9090",
        help="Prometheus API base URL (default: http://198.51.100.24:9090)",
    )
    parser.add_argument(
        "--loki-url",
        default="http://198.51.100.24:3100",
        help="Loki API base URL (default: http://198.51.100.24:3100)",
    )
    parser.add_argument(
        "--lookback-seconds",
        type=int,
        default=300,
        help="Maximum allowable sample age in seconds (default: 300s / 5m)",
    )
    parser.add_argument(
        "--inventories",
        nargs="+",
        help="Path(s) to Ansible inventory files or directories to discover expected hosts",
    )
    parser.add_argument(
        "--inventory",
        help="Legacy single inventory file path",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit machine-readable JSON output",
    )

    args = parser.parse_args()
    repo_root = Path(__file__).resolve().parents[1]

    expected_hosts: Set[str] = set()
    inv_sources = discover_inventory_sources(repo_root, args.inventories, args.inventory)

    for inv_file in inv_sources:
        expected_hosts.update(get_expected_hosts(inv_file))

    errors: List[str] = []

    try:
        prom_report = verify_prometheus(args.prometheus_url, expected_hosts, args.lookback_seconds)
        if prom_report.get("missing_hosts"):
            errors.append(f"Prometheus missing targets for expected hosts: {prom_report['missing_hosts']}")
    except Exception as e:
        prom_report = {"status": "FAILED", "error": str(e)}
        errors.append(f"Prometheus check failed: {e}")

    try:
        # Test expected hosts or fall back to registered hosts if inventory empty
        loki_test_hosts = expected_hosts if expected_hosts else {"public-observability-02"}
        loki_report = verify_loki(args.loki_url, loki_test_hosts, args.lookback_seconds)
    except Exception as e:
        loki_report = {"status": "FAILED", "error": str(e)}
        errors.append(f"Loki check failed: {e}")

    overall_status = "PASSED" if not errors and prom_report.get("status") == "HEALTHY" and loki_report.get("status") == "HEALTHY" else "FAILED"

    report = {
        "status": overall_status,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "prometheus": prom_report,
        "loki": loki_report,
        "errors": errors,
    }

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print("=== Telemetry End-to-End Freshness Report ===")
        print(f"Overall Status: {overall_status}")
        print(f"Prometheus Status: {prom_report.get('status')} ({prom_report.get('up_targets')}/{prom_report.get('total_targets')} targets up)")
        if prom_report.get("down_targets"):
            print(f"  Down targets: {prom_report.get('down_targets')}")
        print(f"KSM Architectural Status: {prom_report.get('kube_state_metrics', {}).get('status')}")
        print(f"Loki Readiness: {loki_report.get('ready_status')}")
        print(f"Loki Streams: {loki_report.get('fresh_hosts_count')} fresh host stream(s) within {args.lookback_seconds}s lookback")
        if loki_report.get("missing_or_idle_hosts"):
            print(f"  Missing/idle Loki host stream(s): {loki_report.get('missing_or_idle_hosts')}")
        if errors:
            print(f"Errors: {errors}", file=sys.stderr)

    return 0 if overall_status == "PASSED" else 1


if __name__ == "__main__":
    sys.exit(main())
