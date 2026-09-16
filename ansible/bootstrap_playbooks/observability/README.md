# Observability Playbook (`observability`)

Deploys a unified observability stack on Ubuntu 24.04 using Docker:

- Grafana
- Prometheus
- Loki
- Tempo
- OpenTelemetry Collector
- Node Exporter

The image pins are deliberately kept separate from the reviewed current
upstream releases. See the [service upgrade compatibility
runbook](../../../docs/service-upgrade-compatibility.md) before changing them:
the proposed Grafana, Prometheus, Loki, Tempo, collector, and
kube-state-metrics updates cross major or multiple minor versions and require
a data-copy test.

Package reconciliation accepts apt metadata updated within the prior hour.
This keeps routine idempotent runs independent of a transient Ubuntu mirror
outage while still refreshing stale package indexes before installation.

Alert ownership is explicit: Alertmanager is the primary notification and
paging engine; Zabbix is retained for secondary host/service checks, inventory,
and SLA history. Zabbix trigger email actions stay disabled to prevent
duplicate pages. Alertmanager SMTP delivery remains disabled until an
environment supplies a verified recipient and encrypted SMTP credentials.
Its unauthenticated HTTP API is published on host loopback only; Prometheus
uses the private Compose network, and UFW explicitly retires any older
external `9093/tcp` rule.

Unauthenticated ingest listeners (Prometheus remote-write on `9090/tcp`, Loki
push on `3100/tcp`, and OTLP on `4317/tcp`/`4318/tcp`) are not opened broadly.
UFW retires any prior unrestricted port allows for those services and adds
source-restricted rules for every `monitoring_clients` host IP. The common
client profile does not open these ingest ports; this role is their sole
firewall owner during unified reconciliation.
Grafana UI on `3000/tcp` remains the operator-facing external port; use an SSH
tunnel when interactive Prometheus/Loki UI access is required from a host that
is not a monitoring client.

Compose convergence uses orphan removal, so a component removed by a feature
flag (including kube-state-metrics) or by a stack upgrade does not retain an
old container or sensitive bind mount. Inventory-derived service probes are
limited to `monitoring_clients`; an application group alone cannot override a
VM's monitoring opt-out.

Optional kube-state-metrics runs as the explicit non-root identity
`65534:65534`. Enabling it requires a non-empty kubeconfig already present on
the observability VM, readable by that owner or group but not world-readable.
Set `observability_kube_state_metrics_manage_kubeconfig=true` to create the
`iac-kube-state-metrics` ServiceAccount on the first `k8s_control_plane` host
and install `/etc/observability/kube-state-metrics.kubeconfig` as mode `0400`
owned by UID/GID `65534` (never copy root-only `admin.conf`).
The role rejects a root-only mode-`0600` bind mount and does not accept detached
Compose startup as proof: `/readyz` on the loopback telemetry port must report
HTTP 200, proving both process readiness and Kubernetes API access.
Kubernetes deployment-health recordings compare
`kube_deployment_spec_replicas` with
`kube_deployment_status_replicas_available`; both sides therefore cover the
same deployment-only universe. DaemonSets, StatefulSets, Jobs, and standalone
pods are not mixed into the available-replica count.

Trace ingestion is available for practical instrumented targets through the
central OTLP endpoints (`4317` gRPC and `4318` HTTP). Applications should set
`OTEL_EXPORTER_OTLP_ENDPOINT` to the observability VM and include a stable
`service.name`; the collector forwards spans to Tempo and exposes exporter
failure counters to Prometheus. For a safe smoke test, send a single OTLP
HTTP span from a disposable client and verify it in Grafana Explore's Tempo
datasource; do not enable high-volume debug sampling in production.

Storage capacity is forecast from the six-hour free-space slope. Prometheus
records `observability:storage_consumption_bytes_per_day` and
`observability:storage_days_remaining` per data mount, warns when seven-day
exhaustion is forecast, and raises a critical alert below 48 hours. These are
forecasts, not guarantees: validate ingest rates and expand `/var/lib` before
increasing Loki/Tempo retention.

The Prometheus rules also publish inventory-driven availability recordings:

- `inventory:host_availability:ratio24h` and `inventory:host_availability:ratio7d`
  (grouped by environment)
- `inventory:service_availability:ratio24h` and
  `inventory:service_availability:ratio7d` (grouped by environment and
  service)

These ratios are computed from the blackbox probe history for targets marked
`expected_up: "true"`. Raw probe series remain available for every inventory
target, including planned maintenance, so an outage is never hidden by
removing its target. Grafana panels can render the ratios as percentages by
multiplying by 100. Service probes cover the generated WebLogic managed-server,
Oracle listener, Kubernetes API/etcd, GitLab, Jenkins, Zabbix, Grafana,
Prometheus, and Loki endpoints.

The stack-health dashboard exposes `environment`, expected-state, VM, and
service filters. Its VM state timeline is tall enough to show the complete
18-host reference inventory, reserves a fixed label column for
`hostname · role · address`, and aggregates by stable inventory identity so
label migrations do not create duplicate rows. Every application probe carries
a concise `check` label such as `observability/grafana` or
`weblogic/<domain>/<server>`. The application timeline displays
`hostname · check`, uses larger rows, and paginates at 15 endpoints so added
domains, servers, databases, services, and environments remain readable.
Dashboard selectors require the current expected-state and `check` labels,
which intentionally excludes obsolete pre-schema time series while preserving
them in Prometheus until retention expires.

The `IaC Homelab` Grafana folder reconciles three stable library panels for
host availability, service availability, and firing Prometheus alerts. The
stack-health dashboard provides an IaC dashboard dropdown and a link to the
environment-owned Prometheus rules endpoint. Grafana-managed alert rules are
not created because Prometheus and Alertmanager own alert evaluation and
routing. Alertmanager remains loopback-only; configure
`observability_alertmanager_ui_url` only for a reviewed secure operator URL,
otherwise use an SSH tunnel. The Expected state selector defaults to `All` so
the overview shows the complete inventory and its factual reachability; use
`true` to focus on expected-up services or `false` to inspect planned-off
objects. Expected-state policy still gates paging and SLA calculations. The
local Grafana, Prometheus, and
Loki self-probes use Compose service DNS names to avoid false failures from
the source-scoped host firewall.

## Weekly color PDF report

Prodesk enables a repo-owned report at Friday `16:00 Africa/Nairobi`. The
systemd timer evaluates the most recently completed Monday `00:00` through
Friday `16:00` Nairobi window, including after a missed run. The report contains
colored executive cards, per-VM and per-service availability/downtime, expected
versus informational policy, current CPU/memory/root-disk pressure, dynamic
Oracle CDB/PDB health, and firing alerts.

Alert emails render their dashboard link from
`observability_grafana_base_url`. Environment group vars derive that value from
the environment's observability host, so dev and future centrally managed
inventories cannot silently link operators to the Prodesk Grafana instance.

Availability is paired with overall and per-row sample coverage at the same
tracked 15-second Prometheus cadence. A partial post-rebuild window or a target
added mid-week is therefore disclosed as incomplete telemetry instead of being
presented as a fully observed 100% period.

The reporter uses only Python's standard library plus the checksum-pinned
Chrome-for-Testing archive already governed in `/resources`. It renders a
repo-owned HTML document locally and prints an A4 landscape PDF. Reports and
JSON evidence are root-only under `/var/lib/observability-reports` and retained
for 90 days. A per-period `.sent` marker prevents duplicate delivery if the
oneshot service is replayed.

Rendering occurs below systemd `PrivateTmp` with a unique temporary `HOME`; the
validated PDF is then atomically published to the persistent report directory.
Do not add an explicit Chrome `--user-data-dir`: the pinned build stalled with
that flag during Prodesk acceptance. Chrome's five-second capture timeout and
the reporter's outer 120-second process guard bound a failed render.

SMTP credentials remain only in the environment's encrypted
`vault_monitoring_smtp_password` and the rendered root-only mode-`0600`
environment file. Delivery uses STARTTLS and the authenticated SMTP address as
the envelope/header address until a custom sender alias is verified.

Useful commands:

```bash
systemctl list-timers iac-observability-weekly-report.timer
systemctl status iac-observability-weekly-report.timer
sudo sh -c 'set -a; . /etc/iac-observability-weekly-report.env; set +a; exec /usr/local/sbin/iac-observability-weekly-report --no-send --window-minutes 10'
sudo ls -lh /var/lib/observability-reports
```

The dry-run command generates and validates a color PDF without sending mail.
Do not enable shell tracing while the protected environment file is loaded.

## Files

- `main.yml`: entry point
- `.env.example`: local secret/non-secret overrides
- Controller dependencies are managed from `ansible/requirements.txt` and `ansible/requirements.yml`.
- `group_vars/observability_servers.yml`: defaults
- `roles/observability/`: install/configure/verify tasks

## Usage

```bash
cd ~/IaC-Homelab/ansible/bootstrap_playbooks/observability
ansible-playbook main.yml
```

## Python Environment

This project uses the repository-wide pyenv virtualenv from `ansible/.python-version`:

- `v3.13.14`

Setup example:

```bash
cd ~/IaC-Homelab/ansible
pyenv install -s 3.13.14
pyenv virtualenv 3.13.14 v3.13.14
pyenv local v3.13.14
python -m pip install --upgrade pip
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

## Notes

- Uses an injected `observability_grafana_admin_password` when supplied; otherwise it persists a generated credential in the ignored mode-`0600` `files/` directory.
- Targets `observability_servers` alias group.
- Run twice for idempotency checks.
- After convergence, verify Prometheus and Loki through the documented
  `make -C terraform-proxmox telemetry-verify` workflow in the
  [monitoring guide](../monitoring/README.md); supply the complete shared
  inventory union and central endpoint URLs explicitly.
