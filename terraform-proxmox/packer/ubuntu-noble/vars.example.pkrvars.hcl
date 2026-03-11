// Copy to vars.<env>.pkrvars.hcl and adjust values.
// When PACKER_USE_VAULT_CREDS=true, token values below are overridden
// by scripts/render-packer-vault-vars.sh from Vault.

proxmox_api_url      = "https://<proxmox-host>:8006/api2/json"
proxmox_node         = "<proxmox-node>"
proxmox_token_id     = "unused-when-vault-enabled"
proxmox_token        = "unused-when-vault-enabled"
proxmox_tls_insecure = true

template_name = "ubuntu2404-template"
vm_id         = 999999995
clone_vm_id   = 999999992
cpu_cores     = 8
memory_mb     = 10240
