# CD auto-rip → Jellyfin (host-side)

Insert an audio CD into **worker3's optical drive** and it is ripped to FLAC, tagged from
MusicBrainz, written to the Jellyfin music library on the NAS (`/srv/media/music`), scanned
into Jellyfin, and ejected — hands-off.

## Why host-side (not in the NAS VM)
QEMU optical passthrough **cannot read audio CDs** — `qemu-img` tries to open the disc as a
data image to probe its format and fails with an I/O error, and media-change events don't
reach the guest. So the rip runs on the Proxmox host that physically has the drive (worker3),
which lives on the persistent layer *outside* the k3s cluster → it survives redeploys.

## How it works
- The host mounts the NAS export at `/mnt/media` (on demand, in the rip script).
- `99-autorip.rules` fires only for discs with audio tracks → `anduripper.service` →
  `rip-cd.sh` (abcde, config `abcde.conf`) → Jellyfin scan (admin auth) → eject.
- Media lives on the NAS; Jellyfin mounts it over NFS. Re-rippable, so it's out of the S3/DR set.

## One-time setup (on worker3)
```
scp -r scripts/ripping root@worker3:/tmp/ && ssh root@worker3 'bash /tmp/ripping/setup-host-ripper.sh'
ssh root@worker3 'nano /etc/anduripper.env'   # set NAS_EXPORT + Jellyfin admin creds
```
Also make sure Jellyfin is set up with a Music library at `/media/music` (done automatically by
`apps/jellyfin-seed`).

## Use
- **Insert an audio CD into worker3.** Watch: `ssh root@worker3 'tail -f /var/log/anduripper.log'`.
- Manual: `ssh root@worker3 'systemctl start anduripper'`.
- Ingest existing files: SMB `\\<nas-ip>\media` → `music/` `movies/` `shows/`.

## Video later
DVD/Blu-ray (video → MKV) would use HandBrake/MakeMKV into `/mnt/media/movies` on the same host
— same Jellyfin scan. Not wired yet (audio CDs only).
