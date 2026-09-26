#!/usr/bin/env bash
# Back up ALL Pterodactyl state to S3 under a timestamped prefix, then prune (GFS).
#
# Captures:  panel DB (mariadb-dump) · panel files (/opt/pterodactyl incl APP_KEY,
#            /opt/ptero/panel, caddy certs) · game-server volumes (/var/lib/pterodactyl
#            on the wings node) · the wings-config Secret (node token).
#
# Env:  S3_BUCKET (def andusystems-pterodactyl-backups) · S3_PREFIX (def pterodactyl)
#       AWS_* creds (env or ~/.aws) · PANEL_HOST/WINGS_HOST/K3S_HOST (auto from tfvars)
#       STOP_SERVERS=1  → gracefully stop game containers before the volume tar (consistent
#                          world saves; used by the pre-destroy backup)
#       SKIP_IF_ABSENT=1 → if the panel is unreachable, exit 0 instead of failing (used by
#                          the pre-destroy step on a first-ever deploy)
#       RETAIN_DAILY/RETAIN_WEEKLY/RETAIN_MONTHLY  → prune knobs (def 7 / 5 / 6)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ptero-common.sh"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="${S3_BASE}/${TS}"
GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# --- AWS gate ----------------------------------------------------------------
# Nightly (no SKIP_IF_ABSENT) fails loudly if S3 is unusable; the pre-destroy step
# (SKIP_IF_ABSENT=1) skips gracefully so a deploy isn't blocked before DR is set up.
if ! { [[ -n "${AWS_ACCESS_KEY_ID:-}" || -f "$HOME/.aws/credentials" ]] && aws sts get-caller-identity >/dev/null 2>&1; }; then
  if [[ "${SKIP_IF_ABSENT:-0}" == "1" ]]; then
    log "AWS creds not configured/valid; SKIP_IF_ABSENT set → skipping backup, exiting 0"
    exit 0
  fi
  echo "FATAL: AWS creds not configured/valid (set AWS_ACCESS_KEY_ID/SECRET or ~/.aws)" >&2
  exit 1
fi

# --- reachability gate -------------------------------------------------------
if ! ssh_panel "sudo docker inspect ptero_database >/dev/null 2>&1"; then
  if [[ "${SKIP_IF_ABSENT:-0}" == "1" ]]; then
    log "panel/DB not present (${PANEL_HOST}); SKIP_IF_ABSENT set → nothing to back up, exiting 0"
    exit 0
  fi
  echo "FATAL: panel database not reachable at ${PANEL_HOST}; refusing to record an empty backup" >&2
  exit 1
fi

log "backup → ${DEST}  (git ${GIT_SHA})"

# --- optional: quiesce game servers on every node for consistent world saves -
declare -A STOPPED       # host-ip -> space-separated container names
if [[ "${STOP_SERVERS:-0}" == "1" ]]; then
  for entry in "${GAME_NODES[@]}"; do
    IFS=: read -r fqdn ip ds secret <<<"$entry"
    [[ -n "$ip" ]] || continue
    names="$(ssh_host "$ip" "sudo docker ps --format '{{.Names}}' | grep -vE '^k8s_|POD' || true" 2>/dev/null | tr '\n' ' ')"
    if [[ -n "${names// }" ]]; then
      ssh_host "$ip" "sudo docker stop -t 60 $names >/dev/null" || true
      STOPPED[$ip]="$names"; log "stopped on $(node_key "$fqdn"): $names"
    fi
  done
fi

# --- 1) panel DB (consistent dump, streamed + gzipped) -----------------------
log "dumping panel DB..."
ssh_panel "sudo docker exec ptero_database sh -c 'exec mariadb-dump --single-transaction --routines --triggers --databases panel -uroot -p\"\$MARIADB_ROOT_PASSWORD\"'" \
  | gzip | aws s3 cp - "${DEST}/panel-db.sql.gz"

# --- 2) panel files (compose+env+APP_KEY, panel storage, caddy certs) --------
log "archiving panel files..."
ssh_panel "sudo tar czf - --ignore-failed-read -C / opt/pterodactyl opt/ptero/panel opt/ptero/caddy" \
  | aws s3 cp - "${DEST}/panel-files.tgz"

# --- 3) per-node game-server volumes + wings-config secrets ------------------
for entry in "${GAME_NODES[@]}"; do
  IFS=: read -r fqdn ip ds secret <<<"$entry"; key="$(node_key "$fqdn")"
  [[ -n "$ip" ]] || continue
  log "archiving volumes from ${key} (${ip})..."
  ssh_host "$ip" "sudo tar czf - --ignore-failed-read -C /var/lib pterodactyl" \
    | aws s3 cp - "${DEST}/volumes-${key}.tgz"
  if ssh_k3s "$KUBECTL -n pterodactyl get secret ${secret} >/dev/null 2>&1"; then
    ssh_k3s "$KUBECTL -n pterodactyl get secret ${secret} -o jsonpath='{.data.config\.yml}' | base64 -d" \
      | aws s3 cp - "${DEST}/${secret}.yml"
  fi
done

# --- restart anything we stopped ---------------------------------------------
for ip in "${!STOPPED[@]}"; do
  ssh_host "$ip" "sudo docker start ${STOPPED[$ip]} >/dev/null" || true
  log "restarted on ${ip}: ${STOPPED[$ip]}"
done

# --- manifest ----------------------------------------------------------------
COUNTS="$(ssh_panel "sudo docker exec ptero_database sh -c 'mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" -N -e \"select concat(count(*)) from panel.servers; select concat(count(*)) from panel.nodes; select concat(count(*)) from panel.users\"'" 2>/dev/null | paste -sd, || echo '?')"
printf '{"timestamp":"%s","git_sha":"%s","servers_nodes_users":"%s"}\n' "$TS" "$GIT_SHA" "$COUNTS" \
  | aws s3 cp - "${DEST}/backup-manifest.json"
aws s3 cp "${DEST}/backup-manifest.json" "${S3_BASE}/LATEST" >/dev/null   # pointer to newest good backup
log "backup complete: servers/nodes/users=${COUNTS}"
aws s3 ls "${DEST}/" | awk '{print "  "$0}'

# --- prune (GFS: keep N daily, then weekly, then monthly) --------------------
log "pruning old backups..."
aws s3 ls "${S3_BASE}/" | grep -oE '[0-9]{8}T[0-9]{6}Z' | sort -u \
  | RETAIN_DAILY="${RETAIN_DAILY:-7}" RETAIN_WEEKLY="${RETAIN_WEEKLY:-5}" RETAIN_MONTHLY="${RETAIN_MONTHLY:-6}" \
    python3 - "$TS" <<'PY' | while read -r del; do
import os, sys
from datetime import datetime, timezone
now = datetime.strptime(sys.argv[1], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
D = int(os.environ["RETAIN_DAILY"]); W = int(os.environ["RETAIN_WEEKLY"]); M = int(os.environ["RETAIN_MONTHLY"])
stamps = [s.strip() for s in sys.stdin if s.strip()]
dts = sorted({datetime.strptime(s, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc): s for s in stamps}.items(), reverse=True)
keep, seen_w, seen_m = set(), set(), set()
for dt, s in dts:
    age = (now - dt).days
    if age < D:                                   # recent: keep all
        keep.add(s)
    elif age < D + W*7:                           # weekly tier
        wk = dt.isocalendar()[:2]
        if wk not in seen_w: seen_w.add(wk); keep.add(s)
    else:                                         # monthly tier (bounded)
        mo = (dt.year, dt.month)
        if mo not in seen_m and len(seen_m) < M: seen_m.add(mo); keep.add(s)
for _, s in dts:
    if s not in keep: print(s)
PY
    [[ -n "$del" ]] && { aws s3 rm --recursive "${S3_BASE}/${del}/" >/dev/null && log "  pruned ${del}"; }
  done
log "done."
