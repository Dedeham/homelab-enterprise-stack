# TrueNAS And Proxmox Backup Strategy

Last updated: 2026-06-24

This describes the backup strategy for the current homelab layout.

| Component | Value |
|---|---|
| Proxmox host | `192.168.1.2` |
| Ubuntu Docker VM | `192.168.1.20` |
| Dedicated Nextcloud VM | `192.168.1.30` if deployed |
| TrueNAS VM | `192.168.1.10` |
| TrueNAS role | Storage only |
| Docker role | Containers and service runtime |
| Main pool | `main`, mirrored 4 TB HDDs |
| Important data path | `/mnt/main/appdata` |
| Backup staging path | `/mnt/main/backups` |
| Current media path | `/mnt/main/media/data`, mounted on Docker VM as `/mnt/media/data` |

## The Important Rule

A TrueNAS mirror is not a backup.

The mirror protects against one HDD failing. It does not protect against accidental deletion, bad container updates, ransomware or corrupted files, a broken command that overwrites data, theft, fire, water or power damage, or losing the whole server.

For this repo's current design, protection is split as follows:

| Data | Primary protection | Real backup target |
|---|---|---|
| Proxmox host config | Manual config export | Off-server copy |
| TrueNAS VM boot disk | Proxmox backup | Proxmox Backup Server or external/off-server storage |
| Ubuntu Docker VM boot disk | Proxmox backup | Proxmox Backup Server or external/off-server storage |
| Dedicated Nextcloud VM boot disk | Proxmox backup | Proxmox Backup Server or external/off-server storage |
| TrueNAS pool data | TrueNAS snapshots | Replication, cloud sync, or external disk |
| `/mnt/main/appdata` | TrueNAS snapshots plus database dumps | Replication, cloud sync, or external disk |
| `/mnt/main/backups` | TrueNAS snapshots | Replication, cloud sync, or external disk |
| Compose files and `.env` files | Git plus encrypted secret backup | Password manager or encrypted off-server copy |

Proxmox backups do not replace TrueNAS backups. Because the HDDs are passed through to the TrueNAS VM, Proxmox backs up the VM boot disks, not the ZFS pool data stored on those physical drives.

## What Is Backed Up In TrueNAS

TrueNAS owns the data disks, so TrueNAS protects the data.

| Dataset | Path | Priority | Why |
|---|---|---:|---|
| `main/appdata` | `/mnt/main/appdata` | Critical | Docker configs, service state, and container databases |
| `main/backups` | `/mnt/main/backups` | Critical | Database dumps, config exports, recovery files |
| `main/nextcloud` | `/mnt/main/nextcloud` | Critical if used | User files |
| `main/userdata` | `/mnt/main/userdata` | Critical if used | Human documents, photos, and shared files |
| `main/media/data` | `/mnt/main/media/data` | Optional | Media/downloads; usually less critical |

If a service stores state in a Docker named volume on the Docker VM instead of `/mnt/main/appdata`, that data is not protected by TrueNAS snapshots. Such service state should either be moved to a bind mount under `/mnt/main/appdata/SERVICE`, or covered by a separate Docker volume backup job writing archives into `/mnt/main/backups/docker-volumes`.

## Layer 1: TrueNAS Snapshots

Snapshots are fast local rollback points — the first protection against accidental deletion, bad updates, and some ransomware-style damage. They are configured through TrueNAS's Periodic Snapshot Tasks.

Current schedule:

| Dataset | Recursive | Schedule | Retention |
|---|---:|---|---|
| `main/appdata` | Yes | Every 6 hours | 14 days |
| `main/backups` | Yes | Daily | 30 days |
| `main/nextcloud` | Yes | Daily | 30 days |
| `main/userdata` | Yes | Daily | 30-90 days |
| `main/media/data` | Optional | Daily or weekly | 7-14 days |

Media snapshot retention is kept short since large deleted files remain on disk while snapshots still reference them.

### Snapshot Timing For Databases

Filesystem snapshots are useful, but live databases also need logical dumps. Database dumps run before the snapshot task:

| Time | Task |
|---|---|
| `01:30` | Database dump runs on the Docker VM, or on the dedicated Nextcloud VM if using the isolated deployment |
| `02:00` | TrueNAS snapshots `main/backups` and `main/appdata` |

For the standard Docker VM deployment, dumps are produced by `scripts/backup/db-backup.sh`, installed on the Docker VM (not TrueNAS, since it uses `docker exec`) and scheduled via cron. It covers Nextcloud MariaDB and Vaultwarden SQLite — any new database-backed service needs its own dump command added before relying on snapshots alone.

For the dedicated Nextcloud VM deployment, `scripts/backup/nextcloud-vm-backup.sh` runs on that VM and writes MariaDB dumps plus the local Nextcloud app/config archive to `/mnt/nc-backups`, which maps to `/mnt/main/backups/nextcloud-db` on TrueNAS.

The step-by-step installation and scheduling of these scripts is covered in `docs/setup-and-testing/monitoring-and-updates.md`.

## Layer 2: TrueNAS Off-Server Backup

Snapshots on the same mirror are not enough — at least one copy needs to live away from the main pool.

| Target | Good for | Notes |
|---|---|---|
| External USB HDD | Cheapest local backup | Disconnected or rotated after backup where possible |
| Second TrueNAS box | Best local replication | Uses ZFS replication tasks |
| Cloud storage | Best off-site option | Encrypted before upload |
| Remote server | Good if another location is available | Uses replication or encrypted `rclone` |

The recommended first version of this layer: create snapshots for `main/appdata`, `main/backups`, and user data; add an external USB drive or cloud target; back up only irreplaceable data first (`appdata`, `backups`, user documents, photos, configs); and skip paying to back up replaceable downloads unless restoring them actually matters.

### Option A: TrueNAS Replication

Used when the target is another ZFS system or a backup disk formatted for ZFS, via TrueNAS Replication Tasks. Replicated datasets:

```text
main/appdata
main/backups
main/nextcloud
main/userdata
```

`main/media/data` is not replicated by default unless the storage cost is acceptable.

### Option B: TrueNAS Cloud Sync

Used for cloud backup, via TrueNAS Cloud Sync Tasks.

| Setting | Value |
|---|---|
| Direction | Push |
| Transfer mode | Sync or Copy |
| Encryption | Enabled if available for the provider/task |
| Schedule | Daily after snapshots |
| Include | `appdata`, `backups`, `nextcloud`, `userdata` |
| Exclude | Large replaceable media and downloads |

A sync task can propagate deletions depending on mode, so snapshots still matter as an independent safety net.

## Layer 3: Proxmox Backups

Proxmox backs up the VM boot disks and VM definitions. It is not the backup for TrueNAS pool data.

VMs covered by Proxmox backup:

| VM | Back up in Proxmox? | Include |
|---|---:|---|
| TrueNAS VM | Yes | TrueNAS boot disk and VM config |
| Ubuntu Docker VM | Yes | VM boot disk, `/opt/stacks` or `/opt/docker`, local configs |
| Dedicated Nextcloud VM | Yes if deployed | VM boot disk and `/opt/docker/nextcloud` local app/config state |
| Hermes VM | Yes if used | VM boot disk and config |

For the TrueNAS VM, the passed-through HDDs are not the data Proxmox backs up — the important TrueNAS data backup happens through snapshots, replication, cloud sync, or external disk backup. The TrueNAS config is still exported after major changes.

For the Docker VM, a Proxmox backup helps rebuild the container host quickly, but it does not replace TrueNAS snapshots for `/mnt/main/appdata`. Containers using local Docker named volumes need separate backup, or should be moved to `/mnt/main/appdata`.

Recommended Proxmox targets:

| Target | Use it? | Notes |
|---|---:|---|
| Proxmox Backup Server | Best | Deduplicated, scheduled, verified backups |
| External USB disk attached to Proxmox | Good starter option | At least one copy kept away from the server |
| TrueNAS NFS share from the same TrueNAS VM | Avoid for core recovery | Circular dependency if TrueNAS is down |
| Same Proxmox boot SSD only | Not enough | Useful only for temporary convenience |

Basic schedule:

| Backup | Schedule | Retention |
|---|---|---|
| Docker VM | Daily | 7-14 days |
| TrueNAS VM boot disk | Weekly or after config changes | 4-8 copies |
| Proxmox `/etc/pve` config export | After major changes | Keep latest off-server |

## TrueNAS Config Backup

After creating pools, shares, users, snapshot tasks, replication tasks, or cloud sync tasks, the TrueNAS config is exported (System Settings → General → Manage Configuration → Download File) and stored in at least two places: a password manager or encrypted archive, and an off-server backup location. Relying only on the TrueNAS boot disk is avoided — if it dies, a config export makes recovery much faster.

## Appdata Backup State

The baseline this strategy targets:

- `/mnt/main/appdata` is a TrueNAS dataset.
- The Docker VM mounts `/mnt/main` from `192.168.1.10:/mnt/main`.
- Services use bind mounts under `/mnt/main/appdata/SERVICE`.
- Any remaining Docker named volumes are documented.
- `scripts/backup/db-backup.sh` runs successfully on the Docker VM if Docker-VM Nextcloud or Vaultwarden are deployed.
- `scripts/backup/nextcloud-vm-backup.sh` runs successfully on the dedicated Nextcloud VM if that deployment path is used.
- Database dumps appear under `/mnt/main/backups/db`, or under `/mnt/main/backups/nextcloud-db` for the dedicated Nextcloud VM.
- TrueNAS snapshots include `main/appdata` and `main/backups`.
- A copy of critical datasets exists outside the main server.
- TrueNAS config has been exported.
- Proxmox VM backups are scheduled to a non-circular target.

## Restore Testing

A backup is not proven until a restore works. Restore tests are run quarterly:

| Test | Where | Success condition |
|---|---|---|
| Restore one file from snapshot | TrueNAS | File opens and has expected contents |
| Restore one database dump to a test database | Docker VM | App can read the restored database |
| Restore one file from off-server backup | Backup target | Downloaded/restored file matches original |
| Restore Docker VM backup | Proxmox test VM or maintenance window | VM boots and mounts TrueNAS |
| Import TrueNAS config | Maintenance test or documented dry run | Config file location is known |

The step-by-step restore procedures and the minimum initial setup checklist are in `docs/setup-and-testing/monitoring-and-updates.md`.
