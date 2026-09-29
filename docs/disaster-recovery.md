# 🔥 Disaster Recovery Runbook

> **What is this document?**
> A step-by-step guide for recovering your home server when something breaks.
> Each scenario tells you exactly what to do, how long it takes, and what data
> (if any) you might lose. Read this BEFORE disaster strikes — when you're calm.
>
> **Last reviewed:** May 2026

---

## Preparation Checklist

> [!IMPORTANT]
> Complete these steps NOW — while everything is working. You can't do them during
> a disaster if the server is down.

- [ ] **This Git repo** is cloned on at least 2 devices (laptop + cloud like GitHub/Gitea)
- [ ] **TrueNAS config backup** — TrueNAS UI → System → General → Save Config → download and store off-site
- [ ] **Proxmox config backup** — `tar czf /root/proxmox-backup.tar.gz /etc/pve/` → store off-site
- [ ] **`.env` files** — Copy all `.env` files from `/opt/docker/*/` to a password manager note or encrypted USB
- [ ] **Authelia config** — Backup `configuration.yml` and `users_database.yml` separately (contains hashed passwords)
- [ ] **Cloudflare API token** — Stored in your password manager (needed for SSL certificate renewal)
- [ ] **Domain registrar login** — Know your login for DNS changes
- [ ] **Router admin login** — Know your login for port forwarding changes
- [ ] **ZFS snapshots running** — Verify: TrueNAS UI → Data Protection → Periodic Snapshot Tasks
- [ ] **Off-site backup running** — Verify: TrueNAS UI → Data Protection → Cloud Sync Tasks
- [ ] **Test a restore quarterly** — Pick a random file, delete it, restore from snapshot. Proves it works.

### Contact Info (fill in)

| Service | Provider | Login / Account |
|---------|----------|-----------------|
| Domain registrar | _______________ | _______________ |
| Cloudflare | _______________ | _______________ |
| ISP | _______________ | _______________ |
| Off-site backup (cloud) | _______________ | _______________ |

---

## Scenario 1: Docker VM Dies

**What happened:** The Docker VM crashed, got corrupted, or won't boot.
**Data at risk:** None — all data lives on TrueNAS (NFS).
**Recovery time:** 30–60 minutes.

### Steps

```
1. In Proxmox, delete or detach the broken Docker VM

2. Create a new Ubuntu Server VM in Proxmox:
   - ID: 111
   - RAM: 10-12 GB
   - CPU: 4-6 cores
   - Disk: 32 GB on ssd-fast
   - Network: vmbr0, IP: 192.168.1.20

3. Install the Ubuntu Server version used by the active Docker VM guide (no GUI)

4. SSH into the new VM:
   ssh root@192.168.1.20

5. Follow docs/os-and-virtualization/ubuntu-docker-security-setup.md to install
   Docker, harden SSH, recreate the service user, and restore the NFS mounts.

6. Reboot:
   reboot

7. Verify NFS mounts:
   df -h | grep nfs
   ls /mnt/main/appdata/    ← Should show all your service data

8. Copy compose files from this repo:
   scp -r configs/docker/* dockeradmin@192.168.1.20:/opt/docker/

9. Recreate .env files (from your backup or password manager):
   cd /opt/docker/traefik && cp .env.example .env && nano .env
   # Repeat for each service

10. Start services in order:
    cd /opt/docker/traefik && docker compose up -d
    cd /opt/docker/authelia && docker compose up -d
    # ... (see deployment order in README.md)
```

> [!TIP]
> Your data is completely safe. All app data, databases, Nextcloud files, Vaultwarden
> passwords — everything is on TrueNAS via NFS. The Docker VM only has compose files
> and Docker images, which are easily recreated.

---

## Scenario 2: TrueNAS Boot Drive Fails

**What happened:** TrueNAS won't boot because its boot drive (32 GB virtual disk on SSD) died.
**Data at risk:** None — ZFS pools are on separate HDDs that are unaffected.
**Docker VM impact:** NFS mounts will hang until TrueNAS is back. Services will be unresponsive.
**Recovery time:** 1–2 hours.

### Steps

```
1. In Proxmox, delete the broken TrueNAS VM disk (or create a new VM)

2. Download TrueNAS SCALE ISO from truenas.com

3. Create a new VM (or reinstall on existing):
   - Use the same VM ID (110) if possible
   - RAM: 14-16 GB
   - Boot disk: 32 GB on ssd-fast
   - Passthrough the same 4× HDDs

4. Install TrueNAS SCALE from ISO

5. After install, restore your TrueNAS config backup:
   TrueNAS UI → System → General → Upload Config
   (This restores all settings, users, shares, snapshot schedules)

6. If you don't have a config backup, manually:
   a. Import existing ZFS pools:
      TrueNAS UI → Storage → Import Pool
      (ZFS stores pool metadata ON the drives — TrueNAS finds them automatically)

   b. Re-create NFS exports:
      Shares → NFS → Add:
        /mnt/main  → Authorized Networks: 192.168.1.20/32
        /mnt/media → Authorized Networks: 192.168.1.20/32

   c. Re-create SMB shares
   d. Re-create snapshot schedules
   e. Re-create cloud sync tasks

7. Once NFS is back, the Docker VM reconnects automatically.
   Docker containers will recover on their own (NFS mounts use 'hard' mode).
```

> [!IMPORTANT]
> **Your ZFS data survives because pools are stored on the HDDs, not the boot drive.**
> ZFS writes all pool metadata (which files exist, their checksums, snapshots) directly
> onto the pool drives. A new TrueNAS install can import them with zero data loss.

---

## Scenario 3: Single HDD Failure (ZFS Mirror)

**What happened:** One of the two 4 TB drives in the `main` mirror pool failed.
**Data at risk:** None — ZFS mirror has a complete copy on the surviving drive.
**Downtime:** Zero — the pool keeps running on the remaining drive.
**Recovery time:** 4–8 hours (resilver time depends on data size).

### Steps

```
1. TrueNAS will alert you (email/UI) that a drive has failed.
   Check: TrueNAS UI → Storage → main pool → Status
   You'll see one drive marked as DEGRADED or FAULTED.

2. Order a replacement drive (same size or larger: ≥4 TB)

3. Shut down the server:
   Proxmox → TrueNAS VM → Shutdown (graceful)

4. Physically replace the failed drive

5. Start the server and TrueNAS

6. Replace the drive in ZFS:
   TrueNAS UI → Storage → main pool → Status → Replace
   Select the new drive

7. ZFS will "resilver" — copying all data from the good drive to the new one.
   This runs in the background. Services keep working during resilver.
   Monitor progress: TrueNAS UI → Storage → main pool → Status

8. Once resilvered, the pool is fully redundant again.
```

> [!WARNING]
> **While running on a single drive (degraded), you have NO redundancy.**
> If the second drive also fails before resilvering completes, you lose the pool.
> Replace the failed drive ASAP. Avoid heavy disk I/O during resilver.

> [!NOTE]
> **The `media` and `scratch` pools are NOT mirrored** (single drives). If those
> drives fail, that data is lost. This is by design — media files can be re-downloaded.
> Critical data should only be stored on the `main` (mirrored) pool.

---

## Scenario 4: Complete Server Hardware Failure

**What happened:** The motherboard, PSU, or other critical component failed. Nothing boots.
**Data at risk:** None — data is on the HDDs which are physically fine.
**Recovery time:** 2–4 hours (plus time to acquire replacement hardware).

### Steps

```
1. Get replacement hardware (any x86_64 server/PC with enough RAM and SATA/SAS ports)

2. Install Proxmox VE on the boot SSD:
   Download ISO: proxmox.com
   Boot from USB → Install → Select boot drive

3. Repeat the Proxmox base setup:
   Follow docs/os-and-virtualization/proxmox-manual-initial-setup.md

4. Create the TrueNAS VM:
   - Same specs as before (14-16 GB RAM, passthrough the HDDs)
   - Install TrueNAS SCALE
   - Import ZFS pools (Storage → Import Pool)
   - Restore config backup or recreate NFS exports

5. Create the Docker VM:
   - Ubuntu Server, 10-12 GB RAM
   - Follow docs/os-and-virtualization/ubuntu-docker-security-setup.md
   - Copy compose files, recreate .env files
   - docker compose up -d

6. Create the Hermes VM on vmbr1 if needed

7. Update router port forwarding to the new Docker VM IP
   Update Cloudflare DNS if your WAN IP changed
```

---

## Scenario 5: Data Corruption or Ransomware

**What happened:** Files got encrypted by ransomware, accidentally deleted, or corrupted.
**Data at risk:** Depends on when you catch it.
**Recovery time:** 5–30 minutes (from snapshot).

### Steps

```
1. STOP the affected service immediately:
   cd /opt/docker/<service> && docker compose down
   (This prevents further damage)

2. On TrueNAS, find a snapshot from BEFORE the corruption:
   TrueNAS UI → Datasets → main → Snapshots
   Look at the timestamps — pick one from before the incident

3. Option A: Roll back the entire dataset (destructive — loses ALL changes after the snapshot):
   zfs rollback main@auto-2026-05-30_02-00

4. Option B: Browse the snapshot and copy only the files you need (non-destructive):
   # Snapshots are accessible as hidden .zfs directories:
   ls /mnt/main/.zfs/snapshot/
   cp /mnt/main/.zfs/snapshot/auto-2026-05-30_02-00/appdata/vaultwarden/db.sqlite3 \
      /mnt/main/appdata/vaultwarden/db.sqlite3

5. Restart the service:
   cd /opt/docker/<service> && docker compose up -d

6. Investigate HOW the corruption happened before reconnecting to the internet
```

> [!CAUTION]
> **If you suspect ransomware:**
> 1. Disconnect the server from the network IMMEDIATELY
> 2. Do NOT pay any ransom
> 3. Restore from ZFS snapshot (step 3 above)
> 4. Change ALL passwords (every .env file, every service account)
> 5. Revoke and regenerate Cloudflare API token
> 6. Check CrowdSec logs for the attack vector

---

## Scenario 6: Database Corruption (MariaDB / Vaultwarden)

**What happened:** Nextcloud shows database errors, or Vaultwarden can't read the vault.
**Data at risk:** Recent changes since the last backup.
**Recovery time:** 10–20 minutes.

### Steps

```
1. Stop the affected service:
   cd /opt/docker/nextcloud && docker compose down

2. Find the latest database dump:
   ls -la /mnt/main/backups/db/
   # Dumps are named like: nextcloud_2026-05-30_01-30-00.sql.gz
   # Pick the most recent one from BEFORE the corruption

3. For Nextcloud (MariaDB):
   # Start only the database container:
   docker compose up -d nextcloud-db

   # Drop and recreate the database:
   docker exec -it nextcloud-db mysql -u root -p
   > DROP DATABASE nextcloud;
   > CREATE DATABASE nextcloud;
   > GRANT ALL ON nextcloud.* TO 'nextcloud'@'%';
   > EXIT;

   # Restore the dump:
   gunzip < /mnt/main/backups/db/nextcloud_2026-05-30_01-30-00.sql.gz | \
     docker exec -i nextcloud-db mysql -u nextcloud -p nextcloud

   # Start all containers:
   docker compose up -d

4. For Vaultwarden (SQLite):
   # Replace the corrupted database with the backup:
   cp /mnt/main/backups/db/vaultwarden_2026-05-30_01-30-00.sqlite3 \
      /mnt/main/appdata/vaultwarden/db.sqlite3

   # Start Vaultwarden:
   cd /opt/docker/vaultwarden && docker compose up -d
```

---

## Testing Your Recovery

> [!IMPORTANT]
> A backup you've never tested is not a backup — it's a hope.
> Schedule these tests quarterly.

### Quarterly Test Checklist

- [ ] **ZFS snapshot restore:** Delete a test file from Nextcloud, restore it from `.zfs/snapshot/`
- [ ] **Database restore:** Restore a MariaDB dump to a test database, verify data integrity
- [ ] **Docker VM rebuild:** Can you recreate it with `ubuntu-docker-security-setup.md` and the backed-up compose/env files?
- [ ] **TrueNAS config restore:** Do you have a recent config backup file?
- [ ] **`.env` files accessible:** Can you access all `.env` files from your password manager?
- [ ] **Off-site backup:** Download a file from your cloud backup, verify it's not corrupted

### Quick Health Check Commands

```bash
# Check ZFS pool health (run on TrueNAS)
zpool status main

# Check Docker container health (run on Docker VM)
docker ps --format "table {{.Names}}\t{{.Status}}"

# Check NFS mounts (run on Docker VM)
df -h | grep nfs

# Check disk space (run on Docker VM)
df -h /opt/docker /mnt/main /mnt/media

# Run the automated health check script
bash /mnt/main/scripts/health-check.sh
```
