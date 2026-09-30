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

# Persistent media/NAS node. Provisioned ONCE from the workstation; serves the Jellyfin media
# library over NFS (+ Samba for ingest). It is NOT part of the cluster (layer-1) state, so a
# cluster destroy/recreate never removes it or the media. The big data disk is thin-provisioned
# on worker3's bulk pool and formatted ONCE (guarded by blkid) so a VM rebuild never wipes it.

resource "proxmox_virtual_environment_file" "ubuntu_image" {
  content_type   = "iso"
  datastore_id   = "local"
  node_name      = var.nas_node
  timeout_upload = 1800
  source_file { path = var.vm_cloud_image_url }
}

resource "proxmox_virtual_environment_file" "nas_cloud_init" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.nas_node
  source_raw {
    file_name = "homelab-nas-cloud-init.yaml"
    # Inject the SSH public key at apply time (keeps it out of the public repo). This custom
    # user-data REPLACES bpg's generated user-data, so the user + key must live here too.
    data = templatefile("${path.module}/cloud-init/nas.yaml.tftpl", {
      ssh_key     = trimspace(file(var.ssh_public_key_path))
      nfs_clients = join(" ", [for c in var.storage_client_cidrs : "${c}(rw,sync,no_subtree_check,all_squash,anonuid=65534,anongid=65534)"])
      smb_hosts   = join(" ", concat(var.storage_client_cidrs, ["127."]))
    })
  }
}

resource "proxmox_virtual_environment_vm" "nas" {
  name        = "${var.cluster_name}-nas"
  description = "Persistent NAS — Jellyfin media over NFS/SMB (not part of the k3s cluster)"
  tags        = [var.cluster_name, "nas"]
  node_name   = var.nas_node
  vm_id       = var.nas_vm_id

  agent { enabled = false }
  stop_on_destroy = true

  cpu {
    cores = var.nas_cores
    type  = "x86-64-v2-AES"
  }
  memory {
    dedicated = var.nas_memory
  }

  # OS disk (cloud image)
  disk {
    datastore_id = var.nas_datastore_id
    file_id      = proxmox_virtual_environment_file.ubuntu_image.id
    interface    = "scsi0"
    size         = var.nas_os_disk
    ssd          = true
    discard      = "on"
  }
  # Media data disk (thin) — the library lives here; appears as /dev/sdb in the guest.
  disk {
    datastore_id = var.nas_datastore_id
    interface    = "scsi1"
    size         = var.nas_data_disk
    discard      = "on"
  }

  network_device {
    bridge   = var.vm_network_bridge
    vlan_id  = var.vlan_id
    firewall = true
  }

  initialization {
    dns {
      servers = var.nas_dns_servers
    }
    ip_config {
      ipv4 {
        address = "${var.nas_ip}/${var.network_prefix}"
        gateway = var.network_gateway
      }
    }
    user_data_file_id = proxmox_virtual_environment_file.nas_cloud_init.id
  }

  operating_system { type = "l26" }

  # cloud-init only runs at first boot, so don't recreate the VM (and wipe the media disk)
  # just because the snippet/IP/keys changed — a fresh deploy still uses the full block on create.
  lifecycle {
    ignore_changes = [initialization]
  }
}

# Firewall: default-deny inbound. Allow admin SSH, and NFS/SMB only from the cluster + mgmt LANs.
resource "proxmox_virtual_environment_firewall_options" "nas" {
  node_name     = var.nas_node
  vm_id         = proxmox_virtual_environment_vm.nas.vm_id
  enabled       = true
  dhcp          = false
  input_policy  = "DROP"
  output_policy = "ACCEPT"
}

resource "proxmox_virtual_environment_firewall_rules" "nas" {
  node_name = var.nas_node
  vm_id     = proxmox_virtual_environment_vm.nas.vm_id

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
  dynamic "rule" {
    for_each = var.storage_client_cidrs
    content {
      type    = "in"
      action  = "ACCEPT"
      source  = rule.value
      proto   = "tcp"
      dport   = "2049,111,445,139"
      comment = "NFS + SMB (tcp)"
      enabled = true
    }
  }
  dynamic "rule" {
    for_each = var.storage_client_cidrs
    content {
      type    = "in"
      action  = "ACCEPT"
      source  = rule.value
      proto   = "udp"
      dport   = "2049,111"
      comment = "NFS (udp)"
      enabled = true
    }
  }
}

output "nas_ip" { value = var.nas_ip }
output "nas_nfs_export" { value = "${var.nas_ip}:/srv/media" }
