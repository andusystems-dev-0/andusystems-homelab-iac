# andusystems-homelab-iac

> Infrastructure-as-code for the consolidated **homelab k3s cluster** on Proxmox — VM provisioning (Terraform), cluster bootstrap (Ansible), and GitOps app delivery (ArgoCD app-of-apps + Helm).

## Purpose

Single lean k3s cluster replacing the old shipyard/management estate. Runs game hosting (Pterodactyl), light web hosting, and supporting services, delivered via ArgoCD from this repository. Network security is a first-class concern: Proxmox VM firewalls, default-deny Kubernetes NetworkPolicies, and CrowdSec in front of ingress.

## At a glance

| Field | Value |
|---|---|
| Type | IaC cluster |
| Orchestrator | k3s (Flannel CNI, ServiceLB, Traefik bundled) |
| Nodes | 3 servers (HA embedded etcd) + 1 agent |
| Primary stack | Terraform + Ansible + ArgoCD + Helm |
| Public ingress | Pangolin (Newt) — raw TCP/UDP for games + web |
| Admin access | Tailscale (private mesh) |
| Secrets | GitHub (SOPS-encrypted in-repo) |
| Backups | Jenkins jobs → S3 |
| Status | building |

## Cluster nodes (Proxmox VMs)

| VM | Proxmox host | Role | vCPU | RAM | Disk / tier |
|---|---|---|---|---|---|
| homelab-k3s-1 | worker1 | k3s server (etcd) | 10 | 24 GB | 120 GB / local-ssd |
| homelab-k3s-2 | worker2 | k3s server | 16 | 64 GB | 250 GB / local-ssd |
| homelab-k3s-3 | worker3 | k3s server | 24 | 84 GB | 2.5 TB / local-lvm |
| homelab-k3s-4 | worker5 | k3s agent | 28 | 128 GB | 1.3 TB / local-lvm |
| homelab-panel | worker2 | Pterodactyl Panel (standalone) | 4 | 12 GB | 60 GB / local-ssd |

`omada` (VM 216) is a pre-existing standalone VM on worker2, not managed by this repo.

## Applications (ArgoCD app-of-apps)

| App | Namespace | Purpose |
|---|---|---|
| argocd | `argocd` | GitOps hub (app-of-apps) |
| traefik | `traefik` | Ingress (bundled with k3s, configured here) |
| cert-manager | `cert-manager` | TLS via Let's Encrypt DNS-01 |
| longhorn | `longhorn-system` | Distributed block storage |
| pangolin-newt | `newt` | Public ingress connector (games + web) |
| crowdsec | `crowdsec` | Intrusion prevention |
| tailscale | `tailscale` | Private/admin mesh |
| pihole | `pihole` | Internal DNS |
| nexus | `nexus` | Artifact + image registry |
| jenkins | `jenkins` | CI + scheduled backup jobs → S3 |
| grafana-lgtm | `observability` | Loki + Grafana + Tempo + Mimir |
| prometheus | `prometheus` | Metrics + Alertmanager |
| vaultwarden | `vaultwarden` | Password vault |
| glance | `glance` | Dashboard portal |
| uptime-kuma | `uptime-kuma` | Uptime / status |
| portainer | `portainer` | Docker + k3s management UI |
| jellyfin | `jellyfin` | Music streaming (audio; capped) |
| pterodactyl-wings | `pterodactyl` | Game-server daemons (DaemonSet on worker2/3/5) |

## Layout

```
terraform/layers/
  layer-0-state/           # remote state (S3)
  layer-1-infrastructure/  # Proxmox VMs + firewall
  layer-2-helmapps/        # optional TF-managed helm
ansible/
  inventory/homelab/       # hosts + group_vars (vault, gitignored)
  configurations/roles/    # k3s bootstrap, argocd, per-app
apps/<app>/                # ArgoCD Application manifest.yml + values.yml
security/networkpolicies/  # default-deny + per-namespace allows
```

## Bootstrap order

1. `terraform apply` (layer-0-state → layer-1-infrastructure) — provisions VMs + firewall.
2. `ansible-playbook` — installs k3s (3 servers + 1 agent), bootstraps ArgoCD.
3. ArgoCD syncs the app-of-apps; Newt/Tailscale bring up ingress/mesh.
