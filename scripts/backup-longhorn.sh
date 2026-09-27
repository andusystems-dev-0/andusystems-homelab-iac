#!/usr/bin/env bash
# Trigger an IMMEDIATE Longhorn backup of every cluster PVC to S3, then wait for it to finish.
# Used pre-destroy in the deploy pipeline so the restore point is fresh (not up to ~24h old).
# Drives the cluster over SSH from the runner. Best-effort: always exits 0 — a backup hiccup
# must never block a deploy, and the nightly/last good backup remains available for restore.
# No-op if Longhorn or its backup target isn't present (first-ever deploy / no S3 creds).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TFVARS="${TFVARS:-$REPO_ROOT/terraform/layers/layer-1-infrastructure/terraform.tfvars}"

SSH_KEY="${PTERO_SSH_KEY:-}"
if [[ -z "$SSH_KEY" ]]; then
  for k in /opt/homelab/keys/proxmox_key "$HOME/.ssh/andusystems-proxmox"; do
    [[ -f "$k" ]] && { SSH_KEY="$k"; break; }
  done
fi
SSH_USER="${SSH_USER:-ubuntu}"
K3S_HOST="${K3S_HOST:-$(grep -E '^[[:space:]]*k3s-1[[:space:]]*=' "$TFVARS" 2>/dev/null \
  | grep -oE 'ip[[:space:]]*=[[:space:]]*"[0-9.]+"' | grep -oE '[0-9.]+' | head -1)}"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

log(){ echo "[backup-longhorn][$(date -u +%H:%M:%S)] $*"; }
[[ -n "$K3S_HOST" && -f "$SSH_KEY" ]] || { log "no K3S_HOST or SSH key — skipping"; exit 0; }

ssh_k3s(){ ssh "${SSH_OPTS[@]}" "${SSH_USER}@${K3S_HOST}" "$@"; }
K="sudo k3s kubectl -n longhorn-system"

# --- gate: Longhorn + backup target available? ---------------------------------------
avail="$(ssh_k3s "$K get backuptarget default -o jsonpath='{.status.available}' 2>/dev/null" 2>/dev/null || true)"
if [[ "$avail" != "true" ]]; then
  log "Longhorn backup target not available — nothing to back up, exiting 0"; exit 0
fi

vols="$(ssh_k3s "$K get volumes.longhorn.io --no-headers 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ' || echo 0)"
log "triggering on-demand backup of ~${vols} volume(s)..."

# A temporary every-minute RecurringJob is the simplest reliable on-demand trigger; it snapshots
# + backs up the whole `default` group (all PVCs). We delete it as soon as a cycle completes.
cleanup(){ ssh_k3s "$K delete recurringjob backup-predestroy >/dev/null 2>&1" 2>/dev/null || true; }
trap cleanup EXIT

ssh_k3s "cat <<'YAML' | $K apply -f - >/dev/null
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: backup-predestroy
  namespace: longhorn-system
spec:
  name: backup-predestroy
  cron: '*/1 * * * *'
  task: backup
  groups: [default]
  retain: 14
  concurrency: 3
YAML" 2>/dev/null || { log "WARN could not create trigger job — using last good backup"; exit 0; }

# Wait for a full cycle: observe InProgress rise above 0, then settle back to 0 (= completed).
inprog_count(){
  ssh_k3s "$K get backups.longhorn.io -o json 2>/dev/null | python3 -c 'import json,sys; d=(json.load(sys.stdin) or {}).get(\"items\",[]); print(sum(1 for b in d if (b.get(\"status\") or {}).get(\"state\")==\"InProgress\"))'" 2>/dev/null || echo 0
}
seen_running=""
for i in $(seq 1 44); do            # ~11 min ceiling
  ip="$(inprog_count)"; ip="${ip:-0}"
  log "t+$((i*15))s: in-progress=${ip}${seen_running:+ (cycle observed)}"
  [[ "$ip" -gt 0 ]] && seen_running=1
  if [[ -n "$seen_running" && "$ip" -eq 0 ]]; then log "fresh backup cycle complete."; exit 0; fi
  sleep 15
done
log "WARN backup did not clearly settle in time — proceeding (last good backup remains for restore)"
exit 0
