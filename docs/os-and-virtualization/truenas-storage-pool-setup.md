# TrueNAS Storage Pool And Share Setup

This guide configures TrueNAS for the current homelab design:

| Component | Value |
|---|---|
| TrueNAS VM | `192.168.1.10` |
| Docker/services VM | `192.168.1.20` |
| Home LAN gateway | `192.168.1.1` |
| Home LAN subnet | `192.168.1.0/24` |
| Isolated Hermes network | `10.10.100.0/24` |

TrueNAS is **storage only** in this setup. Do not run the ARR stack, Jellyfin, Pi-hole, Traefik, Dockge, or other Docker services on TrueNAS. Those belong on the Ubuntu Docker VM.

The rest of the documentation expects these storage paths:

| TrueNAS path | Mounted on Docker VM as | Purpose |
|---|---|---|
| `/mnt/main` | `/mnt/main` | App data, configs, databases, backups |
| `/mnt/media/data` | `/mnt/media/data` | Media files and downloader output |

If your pool names are different, either rename the pools before you store data or update every later guide consistently. For learning and simplicity, use `main` and `media` exactly.

## Step 1: Verify The Hardware Disks

1. Log in to the TrueNAS Web UI:

   ```text
   https://192.168.1.10
   ```

2. Go to **Storage -> Disks**.
3. Confirm you can see:
   - The TrueNAS boot disk, usually the small virtual disk from Proxmox.
   - The passed-through HDDs that will hold your data.
4. Confirm disk sizes look correct. A 4 TB drive normally appears as about `3.64 TiB`.
5. Confirm there are no disk alerts.

Do not create a ZFS pool on the TrueNAS boot disk. The boot disk is only for the TrueNAS operating system.

## Step 2: Choose The Pool Layout

ZFS stores data in pools. A pool is built from one or more vdevs. The vdev layout determines how much usable space you get and how much disk failure protection you have.

### Recommended Layout

For this homelab, use this layout if your disks allow it:

| Pool | Suggested disks | Layout | Purpose |
|---|---|---|---|
| `main` | 2x 4 TB HDDs | Mirror | Important data, app configs, databases, backups |
| `media` | Separate expendable disk, if available | Single disk or mirror | Media library and downloads |

The important rule is:

- Put irreplaceable app data on `main`.
- Treat `media` as less critical unless it is also mirrored and backed up.

### If You Only Have The Two 4 TB Drives

Create only the mirrored pool named `main`. Then you have two choices:

| Choice | What changes | Recommendation |
|---|---|---|
| Create `/mnt/main/media/data` and export it to Docker as `/mnt/media/data` | Later NFS examples need `192.168.1.10:/mnt/main/media/data /mnt/media/data` instead of `192.168.1.10:/mnt/media/data /mnt/media/data` | Best if you only have one mirrored pool |
| Create a separate `media` pool later when you add another disk | Keep the later docs unchanged | Best long-term layout |

The rest of this guide uses the documented target layout: `main` plus `media`. If you only create `main` now, follow the one-pool notes in Step 4 and Step 8.

### Mirror vs Stripe

For two identical 4 TB drives:

| Layout | Usable space | Failure tolerance | Use it? |
|---|---:|---:|---|
| Mirror | About 4 TB | One drive can fail | Yes |
| Stripe | About 8 TB | Any one drive failure loses the pool | No |

Use a mirror for `main`. A stripe is not appropriate for important homelab data.

### VDEV Types To Avoid For Now

Leave these out of the first build:

| VDEV type | Why to avoid it here |
|---|---|
| Cache / L2ARC | Usually unnecessary for media and normal home file storage. RAM already acts as ZFS ARC. |
| Log / SLOG | Useful only for specific synchronous write workloads and needs a power-loss-protected SSD. |
| Spare | You do not have an unused spare disk in the documented setup. |
| Metadata / special vdev | If it fails, the entire pool can be lost. It requires mirrored SSDs and planning. |
| Dedup | Very RAM-heavy and not useful for compressed media files. Do not enable it. |

## Step 3: Create The `main` Pool

1. Go to **Storage -> Create Pool**.
2. Name the pool:

   ```text
   main
   ```

3. Select the two 4 TB HDDs.
4. Move them into **Data VDevs**.
5. Set the layout to **Mirror**.
6. Confirm that TrueNAS shows redundancy.
7. Click **Create Pool**.
8. Confirm the warning that the selected disks will be erased.

After creation, TrueNAS should show:

```text
/mnt/main
```

Why the pool name matters: later Docker VM guides mount `192.168.1.10:/mnt/main` to `/mnt/main`. Keeping this exact path avoids confusion.

## Step 4: Create Datasets

A dataset is like a managed folder with its own permissions, compression, snapshots, quotas, and sharing behavior. Do not dump everything directly into the pool root.

### Required Datasets On `main`

Create these datasets:

| Dataset | Final path | Purpose |
|---|---|---|
| `appdata` | `/mnt/main/appdata` | Docker container configs and persistent service data |
| `backups` | `/mnt/main/backups` | Database dumps, config exports, recovery files |
| `scripts` | `/mnt/main/scripts` | Optional maintenance and backup scripts |

In the TrueNAS UI:

1. Go to **Datasets**.
2. Select the `main` pool.
3. Click **Add Dataset**.
4. Enter the dataset name.
5. Leave compression enabled. `lz4` is a good default.
6. Leave deduplication disabled.
7. Save.

Repeat for each dataset.

### Nextcloud Datasets (Only When Deploying Nextcloud)

Create these in the TrueNAS UI before starting the Nextcloud containers:

| Dataset | Select this parent first | Final path | Purpose |
|---|---|---|---|
| `main/nextcloud` | `main` | `/mnt/main/nextcloud` | Nextcloud-managed user files |
| `main/appdata/nextcloud-db` | `main/appdata` | `/mnt/main/appdata/nextcloud-db` | MariaDB data files |

For `main/nextcloud`, select `main`, click **Add Dataset**, and name it
`nextcloud`. For `main/appdata/nextcloud-db`, select `main/appdata`, click
**Add Dataset**, and name it `nextcloud-db`.

Do not create either final path with `mkdir` on TrueNAS or the Docker VM. The
TrueNAS dataset creation process creates the mount points. Follow the dedicated
[Nextcloud local-first setup guide](../services/nextcloud-local-first-setup.md)
for permissions, NFS verification, deployment, and backups.

### Required Media Path

If you have a separate media pool, create or confirm:

```text
/mnt/media
```

Then create this dataset:

| Dataset | Final path | Purpose |
|---|---|---|
| `data` | `/mnt/media/data` | ARR downloads and organized media library |

The ARR guide expects this structure later:

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

If you only have the `main` pool, create this instead:

```text
/mnt/main/media
/mnt/main/media/data
```

Then in the Docker VM guide, use this NFS line instead of the default media line:

```fstab
192.168.1.10:/mnt/main/media/data /mnt/media/data nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
```

That makes the Docker VM still see `/mnt/media`, even though the real TrueNAS path is `/mnt/main/media`.

## Step 5: Create The Shared Service User

The Docker VM and TrueNAS must agree on the numeric user ID that owns media and app files. Containers use numeric IDs internally, so matching the UID/GID prevents permission problems.

Use this identity:

| Field | Value |
|---|---|
| Username | `mediauser` |
| Group | `mediauser` |
| Suggested UID | `3000` |
| Suggested GID | `3000` |

In TrueNAS:

1. Go to **Credentials -> Local Users**.
2. Click **Add**.
3. Set:
   - **Full Name:** `Media Service`
   - **Username:** `mediauser`
   - **Password:** use a strong unique password
   - **New Primary Group:** enabled
4. If TrueNAS lets you set the UID manually, use:

   ```text
   3000
   ```

5. If TrueNAS assigns a different UID, write it down. You must use the same number in the Ubuntu Docker VM guide.
6. Save.

Security notes:

- Do not use `root` for SMB or NFS access.
- Do not use your personal TrueNAS admin account for Docker file ownership.
- Do not allow the Hermes VM to mount any TrueNAS shares.

## Step 6: Set Dataset Permissions

The goal is simple:

- Docker containers can read/write app and media data.
- Your Windows machine can access the SMB share using `mediauser`.
- Random LAN devices do not get anonymous write access.

### Permissions For `main`

Set ownership for these paths:

| Path | Owner | Group |
|---|---|---|
| `/mnt/main/appdata` | `mediauser` | `mediauser` |
| `/mnt/main/backups` | `mediauser` | `mediauser` |
| `/mnt/main/nextcloud` | `mediauser` | `mediauser` |
| `/mnt/main/appdata/nextcloud-db` | `mediauser` | `mediauser` |
| `/mnt/main/scripts` | `mediauser` | `mediauser` |

In TrueNAS:

1. Go to **Datasets**.
2. Select the dataset, for example `main/appdata`.
3. Find **Permissions**.
4. Click **Edit**.
5. Set **Owner** to `mediauser`.
6. Set **Owner Group** to `mediauser`.
7. Use a simple Unix-style permission model if available:

   ```text
   Owner: read/write/execute
   Group: read/write/execute
   Other: no access
   ```

8. Apply recursively only if the dataset already contains files that need fixing.
9. Save.

Repeat for the required datasets.

### Permissions For Media

Set ownership for:

```text
/mnt/media/data
```

or, if using one pool:

```text
/mnt/main/media/data
```

Use:

```text
Owner: mediauser
Group: mediauser
Mode: 775
```

Why `775` is useful for media:

- Owner and group can write.
- Docker containers using the same group can move and rename files.
- Other users can read if you intentionally allow LAN browsing.

If you want stricter access, use `770` instead.

## Step 7: Create The ARR Directory Layout

You can create the final ARR folders now or let the ARR guide create them from the Docker VM. Creating them now is useful because you can confirm permissions before deploying containers.

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

For one-pool fallback:

```text
/mnt/main/media/data/torrents/incomplete
/mnt/main/media/data/torrents/movies
/mnt/main/media/data/torrents/tv
/mnt/main/media/data/usenet/incomplete
/mnt/main/media/data/usenet/movies
/mnt/main/media/data/usenet/tv
/mnt/main/media/data/media/movies
/mnt/main/media/data/media/tv
/mnt/main/media/data/media/music
```

Keep downloads and final media under the same dataset. This allows Radarr and Sonarr to use hardlinks instead of copying files.

## Step 8: Create NFS Shares For The Docker VM

NFS is how the Ubuntu Docker VM mounts TrueNAS storage. This is the most important step after dataset creation.

Create NFS exports for the Docker VM only:

| Export path | Authorized host/network | Purpose |
|---|---|---|
| `/mnt/main` | `192.168.1.20/32` | Appdata, backups, configs |
| `/mnt/media/data` | `192.168.1.20/32` | Media and downloads |

If using the one-pool fallback, use this second export instead:

| Export path | Authorized host/network | Purpose |
|---|---|---|
| `/mnt/main/media/data` | `192.168.1.20/32` | Media and downloads |

In TrueNAS:

1. Go to **Shares -> Unix Shares (NFS)**.
2. Click **Add**.
3. Set **Path** to the export path.
4. Set **Authorized Hosts and IP addresses** to:

   ```text
   192.168.1.20
   ```

   If the UI asks for a network/CIDR value, use:

   ```text
   192.168.1.20/32
   ```

5. Enable NFSv4 if the UI exposes the option.
6. If TrueNAS exposes **Mapall User** and **Mapall Group**, set both to:

   ```text
   mediauser
   ```

7. Save.
8. Repeat for the second export.
9. When prompted, enable the NFS service.
10. Go to **System Settings -> Services** and make sure NFS is set to start automatically.

Why restrict to `192.168.1.20/32`:

- Only the Docker VM should mount app and media storage.
- Your normal LAN clients should use SMB if they need file browsing.
- Hermes on `10.10.100.2` must never mount TrueNAS storage.

## Step 9: Create Optional SMB Shares For Windows

SMB is for desktop file access from Windows, macOS, or Linux file managers. Docker containers should use NFS, not SMB.

Recommended SMB shares:

| SMB name | Path | Purpose |
|---|---|---|
| `Media` | `/mnt/media/data` or `/mnt/main/media/data` | Add or browse media from Windows |
| `Backups` | `/mnt/main/backups` | Copy recovery files or PC backups |

In TrueNAS:

1. Go to **Shares -> Windows (SMB) Shares**.
2. Click **Add**.
3. Choose the path.
4. Set a simple share name, for example:

   ```text
   Media
   ```

5. Save.
6. Enable the SMB service when prompted.
7. Go to **System Settings -> Services** and make sure SMB is set to start automatically.

From Windows, test:

```text
\\192.168.1.10\Media
```

Log in as:

```text
mediauser
```

Do not log in as TrueNAS `root` or your admin account for normal file work.

## Step 10: Add Snapshot Tasks

Snapshots protect against accidental deletion, broken container updates, and some ransomware-style damage. They are not a replacement for off-site backup, but they are very useful.

Create snapshot tasks in **Data Protection -> Periodic Snapshot Tasks**.

Recommended starting schedule:

| Dataset | Schedule | Retention | Reason |
|---|---|---|---|
| `main/appdata` | Every 6 hours | 14 days | Docker configs and databases change often |
| `main/backups` | Daily | 30 days | Backup files should have history |
| `main/nextcloud` | Daily | 30 days | User files need rollback |
| `media/data` | Daily or weekly | 7-14 days | Useful for accidental deletes, but media can be large |

If using one-pool fallback, apply the media task to:

```text
main/media/data
```

Do not keep very long snapshot retention on huge media datasets unless you understand the space impact. Deleted files remain on disk while snapshots still reference them.

## Step 11: Add Scrub And SMART Tasks

Scrubs make ZFS read and verify stored data. SMART tests check disk health.

### Scrub

In TrueNAS:

1. Go to **Data Protection -> Scrub Tasks**.
2. Add a scrub task for each pool.
3. Schedule monthly to start.

Suggested:

```text
Monthly, overnight
```

### SMART Tests

In TrueNAS:

1. Go to **Data Protection -> S.M.A.R.T. Tests**.
2. Add a short test for all HDDs:

   ```text
   Daily or weekly
   ```

3. Add a long test for all HDDs:

   ```text
   Monthly
   ```

Also configure alert email later in the TrueNAS hardening guide. Disk alerts are only useful if you actually receive them.

## Step 12: Verify From TrueNAS

In the TrueNAS UI:

1. Go to **Storage -> Pools** or **Datasets**.
2. Confirm these paths exist:

   ```text
   /mnt/main
   /mnt/main/appdata
   /mnt/main/backups
   /mnt/media
   /mnt/media/data
   ```

   If using one-pool fallback, confirm:

   ```text
   /mnt/main/media
   /mnt/main/media/data
   ```

3. Go to **Shares -> NFS**.
4. Confirm NFS is restricted to:

   ```text
   192.168.1.20
   ```

5. Go to **System Settings -> Services**.
6. Confirm:
   - NFS is running and starts automatically.
   - SMB is running only if you created SMB shares.

## Step 13: Verify From The Docker VM

This verification is done from the Ubuntu Docker VM. The goal is to confirm that the VM can mount the TrueNAS NFS exports and write to the media path before deploying Docker or the ARR stack.

Current network layout:

| System | IP address | Role |
|---|---:|---|
| TrueNAS | `192.168.1.10` | NFS server |
| Docker VM | `192.168.1.20` | NFS client |

The IP address in `/etc/fstab` must be the **TrueNAS IP**, not the VM IP.

### One-Pool Layout

Use this layout if all storage lives under the `main` pool and the media dataset is mounted at `/mnt/main/media/data`.

Add these lines to `/etc/fstab` on the Docker VM:

```fstab
192.168.1.10:/mnt/main             /mnt/main   nfs4  rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576  0  0
192.168.1.10:/mnt/main/media/data  /mnt/media/data  nfs4  rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576  0  0
```

Create the local mount points on the Docker VM:

```bash
sudo mkdir -p /mnt/main /mnt/media/data
```

Open `/etc/fstab`:

```bash
sudo nano /etc/fstab
```

Add the NFS lines at the bottom, then save with:

```text
Ctrl+O
Enter
Ctrl+X
```

Reload systemd and mount the NFS exports:

```bash
sudo systemctl daemon-reload
sudo mount -a
```

Verify the mounts:

```bash
findmnt /mnt/main
findmnt /mnt/media/data
df -h /mnt/main /mnt/media/data
ls -lah /mnt/media/data
```

Expected result: `/mnt/media/data` should show the TrueNAS media folders.

Run the write test from the Docker VM:

```bash
sudo -u mediauser touch /mnt/media/data/.docker-vm-write-test
sudo -u mediauser rm /mnt/media/data/.docker-vm-write-test
```

If this returns `Permission denied`, check these items in order from the Docker VM:

```bash
findmnt /mnt/media/data
id mediauser
ls -ldn /mnt/media /mnt/media/data
sudo touch /mnt/media/data/.root-write-test && sudo rm /mnt/media/data/.root-write-test
```

Expected:

- `findmnt /mnt/media/data` shows an NFS mount from the TrueNAS IP.
- `id mediauser` shows the same UID/GID used by TrueNAS, normally `3000:3000`.
- `ls -ldn /mnt/media/data` shows numeric owner/group `3000 3000`, or writes are allowed through NFS `Mapall`.

If the mount is correct but `mediauser` still cannot write, check whether root can write through the same NFS mount:

```bash
sudo touch /mnt/media/data/.root-write-test
sudo rm /mnt/media/data/.root-write-test
```

Use the result to decide what to fix:

| Result | Meaning | Fix |
|---|---|---|
| Root can write, `mediauser` cannot | The export is writable, but TrueNAS does not see VM UID/GID `3000:3000` as writable | Fix dataset owner/group or set NFS `Mapall User` and `Mapall Group` to `mediauser` |
| Root also gets `Permission denied` | The NFS export or dataset ACL is blocking writes | Fix the TrueNAS NFS share and dataset permissions before continuing |

If the Docker VM shows this:

```text
drwxr-xr-x+ 2 0 0 ... /mnt/media/data
```

the mounted dataset is still owned by TrueNAS `root:root`, not `mediauser:mediauser`. The `+` also means an ACL is present, so changing only the Ubuntu VM user will not fix it.

On TrueNAS, confirm the `data` dataset permissions:

```text
Dataset: main/media/data
Owner: mediauser
Group: mediauser
Owner permissions: Read / Write / Execute
Group permissions: Read / Write / Execute
Other permissions: None
```

If TrueNAS shows an ACL editor, either use a simple Unix permission preset for this dataset or make sure the ACL grants `mediauser` and group `mediauser` write access. Apply recursively if the dataset already contains folders.

After saving the permission change, the Docker VM should show numeric owner/group `3000 3000`:

```bash
ls -ldn /mnt/media/data
```

If `findmnt /mnt/media` shows this instead:

```text
192.168.1.10:/mnt/main/media/data  /mnt/media
```

the TrueNAS `data` dataset is mounted one level too high. In that layout, `/mnt/media/data` will not exist because the `data` dataset is already mounted as `/mnt/media`. Fix `/etc/fstab` so the target is `/mnt/media/data`:

```fstab
192.168.1.10:/mnt/main/media/data  /mnt/media/data  nfs4  rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576  0  0
```

Then remount:

```bash
sudo umount /mnt/media
sudo mkdir -p /mnt/media/data
sudo systemctl daemon-reload
sudo mount -a
findmnt /mnt/media/data
```

If `findmnt /mnt/media/data` shows nothing, `/mnt/media/data` is only the local VM directory and not the TrueNAS share. Fix `/etc/fstab`, then run:

```bash
sudo systemctl daemon-reload
sudo mount -a
findmnt /mnt/media/data
```

If the UID/GID does not match TrueNAS, fix the VM account before continuing. On the Docker VM:

```bash
id mediauser
```

If it is not `3000:3000`, recreate or adjust the VM user/group to match TrueNAS before storing files there.

If the mount and UID/GID are correct but writes still fail, fix the TrueNAS NFS share:

```text
Path: /mnt/main/media/data
Authorized client: 192.168.1.20/32
Mapall User: mediauser
Mapall Group: mediauser
```

Then restart the NFS service in TrueNAS and remount from the Docker VM:

```bash
sudo umount /mnt/media/data
sudo mount /mnt/media/data
sudo -u mediauser touch /mnt/media/data/.docker-vm-write-test
sudo -u mediauser rm /mnt/media/data/.docker-vm-write-test
```

Also make sure you are testing the writable dataset, not only the parent directory. In the one-pool layout, `/mnt/media/data` on the Docker VM should mount:

```text
192.168.1.10:/mnt/main/media/data
```

The write test should target:

```text
/mnt/media/data
```

Recommended NFS export permission on TrueNAS:

```text
Authorized client: 192.168.1.20/32
Mapall User: mediauser
Mapall Group: mediauser
```

Do not continue until the Docker VM can write to `/mnt/media/data` as `mediauser`.

## Step 14: Security Checklist

Before continuing, confirm:

- TrueNAS UI is only reachable from LAN and Tailscale, not the public internet.
- NFS exports are restricted to `192.168.1.20/32`.
- SMB is password-protected and does not allow guest access.
- `mediauser` owns app and media datasets.
- Hermes `10.10.100.2` has no NFS or SMB access.
- No Docker apps are running on TrueNAS.
- Snapshots are scheduled for important datasets.
- Scrub and SMART tasks are scheduled.

## Step 15: Continue To The Next Guides

After this guide:

1. Follow [TrueNAS hardening](../security/truenas-hardening-guide.md).
2. Follow [Ubuntu Docker VM local-first setup](ubuntu-docker-security-setup.md).
3. Follow [ARR stack homelab setup](../services/arr-stack-homelab-fit-review-and-setup.md).
