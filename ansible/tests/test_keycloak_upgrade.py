"""Exercise the real Keycloak upgrade tasks on disposable installation trees."""

import grp
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
INSTALL = ROOT / "ansible/bootstrap_playbooks/keycloak/roles/keycloak/tasks/install.yml"


@unittest.skipUnless(shutil.which("ansible-playbook"), "ansible-playbook is required")
class KeycloakUpgradeTests(unittest.TestCase):
    def run_upgrade(self, folder, *, mounted, current=False, fail_copy=False, custom=True):
        folder = Path(folder)
        old = folder / "keycloak-old"
        selected = folder / "keycloak-selected"
        active = folder / "keycloak"
        for directory in (old, selected):
            (directory / "bin").mkdir(parents=True)
            (directory / "bin/kc.sh").write_text("fixture distribution\n")
            (directory / "providers").mkdir()
            (directory / "themes").mkdir()
        if mounted:
            old.rename(active)
            source = active
        else:
            active.symlink_to(selected if current else old, target_is_directory=True)
            source = active.resolve()
        (source / ".keycloak-version").write_text("new\n" if current else "old\n")
        (selected / "themes/shipped.txt").write_text("new upstream theme\n")
        (selected / ".built").write_text("previous optimized build\n")
        if custom:
            (source / "providers/custom.jar").write_bytes(b"custom authentication provider")
            (source / "themes/custom/login").mkdir(parents=True)
            (source / "themes/custom/login/template.ftl").write_text("custom login\n")
            (source / "themes/.theme-metadata").write_text("hidden metadata\n")
        else:
            (source / "providers").rmdir()
            (source / "themes").rmdir()

        # Only the external mountpoint probe is faked. No mount, systemd, user
        # management, archive download, or database operation touches this host.
        commands = folder / "commands"
        commands.mkdir()
        probe = commands / "mountpoint"
        probe.write_text(f"#!/bin/sh\nexit {0 if mounted else 1}\n")
        probe.chmod(0o755)
        if fail_copy:
            cp = commands / "cp"
            cp.write_text("#!/bin/sh\necho 'fixture copy failure' >&2\nexit 1\n")
            cp.chmod(0o755)

        tasks = yaml.safe_load(INSTALL.read_text())
        start = next(i for i, task in enumerate(tasks) if task["name"] == "Check whether keycloak install path is a mountpoint")
        end = next(i for i, task in enumerate(tasks) if task["name"] == "Ensure keycloak symlink points to selected version")
        # Run the production preservation/refresh sequence, stopping before
        # root-owned symlink management. Assert the selected tree is ready to
        # activate; mounted trees are actually replaced by the real task.
        play = [{
            "name": "Disposable Keycloak upgrade",
            "hosts": "localhost",
            "gather_facts": False,
            "vars": {
                "ansible_python_interpreter": sys.executable,
                "keycloak_install_dir": str(active),
                "keycloak_extract_dir": str(selected),
                "keycloak_version": "new",
                "keycloak_user": pwd.getpwuid(os.getuid()).pw_name,
                "keycloak_group": grp.getgrgid(os.getgid()).gr_name,
            },
            "environment": {"PATH": f"{commands}:{os.environ['PATH']}"},
            "tasks": tasks[start:end],
            "handlers": [{"name": "Restart keycloak", "ansible.builtin.debug": {"msg": "No live service in this fixture"}}],
        }]
        playbook = folder / "test.yml"
        playbook.write_text(yaml.safe_dump(play, sort_keys=False))
        cfg = folder / "ansible.cfg"
        cfg.write_text("[defaults]\nhost_key_checking = True\n")
        result = subprocess.run(
            ["ansible-playbook", "-i", "localhost,", "-c", "local", str(playbook)],
            env={**os.environ, "ANSIBLE_CONFIG": str(cfg), "ANSIBLE_NOCOLOR": "1"},
            cwd=folder, capture_output=True, text=True, timeout=60,
        )
        return result, source, selected, active

    def test_preserves_customizations_before_activating_new_distribution(self):
        for mounted in (False, True):
            with self.subTest(mounted=mounted), tempfile.TemporaryDirectory(prefix="keycloak-upgrade-") as folder:
                result, _, selected, active = self.run_upgrade(folder, mounted=mounted)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                destination = active if mounted else selected
                self.assertTrue((destination / "providers/custom.jar").is_file(), "upgrade lost custom authentication provider")
                self.assertEqual((destination / "providers/custom.jar").read_bytes(), b"custom authentication provider")
                self.assertEqual((destination / "themes/custom/login/template.ftl").read_text(), "custom login\n")
                self.assertEqual((destination / "themes/.theme-metadata").read_text(), "hidden metadata\n")
                self.assertEqual((destination / "themes/shipped.txt").read_text(), "new upstream theme\n")
                self.assertFalse((destination / ".built").exists(), "custom providers must be included in a fresh optimized build")

    def test_copy_failure_does_not_erase_active_mounted_installation(self):
        with tempfile.TemporaryDirectory(prefix="keycloak-upgrade-") as folder:
            result, source, _, _ = self.run_upgrade(folder, mounted=True, fail_copy=True)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertTrue((source / "providers/custom.jar").is_file(), "failed preservation must not delete the old installation")
            self.assertEqual((source / ".keycloak-version").read_text(), "old\n")

    def test_same_version_rerun_keeps_optimized_build(self):
        for mounted in (False, True):
            with self.subTest(mounted=mounted), tempfile.TemporaryDirectory(prefix="keycloak-upgrade-") as folder:
                result, _, selected, active = self.run_upgrade(folder, mounted=mounted, current=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue((selected / ".built").exists())
                self.assertTrue((active / "providers/custom.jar").exists())

    def test_missing_customization_directories_are_allowed(self):
        with tempfile.TemporaryDirectory(prefix="keycloak-upgrade-") as folder:
            result, _, selected, _ = self.run_upgrade(folder, mounted=False, custom=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((selected / "themes/shipped.txt").read_text(), "new upstream theme\n")


if __name__ == "__main__":
    unittest.main()
