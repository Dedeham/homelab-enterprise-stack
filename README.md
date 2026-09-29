# Homelab Enterprise Stack

A documented blueprint for a self-hosted home server built on enterprise patterns: Proxmox
virtualization, TrueNAS storage, a hardened Docker host, no open inbound ports, two-factor
authentication in front of every service, and full monitoring.

The repository contains step-by-step guides, ready-to-deploy Docker Compose stacks, and
maintenance scripts. All addresses, domains, and user names are placeholders.

## Overview

| Area | Components |
|---|---|
| Virtualization | Proxmox VE with separate VMs for storage, services, and untrusted workloads |
| Storage | TrueNAS with ZFS, exported to the service VMs over NFS and SMB |
| Remote access | Tailscale for administration, optional Cloudflare Tunnel for public services |
| Security | Traefik v3, Let's Encrypt, Authelia, CrowdSec, Docker socket proxy, segmented networks |
| Backup | ZFS snapshots, 3-2-1 strategy, database dump scripts, disaster recovery runbook |
| Monitoring | Prometheus, Grafana, Alertmanager, cAdvisor, Scrutiny, Uptime Kuma |
| Services | Nextcloud, Vaultwarden, Jellyfin, Emby, ARR stack behind Gluetun, Pi-hole, Homepage |
| Local AI | Whisper speech recognition, llama.cpp vision model, n8n workflow automation |

## Architecture

```text
                          Internet
                             |
                   no open inbound ports
                             |
             +---------------+---------------+
             |                               |
         Tailscale                   Cloudflare Tunnel
      (administration)              (optional, public)
             |                               |
+------------+-------------------------------+------------+
| Proxmox VE host                                         |
|                                                         |
|  +----------------+        +--------------------------+ |
|  | TrueNAS VM     |  NFS   | Docker VM                | |
|  | ZFS pools      |<-------| Traefik, Authelia        | |
|  | NFS / SMB      |        | CrowdSec, monitoring     | |
|  +----------------+        | applications, AI stack   | |
|                            +--------------------------+ |
|  +----------------+                                     |
|  | Isolated VMs   |  separate VLAN, no LAN access       |
|  +----------------+                                     |
+---------------------------------------------------------+
```

See [docs/architecture/system-architecture.md](docs/architecture/system-architecture.md) for details.

## Repository Layout

```text
docs/
  architecture/            System design and topology
  os-and-virtualization/   Proxmox, TrueNAS, and Docker VM setup
  networking/              DNS, reverse proxy, Tailscale, Cloudflare Tunnel
  security/                Hardening, SSH, Authelia, CrowdSec, penetration testing
  services/                Per-service guides
  backup-strategy/         Backup plan
  monitoring/              Observability stack
  hardware/                Reference hardware
configs/
  docker/                  Docker Compose stacks with .env.example files
  dns/, firewall/, reverse-proxy/, vpn/
scripts/
  backup/                  Database and VM backup scripts
  maintenance/             Health check and Nextcloud occ wrapper
```

## Getting Started

1. Read the [documentation map](docs/README.md), which lists the guides in deployment order.
2. Set up the base system:
   [Proxmox](docs/os-and-virtualization/proxmox-manual-initial-setup.md),
   [TrueNAS](docs/os-and-virtualization/truenas-storage-pool-setup.md),
   [Docker VM](docs/os-and-virtualization/ubuntu-docker-security-setup.md).
3. Deploy the stacks in the order described in [configs/docker/README.md](configs/docker/README.md).
4. Review the [security hub](docs/security/security-hardening.md),
   [monitoring guide](docs/monitoring/monitoring-and-updates-start-here.md), and
   [backup plan](docs/backup-strategy/storage-and-backup-plan.md).

## Placeholders

Replace the following values with your own:

| Placeholder | Meaning |
|---|---|
| `example.com` | Domain |
| `192.168.1.0/24` | Home LAN |
| `192.168.1.1` | Router |
| `192.168.1.2` | Proxmox host |
| `192.168.1.10` | TrueNAS VM |
| `192.168.1.20` | Docker VM |
| `192.168.1.30` | Dedicated Nextcloud VM |
| `10.10.100.0/24` | Isolated VLAN |
| `alice`, `bob` | Example users |
| `dockeradmin`, `mediauser` | Example admin and service accounts |

Secrets are never stored in this repository. Each stack includes a `.env.example`; copy it
to `.env`, which is excluded by `.gitignore`.

## Disclaimer

These guides describe a private homelab setup. Review every command before running it, keep
current backups, and use media automation tools only for content you are legally permitted
to download.

## License

Released under the [MIT License](LICENSE).
