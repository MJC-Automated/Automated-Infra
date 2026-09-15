"""Regression tests for service upgrade preflight tasks."""

from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

from jinja2 import Environment, StrictUndefined
import yaml


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def load_tasks(relative_path: str) -> list[dict]:
    task_path = REPOSITORY_ROOT / relative_path
    with task_path.open(encoding="utf-8") as task_file:
        return yaml.safe_load(task_file)


def task_named(tasks: list[dict], name: str) -> dict:
    return next(task for task in tasks if task.get("name") == name)


class ServiceUpgradeCheckTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("ansible-playbook"), "ansible-playbook is required")
    def test_zimbra_version_probe_runs_as_zimbra_login_user(self) -> None:
        tasks = load_tasks(
            "ansible/bootstrap_playbooks/zimbra/roles/zimbra/tasks/validate.yml"
        )

        for target_version, expected_success in (("10.1.15", True), ("10.1.16", False)):
            with self.subTest(target_version=target_version), tempfile.TemporaryDirectory(prefix="zimbra-upgrade-") as folder:
                fixture = Path(folder)
                # Model the OS login boundary without root, a zimbra account,
                # or a live installation. Wrong user/login/command arguments
                # fail instead of manufacturing a successful version result.
                su = fixture / "su"
                su.write_text(
                    "#!/bin/sh\n"
                    "[ \"$#\" -eq 4 ] && [ \"$1\" = - ] && [ \"$2\" = zimbra ] && "
                    "[ \"$3\" = -c ] && [ \"$4\" = '/opt/zimbra/bin/zmcontrol -v' ] || exit 1\n"
                    "printf 'Release 10.1.15_GA_4200001.RHEL9_64 FOSS edition.\\n'\n"
                )
                su.chmod(0o755)
                play = [{
                    "name": "Disposable Zimbra preflight",
                    "hosts": "localhost",
                    "gather_facts": False,
                    "vars": {
                        "ansible_python_interpreter": sys.executable,
                        "zimbra_installed_bin": {"stat": {"exists": True}},
                        "zimbra_target_version": target_version,
                        "zimbra_allow_in_place_upgrade": False,
                    },
                    "environment": {"PATH": f"{fixture}:{os.environ['PATH']}"},
                    "tasks": [
                        task_named(tasks, "Read installed Zimbra version before reconciliation"),
                        task_named(tasks, "Block an implicit Zimbra in-place upgrade"),
                    ],
                }]
                playbook = fixture / "test.yml"
                playbook.write_text(yaml.safe_dump(play, sort_keys=False))
                cfg = fixture / "ansible.cfg"
                cfg.write_text("[defaults]\nhost_key_checking = True\n")
                result = subprocess.run(
                    ["ansible-playbook", "-i", "localhost,", "-c", "local", str(playbook)],
                    cwd=fixture, env={**os.environ, "ANSIBLE_CONFIG": str(cfg), "ANSIBLE_NOCOLOR": "1"},
                    capture_output=True, text=True, timeout=30,
                )
                self.assertEqual(result.returncode == 0, expected_success, result.stdout + result.stderr)
                if not expected_success:
                    self.assertIn("Installed Zimbra Release 10.1.15", result.stdout)

    def test_runner_and_helper_images_are_version_pinned_together(self) -> None:
        tasks = load_tasks(
            "ansible/bootstrap_playbooks/gitlab/roles/gitlab/tasks/runner.yml"
        )

        package_install = task_named(tasks, "Install gitlab-runner package")

        renderer = Environment(undefined=StrictUndefined)
        for version, expected in (
            ("19.2.3-1", ["gitlab-runner=19.2.3-1", "gitlab-runner-helper-images=19.2.3-1"]),
            ("19.3.1-1", ["gitlab-runner=19.3.1-1", "gitlab-runner-helper-images=19.3.1-1"]),
        ):
            with self.subTest(version=version):
                requests = package_install["ansible.builtin.apt"]["name"]
                if isinstance(requests, str):
                    requests = [requests]
                packages = [renderer.from_string(request).render(gitlab_runner_version=version) for request in requests]
                self.assertEqual(packages, expected)

    def test_jenkins_flat_apt_repository_format(self) -> None:
        tasks = load_tasks(
            "ansible/bootstrap_playbooks/jenkins/roles/jenkins/tasks/install.yml"
        )
        repo_task = task_named(tasks, "Add Jenkins repository source list")
        repo_def = repo_task["ansible.builtin.deb822_repository"]
        # In deb822 flat repository specification, suites must end with '/' and components omitted
        self.assertEqual(repo_def["suites"], "binary/")
        self.assertNotIn("components", repo_def, "deb822 flat repository must not include empty components list")
        # Ensure cleanup tasks exist for legacy list and pre-existing deb822 files
        cleanup_malformed = task_named(tasks, "Remove any pre-existing Jenkins deb822 sources file before recreation")
        self.assertEqual(cleanup_malformed["ansible.builtin.file"]["path"], "/etc/apt/sources.list.d/jenkins.sources")
        self.assertEqual(cleanup_malformed["ansible.builtin.file"]["state"], "absent")
        cleanup_legacy = task_named(tasks, "Remove legacy Jenkins apt_repository list file")
        self.assertEqual(cleanup_legacy["ansible.builtin.file"]["path"], "/etc/apt/sources.list.d/jenkins.list")

    def test_gitlab_runner_offline_bundle_and_service_health(self) -> None:
        tasks = load_tasks(
            "ansible/bootstrap_playbooks/gitlab/roles/gitlab/tasks/runner.yml"
        )
        bundle_assert = task_named(tasks, "Require both gitlab-runner and helper-images packages for offline installation")
        conditions = bundle_assert["ansible.builtin.assert"]["that"]
        self.assertTrue(any("gitlab_runner_package_path" in c for c in conditions))
        self.assertTrue(any("gitlab_runner_helper_images_package_path" in c for c in conditions))

        checksum_assert = task_named(tasks, "Require checksums for offline GitLab Runner packages")
        chk_conditions = checksum_assert["ansible.builtin.assert"]["that"]
        self.assertTrue(any("gitlab_runner_package_checksum" in c for c in chk_conditions))
        self.assertTrue(any("gitlab_runner_helper_images_package_checksum" in c for c in chk_conditions))

        version_assert = task_named(tasks, "Require local GitLab Runner package versions to match configured version and each other")
        v_conditions = version_assert["ansible.builtin.assert"]["that"]
        self.assertTrue(any("gitlab_runner_version" in c for c in v_conditions))

        # Ensure service management is a top-level task outside registration block
        service_task = task_named(tasks, "Ensure gitlab-runner service is enabled and started")
        self.assertEqual(service_task["ansible.builtin.systemd"]["name"], "gitlab-runner")
        self.assertEqual(service_task["ansible.builtin.systemd"]["state"], "started")
        self.assertTrue(service_task["ansible.builtin.systemd"]["enabled"])

        # Ensure daemon health verification task is present
        verify_task = task_named(tasks, "Verify GitLab Runner daemon connectivity and registration")
        self.assertEqual(verify_task["ansible.builtin.command"]["argv"], ["gitlab-runner", "verify"])


if __name__ == "__main__":
    unittest.main()
