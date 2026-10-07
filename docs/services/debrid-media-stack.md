# Debrid Media Stack

The debrid media stack covers two related but separate debrid workflows layered on top of the ARR stack: **RDTClient local-disk automation** (download debrid-provider results into the normal ARR library) and **Zurg/rclone cloud-first streaming** (mount a debrid library directly for playback without downloading everything first). Both are optional add-ons; the ARR stack (Prowlarr/Radarr/Sonarr/qBittorrent/Jellyfin) remains the source of truth for automation state.

## Workflow A: RDTClient Local-Disk Debrid

```text
Prowlarr -> Radarr/Sonarr -> RDTClient -> Debrid provider -> /data/debrid
                                      |
                                      v
                         Radarr/Sonarr import to /data/media
                                      |
                                      v
                                  Jellyfin
```

RDTClient is a qBittorrent-compatible debrid downloader (Real-Debrid, TorBox, AllDebrid, Premiumize, or DebridLink). It downloads over HTTPS from the debrid provider rather than joining a BitTorrent swarm directly, which reduces — but does not eliminate — privacy exposure: the ISP can still see connections to the debrid provider if RDTClient is not VPN-routed.

RDTClient is added as a **second** download client alongside qBittorrent in Radarr/Sonarr, never as a replacement for a working single Radarr/Sonarr pair — duplicate ARR instances create duplicate databases, root folders, quality profiles, and import histories.

### Is A VPN Necessary For RDTClient?

Not technically. RDTClient's HTTPS download from the debrid provider does not join a torrent swarm, so a VPN is a privacy choice, not a functional requirement. The current design keeps RDTClient on RDTClient's own direct Docker network path for better throughput, while qBittorrent (true torrenting) stays behind its VPN.

### Current Deployment: Independent Debrid Stack

RDTClient runs in its own Compose project, independent of the main ARR stack, with its own Gluetun VPN gateway:

| Service | Purpose |
|---|---|
| `debrid-gluetun` | Own VPN gateway, DNS path, and kill switch for debrid traffic |
| `debrid-rdt-client` | RDTClient sharing `debrid-gluetun`'s network namespace |

```text
/opt/stacks/debrid-stack
  docker-compose.yml
  .env

/mnt/main/appdata/debrid-stack
  rdt-client
  gluetun

/mnt/media/data
  debrid
  media
  torrents
  usenet
```

RDTClient's port (`6500`) is published on `debrid-gluetun`, not on `rdt-client`, because RDTClient shares Gluetun's network namespace. This stack does not run Radarr, Sonarr, Prowlarr, Jellyfin, or qBittorrent — those stay in the main ARR stack (or a split `arr-control-stack`/`torrent-stack`) so there is exactly one Radarr/Sonarr pair and one import history.

### RDTClient Configuration

| Setting | Value |
|---|---|
| Provider | Real-Debrid, TorBox, AllDebrid, Premiumize, or DebridLink |
| API token | Stored only in app config, never committed to git |
| Download path | `/data/debrid` |
| qBittorrent-compatible API | Enabled |
| Port | `6500` |

Radarr/Sonarr add RDTClient as a qBittorrent-type download client named distinctly (e.g. `RDTClient Debrid Movies`/`RDTClient Debrid TV`) so grabs can be told apart from true torrent grabs. If Radarr/Sonarr share RDTClient's VPN namespace, they connect over `127.0.0.1:6500`; if they run on normal Docker networking (split-stack design), they use the Docker VM's LAN IP (`192.168.1.20:6500`).

### Split-Stack Architecture

For independent start/stop of torrenting, debrid, and playback, the ARR stack can be split by lifecycle:

```text
jellyfin-stack      -> jellyfin
arr-control-stack   -> radarr, sonarr, optional prowlarr (normal Docker networking)
torrent-stack        -> torrent-gluetun + qbittorrent
debrid-stack         -> debrid-gluetun + rdt-client
```

Two separate Gluetun instances are used deliberately — sharing one Gluetun between torrent and debrid would couple both paths, so a VPN-gateway failure in one breaks the other too. In this split, Radarr/Sonarr run on normal Docker networking (not inside either VPN namespace) and reach both download clients over the Docker VM's LAN-published ports (`192.168.1.20:8080` for qBittorrent, `192.168.1.20:6500` for RDTClient). This trades the single-stack's strict "every ARR app is VPN-routed" privacy model for independent restartability.

### Why RDTClient Can Be Slow Through A VPN

If RDTClient is VPN-routed, the path becomes `Docker VM -> VPN tunnel -> VPN exit region -> debrid CDN/provider -> back through VPN -> storage`, which adds latency/MTU/DNS overhead versus a direct HTTPS path. Common causes: congested VPN region, poor CDN routing for the VPN exit, MTU mismatches, slow VPN DNS resolution, Gluetun DNS-over-TLS handshake resets (switch `DNS_UPSTREAM_RESOLVER_TYPE` from `dot` to `doh` if logs show repeated `:853` resets), insufficient concurrency, or NFS write bottlenecks.

## Workflow B: Zurg/rclone Cloud-First Streaming

This is a separate, optional streaming path for fast playback from a debrid library (e.g. on iPhone/Apple TV via Infuse) without first downloading every file into the normal ARR library.

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

Zurg is Real-Debrid-specific; other providers (TorBox, AllDebrid, Premiumize, DebridLink) need their own native WebDAV support or mount tool instead of assuming this exact Zurg compose applies. A no-server fallback (`Infuse -> debrid provider WebDAV` directly) is simpler but loses Jellyfin's metadata, watched-state, and multi-user control.

### Stack Role Separation

| Stack | Purpose | Keep separate from |
|---|---|---|
| `torrent-stack` | qBittorrent and torrent VPN path | Debrid mount playback |
| `debrid-stack` | RDTClient download/import automation | Zurg/rclone streaming mount |
| `debrid-mount-stack` | Zurg plus rclone cloud-first streaming | Torrenting and RDTClient |
| `jellyfin-stack` | Playback server and metadata | Download clients |

Jellyfin never downloads media — it only reads library paths.

### Path Layout

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

`/mnt/media/data/media` is the normal local Jellyfin library; `/mnt/media/data/debrid` is RDTClient's local download staging; `/mnt/debrid/zurg` is the mounted cloud-first debrid library. Radarr/Sonarr root folders are never pointed at `/mnt/debrid/zurg` — the Zurg mount is playback-only.

### Jellyfin Libraries

Existing local libraries (`/media/movies`, `/media/tv`, `/media/music`) stay as-is. Separate cloud-first libraries are added on top:

| Jellyfin library | Container path | Host path |
|---|---|---|
| Debrid Movies | `/media/debrid/movies` | `/mnt/debrid/zurg/movies` |
| Debrid TV | `/media/debrid/tv` | `/mnt/debrid/zurg/shows` |

Keeping these separate from the local ARR libraries makes it possible to tell whether playback is coming from local disk or the debrid mount.

### Should Zurg Use The VPN?

Default: no. Zurg/rclone stream from the debrid provider over HTTPS; routing that through a VPN usually hurts playback speed because the provider/CDN sees the VPN exit instead of the home connection. Torrenting (qBittorrent) stays behind its VPN regardless — this is a separate decision about provider-HTTPS playback traffic.

### Infuse On iPhone

Recommended path: `Infuse -> Jellyfin -> /media/debrid/*`, using the LAN or Tailscale Jellyfin URL, since this preserves Jellyfin's users/watched-state/metadata control. An alternative, LAN/Tailscale-only path connects Infuse directly to Zurg's WebDAV endpoint (`http://192.168.1.20:9999/dav`) — this is never exposed publicly.

### What Comet Is (Not Used Here)

Comet is a Stremio/Kodi-style torrent/debrid search add-on that can scrape sources, rank results, and proxy debrid streams — it is not a media server and not a Jellyfin/Infuse replacement. It is relevant only to a separate, later experiment outside the Jellyfin/Infuse workflow described here.

## Why Two Debrid Workflows Are Kept Separate

Decypharr, Zurg, and rclone-style cloud-first mounts are not the default fit for this homelab's library design: files aren't guaranteed to persist locally, playback depends on debrid/cloud availability, and mount/symlink behavior adds another failure mode versus Jellyfin's local-library model. The local-disk RDTClient workflow (Option A) is the default; the Zurg/rclone mount (Option B) is kept as a deliberate, separate streaming experiment rather than the primary library source.

## References

- [RDTClient](https://github.com/rogerfar/rdt-client)
- [Decypharr](https://i-am-puid-0.github.io/DMB/services/decypharr/)
- [Debrid services comparison](https://github.com/fynks/debrid-services-comparison)
- [Zurg](https://github.com/debridmediamanager/zurg-testing)
- [rclone mount](https://rclone.org/commands/rclone_mount/)
- [Comet](https://github.com/g0ldyy/comet)
