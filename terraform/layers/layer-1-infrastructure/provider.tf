provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  # Required for VM disk creation when using an API token (provider SSHs to Proxmox nodes)
  ssh {
    username    = var.proxmox_ssh_username
    agent       = var.proxmox_ssh_private_key_path == null
    private_key = var.proxmox_ssh_private_key_path != null ? file(var.proxmox_ssh_private_key_path) : null
  }
}
