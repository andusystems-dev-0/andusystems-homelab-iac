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

# --- 1) let Longhorn discover BackupVolumes from S3 ------------------------------------
log "waiting for BackupVolumes to appear from the store..."
n=0
for _ in $(seq 1 20); do
  n="$($KUBECTL -n "$LH_NS" get backupvolumes.longhorn.io --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "${n:-0}" -gt 0 ] && break
  sleep 6
done
if [ "${n:-0}" -eq 0 ]; then
  log "no BackupVolumes in the store — first-ever deploy? nothing to restore, exiting 0"
  exit 0
fi
log "found ${n} BackupVolume(s)"

# --- 2) build the restore work-list from backup metadata ------------------------------
# One tab-separated line per restorable volume: VOL  LASTBACKUP  SIZE  NS  PVC  ACCESSMODE
WORKFILE="$(mktemp)"; trap 'rm -f "$WORKFILE"' EXIT
$KUBECTL -n "$LH_NS" get backupvolumes.longhorn.io -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
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
' > "$WORKFILE" || { log "failed to read backup metadata"; exit 1; }

if [ ! -s "$WORKFILE" ]; then
  log "no restorable backups (BackupVolumes lack KubernetesStatus) — exiting 0"
  exit 0
fi
log "$(wc -l < "$WORKFILE" | tr -d ' ') volume(s) to restore"

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
  if $KUBECTL get pv "$VOL" >/dev/null 2>&1; then skipped=$((skipped+1)); continue; fi
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
