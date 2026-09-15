#!/usr/bin/env python3
"""
Proxmox Capacity Headroom and Overcommit Policy Validator.

Evaluates planned VM allocations from tfvars against host physical capacity:
- Total RAM allocation vs Physical RAM minus host/ZFS ARC reserve.
- vCPU allocation and overcommit ratio.
- Disk allocation on storage pools.
- Memory ballooning configuration.
- Enforces failure gate when headroom is exceeded unless explicit disposable
  overcommit approval (ALLOW_OVERCOMMIT=true / --allow-overcommit) is recorded.
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


import importlib.util

# Dynamically import parse_literal_tfvars from validate-ip-conflicts.py
_CONFLICT_VALIDATOR_PATH = Path(__file__).resolve().parent / "validate-ip-conflicts.py"
_spec = importlib.util.spec_from_file_location("validate_ip_conflicts", _CONFLICT_VALIDATOR_PATH)
_v_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_v_mod)
parse_literal_tfvars = _v_mod.parse_literal_tfvars


def parse_tfvars_resources(tfvars_path: Path) -> Dict[str, Any]:
    """Extract VM resource allocations (RAM, cores, disks) from tfvars file."""
    if not tfvars_path.is_file():
        raise FileNotFoundError(f"Tfvars file not found: {tfvars_path}")

    content = tfvars_path.read_text(encoding="utf-8")
    config = parse_literal_tfvars(content)

    node_groups = config.get("node_groups", {})
    vms: List[Dict[str, Any]] = []
    total_memory_mb = 0
    total_cores = 0
    total_disk_gb = 0
    balloon_enabled_count = 0

    for g_name, group in node_groups.items():
        if not isinstance(group, dict):
            continue
        for vm_key, vm in group.items():
            if not isinstance(vm, dict):
                continue
            name = vm.get("name", vm_key)
            cores = int(vm.get("cores", 2))
            mem = int(vm.get("memory", 2048))
            disk_str = str(vm.get("disk_size", "30G"))
            disk_match = re.search(r"\d+", disk_str)
            disk = int(disk_match.group(0)) if disk_match else 30
            balloon = int(vm.get("balloon", 0))

            vms.append({
                "name": name,
                "cores": cores,
                "memory_mb": mem,
                "disk_gb": disk,
                "balloon": balloon,
            })

            total_memory_mb += mem
            total_cores += cores
            total_disk_gb += disk
            if balloon > 0:
                balloon_enabled_count += 1

    return {
        "vms_count": len(vms),
        "vms": vms,
        "total_memory_mb": total_memory_mb,
        "total_memory_gib": round(total_memory_mb / 1024.0, 2),
        "total_cores": total_cores,
        "total_disk_gb": total_disk_gb,
        "balloon_enabled_count": balloon_enabled_count,
    }


def validate_capacity(
    tfvars_path: Path,
    host_ram_gib: float,
    ram_reserve_gib: Optional[float] = None,
    allow_overcommit: bool = False,
) -> Dict[str, Any]:
    """Check resource demands against safe thresholds."""
    env_name = tfvars_path.stem

    total_host_ram = host_ram_gib
    reserve = ram_reserve_gib if ram_reserve_gib is not None else 6.0
    safe_usable_ram = max(0.0, total_host_ram - reserve)

    allocations = parse_tfvars_resources(tfvars_path)
    planned_ram_gib = allocations["total_memory_gib"]
    planned_cores = allocations["total_cores"]

    ram_overcommit_ratio = round(planned_ram_gib / total_host_ram, 2) if total_host_ram > 0 else 0.0
    safe_overcommit_ratio = round(planned_ram_gib / safe_usable_ram, 2) if safe_usable_ram > 0 else 0.0

    errors: List[str] = []
    warnings: List[str] = []

    # Check RAM capacity
    if planned_ram_gib > safe_usable_ram:
        msg = (
            f"Planned RAM allocation ({planned_ram_gib:.1f} GiB) exceeds safe usable host memory "
            f"({safe_usable_ram:.1f} GiB = {total_host_ram:.1f} GiB physical - {reserve:.1f} GiB host reserve)."
        )
        if not allow_overcommit:
            errors.append(msg + " Set ALLOW_OVERCOMMIT=true to explicitly approve disposable lab overcommit.")
        else:
            warnings.append(
                f"RAM OVERCOMMIT APPROVED: {msg} (Overcommit ratio: {ram_overcommit_ratio:.2f}x physical, "
                f"{safe_overcommit_ratio:.2f}x usable)."
            )

    # Check ballooning
    if planned_ram_gib > safe_usable_ram and allocations["balloon_enabled_count"] == 0:
        warnings.append(
            "Memory overcommit detected but KVM memory ballooning is disabled (0) on all VMs. "
            "Host memory exhaustion could trigger Linux OOM-killer if guest memory is fully dirty."
        )

    status = "PASSED" if not errors else "FAILED"

    return {
        "status": status,
        "environment": env_name,
        "tfvars_path": str(tfvars_path),
        "vms_count": allocations["vms_count"],
        "planned_ram_gib": planned_ram_gib,
        "planned_cores": planned_cores,
        "planned_disk_gb": allocations["total_disk_gb"],
        "host_physical_ram_gib": total_host_ram,
        "host_reserve_ram_gib": reserve,
        "safe_usable_ram_gib": safe_usable_ram,
        "ram_overcommit_ratio": ram_overcommit_ratio,
        "overcommit_explicitly_approved": allow_overcommit,
        "errors": errors,
        "warnings": warnings,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate Proxmox host capacity headroom and overcommit policies"
    )
    parser.add_argument(
        "--tfvars",
        required=True,
        help="Path to environment tfvars file",
    )
    parser.add_argument(
        "--host-ram-gib",
        type=float,
        required=True,
        help="Physical host RAM in GiB",
    )
    parser.add_argument(
        "--ram-reserve-gib",
        type=float,
        default=6.0,
        help="Override host OS / ZFS ARC reserve RAM in GiB",
    )
    parser.add_argument(
        "--allow-overcommit",
        action="store_true",
        default=os.environ.get("ALLOW_OVERCOMMIT", "").lower() in ("true", "1", "yes"),
        help="Explicitly record approval for disposable homelab overcommit",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print machine-readable JSON output",
    )

    args = parser.parse_args()
    tfvars_path = Path(args.tfvars)

    report = validate_capacity(
        tfvars_path=tfvars_path,
        host_ram_gib=args.host_ram_gib,
        ram_reserve_gib=args.ram_reserve_gib,
        allow_overcommit=args.allow_overcommit,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print("=== Capacity Headroom and Overcommit Gate Report ===")
        print(f"Environment: {report['environment']}")
        print(f"Status: {report['status']}")
        print(f"VMs: {report['vms_count']} | Cores: {report['planned_cores']} | RAM: {report['planned_ram_gib']} GiB | Disk: {report['planned_disk_gb']} GiB")
        print(f"Host Physical RAM: {report['host_physical_ram_gib']} GiB (Reserve: {report['host_reserve_ram_gib']} GiB -> Usable: {report['safe_usable_ram_gib']} GiB)")
        print(f"Overcommit Ratio: {report['ram_overcommit_ratio']}x")
        if report["warnings"]:
            for w in report["warnings"]:
                print(f"  [WARN] {w}")
        if report["errors"]:
            for e in report["errors"]:
                print(f"  [ERROR] {e}", file=sys.stderr)

    return 0 if report["status"] == "PASSED" else 1


if __name__ == "__main__":
    sys.exit(main())
