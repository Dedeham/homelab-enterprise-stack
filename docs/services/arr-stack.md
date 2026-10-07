# ARR Stack

The ARR stack is the local-first media automation stack: Prowlarr (indexer management), Radarr (movies), Sonarr (TV), qBittorrent (download client), Jellyfin (playback), and Seerr (request UI), plus optional helpers (FlareSolverr, Bazarr, Recyclarr, Unpackerr, RDTClient). It replaces older broad ARR drafts and is treated as the source of truth for the current deployment.

## Design Principles

- Everything is set up on the home LAN first. Internet exposure is a later, optional phase.
- TrueNAS is storage only; no containers run on it. The Ubuntu Server Docker VM runs Docker/Dockge and all media services.
- Tailscale reaches Proxmox for remote management. The Docker VM does not have Tailscale installed directly (optional later).
- The privacy-sensitive services (qBittorrent, Prowlarr, Radarr, Sonarr, FlareSolverr, and optional Bazarr/Recyclarr/Unpackerr/RDTClient) share one VPN network namespace so their indexer/search/download traffic never uses the normal LAN/ISP path.
- Jellyfin and Seerr are playback/request services, not torrent/indexer clients, so they stay on normal Docker networking.
- Public exposure (Cloudflare Tunnel or reverse proxy) is considered last, and only for Jellyfin/Seerr if desired.

## Network Model

```text
Home LAN: 192.168.1.0/24
  Router:       192.168.1.1
  Proxmox:      192.168.1.2
  TrueNAS:      192.168.1.10
  Docker VM:    192.168.1.20

Isolated network: 10.10.100.0/24
  Gateway:      10.10.100.1
  Hermes:       10.10.100.2 (isolated; must not mount TrueNAS storage)
```

Tailscale's current remote entry point is Proxmox. `100.64.0.0/10` firewall rules on the Docker VM only apply if the Docker VM joins Tailscale directly or a subnet router is configured to preserve Tailscale client source IPs.

## VPN Architecture

Two supported designs exist for the privacy-sensitive services:

**hotio qBittorrent VPN (current default).** qBittorrent itself owns the PIA WireGuard tunnel and firewall (hotio's `VPN_PROVIDER=pia` mode). Prowlarr, Radarr, Sonarr, and FlareSolverr use `network_mode: "service:qbittorrent"` so they share qBittorrent's network namespace and egress through the same tunnel. Because they share one namespace, these apps reach each other over `127.0.0.1` rather than Docker service names.

```text
qBittorrent hotio container
+-- owns PIA WireGuard
+-- publishes qBittorrent and ARR UI ports
+-- shared by Prowlarr, Radarr, Sonarr, FlareSolverr
```

**Gluetun VPN gateway (optional alternative).** A dedicated `qmcgaw/gluetun` container owns the VPN tunnel, DNS, and firewall. qBittorrent, Prowlarr, Radarr, Sonarr, FlareSolverr, and optional helpers (Bazarr, Recyclarr, Unpackerr, RDTClient) use `network_mode: "service:gluetun"` and no longer publish their own ports; Gluetun publishes all shared UI ports instead.

```text
Gluetun
+-- owns VPN tunnel and firewall
+-- publishes qBittorrent and ARR UI ports
+-- shared by qBittorrent, Prowlarr, Radarr, Sonarr, FlareSolverr
```

Gluetun is worth switching to when the VPN gateway should be separated from the download client, more VPN-routed download clients will be added, or the VPN provider needs to be swapped without replacing qBittorrent. hotio's bundled VPN is simpler to run day one because it supports PIA WireGuard directly.

For Private Internet Access specifically, Gluetun's documented, straightforward path is OpenVPN (`VPN_SERVICE_PROVIDER=private internet access`, `OPENVPN_USER`, `OPENVPN_PASSWORD`); PIA WireGuard through Gluetun requires the custom-provider path and is treated as an advanced variant. OpenVPN is usually slower than WireGuard but architecturally cleaner.

Neither design routes Jellyfin or Seerr through the VPN; they use normal Docker networking (`arr` bridge network) because they are not torrent/indexer clients.

## Storage Layout

All ARR/download containers mount one shared data root as `/data`, which lets Radarr/Sonarr and the download client use hardlinks and atomic moves (same filesystem/dataset):

```text
/mnt/media/data
+-- torrents
|   +-- incomplete
|   +-- movies
|   +-- tv
+-- usenet
|   +-- incomplete
|   +-- movies
|   +-- tv
+-- media
    +-- movies
    +-- tv
    +-- music
```

Jellyfin mounts the final media directories read-only under `/media/movies`, `/media/tv`, `/media/music` — a separate, read-focused mount from the ARR `/data/...` tree.

App configs/databases live separately from media, under `/mnt/main/appdata/arr-stack` (per-app subdirectories: `prowlarr`, `radarr`, `sonarr`, `seerr`, `jellyfin`, `qbittorrent/wireguard`, `flaresolverr`, `bazarr`, `recyclarr`, `unpackerr`), backed by TrueNAS NFS. Keeping downloads and final media as directories under one dataset (not separate child datasets) is required for hardlinks to work.

Stack files live on the Docker VM at `/opt/stacks/arr-stack/compose.yaml` and `/opt/stacks/arr-stack/.env`.

## Ports And URLs

| Service | Port | Notes |
|---|---:|---|
| qBittorrent Web UI | 8080 | Published on whichever container owns the VPN namespace |
| Prowlarr | 9696 | VPN-namespace shared |
| Radarr | 7878 | VPN-namespace shared |
| Sonarr | 8989 | VPN-namespace shared |
| FlareSolverr | 6767/8191 | VPN-namespace shared; internal use only, no need to expose for most indexers |
| RDTClient, optional | 6500 | VPN-namespace shared when enabled |
| Jellyfin | 8096 | Normal Docker network |
| Seerr | 5055 | Normal Docker network |
| Dockge, optional | 5001 | Normal Docker/Dockge network, admin tool with Docker socket access |

All UI ports are bound to the Docker VM LAN IP (`192.168.1.20`), not all interfaces. None of qBittorrent, Prowlarr, Radarr, Sonarr, FlareSolverr, RDTClient, Dockge, TrueNAS, or Proxmox are exposed to the public internet; Jellyfin/Seerr are the only candidates for later, deliberate public exposure.

## Environment Variables

Key `.env` values for the stack (hotio VPN variant):

```env
PUID=3000
PGID=3000
TZ=Europe/Berlin
DOCKER_IP=192.168.1.20
LAN=192.168.1.0/24
CONFIG_PATH=/mnt/main/appdata/arr-stack
DATA_PATH=/mnt/media/data
QBITTORRENT_VERSION=release-5.1.2
PIA_USER=p1234567
PIA_PASS=***
PIA_REGION=
PIA_PORT_FORWARD=true
```

Gluetun variant adds `GLUETUN_VERSION`, PIA port-forwarding and DNS-over-TLS/HTTPS variables, and `BLOCK_MALICIOUS`/`BLOCK_SURVEILLANCE`/`BLOCK_ADS` toggles. PIA usernames start with `p...`; the PIA account email is never used as the username.

## Integration Points

- **Prowlarr → Radarr/Sonarr**: Full Sync apps, connected over `127.0.0.1` (shared VPN namespace) or the Docker VM LAN IP (if Radarr/Sonarr run outside the VPN namespace — see the split-stack design below).
- **Radarr/Sonarr → qBittorrent**: qBittorrent added as a download client with categories `movies` and `tv`, each mapped to `/data/torrents/movies` and `/data/torrents/tv`. No remote path mapping is needed because all apps see the same `/data` mount.
- **Seerr → Jellyfin/Radarr/Sonarr**: Seerr is not in the VPN namespace, so it must use the Docker VM's LAN-published URLs (`http://192.168.1.20:7878`, `:8989`) for Radarr/Sonarr, and either the Docker service name `http://jellyfin:8096` or the LAN URL for Jellyfin.
- **RDTClient (debrid)**: optionally added as a second, qBittorrent-compatible download client inside the same VPN namespace, downloading to `/data/debrid`. See [Debrid Media Stack](debrid-media-stack.md) for the broader debrid architecture.
- **Bitmagnet**: an independent DHT-crawling Torznab indexer that can be added to Prowlarr as a cross-stack "Generic Torznab" source. See [Bitmagnet](bitmagnet.md).

## Split-Stack Variant

For homelabs that want torrenting, debrid, and playback to each be independently restartable, the single ARR stack can be split into separate Compose projects:

```text
jellyfin-stack      -> jellyfin (never behind torrent/debrid VPN)
arr-control-stack   -> radarr, sonarr, optional prowlarr (normal Docker networking)
torrent-stack       -> torrent-gluetun + qbittorrent, optional flaresolverr/prowlarr
debrid-stack        -> debrid-gluetun + rdt-client
```

In this layout, Radarr/Sonarr no longer share a download client's VPN namespace; they reach qBittorrent and RDTClient through the Docker VM's LAN-published ports (`192.168.1.20:8080`, `192.168.1.20:6500`) instead of `127.0.0.1`. This trades the strict "every ARR app is VPN-routed" privacy model for independent lifecycle management of each stack. Only one Radarr/Sonarr pair should ever run — duplicating them duplicates databases, quality profiles, and import history.

## Recommended Service Set

| Service | Include initially | Reason |
|---|---:|---|
| Prowlarr | Yes | Central indexer management for Radarr/Sonarr |
| Radarr | Yes | Movies |
| Sonarr | Yes | TV shows |
| qBittorrent with VPN | Yes | Download client with VPN enforcement |
| Jellyfin | Yes | Local playback and library validation |
| Seerr | Yes, after Jellyfin works | Request UI |
| FlareSolverr | Yes, internal only | Only for indexers that require it; no LAN port needed |
| Bazarr | Optional profile | Subtitles |
| Recyclarr | Optional profile | Syncs TRaSH quality profiles |
| Unpackerr | Optional profile | Extracts archived downloads |
| Gluetun | Not initially | Cleaner VPN gateway separation; adopt later if needed |
| Qui, Profilarr, Watchtower, Dozzle | No | Extra unauthenticated surface, auto-update risk, or Docker-socket exposure not worth it initially |

## Known Privacy Limits

No VPN setup hides that the home connection is talking to the VPN provider — the ISP can see the destination IP and encrypted traffic volume. A torrent VPN only protects containers that either share its network namespace or use a separate VPN/proxy path; it does not automatically cover Jellyfin or Seerr metadata lookups, which still use the normal Docker VM network path unless redesigned separately. DNS-over-TLS/HTTPS hides DNS query contents from the ISP but not the final destination IPs of non-VPN traffic.
