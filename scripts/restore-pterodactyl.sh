#!/usr/bin/env bash
# Restore the Pterodactyl Panel onto the panel VM from the S3 (cold) backup.
# Usage: restore-pterodactyl.sh <panel-ip> [s3-prefix]
# The panel VM needs AWS creds (env or ~/.aws) to read the backup bucket.
set -euo pipefail
PANEL="${1:?usage: restore-pterodactyl.sh <panel-ip> [s3-prefix]}"
BK="${2:-s3://andusystems-pterodactyl-backups/2026-09-24-cold}"

ssh "ubuntu@${PANEL}" 'sudo bash -s' <<EOS
set -e
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
mkdir -p /opt/pterodactyl /var/lib/pterodactyl
aws s3 cp ${BK}/opt-pterodactyl.tgz /tmp/ && tar xzf /tmp/opt-pterodactyl.tgz -C /opt
aws s3 cp ${BK}/etc-pterodactyl.tgz /tmp/ && tar xzf /tmp/etc-pterodactyl.tgz -C /etc
aws s3 cp ${BK}/volumes-cold.tgz /tmp/ && tar xzf /tmp/volumes-cold.tgz -C /var/lib/pterodactyl
aws s3 cp ${BK}/panel-db.sql /tmp/panel-db.sql
cd /opt/pterodactyl
docker compose up -d ptero_database ptero_cache
sleep 20
docker exec -i ptero_database sh -c 'exec mariadb -uroot -p"\${MARIADB_ROOT_PASSWORD}"' < /tmp/panel-db.sql
docker compose up -d
echo "Panel restored (APP_KEY + DB + volumes intact). Re-register Wings nodes from the panel."
EOS
