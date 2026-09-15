#!/usr/bin/env python3
"""
Cross-Environment IP Overlap and Conflict Validator
Ensures that no VM in the candidate environment has an IP address (IPv4/IPv6),
VMID, or hostname overlapping with:
  1. Other VMs within the same environment (intra-environment).
  2. VMs in other environment configuration files (environments/*.tfvars).
  3. Deployed VMs in other environments' Ansible inventories (inventories/*/inventory.ini).
  4. Core network infrastructure IPs (gateways, Proxmox hypervisors, Ansible control hosts).
  5. Unmanaged live network devices (via optional ICMP probe for new allocations).
"""

import argparse
import glob
import ipaddress
import json
import os
import re
import shlex
import subprocess
import sys
from typing import Dict, List, Tuple
from urllib.parse import urlsplit


def parse_literal_tfvars(text: str) -> Dict:
    """Read literal HCL attributes, maps, lists and heredocs; reject expressions.

    This is deliberately not an HCL evaluator. Unsupported syntax must stop the
    guard, never silently omit a VM. Strings and comments are tokenized together
    so braces or comment markers inside strings cannot change object boundaries.
    """
    token = re.compile(
        r'(?P<space>\s+|\#[^\n]*|//[^\n]*|/\*.*?\*/)'
        r'|(?P<heredoc><<-?(?P<marker>[A-Za-z_][\w-]*)[^\S\n]*\n.*?^\s*(?P=marker)[^\S\n]*(?:\n|$))'
        r'|(?P<string>"(?:[^"\\]|\\.)*")'
        r'|(?P<number>-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)'
        r'|(?P<word>[A-Za-z_][\w-]*)|(?P<punct>[{}\[\]=,:])',
        re.DOTALL | re.MULTILINE,
    )
    tokens = []
    pos = 0
    while pos < len(text):
        match = token.match(text, pos)
        if not match:
            raise ValueError(f"Unsupported tfvars syntax at line {text.count(chr(10), 0, pos) + 1}; use literal values")
        pos = match.end()
        if match.lastgroup != 'space':
            tokens.append((match.lastgroup, match.group()))
    index = 0

    def take():
        nonlocal index
        if index >= len(tokens):
            raise ValueError("Unexpected end of tfvars")
        item = tokens[index]
        index += 1
        return item

    def mapping(end=None):
        result = {}
        while index < len(tokens) and tokens[index][1] != end:
            kind, key = take()
            if kind not in ('word', 'string'):
                raise ValueError("Expected a literal attribute name in tfvars")
            if kind == 'string':
                key = json.loads(key)
            if key in result:
                raise ValueError(f"Duplicate tfvars attribute: {key}")
            if take()[1] not in ('=', ':'):
                raise ValueError("Expected '=' in tfvars attribute")
            result[key] = value()
            if index < len(tokens) and tokens[index][1] == ',':
                take()
        if end:
            if take()[1] != end:
                raise ValueError("Unclosed tfvars object")
        return result

    def value():
        kind, item = take()
        if item == '{':
            return mapping('}')
        if item == '[':
            result = []
            while index < len(tokens) and tokens[index][1] != ']':
                result.append(value())
                if index < len(tokens) and tokens[index][1] == ',':
                    take()
                elif index < len(tokens) and tokens[index][1] != ']':
                    raise ValueError("Expected ',' in tfvars list")
            if take()[1] != ']':
                raise ValueError("Unclosed tfvars list")
            return result
        if kind in ('string', 'number'):
            result = json.loads(item)
            if kind == 'string' and re.search(r'(?<!\$)\$\{|(?<!%)%\{', result):
                raise ValueError("HCL template expressions are unsupported; use literal values")
            return result.replace('$${', '${').replace('%%{', '%{') if kind == 'string' else result
        if kind == 'heredoc':
            result = '\n'.join(item.splitlines()[1:-1]) + '\n'
            if re.search(r'(?<!\$)\$\{|(?<!%)%\{', result):
                raise ValueError("HCL heredoc expressions are unsupported; use literal values")
            return result
        if item in ('true', 'false', 'null'):
            return json.loads(item)
        raise ValueError("Unsupported tfvars expression; use literal values")

    return mapping()


def network_fields(ipconfig: str) -> Dict:
    """Validate the QEMU cloud-init property string before comparing addresses."""
    fields = {}
    seen = set()
    if not ipconfig:
        return fields  # Unconfigured NICs in existing state may use DHCP.
    for part in ipconfig.split(','):
        key, separator, raw = part.strip().partition('=')
        if not separator or key not in ('ip', 'ip6', 'gw', 'gw6') or not raw:
            raise ValueError('ipconfig0 must contain ip/ip6/gw/gw6 key=value entries')
        if key in seen:
            raise ValueError(f'Duplicate ipconfig0 property: {key}')
        seen.add(key)
        if (key == 'ip' and raw == 'dhcp') or (key == 'ip6' and raw in ('dhcp', 'auto')):
            continue
        if key.startswith('gw'):
            address = ipaddress.ip_address(raw)
        else:
            if '/' not in raw:
                raise ValueError(f'Static {key} requires a CIDR prefix')
            interface = ipaddress.ip_interface(raw)
            address = interface.ip
            if (address.version == 4 and interface.network.prefixlen < 31
                    and address in (interface.network.network_address, interface.network.broadcast_address)):
                raise ValueError(f'{key} uses the subnet network or broadcast address')
        if address.version != (6 if key.endswith('6') else 4):
            raise ValueError(f"Wrong address family for {key}")
        if address.is_unspecified or address.is_loopback or address.is_multicast:
            raise ValueError(f'{key} must be a unicast guest or gateway address')
        fields[key] = str(address)
    for gateway, address in (('gw', 'ip'), ('gw6', 'ip6')):
        if gateway in seen and address not in seen:
            raise ValueError(f'{gateway} requires an explicit {address} configuration')
    return fields


def validate_vlan(value):
    if isinstance(value, str) and value.isdecimal():
        value = int(value)
    if type(value) not in (int, float) or not 0 <= value <= 4094 or int(value) != value:
        raise ValueError("VLAN must be an integer from 0 through 4094")
    return int(value)


def validate_vmid(value):
    if isinstance(value, str) and value.isdecimal():
        value = int(value)
    if type(value) not in (int, float) or not 100 <= value <= 999999999 or int(value) != value:
        raise ValueError('VMID must be an integer from 100 through 999999999')
    return int(value)


NETWORK_VARIABLES = ('network_vlan', 'vm_defaults', 'node_groups')


def read_network_variables(path: str) -> Dict:
    with open(path, encoding='utf-8') as stream:
        config = json.load(stream) if path.endswith('.json') else parse_literal_tfvars(stream.read())
    if not isinstance(config, dict):
        raise ValueError('Variable files must contain an attribute object')
    return {key: config[key] for key in NETWORK_VARIABLES if key in config}


def load_network_defaults(repo_root: str, command: str) -> Dict:
    """Model Terraform input precedence before Make's final environment file.

    Maps are replaced, not deep-merged. Keep only allocation-related variables;
    unrelated authentication settings never enter the conflict report.
    """
    config = {}
    for key in NETWORK_VARIABLES:
        raw = os.getenv('TF_VAR_' + key)
        if raw is not None:
            config.update(parse_literal_tfvars(f'{key} = {raw}'))
    for name in ('terraform.tfvars', 'terraform.tfvars.json'):
        path = os.path.join(repo_root, name)
        if os.path.isfile(path):
            config.update(read_network_variables(path))
    automatic_files = sorted(
        glob.glob(os.path.join(repo_root, '*.auto.tfvars'))
        + glob.glob(os.path.join(repo_root, '*.auto.tfvars.json'))
    )
    for path in automatic_files:
        config.update(read_network_variables(path))

    # Terraform prepends global args first, then prepends command-specific args.
    # Thus global assignments occur later and win over command-specific ones.
    arguments = (shlex.split(os.getenv('TF_CLI_ARGS_' + command, ''))
                 + shlex.split(os.getenv('TF_CLI_ARGS', '')))
    index = 0
    while index < len(arguments):
        flag, separator, value = arguments[index].partition('=')
        index += 1
        if flag not in ('-var', '--var', '-var-file', '--var-file'):
            continue
        if not separator:
            if index == len(arguments):
                raise ValueError(f'{flag} in TF_CLI_ARGS requires a value')
            value = arguments[index]
            index += 1
        if flag in ('-var-file', '--var-file'):
            config.update(read_network_variables(os.path.join(repo_root, value)))
        else:
            key, equals, raw = value.partition('=')
            if not equals:
                raise ValueError('TF_CLI_ARGS -var requires name=value')
            if key in NETWORK_VARIABLES:
                config.update(parse_literal_tfvars(f'{key} = {raw}'))
    return config


def parse_tfvars_vms(tfvars_path: str, base_config=None) -> Tuple[str, int, List[Dict]]:
    """
    Parse a .tfvars file and extract VMs defined in node_groups.
    Returns (env_name, default_vlan, list_of_vms).
    """
    if not os.path.isfile(tfvars_path):
        return "", 0, []

    with open(tfvars_path, "r", encoding="utf-8") as f:
        raw_content = f.read()

    config = {**(base_config or {}), **parse_literal_tfvars(raw_content)}
    env_name = config.get('environment_name', os.path.basename(tfvars_path).removesuffix('.tfvars'))
    defaults = config.get('vm_defaults') or {}
    default_vlan = validate_vlan(defaults.get('network_vlan') if defaults.get('network_vlan') is not None else config.get('network_vlan', 0))
    vms = []
    for group in config.get('node_groups', {}).values():
        for vm in group.values():
            vms.append({
                'name': vm['name'].strip(),
                'vmid': validate_vmid(vm['vmid']),
                'ipconfig0': vm['ipconfig0'],
                **network_fields(vm['ipconfig0']),
                'vlan': validate_vlan(vm.get('network_vlan') if vm.get('network_vlan') is not None else default_vlan),
                'source_file': tfvars_path,
                'source_env': env_name,
            })

    return env_name, default_vlan, vms


def parse_inventory_vms(inventory_path: str) -> Tuple[str, List[Dict]]:
    """
    Parse an inventory.ini file and extract deployed hosts.
    Returns (env_name, list_of_hosts).
    """
    if not os.path.isfile(inventory_path):
        return "", []

    env_name = os.path.basename(os.path.dirname(inventory_path))
    hosts = []

    with open(inventory_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("[") or line.startswith(";"):
                continue

            parts = shlex.split(line, comments=True)
            attributes = dict(part.split('=', 1) for part in parts[1:] if '=' in part)
            if 'ansible_host' in attributes:
                try:
                    address = ipaddress.ip_address(attributes['ansible_host'])
                except ValueError:
                    continue  # DNS inventory names do not specify an IP allocation.
                hosts.append({
                    "name": parts[0],
                    "ip" if address.version == 4 else "ip6": str(address),
                    "vmid": int(attributes['vmid']) if 'vmid' in attributes else None,
                    "vlan": validate_vlan(int(attributes['network_vlan'])) if 'network_vlan' in attributes else None,
                    "source_file": inventory_path,
                    "source_env": env_name,
                })

    return env_name, hosts


def parse_env_infrastructure_ips(env_file: str) -> Dict[str, str]:
    """Extract known infrastructure host IPs from .env (Proxmox nodes, Ansible hosts, etc.)."""
    infra_ips: Dict[str, str] = {}
    values = {}
    if os.path.isfile(env_file):
        with open(env_file, "r", encoding="utf-8") as f:
            for line in f:
                match = re.match(r'^\s*(?:export\s+)?([A-Z0-9_]+)\s*=\s*(.*)', line)
                if match:
                    parts = shlex.split(match[2], comments=True)
                    if parts:
                        values[match[1]] = parts[0]
    values.update(os.environ)
    for key, value in values.items():
        if not any(sub in key for sub in ('PROXMOX', 'PVE', 'ANSIBLE', 'GATEWAY', 'GW')):
            continue
        try:
            host = urlsplit(value).hostname if '://' in value else value
            infra_ips[str(ipaddress.ip_address(host))] = f"infrastructure setting {key}"
        except ValueError:
            continue

    return infra_ips


def probe_ip_live(ip: str, timeout_sec: int = 1) -> bool:
    """Ping an IP with 1 packet and short timeout. Returns True if host answers."""
    try:
        family = '-6' if ipaddress.ip_address(ip).version == 6 else '-4'
        cmd = ["ping", family, "-c", "1", "-W", str(timeout_sec), ip]
        res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout_sec + 2)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"Cannot probe {ip}: ping unavailable or timed out") from exc
    if res.returncode not in (0, 1):
        raise RuntimeError(f"Cannot probe {ip}: ping failed (exit {res.returncode})")
    return res.returncode == 0


def same_network(left, right):
    # Missing inventory metadata is unknown. VLAN 0 means untagged, not wildcard.
    return left is None or right is None or left == right


def same_owner(left, right):
    # Names can change on an existing resource; VMID identifies the managed VM.
    return left.get('vmid') is not None and left.get('vmid') == right.get('vmid')


def load_managed_vms(repo_root: str, environment: str) -> List[Dict]:
    """Read the selected workspace without selecting/mutating the active workspace."""
    try:
        result = subprocess.run(
            ['terraform', 'state', 'pull'], cwd=repo_root,
            env={**os.environ, 'TF_WORKSPACE': environment},
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError('Unable to read Terraform state for IP ownership') from exc
    if result.returncode:
        if result.stderr.strip() == 'No state file was found!':
            return []
        raise RuntimeError('Unable to read Terraform state for IP ownership; check backend access')
    if not result.stdout.strip():
        return []  # terraform state pull on a workspace with no state yet
    state = json.loads(result.stdout)
    if not isinstance(state.get('resources'), list):
        raise ValueError('Terraform state has no resources list')
    hosts = []
    for resource in state['resources']:
        if resource.get('mode') != 'managed' or resource.get('type') != 'proxmox_vm_qemu':
            continue
        for instance in resource.get('instances', []):
            attrs = instance['attributes']
            networks = attrs.get('network') or []
            primary = next((n for n in networks if n.get('id', 0) == 0), {})
            hosts.append({
                'name': attrs['name'], 'vmid': int(attrs['vmid']),
                # Provider state may represent an unset tag as null, 0, or -1.
                'vlan': max(0, int(primary.get('tag') or 0)),
                **network_fields(attrs.get('ipconfig0') or ''),
            })
    return hosts


def main():
    parser = argparse.ArgumentParser(description="Cross-environment IP overlap and conflict detector.")
    parser.add_argument("--environment", "-e", required=True, help="Target environment name (e.g. optiplex, example).")
    parser.add_argument("--repo-root", "-r", default=".", help="Root of terraform-proxmox directory.")
    parser.add_argument("--skip-live-probe", action="store_true", help="Skip active ICMP ping check on the wire.")
    parser.add_argument("--warn-only", action="store_true", help="Print warnings but exit 0 (override mode).")
    args = parser.parse_args()

    env_name = args.environment
    repo_root = os.path.abspath(args.repo_root)

    use_color = os.getenv("NO_COLOR", "") == ""
    RED = "\033[0;31m" if use_color else ""
    GREEN = "\033[0;32m" if use_color else ""
    YELLOW = "\033[0;33m" if use_color else ""
    CYAN = "\033[0;36m" if use_color else ""
    BOLD = "\033[1m" if use_color else ""
    NC = "\033[0m" if use_color else ""

    tfvars_candidate = os.path.join(repo_root, "environments", f"{env_name}.tfvars")
    if not os.path.isfile(tfvars_candidate):
        print(f"{RED}Error: Candidate tfvars file not found: {tfvars_candidate}{NC}", file=sys.stderr)
        sys.exit(1)

    print(f"{CYAN}--- Checking cross-environment IP and resource conflicts for '{env_name}' ---{NC}")

    # 1. Parse candidate environment
    plan_defaults = load_network_defaults(repo_root, 'plan')
    apply_defaults = load_network_defaults(repo_root, 'apply')
    c_env, c_vlan, c_vms = parse_tfvars_vms(tfvars_candidate, plan_defaults)
    if c_vms != parse_tfvars_vms(tfvars_candidate, apply_defaults)[2]:
        raise ValueError('Snippet apply and plan resolve different VM allocations; align TF_CLI_ARGS_plan and TF_CLI_ARGS_apply')
    print(f"Candidate tfvars: {os.path.relpath(tfvars_candidate, repo_root)} ({len(c_vms)} VMs defined)")

    if not c_vms:
        print(f"{GREEN}✓ No VMs defined in {env_name}; no conflict possible.{NC}")
        sys.exit(0)

    # 2. Inventory is an allocation record, not proof of current VM ownership.
    cand_inv_path = os.path.join(repo_root, "..", "inventories", env_name, "inventory.ini")
    _, cand_existing_hosts = parse_inventory_vms(cand_inv_path)
    managed_hosts = load_managed_vms(repo_root, env_name) if not args.skip_live_probe else []

    # 3. Parse other environments' tfvars
    other_tfvars = sorted(glob.glob(os.path.join(repo_root, "environments", "*.tfvars")))
    other_env_vms: Dict[str, List[Dict]] = {}
    for path in other_tfvars:
        other_name = os.path.basename(path).replace(".tfvars", "")
        if other_name == env_name:
            continue
        o_name, _, o_vms = parse_tfvars_vms(path, plan_defaults)
        if o_vms:
            other_env_vms[other_name] = o_vms

    # 4. Parse other environments' inventories
    other_inv_files = sorted(glob.glob(os.path.join(repo_root, "..", "inventories", "*", "inventory.ini")))
    other_inv_hosts: Dict[str, List[Dict]] = {}
    for inv_p in other_inv_files:
        o_inv_env = os.path.basename(os.path.dirname(inv_p))
        # k8s is an aggregate inventory synthesized across environments; skip to avoid false self-conflicts
        if o_inv_env == env_name or o_inv_env == "k8s":
            continue
        _, inv_hosts = parse_inventory_vms(inv_p)
        if inv_hosts:
            other_inv_hosts[o_inv_env] = inv_hosts

    # 5. Parse infrastructure IPs
    env_file_path = os.getenv('ENV_FILE') or os.path.join(repo_root, ".env")
    infra_ips = parse_env_infrastructure_ips(env_file_path)

    # Conflict records: list of dicts describing the conflict
    conflicts: List[Dict] = []
    warnings: List[Dict] = []

    # -------------------------------------------------------------
    # Check A: Intra-environment conflicts
    # -------------------------------------------------------------
    seen_ips: Dict[str, Dict] = {}
    seen_vmids: Dict[int, Dict] = {}
    seen_names: Dict[str, Dict] = {}

    for vm in c_vms:
        ip = vm.get("ip")
        vmid = vm.get("vmid")
        name = vm.get("name")

        for field in ('ip', 'ip6'):
            address = vm.get(field)
            if not address:
                continue
            if address in seen_ips:
                conflicts.append({
                    "type": "INTRA_ENV_IP_DUPLICATE",
                    "severity": "ERROR",
                    "ip": address,
                    "vm": name,
                    "vmid": vmid,
                    "details": f"Duplicate IP within '{env_name}' (conflicts with VM '{seen_ips[address]['name']}')"
                })
            else:
                seen_ips[address] = vm

        if vmid:
            if vmid in seen_vmids:
                conflicts.append({
                    "type": "INTRA_ENV_VMID_DUPLICATE",
                    "severity": "ERROR",
                    "vmid": vmid,
                    "vm": name,
                    "details": f"Duplicate VMID {vmid} within '{env_name}' (conflicts with VM '{seen_vmids[vmid]['name']}')"
                })
            else:
                seen_vmids[vmid] = vm

        if name:
            if name in seen_names:
                conflicts.append({
                    "type": "INTRA_ENV_NAME_DUPLICATE",
                    "severity": "ERROR",
                    "vm": name,
                    "details": f"Duplicate VM name '{name}' within '{env_name}'"
                })
            else:
                seen_names[name] = vm

    # -------------------------------------------------------------
    # Check B: Infrastructure IP collisions (Gateways, PVE nodes, control hosts)
    # -------------------------------------------------------------
    all_configured = c_vms + [vm for group in other_env_vms.values() for vm in group]
    for vm in c_vms:
        for field, gateway in (('ip', 'gw'), ('ip6', 'gw6')):
            ip = vm.get(field)
            if not ip:
                continue
            if any(ip == other.get(gateway) and same_network(vm['vlan'], other['vlan']) for other in all_configured):
                conflicts.append({
                    'type': 'GATEWAY_COLLISION', 'ip': ip, 'vm': vm['name'], 'vmid': vm['vmid'],
                    'details': f"VM '{vm['name']}' assigned a configured gateway IP ({ip})",
                })
            if ip in infra_ips:
                conflicts.append({
                    'type': 'INFRASTRUCTURE_IP_COLLISION', 'ip': ip, 'vm': vm['name'], 'vmid': vm['vmid'],
                    'details': f"VM '{vm['name']}' assigned existing infrastructure host IP: {infra_ips[ip]}",
                })

    # -------------------------------------------------------------
    # Check C: Cross-environment .tfvars IP overlaps
    # -------------------------------------------------------------
    for vm in c_vms:
        ip = vm.get("ip")
        ip6 = vm.get("ip6")
        vmid = vm.get("vmid")
        name = vm.get("name")
        vlan = vm.get("vlan")

        for o_env, o_vms in other_env_vms.items():
            for o_vm in o_vms:
                o_ip = o_vm.get("ip")
                o_ip6 = o_vm.get("ip6")
                o_vmid = o_vm.get("vmid")
                o_name = o_vm.get("name")
                o_vlan = o_vm.get("vlan")

                # IPv4 overlap check
                if ip and o_ip and ip == o_ip:
                    if same_network(vlan, o_vlan):
                        conflicts.append({
                            "type": "CROSS_ENV_TFVARS_IP_OVERLAP",
                            "severity": "ERROR",
                            "ip": ip,
                            "vm": name,
                            "vmid": vmid,
                            "other_env": o_env,
                            "other_vm": o_name,
                            "other_vmid": o_vmid,
                            "details": (f"IPv4 {ip} overlaps with VM '{o_name}' (vmid: {o_vmid}) in "
                                        f"environments/{o_env}.tfvars (VLAN {vlan} vs {o_vlan})")
                        })

                # IPv6 overlap check
                if ip6 and o_ip6 and ip6 == o_ip6:
                    if same_network(vlan, o_vlan):
                        conflicts.append({
                            "type": "CROSS_ENV_TFVARS_IP6_OVERLAP",
                            "severity": "ERROR",
                            "ip": ip6,
                            "vm": name,
                            "vmid": vmid,
                            "other_env": o_env,
                            "other_vm": o_name,
                            "details": (f"IPv6 {ip6} overlaps with VM '{o_name}' in "
                                        f"environments/{o_env}.tfvars")
                        })

                # Cross-environment VMID duplicate check (Advisory Warning)
                if vmid and o_vmid and vmid == o_vmid:
                    warnings.append({
                        "type": "CROSS_ENV_VMID_DUPLICATE",
                        "vmid": vmid,
                        "vm": name,
                        "other_env": o_env,
                        "other_vm": o_name,
                        "details": (f"VMID {vmid} is also used by '{o_name}' in environments/{o_env}.tfvars. "
                                    f"Ensure nodes belong to separate clusters with unshared backup namespaces.")
                    })

                # Cross-environment Hostname duplicate check (Error)
                if name and o_name and name == o_name:
                    conflicts.append({
                        "type": "CROSS_ENV_HOSTNAME_DUPLICATE",
                        "severity": "ERROR",
                        "vm": name,
                        "other_env": o_env,
                        "details": f"VM name '{name}' is duplicated in environments/{o_env}.tfvars"
                    })

    # -------------------------------------------------------------
    # Check D: Cross-environment Inventory IP overlaps
    # -------------------------------------------------------------
    for vm in c_vms:
        name = vm.get("name")
        vmid = vm.get("vmid")
        vlan = vm.get("vlan")

        for o_env, o_hosts in other_inv_hosts.items():
            for o_host in o_hosts:
                o_name = o_host.get("name")
                o_vmid = o_host.get("vmid")
                o_vlan = o_host.get("vlan")

                for field in ('ip', 'ip6'):
                    ip = vm.get(field)
                    if ip and ip == o_host.get(field) and same_network(vlan, o_vlan):
                        already_flagged = any(
                            c.get("ip") == ip and c.get("other_env") == o_env
                            for c in conflicts
                        )
                        if not already_flagged:
                            conflicts.append({
                                "type": "CROSS_ENV_INVENTORY_IP_OVERLAP",
                                "severity": "ERROR",
                                "ip": ip,
                                "vm": name,
                                "vmid": vmid,
                                "other_env": o_env,
                                "other_vm": o_name,
                                "other_vmid": o_vmid,
                                "details": (f"IP {ip} overlaps with host '{o_name}' recorded in "
                                            f"inventories/{o_env}/inventory.ini")
                            })

    # -------------------------------------------------------------
    # Check E: Own-environment allocations and live probes for new addresses
    # -------------------------------------------------------------
    for vm in c_vms:
        for field in ('ip', 'ip6'):
            ip = vm.get(field)
            name = vm.get("name")
            vmid = vm.get("vmid")

            if not ip:
                continue

            owners = [h for h in managed_hosts
                      if h.get(field) == ip and same_network(vm['vlan'], h['vlan'])]
            # An allocation held by another VM must not be exempted from probing.
            for host in owners + cand_existing_hosts:
                if (host.get(field) == ip and same_network(vm['vlan'], host['vlan'])
                        and not same_owner(vm, host)):
                    conflicts.append({
                        'type': 'OWN_ENV_IP_REASSIGNMENT', 'ip': ip, 'vm': name, 'vmid': vmid,
                        'details': f"IP {ip} is still recorded for '{host['name']}' (vmid: {host.get('vmid')}); reconcile that allocation first",
                    })

            if args.skip_live_probe or any(same_owner(vm, h) for h in owners):
                continue

            # If already flagged as conflicting with another env or infra, skip probe
            if any(c.get("ip") == ip for c in conflicts):
                continue

            if probe_ip_live(ip):
                conflicts.append({
                    "type": "LIVE_NETWORK_IP_COLLISION",
                    "severity": "ERROR",
                    "ip": ip,
                    "vm": name,
                    "vmid": vmid,
                    "details": (f"IP {ip} responds but Terraform state for '{env_name}' does not "
                                f"associate it with VMID {vmid} on VLAN {vm['vlan']}.")
                })

    # -------------------------------------------------------------
    # Display Warnings
    # -------------------------------------------------------------
    if warnings:
        print(f"\n{YELLOW}[WARNING] Cross-Environment Advisory Notices ({len(warnings)}):{NC}")
        for w in warnings:
            print(f"  {YELLOW}• [{w['type']}] {w['details']}{NC}")

    # -------------------------------------------------------------
    # Display Conflicts and Handle Exit
    # -------------------------------------------------------------
    if conflicts:
        print(f"\n{RED}{BOLD}{'='*72}{NC}")
        print(f"{RED}{BOLD}[FATAL ERROR] IP OVERLAP / INFRASTRUCTURE CONFLICT DETECTED!{NC}")
        print(f"{RED}{BOLD}{'-'*72}{NC}")
        print(f"{RED}The following configuration conflict(s) were found for environment '{env_name}':{NC}\n")

        for idx, c in enumerate(conflicts, 1):
            print(f"{RED}  [{idx}] Conflict Type: {c['type']}{NC}")
            if "ip" in c:
                print(f"      Overlapping IP:  {BOLD}{c['ip']}{NC}")
            if "vm" in c:
                print(f"      Candidate VM:    {c['vm']} (vmid: {c.get('vmid', 'N/A')})")
            print(f"      Details:         {c['details']}")
            print()

        print(f"{RED}{BOLD}Terraform Plan/Apply ABORTED to prevent catastrophic IP collisions and network outages.{NC}")
        print(f"{YELLOW}Action required: Assign unique static IP(s) in environments/{env_name}.tfvars.{NC}")
        print(f"{RED}{BOLD}{'='*72}{NC}\n")

        if args.warn_only:
            print(f"{YELLOW}Warning: --warn-only set; proceeding despite conflicts.{NC}")
            sys.exit(0)
        else:
            sys.exit(1)

    mode = 'static checks only; live probes skipped' if args.skip_live_probe else 'ICMP is best-effort; silent devices may still occupy an address'
    print(f"{GREEN}✓ No conflicts detected for '{env_name}' ({mode}).{NC}")
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, AttributeError, OSError, RuntimeError) as exc:
        print(f"IP conflict validation failed: {exc}", file=sys.stderr)
        sys.exit(1)
