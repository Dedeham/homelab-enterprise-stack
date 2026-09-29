# 🖥️ Reference Hardware

> This is the example hardware the guides were written and tested on. Any x86_64 server
> with VT-x/VT-d, 32 GB RAM (ECC recommended), and a few SATA ports works the same way.

## CPU

| Spec | Detail |
|---|---|
| **Model** | Intel Xeon E3-1245 v6 |
| **Architecture** | Kaby Lake (14nm) |
| **Cores / Threads** | 4C / 8T |
| **Base Clock** | 3.70 GHz |
| **Turbo Clock** | 4.10 GHz |
| **TDP** | 73W |
| **Estimated Idle** | ~5–10W (CPU only), ~20–40W whole system |
| **Integrated Graphics** | Intel HD Graphics P630 |
| **ECC Support** | ✅ Yes |
| **Virtualization** | VT-x, VT-d |

### Why This CPU Works Well

- **Integrated GPU** → No need for a discrete GPU, saving ~30–75W of idle power. The P630 can
  handle hardware transcoding (Quick Sync) for media servers like Jellyfin/Plex.
- **ECC RAM support** → Critical for a 24/7 server handling important data; prevents silent
  memory corruption (bit flips) from corrupting files or ZFS/SnapRAID metadata.
- **4C/8T** → More than enough for running dozens of Docker containers, a reverse proxy,
  media transcoding, and light VM workloads simultaneously.
- **VT-d** → Enables IOMMU/PCI passthrough if you ever want to run Proxmox and pass devices
  to VMs directly.

### Power Consumption Estimate (24/7)

| State | Estimated System Draw | Monthly Cost (€0.30/kWh) |
|---|---|---|
| Idle (typical) | ~25–35W | €5.40 – €7.56 |
| Light load (Docker, NAS) | ~35–50W | €7.56 – €10.80 |
| Moderate load (transcoding) | ~60–80W | €12.96 – €17.28 |
| Full load (sustained) | ~90–110W | €19.44 – €23.76 |

> [!NOTE]
> Actual idle power depends heavily on motherboard, PSU efficiency (80+ Gold recommended),
> number of spinning HDDs, and BIOS power management (enable C-states & SpeedStep).

---

## Memory

| Spec | Detail |
|---|---|
| **Capacity** | 32 GB |
| **Type** | DDR4 ECC (Unbuffered/UDIMM) |
| **Channels** | Likely dual-channel |

### Capacity Assessment

| Workload | RAM Needed |
|---|---|
| Base OS + Docker | ~2–4 GB |
| Reverse proxy (Traefik/Nginx) | ~128–512 MB |
| Media server (Jellyfin) | ~1–2 GB |
| File sharing (Samba/NFS) | ~256–512 MB |
| Monitoring stack (Prometheus + Grafana) | ~1–2 GB |
| Home automation (Home Assistant) | ~512 MB – 1 GB |
| SnapRAID / MergerFS | ~256–512 MB |
| VMs (if running Proxmox) | 2–8 GB each |
| **Total for typical Docker-only setup** | **~8–12 GB** |
| **Remaining headroom** | **~20–24 GB** ✅ |

> [!TIP]
> 32 GB ECC is excellent. You have plenty of headroom to run VMs later or allocate RAM to
> ZFS ARC cache if you ever switch to ZFS for your boot drives.

---

## Storage — Current Inventory

| # | Type | Capacity | Interface | Intended Role |
|---|---|---|---|---|
| 1 | SSD | 256 GB | SATA (assumed) | 🟢 **OS / Boot drive** |
| 2 | SSD | 512 GB | SATA (assumed) | 🟢 **Docker volumes / App data / Databases** |
| 3 | HDD | 4 TB | SATA | 🔵 **Bulk data (media, files, backups)** |
| 4 | HDD | 2 TB | SATA | 🔵 **Bulk data** |
| 5 | HDD | 1 TB | SATA | 🔵 **Bulk data** |

### SSD Roles (Fast Tier)

| Drive | Role | Rationale |
|---|---|---|
| **256 GB SSD** | OS + Boot | Holds the operating system, swap, and system logs. 256 GB is plenty — a typical Linux server install uses 5–15 GB. |
| **512 GB SSD** | Docker volumes, databases, app configs | Containers, databases (PostgreSQL, MariaDB), and any app that benefits from fast I/O lives here. Keeps SSDs out of the MergerFS pool to avoid wearing them out with parity syncs. |

### HDD Roles (Bulk Tier) — See [Backup Strategy](../backup-strategy/storage-and-backup-plan.md)

The 3 HDDs (4TB + 2TB + 1TB) are where the important storage decisions happen.
**⚠️ You need to buy at least one more 4TB HDD** — see the backup strategy document for the full breakdown.

---

## Motherboard & Other Components

> [!IMPORTANT]
> Please provide the following details when you have them so we can verify compatibility:
> - **Motherboard** model (needs LGA 1151 v2, DDR4 ECC support, enough SATA ports)
> - **PSU** wattage and efficiency rating (80+ Gold or better recommended for 24/7)
> - **Case** (airflow matters for HDDs running 24/7)
> - **UPS** (Uninterruptible Power Supply) — **highly recommended** for protecting against
>   sudden power loss which can corrupt filesystems and RAID metadata
> - **Number of SATA ports** on motherboard (you need at least 5, ideally 6+ for future expansion)

---

## Hardware Shopping List

| Item | Why | Estimated Cost | Priority |
|---|---|---|---|
| **4 TB HDD** (e.g., WD Red Plus, Seagate IronWolf) | SnapRAID parity drive — **required** for single-drive failure protection | ~€80–110 | 🔴 **Critical** |
| **UPS** (e.g., APC Back-UPS 700VA+) | Protects against power loss corrupting data/parity | ~€60–100 | 🟠 **Highly recommended** |
| **SATA expansion card** (if needed) | Only if motherboard has fewer than 6 SATA ports | ~€15–30 | 🟡 Conditional |

> [!TIP]
> For the parity HDD, choose a NAS-rated drive (WD Red Plus / Seagate IronWolf) rather than
> a desktop drive. NAS drives are designed for 24/7 operation and have better vibration
> tolerance when running alongside other spinning disks.
