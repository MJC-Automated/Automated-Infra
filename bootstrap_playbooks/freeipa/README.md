# FreeIPA Playbook (`freeipa`)

Automates FreeIPA server installation for Oracle Linux 9 style hosts and performs baseline verification.

## Files

- `main.yml`: entry point
- `.env.example`: optional secrets/non-secret overrides
- `requirements.txt`: Python controller dependencies
- `requirements.yml`: Ansible collection dependencies
- `group_vars/freeipa_servers.yml`: defaults
- `roles/freeipa/`: server role tasks

## Usage

```bash
ansible-playbook -i inventories/example/inventory.ini -i inventories/aliases.ini bootstrap_playbooks/freeipa/main.yml
```

## Run Order

1. Run `time_sync/main.yml` first so the FreeIPA host and all Kerberos clients are on repo-managed Chrony sources.
2. Decide whether FreeIPA owns DNS itself (`FREEIPA_SETUP_DNS=true`) or whether an external authority owns the zone (`FREEIPA_SETUP_DNS=false`).
3. Run this playbook twice for idempotency checks.

## Inputs

- Requires `freeipa_ds_password` and `freeipa_admin_password` (via `.env` or injected vars).
- Targets the `freeipa_servers` alias group.
- Optional `.env` values are documented in `.env.example`.

## Python Environment

This project uses a dedicated pyenv virtualenv name:

- `v3.10.19-freeipa`

Setup example:

```bash
pyenv install -s 3.10.19
pyenv virtualenv 3.10.19 v3.10.19-freeipa

cd ~/IaC-Homelab/bootstrap_playbooks/freeipa
pyenv local v3.10.19-freeipa
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

## DNS Modes

### Integrated DNS

- Set `FREEIPA_SETUP_DNS=true`.
- The playbook installs `ipa-server-dns`, configures `named`, and opens the `dns` firewalld service.
- Use this mode when FreeIPA should be authoritative for the identity zone.

### External DNS

- Set `FREEIPA_SETUP_DNS=false`.
- The playbook skips `ipa-dns-install`, does not start `named`, and closes the `dns` firewalld service on reruns so port 53 is not left open by mistake.
- Verification still requires the external zone to contain all records that FreeIPA expects for service discovery.

## External DNS Requirements

When `FREEIPA_SETUP_DNS=false`, publish these records in the zone before expecting `ipa-healthcheck` verification to pass:

- Host A/AAAA for the FreeIPA server FQDN, for example `public-freeipa-02.example.internal -> 198.51.100.44`
- Host A/AAAA for `ipa-ca.<domain>`, for example `ipa-ca.example.internal -> 198.51.100.44`
- SRV records:
  - `_ldap._tcp.<domain>` -> port `389`
  - `_kerberos._tcp.<domain>` -> port `88`
  - `_kerberos._udp.<domain>` -> port `88`
  - `_kerberos-master._tcp.<domain>` -> port `88`
  - `_kerberos-master._udp.<domain>` -> port `88`
  - `_kpasswd._tcp.<domain>` -> port `464`
  - `_kpasswd._udp.<domain>` -> port `464`
- URI records:
  - `_kerberos.<domain>` -> `krb5srv:m:tcp:<freeipa-fqdn>.`
  - `_kerberos.<domain>` -> `krb5srv:m:udp:<freeipa-fqdn>.`
  - `_kpasswd.<domain>` -> `krb5srv:m:tcp:<freeipa-fqdn>.`
  - `_kpasswd.<domain>` -> `krb5srv:m:udp:<freeipa-fqdn>.`

## Pi-hole / dnsmasq Integration

If Pi-hole is authoritative for the identity zone:

- Treat it as a static external DNS authority. The FreeIPA playbook cannot update Pi-hole with `nsupdate`.
- Pi-hole UI local DNS entries are only sufficient for host A/AAAA records. SRV and URI records require custom dnsmasq configuration.
- On Pi-hole v6/FTL, make sure `/etc/dnsmasq.d/*.conf` loading is enabled, for example with `misc.etc_dnsmasq_d=true` or container env `FTLCONF_misc_etc_dnsmasq_d=true`.

Example `example.internal` snippet for the current `example` environment:

```ini
# /etc/dnsmasq.d/99-freeipa-lab-local.conf
host-record=public-freeipa-02.example.internal,198.51.100.44
host-record=ipa-ca.example.internal,198.51.100.44

srv-host=_ldap._tcp.example.internal,public-freeipa-02.example.internal,389,0,100
srv-host=_kerberos._tcp.example.internal,public-freeipa-02.example.internal,88,0,100
srv-host=_kerberos._udp.example.internal,public-freeipa-02.example.internal,88,0,100
srv-host=_kerberos-master._tcp.example.internal,public-freeipa-02.example.internal,88,0,100
srv-host=_kerberos-master._udp.example.internal,public-freeipa-02.example.internal,88,0,100
srv-host=_kpasswd._tcp.example.internal,public-freeipa-02.example.internal,464,0,100
srv-host=_kpasswd._udp.example.internal,public-freeipa-02.example.internal,464,0,100

# URI records are also required by ipa-healthcheck.
# Publish them with advanced dnsmasq dns-rr entries or use an
# authoritative DNS server that supports first-class URI records.
```

Reload Pi-hole after changing the snippet:

```bash
sudo pihole restartdns
```

Validate the external DNS view before rerunning FreeIPA:

```bash
dig @198.51.100.45 +short A ipa-ca.example.internal
dig @198.51.100.45 +short SRV _ldap._tcp.example.internal
dig @198.51.100.45 +short TYPE256 _kerberos.example.internal
```

## Verification Expectations

- Second-pass success requires `failed=0` and `unreachable=0`.
- In external DNS mode, repeated failures from `ipahealthcheck.ipa.idns` mean the zone is incomplete, not that the FreeIPA install itself is necessarily broken.
