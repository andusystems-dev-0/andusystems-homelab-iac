locals {
  ssh_public_key_content = (var.ssh_public_key != null && var.ssh_public_key != "") ? trimspace(var.ssh_public_key) : trimspace(file(var.ssh_public_key_path))
  # Distinct Proxmox nodes that will host a VM (for cloud-image upload)
  proxmox_vm_nodes = toset([for v in var.vms : v.node])
}

# Cloud image: uploaded to each Proxmox node that hosts a VM (avoids Proxmox 403 fetching the Ubuntu CDN).
resource "proxmox_virtual_environment_file" "ubuntu_image" {
  for_each       = local.proxmox_vm_nodes
  content_type   = var.vm_cloud_image_content_type
  datastore_id   = var.vm_download_datastore_id
  node_name      = each.key
  timeout_upload = var.vm_cloud_image_upload_timeout

  source_file {
    path = var.vm_cloud_image_url
  }
}

# Cluster VMs (k3s servers/agent + Pterodactyl panel), placed and sized per var.vms.
resource "proxmox_virtual_environment_vm" "vm" {
  for_each    = var.vms
  name        = "${var.cluster_name}-${each.key}"
  description = "homelab ${each.value.role}"
  tags        = [var.cluster_name, each.value.role]
  node_name   = each.value.node
  vm_id       = each.value.vm_id

  # Agent disabled: the cloud image doesn't run qemu-guest-agent, so waiting on it
  # blocks the provider (create/refresh/destroy hang). We use static cloud-init IPs,
  # so the agent isn't needed; ACPI handles graceful shutdown.
  agent { enabled = false }
  stop_on_destroy = true

  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory_max
    floating  = each.value.memory_min
  }

  disk {
    datastore_id = each.value.datastore_id
    file_id      = proxmox_virtual_environment_file.ubuntu_image[each.value.node].id
    interface    = "scsi0"
    size         = each.value.disk_size
    ssd          = true
    discard      = "on"
  }

  network_device {
    bridge   = var.vm_network_bridge
    vlan_id  = var.vlan_id
    firewall = true # per-NIC firewall enabled; rules below
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.network_prefix}"
        gateway = var.network_gateway
      }
    }
    user_account {
      username = var.ssh_username
      keys     = [local.ssh_public_key_content]
    }
  }

  operating_system {
    type = "l26"
  }
}

# ---------------------------------------------------------------------------
# Firewall (network-security first). Default-deny inbound at the VM level;
# only intra-cluster traffic and admin sources are
# allowed to SSH / k3s API. Public game/web traffic arrives via the Pangolin
# Newt tunnel (egress-initiated), so it needs no inbound VM rule.
# ---------------------------------------------------------------------------
resource "proxmox_virtual_environment_firewall_options" "vm" {
  for_each  = var.vms
  node_name = each.value.node
  vm_id     = each.value.vm_id

  enabled       = true
  dhcp          = false
  input_policy  = "DROP"
  output_policy = "ACCEPT"
  macfilter     = false
}

resource "proxmox_virtual_environment_firewall_rules" "vm" {
  for_each  = var.vms
  node_name = each.value.node
  vm_id     = each.value.vm_id

  # Allow all traffic between cluster nodes (k3s, etcd, flannel VXLAN, etc.)
  dynamic "rule" {
    for_each = { for k, v in var.vms : k => v.ip }
    content {
      type    = "in"
      action  = "ACCEPT"
      source  = rule.value
      comment = "intra-cluster from ${rule.key}"
      enabled = true
    }
  }

  # Allow SSH + k3s API from admin sources only (workstation subnet)
  dynamic "rule" {
    for_each = var.admin_source_cidrs
    content {
      type    = "in"
      action  = "ACCEPT"
      source  = rule.value
      proto   = "tcp"
      dport   = "22,6443"
      comment = "admin SSH + k3s API"
      enabled = true
    }
  }

  # Allow ICMP from admin sources (diagnostics)
  dynamic "rule" {
    for_each = var.admin_source_cidrs
    content {
      type    = "in"
      action  = "ACCEPT"
      source  = rule.value
      proto   = "icmp"
      comment = "admin ping"
      enabled = true
    }
  }
}
