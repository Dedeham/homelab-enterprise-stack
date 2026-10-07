# System Architecture — Docker VM Design

**Decision: dedicated Docker VM for all apps.** TrueNAS manages storage only (ZFS). A lightweight Debian 12 VM runs all Docker services via plain Docker Compose. Proxmox acts as a thin hypervisor, managing VMs and providing isolation.

## Architecture Philosophy

| Principle | Implementation |
|---|---|
| Separate storage from compute | TrueNAS = storage (ZFS, NFS, SMB). Docker VM = apps (all services). |
| Centralize storage | ZFS pools managed by TrueNAS, shared via NFS to the Docker VM |
| Isolate what matters | Hermes runs in a fully isolated VM — separate kernel, network, no shared storage |
| Keep it simple | Plain Docker Compose — no TrueNAS app system, no Kubernetes, no wrappers |

### Why a Separate Docker VM Instead of Running Apps in TrueNAS

TrueNAS SCALE can run Docker containers, but separating apps from storage is preferred:

- **Independent updates** — TrueNAS can update without affecting apps, and apps can update without touching storage.
- **Clean Docker** — `docker compose up -d` just works, with no TrueNAS app-system wrapper or quirks.
- **Better resource control** — exact RAM/CPU limits for storage vs. apps; ZFS ARC cache doesn't compete with containers.
- **Independent snapshots** — the Docker VM can be rolled back without rolling back storage, and vice versa.
- **TrueNAS stability** — TrueNAS's app ecosystem has been volatile (Kubernetes → Docker migration, TrueCharts departure); keeping apps separate avoids that churn.
- **Portability** — the compose files work on any Linux host with Docker, with zero lock-in.

### NFS Overhead

The Docker VM and TrueNAS VM both run on the same Proxmox host. NFS traffic travels over the internal virtual bridge (`vmbr0`) and never leaves the physical server. Measured latency is approximately 0.1 ms, compared to roughly 0.05 ms for local SSD access — a difference that isn't noticeable in practice.

## The Full Architecture

```
+--------------------------- PROXMOX VE HOST ----------------------------+
|  Boot: 256 GB SSD (ext4) | Fast storage: 512 GB SSD (LVM-Thin)        |
|                                                                        |
|  +--- VM: truenas (ID 110) --- STORAGE ---------------------------+   |
|  | RAM: 14–16 GB  |  CPU: 2–4 cores  |  Boot: 32 GB on ssd-fast   |   |
|  | Passthrough: 4× HDDs (2× 4TB mirror + 2TB + 1TB)               |   |
|  |                                                                  |   |
|  |  ZFS Pools:                                                     |   |
|  |    main    (ZFS Mirror)  2× 4TB = ~3.6 TB redundant            |   |
|  |    media   (Single)      1× 2TB = ~1.8 TB expendable           |   |
|  |    scratch (Single)      1× 1TB = ~930 GB expendable           |   |
|  |                                                                  |   |
|  |  Services (storage only):                                       |   |
|  |    NFS exports    → Docker VM (/mnt/main, /mnt/media)          |   |
|  |    SMB shares      → Windows/Mac file access on LAN             |   |
|  |    ZFS snapshots   → automatic hourly/daily/weekly              |   |
|  |    S.M.A.R.T.       → built-in disk health monitoring           |   |
|  |    Cloud Sync       → off-site backup to cloud storage          |   |
|  +------------------------------------------------------------------+   |
|                                    | NFS                               |
|                                    ▼                                   |
|  +--- VM: docker (ID 111) --- ALL APPS ---------------------------+   |
|  | RAM: 10–12 GB  |  CPU: 4–6 cores  |  Boot: 32 GB on ssd-fast   |   |
|  | Debian 12 minimal + Docker Engine + Docker Compose              |   |
|  |                                                                  |   |
|  |  NFS mounts (from TrueNAS):                                     |   |
|  |    /mnt/main  ← TrueNAS:/mnt/main   (ZFS protected pool)       |   |
|  |    /mnt/media ← TrueNAS:/mnt/media  (media pool)               |   |
|  |                                                                  |   |
|  |  Docker services:                                                |   |
|  |    Traefik            — reverse proxy + auto SSL                |   |
|  |    Authelia           — 2FA authentication gateway              |   |
|  |    CrowdSec           — intrusion detection + IP blocking       |   |
|  |    Pi-hole            — DNS ad-blocking                         |   |
|  |    Vaultwarden        — password manager                       |   |
|  |    Nextcloud          — cloud storage, calendar, contacts       |   |
|  |    Jellyfin           — media streaming                        |   |
|  |    Homepage           — server dashboard                       |   |
|  |    Prometheus         — metrics collection                     |   |
|  |    Grafana            — monitoring dashboards                  |   |
|  |    Uptime Kuma        — service uptime monitor                 |   |
|  |    Watchtower         — update notifier (monitor-only)         |   |
|  |    MariaDB            — database (for Nextcloud)                |   |
|  |    Redis              — cache (for Nextcloud)                   |   |
|  +------------------------------------------------------------------+   |
|                                                                        |
|  +--- VM: hermes (ID 120) --- ISOLATED --------------------------+   |
|  | RAM: 2–4 GB  |  CPU: 1–2 cores  |  Disk: 30–40 GB on ssd-fast |   |
|  |                                                                 |   |
|  | • Hermes agent workload                                         |   |
|  | • Fully isolated: separate network, no shared storage           |   |
|  | • Firewall rules: no access to TrueNAS or other VMs            |   |
|  | • Internet access only (outbound)                               |   |
|  +-----------------------------------------------------------------+   |
|                                                                        |
|  +--- Optional: misc VMs -----------------------------------------+   |
|  | • Small Linux VMs for development, testing, VPN endpoints       |   |
|  | • Windows VM for specific software (RDP access)                 |   |
|  | • Allocated from remaining RAM/CPU headroom                     |   |
|  +-----------------------------------------------------------------+   |
|                                                                        |
+------------------------------------------------------------------------+
```

## Resource Allocation

### With 32 GB Total RAM

| VM | Type | vCPUs | RAM | Disk | Storage Pool |
|---|---|---|---|---|---|
| truenas | VM (ID 110) | 2–4 | 14–16 GB | 32 GB boot + 4× HDD passthrough | `ssd-fast` (boot) |
| docker | VM (ID 111) | 4–6 | 10–12 GB | 32 GB | `ssd-fast` |
| hermes | VM (ID 120) | 1–2 | 2–3 GB | 30 GB | `ssd-fast` |
| Proxmox host | — | — | ~2 GB | 256 GB SSD | `local` |
| Total allocated | | 7–12 | ~28–33 GB | ~126 GB SSD | |

At 16 GB for TrueNAS + 12 GB for the Docker VM + 3 GB for Hermes + 2 GB for Proxmox, total allocation reaches 33 GB, which slightly exceeds 32 GB. A comfortable fit uses TrueNAS 14 GB + Docker VM 10 GB + Hermes 2 GB + Proxmox 2 GB = 28 GB, leaving roughly 2 GB headroom for misc VMs. Upgrading to 64 GB RAM removes this constraint entirely.

### TrueNAS RAM Breakdown (storage only)

| Component | RAM Usage |
|---|---|
| TrueNAS OS + base services | ~2–3 GB |
| ZFS ARC cache | ~8–10 GB (uses whatever's available — improves read speed) |
| NFS/SMB services | ~256–512 MB |
| Recommended total | 14–16 GB |

### Docker VM RAM Breakdown (all apps)

| Component | RAM Usage |
|---|---|
| Debian 12 OS | ~256 MB |
| Docker Engine | ~256 MB |
| Nextcloud + Cron | ~1.5 GB |
| Jellyfin (transcoding) | ~2–4 GB |
| MariaDB + Redis | ~1 GB |
| Monitoring stack (7 services) | ~1.5 GB |
| Traefik + Authelia + CrowdSec | ~512 MB |
| Pi-hole + Homepage + Watchtower | ~384 MB |
| Total | ~7–10 GB |

ZFS ARC is adaptive and automatically shrinks when other processes need more RAM. With 14 GB allocated, TrueNAS still gets strong cache performance for file access, and the Docker VM gets dedicated RAM with no ZFS competition.

## Service Catalog

All services run as Docker containers in the Docker VM (ID 111), managed via plain `docker compose` files stored in `/opt/docker/<service>/`.

### Core Services

| Service | Category | Purpose | RAM Limit | Storage |
|---|---|---|---|---|
| Nextcloud | Cloud | File sync, calendar, contacts | 2 GB | `main` pool (via NFS) |
| Jellyfin | Media | Media streaming (movies, TV, music) | 4 GB | `media` pool (via NFS) |
| Traefik | Proxy | Reverse proxy + auto Let's Encrypt SSL | 256 MB | Config only |
| Vaultwarden | Security | Bitwarden-compatible password manager | 256 MB | `main` pool (via NFS) |

### Security & Access Control

| Service | Category | Purpose | RAM Limit | Storage |
|---|---|---|---|---|
| Authelia | Auth | 2FA gateway for services without their own login | 256 MB | `main` pool (via NFS) |
| CrowdSec | IDS | Intrusion detection + community IP blocklists | 512 MB | `main` pool (via NFS) |
| Pi-hole | DNS | DNS-level ad blocking for all devices | 256 MB | `main` pool (via NFS) |

### Monitoring & Management

| Service | Category | Purpose | RAM Limit | Storage |
|---|---|---|---|---|
| Grafana | Monitoring | Dashboards and visualization | 512 MB | Docker volume |
| Prometheus | Monitoring | Metrics collection + alerting (30-day retention) | 1 GB | Docker volume |
| Uptime Kuma | Uptime | Service uptime monitoring + status page | 256 MB | Docker volume |
| Scrutiny | Disks | Hard drive S.M.A.R.T. health monitoring | 256 MB | Docker volume |
| Homepage | Dashboard | Server dashboard / start page | 256 MB | `main` pool (via NFS) |
| Watchtower | Updates | Monitors for image updates (notifications only — does NOT auto-update) | 128 MB | — |

### Infrastructure (internal only)

| Service | Category | Purpose | RAM Limit | Storage |
|---|---|---|---|---|
| MariaDB | Database | Database for Nextcloud (user accounts, file metadata, etc.) | 1 GB | `main` pool (via NFS) |
| Redis | Cache | Caching + file locking for Nextcloud | 300 MB | Docker volume |
| Socket Proxy | Security | Filtered Docker API access (read-only) for Traefik + Homepage | 64 MB | — |

The Scrutiny *web UI* runs in the Docker VM, but the *collector* (which reads S.M.A.R.T. data from physical disks) needs access to real disk devices. Since disks are passed through to TrueNAS, S.M.A.R.T. health is covered either by TrueNAS's built-in monitoring (Settings → Disks → S.M.A.R.T. Tests) or by running the Scrutiny collector as a standalone container on TrueNAS.

Pi-hole runs in the Docker VM. The router's DNS points to the Docker VM IP (192.168.1.20), not TrueNAS. If the Docker VM goes down, DNS goes down along with every other service it hosts, so the router's secondary DNS is set to a public resolver (1.1.1.1 or 9.9.9.9) for redundancy.

### Isolated (Outside Docker VM)

| Service | Where | Purpose | Why Isolated? |
|---|---|---|---|
| Hermes | Proxmox VM (ID 120) | Isolated AI/agent workload | Full kernel isolation, separate network |

## Hermes Isolation Strategy

Hermes is kept completely isolated from TrueNAS, the Docker VM, and the normal LAN.

### Network Isolation

```
+--- vmbr0 (Main Bridge) ----------------------+
|                                                |
|  TrueNAS  (192.168.1.10) ◄--► NFS to Docker   |
|  Docker   (192.168.1.20) ◄--► LAN + Internet   |
|                                                |
+------------------------------------------------+

+--- vmbr1 (Isolated Bridge / VLAN 100) --------+
|                                                |
|  hermes (10.10.100.2) --► Internet ONLY         |
|                                                |
|  Firewall rules:                               |
|  Outbound to internet: ALLOW                   |
|  Access to 192.168.1.0/24: DENY                |
|  Access to TrueNAS: DENY                       |
|  Access to Docker VM: DENY                     |
|  Inbound traffic to Hermes: DENY                |
|                                                |
+------------------------------------------------+
```

### Isolation Requirements

| Requirement | Implementation |
|---|---|
| Separate network | VLAN or separate bridge (`vmbr1`) |
| No access to storage | No NFS/SMB mounts, no HDD passthrough |
| No access to other VMs | Firewall rules block inter-VM traffic |
| Can't reach TrueNAS | Firewall denies traffic to the TrueNAS IP |
| Can't reach Docker VM | Firewall denies traffic to the Docker VM IP |
| No inbound access | Firewall denies unsolicited inbound traffic to Hermes |
| Internet access | Outbound NAT only — no inbound port forwarding |
| Independent lifecycle | Can start/stop/snapshot the VM independently |

### Hermes VM Template

```
OS:         Debian 12 minimal (or Ubuntu Server 22.04)
CPU:        1–2 vCPUs
RAM:        2–3 GB
Disk:       30 GB on ssd-fast (thin-provisioned)
Network:    vmbr1 (isolated bridge)
Boot order: After Docker VM (delay 90s)
IP:         10.10.100.2/24
Gateway:    10.10.100.1
```

## Data Flow

```
Internet
   |
   ▼
Router (port forward 80/443 → Docker VM IP, or Cloudflare Tunnel)
   |
   ▼
+----------------------------------------------------------+
|  Docker VM (192.168.1.20) — Traefik (ports 80/443)       |
|    |                                                     |
|    +--► auth.example.com    → Authelia (2FA gateway) |
|    +--► cloud.example.com   → Nextcloud              |
|    +--► media.example.com   → Jellyfin               |
|    +--► vault.example.com   → Vaultwarden            |
|    +--► dash.example.com    → Homepage               |
|    +--► monitor.example.com → Grafana                |
|    +--► status.example.com  → Uptime Kuma            |
|    +--► dns.example.com     → Pi-hole admin          |
|                                                          |
|  Internal only (Docker VM):                              |
|    +--► :9090    Prometheus                              |
|    +--► :8082    Traefik metrics                         |
|    +--► :53      Pi-hole DNS (LAN only)                 |
|              |                                           |
|              | NFS (internal bridge, ~0.1ms latency)     |
|              ▼                                           |
|  TrueNAS (192.168.1.10):                                |
|    +--► /mnt/main  (ZFS mirror — all app data + files)  |
|    +--► /mnt/media (expendable — movies, TV, music)     |
|    +--► SMB shares (Windows/Mac file access on LAN)     |
|    +--► ZFS snapshots (automatic rollback protection)   |
+----------------------------------------------------------+

Hermes VM (isolated):
   +--► hermes (10.10.100.2) --► Internet only
   (No connection to TrueNAS, Docker VM, or LAN services)
```

## Boot Order

| Order | VM | Delay | Reason |
|---|---|---|---|
| 1 | TrueNAS (ID 110) | 0s | NFS storage must be available before the Docker VM mounts it |
| 2 | Docker VM (ID 111) | 60s | Waits for TrueNAS NFS exports to be ready |
| 3 | hermes (ID 120) | 90s | Waits for the network to stabilize |
| — | Misc VMs | Manual | Started only when needed |

The Docker VM's NFS mounts use `hard` mode, so if TrueNAS isn't ready yet the mount waits and retries automatically instead of failing — the Docker VM recovers once TrueNAS comes up even if boot timing is off.

## Portability

Since all services run via plain Docker Compose files, the setup is never locked in to a specific platform. The compose files work identically on a Proxmox VM (current setup), bare-metal Debian/Ubuntu, any cloud VPS (Hetzner, DigitalOcean, etc.), or another hypervisor (VMware, Hyper-V). The only thing that changes between environments is where `/mnt/main` and `/mnt/media` come from (NFS, local disk, cloud block storage) — everything else is identical.

## Summary: Why This Architecture

| Decision | Rationale |
|---|---|
| Separate storage from apps | TrueNAS does storage. Docker VM does apps. Each can be updated independently. |
| Docker VM, not Docker on Proxmox | Container escape on the hypervisor would mean total compromise. A VM provides kernel isolation. |
| NFS for storage access | Internal bridge latency is ~0.1ms. Volume paths stay identical. Zero practical performance impact. |
| Plain Docker Compose | No TrueNAS app-system wrapper, no Kubernetes, no lock-in. Standard tooling that works everywhere. |
| Hermes isolated VM | Full kernel isolation for the AI/agent workload. |
| VLAN / separate bridge | Hermes can't touch data or services even if compromised. |
| Proxmox as thin hypervisor | Only job: manage VMs, provide isolation. No host-level apps or storage. |

Setup and configuration procedures for this architecture live in `docs/setup-and-testing/` (Proxmox initial setup, TrueNAS storage setup, Ubuntu Docker VM setup).
