#!/usr/bin/env bash
# Shared helpers for the Pterodactyl backup/restore scripts.
# Sourced by backup-pterodactyl.sh and restore-pterodactyl.sh.
#
# Host addresses are NOT hardcoded (this repo is public). They are discovered from the
# gitignored terraform.tfvars (present locally and reconstructed on the runner), or can
# be overridden via env: PANEL_HOST, WINGS_HOST, K3S_HOST.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TFVARS="${TFVARS:-$REPO_ROOT/terraform/layers/layer-1-infrastructure/terraform.tfvars}"

# SSH key: runner path first, then the workstation key, then env override.
PTERO_SSH_KEY="${PTERO_SSH_KEY:-}"
if [[ -z "$PTERO_SSH_KEY" ]]; then
  for k in /opt/homelab/keys/proxmox_key "$HOME/.ssh/andusystems-proxmox"; do
    [[ -f "$k" ]] && { PTERO_SSH_KEY="$k"; break; }
  done
fi
SSH_USER="${SSH_USER:-ubuntu}"
SSH_OPTS=(-i "$PTERO_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10)

# Pull `ip = "x.x.x.x"` out of a named vms{} entry in the tfvars (e.g. panel, k3s-2, k3s-1).
_tfvar_ip() {
  local name="$1"
  grep -E "^[[:space:]]*${name}[[:space:]]*=" "$TFVARS" 2>/dev/null \
    | grep -oE 'ip[[:space:]]*=[[:space:]]*"[0-9.]+"' | grep -oE '[0-9.]+' | head -1
}

PANEL_HOST="${PANEL_HOST:-$(_tfvar_ip panel)}"      # standalone panel VM
WINGS_HOST="${WINGS_HOST:-$(_tfvar_ip k3s-2)}"      # worker2 = the pinned wings node
K3S_HOST="${K3S_HOST:-$(_tfvar_ip k3s-1)}"          # first k3s server (kubectl entrypoint)

for v in PANEL_HOST WINGS_HOST K3S_HOST; do
  [[ -n "${!v}" ]] || { echo "FATAL: could not determine $v (set it in env or ensure $TFVARS exists)" >&2; exit 2; }
done
[[ -f "$PTERO_SSH_KEY" ]] || { echo "FATAL: SSH key not found (set PTERO_SSH_KEY)" >&2; exit 2; }

ssh_panel() { ssh "${SSH_OPTS[@]}" "${SSH_USER}@${PANEL_HOST}" "$@"; }
ssh_wings() { ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WINGS_HOST}" "$@"; }
ssh_k3s()   { ssh "${SSH_OPTS[@]}" "${SSH_USER}@${K3S_HOST}"   "$@"; }
KUBECTL="sudo k3s kubectl"

# S3 layout / naming
S3_BUCKET="${S3_BUCKET:-andusystems-pterodactyl-backups}"
S3_PREFIX="${S3_PREFIX:-pterodactyl}"
S3_BASE="s3://${S3_BUCKET}/${S3_PREFIX}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
