variable "proxmox_endpoint" { type = string }
variable "proxmox_api_token" {
  type      = string
  sensitive = true
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

variable "vm_cloud_image_url" {
  type    = string
  default = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}
variable "vm_network_bridge" {
  type    = string
  default = "vmbr0"
}
variable "vlan_id" { type = number }
variable "network_gateway" { type = string }
variable "network_prefix" {
  type    = number
  default = 24
}
variable "cluster_name" {
  type    = string
  default = "homelab"
}
variable "ssh_username" {
  type    = string
  default = "ubuntu"
}
variable "ssh_public_key_path" { type = string }

variable "admin_source_cidrs" {
  type    = list(string)
  default = []
}
# LANs allowed to mount NFS / SMB (cluster VLAN + mgmt).
variable "storage_client_cidrs" {
  type    = list(string)
  default = []
}

variable "nas_node" {
  type    = string
  default = "worker3"
}
variable "nas_vm_id" {
  type    = number
  default = 1001
}
variable "nas_ip" { type = string }
variable "nas_cores" {
  type    = number
  default = 2
}
variable "nas_memory" {
  type    = number
  default = 2048
}
variable "nas_os_disk" {
  type    = number
  default = 20
}
variable "nas_data_disk" {
  type    = number
  default = 1000
}
variable "nas_datastore_id" {
  type    = string
  default = "local-lvm"
}
variable "nas_dns_servers" {
  type    = list(string)
  default = ["1.1.1.1", "8.8.8.8"]
}
