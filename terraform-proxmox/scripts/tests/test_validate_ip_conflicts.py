"""Local regression tests; Terraform state and live probes are mocked."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import mock_open, patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('validator', ROOT / 'scripts/validate-ip-conflicts.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)
PARSE_TFVARS = validator.parse_tfvars_vms


def parse(source):
    with patch('builtins.open', mock_open(read_data=source)), patch.object(validator.os.path, 'isfile', return_value=True):
        return PARSE_TFVARS('/fixture/environments/candidate.tfvars')[2]


def config(name='candidate', vmid=101, ip='ip=192.0.2.0/24', extra='', prefix=''):
    return prefix + f'''node_groups = {{
      services = {{ a = {{
        name = "{name}"
        vmid = {vmid}
        ipconfig0 = "{ip}"
        {extra}
      }} }}
    }}'''


class ParserTests(unittest.TestCase):
    def test_malformed_network_entries_fail_closed(self):
        for entry in ('ip_address=192.0.2.0/24', 'ip=dhcp,ip=192.0.2.0/24',
                      'ip=198.51.100.53', 'ip=192.0.2.0/24,', 'ip=auto',
                      'ip6=manual', 'gw=dhcp', 'gw=198.51.100.19', 'gw6=2001:db8::1',
                      'ip=192.0.2.0/24,gw=198.51.100.0/24'):
            with self.subTest(entry=entry), self.assertRaises(ValueError):
                parse(config(ip=entry))

    def test_non_host_addresses_are_rejected(self):
        for entry in ('ip=203.0.113.0/24', 'ip=192.0.2.0/24', 'ip=198.51.100.0/24',
                      'ip=127.0.0.1/8', 'ip=224.0.0.1/24', 'ip6=ff02::1/64'):
            with self.subTest(entry=entry), self.assertRaises(ValueError):
                parse(config(ip=entry))

    def test_point_to_point_and_host_prefixes_remain_valid(self):
        for entry in ('ip=192.0.2.0/31', 'ip=192.0.2.2/31', 'ip=198.51.100.53', 'ip6=2001:db8::1/128'):
            with self.subTest(entry=entry):
                self.assertEqual(len(parse(config(ip=entry))), 1)

    def test_invalid_vmids_do_not_get_truncated_or_accepted(self):
        for vmid in (101.5, 0, -1, 1000000000, True):
            value = 'true' if vmid is True else str(vmid)
            with self.subTest(vmid=vmid), self.assertRaises(ValueError):
                parse(config(vmid=value))

    def test_vlan_precedence_and_zero_override(self):
        prefix = 'network_vlan = 100\nvm_defaults = { network_vlan = 200 }\n'
        self.assertEqual(parse(config(prefix=prefix))[0]['vlan'], 200)
        self.assertEqual(parse(config(prefix=prefix, extra='network_vlan = 0'))[0]['vlan'], 0)
        self.assertEqual(parse(config(prefix=prefix, extra='network_vlan = null'))[0]['vlan'], 200)

    def test_vm_override_does_not_become_global_default(self):
        source = 'node_groups = { g = { a = { name="a" vmid=101 ipconfig0="ip=198.51.100.0/24" network_vlan=200 } b = { name="b" vmid=102 ipconfig0="ip=203.0.113.0/24" } } }'
        self.assertEqual([vm['vlan'] for vm in parse(source)], [200, 0])

    def test_strings_nested_objects_comments_and_heredocs(self):
        prefix = 'ssh_key = <<-KEY\n  literal { # // }\nKEY\n/* ignored } */\n'
        extra = 'description = "literal } # // \\"quoted\\""\npartitioning = { mounts = [{ mount = "/a", size = 10 }] }'
        self.assertEqual(parse(config(prefix=prefix, extra=extra))[0]['vmid'], 101)

    def test_unsupported_syntax_fails_closed(self):
        for source in ('node_groups = merge({}, {})', 'node_groups = {', config(ip='${var.ip}'), config(extra='network_vlan = -1')):
            with self.subTest(source=source), self.assertRaises(ValueError):
                parse(source)

    def test_missing_ipconfig_is_not_silently_skipped(self):
        with self.assertRaises(KeyError):
            parse('node_groups = { g = { a = { name="a" vmid=101 } } }')

    def test_ipv6_is_normalized(self):
        self.assertEqual(parse(config(ip='ip6=2001:0DB8:0:0:0:0:0:1/64'))[0]['ip6'], '2001:db8::1')

    def test_dhcp_keeps_identity_without_fake_ipv6(self):
        vm = parse(config(ip='ip=dhcp,ip6=auto'))[0]
        self.assertEqual(vm['vmid'], 101)
        self.assertNotIn('ip6', vm)

    def test_invalid_address_fails_closed(self):
        with self.assertRaises(ValueError):
            parse(config(ip='ip=999.0.2.1/24'))

    def test_inventory_ipv6_and_unknown_vlan(self):
        source = 'host ansible_host="2001:0db8:0:0:0:0:0:1" vmid=101\n'
        with patch('builtins.open', mock_open(read_data=source)), patch.object(validator.os.path, 'isfile', return_value=True):
            hosts = validator.parse_inventory_vms('/fixture/inventory.ini')[1]
        self.assertEqual(hosts[0]['ip6'], '2001:db8::1')
        self.assertIsNone(hosts[0]['vlan'])

    def test_infrastructure_from_file_and_environment_without_fixed_addresses(self):
        source = 'export PROXMOX_HOST="198.51.100.54"\nPVE_URL="https://[2001:db8::2]:8006"\n'
        with patch('builtins.open', mock_open(read_data=source)), patch.object(validator.os.path, 'isfile', return_value=True), patch.dict(os.environ, {'ANSIBLE_HOST': '198.51.100.55'}, clear=True):
            self.assertEqual(set(validator.parse_env_infrastructure_ips('/fixture/.env')), {'198.51.100.54', '2001:db8::2', '198.51.100.55'})


class VariableSourceTests(unittest.TestCase):
    def test_inherited_vlan_conflict_blocks_both_environments(self):
        with tempfile.TemporaryDirectory(prefix='iac-input-test-') as folder, patch.dict(os.environ, {}, clear=True):
            root = Path(folder)
            (root / 'environments').mkdir()
            (root / 'network.auto.tfvars').write_text('network_vlan=200')
            (root / 'environments/example.tfvars').write_text(config(name='example', vmid=101))
            (root / 'environments/optiplex.tfvars').write_text(config(name='optiplex', vmid=102, extra='network_vlan=200'))
            for environment in ('example', 'optiplex'):
                output = io.StringIO()
                with self.subTest(environment=environment), patch.object(validator.sys, 'argv', ['validator', '-e', environment, '-r', folder, '--skip-live-probe']), contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as result:
                    validator.main()
                self.assertEqual(result.exception.code, 1)
                self.assertIn('CROSS_ENV_TFVARS_IP_OVERLAP', output.getvalue())

    def test_integer_compatible_vlan_inputs(self):
        for value in (100, 100.0, '100'):
            self.assertEqual(validator.validate_vlan(value), 100)
        for value in (100.5, True, -1, 4095):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validator.validate_vlan(value)

    def test_environment_auto_files_and_final_explicit_file(self):
        with tempfile.TemporaryDirectory(prefix='iac-input-test-') as folder, patch.dict(os.environ, {'TF_VAR_network_vlan': '10'}, clear=True):
            root = Path(folder)
            (root / 'terraform.tfvars').write_text('network_vlan=20\nvm_defaults={network_vlan=90}\n')
            (root / 'terraform.tfvars.json').write_text('{"network_vlan":30}')
            (root / 'a.auto.tfvars.json').write_text('{"network_vlan":40}')
            (root / 'z.auto.tfvars').write_text('network_vlan=50')
            candidate = root / 'candidate.tfvars'
            candidate.write_text(config(prefix='vm_defaults={}\n'))
            defaults = validator.load_network_defaults(folder, 'plan')
            self.assertEqual(defaults['network_vlan'], 50)
            # The explicit file replaces the map; VLAN 90 must not survive.
            self.assertEqual(PARSE_TFVARS(str(candidate), defaults)[2][0]['vlan'], 50)
            candidate.write_text(config(prefix='network_vlan=60\nvm_defaults={}\n'))
            self.assertEqual(PARSE_TFVARS(str(candidate), defaults)[2][0]['vlan'], 60)

    def test_injected_files_and_global_cli_precedence(self):
        with tempfile.TemporaryDirectory(prefix='iac-input-test-') as folder, patch.dict(os.environ, {}, clear=True):
            root = Path(folder)
            (root / 'injected.tfvars').write_text('network_vlan=20')
            os.environ.update({
                'TF_CLI_ARGS_plan': '-var=network_vlan=10',
                'TF_CLI_ARGS': '-var-file injected.tfvars -var network_vlan=30',
            })
            self.assertEqual(validator.load_network_defaults(folder, 'plan')['network_vlan'], 30)

    def test_missing_injected_file_and_malformed_assignment_fail_closed(self):
        with tempfile.TemporaryDirectory(prefix='iac-input-test-') as folder:
            for arguments in ('-var-file missing.tfvars', '-var', '-var network_vlan'):
                with self.subTest(arguments=arguments), patch.dict(os.environ, {'TF_CLI_ARGS_plan': arguments}, clear=True), self.assertRaises((ValueError, OSError)):
                    validator.load_network_defaults(folder, 'plan')

    def test_stage_specific_network_mismatch_blocks_main(self):
        with tempfile.TemporaryDirectory(prefix='iac-input-test-') as folder, patch.dict(os.environ, {'TF_CLI_ARGS_plan': '-var=network_vlan=100'}, clear=True):
            root = Path(folder)
            (root / 'environments').mkdir()
            (root / 'environments/candidate.tfvars').write_text(config())
            with patch.object(validator.sys, 'argv', ['validator', '-e', 'candidate', '-r', folder, '--skip-live-probe']), contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(ValueError, 'different VM allocations'):
                validator.main()

    @unittest.skipUnless(shutil.which('terraform'), 'Terraform CLI required for precedence cross-check')
    def test_precedence_matches_real_terraform_console(self):
        with tempfile.TemporaryDirectory(prefix='iac-console-test-') as folder:
            root = Path(folder)
            (root / 'main.tf').write_text('variable "network_vlan" {\n type=number\n default=0\n}\nvariable "vm_defaults" {\n type=object({network_vlan=optional(number)})\n default={}\n}\nvariable "node_groups" { default={} }\n')
            (root / 'terraform.tfvars').write_text('network_vlan=20')
            (root / 'terraform.tfvars.json').write_text('{"network_vlan":30}')
            (root / 'a.auto.tfvars').write_text('network_vlan=40')
            (root / 'z.auto.tfvars.json').write_text('{"network_vlan":50}')
            candidate = root / 'candidate.tfvars'
            candidate.write_text(config())
            environment = {'PATH': os.environ['PATH'], 'TF_VAR_network_vlan': '10',
                           'TF_CLI_ARGS_console': '-var=network_vlan=60',
                           'TF_CLI_ARGS': '-var=network_vlan=70'}
            expression = 'coalesce(try(var.node_groups.services.a.network_vlan,null),try(var.vm_defaults.network_vlan,null),var.network_vlan)\n'
            for prefix in ('', 'network_vlan=80\n', 'vm_defaults={network_vlan=90}\n'):
                candidate.write_text(config(prefix=prefix))
                with self.subTest(prefix=prefix), patch.dict(os.environ, environment, clear=True):
                    predicted = PARSE_TFVARS(str(candidate), validator.load_network_defaults(folder, 'console'))[2][0]['vlan']
                    actual = subprocess.run(['terraform', 'console', '-no-color', '-var-file=candidate.tfvars'], input=expression, cwd=folder, capture_output=True, text=True, timeout=15)
                self.assertEqual(actual.returncode, 0, actual.stderr)
                self.assertEqual(int(actual.stdout.strip()), predicted)


class GuardTests(unittest.TestCase):
    def run_guard(self, candidate, other=None, inventory=(), managed=(), live=False, response=False, other_inventory=(), warn=False, other_inv_paths=None):
        def tfvars(path, base_config=None):
            source = candidate if path.endswith('candidate.tfvars') else (other or 'node_groups = {}')
            return 'fixture', 0, parse(source)

        def inventory_hosts(path):
            is_other = ('/other/' in path or '/k8s/' in path or '/optiplex/' in path or '/example/' in path)
            return 'fixture', list(other_inventory if is_other else inventory)

        def files(pattern):
            if pattern.endswith('*.tfvars'):
                return ['/fixture/environments/candidate.tfvars', '/fixture/environments/other.tfvars']
            if other_inv_paths is not None:
                return other_inv_paths
            return ['/fixture/../inventories/other/inventory.ini'] if other_inventory else []

        args = ['validator', '-e', 'candidate', '-r', '/fixture']
        if not live:
            args.append('--skip-live-probe')
        if warn:
            args.append('--warn-only')
        output = io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(validator.sys, 'argv', args))
            stack.enter_context(patch.object(validator.os.path, 'isfile', return_value=True))
            stack.enter_context(patch.object(validator, 'parse_tfvars_vms', side_effect=tfvars))
            stack.enter_context(patch.object(validator, 'load_network_defaults', return_value={}))
            # Use the original parser inside the mocked loader.
            stack.enter_context(patch.object(validator, 'parse_inventory_vms', side_effect=inventory_hosts))
            stack.enter_context(patch.object(validator.glob, 'glob', side_effect=files))
            stack.enter_context(patch.object(validator, 'parse_env_infrastructure_ips', return_value={}))
            stack.enter_context(patch.object(validator, 'load_managed_vms', return_value=list(managed)))
            probe = stack.enter_context(patch.object(validator, 'probe_ip_live', return_value=response))
            stack.enter_context(contextlib.redirect_stdout(output))
            with self.assertRaises(SystemExit) as result:
                validator.main()
        return result.exception.code, output.getvalue(), probe.call_count

    def test_cross_environment_ipv4_blocks(self):
        status, output, _ = self.run_guard(config(), config(name='other', vmid=102))
        self.assertEqual(status, 1)
        self.assertIn('CROSS_ENV_TFVARS_IP_OVERLAP', output)

    def test_equivalent_ipv6_blocks(self):
        status, output, _ = self.run_guard(config(ip='ip6=2001:db8::1/64'), config(name='other', vmid=102, ip='ip6=2001:0db8:0:0:0:0:0:1/64'))
        self.assertEqual(status, 1)
        self.assertIn('CROSS_ENV_TFVARS_IP6_OVERLAP', output)

    def test_effective_vlan_overlap_blocks(self):
        candidate = config(prefix='network_vlan=100\nvm_defaults={network_vlan=200}\n')
        other = config(name='other', vmid=102, prefix='network_vlan=200\n')
        self.assertEqual(self.run_guard(candidate, other)[0], 1)

    def test_untagged_is_not_wildcard(self):
        other = config(name='other', vmid=102, prefix='network_vlan=200\n')
        self.assertEqual(self.run_guard(config(), other)[0], 0)

    def test_unknown_inventory_vlan_is_conservative(self):
        other = dict(parse(config(name='other', vmid=102))[0], vlan=None)
        self.assertEqual(self.run_guard(config(extra='network_vlan=200'), other_inventory=[other])[0], 1)

    def test_inventory_ipv6_overlap_blocks(self):
        other = parse(config(name='other', vmid=102, ip='ip6=2001:db8::1/64'))
        self.assertEqual(self.run_guard(config(ip='ip6=2001:db8::1/64'), other_inventory=other)[0], 1)

    def test_reassignment_of_old_inventory_address_blocks(self):
        old = parse(config(name='old', vmid=102))
        status, output, _ = self.run_guard(config(), inventory=old, live=True, response=True)
        self.assertEqual(status, 1)
        self.assertIn('OWN_ENV_IP_REASSIGNMENT', output)

    def test_matching_inventory_alone_does_not_bypass_probe(self):
        status, _, probes = self.run_guard(config(), inventory=parse(config()), live=True, response=True)
        self.assertEqual((status, probes), (1, 1))

    def test_state_owner_without_inventory_is_allowed(self):
        status, _, probes = self.run_guard(config(), managed=parse(config()), live=True, response=True)
        self.assertEqual((status, probes), (0, 0))

    def test_state_owner_rename_is_allowed(self):
        self.assertEqual(self.run_guard(config(name='renamed'), managed=parse(config()), live=True, response=True)[0], 0)

    def test_different_vlan_cannot_inherit_state_ownership(self):
        status, _, probes = self.run_guard(config(extra='network_vlan=200'), managed=parse(config()), live=True, response=True)
        self.assertEqual((status, probes), (1, 1))

    def test_live_ipv6_is_probed(self):
        status, output, probes = self.run_guard(config(ip='ip6=2001:db8::1/64'), live=True, response=True)
        self.assertEqual((status, probes), (1, 1))
        self.assertIn('LIVE_NETWORK_IP_COLLISION', output)

    def test_dhcp_hostname_conflict_is_not_skipped(self):
        self.assertEqual(self.run_guard(config(ip='ip=dhcp'), config(vmid=102, ip='ip=dhcp'))[0], 1)

    def test_other_vms_gateway_is_reserved(self):
        other = config(name='other', vmid=102, ip='ip=192.0.2.0/24,gw=198.51.100.53')
        status, output, _ = self.run_guard(config(), other)
        self.assertEqual(status, 1)
        self.assertIn('GATEWAY_COLLISION', output)

    def test_explicit_warn_only_override(self):
        self.assertEqual(self.run_guard(config(), config(name='other', vmid=102), warn=True)[0], 0)

    def test_k8s_aggregate_inventory_is_ignored_and_does_not_conflict(self):
        same_node = parse(config(name='k8s-node', vmid=101, ip='ip=192.0.2.0/24'))
        status, output, _ = self.run_guard(
            config(name='k8s-node', vmid=101, ip='ip=192.0.2.0/24'),
            other_inventory=same_node,
            other_inv_paths=['/fixture/../inventories/k8s/inventory.ini'],
        )
        self.assertEqual(status, 0)
        self.assertNotIn('CROSS_ENV_INVENTORY_IP_OVERLAP', output)

    def test_other_env_inventory_overlap_blocks(self):
        same_node = parse(config(name='other-node', vmid=102, ip='ip=192.0.2.0/24'))
        status, output, _ = self.run_guard(
            config(name='candidate-node', vmid=101, ip='ip=192.0.2.0/24'),
            other_inventory=same_node,
            other_inv_paths=['/fixture/../inventories/optiplex/inventory.ini'],
        )
        self.assertEqual(status, 1)
        self.assertIn('CROSS_ENV_INVENTORY_IP_OVERLAP', output)


class RuntimeTests(unittest.TestCase):
    def test_auth_wrapper_preserves_explicit_workspace(self):
        for environment in ('example', 'optiplex'):
            with self.subTest(environment=environment), tempfile.TemporaryDirectory(prefix='iac-auth-test-') as folder:
                env_file = Path(folder) / 'test.env'
                env_file.write_text('VAULT_ADDR=http://127.0.0.1:9\nVAULT_TOKEN=fixture\nTF_VAR_vault_token=fixture\nTF_WORKSPACE=wrong-workspace\n')
                # A fake token lookup prevents all network/authentication calls.
                (Path(folder) / 'vault').symlink_to('/bin/true')
                result = subprocess.run([
                    '/bin/bash', str(ROOT / 'scripts/with-vault-token.sh'),
                    '/bin/bash', '-c', 'printf "%s" "$TF_WORKSPACE"',
                ], env={'PATH': f'{folder}:/usr/bin:/bin', 'ENV_FILE': str(env_file), 'TF_WORKSPACE': environment}, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, environment)

    def test_make_binds_each_environment_after_dotenv_is_sourced(self):
        # Exercise the real recipes with Terraform replaced by a harmless
        # process that reports its workspace. Suppress prerequisites that could
        # initialize a backend, render files or contact infrastructure.
        for environment in ('example', 'optiplex'):
            if not (ROOT / 'environments' / f'{environment}.tfvars').exists():
                continue
            for target in ('plan', 'render-snippets', 'apply'):
                with self.subTest(environment=environment, target=target), tempfile.TemporaryDirectory(prefix='iac-make-test-') as folder:
                    env_file = Path(folder) / 'test.env'
                    env_file.write_text('TF_WORKSPACE=wrong-workspace\n')
                    result = subprocess.run([
                        'make', '--no-print-directory', '-C', str(ROOT), target,
                        '-o', 'init', '-o', 'validate', '-o', 'check-ip-conflicts', '-o', 'workspace-select',
                        f'ENVIRONMENT={environment}', 'CURRENT_WORKSPACE=wrong-workspace',
                        f'ENV_FILE={env_file}', f'LOG_DIR={folder}', f'PLAN_DIR={folder}',
                        f'WITH_VAULT_TOKEN_SCRIPT={sys.executable} -B {Path(__file__).resolve()} --fake-terraform',
                        'MAKE=/bin/true',
                    ], capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                    records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{"workspace":')]
                    self.assertTrue(records, result.stdout)
                    self.assertTrue(all(record['workspace'] == environment for record in records), records)

    def test_plan_bootstrap_honors_explicit_workspace_without_shared_selection(self):
        # Reproduce the plan -> recursive vault-bootstrap path. The Terraform
        # boundary rejects workspace mutation while TF_WORKSPACE is set, as the
        # real CLI does, and records any unbound mutation attempt.
        with tempfile.TemporaryDirectory(prefix='iac-plan-bootstrap-test-') as folder:
            fixture = Path(folder)
            mutation_log = fixture / 'workspace-mutations.log'
            plan_marker = fixture / 'plan-attempted'
            env_file = fixture / 'test.env'
            env_file.write_text('TF_WORKSPACE=wrong-workspace\n')

            terraform = fixture / 'terraform'
            terraform.write_text(f'''#!/bin/bash
set -eu
if [ "${{1:-}} ${{2:-}}" = "workspace list" ]; then
    printf '  default\n* wrong-workspace\n  dev\n'
    exit 0
fi
if [ "${{1:-}}" = "workspace" ] && {{ [ "${{2:-}}" = "new" ] || [ "${{2:-}}" = "select" ]; }}; then
    printf '%s workspace=%s\n' "$2" "${{TF_WORKSPACE:-}}" >> {mutation_log}
    if [ -n "${{TF_WORKSPACE:-}}" ]; then
        printf 'TF_WORKSPACE cannot be overridden using workspace commands\n' >&2
        exit 1
    fi
fi
''')
            terraform.chmod(0o755)

            plan = fixture / 'fake-plan'
            plan.write_text(f'''#!/bin/bash
set -eu
if [ ! -e {plan_marker} ]; then
    touch {plan_marker}
    printf 'path is already in use at fixture/\n'
    exit 1
fi
printf '{{"workspace":"%s","command":"plan-retry"}}\n' "${{TF_WORKSPACE:-}}"
''')
            plan.chmod(0o755)

            bootstrap = fixture / 'fake-vault-bootstrap'
            bootstrap.write_text('''#!/bin/bash
printf '{"workspace":"%s","command":"vault-bootstrap"}\n' "${TF_WORKSPACE:-}"
''')
            bootstrap.chmod(0o755)

            env = os.environ.copy()
            env['PATH'] = f'{fixture}:{env["PATH"]}'
            result = subprocess.run([
                'make', '--no-print-directory', '-C', str(ROOT), 'plan',
                '-o', 'validate', '-o', 'check-ip-conflicts', '-o', 'create-dirs',
                'ENVIRONMENT=dev', 'CURRENT_WORKSPACE=wrong-workspace',
                'PROXMOX_HOST=198.51.100.19',
                f'DIRS={fixture}/dirs', f'INVENTORY_DIR={fixture}/inventory',
                f'LEGACY_INVENTORY_DIR={fixture}/legacy',
                f'ENV_FILE={env_file}', f'LOG_DIR={fixture}', f'PLAN_DIR={fixture}',
                f'WITH_VAULT_TOKEN_SCRIPT={plan}', f'VAULT_BOOTSTRAP_SCRIPT={bootstrap}',
            ], env=env, capture_output=True, text=True, timeout=15)

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{"workspace":')]
            self.assertEqual(records, [
                {'workspace': 'dev', 'command': 'vault-bootstrap'},
                {'workspace': 'dev', 'command': 'plan-retry'},
            ])
            self.assertFalse(mutation_log.exists(), mutation_log.read_text() if mutation_log.exists() else '')

    def test_real_vault_bootstrap_preserves_workspace_after_dotenv(self):
        # Stop at the authentication boundary before any real Vault/Proxmox
        # call or Terraform mutation. Run the real script's dotenv handling.
        with tempfile.TemporaryDirectory(prefix='iac-bootstrap-env-test-') as folder:
            fixture = Path(folder)
            env_file = fixture / 'test.env'
            env_file.write_text('TF_WORKSPACE=wrong-workspace\n')
            tfvars = fixture / 'test.tfvars'
            tfvars.write_text('vault_manage_kv_mount = false\n')
            observed = fixture / 'observed-workspace'
            auth = fixture / 'auth-probe'
            auth.write_text(f'#!/bin/bash\nprintf "%s" "$TF_WORKSPACE" > "{observed}"\nexit 1\n')
            auth.chmod(0o755)
            for command in ('terraform', 'vault', 'jq'):
                (fixture / command).symlink_to('/bin/true')
            result = subprocess.run([
                '/bin/bash', str(ROOT / 'scripts/vault-bootstrap.sh'),
            ], env={
                'PATH': f'{fixture}:/usr/bin:/bin',
                'ENVIRONMENT': 'dev', 'TF_WORKSPACE': 'dev',
                'ENV_FILE': str(env_file), 'TFVARS_FILE': str(tfvars),
                'VAULT_ADDR': 'http://127.0.0.1:9',
                'VAULT_AUTH_SCRIPT': str(auth),
                'ROTATE_PROXMOX_CREDS_SCRIPT': '/bin/false',
            }, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0, 'the auth probe must stop bootstrap')
            self.assertTrue(observed.exists(), result.stdout + result.stderr)
            self.assertEqual(observed.read_text(), 'dev')

    def test_ping_errors_fail_closed(self):
        for failure in (FileNotFoundError(), subprocess.TimeoutExpired('ping', 3)):
            with patch.object(validator.subprocess, 'run', side_effect=failure), self.assertRaises(RuntimeError):
                validator.probe_ip_live('198.51.100.53')
        with patch.object(validator.subprocess, 'run', return_value=subprocess.CompletedProcess([], 2)), self.assertRaises(RuntimeError):
            validator.probe_ip_live('198.51.100.53')

    def test_ping_no_reply_and_ipv6_arguments(self):
        with patch.object(validator.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)) as run:
            self.assertFalse(validator.probe_ip_live('2001:db8::1'))
        self.assertIn('-6', run.call_args.args[0])
        self.assertEqual(run.call_args.kwargs['timeout'], 3)

    def test_state_pull_selects_workspace_without_mutation(self):
        state = {'resources': [{'mode': 'managed', 'type': 'proxmox_vm_qemu', 'instances': [{'attributes': {
            'name': 'candidate', 'vmid': 101, 'ipconfig0': 'ip=192.0.2.0/24',
            'network': [{'id': 1, 'tag': 300}, {'id': 0, 'tag': 200}],
        }}]}]}
        with patch.object(validator.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(state), '')) as run:
            hosts = validator.load_managed_vms('/fixture', 'candidate')
        self.assertEqual(hosts[0]['vlan'], 200)
        self.assertEqual(run.call_args.kwargs['env']['TF_WORKSPACE'], 'candidate')
        self.assertEqual(run.call_args.args[0], ['terraform', 'state', 'pull'])

    def test_state_backend_failure_blocks(self):
        with patch.object(validator.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'access denied')), self.assertRaises(RuntimeError):
            validator.load_managed_vms('/fixture', 'candidate')

    def test_unset_state_tag_is_untagged(self):
        for tag in (None, 0, -1):
            state = {'resources': [{'mode': 'managed', 'type': 'proxmox_vm_qemu', 'instances': [{'attributes': {
                'name': 'candidate', 'vmid': 101, 'ipconfig0': 'ip=192.0.2.0/24',
                'network': [{'id': 0, 'tag': tag}],
            }}]}]}
            with self.subTest(tag=tag), patch.object(validator.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(state), '')):
                self.assertEqual(validator.load_managed_vms('/fixture', 'candidate')[0]['vlan'], 0)

    def test_new_workspace_has_no_owners(self):
        with patch.object(validator.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')):
            self.assertEqual(validator.load_managed_vms('/fixture', 'candidate'), [])

    def test_wrapper_missing_argument(self):
        result = subprocess.run(['bash', str(ROOT / 'scripts/validate-ip-conflicts.sh'), '--environment'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('requires a value', result.stderr)

    def test_apply_stops_at_failed_guard(self):
        # /bin/false replaces the guard. The first prerequisite must stop make
        # before snippets, plan, or apply. CURRENT_WORKSPACE avoids a state query.
        result = subprocess.run([
            'make', '--no-print-directory', '-C', str(ROOT), 'apply',
            'ENVIRONMENT=dev', 'CURRENT_WORKSPACE=dev', 'ENV_FILE=/dev/null',
            'VALIDATE_IP_CONFLICTS_SCRIPT=/bin/false',
        ], capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('check-ip-conflicts', result.stderr)
        self.assertNotIn('Rendering', result.stdout)
        self.assertNotIn('Applying Terraform', result.stdout)


if __name__ == '__main__':
    if sys.argv[1:2] == ['--fake-terraform']:
        print(json.dumps({'workspace': os.getenv('TF_WORKSPACE'), 'command': sys.argv[2:]}))
    else:
        unittest.main()
