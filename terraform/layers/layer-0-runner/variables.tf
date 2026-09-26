variable "proxmox_endpoint" {
  type = string
}
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
variable "vlan_id" {
  type = number
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
variable "ssh_username" {
  type    = string
  default = "ubuntu"
}
variable "ssh_public_key_path" {
  type = string
}
variable "admin_source_cidrs" {
  type    = list(string)
  default = []
}
variable "runner_node" {
  type    = string
  default = "worker1"
}
variable "runner_vm_id" {
  type    = number
  default = 1000
}
variable "runner_ip" {
  type = string
}
variable "runner_cores" {
  type    = number
  default = 2
}
variable "runner_memory" {
  type    = number
  default = 8192
}
variable "runner_disk" {
  type    = number
  default = 40
}
variable "runner_datastore_id" {
  type    = string
  default = "local-ssd"
}
