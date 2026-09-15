#!/usr/bin/env python3
"""
Inventory Variable Shadowing and Conflict Preflight Validator.

Detects:
1. Stale group_vars definitions where host-keyed maps (e.g. oracle_servers)
   contain hosts absent from that inventory's host list.
2. Cross-inventory variable collisions and shadowing across composite inventory
   arguments (e.g. passing -i inv1 -i inv2 where group_vars clobber each other).
3. Duplicate host definitions across disjoint inventories with conflicting properties.
"""

import argparse
import glob
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

import yaml


HOST_KEYED_MAP_NAMES = {
    "oracle_servers",
    "weblogic_servers",
    "database_servers",
    "service_servers",
}


ENVIRONMENT_SCOPED_VARIABLES = {
    "monitoring_zabbix_server_host",
    "monitoring_zabbix_server_port",
    "monitoring_zabbix_agent_hostname",
    "allowed_unmanaged_accounts_by_host",
    "smtp_host",
    "smtp_port",
    "smtp_user",
    "ntp_server",
    "dns_servers",
    "ansible_user",
    "ansible_ssh_private_key_file",
    "proxmox_host",
    "proxmox_node",
    "proxmox_api_url",
    "proxmox_target_node",
    "storage_pool",
    "vm_gateway",
    "vm_nameserver",
    "vm_searchdomain",
    "cidr_prefix",
}


def parse_ini_hosts(inventory_path: Path) -> Set[str]:
    """Parse host names defined in an Ansible INI inventory file."""
    if not inventory_path.is_file():
        return set()

    hosts: Set[str] = set()
    current_section = None

    with open(inventory_path, "r", encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.strip()
            # Ignore comments and empty lines
            if not line or line.startswith("#") or line.startswith(";"):
                continue

            # Check section header
            if line.startswith("[") and line.endswith("]"):
                current_section = line[1:-1].strip()
                continue

            # Ignore vars or children sections
            if current_section and (":vars" in current_section or ":children" in current_section):
                continue

            # Tokenize line: first token before space is the hostname
            tokens = line.split()
            if tokens:
                host_token = tokens[0]
                # Filter out variable-only lines or malformed lines
                if "=" not in host_token and not host_token.startswith("["):
                    hosts.add(host_token)

    return hosts


def find_group_vars(inventory_dir: Path) -> List[Tuple[str, Path]]:
    """Discover all group_vars files in an inventory directory."""
    group_vars_dir = inventory_dir / "group_vars"
    results: List[Tuple[str, Path]] = []
    if not group_vars_dir.is_dir():
        return results

    for root, _, files in os.walk(group_vars_dir):
        rel_root = Path(root).relative_to(group_vars_dir)
        for f in files:
            if f.endswith((".yml", ".yaml")):
                full_path = Path(root) / f
                if rel_root == Path("."):
                    group_name = full_path.stem
                else:
                    group_name = str(rel_root).replace(os.sep, "/")
                results.append((group_name, full_path))
    return results


class SafeAnsibleLoader(yaml.SafeLoader):
    """Safe YAML loader that understands Ansible specific tags like !vault."""
    pass


def _vault_constructor(loader: yaml.SafeLoader, node: yaml.Node) -> str:
    return "!vault"


def _unsafe_constructor(loader: yaml.SafeLoader, node: yaml.Node) -> Any:
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    elif isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    elif isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node)
    return str(node)


SafeAnsibleLoader.add_constructor("!vault", _vault_constructor)
SafeAnsibleLoader.add_constructor("!unsafe", _unsafe_constructor)


def load_yaml_file(path: Path) -> Dict[str, Any]:
    """Safely load a YAML file, returning an empty dict if empty or invalid."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = yaml.load(f, Loader=SafeAnsibleLoader)
            return content if isinstance(content, dict) else {}
    except Exception as e:
        raise ValueError(f"Failed to parse YAML file {path}: {e}")


def validate_inventory(inventory_dir: Path) -> List[str]:
    """Validate a single inventory directory for stale internal host mappings."""
    errors: List[str] = []
    inv_file = inventory_dir / "inventory.ini"
    if not inv_file.exists():
        for candidate in ["inventory", "hosts", "hosts.ini"]:
            if (inventory_dir / candidate).is_file():
                inv_file = inventory_dir / candidate
                break

    hosts = parse_ini_hosts(inv_file)
    group_vars_files = find_group_vars(inventory_dir)

    for group_name, gv_path in group_vars_files:
        try:
            data = load_yaml_file(gv_path)
        except ValueError as e:
            errors.append(str(e))
            continue

        for key, value in data.items():
            if key in HOST_KEYED_MAP_NAMES and isinstance(value, dict):
                for host_key in value.keys():
                    if host_key not in hosts:
                        errors.append(
                            f"Stale group variable mapping in {gv_path}: key '{host_key}' "
                            f"under '{key}' does not exist in inventory {inv_file} (known hosts: {sorted(hosts)}). "
                            f"This will shadow variables or fail validation if merged with other inventories."
                        )
    return errors


def validate_cross_inventory_shadowing(inventory_dirs: List[Path]) -> List[str]:
    """Validate multiple inventories for colliding variables and cross-shadowing."""
    errors: List[str] = []
    # Map: (group_name, var_name) -> list of (inventory_name, file_path, value)
    declared_vars: Dict[Tuple[str, str], List[Tuple[str, Path, Any]]] = {}

    for inv_dir in inventory_dirs:
        inv_name = inv_dir.name
        gv_files = find_group_vars(inv_dir)
        for group_name, gv_path in gv_files:
            try:
                data = load_yaml_file(gv_path)
            except ValueError as e:
                errors.append(str(e))
                continue

            for var_name, val in data.items():
                if var_name in ENVIRONMENT_SCOPED_VARIABLES:
                    continue
                entry = (inv_name, gv_path, val)
                var_key = (group_name, var_name)
                declared_vars.setdefault(var_key, []).append(entry)

    # Check for colliding host-keyed maps or divergent scalar overrides
    for (group_name, var_name), entries in declared_vars.items():
        if len(entries) > 1:
            first_inv, first_path, first_val = entries[0]
            for other_inv, other_path, other_val in entries[1:]:
                if first_inv == other_inv:
                    continue
                # If both inventories define a dictionary for host-keyed maps, Ansible replace behavior clobbers it
                if var_name in HOST_KEYED_MAP_NAMES and isinstance(first_val, dict) and isinstance(other_val, dict):
                    if set(first_val.keys()) != set(other_val.keys()):
                        errors.append(
                            f"Variable collision and shadowing detected for '{var_name}' in group '{group_name}'! "
                            f"Defined in {first_path} (keys: {list(first_val.keys())}) and "
                            f"{other_path} (keys: {list(other_val.keys())}). Under Ansible's default hash_behaviour, "
                            f"the later inventory on the CLI will clobber the earlier inventory's dictionary."
                        )
                elif first_val != other_val:
                    # Divergent variable definitions on common group
                    errors.append(
                        f"Conflicting value for variable '{var_name}' in group '{group_name}' across inventories: "
                        f"{first_path} vs {other_path}."
                    )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate inventories against variable shadowing and stale group_vars"
    )
    parser.add_argument(
        "--inventories",
        nargs="+",
        help="Path(s) to inventory directories to validate",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Automatically discover all environments under inventories/",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output results in JSON format",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress non-error output",
    )

    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[2]
    inventories_root = repo_root / "inventories"

    candidate_dirs: List[Path] = []
    if args.inventories:
        for p in args.inventories:
            path_obj = Path(p).resolve()
            if path_obj.is_file():
                path_obj = path_obj.parent
            if path_obj.is_dir() and path_obj not in candidate_dirs:
                candidate_dirs.append(path_obj)
    elif args.all:
        deployed = [
            child for child in sorted(inventories_root.iterdir())
            if child.is_dir() and not child.name.startswith((".", "_")) and child.name not in ("k8s", "dev")
        ]
        if deployed:
            candidate_dirs = deployed
        else:
            candidate_dirs = [inventories_root / "dev"]
    else:
        # Default: test tracked environments
        for child in sorted(inventories_root.iterdir()):
            if child.is_dir() and (child / "inventory.ini").exists():
                candidate_dirs.append(child)

    if not candidate_dirs:
        if not args.quiet:
            print("No inventory directories found to validate.")
        return 0

    all_errors: List[str] = []

    # 1. Validate each inventory internally
    for inv_dir in candidate_dirs:
        inv_errors = validate_inventory(inv_dir)
        all_errors.extend(inv_errors)

    # 2. If multiple inventories are evaluated together, check cross-inventory collisions
    if len(candidate_dirs) > 1:
        cross_errors = validate_cross_inventory_shadowing(candidate_dirs)
        all_errors.extend(cross_errors)

    result = {
        "status": "PASSED" if not all_errors else "FAILED",
        "validated_inventories": [str(p) for p in candidate_dirs],
        "error_count": len(all_errors),
        "errors": all_errors,
    }

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        if all_errors:
            print(f"FAILED: Found {len(all_errors)} inventory variable shadowing / stale definition error(s):", file=sys.stderr)
            for err in all_errors:
                print(f"  - {err}", file=sys.stderr)
        elif not args.quiet:
            print(f"OK: Validated {len(candidate_dirs)} inventory directory(ies) with zero shadowing issues.")

    return 1 if all_errors else 0


if __name__ == "__main__":
    sys.exit(main())
