# Terraform-Proxmox Hardening — Design Spec

**Date:** 2026-04-08
**Scope:** 4 specs improving validation, script robustness, Packer templates, and test infrastructure in `terraform-proxmox/`.
**Branch:** `terraform-proxmox-automated-infra`
**Revision:** v2 — incorporates findings from 5 independent code reviews

---

## Spec 1: Terraform Validation & Outputs Hardening

### Problem

- No VMID uniqueness validation — duplicate VMIDs across node_groups are silently accepted, causing Proxmox API failures or VM overwrites.
- No VMID range validation — operators can accidentally use reserved Packer ranges (999999990-999999995).
- IP parsing in `outputs.tf` and `main.tf` uses a fragile triple-nested `split()` chain that crashes on `ipconfig0 = "dhcp"` or malformed strings. Affects outputs (line 53, 109, 115) AND inventory generation (line 191).
- `main.tf:390-391` hard-codes `provider_version = "3.0.2-rc07"` and `terraform_version = ">=1.0.0"` in the deployment summary JSON, drifting from `versions.tf`.

### Changes

#### 1.1 VMID Uniqueness Validation

Add validation block after existing block at `variables.tf:320`:

```hcl
validation {
  condition = length(flatten([
    for _, group in var.node_groups : [for _, vm in group : vm.vmid]
  ])) == length(distinct(flatten([
    for _, group in var.node_groups : [for _, vm in group : vm.vmid]
  ])))
  error_message = "Duplicate VMIDs detected across node_groups. Each VM must have a unique vmid."
}
```

Hard fail at plan time. Operator must fix before any apply.

#### 1.2 VMID Range Validation

Add validation block after 1.1:

```hcl
validation {
  condition = alltrue(flatten([
    for _, group in var.node_groups : [
      for _, vm in group : vm.vmid >= 100 && vm.vmid <= 999999989
    ]
  ]))
  error_message = "node_groups.*.*.vmid must be between 100 and 999999989. Range 999999990-999999995 is reserved for Packer base VMs and templates."
}
```

Hard fail for out-of-range. Reserved template range excluded by upper bound.

#### 1.3 Safe IP Parsing

Add a local in `main.tf` after line 157 (after `sorted_vm_names`):

```hcl
locals {
  vm_parsed_host_ips = {
    for name in local.sorted_vm_names :
    name => try(
      split("/", split("=", split(",", local.vm_name_to_ip[name])[0])[1])[0],
      local.vm_name_to_ip[name]
    )
  }
}
```

Update **4 locations** (3 in outputs.tf + 1 in main.tf):

1. **`outputs.tf:51-54`** (`all_vm_host_ips`): Replace inline split chain with `local.vm_parsed_host_ips[name]`

2. **`outputs.tf:109`** (`connection_info.group_ips`): Wrap with `try()`:
   ```hcl
   try(split("=", split(",", vm.config.ipconfig0)[0])[1], vm.config.ipconfig0)
   ```

3. **`outputs.tf:115`** (`connection_info.group_host_ips`): Wrap with `try()`:
   ```hcl
   try(split("/", split("=", split(",", vm.config.ipconfig0)[0])[1])[0], vm.config.ipconfig0)
   ```

4. **`main.tf:191`** (`inventory_all_nodes_lines` IP extraction): Wrap with `try()`:
   ```hcl
   try(split("/", split("=", split(",", local.flattened_vms[vm_key].config.ipconfig0)[0])[1])[0], "UNPARSED")
   ```

Note: outputs 2-3 iterate over `local.flattened_vms` (not `sorted_vm_names`), so they use inline `try()` rather than the named local.

#### 1.4 Remove Hard-coded Versions from Deployment Summary

At `main.tf:389-394`, remove the hard-coded version strings. The `terraform.workspace` is already captured at line 387, so avoid adding redundancy. Replace:

```hcl
# Before (lines 389-394)
deployment_info = merge({
  terraform_version = ">=1.0.0"
  provider_version  = "3.0.2-rc07"
  }, local.creation_timestamp != "" ? {
  timestamp = local.creation_timestamp
} : {})

# After — only keep the conditional timestamp
deployment_info = local.creation_timestamp != "" ? {
  timestamp = local.creation_timestamp
} : {}
```

Version info belongs in `versions.tf` and `.terraform.lock.hcl`, not duplicated in output artifacts. Workspace is already at line 387.

### Files Modified

| File | Change |
|------|--------|
| `variables.tf` | Add 2 validation blocks after line 320 (~20 lines) |
| `main.tf` | Add `vm_parsed_host_ips` local after line 157 (~7 lines), fix IP parsing at line 191, simplify deployment_info at lines 389-394 |
| `outputs.tf` | Replace inline split at line 53, wrap with try() at lines 109 and 115 |

---

## Spec 2: Script Robustness & Makefile Parsing

### Problem

- tfvars awk parsing logic duplicated in Makefile (lines 50-53, 63, 693-694), `rotate-proxmox-creds.sh` (`read_tfvars_value()` function), and `vault-bootstrap.sh` (lines 265, 268, 278).
- `check-tools.sh` `ver_to_int()` produces zero-padded strings that bash interprets as octal — version 1.14.8 falsely reported as below 1.10.0 (confirmed in E2E testing).
- `upload-snippets.sh` has no post-upload verification — uploads succeed silently even if files don't land correctly.

### Changes

#### 2.1 Shared tfvars Parser: `scripts/read-tfvar.sh`

New standalone script. Interface:

```bash
scripts/read-tfvar.sh <key> <file>
# Outputs value to stdout (lowercase, trimmed, unquoted), exits 1 if key not found or file missing
```

Contains the canonical awk logic (handles `//` and `/* */` comments, quote stripping, whitespace trimming). Output is always lowercased — this matches the `tolower()` behavior at Makefile:693-694 and is safe for all current consumers since parsed values are case-insensitive identifiers (`token`, `approle`, `true`, `false`, storage names, mount paths).

**All 6 consumer sites updated:**

| Location | Before | After |
|----------|--------|-------|
| `Makefile:52` | Inline awk for VAULT_KV_MOUNT_PATH | `$(shell $(MAKEFILE_DIR)/scripts/read-tfvar.sh vault_kv_mount_path $(TFVARS_FILE_FOR_ENV))` |
| `Makefile:53` | Inline awk for VAULT_SECRET_PREFIX | `$(shell $(MAKEFILE_DIR)/scripts/read-tfvar.sh vault_secret_prefix $(TFVARS_FILE_FOR_ENV))` |
| `Makefile:63` | Inline awk for SNIPPET_STORAGE | `$(shell $(MAKEFILE_DIR)/scripts/read-tfvar.sh snippet_storage $(TFVARS_FILE_FOR_ENV))` |
| `Makefile:693` | Inline awk for vault_auth_mode (with tolower) | `$(shell $(MAKEFILE_DIR)/scripts/read-tfvar.sh vault_auth_mode $$TFVARS_FILE)` |
| `Makefile:694` | Inline awk for manage_vault_access (with tolower) | `$(shell $(MAKEFILE_DIR)/scripts/read-tfvar.sh manage_vault_access $$TFVARS_FILE)` |
| `rotate-proxmox-creds.sh:84-101` | `read_tfvars_value()` function | Call `"${SCRIPT_DIR}/read-tfvar.sh" <key> <file>` |
| `vault-bootstrap.sh:265,268,278` | `read_tfvars_value()` function | Call `"${SCRIPT_DIR}/read-tfvar.sh" <key> <file>` |

Note: Makefile calls use `$(MAKEFILE_DIR)/scripts/` (absolute path) to avoid CWD-sensitivity, since Make evaluates `$(shell)` at parse time.

#### 2.2 check-tools.sh Octal Fix

At `check-tools.sh:145`, the `ver_to_int` output (e.g., `001014008` for 1.14.8) is compared with `-ge`. Bash interprets zero-padded numbers as octal, and `008`/`009` are invalid octal digits. Fix at line 145:

```bash
# Before (line 145 — fails on versions with components >= 8)
if [[ "$(ver_to_int "${tf_version}")" -ge "$(ver_to_int "${MIN_TERRAFORM_VERSION}")" ]]; then

# After
if [[ "10#$(ver_to_int "${tf_version}")" -ge "10#$(ver_to_int "${MIN_TERRAFORM_VERSION}")" ]]; then
```

One-line fix. The `10#` prefix forces decimal interpretation. Only one comparison site uses `ver_to_int` (confirmed via codebase search).

#### 2.3 upload-snippets.sh Post-Upload Verification

After the SCP upload loop (line 139), add verification that mirrors the local glob fallback logic (lines 125-129 fall back to all `*.yaml` if no env-prefixed files exist):

```bash
# Build remote glob matching local selection logic
if [[ "${snippet_files[0]}" == *"${ENVIRONMENT}-"* ]]; then
    remote_glob="${REMOTE_PATH}/${ENVIRONMENT}-*.yaml"
else
    remote_glob="${REMOTE_PATH}/*.yaml"
fi

remote_count=$($SSH_CMD -o StrictHostKeyChecking="${SSH_STRICT_HOST_KEY_CHECKING}" \
    "$PROXMOX_USER@$PROXMOX_HOST" "ls -1 $remote_glob 2>/dev/null | wc -l")
local_count=${#snippet_files[@]}

if [[ "$remote_count" -ne "$local_count" ]]; then
    echo "Error: Upload verification failed. Local: $local_count files, Remote: $remote_count files."
    for file in "${snippet_files[@]}"; do
        filename="$(basename "$file")"
        $SSH_CMD -o StrictHostKeyChecking="${SSH_STRICT_HOST_KEY_CHECKING}" \
            "$PROXMOX_USER@$PROXMOX_HOST" "test -f '$REMOTE_PATH/$filename'" \
            || echo "  Missing: $filename"
    done
    exit 1
fi
echo "Verification: $remote_count/$local_count files confirmed on remote."
```

### Files Modified

| File | Change |
|------|--------|
| `scripts/read-tfvar.sh` | New file (~40 lines) |
| `Makefile` | Replace 5 inline awk calls with `$(shell $(MAKEFILE_DIR)/scripts/read-tfvar.sh ...)` |
| `rotate-proxmox-creds.sh` | Remove `read_tfvars_value()`, call `read-tfvar.sh` |
| `vault-bootstrap.sh` | Replace `read_tfvars_value()` calls at lines 265, 268, 278 with `read-tfvar.sh` |
| `scripts/check-tools.sh` | Add `10#` prefix in version comparison at line 145 |
| `scripts/upload-snippets.sh` | Add post-upload verification block (~20 lines) |

---

## Spec 3: Packer Template Improvements

### Problem

All 3 Packer templates (ubuntu-noble, oracle8, oracle9) have empty `build {}` blocks — they clone a base VM into a template but perform zero validation that the resulting template is correctly configured.

### Changes

#### 3.1 New Script: `scripts/verify-packer-template.sh`

Interface:

```bash
scripts/verify-packer-template.sh \
  --api-url <url> --node <node> --vmid <vmid> [--tls-insecure]
# Reads PROXMOX_TOKEN_ID and PROXMOX_TOKEN from environment (avoids token in command line)
```

Credentials are passed via environment variables (not command-line args) to avoid exposure in `ps` output and shell history.

Queries `GET /api2/json/nodes/{node}/qemu/{vmid}/config` via `curl` and asserts:

| Property | Expected |
|----------|----------|
| `bios` | `ovmf` |
| `scsihw` | `virtio-scsi-single` |
| `agent` | contains `1` (enabled) |
| `serial0` | `socket` |
| `machine` | `q35` |
| `scsi0` | exists (boot disk present) |
| cloud-init disk | `scsi1` or `ide2` contains `cloudinit` |
| `cores` | matches expected (passed as `--cores` arg, or skip if not provided) |
| `memory` | matches expected (passed as `--memory` arg, or skip if not provided) |

Note: `template = 1` is NOT checked here because Packer marks the VM as template AFTER all provisioners complete. The template flag is verified separately by the `packer-destroy-all.sh` script which already queries template status.

Exits 0 if all pass. Exits 1 with specific assertion failure messages. Dependencies: `curl`, `jq`.

#### 3.2 Packer Template Updates

Add `shell-local` post-processor (not provisioner) to each `.pkr.hcl`. Using `post-processor` ensures it runs AFTER the VM is converted to a template:

```hcl
build {
  sources = ["source.proxmox-clone.<os>"]

  post-processor "shell-local" {
    environment_vars = [
      "PROXMOX_TOKEN_ID=${var.proxmox_token_id}",
      "PROXMOX_TOKEN=${var.proxmox_token}"
    ]
    inline = [
      "bash ${path.root}/../../scripts/verify-packer-template.sh --api-url '${var.proxmox_api_url}' --node '${var.proxmox_node}' --vmid '${var.vm_id}' --cores '${var.cpu_cores}' --memory '${var.memory_mb}' ${var.proxmox_tls_insecure ? \"--tls-insecure\" : \"\"}"
    ]
  }
}
```

Credentials passed via `environment_vars` (Packer masks sensitive values in logs). The `post-processor` runs after template conversion, so `template=1` could be checked if we add it back later.

### Files Modified

| File | Change |
|------|--------|
| `scripts/verify-packer-template.sh` | New file (~120 lines) |
| `packer/ubuntu-noble/ubuntu-noble.pkr.hcl` | Add shell-local post-processor to build block |
| `packer/oracle8/oracle8.pkr.hcl` | Add shell-local post-processor to build block |
| `packer/oracle9/oracle9.pkr.hcl` | Add shell-local post-processor to build block |

---

## Spec 4: Test Infrastructure

### Problem

Zero automated tests exist anywhere in the repository. No `.tftest.hcl`, no `.bats`, no pytest. Bugs like the check-tools.sh octal issue went undetected.

### Changes

#### 4.1 Directory Structure

```
terraform-proxmox/
  tests/
    terraform/
      setup/
        main.tftest.hcl          # Provider mocks for vault + proxmox
      vmid_validation.tftest.hcl
      ip_parsing.tftest.hcl
      os_profile.tftest.hcl
      inventory.tftest.hcl
    scripts/
      read_tfvar.bats
      check_tools_version.bats
      verify_packer_template.bats
    fixtures/
      sample.tfvars
      sample-proxmox-config.json
  scripts/
    lib/
      version-utils.sh           # Extracted from check-tools.sh
```

#### 4.2 Provider Mocking Strategy

The root module uses `ephemeral "vault_kv_secret_v2"` and the `proxmox` provider with Vault-injected credentials. Tests cannot run against real infrastructure.

**Solution:** Create `tests/terraform/setup/main.tftest.hcl` with `mock_provider` blocks:

```hcl
mock_provider "vault" {}

mock_provider "proxmox" {
  mock_resource "proxmox_vm_qemu" {
    defaults = {
      vmid      = 10000
      name      = "test-vm"
      ipconfig0 = "ip=203.0.113.0/24,gw=198.51.100.90"
    }
  }
}
```

This stubs both providers so `terraform test` can run plan/apply without real Vault or Proxmox.

#### 4.3 Terraform Native Tests (`.tftest.hcl`)

Run via `terraform test`. All tests use mock providers.

**`vmid_validation.tftest.hcl`:**
- Duplicate VMIDs across groups → `command = plan`, `expect_failures = [var.node_groups]`
- VMID below 100 → `command = plan`, `expect_failures = [var.node_groups]`
- VMID at 999999990 (template range) → `command = plan`, `expect_failures = [var.node_groups]`
- Valid unique VMIDs in range → `command = plan`, expect success

**`ip_parsing.tftest.hcl`:**
- Standard `ip=192.0.2.0/24,gw=198.51.100.90` → parsed to `198.51.100.90`
- DHCP → returns raw string `dhcp`
- Malformed string → returns raw string
- (Requires test output block exposing `local.vm_parsed_host_ips`)

**`os_profile.tftest.hcl`:**
- VM with explicit `os_profile = "oracle9"` → oracle9
- Group `database19c` with no explicit profile → oracle8 (from group_os_profile map)
- Group `weblogic14` with no map entry → oracle9 (regex inference)
- Unknown group → default_os_profile (ubuntu2404)
- (Requires test output block exposing `local.vm_os_profile` — pure locals chain, no proxmox dependency)

**`inventory.tftest.hcl`:**
- Generated inventory has `[all_nodes]` section
- Per-group sections match node_groups keys
- Per-VM line includes vmid, cores, os_family metadata
- (Uses mocked proxmox provider for module.proxmox_vms outputs)

#### 4.4 Extracted Version Utilities

Sourcing `check-tools.sh` in bats triggers side effects (`set -euo pipefail`, tool validation, `.env` reading). Extract pure functions into `scripts/lib/version-utils.sh`:

```bash
#!/usr/bin/env bash
# Pure utility functions for version comparison. No side effects.

ver_to_int() {
  local ver="$1"
  local major minor patch
  IFS='.' read -r major minor patch <<< "${ver}"
  printf '%03d%03d%03d\n' "${major:-0}" "${minor:-0}" "${patch:-0}"
}

extract_semver() {
  # Extract first x.y.z from input
  sed -n 's/.*\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p' | head -n 1
}
```

`check-tools.sh` sources this lib at the top instead of defining the functions inline. Bats tests source only the lib.

#### 4.5 Bash Tests (`.bats`)

Run via `bats tests/scripts/`. Requires [bats-core](https://github.com/bats-core/bats-core).

**`read_tfvar.bats`:**
- Simple `key = "value"` extraction → outputs `value`
- Quoted values with spaces → correct extraction
- Line with `//` comment after value → comment stripped
- Line with `/* */` comment → comment stripped
- Missing key → exit 1
- Missing file → exit 1
- Uses `tests/fixtures/sample.tfvars` as input

**`check_tools_version.bats`:**
- Sources `scripts/lib/version-utils.sh` (no side effects)
- Version 1.14.8 vs required 1.10.0 → passes (confirmed octal bug regression test)
- Version 1.0.0 vs required 1.10.0 → fails
- Version 1.10.0 vs required 1.10.0 → passes (exact match)
- Version 0.9.9 vs required 1.0.0 → fails

**`verify_packer_template.bats`:**
- Mocks `curl` to return `tests/fixtures/sample-proxmox-config.json`
- Valid API response (all properties correct) → exit 0
- Missing cloud-init disk → exit 1 with message
- Wrong bios type → exit 1 with message

#### 4.6 Makefile Targets

Add to `terraform-proxmox/Makefile`:

```makefile
test-terraform:    ## Run Terraform native tests
	cd $(MAKEFILE_DIR) && terraform test

test-scripts:      ## Run bash script tests (requires bats-core)
	@command -v bats >/dev/null 2>&1 || { echo "Error: bats-core not found. Install: apt-get install bats or npm i -g bats"; exit 1; }
	bats $(MAKEFILE_DIR)/tests/scripts/

test:              ## Run all tests
	$(MAKE) test-terraform
	$(MAKE) test-scripts
```

#### 4.7 .gitignore Update

Add exception for test fixtures (current `.gitignore` excludes `*.tfvars`):

```gitignore
!tests/fixtures/*.tfvars
```

#### 4.8 Test Output Blocks

Add to root module for test observability (gated behind a variable or always present — lightweight):

```hcl
output "test_vm_os_profiles" {
  description = "OS profile resolution map (for testing)."
  value       = local.vm_os_profile
}

output "test_parsed_host_ips" {
  description = "Parsed host IPs with fallback (for testing)."
  value       = local.vm_parsed_host_ips
}
```

### Files Created

| File | Purpose | Lines (est.) |
|------|---------|-------------|
| `tests/terraform/setup/main.tftest.hcl` | Provider mock configuration | ~20 |
| `tests/terraform/vmid_validation.tftest.hcl` | VMID uniqueness + range tests | ~60 |
| `tests/terraform/ip_parsing.tftest.hcl` | IP parsing fallback tests | ~40 |
| `tests/terraform/os_profile.tftest.hcl` | OS profile resolution tests | ~50 |
| `tests/terraform/inventory.tftest.hcl` | Inventory generation tests | ~50 |
| `tests/scripts/read_tfvar.bats` | tfvars parser tests | ~50 |
| `tests/scripts/check_tools_version.bats` | Version comparison regression tests | ~30 |
| `tests/scripts/verify_packer_template.bats` | Template validation assertion tests | ~40 |
| `tests/fixtures/sample.tfvars` | Test fixture for tfvars parsing | ~20 |
| `tests/fixtures/sample-proxmox-config.json` | Mock Proxmox API response | ~30 |
| `scripts/lib/version-utils.sh` | Extracted ver_to_int + extract_semver | ~20 |

### Files Modified

| File | Change |
|------|--------|
| `Makefile` | Add `test-terraform`, `test-scripts`, `test` targets + `.PHONY` |
| `scripts/check-tools.sh` | Source `lib/version-utils.sh` instead of defining functions inline |
| `outputs.tf` | Add 2 test output blocks |
| `.gitignore` | Add `!tests/fixtures/*.tfvars` exception |

---

## Implementation Order

1. **Spec 1** → 2. **Spec 2** → 3. **Spec 3** → 4. **Spec 4**

Sequential to avoid merge conflicts (Specs 1-3 all touch `main.tf` and/or `Makefile`). Spec 4 must come last since it tests code from Specs 1-3.

## Success Criteria

- `terraform plan` rejects duplicate VMIDs and out-of-range VMIDs
- `terraform plan` succeeds with `ipconfig0 = "dhcp"` without crashing outputs or inventory generation
- Deployment summary JSON contains no hard-coded version strings
- `scripts/read-tfvar.sh` extracts values correctly and is used by all 7 consumer sites (5 Makefile + 2 scripts)
- `check-tools.sh` correctly reports Terraform 1.14.8 as passing (octal bug fixed)
- `upload-snippets.sh` reports file count verification after upload and exits non-zero on mismatch
- Packer builds validate template properties via Proxmox API after template conversion
- Packer validation script receives credentials via environment variables (not command-line args)
- `make test` runs all Terraform and bash tests with zero failures
- `make test-scripts` checks for bats-core before running
- Test fixtures are tracked in git (`.gitignore` exception)

## Follow-up Tasks (out of scope)

- Update CLAUDE.md with testing section (`make test`, `make test-terraform`, `make test-scripts`) and new scripts (`read-tfvar.sh`, `verify-packer-template.sh`, `lib/version-utils.sh`)
- Update `docs/project_overview/` scripts references
- Consider adding CI workflow for tests (GitHub Actions)
