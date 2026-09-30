#!/usr/bin/env bash
# Install the host-side CD auto-rip on the Proxmox host that has the optical drive (worker3).
# Run ON that host as root, from the copied scripts/ripping dir:
#   sudo bash setup-host-ripper.sh
# Then edit /etc/anduripper.env (NAS export + Jellyfin creds). Insert an audio CD → it rips
# to the NAS music library and scans into Jellyfin automatically.
#
# NB: this lives on the persistent Proxmox host, OUTSIDE the k3s cluster — so it survives
# cluster redeploys. (QEMU optical passthrough can't read audio CDs, so we rip on the host.)
set -euo pipefail
cd "$(dirname "$0")"
export DEBIAN_FRONTEND=noninteractive

echo "[host-ripper] installing packages..."
apt-get update -qq
apt-get install -y -qq abcde flac cd-discid cdparanoia eject nfs-common curl python3 >/dev/null

echo "[host-ripper] installing config + script + unit + udev rule..."
install -m 0644 abcde.conf         /etc/abcde.conf
install -m 0755 rip-cd.sh           /usr/local/bin/rip-cd.sh
install -m 0644 anduripper.service  /etc/systemd/system/anduripper.service
install -m 0644 99-autorip.rules    /etc/udev/rules.d/99-autorip.rules
[ -f /etc/anduripper.env ] || install -m 0600 anduripper.env.example /etc/anduripper.env

systemctl daemon-reload
udevadm control --reload-rules

echo "[host-ripper] done."
echo "  - Edit /etc/anduripper.env (NAS_EXPORT + Jellyfin admin creds)."
echo "  - Insert an audio CD → auto-rips to the NAS music library + scans into Jellyfin."
echo "  - Manual run: sudo systemctl start anduripper   (watch: tail -f /var/log/anduripper.log)"
