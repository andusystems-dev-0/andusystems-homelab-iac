# CD auto-rip → Jellyfin

Insert an audio CD into the host's optical drive (passed through to the NAS VM as `/dev/sr0`)
and it is ripped to FLAC, tagged from MusicBrainz, written to the Jellyfin music library on the
NAS (`/srv/media/music`), scanned into Jellyfin, and the disc is ejected — hands-off.

## How it works
- **NAS VM** (`terraform/layers/layer-0-storage`) exports `/srv/media` over NFS; Jellyfin mounts
  it (`apps/jellyfin` → `persistence.media.existingClaim: jellyfin-media-nfs`).
- **Optical drive**: the bulk host's `/dev/sr0` is passed into the NAS VM
  (`qm set <nas-vmid> -ide2 /dev/sr0,media=cdrom`).
- **`99-autorip.rules`** fires only for discs with audio tracks → starts **`anduripper.service`**
  → **`rip-cd.sh`** (abcde, config in `abcde.conf`) → Jellyfin scan → eject.

## One-time setup (yours)
1. Run the installer on the NAS:
   ```
   scp -r scripts/ripping ubuntu@<nas-ip>:/tmp/ && ssh ubuntu@<nas-ip> 'sudo bash /tmp/ripping/setup-nas-ripper.sh'
   ```
2. Open Jellyfin (`https://jellyfin.andusystems.com`), finish the first-run wizard (create your
   admin account), and add libraries pointing at the mounted NFS:
   - **Music** → `/media/music`   · **Movies** → `/media/movies`   · **Shows** → `/media/shows`
3. (Optional, for *instant* scans) Jellyfin → Dashboard → API Keys → create one, then on the NAS
   put it in `/etc/anduripper.env` (`JELLYFIN_URL` + `JELLYFIN_TOKEN`). Without it, Jellyfin's
   scheduled scan still picks up new rips.

## Use
- **Just insert an audio CD.** Watch progress: `ssh <nas> 'tail -f /var/log/anduripper.log'`.
- Manual trigger: `ssh <nas> 'sudo systemctl start anduripper'`.
- Ingest existing files: SMB share `\\<nas-ip>\media` (drop into `music/`, `movies/`, `shows/`).

## Video later
DVDs/Blu-rays use MakeMKV + HandBrake into `/srv/media/movies` (or `shows`) — same Jellyfin scan.
Not wired yet (audio CDs only for now).
