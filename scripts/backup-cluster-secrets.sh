#!/usr/bin/env bash
# Back up every cert-manager-issued TLS secret to S3 so a redeploy can ADOPT the existing
# certs instead of re-requesting them from Let's Encrypt. Without this, each full redeploy
# re-issues ~10 certs → trips LE rate limits (5 dup/domain/wk, 50/registered-domain/wk) and
# leaves a TLS gap (and Wings hard-down) until issuance succeeds.
#
# Runner-side: drives the cluster over SSH, streams to S3. Best-effort — always exits 0 so a
# hiccup never blocks a deploy. No-op if there are no cert-manager TLS secrets yet.
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
RETAIN="${CLUSTER_TLS_RETAIN:-14}"

log(){ echo "[backup-cluster-secrets][$(date -u +%H:%M:%S)] $*"; }
[[ -n "$K3S_HOST" && -f "$SSH_KEY" ]] || { log "no K3S_HOST or SSH key — skipping"; exit 0; }
if ! { [[ -n "${AWS_ACCESS_KEY_ID:-}" || -f "$HOME/.aws/credentials" ]] && aws sts get-caller-identity >/dev/null 2>&1; }; then
  log "AWS creds not usable — skipping"; exit 0
fi
ssh_k3s(){ ssh "${SSH_OPTS[@]}" "${SSH_USER}@${K3S_HOST}" "$@"; }

TS="$(date -u +%Y%m%dT%H%M%SZ)"

# Dump every cert-manager-managed TLS secret as a sanitized manifest list. We strip the
# server-populated + owner fields (uid/resourceVersion/managedFields/ownerReferences/status)
# so the restored secret isn't garbage-collected before its Certificate is recreated, and
# keep only the cert-manager.io/* annotations + labels + data (tls.crt/tls.key/ca.crt).
DUMP="$(ssh_k3s "sudo k3s kubectl get secret -A -o json" 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
out=[]
for s in d.get("items",[]):
    if s.get("type")!="kubernetes.io/tls": continue
    m=s.get("metadata",{}) or {}
    ann=m.get("annotations") or {}
    if "cert-manager.io/certificate-name" not in ann: continue
    out.append({
        "apiVersion":"v1","kind":"Secret","type":s["type"],"data":s.get("data",{}),
        "metadata":{
            "name":m["name"],"namespace":m["namespace"],
            "annotations":{k:v for k,v in ann.items() if k.startswith("cert-manager.io/")},
            "labels":{k:v for k,v in (m.get("labels") or {}).items() if not k.startswith("kubernetes.io/")},
        }})
print(json.dumps(out))
')"

n="$(printf '%s' "$DUMP" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)' 2>/dev/null || echo 0)"
if [[ "${n:-0}" -eq 0 ]]; then
  log "no cert-manager TLS secrets present yet — nothing to back up, exiting 0"; exit 0
fi

printf '%s' "$DUMP" | gzip | aws s3 cp - "${S3_BASE}/${TS}/tls-secrets.json.gz" >/dev/null
printf '%s' "$DUMP" | gzip | aws s3 cp - "${S3_BASE}/LATEST/tls-secrets.json.gz" >/dev/null
log "backed up ${n} cert-manager TLS secret(s) → ${S3_BASE}/${TS}/ (+ LATEST)"

# prune: keep the most recent $RETAIN timestamped dumps (LATEST is separate + always kept)
aws s3 ls "${S3_BASE}/" 2>/dev/null | awk '/PRE/{print $2}' | grep -E '^[0-9]{8}T[0-9]{6}Z/$' | sort \
  | head -n "-${RETAIN}" | while read -r old; do
      aws s3 rm --recursive "${S3_BASE}/${old}" >/dev/null 2>&1 && log "pruned ${old%/}"
    done
log "done."
