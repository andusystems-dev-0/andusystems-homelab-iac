#!/usr/bin/env bash
# Host-side CD auto-rip: mount the NAS, rip the inserted audio CD to FLAC into the Jellyfin
# music library, trigger a Jellyfin library scan, and eject. Started by udev on audio-CD
# insert (anduripper.service), or run by hand: `sudo systemctl start anduripper`.
# Runs on the Proxmox host with the optical drive (QEMU optical passthrough cannot read audio
# CDs — qemu-img can't open them — so ripping must happen on the host, not inside a VM).
# Config: /etc/anduripper.env (NAS_EXPORT + Jellyfin creds). Logs: /var/log/anduripper.log.
set -uo pipefail
LOG=/var/log/anduripper.log
exec >>"$LOG" 2>&1
echo "==== $(date -u '+%F %T') rip start ===="
[ -f /etc/anduripper.env ] && . /etc/anduripper.env

mkdir -p /mnt/media
mountpoint -q /mnt/media || mount -t nfs4 "${NAS_EXPORT:?set NAS_EXPORT in /etc/anduripper.env}" /mnt/media \
  || { echo "NAS mount failed"; exit 0; }

cd /var/tmp
abcde -N -c /etc/abcde.conf -d /dev/sr0; rc=$?
echo "abcde rc=$rc"
chown -R nobody:nogroup /mnt/media/music 2>/dev/null || true

# Trigger an immediate Jellyfin scan (admin auth → token → refresh). -k: the in-cluster edge
# may present a cert this host doesn't chain to; the login is the real auth.
if [ -n "${JELLYFIN_URL:-}" ] && [ -n "${JELLYFIN_USER:-}" ] && [ -n "${JELLYFIN_PASS:-}" ]; then
  TOKEN=$(curl -fsS -k -m 20 -X POST "${JELLYFIN_URL%/}/Users/AuthenticateByName" \
    -H 'Content-Type: application/json' \
    -H 'Authorization: MediaBrowser Client="ripper", Device="pve", DeviceId="pve-ripper", Version="1.0"' \
    -d "{\"Username\":\"${JELLYFIN_USER}\",\"Pw\":\"${JELLYFIN_PASS}\"}" 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("AccessToken",""))' 2>/dev/null)
  if [ -n "$TOKEN" ]; then
    curl -fsS -k -m 20 -X POST "${JELLYFIN_URL%/}/Library/Refresh" -H "X-Emby-Token: $TOKEN" \
      && echo "jellyfin scan triggered" || echo "jellyfin scan request failed"
  else
    echo "jellyfin auth failed — relying on Jellyfin's scheduled scan"
  fi
fi

eject /dev/sr0 2>/dev/null || true
echo "==== $(date -u '+%F %T') rip done (rc=$rc) ===="
