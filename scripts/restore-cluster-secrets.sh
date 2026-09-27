#!/usr/bin/env bash
# Restore cert-manager TLS secrets from S3 onto a fresh cluster BEFORE cert-manager reconciles
# its Certificates. cert-manager then finds a valid secret matching each Certificate and ADOPTS
# it (sets Ready without contacting an ACME server) instead of re-issuing — so a redeploy does
# not hammer Let's Encrypt and TLS (incl. Wings) is up immediately.
#
# Runner-side: pulls from S3, ensures namespaces, kubectl-applies each secret over SSH. Runs
# after k3s install and BEFORE the gitops step (which installs cert-manager + the apps).
# Best-effort/no-op-safe: exits 0 if there's no backup yet (first-ever deploy) or no creds.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TFVARS="${TFVARS:-$REPO_ROOT/terraform/layers/layer-1-infrastructure/terraform.tfvars}"
SSH_KEY="${PTERO_SSH_KEY:-}"
if [[ -z "$SSH_KEY" ]]; then
  for k in /opt/homelab/keys/proxmox_key "$HOME/.ssh/andusystems-proxmox"; do [[ -f "$k" ]] && { SSH_KEY="$k"; break; }; done
fi
SSH_USER="${SSH_USER:-ubuntu}"
K3S_HOST="${K3S_HOST:-$(grep -E '^[[:space:]]*k3s-1[[:space:]]*=' "$TFVARS" 2>/dev/null \
  | grep -oE 'ip[[:space:]]*=[[:space:]]*"[0-9.]+"' | grep -oE '[0-9.]+' | head -1)}"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
S3_BUCKET="${S3_BUCKET:-andusystems-pterodactyl-backups}"
S3_BASE="s3://${S3_BUCKET}/cluster-tls"

log(){ echo "[restore-cluster-secrets][$(date -u +%H:%M:%S)] $*"; }
[[ -n "$K3S_HOST" && -f "$SSH_KEY" ]] || { log "no K3S_HOST or SSH key — skipping"; exit 0; }
if ! { [[ -n "${AWS_ACCESS_KEY_ID:-}" || -f "$HOME/.aws/credentials" ]] && aws sts get-caller-identity >/dev/null 2>&1; }; then
  log "AWS creds not usable — skipping (certs will be issued fresh)"; exit 0
fi
if ! aws s3 ls "${S3_BASE}/LATEST/tls-secrets.json.gz" >/dev/null 2>&1; then
  log "no TLS-secret backup in S3 — first deploy / nothing to restore, exiting 0"; exit 0
fi
ssh_k3s(){ ssh "${SSH_OPTS[@]}" "${SSH_USER}@${K3S_HOST}" "$@"; }

DUMP="$(aws s3 cp "${S3_BASE}/LATEST/tls-secrets.json.gz" - 2>/dev/null | gunzip 2>/dev/null)"
n="$(printf '%s' "$DUMP" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)' 2>/dev/null || echo 0)"
if [[ "${n:-0}" -eq 0 ]]; then log "backup empty/unreadable — nothing to restore, exiting 0"; exit 0; fi
log "restoring ${n} cert-manager TLS secret(s) from ${S3_BASE}/LATEST"

# 1) ensure every target namespace exists (before cert-manager / the apps do)
printf '%s' "$DUMP" | python3 -c 'import json,sys
print("\n".join(sorted({s["metadata"]["namespace"] for s in json.load(sys.stdin)})))' \
  | while read -r ns; do
      [[ -n "$ns" ]] || continue
      ssh_k3s "sudo k3s kubectl create namespace '$ns' --dry-run=client -o yaml | sudo k3s kubectl apply -f -" >/dev/null 2>&1
    done

# 2) apply each secret (kubectl apply is idempotent + adopts if a matching one already exists)
applied=0; failed=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  ns="$(printf '%s' "$line" | python3 -c 'import json,sys;print(json.load(sys.stdin)["metadata"]["namespace"])' 2>/dev/null)"
  name="$(printf '%s' "$line" | python3 -c 'import json,sys;print(json.load(sys.stdin)["metadata"]["name"])' 2>/dev/null)"
  if printf '%s' "$line" | ssh_k3s "sudo k3s kubectl apply -f -" >/dev/null 2>&1; then
    log "  ✓ ${ns}/${name}"; applied=$((applied+1))
  else
    log "  ✗ ${ns}/${name} (apply failed)"; failed=$((failed+1))
  fi
done < <(printf '%s' "$DUMP" | python3 -c 'import json,sys
for s in json.load(sys.stdin): print(json.dumps(s))')

log "RESTORE SUMMARY: ${applied} applied, ${failed} failed"
exit 0
