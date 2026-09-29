# Services Documentation Index

This directory contains service documentation for the homelab. For ARR/media automation, the current deployment path is local-first: LAN and Tailscale first, public exposure last.

## ARR Stack

Start here:

1. [ARR Stack Local-First Homelab Setup Guide](arr-stack-homelab-fit-review-and-setup.md)
   - Current source of truth.
   - Uses Ubuntu Docker VM for containers.
   - Uses TrueNAS for storage only.
   - Includes Tailscale-aware local access.
   - Defers Cloudflare/public exposure until the final phase.

2. [ARR Stack App Configuration Guide](arr-stack-app-configuration-guide.md)
   - Detailed qBittorrent, Radarr, Sonarr, Prowlarr, Jellyfin, Seerr, and local testing steps.
   - Expands phases 8 through 11 from the source-of-truth ARR guide.

3. [Jellyfin Intel iGPU Passthrough And Local Appdata Guide](jellyfin-intel-igpu-passthrough-and-local-appdata-guide.md)
   - Working Intel P630 passthrough for Docker VM `111`.
   - Configures Quick Sync and validates a real QSV transcode.
   - Moves Jellyfin SQLite appdata from TrueNAS NFS to a local virtual SSD with backup and rollback.

4. [ARR Stack Leak And Kill-Switch Test](arr-stack-leak-and-killswitch-test.md)
   - Full pre-download validation for public IP, IPv6, DNS, torrent leak, and VPN kill-switch behavior.
   - Run before adding indexers, real downloads, or debrid automation.

5. [ARR Stack Gluetun VPN Gateway Guide](arr-stack-gluetun-vpn-gateway-guide.md)
   - Later migration path from hotio qBittorrent VPN to a dedicated Gluetun gateway.
   - Includes compose pattern, port mapping, leak tests, kill-switch tests, and rollback.

6. [Bitmagnet Local Setup And Prowlarr Integration](bitmagnet-local-prowlarr-integration-guide.md)
   - Adds a local DHT indexer to the independent debrid stack.
   - Uses `debrid-gluetun`; Prowlarr connects through the Docker VM LAN address.

7. [Bitmagnet Gluetun IP Leak Test](bitmagnet-gluetun-ip-leak-test.md)
   - Verifies Bitmagnet uses the VPN IP and fails closed when Gluetun stops.
   - Confirms the direct RDTClient remains outside the Gluetun namespace.

Optional related guide:

8. [Media Automation with Debrid](media-automation-debrid.md)
   - Alternative to direct torrenting.
   - Review later if you want a debrid-based workflow.

9. [Debrid Streaming With Zurg, rclone, Jellyfin, And Infuse](debrid-zurg-rclone-jellyfin-infuse-guide.md)
   - Cloud-first playback path for iPhone/Infuse.
   - Keeps Zurg/rclone separate from the torrent and RDTClient stacks.

## Other Services

| Document | Purpose | Status |
|---|---|---|
| [AI Stack](ai-stack.md) | Local Whisper speech recognition, llama.cpp vision model, and n8n workflows | Optional |
| [Local-First User Data Storage](user-data-storage-local-first-guide.md) | TrueNAS user datasets, SMB access, optional Syncthing, and backups | Active foundation |
| [Nextcloud Dedicated VM Setup](nextcloud-dedicated-vm-setup.md) | Isolated Nextcloud VM with narrow TrueNAS NFS access and Traefik routing from the Docker VM | Preferred for stronger isolation |
| [Nextcloud SMTP And User Onboarding](nextcloud-smtp-user-onboarding-guide.md) | Outbound SMTP, domain DNS records, activation emails, invite-only onboarding, and optional registration app | Active follow-up |
| [Nextcloud Local-First Setup](nextcloud-local-first-setup.md) | Nextcloud deployment on Docker VM | Simpler alternative |
| [Jellyfin Live TV For German, English, And Sports Channels](jellyfin-live-tv-germany-english-sports-guide.md) | Legal-first no-hardware Live TV stack using Dispatcharr, Jellyfin M3U/XMLTV, and optional Mediathek downloads | Optional later-stage |
| [Dispatcharr High Quality Streams With Gluetun](dispatcharr-high-quality-streams-gluetun-guide.md) | Focused Dispatcharr setup for legal high-quality M3U sources, Gluetun routing proof, Jellyfin export checks, and kill-switch testing | Optional later-stage |
| [Emby With Traefik And Your Domain](emby-traefik-domain-guide.md) | Optional Emby deployment beside Jellyfin through Traefik and `emby.example.com` | Optional |
| [Pi-hole Local DNS and Filtering Guide](pihole-local-dns-filtering-guide.md) | LAN DNS filtering, local DNS records, blocklists, and bypass controls | Planned |
| [SSL/TLS For The Homestack](../networking/ssl-traefik-cloudflare-guide.md) | Trusted HTTPS through Traefik, Let's Encrypt, and Cloudflare DNS challenge | Later-stage |
| [Jellyfin Cloudflare Tunnel Public Access](../networking/jellyfin-cloudflare-tunnel-public-access-guide.md) | Public Jellyfin access through Cloudflare Tunnel, Traefik, and safety checks | Optional |
| [Seerr Cloudflare Tunnel Public Access](../networking/seerr-cloudflare-tunnel-public-access-guide.md) | Public Seerr request access through Cloudflare Tunnel, Traefik, Cloudflare Access, and safety checks | Optional |
| [Hermes Agents Isolated](hermes-agents-isolated.md) | Hermes isolated VM deployment notes | Active |
| [Media Server Complete Guide](media-server-complete-guide.md) | Jellyfin/media-server details | Reference |

## Current Rules

- Containers run on the Ubuntu Docker VM, not TrueNAS.
- Nextcloud may run in its own VM when isolation from the Docker VM matters.
- TrueNAS provides storage over NFS/SMB only.
- Management access is LAN and Tailscale only.
- Hermes is isolated on `10.10.100.2`.
- qBittorrent must not download until VPN verification passes.
- Internet exposure is last and should be limited to Jellyfin/Seerr if enabled.
