# Jellyfin

Jellyfin is the primary user-facing media server for the homelab. It runs as a container on the Ubuntu Docker VM and serves Movies, TV, Music, and Live TV libraries sourced from TrueNAS.

## Placement And Architecture

| Item | Value |
|---|---|
| Proxmox host | `192.168.1.2` |
| TrueNAS VM | VM `110`, `192.168.1.10` |
| Ubuntu Docker VM | VM `111`, `192.168.1.20` |
| Jellyfin stack path | `/opt/stacks/jellyfin-stack` |
| Container UID/GID | `3000:3000` |
| Appdata (active DB/cache/logs) | `/srv/appdata/jellyfin` (local VM SSD, ext4) |
| Media mount | `/mnt/media/data` (TrueNAS NFS) |
| Movies | `/mnt/media/data/media/movies` |
| TV | `/mnt/media/data/media/tv` |
| Music | `/mnt/media/data/media/music` |
| Config backup target | `/mnt/main/backups/docker-volumes/jellyfin` |

The older template under `configs/docker/jellyfin` (`/opt/docker/jellyfin`, `/mnt/media/...`) does not match the running local-first stack and is not used.

### Why appdata lives on local disk, not NFS

Jellyfin's active SQLite database, metadata cache, and transcode cache were originally on the TrueNAS NFS mount (`/mnt/main/appdata/arr-stack/jellyfin`), which produced `SQLite Error 5: database is locked` because that storage path reported as `Network`. The active database, metadata, logs, and transcode cache now live on a dedicated local virtual disk (`/srv/appdata/jellyfin`, ext4) attached to the Docker VM, while the media library itself remains on TrueNAS NFS. The local appdata disk is covered by Proxmox VM backups plus a periodic application-consistent tar archive to `/mnt/main/backups/docker-volumes/jellyfin`.

## Intel iGPU (Quick Sync) Passthrough

The Docker VM (`111`) has an Intel HD Graphics P630 iGPU (PCI ID `8086:591d`, Proxmox address `0000:00:02.0`) passed through as a secondary PCI device.

- The VM stays on its existing legacy BIOS/default machine type (no OVMF/q35 change was needed).
- `Primary GPU` and `PCI-Express` are left disabled for the PCI device.
- No persistent `vfio-pci.ids` binding or `i915` blacklist is used; the runtime handoff works without it.
- Inside the VM, the iGPU appears as `/dev/dri/card1` / `/dev/dri/renderD128` (the virtual Bochs display is `card0`).
- The Jellyfin container is granted access via `devices: - /dev/dri:/dev/dri` and `group_add` for the host's numeric `video` (`44`) and `render` (`991`) group IDs — these must be re-verified per installation with `getent group video` / `getent group render`.

Quick Sync (QSV) is configured in Jellyfin at **Dashboard → Playback → Transcoding** with the QSV device explicitly set to `/dev/dri/renderD128` (left implicit, the virtual Bochs GPU could otherwise be selected). H.264, HEVC, MPEG-2, VC-1, VP8, VP9, and HEVC/VP9 10-bit decode are enabled; AV1 decode and HEVC RExt profiles are disabled. Hardware encoding is enabled; low-power encoding, HEVC output encoding, AV1 output encoding, and VPP/OpenCL tone mapping are left disabled initially. A real hardware transcode is confirmed by the FFmpeg command line (`-init_hw_device vaapi=...`, `-codec:v:0 h264_qsv`) in the container logs, not merely by `qsv` appearing in the encoder list. `intel_gpu_top` reporting `Failed to detect engines` in this passed-through guest is expected and does not indicate a passthrough failure.

## Live TV

Live TV is provided through legal IPTV/public M3U and XMLTV sources only (for example the iptv-org playlists, or a provider's own authorized raw M3U/XMLTV feed). Premium, DRM-gated, or app-only services (DAZN, Sky/WOW, MagentaSport, RTL+) are explicitly out of scope and are not proxied or worked around.

Pipeline:

```text
Legal IPTV/public M3U/XMLTV source
-> Dispatcharr
-> Jellyfin Live TV (via Dispatcharr's M3U/XMLTV export)
-> Jellyfin clients
```

Dispatcharr (`ghcr.io/dispatcharr/dispatcharr`) sits in front of Jellyfin rather than feeding M3U sources directly into Jellyfin, because it provides one managed place for source cleanup, EPG control, channel grouping/numbering, and a stable export. It runs on the Ubuntu Docker VM:

| Item | Value |
|---|---|
| Dispatcharr URL | `http://192.168.1.20:9191` |
| Dispatcharr appdata (`/data`) | `/srv/appdata/dispatcharr` (local VM storage, not NFS — PostgreSQL requires local `chown`) |
| Legal M3U/XMLTV source files | `/mnt/main/appdata/live-tv/sources` |
| Mediathek (yt-dlp/MediathekView) metadata | `/mnt/main/appdata/live-tv/mediathek` |
| Dispatcharr DVR recordings | `/mnt/media/data/live-tv/dispatcharr-recordings` |
| Dispatcharr backup target | `/mnt/main/backups/docker-volumes/dispatcharr` |

Channels are organized into stable numeric ranges (1-99 main German, 100-199 German regional/public, 200-299 English, 300-399 sports, 400-499 news, 500-599 kids, 900-999 test/disabled review). Dispatcharr's "Automatically enable new groups discovered on future scans" is left off so newly discovered playlist groups require manual review before reaching Jellyfin; "Auto-sync orphan cleanup" is on so channels for streams that disappear are removed automatically.

Dispatcharr is reachable only on LAN/Tailscale (`http://192.168.1.20:9191`); it is never exposed through Cloudflare Tunnel or router port forwarding. An optional Gluetun VPN gateway (`live-tv-gluetun`, a separate instance from the ARR/debrid stack's Gluetun) can route Dispatcharr's upstream M3U/XMLTV/stream requests through a VPN provider; this is only meaningful when Dispatcharr itself proxies playback (i.e. Jellyfin uses Dispatcharr-generated URLs rather than the original upstream URLs) and is not used to bypass DRM or geo-blocking.

### Optional local Mediathek archive

Separately from Live TV, permitted public-broadcaster on-demand episodes (for example, legally downloadable ZDF/ARD content) can be archived locally via `yt-dlp` (running from a dedicated virtualenv at `/mnt/main/appdata/live-tv/mediathek/venv`) or manually via MediathekView on a desktop. Saved files land under `/mnt/media/data/media/tv/Bares fuer Rares` or `/mnt/media/data/media/movies/public-broadcaster` and are picked up by Jellyfin as ordinary library media. This path only stores content when local storage is explicitly permitted by the broadcaster's terms.

## Firewall

Dispatcharr's web UI (port `9191`) is restricted to the LAN subnet via UFW on the Docker VM.
