# Services

Descriptions of each service as currently deployed. Setup and testing procedures are in [setup-and-testing/services/](../setup-and-testing/services/).

## Media

| Service | Description |
|---|---|
| [ARR Stack](arr-stack.md) | Automated media acquisition behind a Gluetun VPN gateway |
| [Bitmagnet](bitmagnet.md) | Local DHT indexer feeding Prowlarr |
| [Debrid Media Stack](debrid-media-stack.md) | RDTClient local-disk automation and Zurg/rclone cloud-first streaming |
| [Dispatcharr](dispatcharr.md) | Live TV M3U/XMLTV curation for Jellyfin, with optional VPN egress |
| [Jellyfin](jellyfin.md) | Media server with Intel Quick Sync passthrough and local appdata |
| [Emby](emby.md) | Optional media server beside Jellyfin, routed through Traefik |

## Files and Productivity

| Service | Description |
|---|---|
| [Nextcloud](nextcloud.md) | File sync and sharing, including SMTP and user onboarding |
| [User Data Storage](user-data-storage.md) | TrueNAS user datasets, SMB access, and backups |

## Other

| Service | Description |
|---|---|
| [AI Stack](ai-stack.md) | Local speech recognition, vision model, and n8n |
| [Hermes](hermes.md) | Isolated agent deployment and dashboard access |
| [Pi-hole](pihole.md) | LAN DNS filtering and local DNS records |

## Current Rules

- Containers run on the Ubuntu Docker VM, not TrueNAS.
- Nextcloud may run in its own VM when isolation from the Docker VM matters.
- TrueNAS provides storage over NFS/SMB only.
- Management access is LAN and Tailscale only.
- Internet exposure is last and should be limited to Jellyfin and Seerr if enabled.
