# Debrid Streaming With Zurg, rclone, Jellyfin, And Infuse

Last updated: 2026-06-12

This is an optional cloud-first streaming guide for the current homelab. It is
separate from [Media Automation With Debrid](media-automation-debrid.md).

Use this when you want fast playback from a debrid library on iPhone, Apple TV,
or browser without first downloading every file into the normal ARR library.

Use the existing debrid automation guide when you want Radarr/Sonarr to import
files into local storage.

Zurg is a Real-Debrid-focused tool. If your provider is TorBox, AllDebrid,
Premiumize, DebridLink, or something else, use that provider's native WebDAV
support or a provider-specific mount tool instead of assuming this exact Zurg
compose will apply.

## Short Answer

Best iPhone playback setup:

```text
Discovery/DMM -> Debrid account -> Zurg -> rclone mount -> Jellyfin -> Infuse
```

Fallback without a home server:

```text
Debrid provider WebDAV -> Infuse
```

Keep these roles separate:

| Stack | Purpose | Keep separate from |
|---|---|---|
| `torrent-stack` | qBittorrent and torrent VPN path | Debrid mount playback |
| `debrid-stack` | RDTClient download/import automation | Zurg/rclone streaming mount |
| `debrid-mount-stack` | Zurg plus rclone cloud-first streaming | Torrenting and RDTClient |
| `jellyfin-stack` | Playback server and metadata | Download clients |

Do not make Jellyfin download media. Jellyfin should only read library paths.

## Why RDTClient Downloads Can Be Slow

Yes, the VPN can be the reason RDTClient is slow.

RDTClient usually downloads from the debrid provider over HTTPS. If it is routed
through Gluetun/PIA, the path becomes:

```text
Docker VM -> VPN tunnel -> VPN exit region -> debrid CDN/provider -> back through VPN -> TrueNAS/NFS
```

That can be slower than a direct HTTPS download because of VPN exit congestion,
extra latency, MTU issues, CDN region mismatch, DNS routing through the VPN,
provider throttling of VPN IPs, or weak single-connection throughput.

Common causes:

| Cause | Symptom | Fix |
|---|---|---|
| VPN region is congested | Slow at all times from RDTClient | Try a nearby PIA region. |
| Debrid CDN picks a bad route for the VPN exit | Slow only through VPN | Test direct path and another VPN region. |
| MTU problem | Downloads start then stall or fluctuate heavily | Lower WireGuard/OpenVPN MTU in the VPN stack. |
| DNS through VPN is poor | Slow start before transfer begins | Try another VPN DNS resolver path. |
| Gluetun DNS-over-TLS resets | RDTClient logs show provider timeouts or `429`; Gluetun logs show TLS handshake resets to `:853` | Switch the debrid Gluetun DNS mode from `dot` to `doh` and retry after the provider cooldown. |
| Too little concurrency | One stream is slow, several together are faster | Tune RDTClient/provider concurrency carefully. |
| NFS/TrueNAS write bottleneck | Download speed drops when writing final files | Test local disk write speed and NFS throughput. |
| Provider-side throttling/filtering | Only some files/providers are slow | Test another legal/public-domain item. |

For debrid HTTPS downloads, a VPN is a privacy choice, not a torrent swarm
requirement. Without the VPN, your ISP can see that your server connects to the
debrid provider, but your server is not joining a BitTorrent swarm for those
provider HTTPS downloads. Keep qBittorrent behind the torrent VPN either way.

### Speed Test Checklist

Run these tests from the Docker VM.

Check the RDTClient network path:

```bash
docker exec debrid-rdt-client sh -lc 'curl -4 -fsS --max-time 15 https://ifconfig.me || wget -qO- --timeout=15 https://ifconfig.me'
```

Expected result if RDTClient is still routed through `debrid-gluetun`:

```text
PIA/VPN public IP
```

Check the VPN gateway itself:

```bash
docker exec debrid-gluetun wget -qO- --timeout=15 https://ifconfig.me
```

Check whether Gluetun DNS is the failing part:

```bash
docker logs --tail 100 debrid-gluetun | grep -E 'dns|api\.torbox|connection reset|TLS handshake' || true
```

If the logs repeatedly show DNS TLS handshake resets to `:853`, switch this
debrid stack from DNS-over-TLS to DNS-over-HTTPS:

```env
DNS_UPSTREAM_RESOLVER_TYPE=doh
DNS_UPSTREAM_RESOLVERS=cloudflare
```

Then recreate the debrid stack and retry only one item after the provider's
rate-limit window has cooled down:

```bash
cd /opt/stacks/debrid-stack
docker compose up -d
```

Compare with the Docker VM direct path:

```bash
curl -4 -fsS --max-time 15 https://ifconfig.me
```

If direct downloads are much faster than VPN-routed RDTClient downloads, the VPN
path is probably the bottleneck. For RDTClient you then choose between:

| Mode | Tradeoff |
|---|---|
| Keep RDTClient behind VPN | More private from ISP, often slower, has kill switch. |
| Run RDTClient without VPN | Faster and simpler, ISP sees debrid provider connections. |
| Try another VPN region | Keeps VPN model while improving route quality. |

Do not move qBittorrent out of the VPN path. This only discusses RDTClient and
Zurg/rclone provider HTTPS traffic.

## What Comet Is

Comet is a Stremio/Kodi-style torrent/debrid search add-on. It can scrape
sources, rank results, talk to debrid providers, and proxy debrid streams.

It is not a media server and it is not a replacement for Jellyfin or Infuse.

Use Comet if:

- you still use Stremio or Kodi as the frontend;
- you want a self-hosted add-on/search layer;
- you need debrid stream proxying for that add-on workflow.

Do not start with Comet if:

- the broken part is Stremio on iPhone;
- you want a normal Jellyfin/Infuse library;
- you want a mounted debrid library for browsing and playback.

For this homelab, Comet should be a later, separate experiment. The practical
iPhone replacement is Infuse, with Jellyfin or WebDAV behind it.

## Architecture

Recommended with home server:

```text
Browser / Debrid Media Manager
        |
        v
Debrid account torrent library
        |
        v
debrid-mount-stack
  zurg: Real-Debrid WebDAV service
  rclone: mounts zurg WebDAV to /mnt/debrid/zurg
        |
        v
jellyfin-stack
  reads /mnt/debrid/zurg as read-only libraries
        |
        v
iPhone
  Infuse connects to Jellyfin
```

Optional no-server mode:

```text
Infuse -> debrid provider WebDAV
```

No-server mode is simpler, but metadata, watched state, users, and library
control are weaker. Server mode is better if Jellyfin already exists.

## Path Layout

Keep the cloud-first mount away from the local ARR import tree:

```text
/mnt/media/data
|-- media
|   |-- movies
|   |-- tv
|   `-- music
|-- torrents
|-- debrid
`-- usenet

/mnt/debrid
`-- zurg
    |-- movies
    |-- shows
    `-- anime

/mnt/main/appdata
|-- debrid-stack
|-- debrid-mount-stack
|   |-- zurg
|   `-- rclone
`-- jellyfin
```

Important separation:

- `/mnt/media/data/media` is your normal local Jellyfin library.
- `/mnt/media/data/debrid` is RDTClient local download staging.
- `/mnt/debrid/zurg` is a mounted cloud-first debrid library.

Do not point Radarr/Sonarr root folders at `/mnt/debrid/zurg`. Treat the Zurg
mount as playback-only.

## Create Directories

Run this on the Ubuntu Docker VM:

```bash
sudo mkdir -p /opt/stacks/debrid-mount-stack
sudo chown -R "$USER":"$USER" /opt/stacks/debrid-mount-stack

sudo mkdir -p /mnt/main/appdata/debrid-mount-stack/zurg
sudo mkdir -p /mnt/main/appdata/debrid-mount-stack/rclone
sudo mkdir -p /mnt/debrid/zurg

sudo chown -R mediauser:mediauser /mnt/main/appdata/debrid-mount-stack
sudo chown -R mediauser:mediauser /mnt/debrid
```

If `mediauser` is not the user used by Jellyfin/ARR, use the same UID/GID you
already use for media services.

## Zurg Config

Create:

```text
/opt/stacks/debrid-mount-stack/config.yml
```

Example:

```yaml
zurg: v1
token: replace_with_real_debrid_token
check_for_changes_every_secs: 10
enable_repair: true
auto_delete_rar_torrents: true

directories:
  shows:
    group_order: 20
    group: media
    filters:
      - has_episodes: true

  movies:
    group_order: 30
    group: media
    only_show_the_biggest_file: true
    filters:
      - regex: /.*/
```

Do not commit the real token to git.

The public Zurg image is currently the `zurg-testing` image. The private/sponsor
Zurg image is a different image. Start with the public image unless you
intentionally choose the sponsor release.

If you later expose Zurg to Tailscale clients directly, add Zurg WebDAV
username/password settings and update `rclone.conf` with matching credentials.
For the first Jellyfin path, keep Zurg bound to the Docker VM LAN IP and let
Jellyfin/Infuse handle users.

## rclone Config

Create:

```text
/opt/stacks/debrid-mount-stack/rclone.conf
```

Use this when rclone runs in the same compose project as Zurg:

```ini
[zurg]
type = webdav
url = http://zurg:9999/dav
vendor = other
pacer_min_sleep = 0
```

## Compose: debrid-mount-stack

Create:

```text
/opt/stacks/debrid-mount-stack/compose.yaml
```

Example:

```yaml
services:
  zurg:
    image: ghcr.io/debridmediamanager/zurg-testing:latest
    container_name: zurg
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "192.168.1.20:9999:9999"
    volumes:
      - ./config.yml:/app/config.yml:ro
      - /mnt/main/appdata/debrid-mount-stack/zurg:/app/data
    networks:
      - debrid-mount
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  rclone:
    image: rclone/rclone:latest
    container_name: zurg-rclone
    restart: unless-stopped
    environment:
      TZ: Europe/Berlin
      PUID: "3000"
      PGID: "3000"
    volumes:
      - /mnt/debrid/zurg:/data:rshared
      - ./rclone.conf:/config/rclone/rclone.conf:ro
      - /mnt/main/appdata/debrid-mount-stack/rclone:/cache
    cap_add:
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    devices:
      - /dev/fuse:/dev/fuse:rwm
    depends_on:
      - zurg
    command: >
      mount zurg: /data
      --allow-other
      --allow-non-empty
      --dir-cache-time 10s
      --poll-interval 10s
      --vfs-cache-mode full
      --vfs-cache-max-size 50G
      --vfs-cache-max-age 24h
      --cache-dir /cache
      --buffer-size 64M
      --log-level INFO
    networks:
      - debrid-mount
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  debrid-mount:
    name: debrid-mount
    driver: bridge
```

Adjust these values:

| Value | Replace with |
|---|---|
| `192.168.1.20` | Docker VM LAN IP. |
| `PUID` / `PGID` | Same media UID/GID used by Jellyfin. |
| `50G` | Cache size that fits your appdata pool. |

The rclone container needs FUSE access. This is why it has `/dev/fuse`,
`SYS_ADMIN`, and `apparmor:unconfined`. Keep this stack LAN-only.

## Start And Verify

Start the stack:

```bash
cd /opt/stacks/debrid-mount-stack
docker compose config
docker compose up -d
docker compose ps
```

Check Zurg:

```bash
curl -fsS http://192.168.1.20:9999/dav/ | head
```

Check the mount:

```bash
find /mnt/debrid/zurg -maxdepth 2 -type f | head -20
```

Check logs:

```bash
docker logs --tail 100 zurg
docker logs --tail 100 zurg-rclone
```

If `/mnt/debrid/zurg` is empty, add one legal/public-domain test item to the
debrid account first, then wait for Zurg to detect it.

## Jellyfin Integration

Keep existing local Jellyfin libraries:

| Library | Existing path |
|---|---|
| Movies | `/media/movies` |
| TV Shows | `/media/tv` |
| Music | `/media/music` |

Add separate cloud-first libraries:

| Jellyfin library | Container path | Host path |
|---|---|---|
| Debrid Movies | `/media/debrid/movies` | `/mnt/debrid/zurg/movies` |
| Debrid TV | `/media/debrid/tv` | `/mnt/debrid/zurg/shows` |

Add these read-only mounts to the Jellyfin service:

```yaml
      - /mnt/debrid/zurg/movies:/media/debrid/movies:ro
      - /mnt/debrid/zurg/shows:/media/debrid/tv:ro
```

Then recreate Jellyfin:

```bash
cd /opt/stacks/jellyfin-stack
docker compose up -d
```

In Jellyfin:

1. Add a movie library named `Debrid Movies`.
2. Point it at `/media/debrid/movies`.
3. Add a TV library named `Debrid TV`.
4. Point it at `/media/debrid/tv`.
5. Disable aggressive real-time monitoring if scans cause provider/API churn.
6. Run one manual scan.

Keep these libraries separate from the local ARR libraries so you can tell
whether playback is from local disk or debrid mount.

## Infuse On iPhone

Recommended:

```text
Infuse -> Jellyfin -> /media/debrid/*
```

In Infuse:

1. Add a media server.
2. Choose Jellyfin.
3. Use the LAN or Tailscale Jellyfin URL.
4. Sign in with a Jellyfin user.
5. Let Infuse index/sync.

Use Tailscale for remote access first:

```text
http://docker-vm-tailnet-name:8096
```

Only expose Jellyfin publicly later if you deliberately choose that model.

Alternative:

```text
Infuse -> Zurg WebDAV
```

Use direct Zurg WebDAV only for private LAN/Tailscale testing. Do not expose
Zurg publicly. If you use this path, point Infuse at:

```text
http://192.168.1.20:9999/dav
```

The Jellyfin path is usually better because it gives you users, watched state,
metadata control, and a single media server for local and cloud-first libraries.

## Should Zurg Use The VPN?

Default recommendation: no.

Zurg/rclone streams from the debrid provider over HTTPS. Running that through a
VPN often hurts speed because the provider/CDN sees the VPN exit instead of your
home connection. For playback quality, direct provider HTTPS is usually faster.

Use VPN for Zurg only if you intentionally accept:

- lower throughput;
- more buffering risk;
- account/CDN routing through VPN exits;
- another kill-switch dependency for playback.

Keep torrenting behind VPN. Treat Zurg as provider HTTPS playback, not torrent
swarm traffic from your home server.

## Discovery Workflow

This guide does not make Jellyfin search the internet.

Discovery options:

| Option | Fit |
|---|---|
| Debrid Media Manager | Best simple discovery path for a Zurg library. |
| Provider website/app | Good for manual tests. |
| RDTClient/Radarr/Sonarr | Better for local import, not mounted cloud playback. |
| Comet | Better for Stremio/Kodi add-on workflow, not Jellyfin/Infuse first. |

Keep the workflows separate:

```text
Local import:
Prowlarr -> Radarr/Sonarr -> RDTClient -> /mnt/media/data/debrid -> /mnt/media/data/media -> Jellyfin

Cloud-first playback:
DMM/provider -> debrid account -> Zurg/rclone -> /mnt/debrid/zurg -> Jellyfin -> Infuse
```

## Troubleshooting

| Symptom | Check |
|---|---|
| RDTClient is slow | Compare VPN-routed speed against Docker VM direct speed. Try a different VPN region. |
| Zurg WebDAV works but mount is empty | Check `rclone.conf`, Zurg token, and whether the debrid library has test content. |
| Jellyfin sees folders but no playback | Check permissions and that the rclone mount is still active. |
| Playback buffers in Infuse | Test direct Jellyfin web playback, then increase rclone VFS cache size or avoid VPN for Zurg. |
| Jellyfin scan is very slow | Split movies and shows, reduce scan frequency, and keep mounted library separate. |
| Mount disappears after reboot | Start `debrid-mount-stack` before Jellyfin, or restart Jellyfin after the mount is ready. |
| Permission denied from rclone | Check `/dev/fuse`, `SYS_ADMIN`, `apparmor:unconfined`, and `/mnt/debrid` ownership. |
| Account complains about multiple IPs | Avoid simultaneous direct and VPN streams for the same debrid account. Pick one network path. |

## Verification Checklist

- [ ] Existing torrent stack still routes qBittorrent through VPN.
- [ ] Existing RDTClient debrid stack still works or is intentionally stopped.
- [ ] `debrid-mount-stack` starts independently.
- [ ] Zurg WebDAV responds on LAN only.
- [ ] `/mnt/debrid/zurg` lists one legal/public-domain test item.
- [ ] Jellyfin has separate `Debrid Movies` and `Debrid TV` libraries.
- [ ] Infuse connects to Jellyfin and plays one test item.
- [ ] Remote playback uses Tailscale before any public exposure.

## External References

- Zurg: https://github.com/debridmediamanager/zurg-testing
- rclone mount: https://rclone.org/commands/rclone_mount/
- Jellyfin Docker/container docs: https://jellyfin.org/docs/general/installation/container/
- Comet: https://github.com/g0ldyy/comet
