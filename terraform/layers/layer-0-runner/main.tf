terraform {
  required_version = ">= 1.6.0"
  required_providers {
    proxmox = { source = "bpg/proxmox", version = ">= 0.66.0" }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure
  ssh {
    username    = var.proxmox_ssh_username
    agent       = var.proxmox_ssh_private_key_path == null
    private_key = var.proxmox_ssh_private_key_path != null ? file(var.proxmox_ssh_private_key_path) : null
  }
}

# Persistent off-cluster ops runner. Provisioned ONCE from the workstation; it then
# drives all cluster ops (terraform/ansible/gitops) via GitHub Actions. NOT part of
# the cluster (layer-1) state, so a cluster teardown never removes it.
resource "proxmox_virtual_environment_file" "ubuntu_image" {
  content_type   = "iso"
  datastore_id   = "local"
  node_name      = var.runner_node
  timeout_upload = 1800
  source_file { path = var.vm_cloud_image_url }
}

resource "proxmox_virtual_environment_vm" "runner" {
  name        = "${var.cluster_name}-ops-runner"
  description = "Persistent GitHub Actions self-hosted runner (homelab-ops)"
  tags        = [var.cluster_name, "ops-runner"]
  node_name   = var.runner_node
  vm_id       = var.runner_vm_id

  agent { enabled = true }
  stop_on_destroy = true

  cpu {
    cores = var.runner_cores
    type  = "x86-64-v2-AES"
  }
  memory {
    dedicated = var.runner_memory
  }

  disk {
    datastore_id = var.runner_datastore_id
    file_id      = proxmox_virtual_environment_file.ubuntu_image.id
    interface    = "scsi0"
    size         = var.runner_disk
    ssd          = true
    discard      = "on"
  }

  network_device {
    bridge   = var.vm_network_bridge
    vlan_id  = var.vlan_id
    firewall = true
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${var.runner_ip}/${var.network_prefix}"
        gateway = var.network_gateway
      }
    }
    user_account {
      username = var.ssh_username
      keys     = [trimspace(file(var.ssh_public_key_path))]
    }
  }

  operating_system { type = "l26" }
}

# Firewall: default-deny inbound, allow SSH from admin sources only. All egress open
# (needs to reach GitHub, Proxmox API, and the cluster nodes).
resource "proxmox_virtual_environment_firewall_options" "runner" {
  node_name     = var.runner_node
  vm_id         = proxmox_virtual_environment_vm.runner.vm_id
  enabled       = true
  dhcp          = false
  input_policy  = "DROP"
  output_policy = "ACCEPT"
}

resource "proxmox_virtual_environment_firewall_rules" "runner" {
  node_name = var.runner_node
  vm_id     = proxmox_virtual_environment_vm.runner.vm_id
  dynamic "rule" {
    for_each = var.admin_source_cidrs
    content {
      type    = "in"
      action  = "ACCEPT"
      source  = rule.value
      proto   = "tcp"
      dport   = "22"
      comment = "admin SSH"
      enabled = true
    }
  }
}

output "runner_ip" { value = var.runner_ip }
