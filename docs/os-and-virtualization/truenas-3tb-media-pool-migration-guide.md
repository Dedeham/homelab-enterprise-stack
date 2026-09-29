# TrueNAS 3 TB Media Pool Migration Guide

Last updated: 2026-06-24

This guide moves the current media tree off the protected `main` mirror and onto
the newly added 3 TB HDD, while keeping Docker paths unchanged.

Use it after these guides:

1. [TrueNAS storage pool setup](truenas-storage-pool-setup.md)
2. [Ubuntu Docker VM local-first setup](ubuntu-docker-security-setup.md)
3. [ARR stack local-first guide](../services/arr-stack-homelab-fit-review-and-setup.md), if the ARR stack is already deployed

## Current Hardware Assumption

This guide assumes the corrected HDD layout:

| Disk | Role |
|---|---|
| 2x 4 TB HDD | Existing `main` ZFS mirror |
| 1x 3 TB HDD | New `media` pool |
| 1x 1 TB HDD | Optional `scratch` pool |

Do not add the 3 TB or 1 TB disk as a new single-disk vdev to the existing
`main` pool. That would make the whole `main` pool depend on an unmirrored disk.

## Target Layout

After this guide:

| TrueNAS path | Docker VM path | Purpose |
|---|---|---|
| `/mnt/main` | `/mnt/main` | Important appdata, backups, user data |
| `/mnt/media/data` | `/mnt/media/data` | Media library and downloads on the 3 TB HDD |
| `/mnt/scratch` | Not mounted by default | Temporary or non-critical local copies |

Container paths should stay the same:

| Service | Internal path |
|---|---|
| Radarr | `/data/media/movies` |
| Sonarr | `/data/media/tv` |
| qBittorrent | `/data/torrents` |
| Jellyfin | `/media/movies`, `/media/tv`, `/media/music` |

The important part is that the Docker VM still mounts media at:

```text
/mnt/media/data
```

That means most Compose files should not need changes. You are changing the
TrueNAS source from:

```text
192.168.1.10:/mnt/main/media/data
```

to:

```text
192.168.1.10:/mnt/media/data
```

## Phase 1: Preflight Checks

Run these checks before creating or moving anything.

### On The Docker VM

Confirm the current mounts:

```bash
findmnt -T /mnt/main -o TARGET,SOURCE,FSTYPE,OPTIONS
findmnt -T /mnt/media/data -o TARGET,SOURCE,FSTYPE,OPTIONS
df -h /mnt/main /mnt/media/data
id mediauser
```

Expected current one-pool media source:

```text
192.168.1.10:/mnt/main/media/data
```

Check whether any stack hardcodes the old TrueNAS source path:

```bash
sudo grep -R "/mnt/main/media/data" -n /opt/stacks /opt/docker 2>/dev/null || true
sudo grep -R "DATA_PATH=" -n /opt/stacks /opt/docker 2>/dev/null || true
```

Good value:

```text
DATA_PATH=/mnt/media/data
```

If a Compose file uses `/mnt/main/media/data` directly, change it later to
`/mnt/media/data`. The stable host path for Docker containers is
`/mnt/media/data`.

Stop services that can write to media before the final copy:

```bash
cd /opt/stacks/arr-stack
docker compose stop
```

If Jellyfin is in a separate stack, stop it too during the final sync:

```bash
cd /opt/stacks/jellyfin-stack
docker compose stop
```

If a stack directory does not exist, skip that command.

### On TrueNAS

Confirm the current pool and media path:

```bash
zpool list
zfs list
ls -lah /mnt/main/media/data
du -sh /mnt/main/media/data
```

If `/mnt/main/media/data` does not exist, stop and find the real current media
path before continuing.

## Phase 2: Create The New `media` Pool

Use the TrueNAS UI for this step so TrueNAS records the disk, pool, and service
state cleanly.

1. Go to `Storage -> Create Pool`.
2. Name the pool:

   ```text
   media
   ```

3. Select only the new 3 TB HDD.
4. Use it as a single-disk data vdev.
5. Confirm the warning that this disk will be erased.

This pool has no redundancy. That is acceptable for replaceable media and
downloads. It is not appropriate for appdata, user documents, photos, or
Nextcloud primary data.

Create the dataset:

```text
Datasets -> media -> Add Dataset -> Name: data
```

Recommended dataset settings:

| Setting | Value |
|---|---|
| Path | `/mnt/media/data` |
| Compression | `lz4` enabled |
| Deduplication | Disabled |
| Atime | Off, if the UI exposes it |
| Owner | `mediauser` |
| Group | `mediauser` |
| Permissions | Owner/group read-write-execute |

If you prefer shell verification after the UI step:

```bash
zpool list media
zfs list media/data
ls -ld /mnt/media/data
```

## Phase 3: Optional 1 TB `scratch` Pool

Create this only if you want to use the new 1 TB HDD.

Recommended role:

```text
/mnt/scratch
```

Use it for temporary files, staging, or secondary local copies. Do not use it as
the only backup of important data.

In TrueNAS:

1. Go to `Storage -> Create Pool`.
2. Name the pool:

   ```text
   scratch
   ```

3. Select only the new 1 TB HDD.
4. Create datasets such as:

   ```text
   scratch/temp
   scratch/local-copies
   ```

Do not mount `/mnt/scratch` into Docker by default. Keeping it unmounted avoids
containers accidentally writing important data to a non-redundant disk.

## Phase 4: Create The Media Folder Layout

If you are copying an existing complete media tree, `rsync` will bring the
folders across. Creating the expected layout first is still useful because it
proves permissions.

Run on TrueNAS:

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

If TrueNAS uses ACLs and these commands are blocked or partially ignored, set
the owner/group and equivalent write permissions through the TrueNAS dataset
permissions UI.

## Phase 5: Copy Existing Media To The 3 TB Disk

Run the copy locally on TrueNAS. This avoids sending all media over NFS through
the Docker VM.

First run a dry run:

```bash
rsync -aHAXn --numeric-ids --info=progress2 \
  /mnt/main/media/data/ \
  /mnt/media/data/
```

If TrueNAS complains about `--info=progress2`, use:

```bash
rsync -aHAXn --numeric-ids \
  /mnt/main/media/data/ \
  /mnt/media/data/
```

If the dry run looks correct, run the real copy:

```bash
rsync -aHAX --numeric-ids --info=progress2 \
  /mnt/main/media/data/ \
  /mnt/media/data/
```

Fallback without progress output:

```bash
rsync -aHAX --numeric-ids \
  /mnt/main/media/data/ \
  /mnt/media/data/
```

Do not use `--delete` on the first copy. The goal is to populate the new media
pool without risking the old source.

Verify the copy:

```bash
du -sh /mnt/main/media/data
du -sh /mnt/media/data
find /mnt/media/data -maxdepth 3 -type d | sort
```

If services were running during the first copy, stop them and run one final sync:

```bash
rsync -aHAX --numeric-ids \
  /mnt/main/media/data/ \
  /mnt/media/data/
```

Use `--delete` only after you have confirmed the source and destination are
correct and the services are stopped:

```bash
rsync -aHAX --numeric-ids --delete \
  /mnt/main/media/data/ \
  /mnt/media/data/
```

If you are not fully sure, skip `--delete`. It is safer to leave harmless extra
files on the new pool than to delete wanted files.

After the copy, enforce the service ownership:

```bash
chown -R mediauser:mediauser /mnt/media/data
```

## Phase 6: Create The New NFS Export

In TrueNAS, create or update the NFS share:

| Setting | Value |
|---|---|
| Path | `/mnt/media/data` |
| Authorized host | `192.168.1.20` or `192.168.1.20/32` |
| Read-only | Disabled |
| Mapall User | `mediauser` |
| Mapall Group | `mediauser` |
| NFS service | Enabled and start automatically |

Keep the old `/mnt/main/media/data` export until the Docker VM has mounted and
tested the new export. Remove or disable the old export only after everything
works.

If you use SMB for desktop media browsing, update the `Media` SMB share path to:

```text
/mnt/media/data
```

## Phase 7: Switch The Docker VM Mount

On the Docker VM, edit `/etc/fstab`.

Old media line:

```fstab
192.168.1.10:/mnt/main/media/data /mnt/media/data nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
```

New media line:

```fstab
192.168.1.10:/mnt/media/data /mnt/media/data nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
```

Keep the `/mnt/main` line unchanged:

```fstab
192.168.1.10:/mnt/main /mnt/main nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
```

Remount:

```bash
sudo systemctl daemon-reload
sudo umount /mnt/media/data
sudo mount -a
findmnt -T /mnt/media/data -o TARGET,SOURCE,FSTYPE,OPTIONS
df -h /mnt/media/data
```

Expected source:

```text
192.168.1.10:/mnt/media/data
```

If `umount` says the path is busy, a container or shell is still using it:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
sudo fuser -vm /mnt/media/data
```

Stop the stack that is using the mount, leave any shell that has its working
directory inside `/mnt/media/data`, then retry the unmount.

## Phase 8: Verify Docker VM Write Access

Run on the Docker VM:

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

Do not start the media stack until every required folder shows `OK` and the
write tests pass.

## Phase 9: Verify Compose Paths

The host path should remain:

```text
/mnt/media/data
```

ARR containers should normally mount it internally as:

```text
/data
```

Jellyfin should normally mount only the final media folders:

```text
/mnt/media/data/media/movies -> /media/movies
/mnt/media/data/media/tv     -> /media/tv
/mnt/media/data/media/music  -> /media/music
```

Search for old direct references:

```bash
sudo grep -R "/mnt/main/media/data" -n /opt/stacks /opt/docker 2>/dev/null || true
```

If anything appears, update it to `/mnt/media/data`, then validate the affected
stack:

```bash
cd /opt/stacks/arr-stack
docker compose config
```

For Jellyfin, if it is in a separate stack:

```bash
cd /opt/stacks/jellyfin-stack
docker compose config
```

## Phase 10: Start Containers And Test Access

Start the media stack:

```bash
cd /opt/stacks/arr-stack
docker compose up -d
docker compose ps
```

If Jellyfin is separate:

```bash
cd /opt/stacks/jellyfin-stack
docker compose up -d
docker compose ps
```

Run container-level path checks. Skip commands for containers that are not
deployed.

```bash
docker exec qbittorrent ls -la /data/torrents
docker exec radarr ls -la /data/media/movies
docker exec sonarr ls -la /data/media/tv
docker exec jellyfin ls -la /media/movies
docker exec jellyfin ls -la /media/tv
docker exec jellyfin ls -la /media/music
```

Check numeric ownership from the Docker VM:

```bash
ls -ln /mnt/media/data
ls -ln /mnt/media/data/media
ls -ln /mnt/media/data/torrents
```

The owner/group should match the `mediauser` UID/GID, normally:

```text
3000 3000
```

If the files are readable but containers cannot write, fix the TrueNAS dataset
permissions and NFS Mapall settings first. Do not solve this by running
containers as root.

## Phase 11: App UI Checks

In the app UIs, confirm these paths:

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

If Radarr or Sonarr reports missing root folders, the container is not seeing
the same `/data` tree as qBittorrent. Recheck the Compose `DATA_PATH` value and
the `/mnt/media/data:/data` volume mapping.

If Jellyfin libraries are empty, confirm the Jellyfin stack still maps:

```text
/mnt/media/data/media/movies:/media/movies:ro
/mnt/media/data/media/tv:/media/tv:ro
/mnt/media/data/media/music:/media/music:ro
```

Then rescan libraries from the Jellyfin dashboard.

## Phase 12: Update TrueNAS Tasks

Add or update these tasks in TrueNAS:

| Task | Target | Schedule |
|---|---|---|
| Scrub | `media` pool | Monthly |
| SMART short test | New 3 TB HDD | Daily or weekly |
| SMART long test | New 3 TB HDD | Monthly |
| Snapshot | `media/data` | Daily or weekly, 7-14 day retention |

For the 1 TB `scratch` disk, add scrub and SMART tasks too. Snapshots are only
useful there if you keep something worth rolling back.

Update backup thinking:

- `main/appdata`, `main/userdata`, `main/nextcloud`, and `main/backups` remain
  critical.
- `media/data` is optional to back up unless you care about restoring media
  without redownloading or reripping.
- `scratch` is not a backup unless it is copied somewhere else too.

## Phase 13: Keep The Old Media Copy Temporarily

Do not delete the old source immediately.

Recommended hold period:

```text
7-14 days
```

During that time, confirm:

- qBittorrent can download to `/data/torrents`.
- Radarr imports to `/data/media/movies`.
- Sonarr imports to `/data/media/tv`.
- Jellyfin sees and plays existing media.
- Rebooting the Docker VM preserves the new `/mnt/media/data` mount.
- Rebooting TrueNAS and then the Docker VM preserves the new mount.

If the old media path is a ZFS dataset, you can make it read-only during the
hold period:

```bash
zfs set readonly=on main/media/data
```

Only do that if `zfs list main/media/data` confirms it is a dataset. If it is a
plain directory, skip this.

After the hold period, remove the old media copy from the TrueNAS UI if it is a
dataset, or delete the old directory from the TrueNAS shell only after checking
the new pool one final time.

Do not destroy or delete anything from `main` until the new `media` pool has
passed the container tests and at least one reboot test.

## Rollback

If the new media mount fails and you need to return to the old path:

1. Stop the media stacks on the Docker VM.
2. Restore the old `/etc/fstab` media line:

   ```fstab
   192.168.1.10:/mnt/main/media/data /mnt/media/data nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
   ```

3. Remount:

   ```bash
   sudo systemctl daemon-reload
   sudo umount /mnt/media/data
   sudo mount -a
   findmnt -T /mnt/media/data -o TARGET,SOURCE,FSTYPE,OPTIONS
   ```

4. Start the stacks again.

Do not copy data back from the new pool to the old source until you understand
which side has the newest files.

## Final Checklist

- [ ] `main` remains the 2x 4 TB mirror.
- [ ] The 3 TB HDD is its own `media` pool.
- [ ] Optional 1 TB HDD is `scratch`, not part of `main`.
- [ ] `/mnt/media/data` exists on TrueNAS and is owned by `mediauser`.
- [ ] Existing media was copied from `/mnt/main/media/data` to `/mnt/media/data`.
- [ ] NFS exports `/mnt/media/data` only to `192.168.1.20/32`.
- [ ] Docker VM `/etc/fstab` mounts `192.168.1.10:/mnt/media/data` at `/mnt/media/data`.
- [ ] `findmnt -T /mnt/media/data` shows the new `media` pool export.
- [ ] `mediauser` can write to `/mnt/media/data`.
- [ ] ARR folders exist under `/mnt/media/data`.
- [ ] Compose files use `/mnt/media/data`, not `/mnt/main/media/data`.
- [ ] qBittorrent, Radarr, Sonarr, and Jellyfin can see their expected paths.
- [ ] TrueNAS scrub, SMART, and snapshot tasks include the new `media` pool.
- [ ] Old media copy is retained until reboot and app tests pass.
