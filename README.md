# 🏢 Homelab Enterprise Stack

> Enterprise-grade patterns for a self-hosted home server: Proxmox virtualization, TrueNAS storage,
> a hardened Docker VM, zero open ports, 2FA in front of everything, and full monitoring.

This repository is a complete, documented blueprint. It contains step-by-step guides, ready-to-deploy
Docker Compose stacks, and maintenance scripts. It uses placeholder values throughout, so you can adapt it
to your own network.

## ✨ Highlights

- **Layered architecture:** Proxmox VE host → TrueNAS VM (storage only) → Ubuntu Docker VM (services) → isolated VMs for risky workloads
- **Zero open ports:** remote access through Tailscale; optional public services only through a Cloudflare Tunnel
- **Defense in depth:** Traefik v3 + Let's Encrypt, Authelia 2FA, CrowdSec, Docker socket proxy, segmented Docker networks, read-only containers
- **Data safety:** ZFS snapshots, 3-2-1 backups, database dump scripts, and a disaster-recovery runbook
- **Observability:** Prometheus, Grafana, Alertmanager, cAdvisor, Scrutiny, Uptime Kuma
- **Services:** Nextcloud, Vaultwarden, Jellyfin/Emby, ARR stack behind Gluetun, Pi-hole, Homepage
- **Local AI:** Whisper speech recognition, llama.cpp vision model, and n8n workflow automation, CPU-only by default

## 🗺️ Architecture

```text
                    Internet
                       │  (no open ports)
          ┌────────────┴─────────────┐
          │ Tailscale  │ Cloudflare  │
          │ (admin)    │ Tunnel (opt)│
          └────────────┬─────────────┘
                       │
┌──────────────────────┴───────────────────────────────┐
│ Proxmox VE host                                       │
│  ┌───────────────┐  ┌──────────────────────────────┐  │
│  │ TrueNAS VM    │  │ Ubuntu Docker VM             │  │
│  │ ZFS pools     │◄─┤ Traefik · Authelia · CrowdSec│  │
│  │ NFS / SMB     │  │ Nextcloud · Vaultwarden      │  │
│  └───────────────┘  │ Jellyfin · ARR · Pi-hole     │  │
│                     │ Monitoring · AI stack        │  │
│  ┌───────────────┐  └──────────────────────────────┘  │
│  │ Isolated VMs  │  (separate VLAN, no LAN access)    │
│  └───────────────┘                                    │
└───────────────────────────────────────────────────────┘
```

Details: [docs/architecture/system-architecture.md](docs/architecture/system-architecture.md)

## 📁 Repository Layout

```text
├── docs/                       # Guides and reference documentation
│   ├── architecture/           # System design and topology
│   ├── os-and-virtualization/  # Proxmox, TrueNAS, Docker VM setup
│   ├── networking/             # DNS, reverse proxy, Tailscale, Cloudflare Tunnel
│   ├── security/               # Hardening, SSH, Authelia, CrowdSec, pentesting
│   ├── services/               # Per-service guides (ARR, Nextcloud, Jellyfin, AI stack, ...)
│   ├── backup-strategy/        # 3-2-1 backup plan
│   ├── monitoring/             # Observability stack
│   └── hardware/               # Reference hardware
├── configs/
│   ├── docker/                 # Ready-to-deploy docker-compose stacks + .env.example files
│   └── dns/ firewall/ reverse-proxy/ vpn/
└── scripts/
    ├── backup/                 # Database and VM backup scripts
    └── maintenance/            # Health check, Nextcloud occ wrapper
```

## 🚀 Getting Started

1. Read the [documentation map](docs/README.md). It lists the guides in deployment order.
2. Set up the host: [Proxmox](docs/os-and-virtualization/proxmox-manual-initial-setup.md) → [TrueNAS](docs/os-and-virtualization/truenas-storage-pool-setup.md) → [Docker VM](docs/os-and-virtualization/ubuntu-docker-security-setup.md).
3. Deploy the stacks in the order given in [configs/docker/README.md](configs/docker/README.md).
4. Harden and monitor: [security hub](docs/security/security-hardening.md), [monitoring](docs/monitoring/monitoring-and-updates-start-here.md), [backups](docs/backup-strategy/storage-and-backup-plan.md).

## 🔧 Placeholders Used

Replace these with your own values:

| Placeholder | Meaning |
|---|---|
| `example.com` | Your domain |
| `192.168.1.0/24` | Home LAN |
| `192.168.1.1` | Router / gateway |
| `192.168.1.2` | Proxmox host |
| `192.168.1.10` | TrueNAS VM |
| `192.168.1.20` | Docker VM |
| `192.168.1.30` | Dedicated Nextcloud VM |
| `10.10.100.0/24` | Isolated VLAN for untrusted VMs |
| `alice`, `bob` | Example human users |
| `dockeradmin`, `mediauser` | Example admin and service accounts |

Secrets never live in this repo. Every stack ships a `.env.example`. Copy it to `.env`, which git ignores.

## ⚠️ Disclaimer

These guides describe a personal homelab. Review every command before running it, keep backups,
and only use media automation tools for content you are legally allowed to download.

## 📄 License

[MIT](LICENSE)
