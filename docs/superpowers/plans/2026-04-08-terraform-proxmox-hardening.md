# Terraform-Proxmox Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden terraform-proxmox with VMID validation, safe IP parsing, deduplicated tfvars parsing, Packer template verification, and a test suite.

**Architecture:** 4 sequential specs. Spec 1 adds Terraform validation blocks and safe IP parsing. Spec 2 extracts a shared tfvars parser, fixes the check-tools.sh octal bug, and adds upload verification. Spec 3 adds Packer post-build API validation. Spec 4 creates `.tftest.hcl` and `.bats` test infrastructure covering all new code.

**Tech Stack:** Terraform >=1.10.0 (HCL, tftest), Bash (bats-core), Packer (shell-local post-processor), curl+jq (Proxmox API), GNU Make

**Spec:** `docs/superpowers/specs/2026-04-08-terraform-proxmox-hardening-design.md`

---

## File Map

### New Files
| File | Spec | Responsibility |
|------|------|---------------|
| `scripts/read-tfvar.sh` | 2 | Canonical tfvars key-value parser |
| `scripts/lib/version-utils.sh` | 4 | Extracted `ver_to_int` + `extract_semver` (no side effects) |
| `scripts/verify-packer-template.sh` | 3 | Post-build Proxmox API validation |
| `tests/terraform/vmid_validation.tftest.hcl` | 4 | VMID uniqueness + range tests |
| `tests/terraform/ip_parsing.tftest.hcl` | 4 | IP parsing fallback tests |
| `tests/terraform/os_profile.tftest.hcl` | 4 | OS profile resolution tests |
| `tests/terraform/inventory.tftest.hcl` | 4 | Inventory generation tests |
| `tests/scripts/read_tfvar.bats` | 4 | tfvars parser tests |
| `tests/scripts/check_tools_version.bats` | 4 | Version comparison regression |
| `tests/scripts/verify_packer_template.bats` | 4 | Template validation assertion tests |
| `tests/fixtures/sample.tfvars` | 4 | Test fixture |
| `tests/fixtures/sample-proxmox-config.json` | 4 | Mock Proxmox API response |

### Modified Files
| File | Spec(s) | What Changes |
|------|---------|-------------|
| `variables.tf` | 1 | +2 validation blocks after line 320 |
| `main.tf` | 1 | +`vm_parsed_host_ips` local at ~158, fix IP at line 191, simplify deployment_info at 389-394 |
| `outputs.tf` | 1, 4 | Safe IP parsing at lines 53/109/115, +2 test outputs |
| `Makefile` | 2, 4 | Replace 5 awk calls with read-tfvar.sh, +3 test targets |
| `scripts/rotate-proxmox-creds.sh` | 2 | Remove `read_tfvars_value()`, call read-tfvar.sh |
| `scripts/vault-bootstrap.sh` | 2 | Replace `read_tfvars_value()` calls with read-tfvar.sh |
| `scripts/check-tools.sh` | 2, 4 | Octal fix at line 145, source lib/version-utils.sh |
| `scripts/upload-snippets.sh` | 2 | +post-upload verification block |
| `packer/ubuntu-noble/ubuntu-noble.pkr.hcl` | 3 | +shell-local post-processor |
| `packer/oracle8/oracle8.pkr.hcl` | 3 | +shell-local post-processor |
| `packer/oracle9/oracle9.pkr.hcl` | 3 | +shell-local post-processor |
| `.gitignore` | 4 | +`!tests/fixtures/*.tfvars` exception |

---

## Task 1: VMID Validation Blocks (Spec 1.1 + 1.2)

**Files:**
- Modify: `terraform-proxmox/variables.tf:320` (insert after this line)

- [ ] **Step 1: Add VMID uniqueness + range validation blocks**

In `variables.tf`, after line 320 (the closing `}` of the last existing validation block in `node_groups`), before line 321 (`}`), insert:

```hcl
  validation {
    condition = length(flatten([
      for _, group in var.node_groups : [for _, vm in group : vm.vmid]
    ])) == length(distinct(flatten([
      for _, group in var.node_groups : [for _, vm in group : vm.vmid]
    ])))
    error_message = "Duplicate VMIDs detected across node_groups. Each VM must have a unique vmid."
  }
  validation {
    condition = alltrue(flatten([
      for _, group in var.node_groups : [
        for _, vm in group : vm.vmid >= 100 && vm.vmid <= 999999989
      ]
    ]))
    error_message = "node_groups.*.*.vmid must be between 100 and 999999989. Range 999999990-999999995 is reserved for Packer base VMs and templates."
  }
```

- [ ] **Step 2: Validate syntax**

Run: `cd terraform-proxmox && terraform validate`
Expected: Success (dev.tfvars VMIDs 10000-10008 are valid and unique)

- [ ] **Step 3: Commit**

```bash
cd /home/kirui/IaC-Homelab
git add terraform-proxmox/variables.tf
git commit -m "feat: add VMID uniqueness and range validation to node_groups"
```

---

## Task 2: Safe IP Parsing (Spec 1.3)

**Files:**
- Modify: `terraform-proxmox/main.tf:157` (insert after), `terraform-proxmox/main.tf:191`, `terraform-proxmox/outputs.tf:51-54,109,115`

- [ ] **Step 1: Add `vm_parsed_host_ips` local in main.tf**

After line 157 (`sorted_vm_names = sort(keys(local.vm_name_to_id))`), insert:

```hcl

  // Safe IP parsing with fallback for DHCP or malformed ipconfig0
  vm_parsed_host_ips = {
    for name in local.sorted_vm_names :
    name => try(
      split("/", split("=", split(",", local.vm_name_to_ip[name])[0])[1])[0],
      local.vm_name_to_ip[name]
    )
  }
```

- [ ] **Step 2: Fix inventory IP parsing at main.tf:191**

Replace line 191:
```hcl
        split("/", split("=", split(",", local.flattened_vms[vm_key].config.ipconfig0)[0])[1])[0],
```

With:
```hcl
        try(split("/", split("=", split(",", local.flattened_vms[vm_key].config.ipconfig0)[0])[1])[0], "UNPARSED"),
```

- [ ] **Step 3: Fix `all_vm_host_ips` in outputs.tf:51-54**

Replace lines 51-54:
```hcl
  value = [
    for name in local.sorted_vm_names :
    split("/", split("=", split(",", local.vm_name_to_ip[name])[0])[1])[0]
  ]
```

With:
```hcl
  value = [
    for name in local.sorted_vm_names :
    local.vm_parsed_host_ips[name]
  ]
```

- [ ] **Step 4: Fix `connection_info.group_ips` in outputs.tf:109**

Replace line 109:
```hcl
        for vm in local.flattened_vms : split("=", split(",", vm.config.ipconfig0)[0])[1] if vm.group == group
```

With:
```hcl
        for vm in local.flattened_vms : try(split("=", split(",", vm.config.ipconfig0)[0])[1], vm.config.ipconfig0) if vm.group == group
```

- [ ] **Step 5: Fix `connection_info.group_host_ips` in outputs.tf:115**

Replace line 115:
```hcl
        for vm in local.flattened_vms : split("/", split("=", split(",", vm.config.ipconfig0)[0])[1])[0] if vm.group == group
```

With:
```hcl
        for vm in local.flattened_vms : try(split("/", split("=", split(",", vm.config.ipconfig0)[0])[1])[0], vm.config.ipconfig0) if vm.group == group
```

- [ ] **Step 6: Validate syntax**

Run: `cd terraform-proxmox && terraform validate`
Expected: Success

- [ ] **Step 7: Commit**

```bash
git add terraform-proxmox/main.tf terraform-proxmox/outputs.tf
git commit -m "fix: safe IP parsing with try() fallback for DHCP/malformed ipconfig0"
```

---

## Task 3: Remove Hard-coded Versions (Spec 1.4)

**Files:**
- Modify: `terraform-proxmox/main.tf:389-394`

- [ ] **Step 1: Simplify deployment_info**

Replace lines 389-394:
```hcl
    deployment_info = merge({
      terraform_version = ">=1.0.0"
      provider_version  = "3.0.2-rc07"
      }, local.creation_timestamp != "" ? {
      timestamp = local.creation_timestamp
    } : {})
```

With:
```hcl
    deployment_info = local.creation_timestamp != "" ? {
      timestamp = local.creation_timestamp
    } : {}
```

- [ ] **Step 2: Validate syntax**

Run: `cd terraform-proxmox && terraform validate`
Expected: Success

- [ ] **Step 3: Commit**

```bash
git add terraform-proxmox/main.tf
git commit -m "fix: remove hard-coded version strings from deployment summary"
```

---

## Task 4: Create `read-tfvar.sh` (Spec 2.1)

**Files:**
- Create: `terraform-proxmox/scripts/read-tfvar.sh`

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
# Canonical tfvars key-value parser.
# Usage: read-tfvar.sh <key> <file>
# Outputs: lowercase, trimmed, unquoted value to stdout
# Exit 1 if key not found or file missing.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: read-tfvar.sh <key> <file>" >&2
  exit 1
fi

KEY="$1"
FILE="$2"

if [[ ! -f "${FILE}" ]]; then
  echo "Error: file not found: ${FILE}" >&2
  exit 1
fi

value="$(awk -F= -v k="${KEY}" '
  $1 ~ "^[[:space:]]*" k "[[:space:]]*$" {
    val = $2
    sub(/[[:space:]]*(\/\/|#).*/, "", val)
    sub(/[[:space:]]*\/\*.*\*\/[[:space:]]*$/, "", val)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
    sub(/^"/, "", val)
    sub(/"$/, "", val)
    print tolower(val)
    exit
  }
' "${FILE}")"

if [[ -z "${value}" ]]; then
  exit 1
fi

printf '%s\n' "${value}"
```

- [ ] **Step 2: Make executable**

Run: `chmod +x terraform-proxmox/scripts/read-tfvar.sh`

- [ ] **Step 3: Smoke test**

Run: `cd terraform-proxmox && scripts/read-tfvar.sh vault_kv_mount_path environments/dev.tfvars`
Expected: `secret`

Run: `scripts/read-tfvar.sh snippet_storage environments/dev.tfvars`
Expected: `local`

Run: `scripts/read-tfvar.sh nonexistent_key environments/dev.tfvars; echo "exit: $?"`
Expected: `exit: 1`

- [ ] **Step 4: Commit**

```bash
git add terraform-proxmox/scripts/read-tfvar.sh
git commit -m "feat: add canonical read-tfvar.sh for deduplicated tfvars parsing"
```

---

## Task 5: Replace Makefile Inline Awk (Spec 2.1)

**Files:**
- Modify: `terraform-proxmox/Makefile:52-53,63,693-694`

- [ ] **Step 1: Replace lines 52-53 (VAULT_KV_MOUNT_PATH, VAULT_SECRET_PREFIX)**

Replace line 52:
```makefile
VAULT_KV_MOUNT_PATH_FOR_ENV = $(if $(VAULT_KV_MOUNT_PATH),$(VAULT_KV_MOUNT_PATH),$(shell awk -F= '/^[[:space:]]*vault_kv_mount_path[[:space:]]*=/{val=$$2; sub(/[[:space:]]*(\/\/|#).*$$/,"",val); sub(/[[:space:]]*\/\*.*\*\/[[:space:]]*$$/,"",val); gsub(/^[[:space:]]+|[[:space:]]+$$/,"",val); sub(/^"/,"",val); sub(/"$$/,"",val); print val; exit}' "$(TFVARS_FILE_FOR_ENV)" 2>/dev/null || true))
```

With:
```makefile
VAULT_KV_MOUNT_PATH_FOR_ENV = $(if $(VAULT_KV_MOUNT_PATH),$(VAULT_KV_MOUNT_PATH),$(shell "$(MAKEFILE_DIR)/scripts/read-tfvar.sh" vault_kv_mount_path "$(TFVARS_FILE_FOR_ENV)" 2>/dev/null || true))
```

Replace line 53 similarly for `vault_secret_prefix`.

Replace line 63 similarly for `snippet_storage`.

- [ ] **Step 2: Replace lines 693-694 (vault_auth_mode, manage_vault_access)**

These are inside the `plan` target recipe. Replace line 693:
```makefile
			VAULT_AUTH_MODE="$$(awk -F= '/^[[:space:]]*vault_auth_mode[[:space:]]*=/{gsub(/[[:space:]]|"/, "", $$2); print tolower($$2); exit}' "$$TFVARS_FILE")"; \
```

With:
```makefile
			VAULT_AUTH_MODE="$$("$(MAKEFILE_DIR)/scripts/read-tfvar.sh" vault_auth_mode "$$TFVARS_FILE" 2>/dev/null || true)"; \
```

Replace line 694 similarly for `manage_vault_access`.

- [ ] **Step 3: Verify Makefile parses**

Run: `cd terraform-proxmox && make help 2>&1 | head -5`
Expected: Help text prints without errors

- [ ] **Step 4: Commit**

```bash
git add terraform-proxmox/Makefile
git commit -m "refactor: replace inline awk tfvars parsing with read-tfvar.sh"
```

---

## Task 6: Update Script Consumers (Spec 2.1)

**Files:**
- Modify: `terraform-proxmox/scripts/rotate-proxmox-creds.sh:84-101,190,193-194`
- Modify: `terraform-proxmox/scripts/vault-bootstrap.sh:84-101,265,268,278`

- [ ] **Step 1: Update rotate-proxmox-creds.sh**

Remove the `read_tfvars_value()` function (lines 84-101). Replace call sites at lines 190 and 193-194:

```bash
# Before (line 190):
    VAULT_KV_MOUNT_PATH="$(read_tfvars_value "vault_kv_mount_path" "${TFVARS_FILE}" || true)"
# After:
    VAULT_KV_MOUNT_PATH="$("${SCRIPT_DIR}/read-tfvar.sh" "vault_kv_mount_path" "${TFVARS_FILE}" 2>/dev/null || true)"
```

Same pattern for `vault_secret_prefix` at line 193-194.

- [ ] **Step 2: Update vault-bootstrap.sh**

Remove its `read_tfvars_value()` function (lines 84-101). Replace call sites at lines 265, 268, 278:

```bash
# Before (line 265):
  VAULT_KV_MOUNT_PATH="$(read_tfvars_value "vault_kv_mount_path" "${TFVARS_FILE}" || true)"
# After:
  VAULT_KV_MOUNT_PATH="$("${SCRIPT_DIR}/read-tfvar.sh" "vault_kv_mount_path" "${TFVARS_FILE}" 2>/dev/null || true)"
```

Same pattern for lines 268 and 278.

- [ ] **Step 3: Verify scripts are syntactically valid**

Run: `bash -n terraform-proxmox/scripts/rotate-proxmox-creds.sh && echo OK`
Expected: `OK`

Run: `bash -n terraform-proxmox/scripts/vault-bootstrap.sh && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add terraform-proxmox/scripts/rotate-proxmox-creds.sh terraform-proxmox/scripts/vault-bootstrap.sh
git commit -m "refactor: use shared read-tfvar.sh in rotate-proxmox-creds and vault-bootstrap"
```

---

## Task 7: Fix check-tools.sh Octal Bug (Spec 2.2)

**Files:**
- Modify: `terraform-proxmox/scripts/check-tools.sh:145`

- [ ] **Step 1: Add 10# prefix**

Replace line 145:
```bash
    if [[ "$(ver_to_int "${tf_version}")" -ge "$(ver_to_int "${MIN_TERRAFORM_VERSION}")" ]]; then
```

With:
```bash
    if [[ "10#$(ver_to_int "${tf_version}")" -ge "10#$(ver_to_int "${MIN_TERRAFORM_VERSION}")" ]]; then
```

- [ ] **Step 2: Quick manual verify**

Run: `cd terraform-proxmox && bash scripts/check-tools.sh 2>&1 | grep -i terraform`
Expected: Line showing "Terraform version X.Y.Z satisfies minimum" (no octal error)

- [ ] **Step 3: Commit**

```bash
git add terraform-proxmox/scripts/check-tools.sh
git commit -m "fix: check-tools.sh octal parsing bug in version comparison"
```

---

## Task 8: upload-snippets.sh Verification (Spec 2.3)

**Files:**
- Modify: `terraform-proxmox/scripts/upload-snippets.sh:139-141`

- [ ] **Step 1: Add post-upload verification block**

Replace lines 139-141:
```bash
done

echo "Snippets upload complete."
```

With:
```bash
done

# Post-upload verification: confirm file counts match
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
echo "Snippets upload complete."
```

- [ ] **Step 2: Validate syntax**

Run: `bash -n terraform-proxmox/scripts/upload-snippets.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add terraform-proxmox/scripts/upload-snippets.sh
git commit -m "feat: add post-upload verification to upload-snippets.sh"
```

---

## Task 9: Create verify-packer-template.sh (Spec 3.1)

**Files:**
- Create: `terraform-proxmox/scripts/verify-packer-template.sh`

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
# Validate Packer template VM config via Proxmox API.
# Reads PROXMOX_TOKEN_ID and PROXMOX_TOKEN from environment.
# Usage: verify-packer-template.sh --api-url <url> --node <node> --vmid <vmid> [options]
set -euo pipefail

API_URL="" NODE="" VMID="" TLS_INSECURE="false" CORES="" MEMORY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-url)    API_URL="$2"; shift 2 ;;
    --node)       NODE="$2"; shift 2 ;;
    --vmid)       VMID="$2"; shift 2 ;;
    --cores)      CORES="$2"; shift 2 ;;
    --memory)     MEMORY="$2"; shift 2 ;;
    --tls-insecure) TLS_INSECURE="true"; shift ;;
    -h|--help)    echo "Usage: $0 --api-url <url> --node <node> --vmid <vmid> [--cores N] [--memory N] [--tls-insecure]"; exit 0 ;;
    *)            echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

for var in API_URL NODE VMID; do
  if [[ -z "${!var}" ]]; then
    echo "Error: --$(echo "$var" | tr '[:upper:]' '[:lower:]' | tr '_' '-') is required" >&2
    exit 1
  fi
done

if [[ -z "${PROXMOX_TOKEN_ID:-}" || -z "${PROXMOX_TOKEN:-}" ]]; then
  echo "Error: PROXMOX_TOKEN_ID and PROXMOX_TOKEN environment variables are required" >&2
  exit 1
fi

for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: $cmd" >&2
    exit 1
  fi
done

CURL_OPTS=(-s -f)
if [[ "${TLS_INSECURE}" == "true" ]]; then
  CURL_OPTS+=(-k)
fi

CONFIG_JSON="$(curl "${CURL_OPTS[@]}" \
  -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN}" \
  "${API_URL}/nodes/${NODE}/qemu/${VMID}/config" 2>&1)" || {
  echo "Error: Failed to query Proxmox API for VMID ${VMID} on node ${NODE}" >&2
  echo "${CONFIG_JSON}" >&2
  exit 1
}

DATA="$(echo "${CONFIG_JSON}" | jq -r '.data')"
FAILURES=0

assert_eq() {
  local field="$1" expected="$2"
  local actual
  actual="$(echo "${DATA}" | jq -r ".${field} // empty")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "FAIL: ${field} = '${actual}', expected '${expected}'" >&2
    FAILURES=$((FAILURES + 1))
  else
    echo "  OK: ${field} = '${actual}'"
  fi
}

assert_contains() {
  local field="$1" substring="$2"
  local actual
  actual="$(echo "${DATA}" | jq -r ".${field} // empty")"
  if [[ "${actual}" != *"${substring}"* ]]; then
    echo "FAIL: ${field} = '${actual}', expected to contain '${substring}'" >&2
    FAILURES=$((FAILURES + 1))
  else
    echo "  OK: ${field} contains '${substring}'"
  fi
}

assert_exists() {
  local field="$1"
  local actual
  actual="$(echo "${DATA}" | jq -r ".${field} // empty")"
  if [[ -z "${actual}" ]]; then
    echo "FAIL: ${field} is missing or empty" >&2
    FAILURES=$((FAILURES + 1))
  else
    echo "  OK: ${field} exists"
  fi
}

echo "Validating Packer template VMID=${VMID} on ${NODE}..."

assert_eq "bios" "ovmf"
assert_eq "scsihw" "virtio-scsi-single"
assert_contains "agent" "1"
assert_eq "serial0" "socket"
assert_eq "machine" "q35"
assert_exists "scsi0"

# Check cloud-init disk on scsi1 or ide2
ci_scsi1="$(echo "${DATA}" | jq -r '.scsi1 // empty')"
ci_ide2="$(echo "${DATA}" | jq -r '.ide2 // empty')"
if [[ "${ci_scsi1}" == *"cloudinit"* || "${ci_ide2}" == *"cloudinit"* ]]; then
  echo "  OK: cloud-init disk found"
else
  echo "FAIL: no cloud-init disk found on scsi1 or ide2" >&2
  FAILURES=$((FAILURES + 1))
fi

if [[ -n "${CORES}" ]]; then
  assert_eq "cores" "${CORES}"
fi
if [[ -n "${MEMORY}" ]]; then
  assert_eq "memory" "${MEMORY}"
fi

if [[ ${FAILURES} -gt 0 ]]; then
  echo "Template validation FAILED: ${FAILURES} assertion(s) failed." >&2
  exit 1
fi
echo "Template validation PASSED."
```

- [ ] **Step 2: Make executable**

Run: `chmod +x terraform-proxmox/scripts/verify-packer-template.sh`

- [ ] **Step 3: Commit**

```bash
git add terraform-proxmox/scripts/verify-packer-template.sh
git commit -m "feat: add verify-packer-template.sh for post-build Proxmox API validation"
```

---

## Task 10: Add Post-Processor to Packer Templates (Spec 3.2)

**Files:**
- Modify: `terraform-proxmox/packer/ubuntu-noble/ubuntu-noble.pkr.hcl:99-101`
- Modify: `terraform-proxmox/packer/oracle8/oracle8.pkr.hcl:99-101`
- Modify: `terraform-proxmox/packer/oracle9/oracle9.pkr.hcl:99-101`

- [ ] **Step 1: Update ubuntu-noble build block**

Replace lines 99-101:
```hcl
build {
  sources = ["source.proxmox-clone.ubuntu_noble"]
}
```

With:
```hcl
build {
  sources = ["source.proxmox-clone.ubuntu_noble"]

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

- [ ] **Step 2: Update oracle8 build block**

Same replacement in `packer/oracle8/oracle8.pkr.hcl`, changing `ubuntu_noble` to `oracle8` in the sources line.

- [ ] **Step 3: Update oracle9 build block**

Same replacement in `packer/oracle9/oracle9.pkr.hcl`, changing to `oracle9` in the sources line.

- [ ] **Step 4: Validate Packer syntax**

Run: `cd terraform-proxmox/packer/ubuntu-noble && packer validate -syntax-only ubuntu-noble.pkr.hcl; cd ../..`
Expected: No syntax errors (validation may warn about missing vars, that's OK)

- [ ] **Step 5: Commit**

```bash
git add terraform-proxmox/packer/
git commit -m "feat: add post-build API validation to all Packer templates"
```

---

## Task 11: Extract Version Utilities (Spec 4.4)

**Files:**
- Create: `terraform-proxmox/scripts/lib/version-utils.sh`
- Modify: `terraform-proxmox/scripts/check-tools.sh:87-99`

- [ ] **Step 1: Create lib directory and version-utils.sh**

```bash
#!/usr/bin/env bash
# Pure utility functions for version comparison. No side effects.
# Sourced by check-tools.sh and bats tests.

ver_to_int() {
  local ver="$1"
  local major minor patch
  IFS='.' read -r major minor patch <<< "${ver}"
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"
  printf '%03d%03d%03d\n' "${major}" "${minor}" "${patch}"
}

extract_semver() {
  # Extract first x.y.z from input.
  sed -n 's/.*\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p' | head -n 1
}
```

- [ ] **Step 2: Update check-tools.sh to source the lib**

Replace lines 87-99 (the `ver_to_int` and `extract_semver` function definitions) with:

```bash
# Source shared version utilities
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/version-utils.sh"
```

Note: If `SCRIPT_DIR` is already defined earlier in the file, reuse it. Otherwise add this definition.

- [ ] **Step 3: Verify check-tools.sh still works**

Run: `cd terraform-proxmox && bash scripts/check-tools.sh 2>&1 | grep -i terraform`
Expected: Same output as before (version check passes)

- [ ] **Step 4: Commit**

```bash
git add terraform-proxmox/scripts/lib/version-utils.sh terraform-proxmox/scripts/check-tools.sh
git commit -m "refactor: extract version utilities from check-tools.sh into lib/version-utils.sh"
```

---

## Task 12: Test Fixtures + .gitignore (Spec 4.1, 4.7)

**Files:**
- Create: `terraform-proxmox/tests/fixtures/sample.tfvars`
- Create: `terraform-proxmox/tests/fixtures/sample-proxmox-config.json`
- Modify: `terraform-proxmox/.gitignore`

- [ ] **Step 1: Create sample.tfvars fixture**

```hcl
// Test fixture for read-tfvar.sh
vault_kv_mount_path = "secret"
vault_secret_prefix = "terraform"
snippet_storage     = "local"
vault_auth_mode     = "token"
manage_vault_access = true

// Value with inline comment
target_node = "proxmox" // production node

// Value with block comment
storage_pool = "local-lvm" /* default pool */

// Quoted value with spaces (edge case)
cluster_name = "my test cluster"
```

- [ ] **Step 2: Create sample-proxmox-config.json fixture**

```json
{
  "data": {
    "bios": "ovmf",
    "scsihw": "virtio-scsi-single",
    "agent": "1",
    "serial0": "socket",
    "machine": "q35",
    "scsi0": "local-lvm:vm-999999995-disk-0,discard=on,iothread=1,size=50G,ssd=1",
    "scsi1": "local-lvm:vm-999999995-cloudinit,media=cdrom,size=4M",
    "cores": 8,
    "memory": 10240,
    "name": "ubuntu2404-template",
    "template": 1,
    "boot": "order=scsi0",
    "cpu": "host",
    "net0": "virtio=AA:BB:CC:DD:EE:FF,bridge=vmbr0"
  }
}
```

- [ ] **Step 3: Update .gitignore**

After line 8 (`!environments/dev.tfvars`), add:

```gitignore
!tests/fixtures/*.tfvars
```

- [ ] **Step 4: Verify fixtures are tracked**

Run: `cd terraform-proxmox && git add tests/fixtures/sample.tfvars && git status tests/`
Expected: `sample.tfvars` shows as staged (not ignored)

- [ ] **Step 5: Commit**

```bash
git add terraform-proxmox/tests/ terraform-proxmox/.gitignore
git commit -m "feat: add test fixtures and .gitignore exception for test tfvars"
```

---

## Task 13: Bats Tests (Spec 4.5)

**Files:**
- Create: `terraform-proxmox/tests/scripts/read_tfvar.bats`
- Create: `terraform-proxmox/tests/scripts/check_tools_version.bats`
- Create: `terraform-proxmox/tests/scripts/verify_packer_template.bats`

- [ ] **Step 1: Create read_tfvar.bats**

```bash
#!/usr/bin/env bats

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
READ_TFVAR="${SCRIPT_DIR}/scripts/read-tfvar.sh"
FIXTURE="${SCRIPT_DIR}/tests/fixtures/sample.tfvars"

@test "extracts simple quoted value" {
  run "$READ_TFVAR" vault_kv_mount_path "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$output" = "secret" ]
}

@test "extracts boolean value as lowercase" {
  run "$READ_TFVAR" manage_vault_access "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "strips inline // comment" {
  run "$READ_TFVAR" target_node "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$output" = "proxmox" ]
}

@test "strips block /* */ comment" {
  run "$READ_TFVAR" storage_pool "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$output" = "local-lvm" ]
}

@test "extracts quoted value with spaces" {
  run "$READ_TFVAR" cluster_name "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$output" = "my test cluster" ]
}

@test "exits 1 for missing key" {
  run "$READ_TFVAR" nonexistent_key "$FIXTURE"
  [ "$status" -eq 1 ]
}

@test "exits 1 for missing file" {
  run "$READ_TFVAR" vault_kv_mount_path "/tmp/nonexistent.tfvars"
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Create check_tools_version.bats**

```bash
#!/usr/bin/env bats

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
source "${SCRIPT_DIR}/scripts/lib/version-utils.sh"

@test "ver_to_int: 1.14.8 >= 1.10.0 (octal regression)" {
  result_a="$(ver_to_int "1.14.8")"
  result_b="$(ver_to_int "1.10.0")"
  [[ "10#${result_a}" -ge "10#${result_b}" ]]
}

@test "ver_to_int: 1.0.0 < 1.10.0" {
  result_a="$(ver_to_int "1.0.0")"
  result_b="$(ver_to_int "1.10.0")"
  [[ "10#${result_a}" -lt "10#${result_b}" ]]
}

@test "ver_to_int: 1.10.0 == 1.10.0 (exact match)" {
  result_a="$(ver_to_int "1.10.0")"
  result_b="$(ver_to_int "1.10.0")"
  [[ "10#${result_a}" -eq "10#${result_b}" ]]
}

@test "ver_to_int: 0.9.9 < 1.0.0" {
  result_a="$(ver_to_int "0.9.9")"
  result_b="$(ver_to_int "1.0.0")"
  [[ "10#${result_a}" -lt "10#${result_b}" ]]
}

@test "extract_semver: extracts from terraform output" {
  result="$(echo "Terraform v1.14.8 on linux_amd64" | extract_semver)"
  [ "$result" = "1.14.8" ]
}
```

- [ ] **Step 3: Create verify_packer_template.bats**

```bash
#!/usr/bin/env bats

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
VERIFY="${SCRIPT_DIR}/scripts/verify-packer-template.sh"
VALID_FIXTURE="${SCRIPT_DIR}/tests/fixtures/sample-proxmox-config.json"

# Mock curl to return fixture data
mock_curl() {
  cat "$1"
}

setup() {
  export PROXMOX_TOKEN_ID="test@pve!test-token"
  export PROXMOX_TOKEN="fake-token-for-testing"
  # Create a wrapper that replaces curl with our mock
  export MOCK_FIXTURE="${VALID_FIXTURE}"
  export PATH="${BATS_TEST_TMPDIR}:${PATH}"
  cat > "${BATS_TEST_TMPDIR}/curl" <<'MOCK'
#!/bin/bash
cat "${MOCK_FIXTURE}"
MOCK
  chmod +x "${BATS_TEST_TMPDIR}/curl"
}

@test "valid template passes all checks" {
  run "$VERIFY" --api-url "https://fake:8006/api2/json" --node "pve" --vmid "999999995"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASSED"* ]]
}

@test "wrong bios type fails" {
  # Create modified fixture with wrong bios
  local bad_fixture="${BATS_TEST_TMPDIR}/bad-bios.json"
  jq '.data.bios = "seabios"' "$VALID_FIXTURE" > "$bad_fixture"
  export MOCK_FIXTURE="$bad_fixture"
  run "$VERIFY" --api-url "https://fake:8006/api2/json" --node "pve" --vmid "999999995"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: bios"* ]]
}

@test "missing cloud-init disk fails" {
  local bad_fixture="${BATS_TEST_TMPDIR}/no-cloudinit.json"
  jq 'del(.data.scsi1) | del(.data.ide2)' "$VALID_FIXTURE" > "$bad_fixture"
  export MOCK_FIXTURE="$bad_fixture"
  run "$VERIFY" --api-url "https://fake:8006/api2/json" --node "pve" --vmid "999999995"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: no cloud-init disk"* ]]
}

@test "missing required args fails" {
  run "$VERIFY" --api-url "https://fake:8006/api2/json"
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 4: Install bats-core if needed and run tests**

Run: `command -v bats || sudo apt-get install -y bats`
Run: `cd terraform-proxmox && bats tests/scripts/`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add terraform-proxmox/tests/scripts/
git commit -m "feat: add bats tests for read-tfvar, version comparison, and packer validation"
```

---

## Task 14: Terraform Test Infrastructure (Spec 4.2, 4.3, 4.8)

**Files:**
- Create: `terraform-proxmox/tests/terraform/vmid_validation.tftest.hcl`
- Create: `terraform-proxmox/tests/terraform/os_profile.tftest.hcl`
- Modify: `terraform-proxmox/outputs.tf` (add test outputs)

- [ ] **Step 1: Add test output blocks to outputs.tf**

Append at the end of `outputs.tf` (after `workspace_info`):

```hcl

// Test-only outputs for terraform test observability
output "test_vm_os_profiles" {
  description = "OS profile resolution map (for testing)."
  value       = local.vm_os_profile
}

output "test_parsed_host_ips" {
  description = "Parsed host IPs with fallback (for testing)."
  value       = local.vm_parsed_host_ips
}
```

- [ ] **Step 2: Create vmid_validation.tftest.hcl**

```hcl
# Tests for VMID uniqueness and range validation blocks.
# These test that invalid inputs are correctly rejected at plan time.

mock_provider "vault" {}
mock_provider "proxmox" {}

variables {
  vault_address  = "https://127.0.0.1:8200"
  vault_token    = "test-token"
  target_node    = "test-node"
  vm_pool        = "test-pool"
  clone_template = "ubuntu2404"
  storage_pool   = "local-lvm"
  network_bridge = "vmbr0"
  cluster_name   = "test-cluster"
}

run "valid_unique_vmids" {
  command = plan

  variables {
    node_groups = {
      "group1" = {
        "vm1" = {
          vmid = 100, name = "test-vm1", ipconfig0 = "ip=192.0.2.0/24,gw=198.51.100.90"
          cores = 2, memory = 2048, disk_size = "20G"
        }
      }
      "group2" = {
        "vm2" = {
          vmid = 200, name = "test-vm2", ipconfig0 = "ip=198.51.100.0/24,gw=198.51.100.90"
          cores = 2, memory = 2048, disk_size = "20G"
        }
      }
    }
  }
}

run "duplicate_vmids_rejected" {
  command = plan
  expect_failures = [var.node_groups]

  variables {
    node_groups = {
      "group1" = {
        "vm1" = {
          vmid = 100, name = "test-vm1", ipconfig0 = "ip=192.0.2.0/24,gw=198.51.100.90"
          cores = 2, memory = 2048, disk_size = "20G"
        }
      }
      "group2" = {
        "vm2" = {
          vmid = 100, name = "test-vm2", ipconfig0 = "ip=198.51.100.0/24,gw=198.51.100.90"
          cores = 2, memory = 2048, disk_size = "20G"
        }
      }
    }
  }
}

run "vmid_below_100_rejected" {
  command = plan
  expect_failures = [var.node_groups]

  variables {
    node_groups = {
      "group1" = {
        "vm1" = {
          vmid = 99, name = "test-vm1", ipconfig0 = "ip=192.0.2.0/24,gw=198.51.100.90"
          cores = 2, memory = 2048, disk_size = "20G"
        }
      }
    }
  }
}

run "vmid_in_template_range_rejected" {
  command = plan
  expect_failures = [var.node_groups]

  variables {
    node_groups = {
      "group1" = {
        "vm1" = {
          vmid = 999999990, name = "test-vm1", ipconfig0 = "ip=192.0.2.0/24,gw=198.51.100.90"
          cores = 2, memory = 2048, disk_size = "20G"
        }
      }
    }
  }
}
```

- [ ] **Step 3: Create os_profile.tftest.hcl**

```hcl
# Tests for OS profile resolution (4-level fallback chain).

mock_provider "vault" {}
mock_provider "proxmox" {}

variables {
  vault_address  = "https://127.0.0.1:8200"
  vault_token    = "test-token"
  target_node    = "test-node"
  vm_pool        = "test-pool"
  clone_template = "ubuntu2404"
  storage_pool   = "local-lvm"
  network_bridge = "vmbr0"
  cluster_name   = "test-cluster"
}

run "explicit_os_profile_override" {
  command = plan

  variables {
    node_groups = {
      "mygroup" = {
        "vm1" = {
          vmid = 100, name = "test-vm", ipconfig0 = "ip=192.0.2.0/24,gw=198.51.100.90"
          cores = 2, memory = 2048, disk_size = "20G"
          os_profile = "oracle9"
        }
      }
    }
  }

  assert {
    condition     = output.test_vm_os_profiles["mygroup-vm1"] == "oracle9"
    error_message = "Explicit os_profile should override all other resolution methods"
  }
}

run "group_os_profile_map_lookup" {
  command = plan

  variables {
    node_groups = {
      "database19c" = {
        "vm1" = {
          vmid = 100, name = "test-db", ipconfig0 = "ip=192.0.2.0/24,gw=198.51.100.90"
          cores = 2, memory = 2048, disk_size = "20G"
        }
      }
    }
  }

  assert {
    condition     = output.test_vm_os_profiles["database19c-vm1"] == "oracle8"
    error_message = "database19c should resolve to oracle8 via group_os_profile map"
  }
}

run "regex_inference_weblogic14" {
  command = plan

  variables {
    node_groups = {
      "weblogic14" = {
        "vm1" = {
          vmid = 100, name = "test-wl", ipconfig0 = "ip=192.0.2.0/24,gw=198.51.100.90"
          cores = 2, memory = 2048, disk_size = "20G"
        }
      }
    }
  }

  assert {
    condition     = output.test_vm_os_profiles["weblogic14-vm1"] == "oracle9"
    error_message = "weblogic14 should infer oracle9 via regex"
  }
}

run "unknown_group_uses_default" {
  command = plan

  variables {
    node_groups = {
      "customapp" = {
        "vm1" = {
          vmid = 100, name = "test-custom", ipconfig0 = "ip=192.0.2.0/24,gw=198.51.100.90"
          cores = 2, memory = 2048, disk_size = "20G"
        }
      }
    }
  }

  assert {
    condition     = output.test_vm_os_profiles["customapp-vm1"] == "ubuntu2404"
    error_message = "Unknown group should fall back to default_os_profile (ubuntu2404)"
  }
}
```

- [ ] **Step 4: Run terraform tests**

Run: `cd terraform-proxmox && terraform test`
Expected: All test runs pass (valid inputs succeed, invalid inputs fail as expected)

Note: If `mock_provider` doesn't work with ephemeral resources, the tests may need adjustment. Check terraform test output carefully and fix any mock issues.

- [ ] **Step 5: Commit**

```bash
git add terraform-proxmox/outputs.tf terraform-proxmox/tests/terraform/
git commit -m "feat: add terraform native tests for VMID validation and OS profile resolution"
```

---

## Task 15: Makefile Test Targets (Spec 4.6)

**Files:**
- Modify: `terraform-proxmox/Makefile`

- [ ] **Step 1: Add test targets**

Add before the `help` target (or at the end of the targets section). Also add to the `.PHONY` declaration at the top:

```makefile
test-terraform: ## Run Terraform native tests
	@echo "$(CYAN)Running Terraform tests...$(NC)"
	cd $(MAKEFILE_DIR) && terraform test

test-scripts: ## Run bash script tests (requires bats-core)
	@command -v bats >/dev/null 2>&1 || { echo "$(RED)Error: bats-core not found. Install: apt-get install bats$(NC)"; exit 1; }
	@echo "$(CYAN)Running bash script tests...$(NC)"
	bats $(MAKEFILE_DIR)/tests/scripts/

test: test-terraform test-scripts ## Run all tests
	@echo "$(GREEN)✓ All tests passed.$(NC)"
```

Add `test test-terraform test-scripts` to the `.PHONY` line at the top of the Makefile.

- [ ] **Step 2: Verify targets**

Run: `cd terraform-proxmox && make test 2>&1 | tail -5`
Expected: Tests execute (pass or fail depending on bats/terraform availability)

- [ ] **Step 3: Commit**

```bash
git add terraform-proxmox/Makefile
git commit -m "feat: add make test, test-terraform, test-scripts targets"
```

---

## Task 16: Final Validation

- [ ] **Step 1: Run full test suite**

```bash
cd /home/kirui/IaC-Homelab/terraform-proxmox
terraform validate
make test
```

Expected: `terraform validate` passes, all bats and terraform tests pass.

- [ ] **Step 2: Run check-tools.sh to verify octal fix**

```bash
bash scripts/check-tools.sh 2>&1 | grep -i terraform
```

Expected: "Terraform version X.Y.Z satisfies minimum" (no octal errors)

- [ ] **Step 3: Run read-tfvar.sh against all keys**

```bash
for key in vault_kv_mount_path vault_secret_prefix snippet_storage vault_auth_mode manage_vault_access; do
  echo "$key = $(scripts/read-tfvar.sh $key environments/dev.tfvars)"
done
```

Expected: All 5 keys return correct values

- [ ] **Step 4: Commit any final fixes and verify clean state**

```bash
git status
git log --oneline -10
```

Expected: Clean working directory, ~10 focused commits from this implementation
