#!/usr/bin/env python3

from __future__ import annotations

import argparse
import ipaddress
import shutil
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
import re

EXCLUDED_PREFIXES = (
    ".github/workflows/",
)

EXCLUDED_PATHS = {
    ".github/workflows",
}

SSH_KEY_PATTERN = re.compile(
    r"(?P<algo>ssh-(?:rsa|ed25519)|ecdsa-sha2-nistp(?:256|384|521))\s+\S+(?:\s+\S+)?"
)
HOST_PATTERN = re.compile(
    r"\b(?P<env>[a-z0-9]+)-(?P<service>[a-z0-9][a-z0-9-]*?)-dot(?P<ordinal>\d+)"
    r"(?P<domain>\.[a-z0-9.-]+)?\b"
)
STACK_PATTERN = re.compile(r"\b[a-z0-9]+-stack\b")
DOMAIN_PATTERN = re.compile(r"\b(?P<label>[a-z0-9-]+)\.(?P<domain>lab\.local|example.internal)\b")
LOCALDOMAIN_PATTERN = re.compile(r"(?<!localhost\.)example.internal\b")
IP_OR_CIDR_PATTERN = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?\b")

SSH_PLACEHOLDER = (
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedForPublicDocs sanitized@example.invalid
    "sanitized@example.invalid"
)
PUBLIC_DOMAIN = "example.internal"
SPECIAL_PUBLIC_IPS = {
    "198.51.100.17",
    "198.51.100.13",
}
DIRECT_REPLACEMENTS = {
    "example-platform": "example-platform",
    "automated-infra": "automated-infra",
    "platform-team": "platform-team",
    "platform-ha": "platform-ha",
    "shared-storage": "shared-storage",
    "example": "example",
    "proxmox-node": "proxmox-node",
}
IP_BASE_NETWORKS = (
    ipaddress.ip_network("203.0.113.0/24"),
    ipaddress.ip_network("192.0.2.0/24"),
    ipaddress.ip_network("198.51.100.0/24"),
)
CIDR_BASE_NETWORKS = (
    ipaddress.ip_network("198.51.100.0/24"),
    ipaddress.ip_network("203.0.113.0/24"),
    ipaddress.ip_network("192.0.2.0/24"),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export a sanitized tracked-file snapshot of the repository."
    )
    parser.add_argument(
        "--output-dir",
        required=True,
        help="Directory that will receive the sanitized snapshot.",
    )
    parser.add_argument(
        "--repo-root",
        default=".",
        help="Repository root to read from. Defaults to the current directory.",
    )
    return parser.parse_args()


def run_git(repo_root: Path, *args: str) -> str:
    return subprocess.check_output(
        ["git", "-C", str(repo_root), *args],
        text=True,
    )


def tracked_files(repo_root: Path) -> list[str]:
    output = run_git(repo_root, "ls-files", "-z")
    return [path for path in output.split("\0") if path]


def should_exclude(path: str) -> bool:
    return path in EXCLUDED_PATHS or any(path.startswith(prefix) for prefix in EXCLUDED_PREFIXES)


def is_text_file(path: Path) -> bool:
    try:
        data = path.read_bytes()
    except OSError:
        return False
    if b"\x00" in data:
        return False
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return True


class SnapshotSanitizer:
    def __init__(self) -> None:
        self.host_map: dict[str, str] = {}
        self.host_counters: defaultdict[str, int] = defaultdict(int)
        self.ip_map: dict[str, str] = {}
        self.cidr_map: dict[str, str] = {}
        self.ip_pool = self._iter_public_ips()
        self.cidr_indices: defaultdict[int, int] = defaultdict(int)

    def sanitize_text(self, text: str) -> str:
        text = SSH_KEY_PATTERN.sub(SSH_PLACEHOLDER, text)
        text = HOST_PATTERN.sub(self._replace_host, text)
        text = STACK_PATTERN.sub("public-stack", text)
        text = DOMAIN_PATTERN.sub(self._replace_domain, text)
        text = text.replace("EXAMPLE.INTERNAL", "EXAMPLE.INTERNAL")
        text = text.replace("example.internal", PUBLIC_DOMAIN)
        text = LOCALDOMAIN_PATTERN.sub(PUBLIC_DOMAIN, text)
        for source, replacement in DIRECT_REPLACEMENTS.items():
            text = text.replace(source, replacement)
        text = IP_OR_CIDR_PATTERN.sub(self._replace_ip_or_cidr, text)
        return text

    def summary(self) -> str:
        return (
            f"sanitized {len(self.host_map)} hostname(s), "
            f"{len(self.ip_map)} IP address(es), "
            f"{len(self.cidr_map)} CIDR(s)"
        )

    def _replace_host(self, match: re.Match[str]) -> str:
        original = match.group(0)
        if original in self.host_map:
            return self.host_map[original]

        service = re.sub(r"[^a-z0-9-]", "-", match.group("service")).strip("-")
        self.host_counters[service] += 1
        sanitized = f"public-{service}-{self.host_counters[service]:02d}"
        if match.group("domain"):
            sanitized = f"{sanitized}.{PUBLIC_DOMAIN}"
        self.host_map[original] = sanitized
        return sanitized

    def _replace_domain(self, match: re.Match[str]) -> str:
        label = match.group("label")
        if label == "localhost":
            return match.group(0)
        return f"{label}.{PUBLIC_DOMAIN}"

    def _replace_ip_or_cidr(self, match: re.Match[str]) -> str:
        token = match.group(0)
        if "/" in token:
            return self._replace_cidr(token)
        return self._replace_ip(token)

    def _replace_ip(self, token: str) -> str:
        try:
            address = ipaddress.ip_address(token)
        except ValueError:
            return token

        if address.version != 4:
            return token
        if address.is_loopback or address.is_unspecified or address.is_multicast or address.is_link_local:
            return token
        if not address.is_private and token not in SPECIAL_PUBLIC_IPS:
            return token

        if token not in self.ip_map:
            self.ip_map[token] = next(self.ip_pool)
        return self.ip_map[token]

    def _replace_cidr(self, token: str) -> str:
        try:
            network = ipaddress.ip_network(token, strict=False)
        except ValueError:
            return token

        if network.version != 4:
            return token
        if network.prefixlen == 32:
            return self._replace_ip(str(network.network_address))
        if network.is_loopback or network.prefixlen == 0:
            return token
        if not network.is_private:
            return token

        if token not in self.cidr_map:
            self.cidr_map[token] = self._next_cidr(network.prefixlen)
        return self.cidr_map[token]

    def _iter_public_ips(self):
        for network in IP_BASE_NETWORKS:
            for host in network.hosts():
                if int(str(host).split(".")[-1]) < 10:
                    continue
                yield str(host)

    def _next_cidr(self, prefixlen: int) -> str:
        if prefixlen < 24:
            return f"198.51.100.27/{prefixlen}"

        candidates: list[ipaddress.IPv4Network] = []
        for base in CIDR_BASE_NETWORKS:
            if prefixlen == 24:
                candidates.append(base)
            else:
                candidates.extend(base.subnets(new_prefix=prefixlen))

        index = self.cidr_indices[prefixlen]
        self.cidr_indices[prefixlen] += 1
        return str(candidates[index % len(candidates)])


def copy_tracked_files(repo_root: Path, output_dir: Path) -> int:
    copied = 0
    for relative_path in tracked_files(repo_root):
        if should_exclude(relative_path):
            continue

        source = repo_root / relative_path
        destination = output_dir / relative_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        copied += 1
    return copied


def sanitize_tree(output_dir: Path) -> SnapshotSanitizer:
    sanitizer = SnapshotSanitizer()
    for path in output_dir.rglob("*"):
        if not path.is_file() or not is_text_file(path):
            continue
        content = path.read_text(encoding="utf-8")
        sanitized = sanitizer.sanitize_text(content)
        if sanitized != content:
            path.write_text(sanitized, encoding="utf-8")
    return sanitizer


def main() -> int:
    args = parse_args()
    repo_root = Path(args.repo_root).resolve()
    output_dir = Path(args.output_dir).resolve()

    if not (repo_root / ".git").exists():
        print(f"{repo_root} does not look like a git repository root.", file=sys.stderr)
        return 1

    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)

    copied = copy_tracked_files(repo_root, output_dir)
    sanitizer = sanitize_tree(output_dir)

    print(f"Copied {copied} tracked file(s) into {output_dir}")
    print(sanitizer.summary())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
