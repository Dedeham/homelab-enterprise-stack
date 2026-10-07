# TrueNAS Storage Setup

This guide configures TrueNAS for the current homelab design, then walks through migrating the media tree onto a dedicated 3 TB pool once that disk is added. Use it after the [Proxmox initial setup](proxmox-initial-setup.md).

| Component | Value |
|---|---|
| TrueNAS VM | `192.168.1.10` |
| Docker/services VM | `192.168.1.20` |
| Home LAN gateway | `192.168.1.1` |
| Home LAN subnet | `192.168.1.0/24` |
| Isolated Hermes network | `10.10.100.0/24` |

TrueNAS is storage only in this setup. The ARR stack, Jellyfin, Pi-hole, Traefik, Dockge, and other Docker services run on the Ubuntu Docker VM, not TrueNAS.

The rest of the documentation expects these storage paths:

| TrueNAS path | Mounted on Docker VM as | Purpose |
|---|---|---|
| `/mnt/main` | `/mnt/main` | App data, configs, databases, backups |
| `/mnt/media/data` | `/mnt/media/data` | Media files and downloader output |

If pool names differ, either rename the pools before storing data or update every later guide consistently. For simplicity, use `main` and `media` exactly.

## Part 1: Pool And Share Setup

### Step 1: Verify The Hardware Disks

1. Log in to the TrueNAS Web UI at `https://192.168.1.10`.
2. Go to Storage → Disks.
3. Confirm you can see the TrueNAS boot disk (usually the small virtual disk from Proxmox) and the passed-through HDDs that will hold data.
4. Confirm disk sizes look correct — a 4 TB drive normally appears as about `3.64 TiB`.
5. Confirm there are no disk alerts.

Do not create a ZFS pool on the TrueNAS boot disk — it is only for the TrueNAS operating system.

### Step 2: Choose The Pool Layout

ZFS stores data in pools, built from one or more vdevs. The vdev layout determines usable space and failure protection.

Recommended layout:

| Pool | Suggested disks | Layout | Purpose |
|---|---|---|---|
| `main` | 2x 4 TB HDDs | Mirror | Important data, app configs, databases, backups |
| `media` | Separate expendable disk, if available | Single disk or mirror | Media library and downloads |

Irreplaceable app data goes on `main`; `media` is treated as less critical unless it's also mirrored and backed up.

If only the two 4 TB drives are available, create only the mirrored `main` pool, then either create `/mnt/main/media/data` and export it to Docker as `/mnt/media/data` (later NFS examples use `192.168.1.10:/mnt/main/media/data` instead of `192.168.1.10:/mnt/media/data`), or add a separate `media` pool later when another disk is added (keeps later docs unchanged — this is the better long-term layout, and is what Part 2 of this guide walks through).

For two identical 4 TB drives, a mirror (about 4 TB usable, tolerates one drive failure) is used instead of a stripe (about 8 TB usable, but any one drive failure loses the whole pool) — a stripe is not appropriate for important homelab data.

VDEV types left out of the first build: cache/L2ARC (usually unnecessary; RAM already acts as ZFS ARC), log/SLOG (needed only for specific synchronous write workloads with a power-loss-protected SSD), spare (no unused spare disk in this layout), metadata/special vdev (pool-fatal if it fails, needs mirrored SSDs), and dedup (RAM-heavy, not useful for compressed media).

### Step 3: Create The `main` Pool

1. Go to Storage → Create Pool.
2. Name the pool `main`.
3. Select the two 4 TB HDDs and move them into Data VDevs.
4. Set the layout to Mirror.
5. Confirm TrueNAS shows redundancy.
6. Click Create Pool, and confirm the warning that the selected disks will be erased.

After creation, TrueNAS shows `/mnt/main`. Keeping this exact path matters because later Docker VM guides mount `192.168.1.10:/mnt/main` to `/mnt/main`.

### Step 4: Create Datasets

A dataset is a managed folder with its own permissions, compression, snapshots, quotas, and sharing behavior — data isn't dumped directly into the pool root.

Required datasets on `main`:

| Dataset | Final path | Purpose |
|---|---|---|
| `appdata` | `/mnt/main/appdata` | Docker container configs and persistent service data |
| `backups` | `/mnt/main/backups` | Database dumps, config exports, recovery files |
| `scripts` | `/mnt/main/scripts` | Optional maintenance and backup scripts |

In the TrueNAS UI: Datasets → select the `main` pool → Add Dataset → enter the name → leave compression enabled (`lz4` is a good default) → leave deduplication disabled → Save. Repeat for each dataset.

Nextcloud datasets (only when deploying Nextcloud), created before starting the Nextcloud containers:

| Dataset | Select this parent first | Final path | Purpose |
|---|---|---|---|
| `main/nextcloud` | `main` | `/mnt/main/nextcloud` | Nextcloud-managed user files |
| `main/appdata/nextcloud-db` | `main/appdata` | `/mnt/main/appdata/nextcloud-db` | MariaDB data files |

Do not create either final path with `mkdir` — TrueNAS dataset creation creates the mount points. See the dedicated [Nextcloud local-first setup guide](../services/nextcloud.md) for permissions, NFS verification, deployment, and backups.

Required media path: if a separate media pool exists, create or confirm `/mnt/media`, then create a `data` dataset at `/mnt/media/data` for ARR downloads and the organized media library. The ARR guide expects:

```text
/mnt/media/data/torrents/incomplete
/mnt/media/data/torrents/movies
/mnt/media/data/torrents/tv
/mnt/media/data/usenet/incomplete
/mnt/media/data/usenet/movies
/mnt/media/data/usenet/tv
/mnt/media/data/media/movies
/mnt/media/data/media/tv
/mnt/media/data/media/music
```

If only the `main` pool exists, create `/mnt/main/media` and `/mnt/main/media/data` instead, and in the Docker VM guide use this NFS line for media:

```fstab
192.168.1.10:/mnt/main/media/data /mnt/media/data nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
```

That makes the Docker VM still see `/mnt/media`, even though the real TrueNAS path is `/mnt/main/media`.

### Step 5: Create The Shared Service User

The Docker VM and TrueNAS must agree on the numeric user ID that owns media and app files, since containers use numeric IDs internally.

| Field | Value |
|---|---|
| Username | `mediauser` |
| Group | `mediauser` |
| Suggested UID | `3000` |
| Suggested GID | `3000` |

In TrueNAS: Credentials → Local Users → Add. Set Full Name `Media Service`, Username `mediauser`, a strong unique password, and enable New Primary Group. Set UID to `3000` if possible; if TrueNAS assigns a different UID, note it down for use in the Ubuntu Docker VM guide. Save.

Security notes: don't use `root` for SMB or NFS access, don't use a personal TrueNAS admin account for Docker file ownership, and don't allow the Hermes VM any TrueNAS share access.

### Step 6: Set Dataset Permissions

Goal: Docker containers can read/write app and media data, a Windows machine can access the SMB share as `mediauser`, and random LAN devices don't get anonymous write access.

Ownership for `main`:

| Path | Owner | Group |
|---|---|---|
| `/mnt/main/appdata` | `mediauser` | `mediauser` |
| `/mnt/main/backups` | `mediauser` | `mediauser` |
| `/mnt/main/nextcloud` | `mediauser` | `mediauser` |
| `/mnt/main/appdata/nextcloud-db` | `mediauser` | `mediauser` |
| `/mnt/main/scripts` | `mediauser` | `mediauser` |

In TrueNAS: Datasets → select the dataset (e.g. `main/appdata`) → Permissions → Edit → set Owner and Owner Group to `mediauser` → use a simple Unix-style model (owner rwx, group rwx, other no access) if available → apply recursively only if the dataset already contains files needing fixes → Save. Repeat for each dataset.

Media ownership (`/mnt/media/data` or `/mnt/main/media/data`): owner `mediauser`, group `mediauser`, mode `775` — owner and group can write, containers using the same group can move/rename files, and others can read if LAN browsing is intentionally allowed. Use `770` for stricter access.

### Step 7: Create The ARR Directory Layout

These folders can be created now (useful for confirming permissions before deploying containers) or left for the ARR guide to create from the Docker VM.

For a separate `media` pool:

```text
/mnt/media/data/torrents/incomplete
/mnt/media/data/torrents/movies
/mnt/media/data/torrents/tv
/mnt/media/data/usenet/incomplete
/mnt/media/data/usenet/movies
/mnt/media/data/usenet/tv
/mnt/media/data/media/movies
/mnt/media/data/media/tv
/mnt/media/data/media/music
```

For the one-pool fallback, use the same structure under `/mnt/main/media/data/...`. Keeping downloads and final media under the same dataset allows Radarr and Sonarr to use hardlinks instead of copying files.

### Step 8: Create NFS Shares For The Docker VM

NFS is how the Ubuntu Docker VM mounts TrueNAS storage — the most important step after dataset creation.

| Export path | Authorized host/network | Purpose |
|---|---|---|
| `/mnt/main` | `192.168.1.20/32` | Appdata, backups, configs |
| `/mnt/media/data` | `192.168.1.20/32` | Media and downloads |

One-pool fallback uses `/mnt/main/media/data` as the second export instead.

In TrueNAS: Shares → Unix Shares (NFS) → Add → set Path to the export path → set Authorized Hosts and IP addresses to `192.168.1.20` (or `192.168.1.20/32` for a CIDR field) → enable NFSv4 if exposed → if Mapall User/Group are exposed, set both to `mediauser` → Save. Repeat for the second export, enable the NFS service when prompted, and confirm in System Settings → Services that NFS starts automatically.

Restricting to `192.168.1.20/32` keeps app/media storage mountable only by the Docker VM; normal LAN clients use SMB for file browsing, and Hermes on `10.10.100.2` must never mount TrueNAS storage.

### Step 9: Create Optional SMB Shares For Windows

SMB is for desktop file access from Windows, macOS, or Linux file managers — Docker containers use NFS, not SMB.

| SMB name | Path | Purpose |
|---|---|---|
| `Media` | `/mnt/media/data` or `/mnt/main/media/data` | Add or browse media from Windows |
| `Backups` | `/mnt/main/backups` | Copy recovery files or PC backups |

In TrueNAS: Shares → Windows (SMB) Shares → Add → choose the path → set a simple share name → Save → enable the SMB service when prompted → confirm in System Settings → Services that SMB starts automatically.

From Windows, test `\\192.168.1.10\Media`, logging in as `mediauser` (not TrueNAS `root` or an admin account).

### Step 10: Add Snapshot Tasks

Snapshots protect against accidental deletion, broken container updates, and some ransomware-style damage. They are not a replacement for off-site backup. Create them in Data Protection → Periodic Snapshot Tasks.

| Dataset | Schedule | Retention | Reason |
|---|---|---|---|
| `main/appdata` | Every 6 hours | 14 days | Docker configs and databases change often |
| `main/backups` | Daily | 30 days | Backup files should have history |
| `main/nextcloud` | Daily | 30 days | User files need rollback |
| `media/data` | Daily or weekly | 7-14 days | Useful for accidental deletes, but media can be large |

One-pool fallback applies the media task to `main/media/data`. Avoid very long snapshot retention on huge media datasets — deleted files remain on disk while snapshots still reference them.

### Step 11: Add Scrub And SMART Tasks

Scrubs make ZFS read and verify stored data; SMART tests check disk health.

Scrub: Data Protection → Scrub Tasks → add a task per pool, scheduled monthly overnight.

SMART tests: Data Protection → S.M.A.R.T. Tests → add a short test for all HDDs (daily or weekly) and a long test for all HDDs (monthly). Alert email is configured later in the TrueNAS hardening guide — disk alerts are only useful if they're actually received.

### Step 12: Verify From TrueNAS

In the TrueNAS UI: Storage → Pools/Datasets, confirm `/mnt/main`, `/mnt/main/appdata`, `/mnt/main/backups`, `/mnt/media`, `/mnt/media/data` exist (or `/mnt/main/media`, `/mnt/main/media/data` for the one-pool fallback). Then Shares → NFS, confirm NFS is restricted to `192.168.1.20`. Then System Settings → Services, confirm NFS is running and starts automatically, and SMB is running only if SMB shares were created.

### Step 13: Verify From The Docker VM

This verification confirms the Docker VM can mount the TrueNAS NFS exports and write to the media path before deploying Docker or the ARR stack.

| System | IP address | Role |
|---|---:|---|
| TrueNAS | `192.168.1.10` | NFS server |
| Docker VM | `192.168.1.20` | NFS client |

The IP in `/etc/fstab` must be the TrueNAS IP, not the VM IP.

One-pool layout — add these lines to `/etc/fstab` on the Docker VM:

```fstab
192.168.1.10:/mnt/main             /mnt/main   nfs4  rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576  0  0
192.168.1.10:/mnt/main/media/data  /mnt/media/data  nfs4  rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576  0  0
```

```bash
sudo mkdir -p /mnt/main /mnt/media/data
sudo nano /etc/fstab
```

Add the NFS lines at the bottom, save (Ctrl+O, Enter, Ctrl+X), then:

```bash
sudo systemctl daemon-reload
sudo mount -a
findmnt /mnt/main
findmnt /mnt/media/data
df -h /mnt/main /mnt/media/data
ls -lah /mnt/media/data
```

Expected: `/mnt/media/data` shows the TrueNAS media folders. Write test:

```bash
sudo -u mediauser touch /mnt/media/data/.docker-vm-write-test
sudo -u mediauser rm /mnt/media/data/.docker-vm-write-test
```

If this returns `Permission denied`, check in order:

```bash
findmnt /mnt/media/data
id mediauser
ls -ldn /mnt/media /mnt/media/data
sudo touch /mnt/media/data/.root-write-test && sudo rm /mnt/media/data/.root-write-test
```

Expected: `findmnt` shows an NFS mount from the TrueNAS IP; `id mediauser` shows the same UID/GID used by TrueNAS (normally `3000:3000`); `ls -ldn` shows numeric owner/group `3000 3000`, or writes are allowed through NFS Mapall.

| Result of root write test | Meaning | Fix |
|---|---|---|
| Root can write, `mediauser` cannot | Export is writable, but TrueNAS doesn't see VM UID/GID `3000:3000` as writable | Fix dataset owner/group, or set NFS Mapall User/Group to `mediauser` |
| Root also gets `Permission denied` | NFS export or dataset ACL is blocking writes | Fix the TrueNAS NFS share and dataset permissions before continuing |

If the directory shows `drwxr-xr-x+ 2 0 0 ... /mnt/media/data`, the mounted dataset is still owned by TrueNAS `root:root` (the `+` indicates an ACL is present too, so fixing only the Ubuntu VM user won't help). On TrueNAS, confirm the `data` dataset has owner/group `mediauser`/`mediauser` with owner and group read/write/execute, other none. If an ACL editor is shown, use a simple Unix permission preset or ensure the ACL grants `mediauser`/`mediauser` write access, applying recursively if the dataset already has folders.

If `findmnt /mnt/media` shows `192.168.1.10:/mnt/main/media/data /mnt/media` (one level too high), fix `/etc/fstab` so the target is `/mnt/media/data`, then:

```bash
sudo umount /mnt/media
sudo mkdir -p /mnt/media/data
sudo systemctl daemon-reload
sudo mount -a
findmnt /mnt/media/data
```

If the UID/GID doesn't match TrueNAS, fix the VM account (`id mediauser` should show `3000:3000`) before storing files there. If the mount and UID/GID are correct but writes still fail, fix the TrueNAS NFS share (path `/mnt/main/media/data`, authorized client `192.168.1.20/32`, Mapall User/Group `mediauser`), restart NFS in TrueNAS, and remount:

```bash
sudo umount /mnt/media/data
sudo mount /mnt/media/data
sudo -u mediauser touch /mnt/media/data/.docker-vm-write-test
sudo -u mediauser rm /mnt/media/data/.docker-vm-write-test
```

Do not continue until the Docker VM can write to `/mnt/media/data` as `mediauser`.

### Step 14: Security Checklist

- TrueNAS UI is only reachable from LAN and Tailscale, not the public internet.
- NFS exports are restricted to `192.168.1.20/32`.
- SMB is password-protected and does not allow guest access.
- `mediauser` owns app and media datasets.
- Hermes `10.10.100.2` has no NFS or SMB access.
- No Docker apps are running on TrueNAS.
- Snapshots are scheduled for important datasets.
- Scrub and SMART tasks are scheduled.

### Step 15: Continue To The Next Guides

After this guide: follow [TrueNAS hardening](security/truenas-hardening.md), then [Ubuntu Docker VM setup](ubuntu-docker-security-setup.md), then [ARR stack setup](../services/arr-stack.md).

## Part 2: 3 TB Media Pool Migration

This part moves the media tree off the protected `main` mirror and onto a newly added 3 TB HDD, keeping Docker paths unchanged. Use it after Part 1 above, after the [Ubuntu Docker VM setup](ubuntu-docker-security-setup.md), and after the [ARR stack guide](../services/arr-stack.md) if that stack is already deployed.

### Hardware Assumption

| Disk | Role |
|---|---|
| 2x 4 TB HDD | Existing `main` ZFS mirror |
| 1x 3 TB HDD | New `media` pool |
| 1x 1 TB HDD | Optional `scratch` pool |

Do not add the 3 TB or 1 TB disk as a new single-disk vdev to the existing `main` pool — that would make the whole `main` pool depend on an unmirrored disk.

### Target Layout

| TrueNAS path | Docker VM path | Purpose |
|---|---|---|
| `/mnt/main` | `/mnt/main` | Important appdata, backups, user data |
| `/mnt/media/data` | `/mnt/media/data` | Media library and downloads on the 3 TB HDD |
| `/mnt/scratch` | Not mounted by default | Temporary or non-critical local copies |

Container paths stay the same (Radarr `/data/media/movies`, Sonarr `/data/media/tv`, qBittorrent `/data/torrents`, Jellyfin `/media/movies`, `/media/tv`, `/media/music`). The Docker VM still mounts media at `/mnt/media/data`, so most Compose files need no changes — only the TrueNAS source changes, from `192.168.1.10:/mnt/main/media/data` to `192.168.1.10:/mnt/media/data`.

### Phase 1: Preflight Checks

On the Docker VM, confirm current mounts:

```bash
findmnt -T /mnt/main -o TARGET,SOURCE,FSTYPE,OPTIONS
findmnt -T /mnt/media/data -o TARGET,SOURCE,FSTYPE,OPTIONS
df -h /mnt/main /mnt/media/data
id mediauser
```

Expected current one-pool media source: `192.168.1.10:/mnt/main/media/data`.

Check whether any stack hardcodes the old TrueNAS source path:

```bash
sudo grep -R "/mnt/main/media/data" -n /opt/stacks /opt/docker 2>/dev/null || true
sudo grep -R "DATA_PATH=" -n /opt/stacks /opt/docker 2>/dev/null || true
```

A Compose file using `/mnt/main/media/data` directly should later change to `/mnt/media/data`, the stable host path for containers.

Stop services that can write to media before the final copy:

```bash
cd /opt/stacks/arr-stack
docker compose stop
```

If Jellyfin is a separate stack, stop it too (skip any stack directory that doesn't exist):

```bash
cd /opt/stacks/jellyfin-stack
docker compose stop
```

On TrueNAS, confirm the current pool and media path:

```bash
zpool list
zfs list
ls -lah /mnt/main/media/data
du -sh /mnt/main/media/data
```

If `/mnt/main/media/data` doesn't exist, stop and find the real current media path before continuing.

### Phase 2: Create The New `media` Pool

Use the TrueNAS UI so TrueNAS records the disk, pool, and service state cleanly. Storage → Create Pool → name `media` → select only the new 3 TB HDD → single-disk data vdev → confirm the erase warning. This pool has no redundancy, which is acceptable for replaceable media/downloads but not for appdata, user documents, photos, or Nextcloud primary data.

Create the dataset via Datasets → `media` → Add Dataset → name `data`, with path `/mnt/media/data`, `lz4` compression, deduplication disabled, atime off if exposed, owner/group `mediauser`, owner/group read-write-execute permissions.

Shell verification if preferred:

```bash
zpool list media
zfs list media/data
ls -ld /mnt/media/data
```

### Phase 3: Optional 1 TB `scratch` Pool

Create this only if using the new 1 TB HDD, for temporary files, staging, or secondary local copies — not as the only backup of important data. Storage → Create Pool → name `scratch` → select only the new 1 TB HDD → create datasets such as `scratch/temp`, `scratch/local-copies`. Do not mount `/mnt/scratch` into Docker by default, to avoid containers accidentally writing important data to a non-redundant disk.

### Phase 4: Create The Media Folder Layout

If copying an existing complete media tree, `rsync` brings the folders across, but creating the expected layout first is useful to prove permissions. Run on TrueNAS:

```bash
mkdir -p \
  /mnt/media/data/torrents/incomplete \
  /mnt/media/data/torrents/movies \
  /mnt/media/data/torrents/tv \
  /mnt/media/data/usenet/incomplete \
  /mnt/media/data/usenet/movies \
  /mnt/media/data/usenet/tv \
  /mnt/media/data/media/movies \
  /mnt/media/data/media/tv \
  /mnt/media/data/media/music

chown -R mediauser:mediauser /mnt/media/data
find /mnt/media/data -type d -exec chmod 775 {} \;
find /mnt/media/data -type f -exec chmod 664 {} \;
```

If TrueNAS ACLs block or partially ignore these commands, set owner/group and equivalent write permissions through the TrueNAS dataset permissions UI instead.

### Phase 5: Copy Existing Media To The 3 TB Disk

Run the copy locally on TrueNAS to avoid sending all media over NFS through the Docker VM. Dry run first:

```bash
rsync -aHAXn --numeric-ids --info=progress2 \
  /mnt/main/media/data/ \
  /mnt/media/data/
```

If `--info=progress2` isn't supported, drop it. If the dry run looks correct, run the real copy:

```bash
rsync -aHAX --numeric-ids --info=progress2 \
  /mnt/main/media/data/ \
  /mnt/media/data/
```

Do not use `--delete` on this first copy — the goal is to populate the new pool without risking the old source. Verify:

```bash
du -sh /mnt/main/media/data
du -sh /mnt/media/data
find /mnt/media/data -maxdepth 3 -type d | sort
```

If services were running during the first copy, stop them and run one final sync. Use `--delete` only after confirming source and destination are correct and services are stopped:

```bash
rsync -aHAX --numeric-ids --delete \
  /mnt/main/media/data/ \
  /mnt/media/data/
```

If unsure, skip `--delete` — it's safer to leave harmless extra files than to delete wanted ones. After the copy, enforce ownership:

```bash
chown -R mediauser:mediauser /mnt/media/data
```

### Phase 6: Create The New NFS Export

In TrueNAS, create or update the NFS share: path `/mnt/media/data`, authorized host `192.168.1.20` (or `/32`), read-only disabled, Mapall User/Group `mediauser`, NFS service enabled and starting automatically. Keep the old `/mnt/main/media/data` export until the Docker VM has mounted and tested the new export — remove or disable it only after everything works. If SMB is used for desktop media browsing, update the `Media` SMB share path to `/mnt/media/data`.

### Phase 7: Switch The Docker VM Mount

On the Docker VM, edit `/etc/fstab`. Old line:

```fstab
192.168.1.10:/mnt/main/media/data /mnt/media/data nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
```

New line:

```fstab
192.168.1.10:/mnt/media/data /mnt/media/data nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
```

Keep the `/mnt/main` line unchanged. Remount:

```bash
sudo systemctl daemon-reload
sudo umount /mnt/media/data
sudo mount -a
findmnt -T /mnt/media/data -o TARGET,SOURCE,FSTYPE,OPTIONS
df -h /mnt/media/data
```

Expected source: `192.168.1.10:/mnt/media/data`. If `umount` says the path is busy:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
sudo fuser -vm /mnt/media/data
```

Stop the stack using the mount (and leave any shell with its working directory inside it) before retrying.

### Phase 8: Verify Docker VM Write Access

```bash
findmnt -T /mnt/main -o TARGET,SOURCE,FSTYPE,OPTIONS
findmnt -T /mnt/media/data -o TARGET,SOURCE,FSTYPE,OPTIONS
id mediauser

sudo -u mediauser touch /mnt/media/data/.docker-vm-write-test
sudo -u mediauser rm /mnt/media/data/.docker-vm-write-test

sudo -u mediauser touch /mnt/media/data/torrents/.docker-vm-write-test
sudo -u mediauser rm /mnt/media/data/torrents/.docker-vm-write-test

sudo -u mediauser touch /mnt/media/data/media/.docker-vm-write-test
sudo -u mediauser rm /mnt/media/data/media/.docker-vm-write-test
```

Then verify the ARR folder layout:

```bash
for path in \
  /mnt/media/data/torrents/incomplete \
  /mnt/media/data/torrents/movies \
  /mnt/media/data/torrents/tv \
  /mnt/media/data/usenet/incomplete \
  /mnt/media/data/usenet/movies \
  /mnt/media/data/usenet/tv \
  /mnt/media/data/media/movies \
  /mnt/media/data/media/tv \
  /mnt/media/data/media/music
do
  sudo -u mediauser test -d "$path" && echo "OK  $path" || echo "MISS $path"
done
```

Do not start the media stack until every folder shows `OK` and write tests pass.

### Phase 9: Verify Compose Paths

The host path should remain `/mnt/media/data`, with ARR containers mounting it internally as `/data`, and Jellyfin mounting only the final folders (`/mnt/media/data/media/movies` → `/media/movies`, etc.). Search for old direct references:

```bash
sudo grep -R "/mnt/main/media/data" -n /opt/stacks /opt/docker 2>/dev/null || true
```

Update anything found to `/mnt/media/data`, then validate the affected stacks with `docker compose config`.

### Phase 10: Start Containers And Test Access

```bash
cd /opt/stacks/arr-stack
docker compose up -d
docker compose ps
```

(and similarly for `jellyfin-stack` if separate). Run container-level path checks, skipping any container not deployed:

```bash
docker exec qbittorrent ls -la /data/torrents
docker exec radarr ls -la /data/media/movies
docker exec sonarr ls -la /data/media/tv
docker exec jellyfin ls -la /media/movies
docker exec jellyfin ls -la /media/tv
docker exec jellyfin ls -la /media/music
```

Check numeric ownership from the Docker VM — should match `mediauser`'s UID/GID (normally `3000 3000`):

```bash
ls -ln /mnt/media/data
ls -ln /mnt/media/data/media
ls -ln /mnt/media/data/torrents
```

If files are readable but containers can't write, fix TrueNAS dataset permissions and NFS Mapall settings — don't work around it by running containers as root.

### Phase 11: App UI Checks

| App | Setting | Expected path |
|---|---|---|
| qBittorrent | Incomplete downloads | `/data/torrents/incomplete` |
| qBittorrent | Movies category | `/data/torrents/movies` |
| qBittorrent | TV category | `/data/torrents/tv` |
| Radarr | Root folder | `/data/media/movies` |
| Sonarr | Root folder | `/data/media/tv` |
| Jellyfin | Movies library | `/media/movies` |
| Jellyfin | TV library | `/media/tv` |
| Jellyfin | Music library | `/media/music` |

If Radarr or Sonarr reports missing root folders, the container isn't seeing the same `/data` tree as qBittorrent — recheck the Compose `DATA_PATH` value and the `/mnt/media/data:/data` volume mapping. If Jellyfin libraries are empty, confirm the mappings for `/media/movies`, `/media/tv`, `/media/music`, then rescan libraries from the dashboard.

### Phase 12: Update TrueNAS Tasks

| Task | Target | Schedule |
|---|---|---|
| Scrub | `media` pool | Monthly |
| SMART short test | New 3 TB HDD | Daily or weekly |
| SMART long test | New 3 TB HDD | Monthly |
| Snapshot | `media/data` | Daily or weekly, 7-14 day retention |

Add scrub and SMART tasks for the 1 TB `scratch` disk too; snapshots there are only useful if something worth rolling back is kept. `main/appdata`, `main/userdata`, `main/nextcloud`, and `main/backups` remain critical to back up; `media/data` is optional unless restoring media without redownloading matters; `scratch` is not a backup unless copied elsewhere too.

### Phase 13: Keep The Old Media Copy Temporarily

Do not delete the old source immediately — hold it for 7-14 days while confirming: qBittorrent downloads to `/data/torrents`; Radarr imports to `/data/media/movies`; Sonarr imports to `/data/media/tv`; Jellyfin sees and plays existing media; rebooting the Docker VM preserves the new mount; rebooting TrueNAS and then the Docker VM preserves the new mount.

If the old media path is a ZFS dataset, it can be made read-only during the hold period (only if `zfs list main/media/data` confirms it's a dataset):

```bash
zfs set readonly=on main/media/data
```

After the hold period, remove the old media copy from the TrueNAS UI (if a dataset) or delete the old directory from the TrueNAS shell, only after a final check of the new pool. Do not destroy or delete anything from `main` until the new `media` pool has passed the container tests and at least one reboot test.

### Rollback

If the new media mount fails: stop the media stacks on the Docker VM, restore the old `/etc/fstab` media line (`192.168.1.10:/mnt/main/media/data /mnt/media/data ...`), remount (`sudo systemctl daemon-reload && sudo umount /mnt/media/data && sudo mount -a && findmnt -T /mnt/media/data -o TARGET,SOURCE,FSTYPE,OPTIONS`), then start the stacks again. Do not copy data back from the new pool to the old source until it's clear which side has the newest files.

### Final Checklist

- `main` remains the 2x 4 TB mirror.
- The 3 TB HDD is its own `media` pool.
- Optional 1 TB HDD is `scratch`, not part of `main`.
- `/mnt/media/data` exists on TrueNAS and is owned by `mediauser`.
- Existing media was copied from `/mnt/main/media/data` to `/mnt/media/data`.
- NFS exports `/mnt/media/data` only to `192.168.1.20/32`.
- Docker VM `/etc/fstab` mounts `192.168.1.10:/mnt/media/data` at `/mnt/media/data`.
- `findmnt -T /mnt/media/data` shows the new `media` pool export.
- `mediauser` can write to `/mnt/media/data`.
- ARR folders exist under `/mnt/media/data`.
- Compose files use `/mnt/media/data`, not `/mnt/main/media/data`.
- qBittorrent, Radarr, Sonarr, and Jellyfin can see their expected paths.
- TrueNAS scrub, SMART, and snapshot tasks include the new `media` pool.
- Old media copy is retained until reboot and app tests pass.
