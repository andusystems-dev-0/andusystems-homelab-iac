#!/usr/bin/env bash
# Restore Pterodactyl from an S3 backup produced by backup-pterodactyl.sh.
#   restore-pterodactyl.sh [latest|<YYYYMMDDTHHMMSSZ>]   (default: latest)
#
# Rebuilds the split topology: PANEL on the panel VM (docker-compose panel+db+cache+caddy)
# and WINGS as the k3s DaemonSet on the wings node. APP_KEY is restored with the panel
# files, so the node's daemon token stays valid — no re-registration.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ptero-common.sh"

WANT="${1:-latest}"
if [[ "$WANT" == "latest" ]]; then
  TS="$(aws s3 ls "${S3_BASE}/" | grep -oE '[0-9]{8}T[0-9]{6}Z' | sort | tail -1)"
  [[ -n "$TS" ]] || { echo "No backups found under ${S3_BASE}/" >&2; exit 1; }
else
  TS="$WANT"
fi
SRC="${S3_BASE}/${TS}"
aws s3 ls "${SRC}/panel-db.sql.gz" >/dev/null 2>&1 || { echo "Backup ${SRC} incomplete/missing" >&2; exit 1; }
log "restoring from ${SRC}"

# --- panel VM: docker + stop any existing stack -----------------------------
ssh_panel "command -v docker >/dev/null || (curl -fsSL https://get.docker.com | sudo sh)"
ssh_panel "cd /opt/pterodactyl 2>/dev/null && sudo docker compose down 2>/dev/null || true"

# --- 1) panel files (compose+env+APP_KEY, panel storage, caddy certs) --------
log "restoring panel files..."
aws s3 cp "${SRC}/panel-files.tgz" - | ssh_panel "sudo tar xzf - -C /"

# --- 2) DB: bring up mariadb+redis, then load the dump -----------------------
log "starting database + cache..."
ssh_panel "sudo bash -c 'cd /opt/pterodactyl && docker compose up -d database cache'"
ssh_panel "for i in \$(seq 1 40); do [ \"\$(sudo docker inspect ptero_database --format '{{.State.Health.Status}}' 2>/dev/null)\" = healthy ] && break; sleep 3; done"
log "loading panel DB..."
aws s3 cp "${SRC}/panel-db.sql.gz" - | gunzip \
  | ssh_panel "sudo docker exec -i ptero_database sh -c 'exec mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\"'"

# --- 3) bring up panel + TLS front ------------------------------------------
log "starting panel + caddy..."
ssh_panel "sudo bash -c 'cd /opt/pterodactyl && docker compose up -d panel && docker compose --profile tls up -d tls'"

# --- 4) game-server volumes onto the wings node ------------------------------
log "restoring game-server volumes to wings node..."
ssh_wings "sudo mkdir -p /var/lib/pterodactyl"
aws s3 cp "${SRC}/volumes.tgz" - | ssh_wings "sudo tar xzf - -C /var/lib"

# --- 5) wings-config Secret (node token) -------------------------------------
if aws s3 ls "${SRC}/wings-config.yml" >/dev/null 2>&1; then
  log "recreating wings-config secret..."
  ssh_k3s "$KUBECTL create namespace pterodactyl --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null"
  aws s3 cp "${SRC}/wings-config.yml" - \
    | ssh_k3s "$KUBECTL create secret generic wings-config -n pterodactyl --from-file=config.yml=/dev/stdin --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null"
fi

# --- 6) inject the panel LAN address into wings (direct panel<->wings) -------
log "waiting for wings DaemonSet + injecting panel hostAlias..."
ssh_k3s "for i in \$(seq 1 40); do $KUBECTL -n pterodactyl get ds/wings >/dev/null 2>&1 && break; sleep 5; done
$KUBECTL -n pterodactyl patch daemonset wings --type merge -p '{\"spec\":{\"template\":{\"spec\":{\"hostAliases\":[{\"ip\":\"${PANEL_HOST}\",\"hostnames\":[\"pterodactyl.andusystems.com\"]}]}}}}' >/dev/null 2>&1 || true
$KUBECTL -n pterodactyl rollout restart daemonset/wings >/dev/null 2>&1 || true"

# --- 7) verify node online ---------------------------------------------------
log "verifying node online..."
ssh_panel "sudo docker exec ptero_panel php artisan tinker --execute='\$n=\Pterodactyl\Models\Node::first(); try{ \$s=app(\Pterodactyl\Repositories\Wings\DaemonConfigurationRepository::class)->setNode(\$n)->getSystemInformation(); echo \"NODE ONLINE — wings v\".(\$s[\"version\"]??\"?\"); }catch(\Throwable \$e){ echo \"node not yet reachable: \".substr(\$e->getMessage(),0,100); }'" 2>/dev/null | tail -2
log "restore complete from ${TS}."
