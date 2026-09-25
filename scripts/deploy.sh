#!/usr/bin/env bash
# Phased bring-up. Run a single phase and verify before the next, or `all`.
#   ./deploy.sh vms        # 1. Terraform: provision the 5 Proxmox VMs
#   ./deploy.sh k3s        # 2. Ansible: install k3s (3 servers HA + 1 agent)
#   ./deploy.sh gitops     # 3. Ansible: ArgoCD + secrets + root app-of-apps
#   ./deploy.sh all        # run 1→3 in sequence
#
# Prereqs: terraform.tfvars, ansible vault, and hosts.yml filled in (all gitignored).
# After this, ArgoCD reconciles every app from GitHub — including Jenkins, which then
# owns CI + nightly backups. ArgoCD is the deployer; Jenkins is not.
set -euo pipefail
cd "$(dirname "$0")/.."
PHASE="${1:-all}"

vms() {
  echo "== [vms] Terraform: provision Proxmox VMs =="
  ( cd terraform/layers/layer-1-infrastructure && terraform init -input=false && terraform apply -auto-approve )
  echo "== VMs created. Waiting 90s for cloud-init + SSH =="
  sleep 90
}

k3s() {
  echo "== [k3s] Ansible: install k3s (3 servers + 1 agent) =="
  ( cd ansible && ansible-playbook site.yml --tags k3s --limit 'k3s_servers:k3s_agents' )
  echo "== k3s up. Verify: kubectl get nodes (should show 4 Ready) =="
}

gitops() {
  echo "== [gitops] Ansible: ArgoCD + secrets + root app-of-apps =="
  ( cd ansible && ansible-playbook site.yml --tags gitops --limit 'k3s_servers[0]' )
  cat <<'EOF'
== GitOps seeded. ArgoCD is now reconciling the fleet from GitHub. ==
   ArgoCD admin pw:
     kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
   Watch rollout:
     kubectl get applications -n argocd
EOF
}

case "$PHASE" in
  vms)    vms ;;
  k3s)    k3s ;;
  gitops) gitops ;;
  all)    vms; k3s; gitops ;;
  *) echo "usage: $0 {vms|k3s|gitops|all}"; exit 1 ;;
esac
