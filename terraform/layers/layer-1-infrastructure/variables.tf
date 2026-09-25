# --- Proxmox connection ---
variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox API endpoint, e.g. https://proxmox-host:8006/"
}

variable "proxmox_api_token" {
  type        = string
  description = "Proxmox API token, e.g. terraform@pam!terraform=<uuid>"
  sensitive   = true
}

variable "proxmox_insecure" {
  type    = bool
  default = true
}

variable "proxmox_ssh_username" {
  type    = string
  default = "root"
}

variable "proxmox_ssh_private_key_path" {
  type    = string
  default = null
}

# --- Cloud image ---
variable "vm_cloud_image_url" {
  type    = string
  default = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "vm_cloud_image_content_type" {
  type    = string
  default = "iso"
}

variable "vm_download_datastore_id" {
  type    = string
  default = "local"
}

variable "vm_cloud_image_upload_timeout" {
  type    = number
  default = 1800
}

# --- Networking ---
variable "vm_network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "vlan_id" {
  type        = number
  description = "VLAN tag for the cluster network"
}

variable "network_gateway" {
  type = string
}

variable "network_prefix" {
  type    = number
  default = 24
}

variable "cluster_name" {
  type    = string
  default = "homelab"
}

# --- SSH / cloud-init ---
variable "ssh_username" {
  type    = string
  default = "ubuntu"
}

variable "ssh_public_key_path" {
  type    = string
  default = null
}

variable "ssh_public_key" {
  type    = string
  default = null
}

# --- Firewall (security-first): sources allowed to reach the cluster/SSH ---
variable "admin_source_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach node SSH + k3s API (e.g. workstation subnet)"
  default     = [] # set your admin/workstation subnet(s) in tfvars, e.g. ["10.0.0.0/24"]
}

# --- VM definitions: node placement, sizing, and storage tier per VM ---
# datastore_id: local-ssd on the R630s (worker1/worker2), local-lvm on the DDR3 nodes.
variable "vms" {
  type = map(object({
    node         = string # Proxmox host
    vm_id        = number
    role         = string # server | agent | panel
    cores        = number
    memory_max   = number # MB
    memory_min   = number # MB (balloon floor)
    disk_size    = number # GB
    datastore_id = string # local-ssd | local-lvm
    ip           = string # last octet handled by caller; full address here
  }))
}
