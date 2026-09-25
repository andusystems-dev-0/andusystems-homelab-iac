#!/usr/bin/env bash
# ONE-TIME SEED — run from an on-network box (workstation) exactly once, because
# nothing exists yet to run on. Provisions VMs, installs k3s, and installs the
# ARC self-hosted GHA runner. After this, ALL further deploys run on that runner
# via GitHub Actions (.github/workflows/deploy.yml) — the workstation is done.
#
#   ./deploy.sh vms     # 1. Terraform: provision the 5 Proxmox VMs
#   ./deploy.sh k3s     # 2. Ansible: install k3s (3 servers HA + 1 agent)
#   ./deploy.sh arc     # 3. Ansible: install ARC runner (registers self-hosted-homelab-iac)
#   ./deploy.sh gitops  # (optional) seed ArgoCD locally instead of via GHA
#   ./deploy.sh seed    # run 1→3 (the full one-time seed)
#
# Prereqs: terraform.tfvars, ansible vault (incl. github_runner_pat), hosts.yml (all gitignored).
set -euo pipefail
cd "$(dirname "$0")/.."
PHASE="${1:-seed}"

vms() {
  echo "== [vms] Terraform: provision Proxmox VMs =="
  ( cd terraform/layers/layer-1-infrastructure && terraform init -input=false && terraform apply -auto-approve )
  echo "== VMs created. Waiting 90s for cloud-init + SSH =="; sleep 90
}
k3s()    { echo "== [k3s] Ansible: install k3s =="; ( cd ansible && ansible-playbook site.yml --tags k3s --limit 'k3s_servers:k3s_agents' ); echo "verify: kubectl get nodes (4 Ready)"; }
gitops() { echo "== [gitops] Ansible: ArgoCD + secrets + app-of-apps (optional; normally run via GHA) =="; ( cd ansible && ansible-playbook site.yml --tags gitops --limit 'k3s_servers[0]' ); }

case "$PHASE" in
  vms) vms ;;
  k3s) k3s ;;
  gitops) gitops ;;
  seed) vms; k3s; echo "== SEED DONE. Now trigger the GHA 'deploy' workflow (apply=true) to bring up ArgoCD + the fleet. ==" ;;
  *) echo "usage: $0 {vms|k3s|gitops|seed}"; exit 1 ;;
esac
