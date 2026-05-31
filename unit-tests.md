# Unit Tests and Final Rebuild Runbook

This runbook is designed for one final high-signal test cycle:

1. Destroy and recreate infra.
2. Run the 5 automations in series (to reduce IO pressure).
3. Re-run each automation for idempotency.
4. Execute VM-side verification checks (DB, WebLogic, and user-management controls).

## Scope

Automations covered:

- `bootstrap_playbooks/oracle819c` (database19c)
- `bootstrap_playbooks/oracle821c` (database21c)
- `bootstrap_playbooks/oracle_weblogic12c` (weblogic12c)
- `bootstrap_playbooks/oracle_weblogic14c` (weblogic14c)
- `ansible_user_management` (all 5 hosts)

Hosts covered:

- `public-weblogic14c-01` (`198.51.100.13`)
- `public-weblogic12c-01` (`198.51.100.12`)
- `public-database19c-01` (`198.51.100.10`)
- `public-database21c-01` (`198.51.100.11`)
- `public-jenkins-01` (`198.51.100.14`)

## One-command serial run (recommended)

Use the orchestrator script from repo root:

```bash
cd ~/IaC-Homelab

# Optional overrides
export ENVIRONMENT=dev
export ANSIBLE_FORKS=1
export STRICT_IDEMPOTENCY=true
export ANSIBLE_BECOME_TIMEOUT=300
export TCP_WAIT_TIMEOUT=3600
export LOGIN_WAIT_TIMEOUT=7200
export READY_CHECK_INTERVAL=10
export TCP_PROBE_TIMEOUT=10
export SSH_CONNECT_TIMEOUT=20
export HTTP_VERIFY_TIMEOUT=30
export DB_SYS_PASSWORD='<set-strong-db-sys-password>'
export APP_USER='APP_CRM'
export APP_USER_PASSWORD='<set-strong-app-user-password>'
export SSH_STRICT_HOST_KEY_CHECKING='accept-new'

./run_final_series.sh
```

What this script does:

- `make destroy` then `make apply` (serial).
- Waits for host readiness on all 5 hosts with generous allowances:
  - TCP/22 reachable
  - SSH login works (avoids `pam_nologin` boot window failures)
  - cloud-init wait check when present
- Runs each automation twice (`run1`, `run2`).
- Enforces `changed=0` on reruns if `STRICT_IDEMPOTENCY=true`.
- Writes progress + detailed logs + recap summaries.

If you still hit early-boot errors, increase:

```bash
export TCP_WAIT_TIMEOUT=5400
export LOGIN_WAIT_TIMEOUT=10800
export ANSIBLE_BECOME_TIMEOUT=600
```

Artifacts:

- `test-runs/final-series-<timestamp>/progress.log`
- `test-runs/final-series-<timestamp>/master.log`
- `test-runs/final-series-<timestamp>/logs/*.log`
- `test-runs/final-series-<timestamp>/reports/idempotency.tsv`
- `test-runs/final-series-<timestamp>/reports/play_recaps.txt`

## Manual serial run (if you want full control)

```bash
cd ~/IaC-Homelab

# 1) Rebuild infra
printf 'yes\n' | make -C terraform-proxmox destroy ENVIRONMENT=dev
make -C terraform-proxmox apply ENVIRONMENT=dev

# 2) Run automations in series (first pass)
# Optional: explicit readiness gate before first playbook to avoid pam_nologin
for ip in 198.51.100.13 198.51.100.12 198.51.100.10 198.51.100.14 198.51.100.11; do
  until ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes ansible@"$ip" \
    "test ! -e /run/nologin && test ! -e /etc/nologin" >/dev/null 2>&1; do
    echo "waiting for login readiness on $ip ..."
    sleep 10
  done
done

(cd bootstrap_playbooks/oracle819c && ansible-playbook main.yml --limit database19c --forks 1)
(cd bootstrap_playbooks/oracle821c && ansible-playbook main.yml --limit database21c --forks 1)
(cd bootstrap_playbooks/oracle_weblogic12c && ansible-playbook main.yml --limit weblogic12c --forks 1)
(cd bootstrap_playbooks/oracle_weblogic14c && ansible-playbook main.yml --limit weblogic14c --forks 1)
cd ansible_user_management && ansible-playbook main.yml --limit "public-weblogic14c-01,public-weblogic12c-01,public-database21c-01,public-database19c-01,public-jenkins-01" --forks 1 --vault-password-file .vault_password && cd ..

# 3) Rerun same commands (second pass for idempotency)
# Expect changed=0, failed=0, unreachable=0.
```

## CRUD tests per automation

## A) Database CRUD (19c/21c)

Use the existing scenario doc for full add/update/delete sequence:

- [`docs/oracle-db-weblogic-crud-scenario.md`](docs/oracle-db-weblogic-crud-scenario.md)

Minimum CRUD cycle to validate:

1. Create extra `cdb2` + `pdb2`.
2. Validate service and logins.
3. Update listener/firewall (`LISTENER2` if needed).
4. Delete `pdb2`, then `cdb2`.
5. Reconcile back to default desired state and rerun.

## B) WebLogic CRUD/idempotency

12c:

```bash
cd ~/IaC-Homelab/bootstrap_playbooks/oracle_weblogic12c
ansible-playbook main.yml --limit weblogic12c --forks 1
ansible-playbook main.yml --limit weblogic12c --forks 1
```

14c (includes managed server validation):

```bash
cd ~/IaC-Homelab/bootstrap_playbooks/oracle_weblogic14c
ansible-playbook main.yml --limit weblogic14c --forks 1
ansible-playbook main.yml --limit weblogic14c --forks 1
```

## C) User management CRUD

Create/update pass:

```bash
cd ~/IaC-Homelab/ansible_user_management
ansible-playbook main.yml --limit "public-weblogic14c-01,public-weblogic12c-01,public-database21c-01,public-database19c-01,public-jenkins-01" --forks 1 --vault-password-file .vault_password
```

Read verification:

```bash
ansible all -i ~/IaC-Homelab/inventories/dev/inventory.ini \
  -l "public-weblogic14c-01,public-weblogic12c-01,public-database21c-01,public-database19c-01,public-jenkins-01" \
  -b -m shell -a 'set -eu; for u in user2 user1 user3 user4 user5; do id -u "$u"; done'
```

Update test (example):

1. Change one user comment/group/shell in `ansible_user_management/group_vars/all.yml`.
2. Rerun playbook.
3. Verify with `getent passwd <user>` and `id <user>`.

Delete test (example):

1. Add user under `remove_users` in `ansible_user_management/group_vars/all.yml`.
2. Run playbook.
3. Verify user absent with `id <user>` (non-zero expected).

## VM-side verification commands

## DB checks

19c:

```bash
ssh -o StrictHostKeyChecking=accept-new ansible@198.51.100.10 "sudo bash -lc '
systemctl is-active firewalld
firewall-cmd --list-ports
ss -ltnp | egrep \":1521|:1522\" || true
'"
```

21c:

```bash
ssh -o StrictHostKeyChecking=accept-new ansible@198.51.100.11 "sudo bash -lc '
systemctl is-active firewalld
firewall-cmd --list-ports
ss -ltnp | egrep \":1521|:1522\" || true
'"
```

Remote login checks from DB hosts:

```bash
# 19c
ssh -o StrictHostKeyChecking=accept-new ansible@198.51.100.10 'sudo -iu oracle bash -s' <<'EOF'
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
export PATH="$ORACLE_HOME/bin:$PATH"

sqlplus -s /nolog <<'SQL'
whenever sqlerror exit 1
connect sys/<DB_SYS_PASSWORD>@//oracle19c.example.internal:1521/pdb1 as sysdba
set heading off feedback off pages 100
select name from v$database;
exit;
SQL

sqlplus -s /nolog <<'SQL'
whenever sqlerror exit 1
connect <APP_USER>/<APP_USER_PASSWORD>@//oracle19c.example.internal:1521/pdb1
set heading off feedback off pages 100
select user from dual;
exit;
SQL
EOF


# 21c
ssh -o StrictHostKeyChecking=accept-new ansible@198.51.100.11 'sudo -iu oracle bash -s' <<'EOF'
export ORACLE_HOME=/u01/app/oracle/product/21.0.0/dbhome_1
export PATH="$ORACLE_HOME/bin:$PATH"

sqlplus -s /nolog <<'SQL'
whenever sqlerror exit 1
connect sys/<DB_SYS_PASSWORD>@//oracle21c.example.internal:1521/pdb1 as sysdba
set heading off feedback off pages 100
select name from v$database;
exit;
SQL

sqlplus -s /nolog <<'SQL'
whenever sqlerror exit 1
connect <APP_USER>/<APP_USER_PASSWORD>@//oracle21c.example.internal:1521/pdb1
set heading off feedback off pages 100
select user from dual;
exit;
SQL
EOF

```

## WebLogic checks

12c:

```bash
ssh -o StrictHostKeyChecking=accept-new ansible@198.51.100.12 "sudo bash -lc '
systemctl is-active wlsCLIENT_ADOMAIN8006.service
firewall-cmd --list-ports
ss -ltnp | egrep \":7001|:8006\" || true
'"
curl -k -sS -o /dev/null -w "%{http_code}\n" http://198.51.100.12:8006/console
```

14c (managed servers):

```bash
ssh -o StrictHostKeyChecking=accept-new ansible@198.51.100.13 "sudo bash -lc '
systemctl is-active wlsWLS14CDOMAINNM.service
systemctl is-active wlsWLS14CDOMAIN7001.service
systemctl is-active wlsWLS14CDOMAIN8001.service
systemctl is-active wlsWLS14CDOMAIN8002.service
firewall-cmd --list-ports
ss -ltnp | egrep \":5556|:7001|:8001|:8002\" || true
'"
for url in http://198.51.100.13:7001/console http://198.51.100.13:8001 http://198.51.100.13:8002; do
  code=$(curl -k -sS -o /dev/null -w "%{http_code}" --max-time 10 "$url" || true)
  echo "$url -> HTTP_${code}"
done
```

## User-management security checks

```bash
ansible all -i ~/IaC-Homelab/inventories/dev/inventory.ini \
  -l "public-weblogic14c-01,public-weblogic12c-01,public-database21c-01,public-database19c-01,public-jenkins-01" \
  -b -m shell -a '
set -eu
for u in user2 user1 user3 user4 user5; do
  echo "== $u =="
  id -u "$u"
  chage -l "$u" | awk -F": " "/Maximum/{print \"maxdays=\" \$2; exit}"
done
echo -n "ansible_shadow_prefix="
awk -F: '\''$1=="ansible"{print substr($2,1,1); exit}'\'' /etc/shadow
test -f /etc/ssh/sshd_config.d/99-key-only-account-hardening.conf
test -f /etc/ssh/sshd_config.d/98-account-allowlist.conf
'
```

Expected:

- managed users exist on all 5 hosts
- `maxdays=31`
- `ansible` password locked (`!` or `*` prefix)
- hardening drop-in exists

## Pass/fail criteria

- Every playbook run: `failed=0`, `unreachable=0`
- Reruns: `changed=0` (strict idempotency)
- DB login checks succeed for both SYS and one `APP_*` user
- WebLogic 14c managed server endpoints respond
- Firewall/listener/service state matches desired configuration
