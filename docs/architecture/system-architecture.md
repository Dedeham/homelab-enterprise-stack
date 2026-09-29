# 🏗️ System Architecture — Docker VM Design

> **Decision: Dedicated Docker VM for all apps.** TrueNAS manages storage only (ZFS).
> A lightweight Debian 12 VM runs all Docker services via plain Docker Compose.
> Proxmox acts as a thin hypervisor — managing VMs and providing isolation.

---

## Architecture Philosophy

| Principle | Implementation |
|---|---|
| **Separate storage from compute** | TrueNAS = storage (ZFS, NFS, SMB). Docker VM = apps (all services). |
| **Centralize storage** | ZFS pools managed by TrueNAS, shared via NFS to Docker VM |
| **Isolate what matters** | Hermes runs in a fully isolated VM — separate kernel, network, no shared storage |
| **Keep it simple** | Plain Docker Compose — no TrueNAS app system, no Kubernetes, no wrappers |

### Why a Separate Docker VM Instead of Running Apps in TrueNAS?

TrueNAS SCALE *can* run Docker containers, but separating apps from storage is better:

- ✅ **Independent updates** — Update TrueNAS without affecting apps, update apps without touching storage
- ✅ **Clean Docker** — `docker compose up -d` just works. No TrueNAS app system wrapper or quirks
- ✅ **Better resource control** — Set exact RAM/CPU for storage vs apps. ZFS ARC cache doesn't fight with containers
- ✅ **Snapshottable independently** — Roll back the Docker VM without rolling back storage, and vice versa
- ✅ **TrueNAS stability** — TrueNAS's app ecosystem has been volatile (Kubernetes → Docker migration, TrueCharts departure). Keeping apps separate avoids this risk
- ✅ **Portable** — The compose files work on ANY Linux host with Docker. Zero lock-in.

### NFS Overhead Is Negligible

The Docker VM and TrueNAS VM both run on the same Proxmox host. NFS traffic travels
over the internal virtual bridge (`vmbr0`) — it never leaves the physical server.
Measured latency: **~0.1 ms**. For reference, a local SSD access takes ~0.05 ms.
You will not notice any difference compared to direct ZFS access.

---

## The Full Architecture

```
┌─────────────────────────── PROXMOX VE HOST ────────────────────────────┐
│  Boot: 256 GB SSD (ext4) │ Fast storage: 512 GB SSD (LVM-Thin)        │
│                                                                        │
│  ┌─── VM: truenas (ID 110) ─── STORAGE ───────────────────────────┐   │
│  │ RAM: 14–16 GB  |  CPU: 2–4 cores  |  Boot: 32 GB on ssd-fast   │   │
│  │ Passthrough: 4× HDDs (2× 4TB mirror + 2TB + 1TB)               │   │
│  │                                                                  │   │
│  │ ┌─── ZFS POOLS ──────────────────────────────────────────────┐  │   │
│  │ │ Pool: main   (ZFS Mirror)  2× 4TB = ~3.6 TB redundant     │  │   │
│  │ │ Pool: media  (Single)      1× 2TB = ~1.8 TB expendable    │  │   │
│  │ │ Pool: scratch (Single)     1× 1TB = ~930 GB expendable    │  │   │
│  │ └────────────────────────────────────────────────────────────┘  │   │
│  │                                                                  │   │
│  │ ┌─── SERVICES (storage only) ────────────────────────────────┐  │   │
│  │ │ 📁 NFS exports      → Docker VM (/mnt/main, /mnt/media)   │  │   │
│  │ │ 📁 SMB shares       → Windows/Mac file access on LAN      │  │   │
│  │ │ 📸 ZFS snapshots    → Automatic hourly/daily/weekly        │  │   │
│  │ │ 🔧 S.M.A.R.T.      → Built-in disk health monitoring     │  │   │
│  │ │ ☁️  Cloud Sync       → Off-site backup to cloud storage    │  │   │
│  │ └────────────────────────────────────────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                    │ NFS                               │
│                                    ▼                                   │
│  ┌─── VM: docker (ID 111) ─── ALL APPS ───────────────────────────┐   │
│  │ RAM: 10–12 GB  |  CPU: 4–6 cores  |  Boot: 32 GB on ssd-fast   │   │
│  │ Debian 12 minimal + Docker Engine + Docker Compose              │   │
│  │                                                                  │   │
│  │ NFS Mounts (from TrueNAS):                                      │   │
│  │   /mnt/main  ← TrueNAS:/mnt/main   (ZFS protected pool)       │   │
│  │   /mnt/media ← TrueNAS:/mnt/media  (media pool)               │   │
│  │                                                                  │   │
│  │ ┌─── DOCKER SERVICES ────────────────────────────────────────┐  │   │
│  │ │                                                             │  │   │
│  │ │  🔀 Traefik            — Reverse proxy + auto SSL           │  │   │
│  │ │  🔐 Authelia           — 2FA authentication gateway         │  │   │
│  │ │  🛡️  CrowdSec           — Intrusion detection + IP blocking │  │   │
│  │ │  🌐 Pi-hole            — DNS ad-blocking                    │  │   │
│  │ │  🔑 Vaultwarden        — Password manager                   │  │   │
│  │ │  ☁️  Nextcloud           — Cloud storage, calendar, contacts │  │   │
│  │ │  🎬 Jellyfin           — Media streaming                    │  │   │
│  │ │  🏠 Homepage           — Server dashboard                   │  │   │
│  │ │  📊 Prometheus         — Metrics collection                 │  │   │
│  │ │  📊 Grafana            — Monitoring dashboards              │  │   │
│  │ │  🟢 Uptime Kuma        — Service uptime monitor             │  │   │
│  │ │  🔄 Watchtower         — Update notifier (monitor-only)     │  │   │
│  │ │  🗃️  MariaDB            — Database (for Nextcloud)          │  │   │
│  │ │  🗃️  Redis              — Cache (for Nextcloud)             │  │   │
│  │ │                                                             │  │   │
│  │ └─────────────────────────────────────────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                        │
│  ┌─── VM: hermes (ID 120) ─── ISOLATED ──────────────────────────┐   │
│  │ RAM: 2–4 GB  |  CPU: 1–2 cores  |  Disk: 30–40 GB on ssd-fast │   │
│  │                                                                 │   │
│  │ • Hermes agent workload                                         │   │
│  │ • Fully isolated: separate network, no shared storage           │   │
│  │ • Firewall rules: no access to TrueNAS or other VMs            │   │
│  │ • Internet access only (outbound)                               │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                        │
│  ┌─── Optional: Misc VMs ─────────────────────────────────────────┐   │
│  │                                                                 │   │
│  │ • Small Linux VMs for development, testing, VPN endpoints       │   │
│  │ • Windows VM for specific software (RDP access)                 │   │
│  │ • Allocate from remaining RAM/CPU headroom                      │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Resource Allocation

### With 32 GB Total RAM

| VM | Type | vCPUs | RAM | Disk | Storage Pool |
|---|---|---|---|---|---|
| **truenas** | VM (ID 110) | 2–4 | 14–16 GB | 32 GB boot + 4× HDD passthrough | `ssd-fast` (boot) |
| **docker** | VM (ID 111) | 4–6 | 10–12 GB | 32 GB | `ssd-fast` |
| **hermes** | VM (ID 120) | 1–2 | 2–3 GB | 30 GB | `ssd-fast` |
| Proxmox host | — | — | ~2 GB | 256 GB SSD | `local` |
| **Total allocated** | | **7–12** | **~28–33 GB** | **~126 GB SSD** | |

> [!WARNING]
> At 16 GB for TrueNAS + 12 GB Docker VM + 3 GB for Hermes + 2 GB Proxmox = **33 GB**.
> That slightly exceeds 32 GB. To fit comfortably:
> - TrueNAS 14 GB + Docker VM 10 GB + Hermes 2 GB + Proxmox 2 GB = **28 GB** ✓
> - This leaves **~2 GB** for misc VMs or overhead
> - If you need more, reduce Hermes or upgrade to 64 GB RAM in the future

### TrueNAS RAM Breakdown (storage only)

| Component | RAM Usage |
|---|---|
| TrueNAS OS + base services | ~2–3 GB |
| ZFS ARC cache | ~8–10 GB (uses whatever's available — improves read speed) |
| NFS/SMB services | ~256–512 MB |
| **Recommended total** | **14–16 GB** |

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
| **Total** | **~7–10 GB** |

> [!TIP]
> ZFS ARC is adaptive — it automatically shrinks when other processes need more RAM.
> With 14 GB, TrueNAS still gets excellent cache performance for file access.
> The Docker VM gets dedicated RAM with no ZFS competition.

---

## Service Catalog

All services run as **Docker containers** in the Docker VM (ID 111), managed via
plain `docker compose` files stored in `/opt/docker/<service>/`.

### Core Services

| Service | Category | Purpose | RAM Limit | Storage |
|---|---|---|---|---|
| **Nextcloud** | ☁️ Cloud | File sync, calendar, contacts | 2 GB | `main` pool (via NFS) |
| **Jellyfin** | 🎬 Media | Media streaming (movies, TV, music) | 4 GB | `media` pool (via NFS) |
| **Traefik** | 🔀 Proxy | Reverse proxy + auto Let's Encrypt SSL | 256 MB | Config only |
| **Vaultwarden** | 🔐 Security | Bitwarden-compatible password manager | 256 MB | `main` pool (via NFS) |

### Security & Access Control

| Service | Category | Purpose | RAM Limit | Storage |
|---|---|---|---|---|
| **Authelia** | 🔐 Auth | 2FA gateway for services without their own login | 256 MB | `main` pool (via NFS) |
| **CrowdSec** | 🛡️ IDS | Intrusion detection + community IP blocklists | 512 MB | `main` pool (via NFS) |
| **Pi-hole** | 🌐 DNS | DNS-level ad blocking for all devices | 256 MB | `main` pool (via NFS) |

### Monitoring & Management

| Service | Category | Purpose | RAM Limit | Storage |
|---|---|---|---|---|
| **Grafana** | 📊 Monitoring | Dashboards and visualization | 512 MB | Docker volume |
| **Prometheus** | 📊 Monitoring | Metrics collection + alerting (30-day retention) | 1 GB | Docker volume |
| **Uptime Kuma** | 🟢 Uptime | Service uptime monitoring + status page | 256 MB | Docker volume |
| **Scrutiny** | 💾 Disks | Hard drive S.M.A.R.T. health monitoring | 256 MB | Docker volume |
| **Homepage** | 🏠 Dashboard | Server dashboard / start page | 256 MB | `main` pool (via NFS) |
| **Watchtower** | 🔄 Updates | Monitors for image updates (notifications only — does NOT auto-update) | 128 MB | — |

### Infrastructure (internal only)

| Service | Category | Purpose | RAM Limit | Storage |
|---|---|---|---|---|
| **MariaDB** | 🗃️ Database | Database for Nextcloud (user accounts, file metadata, etc.) | 1 GB | `main` pool (via NFS) |
| **Redis** | 🗃️ Cache | Caching + file locking for Nextcloud | 300 MB | Docker volume |
| **Socket Proxy** | 🔒 Security | Filtered Docker API access (read-only) for Traefik + Homepage | 64 MB | — |

> [!NOTE]
> **Scrutiny note:** The Scrutiny *web UI* runs in the Docker VM, but the *collector*
> (which reads S.M.A.R.T. data from physical disks) needs access to real disk devices.
> Since disks are passed through to TrueNAS, you have two options:
> 1. Use TrueNAS's built-in S.M.A.R.T. monitoring (Settings → Disks → S.M.A.R.T. Tests)
> 2. Run the Scrutiny collector as a standalone container on TrueNAS

> [!NOTE]
> **Pi-hole placement:** Pi-hole runs in the Docker VM. Set your router's DNS to the
> Docker VM IP (192.168.1.20), NOT TrueNAS. If the Docker VM goes down, DNS goes down
> — but so do all your services anyway. For redundancy, set your router's secondary DNS
> to a public resolver like 1.1.1.1 or 9.9.9.9.

### Isolated (Outside Docker VM)

| Service | Where | Purpose | Why Isolated? |
|---|---|---|---|
| **Hermes** | Proxmox VM (ID 120) | Isolated AI/agent workload | Full kernel isolation, separate network |

---

## Hermes Isolation Strategy

Hermes must be **completely isolated** from TrueNAS, the Docker VM, and the normal LAN.

### Network Isolation

```
┌─── vmbr0 (Main Bridge) ──────────────────────┐
│                                                │
│  TrueNAS  (192.168.1.10) ◄──► NFS to Docker   │
│  Docker   (192.168.1.20) ◄──► LAN + Internet   │
│                                                │
└────────────────────────────────────────────────┘

┌─── vmbr1 (Isolated Bridge / VLAN 100) ────────┐
│                                                │
│  hermes (10.10.100.2) ──► Internet ONLY         │
│                                                │
│  Firewall rules:                               │
│  ✅ Outbound to internet: ALLOW                │
│  ❌ Access to 192.168.1.0/24: DENY              │
│  ❌ Access to TrueNAS: DENY                    │
│  ❌ Access to Docker VM: DENY                  │
│  ❌ Inbound traffic to Hermes: DENY             │
│                                                │
└────────────────────────────────────────────────┘
```

### Isolation Checklist

| Requirement | Implementation |
|---|---|
| Separate network | VLAN or separate bridge (`vmbr1`) |
| No access to storage | No NFS/SMB mounts, no HDD passthrough |
| No access to other VMs | Firewall rules block inter-VM traffic |
| Can't reach TrueNAS | Firewall denies traffic to TrueNAS IP |
| Can't reach Docker VM | Firewall denies traffic to Docker VM IP |
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

---

## Data Flow

```
Internet
   │
   ▼
Router (port forward 80/443 → Docker VM IP, or Cloudflare Tunnel)
   │
   ▼
┌──────────────────────────────────────────────────────────┐
│  Docker VM (192.168.1.20) — Traefik (ports 80/443)       │
│    │                                                     │
│    ├──► auth.example.com    → Authelia (2FA gateway) │
│    ├──► cloud.example.com   → Nextcloud              │
│    ├──► media.example.com   → Jellyfin               │
│    ├──► vault.example.com   → Vaultwarden            │
│    ├──► dash.example.com    → Homepage               │
│    ├──► monitor.example.com → Grafana                │
│    ├──► status.example.com  → Uptime Kuma            │
│    └──► dns.example.com     → Pi-hole admin          │
│                                                          │
│  Internal only (Docker VM):                              │
│    ├──► :9090    Prometheus                              │
│    ├──► :8082    Traefik metrics                         │
│    └──► :53      Pi-hole DNS (LAN only)                 │
│              │                                           │
│              │ NFS (internal bridge, ~0.1ms latency)     │
│              ▼                                           │
│  TrueNAS (192.168.1.10):                                │
│    ├──► /mnt/main  (ZFS mirror — all app data + files)  │
│    ├──► /mnt/media (expendable — movies, TV, music)     │
│    ├──► SMB shares (Windows/Mac file access on LAN)     │
│    └──► ZFS snapshots (automatic rollback protection)   │
└──────────────────────────────────────────────────────────┘

Hermes VM (isolated):
   └──► hermes (10.10.100.2) ──► Internet only
   (No connection to TrueNAS, Docker VM, or LAN services)
```

---

## Boot Order

| Order | VM | Delay | Reason |
|---|---|---|---|
| 1 | **TrueNAS** (ID 110) | 0s | NFS storage must be available before Docker VM mounts it |
| 2 | **Docker VM** (ID 111) | 60s | Wait for TrueNAS NFS exports to be ready |
| 3 | **hermes** (ID 120) | 90s | Wait for network to stabilize |
| — | Misc VMs | Manual | Start only when needed |

Configure in Proxmox: **VM → Options → Start at boot: Yes → Start/Shutdown order**

> [!TIP]
> The Docker VM's NFS mounts use `hard` mode — if TrueNAS isn't ready yet, the mount
> will wait and retry automatically (instead of failing). So even if boot timing is off,
> the Docker VM will recover once TrueNAS comes up.

---

## Portability & Escape Hatch

Since all services run via plain Docker Compose files, you are **never locked in** to
any specific platform. The compose files work identically on:

- Proxmox VM (current setup)
- Bare metal Debian/Ubuntu
- Any cloud VPS (Hetzner, DigitalOcean, etc.)
- Another hypervisor (VMware, Hyper-V)

### Migration Path

```
1. Install Docker on the new host
2. Copy /opt/docker/ (all compose files and configs)
3. Mount or copy your data (/mnt/main, /mnt/media)
4. docker network create proxy
5. docker compose up -d in each service directory
```

The only thing that changes between environments is where `/mnt/main` and `/mnt/media`
come from (NFS, local disk, cloud block storage). Everything else is identical.

---

## Setup Scripts

| Script | Where To Run | Purpose |
|---|---|---|
| `docs/os-and-virtualization/proxmox-manual-initial-setup.md` | Proxmox host | One-time setup: repos, IOMMU, LVM-Thin, vmbr1 |
| `docs/os-and-virtualization/ubuntu-docker-security-setup.md` | Docker VM | Active setup: Docker, NFS mounts, directories, and security controls |

---

## Summary: Why This Architecture?

| Decision | Rationale |
|---|---|
| **Separate storage from apps** | TrueNAS does storage. Docker VM does apps. Each can be updated independently. |
| **Docker VM, not Docker on Proxmox** | Container escape on the hypervisor = total compromise. A VM provides kernel isolation. |
| **NFS for storage access** | Internal bridge latency is ~0.1ms. Volume paths stay identical. Zero performance impact. |
| **Plain Docker Compose** | No TrueNAS app system wrapper, no Kubernetes, no lock-in. Standard tooling that works everywhere. |
| **Hermes isolated VM** | Full kernel isolation for the AI/agent workload. |
| **VLAN / separate bridge** | Hermes can't touch your data or services even if compromised. |
| **Proxmox as thin hypervisor** | Only job: manage VMs, provide isolation. No host-level apps or storage. |
