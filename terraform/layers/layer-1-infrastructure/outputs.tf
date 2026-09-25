output "vm_ips" {
  description = "Map of VM key -> IP address"
  value       = { for k, v in var.vms : k => v.ip }
}

output "k3s_server_ips" {
  description = "k3s server (control-plane) node IPs"
  value       = [for k, v in var.vms : v.ip if v.role == "server"]
}

output "k3s_agent_ips" {
  description = "k3s agent node IPs"
  value       = [for k, v in var.vms : v.ip if v.role == "agent"]
}

output "panel_ip" {
  description = "Pterodactyl panel VM IP"
  value       = [for k, v in var.vms : v.ip if v.role == "panel"]
}
