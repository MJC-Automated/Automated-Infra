# Service Upgrade Compatibility

This document records the reviewed upgrade posture as of 2026-09-07. It is
an operator runbook, not an instruction to upgrade every service at once.
Take a backup, test in a disposable environment, and upgrade one service
family at a time.

## Current Targets and Artifact Status

| Service | Reviewed target | Repository action | Offline artifact status |
| --- | --- | --- | --- |
| Jenkins controller and agents | Jenkins LTS `2.568.3`; Java `21` or `25` | Version pin updated; role now verifies the JVM on every controller and agent | The supplied `jenkins_2.555.3_all.deb` is older; do not set `JENKINS_PACKAGE_PATH` until a `2.568.3` package is checksum-pinned. |
| JDK for Jenkins | JDK `21.0.11` or Java 25 | Existing JDK 21 archive remains valid for the Jenkins runtime requirement | `jdk-21_linux-x64_bin.tar.gz` contains `jdk-21.0.11+10`. |
| GitLab CE and Runner | `19.3.1-ce.0` and `19.3.1-1` | Both packages are pinned; the role blocks a jump over the mandatory GitLab 19.2 stop | Supplied packages are `19.1.2-ce.0` and `19.1.1-1`, so they are not valid for the target. |
| Grafana Alloy | `1.19.2` | Keep the deployed pin at `1.17.1` until both new packages are added to `/resources` and `ansible/resources.sha256` | Required SHA-256: Debian `9872732d43c6d14996e1ad5a075086a93381ea6375c8c756820da68b85422eea`; RPM `daac715d840ce8c1074c00ce0b82ed9367d5647d4daef4d2a836f154328bfb30`. |
| Keycloak | `26.7.3` | Version and official archive SHA-256 are pinned; local stale archives are rejected and the fallback download is checksum-verified | Supplied `keycloak-26.2.0.tar.gz` is older and is no longer selected. |
| Zimbra | `10.1.15` | The supplied artifact already matches. The role now blocks an implicit in-place upgrade of a different installation | `zcs-10.1.15_GA_4200001.RHEL9_64.20260110181427.tgz` is the selected artifact. |
| FreeIPA | OL9 package stream | No cross-version automation is enabled; use replica-aware vendor upgrade procedures | OS repository packages are not an offline artifact. |

The reviewed upstream sources are the [Jenkins LTS changelog](https://www.jenkins.io/changelog-stable/), [Jenkins Java support policy](https://www.jenkins.io/doc/book/platform-information/support-policy-java/), [GitLab upgrade paths](https://docs.gitlab.com/update/upgrade_paths/), [GitLab 19 upgrade notes](https://docs.gitlab.com/update/versions/gitlab_19_changes/), [Grafana Alloy release information](https://grafana.com/docs/alloy/latest/reference/release-information/), and [Keycloak releases](https://www.keycloak.org/).

## Jenkins: Controller, Agents, JDK, and Plugins

Jenkins 2.555.1 and later requires Java 21 or Java 25 for the controller,
agents, CLI, and remoting processes. The playbook installs Java before Jenkins
and now asserts that the configured `JAVA_HOME` provides one of those majors
on every target. An application build may still use another JDK, but the agent
process itself must use 21 or 25.

Before moving an existing controller from 2.555.3 to 2.568.3:

1. Back up `JENKINS_HOME`, including jobs, credentials, and controller
   configuration.
2. Verify Java 21/25 on the controller and every SSH agent.
3. Update plugins before and after the core upgrade; test pipeline, GitLab,
   credentials, SSH-agent, and configuration-as-code plugins in a clone.
4. Use the Jenkins package repository by leaving `JENKINS_PACKAGE_PATH` empty,
   or add the exact local package and its SHA-256 to the resource manifest.

## GitLab and Runner

GitLab's required stop after 19.1 is the latest `19.2` patch. Upgrade the
server first, then its drained runners at each stop. These commands select
repository packages explicitly, overriding any older local package paths in
`.env`. Omit the runner commands for a standalone server.

```bash
cd ansible/bootstrap_playbooks/gitlab
ansible-playbook main.yml --limit gitlab_servers \
  -e gitlab_version=19.2.5-ce.0 -e '{"gitlab_package_path":""}'
# Wait for all background migrations, verify readiness, and take a fresh backup.
ansible-playbook main.yml --limit gitlab_runners \
  -e gitlab_runner_version=19.2.3-1 -e '{"gitlab_runner_package_path":""}'
# Verify a Docker job; drain runners again before the next server upgrade.
ansible-playbook main.yml --limit gitlab_servers \
  -e gitlab_version=19.3.1-ce.0 -e '{"gitlab_package_path":""}'
# Wait for migrations and verify server readiness before upgrading runners.
ansible-playbook main.yml --limit gitlab_runners \
  -e gitlab_runner_version=19.3.1-1 -e '{"gitlab_runner_package_path":""}'
```

Use Ansible extra variables (`-e`) for one-run overrides: shell assignments
such as `GITLAB_VERSION=... ansible-playbook ...` are not imported by this
playbook. Persistent `GITLAB_*` settings belong in its `.env` file. Repository
Runner installs pin both `gitlab-runner` and `gitlab-runner-helper-images` to
the same version, including intermediate releases, as required by the
[Runner installation guide](https://docs.gitlab.com/runner/install/linux-repository/).
Offline Runner installations require both `gitlab_runner_package_path` and
`gitlab_runner_helper_images_package_path` (or `GITLAB_RUNNER_HELPER_IMAGES_PACKAGE_PATH`
in `.env`). The role asserts version parity between both local packages and installs
them together as a single bundle to satisfy package dependencies.

The role refuses a direct jump from a pre-19.2 installation to a later
target, including local packages. Verify runner registration and a Docker
job after each upgrade. Review the GitLab 19.2/19.3 upgrade notes for API and
restore behavior before upgrading a non-disposable instance.

## Monitoring and Observability

The centralized Compose stack currently pins Prometheus `2.54.1`, Alertmanager
`0.33.1`, Blackbox Exporter `0.28.0`, Loki `3.2.1`, Tempo `2.6.1`, Grafana
`11.2.0`, OpenTelemetry Collector Contrib `0.108.0`, and optional
kube-state-metrics `2.14.0`. Current upstream releases include Prometheus
`3.14.0`, Alertmanager `0.34.0`, Loki `3.7.7`, Tempo `3.0.3`, Grafana
`13.2.1`, OpenTelemetry Collector `0.160.0`, and kube-state-metrics `2.20.0`.

Those are major or multi-minor changes, so they are candidates—not an
unreviewed default change. Test the rendered Compose file and all existing
Prometheus rules, Loki OTLP ingestion, Tempo OTLP export, Grafana provisioning,
Alertmanager routing, and dashboard queries against a copied data directory
first. Back up Grafana's SQLite database and the Prometheus/Loki/Tempo data
directories before making the image changes. Grafana's published upgrade
guidance requires reviewing breaking changes for each crossed major.

Alloy remains an offline checksum-governed package. Add both `1.19.2` package
files and the two hashes above, run `scripts/verify-resources.sh`, update the
Alloy defaults, then validate remote-write, Loki push, OTLP, journald, and
Kubernetes scrape behavior before production rollout.

## Keycloak, FreeIPA, and Zimbra

Keycloak 26.7.3 is a same-major, cross-minor upgrade from 26.2.0. Stop all
Keycloak nodes sharing its database and back up both the installation and
PostgreSQL before running the playbook. Before replacing a mounted install or
switching its symlink, the role copies `providers/` and `themes/` into the new
distribution, then rebuilds it with those providers before restart. If that
preservation copy fails, replacement is not attempted. A same-version rerun
keeps its optimized build.

The database is retained and migrated by Keycloak, so rollback requires a
database restore as well as the old installation. Preserved extensions still
need compatibility testing: verify login, health, hostname/proxy behavior,
and custom providers/themes using the [Keycloak upgrade guide](https://www.keycloak.org/docs/latest/upgrading/).
The download path verifies SHA-256
`77657f30b7e90d70f727712ce1c967f430fd6a5e9f458d32d8c6df0635345f47`.

FreeIPA should be upgraded by the supported OS package path with a topology and
replica plan, an IPA backup, `ipa-healthcheck`, and tested Kerberos/DNS flows.
Do not use a rolling package update as a substitute for that procedure.

The available Zimbra 10.1.15 artifact is already the selected target. For a
future Zimbra release, use its release-specific in-place upgrade procedure
after backup; the installed-version check runs in the `zimbra` login context.
The role deliberately fails when it detects a different existing release
rather than silently declaring it converged.
