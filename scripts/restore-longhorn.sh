#!/usr/bin/env bash
# Restore ALL cluster PVC data from the Longhorn S3 backup store onto a fresh cluster.
#
# For every BackupVolume that Longhorn discovers in the store, this:
#   1) creates a Longhorn Volume restored from that volume's latest backup (spec.fromBackup),
#   2) waits for the restore to finish,
#   3) creates a static PersistentVolume pre-bound (claimRef) to the ORIGINAL PVC
#      name+namespace recorded in the backup's KubernetesStatus metadata.
# The apps then create their own PVCs normally (Helm- or StatefulSet-driven) and bind to
# these restored PVs instead of provisioning empty volumes — so a full redeploy comes back
# with all data intact. No chart edits and no ArgoCD PVC conflicts (we create PVs, not PVCs).
#
# MUST run AFTER Longhorn is healthy + its backup target is available, but BEFORE the data
# apps sync (i.e. before the root app-of-apps). The Ansible secrets role enforces that order.
#
# Safe by construction:
#   - first-ever deploy (empty store / no creds) → backup target never becomes available or
#     no BackupVolumes exist → clean no-op, exit 0.
#   - idempotent: skips any target whose PV already exists or whose PVC is already Bound.
#   - per-volume failures are logged and counted, never abort the whole pass.
set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
KUBECTL="${KUBECTL:-kubectl}"
command -v kubectl >/dev/null 2>&1 || KUBECTL="k3s kubectl"
LH_NS="longhorn-system"
BACKUP_TARGET_URL="${LONGHORN_BACKUP_TARGET:-s3://andusystems-longhorn-backups@us-east-1/}"
REPLICAS="${LONGHORN_RESTORE_REPLICAS:-2}"
RESTORE_TIMEOUT="${LONGHORN_RESTORE_TIMEOUT:-900}"   # seconds to wait for ALL restores

log(){ echo "[restore-longhorn] $*"; }

# --- 0) backup target must be available before BackupVolumes populate ------------------
log "waiting for the Longhorn backup target to become available..."
avail=""
for _ in $(seq 1 40); do
  avail="$($KUBECTL -n "$LH_NS" get backuptarget default -o jsonpath='{.status.available}' 2>/dev/null || true)"
  [ "$avail" = "true" ] && break
  sleep 6
done
if [ "$avail" != "true" ]; then
  log "backup target not available (first-ever deploy or no S3 creds) — nothing to restore, exiting 0"
  exit 0
fi

# --- 1) force a store sync + wait for a STABLE, non-empty restore work-list -----------
# BackupVolume CRs appear within seconds, but their status (lastBackupName + the
# KubernetesStatus we map PVCs from) only fills in on a backup-store SYNC — and the poll
# interval defaults to 5m. Racing on mere BackupVolume existence yields an empty work-list
# and a silent no-op (which is exactly how the first redeploy provisioned empty volumes).
# So: force a sync every loop and wait until the derived work-list is non-empty AND stable.
# One tab-separated line per restorable volume: VOL  LASTBACKUP  SIZE  NS  PVC  ACCESSMODE
WORKFILE="$(mktemp)"; trap 'rm -f "$WORKFILE"' EXIT
build_worklist(){
  $KUBECTL -n "$LH_NS" get backupvolumes.longhorn.io -o json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for bv in d.get("items",[]):
    st=bv.get("status",{}) or {}
    last=st.get("lastBackupName"); size=st.get("size")
    vol=(bv.get("spec",{}) or {}).get("volumeName") or bv["metadata"]["name"]
    labels=st.get("labels",{}) or {}
    ks=labels.get("KubernetesStatus")
    if not (last and size and ks): continue
    try: ks=json.loads(ks)
    except Exception: continue
    pvc=ks.get("pvcName"); ns=ks.get("namespace")
    if not (pvc and ns): continue
    am="ReadWriteMany" if labels.get("longhorn.io/volume-access-mode")=="rwx" else "ReadWriteOnce"
    print("\t".join([vol,last,str(size),ns,pvc,am]))
'
}
log "forcing backup-store sync and waiting for the restore work-list to populate..."
prev_n=-1
for i in $(seq 1 42); do   # up to ~7 min
  $KUBECTL -n "$LH_NS" patch backuptarget default --type=merge \
    -p "{\"spec\":{\"syncRequestedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" >/dev/null 2>&1 || true
  build_worklist > "$WORKFILE" 2>/dev/null || true
  n="$(grep -c . "$WORKFILE" 2>/dev/null || echo 0)"
  bvn="$($KUBECTL -n "$LH_NS" get backupvolumes.longhorn.io --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  log "  t+$((i*10))s: backupvolumes=${bvn:-0} restorable=${n}"
  [ "$n" -gt 0 ] && [ "$n" -eq "$prev_n" ] && break   # non-empty and unchanged for one interval
  prev_n="$n"
  sleep 10
done
if [ ! -s "$WORKFILE" ]; then
  log "no restorable backups discovered (empty store / first-ever deploy) — exiting 0"
  exit 0
fi
log "$(grep -c . "$WORKFILE") volume(s) to restore"

# --- 3a) PASS 1: kick off every restore (concurrent in Longhorn) ----------------------
lh_accessmode(){ [ "$1" = "ReadWriteMany" ] && echo rwx || echo rwo; }
while IFS=$'\t' read -r VOL LAST SIZE NS PVC AM; do
  [ -n "$VOL" ] || continue
  if $KUBECTL get pv "$VOL" >/dev/null 2>&1; then continue; fi
  if [ "$($KUBECTL -n "$NS" get pvc "$PVC" -o jsonpath='{.status.phase}' 2>/dev/null || true)" = "Bound" ]; then continue; fi
  if $KUBECTL -n "$LH_NS" get volume "$VOL" >/dev/null 2>&1; then continue; fi
  log "restoring $NS/$PVC  (vol $VOL ← backup $LAST, ${SIZE}B)"
  cat <<YAML | $KUBECTL apply -f - >/dev/null
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: ${VOL}
  namespace: ${LH_NS}
spec:
  fromBackup: "${BACKUP_TARGET_URL}?backup=${LAST}&volume=${VOL}"
  size: "${SIZE}"
  numberOfReplicas: ${REPLICAS}
  frontend: blockdev
  dataEngine: v1
  accessMode: $(lh_accessmode "$AM")
  dataLocality: disabled
  staleReplicaTimeout: 30
YAML
done < "$WORKFILE"

# --- 3b) PASS 2: wait for all restores to complete ------------------------------------
log "waiting for restores to complete (timeout ${RESTORE_TIMEOUT}s)..."
deadline=$(( $(date +%s) + RESTORE_TIMEOUT ))
while :; do
  pending=0
  while IFS=$'\t' read -r VOL LAST SIZE NS PVC AM; do
    [ -n "$VOL" ] || continue
    $KUBECTL get pv "$VOL" >/dev/null 2>&1 && continue                 # already finalized on a prior run
    $KUBECTL -n "$LH_NS" get volume "$VOL" >/dev/null 2>&1 || continue  # volume gone (skipped) — ignore
    rr="$($KUBECTL -n "$LH_NS" get volume "$VOL" -o jsonpath='{.status.restoreRequired}' 2>/dev/null || true)"
    stt="$($KUBECTL -n "$LH_NS" get volume "$VOL" -o jsonpath='{.status.state}' 2>/dev/null || true)"
    if [ "$rr" = "false" ] && { [ "$stt" = "detached" ] || [ "$stt" = "attached" ]; }; then continue; fi
    pending=$((pending+1))
  done < "$WORKFILE"
  [ "$pending" -eq 0 ] && { log "all restores complete"; break; }
  [ "$(date +%s)" -ge "$deadline" ] && { log "WARN timeout with ${pending} restore(s) still pending"; break; }
  sleep 8
done

# --- 3c) PASS 3: create the pre-bound PVs (claimRef → original PVC) --------------------
restored=0; skipped=0; failed=0
while IFS=$'\t' read -r VOL LAST SIZE NS PVC AM; do
  [ -n "$VOL" ] || continue
  # Mirror the PASS 1 skips so already-satisfied targets count as skipped, not failed:
  if $KUBECTL get pv "$VOL" >/dev/null 2>&1; then skipped=$((skipped+1)); continue; fi
  if [ "$($KUBECTL -n "$NS" get pvc "$PVC" -o jsonpath='{.status.phase}' 2>/dev/null || true)" = "Bound" ]; then
    skipped=$((skipped+1)); continue          # app already has storage (PVC bound) — nothing to do
  fi
  if ! $KUBECTL -n "$LH_NS" get volume "$VOL" >/dev/null 2>&1; then
    skipped=$((skipped+1)); continue           # no restore volume was created for this target
  fi
  # only bind a fully-restored volume
  rr="$($KUBECTL -n "$LH_NS" get volume "$VOL" -o jsonpath='{.status.restoreRequired}' 2>/dev/null || true)"
  if [ "$rr" != "false" ]; then
    log "WARN $NS/$PVC — volume $VOL not fully restored (restoreRequired=$rr); leaving for next run"
    failed=$((failed+1)); continue
  fi
  if cat <<YAML | $KUBECTL apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${VOL}
  labels:
    longhorn-restore: "true"
spec:
  capacity:
    storage: "${SIZE}"
  volumeMode: Filesystem
  accessModes: [${AM}]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: ${VOL}
  claimRef:
    namespace: ${NS}
    name: ${PVC}
YAML
  then
    log "  ✓ $NS/$PVC ← PV $VOL (pre-bound)"
    restored=$((restored+1))
  else
    log "  ✗ $NS/$PVC — failed to create PV $VOL"
    failed=$((failed+1))
  fi
done < "$WORKFILE"

log "RESTORE SUMMARY: ${restored} restored, ${skipped} already-present, ${failed} failed/pending"
[ "$failed" -gt 0 ] && log "NOTE: ${failed} volume(s) not restored this pass — re-run to retry (data is still safe in S3)"
exit 0
