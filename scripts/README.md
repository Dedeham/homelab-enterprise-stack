# Scripts Overview

> **Philosophy:** Only write scripts for tasks that aren't already handled by a built-in tool.

## What's Already Automatic (No Script Needed)

| Task | Handled By |
|---|---|
| ZFS snapshots | TrueNAS → Data Protection → Snapshots (scheduled) |
| ZFS scrubs (disk integrity check) | TrueNAS → Data Protection → Scrub Tasks |
| SSL certificate renewal | Traefik + Let's Encrypt (runs automatically) |
| Container update checks | Watchtower monitor-only (runs on schedule; updates remain manual) |
| Log rotation | Docker + systemd built-in |
| Off-site cloud backup | TrueNAS → Data Protection → Cloud Sync Tasks |
| Pi-hole blocklist updates | Pi-hole → Tools → Update Gravity (built-in) |
| Container restart on crash | `restart: unless-stopped` in every compose file |
| Monitoring & alerting | Prometheus + Alertmanager + Uptime Kuma (always-on) |
| Database migrations after update | Nextcloud auto-runs on startup |

## Scripts in This Repository

| Script | When to Run | What It Does |
|---|---|---|
| `backup/db-backup.sh` | **Daily** via TrueNAS cron (30 min before ZFS snapshot) | MariaDB dump to `/mnt/main/backups/db/` |
| `backup/nextcloud-vm-backup.sh` | **Daily** on the dedicated Nextcloud VM if that deployment path is used | MariaDB dump and local app/config archive to `/mnt/nc-backups` |
| `maintenance/nextcloud-occ.sh` | **On demand** | Nextcloud CLI wrapper — file scan, maintenance mode, users |
| `maintenance/health-check.sh` | **On demand** | Quick status of system, ZFS, containers, and services |

## Usage

```bash
# Manual database backup (normally runs via cron automatically)
bash scripts/backup/db-backup.sh

# Nextcloud file rescan (after adding files directly to /mnt/main/nextcloud)
bash scripts/maintenance/nextcloud-occ.sh files:scan --all

# Full health check
bash scripts/maintenance/health-check.sh

# Quick health check (skips URL reachability tests)
bash scripts/maintenance/health-check.sh --quick
```

## Setting Up the DB Backup Cron (TrueNAS)

```
TrueNAS UI → System → Advanced → Cron Jobs → Add
  Description: MariaDB daily backup
  Command:     bash /mnt/main/scripts/db-backup.sh
  Schedule:    30 1 * * *   (01:30 daily — 30 min before ZFS snapshot at 02:00)
  Run As User: root
```

First, create the secrets file on TrueNAS:
```bash
echo 'NEXTCLOUD_DB_PASSWORD=your_actual_password' > /root/.db-backup-secrets
chmod 600 /root/.db-backup-secrets
```
