# Inventory-Driven Monitoring

This project installs the common monitoring clients on Terraform-managed VMs
and coordinates the existing Zabbix and observability playbooks. Run it only
after account management, time synchronization, and each VM's service
playbook have converged. That ordering lets Oracle, WebLogic, Kubernetes,
Zimbra, CI/CD, and other profiles discover the final service topology rather
than an incomplete bootstrap state.

For repository-wide architecture, capacity guards, retention, and current
acceptance evidence, see:

- [Zabbix server documentation](../zabbix_server/README.md)
- [Observability documentation](../observability/README.md)
- [Service upgrade compatibility runbook](../../../docs/service-upgrade-compatibility.md)

## Execution Model

| Entrypoint | Scope | Use case |
| --- | --- | --- |
| `clients.yml` | Hosts in `monitoring_clients` only | Bounded VM batches or client-only reconciliation while a central component is intentionally stopped |
| `../zabbix_server/main.yml` | `zabbix_servers` | Standalone Zabbix service and inventory/API reconciliation |
| `../observability/main.yml` | `observability_servers` | Standalone Prometheus, Grafana, Loki, Tempo, OpenTelemetry, blackbox, and Alertmanager reconciliation |
| `main.yml` | Clients, then Zabbix, then observability | Full-environment convergence when every target can be safely powered and reached |

Do not use `--limit` with `main.yml` and assume the central plays will still
run. Ansible applies the limit to every imported play. Use `clients.yml` for a
bounded client batch, then invoke the required central playbook separately.

Setting `monitoring_enabled=false` removes a VM from the generated
`monitoring_clients` group. It does not uninstall an already deployed Agent 2
or Alloy client. Central reconciliation also excludes that VM from
inventory-derived Zabbix web scenarios and Prometheus service probes, even if
it remains in an application group. Zabbix retirement disables a removed
IaC-managed host and retains history; it does not immediately delete the host.

## Prerequisites and Safety Guards

Before a runtime change:

1. Confirm the intended Terraform environment, workspace, tfvars, generated
   inventory, PVE endpoint, and live PVE hostname agree.
2. List the current VM power states and capture memory, load, memory PSI,
   storage, and I/O. On `example`, keep running guest memory at or below
   42 GiB and at least 8 GiB of host memory available.
3. Complete `ansible/user-man`, `ansible/time_sync`, and the target service
   playbooks first. A second service pass should be idempotent.
4. Ensure the generated inventory contains `monitoring_clients`,
   `zabbix_servers`, and `observability_servers`, each with the intended
   `ansible_host` values.
5. Install the repository-pinned controller dependencies and collections from
   `ansible/requirements.txt` and `ansible/requirements.yml`.
6. Verify the checksum-governed files under `/resources` with
   `scripts/verify-resources.sh`.
7. Ensure the environment's encrypted monitoring Vault variables are
   available. Never copy decrypted values into inventory, commands, logs, or
   this document.

The role supports exactly x86-64 Ubuntu 24.04 and Oracle Linux 8/9 guests.
Other Debian/Ubuntu releases fail validation before repository installation;
the role never points them at an Ubuntu 24.04 package repository. Package
tasks use CLI-based DNF and firewalld reconciliation on Oracle Linux where the
guest Python bindings are incompatible with the controller's Ansible version.

## Inventory Desired State

Terraform accepts these optional fields on each VM definition:

| Field | Default | Meaning |
| --- | --- | --- |
| `monitoring_enabled` | `true` | Include the VM in `monitoring_clients` and central desired state |
| `monitoring_profile` | VM node-group name | Select templates, exporters, logs, firewall behavior, and alert labels |

Terraform emits `monitoring_enabled`, `monitoring_profile`, `node_role`,
`os_profile`, and environment data into the generated inventory. The common
client attaches bounded `environment`, `instance`, `role`, and `profile`
labels to metrics and logs.

An unknown syntactically valid profile silently inherits `default` behavior.
That provides a Linux baseline but omits service-specific logs, exporters,
ports, and templates. Treat an unexpected profile as an inventory defect and
inspect the generated inventory before convergence.

## Tracked Profiles

| Profiles | Deep behavior | Profile-owned service ports | Firewall policy |
| --- | --- | --- | --- |
| `default` | Linux Agent 2, Unix exporter, journald | None | Managed |
| `database19c`, `database19c_ol9`, `database21c` | Oracle Agent 2 sessions, dynamic CDB/PDB metrics, alert/listener logs | `1521/tcp` | Managed |
| `weblogic12c`, `weblogic14c` | WebLogic exporter, authenticated JMX, JVM manifest, domain/server logs | Application ports remain service-playbook owned; JMX is source-restricted separately | Managed |
| `k8s_control_plane`, `k8s_workers`, `k8s_etcd` | Linux baseline; container logs on control-plane/workers with recursive/default Alloy ACLs on CRI targets and parsed `pod`/`namespace`/`container` Loki labels (filename dropped); local Alloy scrapes of kube-apiserver `/metrics` (CP) and etcd `/metrics` (etcd); API or etcd verification | None | Disabled; Kubernetes networking remains cluster-owned |
| `jenkins` | Linux baseline and Jenkins service label | `8080/tcp` | Managed |
| `jenkins_agent` | Linux baseline and agent label | None | Managed |
| `gitlab` | Allowlisted GitLab component logs | `80/tcp`, `443/tcp` | Managed |
| `gitlab_runner` | Linux baseline and runner label | None | Managed |
| `freeipa` | Linux baseline and identity label | DNS, Kerberos, LDAP/LDAPS, HTTP/HTTPS | Managed |
| `keycloak` | Linux baseline and Keycloak label | `8080/tcp` | Managed |
| `zimbra` | `/var/log/zimbra.log` plus mail/web ports | SMTP, HTTP(S), POP3(S), IMAP(S), submission | Managed |
| `zabbix` | Linux baseline for the central Zabbix host | `80/tcp`, `443/tcp`, `10051/tcp` | Service-owned by the Zabbix role |
| `observability` | Linux baseline for the central stack | Grafana UI `3000/tcp`; the central role owns source-scoped `9090`, `3100`, `4317`, and `4318`; Alertmanager `9093` remains loopback-only | Managed |

The exact definitions are authoritative in
`roles/monitoring_client/defaults/main.yml`.

The common observability client profile must not own unauthenticated ingest
ports. It manages the broadly reachable Grafana UI and exact-source Agent 2
access; the central observability role alone reconciles source-scoped
Prometheus remote-write, Loki push, and OTLP ingress. This division keeps the
unified playbook idempotent and avoids a temporary broad-ingest window.

## Common Client Behavior

Every enabled client receives:

- Zabbix Agent 2 with active-check metadata derived from inventory.
- Passive Agent 2 access on TCP/10050 only from the resolved Zabbix server.
- Checksum-pinned Grafana Alloy `1.17.1` from controller-owned `/resources`
  packages.
- Alloy's embedded Unix exporter, remotely written with `job="node"`.
- Alloy self-scrape metrics with `job="alloy"`.
- Journald ingestion with a bounded initial maximum age of 24 hours.
- Only profile-allowlisted file logs; credential and audit files are not
  selected.
- Native Agent 2 key tests, Alloy configuration validation, readiness checks,
  and profile-specific verification.

## Firewall Ownership and Service Playbook Interaction

For `managed` profiles, the role starts firewalld, adds the tracked profile
service ports, removes broad TCP/10050 exposure and every obsolete
source-specific TCP/10050 accept rule, and creates the one rich rule that
allows passive Agent 2 access only from the current Zabbix server. Verification
requires that exact rule to be the sole matching permanent and runtime accept
rule. The role does not flush the zone or remove unrelated service-playbook
rules. This makes the monitoring rules additive to Jenkins, GitLab, Oracle,
Zimbra, identity, and public-stack firewall configuration.

WebLogic application ports remain owned by the WebLogic playbooks. The
monitoring role adds only source-restricted JMX rules for the generated JVM
ports; Alloy scrapes WebLogic exporter endpoints locally.

The Kubernetes profiles are intentionally different. They stop and disable
an inherited firewalld unit before package work and never reconcile firewall
ports. Kubespray and the cluster networking stack remain authoritative. The
control-plane and worker profiles grant Alloy recursive read/traverse ACLs on
the root-owned CRI targets below `/var/log/pods`, recursively install default
ACLs for future files below existing pod directories, and grant list/traverse
access on `/var/log/containers`. Verification checks the ACLs and reads one
resolved container-log target as `alloy` when a target exists. The role also
verifies the API live endpoint or external-etcd listener after client
installation.

## Oracle Monitoring

Each inventory-declared CDB receives a named Agent 2 Oracle session using the
dedicated common account `C##ZABBIX_MONITOR`. Its password remains in the
guest-local Agent 2 configuration and is not copied into Zabbix macros.

The repo-owned Zabbix template provides CDB, PDB, and tablespace discovery. It
intentionally excludes `oracle.sessions.stats`, ASH, AWR,
`V$ACTIVE_SESSION_HISTORY`, and `DBA_HIST` query families. The allowlisted
custom session query uses only `V$SESSION`.

Prometheus coverage is independent of the Agent 2 credential:

- `iac-oracle-metrics.timer` runs every minute.
- The oneshot collector executes as the existing `oracle` OS identity and uses
  local OS authentication.
- It queries only `V$DATABASE` and `V$PDBS`.
- It atomically writes `/var/lib/oracle-monitoring/oracle.prom` as
  `oracle:alloy` mode `0640`.
- Alloy's textfile collector exports `iac_oracle_cdb_up`,
  `iac_oracle_pdb_count`, `iac_oracle_pdb_up`, and `iac_oracle_pdb_info`.
- A newly declared and created PDB appears automatically on the next timer
  interval; no Prometheus target registration is needed.

Alloy must remain outside `dba`. The collector service temporarily preserves
the existing Oracle owner's OSDBA execution context; Alloy can read only the
completed non-secret snapshot and allowlisted alert/listener logs. Never add a
telemetry user to Oracle privileged groups to bypass a file-permission error.
The ACL model is exact: ancestors of discovered allowlisted files receive
execute only, their containing `trace` directories receive read/list access,
and the matched `alert_*.log`/`listener.log` files receive read only. A run
also removes stale Alloy ACL entries from every other discovered ADR directory,
including incident, metadata, XML alert, and diagnostic subtrees.

The Oracle password must be 20-30 characters, contain no newline, and match
the tracked safe set: letters, numbers, `.`, `_`, `#`, and `-`. Oracle 19c caps
the common-user password at 30 bytes.

## WebLogic Monitoring

WebLogic profiles:

- Deploy checksum-verified WebLogic Monitoring Exporter `2.3.12` into every
  inventory-declared domain.
- Generate exporter configuration from primary/additional domains and their
  managed-server definitions.
- Create the dedicated `iac_monitor` identity in the built-in `Monitors`
  group instead of reusing an administrator for monitoring traffic.
- Configure authenticated JMX with source-restricted ports for Zabbix Java
  Gateway.
- Generate a non-secret JVM manifest for Zabbix low-level discovery.
- Scrape exporter endpoints locally through Alloy and label metrics by
  environment, host, role, domain, and server.
- Ship only declared domain/server logs to Loki.

Alloy is never a member of the `wlogic` service group. The role removes any
legacy membership, grants execute-only traversal ACLs on every ancestor of each
declared domain/server log path, grants list access only to its `logs`
directory, and grants read ACLs to existing and newly created files in that
directory. Including the ancestors is required for WebLogic 12c layouts whose
`user_projects` and `domains` directories are mode `0750`; execute-only
access still prevents directory listing and file reads outside the allowlist.
Alloy can tail the selected `*.log` targets without write access to
middleware, domain configuration, lifecycle scripts, or credential files.

Reconciliation needs an existing WebLogic administrator secret to create or
update the monitor identity and deploy exporter configuration. The role
prefers `vault_weblogic_password`, then controller `WLS_ADMIN_PASSWORD`, then
the corresponding WebLogic service playbook's protected mode-`0600` `.env`.
The administrator secret is not copied into inventory, acceptance logs, or
central monitoring macros.

Each convergence first authenticates `iac_monitor` with the desired encrypted
password. If an existing identity still has an older password, the role uses
the administrator connection to reset it; an already valid credential is left
unchanged, preserving second-pass idempotency. Exporter authentication is
verified after reconciliation. The JMX password file has a separate root-only
desired-secret SHA-256 marker: this permits password rotation while preserving
the salted file format written by newer JDKs and prevents an unchanged run
from restarting every WebLogic JVM.

## Secrets and Non-Secret Topology

Keep topology, addresses, ports, profile mappings, SMTP usernames, and
recipients in the environment's normal group vars. Keep these values only in
the environment's encrypted Ansible Vault, normally
`inventories/<environment>/group_vars/all/monitoring_vault.yml`:

- `vault_monitoring_oracle_password`
- `vault_monitoring_weblogic_password`
- `vault_monitoring_smtp_password` when email is enabled

The monitoring `ansible.cfg` resolves the repository-local ignored
`ansible/.vault_password` by default. Do not commit or print the Vault password
or decrypted values. If the WebLogic monitoring password changes, bump the
non-secret `monitoring_weblogic_secret_version` marker so Zabbix can reconcile
the write-only JMX macro safely.

The authenticated SMTP account remains the envelope sender until any custom
monitoring-domain alias is verified. A chat-disclosed or acceptance-only app
password must be rotated before staging or production use.

## Controller Artifacts and Network Downloads

Alloy Debian and RPM packages are controller-owned `/resources` artifacts.
Their names and SHA-256 values are checked against role pins and
`ansible/resources.sha256` before copying to guests. Monitoring convergence
therefore does not download Alloy independently on every VM.

Zabbix repository packages are obtained from the configured Zabbix 7.0
repository. WebLogic Monitoring Exporter is downloaded from its upstream
release URL and verified against the pinned SHA-256 before deployment.

## Validate Before Convergence

Run commands from the repository root. Replace `example` only after confirming
the target environment and PVE endpoint.

```bash
ENVIRONMENT=example

ansible-inventory \
  -i "inventories/${ENVIRONMENT}/inventory.ini" \
  -i inventories/aliases.ini --graph

PYENV_VERSION=v3.13.14 \
ANSIBLE_CONFIG=ansible/bootstrap_playbooks/monitoring/ansible.cfg \
  ansible-playbook --syntax-check \
  -i "inventories/${ENVIRONMENT}/inventory.ini" \
  -i inventories/aliases.ini \
  ansible/bootstrap_playbooks/monitoring/main.yml

PYENV_VERSION=v3.13.14 ansible-lint \
  ansible/bootstrap_playbooks/monitoring \
  ansible/bootstrap_playbooks/zabbix_server \
  ansible/bootstrap_playbooks/observability

scripts/verify-resources.sh
```

Inspect the resolved variables for a sample host without printing secret
values:

```bash
INVENTORY_HOST=public-database19c-03

ansible-inventory \
  -i "inventories/${ENVIRONMENT}/inventory.ini" \
  -i inventories/aliases.ini --host "${INVENTORY_HOST}" |
  jq '{monitoring_enabled, monitoring_profile, node_role, os_profile}'
```

## Convergence Workflows

The examples reuse the validated `ENVIRONMENT` shell variable. Set it again
when starting a new shell.

### Full environment

Use this only when all imported-play targets can be safely powered and reached:

```bash
PYENV_VERSION=v3.13.14 \
ANSIBLE_CONFIG=ansible/bootstrap_playbooks/monitoring/ansible.cfg \
  ansible-playbook \
  -i "inventories/${ENVIRONMENT}/inventory.ini" \
  -i inventories/aliases.ini \
  ansible/bootstrap_playbooks/monitoring/main.yml
```

### Bounded client batch

This is the preferred homelab workflow when PVE cannot run the whole fleet:

```bash
PYENV_VERSION=v3.13.14 \
ANSIBLE_CONFIG=ansible/bootstrap_playbooks/monitoring/ansible.cfg \
  ansible-playbook \
  -i "inventories/${ENVIRONMENT}/inventory.ini" \
  -i inventories/aliases.ini \
  ansible/bootstrap_playbooks/monitoring/clients.yml \
  --limit 'database19c:database21c:database19c_ol9'
```

Use inventory host or group patterns that are also members of
`monitoring_clients`. Reconfirm PVE capacity before every new batch.

### Clients and observability without Zabbix

Agent 2 can queue active-check retries while Zabbix is intentionally stopped.
Reconcile the selected clients first, then refresh inventory-derived probes,
rules, and dashboards on the observability VM:

```bash
CLIENT_LIMIT='jenkins_agent:gitlab_runner'

PYENV_VERSION=v3.13.14 \
ANSIBLE_CONFIG=ansible/bootstrap_playbooks/monitoring/ansible.cfg \
  ansible-playbook \
  -i "inventories/${ENVIRONMENT}/inventory.ini" \
  -i inventories/aliases.ini \
  ansible/bootstrap_playbooks/monitoring/clients.yml \
  --limit "${CLIENT_LIMIT}"

PYENV_VERSION=v3.13.14 \
ANSIBLE_CONFIG=ansible/bootstrap_playbooks/observability/ansible.cfg \
  ansible-playbook \
  -i "inventories/${ENVIRONMENT}/inventory.ini" \
  -i inventories/aliases.ini \
  ansible/bootstrap_playbooks/observability/main.yml
```

### Zabbix-only reconciliation

```bash
PYENV_VERSION=v3.13.14 \
ANSIBLE_CONFIG=ansible/bootstrap_playbooks/zabbix_server/ansible.cfg \
  ansible-playbook \
  -i "inventories/${ENVIRONMENT}/inventory.ini" \
  -i inventories/aliases.ini \
  ansible/bootstrap_playbooks/zabbix_server/main.yml
```

Run every selected workflow twice. Pass two must finish with `failed=0`,
`unreachable=0`, and no unexpected changes. Store only sanitized acceptance
logs under `terraform-proxmox/logs/acceptance/` and leave changes unstaged
unless the operator explicitly requests staging.

All playbook-local Ansible configurations disable injected top-level fact
variables. Use `ansible_facts[...]` in roles and run syntax checks with
`ANSIBLE_INJECT_FACT_VARS=False` when validating from outside those playbook
directories. This is the forward-compatible behavior for Ansible 2.24 and
later; deprecation warnings must be fixed rather than hidden.

## Exactly-Two Email Acceptance

Normal convergence must leave both guard variables disabled. An approved test
requires valid SMTP topology, an encrypted rotated SMTP password, enabled
Zabbix and observability email routes, and the exact confirmation below:

```bash
PYENV_VERSION=v3.13.14 \
ANSIBLE_CONFIG=ansible/bootstrap_playbooks/monitoring/ansible.cfg \
  ansible-playbook \
  -i "inventories/${ENVIRONMENT}/inventory.ini" \
  -i inventories/aliases.ini \
  ansible/bootstrap_playbooks/monitoring/main.yml \
  -e monitoring_send_test_alerts=true \
  -e monitoring_test_alerts_confirm=SEND_EXACTLY_TWO
```

This sends exactly one Zabbix media-type test and one Alertmanager synthetic
alert to the approved recipient. The Zabbix half uses the server's
`alert.send` media-test protocol with the reconciled media-type ID, so `None`,
`STARTTLS`, and `SSL/TLS` settings, HELO, authentication, and certificate
verification are exercised by Zabbix itself. Record only timestamps and SMTP
acceptance; never record credentials. Do not persist either guard as enabled
in group vars, and do not repeat the test without a new approval.

## Runtime Verification

The roles perform native validation during convergence. These commands are
useful for direct, sanitized follow-up.

Common client:

```bash
systemctl is-enabled zabbix-agent2 alloy
systemctl is-active zabbix-agent2 alloy
zabbix_agent2 -t agent.ping
alloy validate /etc/alloy/config.alloy
curl -fsS http://127.0.0.1:12345/-/ready
```

Oracle client:

```bash
systemctl is-enabled iac-oracle-metrics.timer
systemctl is-active iac-oracle-metrics.timer
systemctl status iac-oracle-metrics.service
sudo -u alloy head /var/lib/oracle-monitoring/oracle.prom
id alloy
```

`iac-oracle-metrics.service` is a oneshot unit and is normally inactive
between timer runs. The timer must be active. `id alloy` must not list `dba`.
The snapshot must be non-empty, readable by Alloy, and contain no credentials.

Central Prometheus examples:

```bash
OBSERVABILITY_IP=198.51.100.24

curl -fsS --get \
  --data-urlencode 'query=up{job="alloy"}' \
  "http://${OBSERVABILITY_IP}:9090/api/v1/query" | jq

curl -fsS --get \
  --data-urlencode 'query=iac_oracle_cdb_up' \
  "http://${OBSERVABILITY_IP}:9090/api/v1/query" | jq

curl -fsS --get \
  --data-urlencode 'query=probe_success' \
  "http://${OBSERVABILITY_IP}:9090/api/v1/query" | jq

curl -fsS "http://${OBSERVABILITY_IP}:9090/api/v1/rules" |
  jq '.data.groups[].rules[] | {name, health, state, lastError}'
```

Grafana must provision Node Exporter Full plus the repo-owned dashboards with
UIDs `iac-weblogic`, `iac-oracle`, and `iac-observability-health`. Loki should
show only bounded labels and allowlisted file paths. Prometheus currently
loads rules for host reachability, missing/stale metrics, pressure/capacity,
Alloy/exporter failures, WebLogic, Oracle, service probes, and public-stack
health.

The `IaC Homelab` Grafana folder also reconciles three curated reusable library
panels: 24-hour host availability, 24-hour service availability, and firing
Prometheus alerts. These are separate from the panels embedded in the
repo-owned dashboards, so the folder's Panels tab is useful without taking
ownership of dashboard layout. The stack-health dashboard links to the
environment-owned Prometheus rules endpoint. Alertmanager remains loopback-only
by design; set `observability_alertmanager_ui_url` only when a reviewed secure
operator URL exists, otherwise use an SSH tunnel to inspect its UI.

The Application Services Reachability History panel intentionally includes raw
reachability for planned-off inventory objects. The Expected state selector
defaults to `All`, so the overview includes every inventory VM; use `true` to
focus on expected-up services or `false` to inspect planned-off services. This
selector distinguishes expected-down services from a real outage. Self-probes
for the local Grafana, Prometheus, and Loki containers use Compose DNS names so
the source-scoped host firewall does not report the central stack as down.

The `iac-observability-health` dashboard provides:

- Overall inventory VM uptime for the selected Grafana time range.
- Per-VM uptime percentages, trends, and reachability history.
- Overall observability-component uptime and component status history.
- Per-endpoint application uptime and reachability history for declared HTTP,
  WebLogic, Oracle listener, Kubernetes API, and etcd probes.
- The current count and list of firing alerts.

The Oracle dashboard adds CDB availability, dynamic per-CDB PDB counts,
per-PDB availability/open mode, and selected-range uptime. Inventory changes
scale the probe and Oracle metric definitions when the owning service and
monitoring playbooks are rerun.

Prodesk sends a repo-owned color PDF every Friday at `16:00 Africa/Nairobi`.
The observability-host systemd timer selects the most recently completed Monday
`00:00` through Friday `16:00` window and queries Prometheus directly, avoiding
a Grafana Enterprise reporting dependency. The PDF covers all inventory VMs,
service endpoints, expected-up policy, resource snapshots, Oracle CDB/PDB
health, and firing alerts. Root-only PDFs/JSON are retained for 90 days, and a
per-period `.sent` marker makes service replay safe from duplicate messages.
Observed uptime is paired with overall and per-target sample coverage at the
tracked Prometheus cadence, so a rebuild or mid-period service addition is
visibly incomplete rather than silently scored as a full data window.
The earlier one-off 10-minute plain-text delivery remains separate evidence.

## Multiple Environments and a Shared Central Stack

Client metrics and logs carry an environment label, and Zabbix host retirement
is filtered by the environment tag. A target inventory can therefore point
client-only runs at reachable shared central addresses through its monitoring
group vars.

Central reconciliation is fail-closed when
`monitoring_central_require_authoritative_inventory` is true (the default):
every host in `monitoring_clients` must declare `monitoring_environment` and
`monitoring_expected_up`, and the set of environments present must exactly
match `monitoring_central_expected_environments`. Supply the complete
generated inventory union to the same `ansible-playbook` invocation before
reconciling retirement, autoregistration actions, or inventory-derived probe
targets.

Residual operator risk remains if the guard is overridden or the union is
wrongly declared:

- Prefer one designated environment's inventories as the authoritative union
  for shared Zabbix/observability ownership.
- Do not run `main.yml` successively from incomplete single-environment
  inventories against the same central stack while retirement is enabled.
- Keep `clients.yml` usable per environment when only agent/Alloy convergence
  is required.

## Troubleshooting

| Symptom | Check | Safe response |
| --- | --- | --- |
| Topology validation fails | `zabbix_servers` and `observability_servers` groups and their first hosts | Correct inventory/aliases or environment topology; do not hard-code a different environment casually |
| Expected service coverage is absent | Resolved `monitoring_profile` | Fix the profile; unknown names fall back to the Linux baseline |
| Kubernetes API or etcd breaks after client work | Exact Kubernetes profile and `systemctl is-active firewalld` | Stop the batch; the tracked Kubernetes profiles require firewalld inactive, then rerun the service verification |
| Alloy fails validation | `/etc/alloy/config.alloy` and profile inputs | Run `alloy validate`; do not log the rendered WebLogic password-bearing configuration |
| Oracle metrics are missing | Timer state, snapshot ownership, PMON/listener/CDB state | Restore the Oracle service first; keep Alloy outside `dba` and correct only the snapshot handoff |
| Oracle snapshot reports CDB down | Oracle boot unit and CDB open mode | Run the owning database playbook/systemd workflow; do not grant more monitoring privileges |
| WebLogic exporter is absent | Domain definitions, administrator input, `iac_monitor`, local exporter URL | Reconcile the WebLogic service and monitoring profile; keep JMX source-restricted |
| GitLab/Jenkins probe fails after monitoring | Service port in the exact profile and service-owned firewall rules | Reconcile the tracked profile; do not flush firewalld or replace the service playbook's rules |
| Alloy artifact validation fails | `/resources` filenames and `ansible/resources.sha256` | Restore the exact checksum-pinned package and rerun `scripts/verify-resources.sh` |
| Pass two still changes | Recap and changed task names | Investigate the specific task before starting another VM batch |

Never capture verbose Zabbix HTTPAPI connection context when secret macros may
be present. If a credential appears in a log, rotate it and securely remove the
unsafe log rather than merely redacting a copy.

## Rollback and Retirement

Prefer correcting desired state and reconverging. This project does not provide
an uninstall playbook, and `monitoring_enabled=false` is an opt-out from future
client reconciliation rather than guest cleanup.

For a reviewed manual rollback:

1. Stop the affected batch and preserve only sanitized evidence.
2. Disable the monitoring-created units before removing their files.
3. Remove only the Agent 2 fragments, Alloy configuration, Oracle metric units
   and snapshot directory, or WebLogic monitoring assets created by this role.
4. Preserve service-playbook firewall rules and application configuration.
5. Validate native service configuration before restarting anything.
6. Let Zabbix disable removed IaC-managed hosts and retain their history; do
   not delete hosts merely because a VM is temporarily powered off.

If a service playbook fails twice and guest state is uncertain, replacement is
authorized only for the disposable `example` workload VM under the repository
guards. Never destroy Vault governance as a monitoring rollback.

After a temporary PVE memory cap was used for a bounded batch, stop the guest
before restoring its Terraform-declared memory value. Capture a new capacity
preflight before starting the next batch.
