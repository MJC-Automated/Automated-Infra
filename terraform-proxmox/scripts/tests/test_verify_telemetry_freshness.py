"""Unit tests for verify-telemetry-freshness inventory discovery and filtering."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location(
    "telemetry_validator", ROOT / "scripts/verify-telemetry-freshness.py"
)
telemetry_validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(telemetry_validator)

discover_inventory_sources = telemetry_validator.discover_inventory_sources
get_expected_hosts = telemetry_validator.get_expected_hosts


class TelemetryDiscoveryTests(unittest.TestCase):
    def test_autodiscovery_excludes_dev_and_k8s_environments(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            inv_dir = root / "inventories"
            inv_dir.mkdir(parents=True)

            # Create mock environments
            for env in ["dev", "k8s", "example", "optiplex"]:
                env_p = inv_dir / env
                env_p.mkdir()
                (env_p / "inventory.ini").write_text(f"[{env}_hosts]\n{env}-host-1 ansible_host=198.51.100.49\n")

            # Create a regular non-directory file and a dir without inventory.ini
            (inv_dir / "aliases.ini").write_text("[all]\n")
            (inv_dir / "empty_env").mkdir()

            discovered = discover_inventory_sources(root)
            discovered_rel = [p.relative_to(root).as_posix() for p in discovered]

            self.assertIn("inventories/optiplex/inventory.ini", discovered_rel)
            self.assertIn("inventories/example/inventory.ini", discovered_rel)
            self.assertNotIn("inventories/example/inventory.ini", discovered_rel)
            self.assertNotIn("inventories/k8s/inventory.ini", discovered_rel)
            self.assertEqual(len(discovered), 2)

    def test_explicit_inventories_override_autodiscovery(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            inv_dir = root / "inventories"
            inv_dir.mkdir(parents=True)

            k8s_p = inv_dir / "k8s"
            k8s_p.mkdir()
            k8s_file = k8s_p / "inventory.ini"
            k8s_file.write_text("[kube_control_plane]\nk8s-cp-1\n")

            # Explicit list can include k8s when requested directly
            discovered = discover_inventory_sources(root, inventories=[str(k8s_file)])
            self.assertEqual(discovered, [k8s_file])

            # Directory passed as explicit inventory resolves to inventory.ini
            discovered_dir = discover_inventory_sources(root, single_inventory=str(k8s_p))
            self.assertEqual(discovered_dir, [k8s_file])

    def test_get_expected_hosts_ignores_sections_and_comments(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".ini", delete=False) as f:
            f.write("""# Top level comment
; Semicolon comment
[group_a]
host-a-1 ansible_host=198.51.100.50
host-a-2 ansible_host=198.51.100.51 node_role=worker

[group_b:children]
group_a

[all:vars]
ansible_user=ansible
""")
            f.flush()
            temp_path = Path(f.name)

        try:
            hosts = get_expected_hosts(temp_path)
            self.assertEqual(hosts, {"host-a-1", "host-a-2"})
        finally:
            temp_path.unlink()


if __name__ == "__main__":
    unittest.main()
