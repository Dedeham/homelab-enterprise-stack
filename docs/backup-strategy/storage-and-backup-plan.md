# TrueNAS And Proxmox Backup Strategy

Last updated: 2026-06-24

This guide matches the current homelab layout used by the other setup guides:

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

Use this guide after:

1. [Proxmox manual initial setup](../os-and-virtualization/proxmox-manual-initial-setup.md)
2. [TrueNAS storage pool setup](../os-and-virtualization/truenas-storage-pool-setup.md)
3. [Ubuntu Docker VM setup](../os-and-virtualization/ubuntu-docker-security-setup.md)

## The Important Rule

A TrueNAS mirror is not a backup.

The mirror protects against one HDD failing. It does not protect against:

- Accidental deletion.
- Bad container updates.
- Ransomware or corrupted files.
- A broken command that overwrites data.
- Theft, fire, water damage, or power damage.
- Losing the whole server.

For this repo's current design, use this split:

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

## What To Back Up In TrueNAS

TrueNAS owns the data disks, so TrueNAS should protect the data.

Back up these datasets first:

| Dataset | Path | Priority | Why |
|---|---|---:|---|
| `main/appdata` | `/mnt/main/appdata` | Critical | Docker configs, service state, and container databases |
| `main/backups` | `/mnt/main/backups` | Critical | Database dumps, config exports, recovery files |
| `main/nextcloud` | `/mnt/main/nextcloud` | Critical if used | User files |
| `main/userdata` | `/mnt/main/userdata` | Critical if used | Human documents, photos, and shared files |
| `main/media/data` | `/mnt/main/media/data` | Optional | Media/downloads; usually less critical |

If a service stores state in a Docker named volume on the Docker VM instead of `/mnt/main/appdata`, that data is not protected by TrueNAS snapshots. Either move that service state to a bind mount under `/mnt/main/appdata/SERVICE` or add a separate Docker volume backup job that writes archives into `/mnt/main/backups/docker-volumes`.

## Layer 1: TrueNAS Snapshots

Snapshots are fast local rollback points. They are the first protection for accidental deletion, bad updates, and some ransomware-style damage.

Create them in TrueNAS:

```text
Data Protection -> Periodic Snapshot Tasks -> Add
```

Recommended starting schedule:

| Dataset | Recursive | Schedule | Retention |
|---|---:|---|---|
| `main/appdata` | Yes | Every 6 hours | 14 days |
| `main/backups` | Yes | Daily | 30 days |
| `main/nextcloud` | Yes | Daily | 30 days |
| `main/userdata` | Yes | Daily | 30-90 days |
| `main/media/data` | Optional | Daily or weekly | 7-14 days |

Keep media snapshot retention short unless you intentionally want deleted media to keep using disk space. Large deleted files remain on disk while snapshots still reference them.

### Snapshot Timing For Databases

Filesystem snapshots are useful, but live databases also need logical dumps.

Run database dumps before the snapshot task:

| Time | Task |
|---|---|
| `01:30` | Run database dump on the Docker VM, or on the dedicated Nextcloud VM if using the isolated deployment |
| `02:00` | TrueNAS snapshots `main/backups` and `main/appdata` |

For the normal Docker VM deployment, the repo contains the backup script:

```text
scripts/backup/db-backup.sh
```

Install it on the Docker VM, not on TrueNAS, because it uses `docker exec`:

```bash
sudo mkdir -p /mnt/main/scripts
sudo cp scripts/backup/db-backup.sh /mnt/main/scripts/db-backup.sh
sudo chmod 750 /mnt/main/scripts/db-backup.sh
```

Create the secrets file on the Docker VM:

```bash
sudo nano /root/.db-backup-secrets
sudo chmod 600 /root/.db-backup-secrets
```

Example contents:

```bash
DB_USER=nextcloud
DB_PASS=replace_with_the_nextcloud_database_password
```

Test manually from the Docker VM:

```bash
sudo bash /mnt/main/scripts/db-backup.sh
ls -lah /mnt/main/backups/db
```

Then schedule it with cron on the Docker VM:

```bash
sudo crontab -e
```

Add:

```cron
30 1 * * * /bin/bash /mnt/main/scripts/db-backup.sh
```

The current script covers Nextcloud MariaDB and Vaultwarden SQLite. Add more dump commands before relying on snapshots for any new database-backed service.

For the dedicated Nextcloud VM deployment, use:

```text
scripts/backup/nextcloud-vm-backup.sh
```

That script runs on the Nextcloud VM and writes MariaDB dumps plus the local
Nextcloud app/config archive to `/mnt/nc-backups`, which maps to
`/mnt/main/backups/nextcloud-db` on TrueNAS.

## Layer 2: TrueNAS Off-Server Backup

Snapshots on the same mirror are not enough. You need at least one copy away from the main pool.

Use one of these targets:

| Target | Good for | Notes |
|---|---|---|
| External USB HDD | Cheapest local backup | Disconnect or rotate it after backup if possible |
| Second TrueNAS box | Best local replication | Uses ZFS replication tasks |
| Cloud storage | Best off-site option | Use encryption before upload |
| Remote server | Good if you have another location | Use replication or encrypted `rclone` |

Recommended first version:

1. Create snapshots for `main/appdata`, `main/backups`, and user data.
2. Add an external USB drive or cloud target.
3. Back up only irreplaceable data first: `appdata`, `backups`, user documents, photos, and configs.
4. Do not spend money backing up replaceable downloads unless you actually care about restoring them.

### Option A: TrueNAS Replication

Use this if the target is another ZFS system or a backup disk formatted for ZFS.

In TrueNAS:

```text
Data Protection -> Replication Tasks -> Add
```

Replicate:

```text
main/appdata
main/backups
main/nextcloud
main/userdata
```

Do not replicate `main/media/data` by default unless you want the storage cost.

### Option B: TrueNAS Cloud Sync

Use this for cloud backup.

In TrueNAS:

```text
Data Protection -> Cloud Sync Tasks -> Add
```

Recommended settings:

| Setting | Value |
|---|---|
| Direction | Push |
| Transfer mode | Sync or Copy |
| Encryption | Enabled if available for the provider/task |
| Schedule | Daily after snapshots |
| Include | `appdata`, `backups`, `nextcloud`, `userdata` |
| Exclude | Large replaceable media and downloads |

Use a provider and retention model you understand. A sync task can propagate deletions depending on mode, so snapshots still matter.

## Layer 3: Proxmox Backups

Proxmox should back up the VM boot disks and VM definitions. It should not be treated as the backup for TrueNAS pool data.

Back up these VMs:

| VM | Back up in Proxmox? | Include |
|---|---:|---|
| TrueNAS VM | Yes | TrueNAS boot disk and VM config |
| Ubuntu Docker VM | Yes | VM boot disk, `/opt/stacks` or `/opt/docker`, local configs |
| Dedicated Nextcloud VM | Yes if deployed | VM boot disk and `/opt/docker/nextcloud` local app/config state |
| Hermes VM | Yes if used | VM boot disk and config |

For the TrueNAS VM:

- The passed-through HDDs are not the data you want Proxmox to back up.
- The important TrueNAS data backup happens through snapshots, replication, cloud sync, or external disk backup.
- Still export the TrueNAS config after major changes.

For the Docker VM:

- A Proxmox backup helps rebuild the container host quickly.
- It does not replace TrueNAS snapshots for `/mnt/main/appdata`.
- If any containers use local Docker named volumes, back those up separately or move them to `/mnt/main/appdata`.

Recommended Proxmox targets:

| Target | Use it? | Notes |
|---|---:|---|
| Proxmox Backup Server | Best | Deduplicated, scheduled, verified backups |
| External USB disk attached to Proxmox | Good starter option | Keep at least one copy away from the server |
| TrueNAS NFS share from the same TrueNAS VM | Avoid for core recovery | Circular dependency if TrueNAS is down |
| Same Proxmox boot SSD only | Not enough | Useful only for temporary convenience |

Basic schedule:

| Backup | Schedule | Retention |
|---|---|---|
| Docker VM | Daily | 7-14 days |
| TrueNAS VM boot disk | Weekly or after config changes | 4-8 copies |
| Proxmox `/etc/pve` config export | After major changes | Keep latest off-server |

Manual Proxmox config export:

```bash
tar czf /root/proxmox-config-$(date +%F).tar.gz /etc/pve
```

Copy that archive off the Proxmox host. Do not leave the only copy on the same boot disk.

## TrueNAS Config Backup

After creating pools, shares, users, snapshot tasks, replication tasks, or cloud sync tasks, export the TrueNAS config.

In TrueNAS:

```text
System Settings -> General -> Manage Configuration -> Download File
```

Store the config file in at least two places:

- Password manager or encrypted archive.
- Off-server backup location.

Do not rely only on the TrueNAS boot disk. If the TrueNAS VM boot disk dies, a config export makes recovery much faster.

## Appdata Backup Checklist

Before treating the homelab as production, confirm:

- [ ] `/mnt/main/appdata` is a TrueNAS dataset.
- [ ] The Docker VM mounts `/mnt/main` from `192.168.1.10:/mnt/main`.
- [ ] Services use bind mounts under `/mnt/main/appdata/SERVICE`.
- [ ] Any remaining Docker named volumes are documented.
- [ ] `scripts/backup/db-backup.sh` runs successfully on the Docker VM if Docker-VM Nextcloud or Vaultwarden are deployed.
- [ ] `scripts/backup/nextcloud-vm-backup.sh` runs successfully on the dedicated Nextcloud VM if that deployment path is used.
- [ ] Database dumps appear under `/mnt/main/backups/db`, or under `/mnt/main/backups/nextcloud-db` for the dedicated Nextcloud VM.
- [ ] TrueNAS snapshots include `main/appdata` and `main/backups`.
- [ ] A copy of critical datasets exists outside the main server.
- [ ] TrueNAS config has been exported.
- [ ] Proxmox VM backups are scheduled to a non-circular target.

## Restore Tests

A backup is not proven until a restore works.

Run these tests quarterly:

| Test | Where | Success condition |
|---|---|---|
| Restore one file from snapshot | TrueNAS | File opens and has expected contents |
| Restore one database dump to a test database | Docker VM | App can read the restored database |
| Restore one file from off-server backup | Backup target | Downloaded/restored file matches original |
| Restore Docker VM backup | Proxmox test VM or maintenance window | VM boots and mounts TrueNAS |
| Import TrueNAS config | Maintenance test or documented dry run | You know where the config file is |

Quick snapshot restore pattern from the Docker VM:

```bash
ls /mnt/main/.zfs/snapshot
```

If the `.zfs` directory is not visible, enable snapshot directory visibility in TrueNAS for the dataset or restore through the TrueNAS UI.

## Minimum Setup To Do Now

If you only do the essentials, do these in order:

1. Create TrueNAS snapshot tasks for `main/appdata` and `main/backups`.
2. Run database dumps into `/mnt/main/backups/db` for database-backed containers.
3. Export the TrueNAS config file.
4. Configure Proxmox backups for the TrueNAS VM boot disk and Ubuntu Docker VM.
5. Add one off-server backup target for `appdata`, `backups`, and user data.
6. Restore one test file from snapshot and one file from the off-server backup.

That gives you the practical baseline: Proxmox can restore machines, TrueNAS can restore data, and `appdata` is protected beyond the mirror.
