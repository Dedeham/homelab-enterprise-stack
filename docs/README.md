# Documentation Map

Use this file as the entry point for the docs folder.

## Start Here

Follow the guides in this order:

1. [os-and-virtualization/proxmox-manual-initial-setup.md](os-and-virtualization/proxmox-manual-initial-setup.md)
2. [os-and-virtualization/truenas-storage-pool-setup.md](os-and-virtualization/truenas-storage-pool-setup.md)
3. [security/truenas-hardening-guide.md](security/truenas-hardening-guide.md)
4. [os-and-virtualization/ubuntu-docker-security-setup.md](os-and-virtualization/ubuntu-docker-security-setup.md)
5. [os-and-virtualization/truenas-3tb-media-pool-migration-guide.md](os-and-virtualization/truenas-3tb-media-pool-migration-guide.md), only if moving media from the one-pool layout to the new 3 TB HDD
6. [backup-strategy/storage-and-backup-plan.md](backup-strategy/storage-and-backup-plan.md)
7. [services/arr-stack-homelab-fit-review-and-setup.md](services/arr-stack-homelab-fit-review-and-setup.md)
8. [services/arr-stack-leak-and-killswitch-test.md](services/arr-stack-leak-and-killswitch-test.md)
9. [services/arr-stack-gluetun-vpn-gateway-guide.md](services/arr-stack-gluetun-vpn-gateway-guide.md)
10. [monitoring/monitoring-and-updates-start-here.md](monitoring/monitoring-and-updates-start-here.md)
11. [monitoring/monitoring-and-updates-follow-up.md](monitoring/monitoring-and-updates-follow-up.md)
12. [services/ai-stack.md](services/ai-stack.md), optional: local speech recognition, vision model, and n8n

Use the table below as a topic index.

| Topic | Current file |
|---|---|
| Architecture | [architecture/system-architecture.md](architecture/system-architecture.md) |
| Current ARR deployment | [services/arr-stack-homelab-fit-review-and-setup.md](services/arr-stack-homelab-fit-review-and-setup.md) |
| ARR leak and kill-switch validation | [services/arr-stack-leak-and-killswitch-test.md](services/arr-stack-leak-and-killswitch-test.md) |
| ARR Gluetun migration | [services/arr-stack-gluetun-vpn-gateway-guide.md](services/arr-stack-gluetun-vpn-gateway-guide.md) |
| Bitmagnet local setup and Prowlarr integration | [services/bitmagnet-local-prowlarr-integration-guide.md](services/bitmagnet-local-prowlarr-integration-guide.md) |
| Bitmagnet Gluetun IP leak test | [services/bitmagnet-gluetun-ip-leak-test.md](services/bitmagnet-gluetun-ip-leak-test.md) |
| Debrid streaming to Infuse | [services/debrid-zurg-rclone-jellyfin-infuse-guide.md](services/debrid-zurg-rclone-jellyfin-infuse-guide.md) |
| Jellyfin Intel iGPU passthrough and local appdata | [services/jellyfin-intel-igpu-passthrough-and-local-appdata-guide.md](services/jellyfin-intel-igpu-passthrough-and-local-appdata-guide.md) |
| Jellyfin Live TV for German, English, and sports channels | [services/jellyfin-live-tv-germany-english-sports-guide.md](services/jellyfin-live-tv-germany-english-sports-guide.md) |
| Dispatcharr high quality streams with Gluetun | [services/dispatcharr-high-quality-streams-gluetun-guide.md](services/dispatcharr-high-quality-streams-gluetun-guide.md) |
| Emby with Traefik and domain | [services/emby-traefik-domain-guide.md](services/emby-traefik-domain-guide.md) |
| Monitoring and controlled updates | [monitoring/monitoring-and-updates-start-here.md](monitoring/monitoring-and-updates-start-here.md) |
| Monitoring post-install follow-up | [monitoring/monitoring-and-updates-follow-up.md](monitoring/monitoring-and-updates-follow-up.md) |
| Monitoring stack reference | [monitoring/monitoring-stack.md](monitoring/monitoring-stack.md) |
| AI stack (Whisper, vision model, n8n) | [services/ai-stack.md](services/ai-stack.md) |
| Reference hardware | [hardware/hardware-specs.md](hardware/hardware-specs.md) |
| Disaster recovery | [disaster-recovery.md](disaster-recovery.md) |
| Local-first user data storage | [services/user-data-storage-local-first-guide.md](services/user-data-storage-local-first-guide.md) |
| Nextcloud | [services/nextcloud-dedicated-vm-setup.md](services/nextcloud-dedicated-vm-setup.md) |
| Nextcloud SMTP and user onboarding | [services/nextcloud-smtp-user-onboarding-guide.md](services/nextcloud-smtp-user-onboarding-guide.md) |
| Pi-hole local DNS filtering | [services/pihole-local-dns-filtering-guide.md](services/pihole-local-dns-filtering-guide.md) |
| Proxmox base setup | [os-and-virtualization/proxmox-manual-initial-setup.md](os-and-virtualization/proxmox-manual-initial-setup.md) |
| TrueNAS storage setup | [os-and-virtualization/truenas-storage-pool-setup.md](os-and-virtualization/truenas-storage-pool-setup.md) |
| TrueNAS 3 TB media pool migration | [os-and-virtualization/truenas-3tb-media-pool-migration-guide.md](os-and-virtualization/truenas-3tb-media-pool-migration-guide.md) |
| Docker VM setup | [os-and-virtualization/ubuntu-docker-security-setup.md](os-and-virtualization/ubuntu-docker-security-setup.md) |
| Network reference | [networking/network-reference.md](networking/network-reference.md) |
| Networking | [networking/networking-plan.md](networking/networking-plan.md) |
| SSL/TLS for homestack services | [networking/ssl-traefik-cloudflare-guide.md](networking/ssl-traefik-cloudflare-guide.md) |
| Jellyfin public access through Cloudflare Tunnel | [networking/jellyfin-cloudflare-tunnel-public-access-guide.md](networking/jellyfin-cloudflare-tunnel-public-access-guide.md) |
| Seerr public access through Cloudflare Tunnel | [networking/seerr-cloudflare-tunnel-public-access-guide.md](networking/seerr-cloudflare-tunnel-public-access-guide.md) |
| Security hub | [security/security-hardening.md](security/security-hardening.md) |
| Backup strategy | [backup-strategy/storage-and-backup-plan.md](backup-strategy/storage-and-backup-plan.md) |

## Active Versus Reference

Active docs are the files you should follow during setup. Reference docs explain background, alternatives, or later-stage services.

| Folder | Status |
|---|---|
| `architecture/` | Active overview |
| `os-and-virtualization/` | Active setup sequence |
| `services/` | Active ARR and Hermes docs plus optional media references |
| `networking/` | Active, but note the correction banner in `networking-plan.md` |
| `security/` | Security hub plus component-specific guides |
| `monitoring/` | Active baseline plus later-stage reference |
| `backup-strategy/` | Active planning reference |

## Design Rules

- TrueNAS is treated as storage only.
- Docker services run on the Ubuntu Docker VM.
- Internet exposure steps belong at the end of service guides, not at the beginning.
