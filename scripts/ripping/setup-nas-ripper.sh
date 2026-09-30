#!/usr/bin/env bash
# Install the CD auto-rip pipeline onto the NAS VM. Idempotent — safe to re-run.
# Run on the NAS:  sudo bash setup-nas-ripper.sh   (from the copied scripts/ripping dir)
set -euo pipefail
cd "$(dirname "$0")"
export DEBIAN_FRONTEND=noninteractive

echo "[ripper] installing packages..."
apt-get update -qq
apt-get install -y -qq abcde flac cd-discid cdparanoia eject vorbis-tools curl >/dev/null

echo "[ripper] installing config + script + unit + udev rule..."
install -m 0644 abcde.conf                 /etc/abcde.conf
install -m 0755 rip-cd.sh                   /usr/local/bin/rip-cd.sh
install -m 0644 anduripper.service          /etc/systemd/system/anduripper.service
install -m 0644 99-autorip.rules            /etc/udev/rules.d/99-autorip.rules
[ -f /etc/anduripper.env ] || install -m 0600 anduripper.env.example /etc/anduripper.env

systemctl daemon-reload
udevadm control --reload-rules
udevadm trigger --subsystem-match=block --sysname-match=sr0 || true

echo "[ripper] done."
echo "  - Insert an audio CD → it auto-rips to /srv/media/music and ejects."
echo "  - Manual run:  sudo systemctl start anduripper   (watch: tail -f /var/log/anduripper.log)"
echo "  - For INSTANT Jellyfin scans, put your API key in /etc/anduripper.env."
