#!/usr/bin/env python3
"""
Unit tests for validate-inventory-shadowing.py
"""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "validate-inventory-shadowing.py"
spec = importlib.util.spec_from_file_location("validator", SCRIPT_PATH)
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class InventoryShadowingValidatorTests(unittest.TestCase):
    def test_clean_inventory_passes(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            inv_dir = Path(tmpdir)
            inv_file = inv_dir / "inventory.ini"
            inv_file.write_text(
                "[database19c]\n"
                "host-db-1 ansible_host=198.51.100.50\n"
                "[database21c]\n"
                "host-db-2 ansible_host=198.51.100.51\n"
            )
            gv_dir = inv_dir / "group_vars"
            gv_dir.mkdir()
            (gv_dir / "database19c.yml").write_text(
                "oracle_servers:\n"
                "  host-db-1:\n"
                "    sid: cdb1\n"
            )
            errors = validator.validate_inventory(inv_dir)
            self.assertEqual(errors, [])

    def test_stale_host_in_group_vars_fails_preflight(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            inv_dir = Path(tmpdir)
            inv_file = inv_dir / "inventory.ini"
            inv_file.write_text(
                "[database19c]\n"
                "host-db-1 ansible_host=198.51.100.50\n"
            )
            gv_dir = inv_dir / "group_vars"
            gv_dir.mkdir()
            (gv_dir / "database19c.yml").write_text(
                "oracle_servers:\n"
                "  stale-migrated-host:\n"
                "    sid: cdb1\n"
            )
            errors = validator.validate_inventory(inv_dir)
            self.assertEqual(len(errors), 1)
            self.assertIn("stale-migrated-host", errors[0])
            self.assertIn("oracle_servers", errors[0])

    def test_cross_inventory_variable_collision(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            inv1 = root / "inv1"
            inv2 = root / "inv2"
            inv1.mkdir()
            inv2.mkdir()

            (inv1 / "inventory.ini").write_text("host1 ansible_host=198.51.100.49\n")
            (inv2 / "inventory.ini").write_text("host2 ansible_host=198.51.100.58\n")

            gv1 = inv1 / "group_vars"
            gv2 = inv2 / "group_vars"
            gv1.mkdir()
            gv2.mkdir()

            (gv1 / "all.yml").write_text("common_var: value_a\n")
            (gv2 / "all.yml").write_text("common_var: value_b\n")

            errors = validator.validate_cross_inventory_shadowing([inv1, inv2])
            self.assertEqual(len(errors), 1)
            self.assertIn("common_var", errors[0])
            self.assertIn("Conflicting value", errors[0])

    def test_environment_scoped_variables_are_not_flagged(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            inv1 = root / "inv1"
            inv2 = root / "inv2"
            inv1.mkdir()
            inv2.mkdir()

            (inv1 / "inventory.ini").write_text("host1 ansible_host=198.51.100.49\n")
            (inv2 / "inventory.ini").write_text("host2 ansible_host=198.51.100.58\n")

            gv1 = inv1 / "group_vars"
            gv2 = inv2 / "group_vars"
            gv1.mkdir()
            gv2.mkdir()

            (gv1 / "all.yml").write_text("proxmox_host: pve1\n")
            (gv2 / "all.yml").write_text("proxmox_host: pve2\n")

            errors = validator.validate_cross_inventory_shadowing([inv1, inv2])
            self.assertEqual(len(errors), 0)

    def test_real_composite_workflow_example_and_optiplex(self):
        repo_root = Path(__file__).resolve().parents[3]
        example_dir = repo_root / "inventories" / "example"
        optiplex_dir = repo_root / "inventories" / "optiplex"
        if example_dir.is_dir() and optiplex_dir.is_dir():
            errors = validator.validate_cross_inventory_shadowing([example_dir, optiplex_dir])
            self.assertEqual(errors, [])

    def test_ansible_vault_tag_parsed_without_error(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "vault.yml"
            path.write_text("secret_var: !vault |\n          $ANSIBLE_VAULT;1.1;AES256\n          deadbeef\n")
            data = validator.load_yaml_file(path)
            self.assertIn("secret_var", data)
            self.assertEqual(data["secret_var"], "!vault")


if __name__ == "__main__":
    unittest.main()
