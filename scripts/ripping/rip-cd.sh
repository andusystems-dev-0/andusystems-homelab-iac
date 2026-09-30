#!/usr/bin/env bash
# Rip the inserted audio CD to the Jellyfin music library, then trigger a Jellyfin scan + eject.
# Invoked by anduripper.service, which is started by the udev rule on audio-CD insert (or run
# by hand: `sudo systemctl start anduripper`). Logs to /var/log/anduripper.log.
set -uo pipefail
LOG=/var/log/anduripper.log
exec >>"$LOG" 2>&1
echo "==================== $(date -u '+%F %T UTC') rip start ===================="

# Optional Jellyfin scan config (JELLYFIN_URL, JELLYFIN_TOKEN). See anduripper.env.example.
[ -f /etc/anduripper.env ] && . /etc/anduripper.env

if ! blkid /dev/sr0 >/dev/null 2>&1 && [ ! -e /dev/sr0 ]; then
  echo "no optical device at /dev/sr0 — abort"; exit 0
fi

# Rip: -N = non-interactive (auto-pick the first MusicBrainz match) for a hands-off flow.
abcde -N -c /etc/abcde.conf -d /dev/sr0
rc=$?
echo "abcde exit=$rc"

# NFS is all_squash→nobody; make sure everything is readable by Jellyfin.
chown -R nobody:nogroup /srv/media/music 2>/dev/null || true
chmod -R a+rX /srv/media/music 2>/dev/null || true

# Trigger an immediate Jellyfin library scan if a token is configured; otherwise Jellyfin's
# scheduled scan will pick it up on its next run.
if [ -n "${JELLYFIN_URL:-}" ] && [ -n "${JELLYFIN_TOKEN:-}" ]; then
  # -k: internal, token-authenticated scan trigger (the in-cluster edge may present a cert this
  # host doesn't chain to); the API token is the real auth and this only kicks off a library scan.
  if curl -fsS -k -m 20 -X POST "${JELLYFIN_URL%/}/Library/Refresh" -H "X-Emby-Token: ${JELLYFIN_TOKEN}"; then
    echo "jellyfin scan triggered"
  else
    echo "jellyfin scan request failed (check JELLYFIN_URL/JELLYFIN_TOKEN)"
  fi
else
  echo "no /etc/anduripper.env token set — relying on Jellyfin's scheduled library scan"
fi

eject /dev/sr0 2>/dev/null || true
echo "==================== $(date -u '+%F %T UTC') rip done (rc=$rc) ===================="
