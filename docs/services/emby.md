# Emby

Emby runs as an additional media server alongside Jellyfin, reachable at `https://emby.example.com` through Traefik. It exists so a second media-server option is available without disturbing the existing Jellyfin deployment.

## Placement And Architecture

| Item | Value |
|---|---|
| Docker VM | VM `111`, `192.168.1.20` |
| Traefik stack path | `/opt/docker/traefik` |
| Emby stack path | `/opt/stacks/emby-stack` |
| Emby config path | `/srv/appdata/emby` (local Docker VM storage) |
| Media data root | `/mnt/media/data` (TrueNAS NFS) |
| Movies / TV / Music | `/mnt/media/data/media/{movies,tv,music}` |
| Container UID/GID | `3000:3000` |
| `GIDLIST` (video/render groups) | `44,991` (verify per host) |
| Shared Docker proxy network | `proxy` |
| Emby hostname | `emby.example.com` |
| Emby internal HTTP port | `8096` |

Emby's active database, metadata, logs, and transcode cache live on local Docker VM storage (`/srv/appdata/emby`), the same pattern used for Jellyfin; the media library itself stays on TrueNAS. `emby.example.com` is used instead of reusing Jellyfin's hostname so both services can run side by side.

## Network Exposure

Emby is placed on the `proxy` Docker network with no `ports:` section and no `network_mode: host` — Traefik is the only entrypoint, reaching the container on its internal port `8096`. The `8920` HTTPS port is not needed because Traefik terminates TLS. Host ports `8096`/`8920` are never published, Emby is never placed behind the torrent/VPN container network, and UPnP/automatic port mapping is disabled.

Traefik routing uses:

- `Host(\`emby.${DOMAIN}\`)` on the `websecure` entrypoint with the `cloudflare` cert resolver.
- The `security-headers@file` and `rate-limit@file` middlewares.

Local DNS (Pi-hole) resolves `emby.example.com` to `192.168.1.20`. Public access, when enabled, is layered on later through the same Cloudflare Tunnel used for Jellyfin, pointed at `traefik:443` (never directly at the Emby container), with a cache-bypass rule for the Emby hostname.

## Users And Access

Each person has a separate Emby account; the admin account is reserved for administration, not day-to-day watching. Remote access is disabled for users who don't need it. Authelia is not placed in front of Emby by default, to avoid breaking Emby clients that don't support an extra login layer.

## Hardware Transcoding

Once the shared Intel iGPU passthrough (see the Jellyfin docs) is working on VM `111`, Emby is given access to `/dev/dri` via `devices: - /dev/dri:/dev/dri` and the numeric `video`/`render` groups through the `GIDLIST` environment variable (Emby's official image uses `UID`/`GID`/`GIDLIST`, not the `PUID`/`PGID` convention used elsewhere in this homelab). Transcoding is configured under **Dashboard → Playback → Transcoding** with VAAPI/Advanced hardware acceleration pointed at `/dev/dri/renderD128`, H.264/HEVC/MPEG-2/VC-1/VP8/VP9 decode enabled, AV1 decode disabled, hardware encoding enabled, and tone mapping disabled initially.

## Backups

`/srv/appdata/emby` is local VM storage, so it is protected by Proxmox VM backups plus a periodic application-consistent tar archive copied to TrueNAS at `/mnt/main/backups/docker-volumes/emby`.
