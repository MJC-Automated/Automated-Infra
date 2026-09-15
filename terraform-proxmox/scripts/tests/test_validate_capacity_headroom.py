#!/usr/bin/env python3
"""
Unit tests for validate-capacity-headroom.py
"""

import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT_PATH = Path(__file__).resolve().parents[1] / "validate-capacity-headroom.py"
spec = importlib.util.spec_from_file_location("capacity_validator", SCRIPT_PATH)
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class CapacityHeadroomValidatorTests(unittest.TestCase):
    def setUp(self):
        self.repo_root = Path(__file__).resolve().parents[3]
        self.example_tfvars = self.repo_root / "terraform-proxmox" / "environments" / "example.tfvars"
        self.optiplex_tfvars = self.repo_root / "terraform-proxmox" / "environments" / "optiplex.tfvars"

    def test_example_fails_on_actual_48gib_without_overcommit(self):
        if not self.example_tfvars.is_file():
            self.skipTest("example.tfvars not found")
        # example plans 50 GiB RAM. On 48 GiB host with 6 GiB reserve, usable is 42 GiB.
        report = validator.validate_capacity(
            tfvars_path=self.example_tfvars,
            host_ram_gib=48.0,
            ram_reserve_gib=6.0,
            allow_overcommit=False,
        )
        self.assertEqual(report["status"], "FAILED")
        self.assertGreater(len(report["errors"]), 0)
        self.assertIn("exceeds safe usable host memory", report["errors"][0])

    def test_example_passes_on_actual_48gib_with_overcommit_approval(self):
        if not self.example_tfvars.is_file():
            self.skipTest("example.tfvars not found")
        report = validator.validate_capacity(
            tfvars_path=self.example_tfvars,
            host_ram_gib=48.0,
            ram_reserve_gib=6.0,
            allow_overcommit=True,
        )
        self.assertEqual(report["status"], "PASSED")
        self.assertEqual(len(report["errors"]), 0)
        self.assertTrue(report["overcommit_explicitly_approved"])
        self.assertTrue(any("RAM OVERCOMMIT APPROVED" in w for w in report["warnings"]))

    def test_optiplex_fails_on_actual_32gib_without_overcommit(self):
        if not self.optiplex_tfvars.is_file():
            self.skipTest("optiplex.tfvars not found")
        # optiplex plans 30 GiB RAM. On 32 GiB host with 6 GiB reserve, usable is 26 GiB.
        report = validator.validate_capacity(
            tfvars_path=self.optiplex_tfvars,
            host_ram_gib=32.0,
            ram_reserve_gib=6.0,
            allow_overcommit=False,
        )
        self.assertEqual(report["status"], "FAILED")
        self.assertGreater(len(report["errors"]), 0)
        self.assertIn("exceeds safe usable host memory", report["errors"][0])

    def test_optiplex_passes_on_actual_32gib_with_overcommit_approval(self):
        if not self.optiplex_tfvars.is_file():
            self.skipTest("optiplex.tfvars not found")
        report = validator.validate_capacity(
            tfvars_path=self.optiplex_tfvars,
            host_ram_gib=32.0,
            ram_reserve_gib=6.0,
            allow_overcommit=True,
        )
        self.assertEqual(report["status"], "PASSED")
        self.assertEqual(len(report["errors"]), 0)
        self.assertTrue(report["overcommit_explicitly_approved"])

    def test_ample_capacity_passes_without_overcommit(self):
        if not self.example_tfvars.is_file():
            self.skipTest("example.tfvars not found")
        report = validator.validate_capacity(
            tfvars_path=self.example_tfvars,
            host_ram_gib=128.0,
            ram_reserve_gib=6.0,
            allow_overcommit=False,
        )
        self.assertEqual(report["status"], "PASSED")
        self.assertEqual(len(report["errors"]), 0)


if __name__ == "__main__":
    unittest.main()
