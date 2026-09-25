#!/usr/bin/env bash
# One-shot bring-up: provision VMs (Terraform) → bootstrap k3s + GitOps (Ansible).
# Prereqs: terraform.tfvars and ansible vault + hosts.yml filled in (all gitignored).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== layer-1: provision Proxmox VMs =="
( cd terraform/layers/layer-1-infrastructure && terraform init && terraform apply )

echo "== wait for cloud-init + SSH on the new VMs =="
sleep 90

echo "== bootstrap k3s (3 servers + agent) + ArgoCD + secrets + app-of-apps =="
( cd ansible && ansible-playbook site.yml )

echo "== done. ArgoCD is now reconciling every app from GitHub. =="
echo "   argocd admin pw: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
