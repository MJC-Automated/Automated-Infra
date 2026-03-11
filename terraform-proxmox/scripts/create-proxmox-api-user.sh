#!/bin/bash
# Scripts/create-proxmox-api-user.sh
# Creates a Proxmox API user and token with appropriate permissions.
# Auto-detects PVE version (8 or 9) and outputs the corresponding Vault command.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  create-proxmox-api-user.sh [--password <password>] [--json]
  create-proxmox-api-user.sh [legacy_password]

Options:
  --password <password>  Password for terraform-prov@pve.
  --json                 Output credentials as JSON only.
  -h, --help             Show this help.

Environment:
  PROXMOX_API_USER_PASSWORD  Password fallback if --password is not provided.
EOF
}

# Configuration
USER_ID="terraform-prov@pve"
TOKEN_ID="terraform-token"
ROLE_ID="TerraformProv"
PASSWORD="${PROXMOX_API_USER_PASSWORD:-}"
JSON_OUTPUT=false

log() {
    if [[ "${JSON_OUTPUT}" == true ]]; then
        printf '%s\n' "$*" >&2
    else
        printf '%s\n' "$*"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --password)
            PASSWORD="${2:-}"
            if [[ -z "${PASSWORD}" ]]; then
                echo "Error: --password requires a value." >&2
                exit 1
            fi
            shift 2
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            echo "Error: unknown option: $1" >&2
            usage
            exit 1
            ;;
        *)
            # Backward compatibility: first positional argument as password.
            PASSWORD="$1"
            shift
            ;;
    esac
done

# Detect PVE Version
if [[ -z "${PASSWORD}" ]]; then
    if command -v openssl >/dev/null 2>&1; then
        PASSWORD="$(openssl rand -base64 48 | tr -d '\n' | cut -c1-24)"
        log "No API user password supplied; generated a random password for ${USER_ID}."
    else
        echo "Error: missing API user password and openssl is unavailable for random generation." >&2
        exit 1
    fi
fi
if [[ "${#PASSWORD}" -lt 12 ]]; then
    echo "Error: API user password must be at least 12 characters." >&2
    exit 1
fi

log "Detecting Proxmox VE version..."
if ! command -v pveversion &> /dev/null; then
    echo "Error: pveversion command not found. Are you running this on the Proxmox host?"
    exit 1
fi

PVE_VERSION_FULL=$(pveversion)
PVE_MAJOR_VERSION=$(echo "$PVE_VERSION_FULL" | awk -F/ '{print $2}' | cut -d. -f1)

log "Detected PVE Version: $PVE_MAJOR_VERSION"

# Define Permissions based on version
if [[ "$PVE_MAJOR_VERSION" -eq 8 ]]; then
    PRIVS="Datastore.AllocateSpace Datastore.Audit Pool.Allocate Pool.Audit SDN.Use Sys.Audit Sys.Console Sys.Modify VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Migrate VM.PowerMgmt User.Modify Permissions.Modify"
elif [[ "$PVE_MAJOR_VERSION" -eq 9 ]]; then
    # Note: VM.Monitor might not exist in PVE 9, adjusted as per notes
    PRIVS="Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Pool.Allocate Pool.Audit SDN.Use Sys.Audit Sys.Console Sys.Modify User.Modify VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Console VM.Migrate VM.PowerMgmt"
else
    echo "Error: Unsupported Proxmox VE version: $PVE_MAJOR_VERSION"
    exit 1
fi

# Create Role
log "Creating/Updating Role $ROLE_ID..."
if ! pveum role add "$ROLE_ID" -privs "$PRIVS" 2>/dev/null; then
    pveum role modify "$ROLE_ID" -privs "$PRIVS"
fi

# Create User
log "Creating User $USER_ID..."
if pveum user list | grep -q "$USER_ID"; then
    log "User $USER_ID already exists. Deleting..."
    pveum user delete "$USER_ID"
fi
log "Adding user..."
pveum user add "$USER_ID" --password "$PASSWORD"

# Assign Permissions
log "Assigning ACLs..."
pveum aclmod / -user "$USER_ID" -role "$ROLE_ID"

# Create Token
log "Generating API Token..."
# Remove existing token if it exists to ensure we get a new secret
pveum user token delete "$USER_ID" "$TOKEN_ID" 2>/dev/null || true

# Capture the output which contains the secret
TOKEN_OUTPUT=$(pveum user token add "$USER_ID" "$TOKEN_ID" --privsep 0 --output-format json)
# Extract value using sed/awk since jq might not be present
TOKEN_SECRET=$(echo "$TOKEN_OUTPUT" | grep "value" | sed 's/.*"value": *"\([^"]*\)".*/\1/')

if [[ -z "$TOKEN_SECRET" || "$TOKEN_SECRET" == "null" ]]; then
    echo "Error: Failed to retrieve token secret."
    exit 1
fi

PROXMOX_API_URL="https://$(hostname -i | awk '{print $1}'):8006/api2/json"
TOKEN_FULL_ID="$USER_ID!$TOKEN_ID"

if [[ "${JSON_OUTPUT}" == true ]]; then
    printf '{"proxmox_config_api_url":"%s","proxmox_config_api_token_id":"%s","proxmox_config_api_token_secret":"%s","proxmox_config_tls_insecure":true}\n' \
        "${PROXMOX_API_URL}" \
        "${TOKEN_FULL_ID}" \
        "${TOKEN_SECRET}"
    exit 0
fi

echo "✅ Proxmox API user/token created."
echo "For secure rotation + Vault update, run from workstation:"
echo "  make -C terraform-proxmox rotate-proxmox-creds ENVIRONMENT=<env>"
echo "If you must use this script directly, use --json and handle output securely (no shell history/logs)."
