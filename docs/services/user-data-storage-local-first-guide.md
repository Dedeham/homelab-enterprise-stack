# Local-First User Data Storage With TrueNAS

This guide shows how to store user data in the current homelab design without making Nextcloud the storage foundation.

The short version:

1. TrueNAS owns the disks, datasets, snapshots, SMB shares, and NFS exports.
2. The Ubuntu Docker VM runs applications.
3. Docker containers use TrueNAS storage through NFS mounts.
4. Windows, macOS, and Linux desktops use TrueNAS SMB shares.
5. Nextcloud is optional. It is a web UI, sync layer, sharing layer, calendar/contact server, and mobile app target. It is not the base storage layer.

## Current System Layout

This guide matches the current documented system:

| Component | Value |
|---|---|
| TrueNAS VM | `192.168.1.10` |
| Ubuntu Docker/services VM | `192.168.1.20` |
| Main TrueNAS pool | `/mnt/main` |
| Media TrueNAS path | `/mnt/media/data` |
| Docker VM main mount | `/mnt/main` |
| Docker VM media mount | `/mnt/media/data` |
| Service user/group | `mediauser:mediauser`, normally UID/GID `3000:3000` |
| Human users | TrueNAS local users such as `alice`, `bob`, etc. |

TrueNAS is storage only in this stack. Do not run Nextcloud, Jellyfin, ARR apps, Pi-hole, Traefik, or other Docker services on TrueNAS. Run those on the Ubuntu Docker VM.

Use these existing guides as the source of truth for the base platform:

- [TrueNAS storage pool setup](../os-and-virtualization/truenas-storage-pool-setup.md)
- [Ubuntu Docker VM security setup](../os-and-virtualization/ubuntu-docker-security-setup.md)
- [Nextcloud local-first setup](nextcloud-local-first-setup.md)

## Can This Guide Be Followed Before Nextcloud?

Yes. Follow this guide first to create the durable storage foundation:

1. TrueNAS datasets.
2. Human SMB users and private folders.
3. Shared user-data folders.
4. Docker VM NFS mount verification.
5. Snapshots and backup targets.

Do not start the Nextcloud containers until this guide's storage checks pass and
the Nextcloud compose has been reviewed for a supported Nextcloud major version.
As of 2026-06-12, do not deploy Nextcloud 29 for a new install because it is
end-of-life. Use the dedicated Nextcloud guide only after this local-first base
is working.

## Storage Architecture

Nextcloud should sit on top of normal storage, not replace it.

Recommended TrueNAS layout:

```text
/mnt/main/
  userdata/
    users/
      alice/
        documents/
        photos/
        scans/
        personal/
      bob/
        documents/
        photos/
        scans/
        personal/
    shared/
      family/
      scans/
      transfer/
  appdata/
    authelia/
    vaultwarden/
    jellyfin/
    pihole/
    homepage/
    nextcloud-db/
    syncthing/
  backups/
    db/
    config/
  nextcloud/
  scripts/

/mnt/media/data/
  torrents/
    incomplete/
    movies/
    tv/
  usenet/
    incomplete/
    movies/
    tv/
  media/
    movies/
    tv/
    music/
```

On the Docker VM, those same paths appear through NFS:

```text
/mnt/main
/mnt/media/data
```

That means compose files should bind mount TrueNAS-backed paths such as:

```text
/mnt/main/appdata/SERVICE
/mnt/main/userdata/users/alice
/mnt/main/userdata/users/bob
/mnt/main/userdata/shared
/mnt/main/nextcloud
/mnt/media/data
```

Do not use `/srv/homelab` for this system. That path fits a single Debian storage server, not this TrueNAS-backed design.

## What Each Layer Does

| Need | Use |
|---|---|
| ZFS pools, datasets, snapshots, scrubs, SMART checks | TrueNAS |
| LAN file shares for Windows/macOS/Linux desktops | TrueNAS SMB |
| Storage for Docker containers | TrueNAS NFS mounted on Docker VM |
| App configs and databases | `/mnt/main/appdata` |
| Important user files outside Nextcloud | `/mnt/main/userdata/users/USERNAME` |
| Shared household/team files | `/mnt/main/userdata/shared` |
| Nextcloud user files | `/mnt/main/nextcloud` |
| Media library and downloader output | `/mnt/media/data` |
| Compose files and `.env` files | `/opt/docker` on the Docker VM |
| Optional web file UI and sync clients | Nextcloud on Docker VM |
| Backups and logical database dumps | `/mnt/main/backups` plus off-site backup |

## Pasteable Fast Path For First User `alice`

Use these commands after the `main` pool exists in TrueNAS and the Docker VM already mounts `/mnt/main` and `/mnt/media/data`.

This fast path is meant to speed up folder, owner, and permission setup. Create TrueNAS users, groups, and the SMB share in the TrueNAS UI so TrueNAS manages SMB authentication cleanly.

First, in the **TrueNAS UI**, create these items:

| Type | Name | Notes |
|---|---|---|
| Group | `homelab-users` | Shared group for people who can use `/mnt/main/userdata/shared` |
| User | `alice` | Add `alice` to `homelab-users`; enable SMB/password login |
| Dataset | `main/userdata` | Creates `/mnt/main/userdata` as a real ZFS dataset |

Do not create `/mnt/main/userdata` with `mkdir`. If that path exists as a normal folder, TrueNAS cannot create the `main/userdata` dataset there.

Then run this block in the **TrueNAS Shell**. Paste the whole block exactly; it uses one `sudo bash` wrapper so the privileged commands really run as root:

```bash
sudo bash <<'EOF'
set -euo pipefail

FIRST_USER="alice"
USERDATA_ROOT="/mnt/main/userdata"

if [ ! -d /mnt/main ]; then
  echo "ERROR: /mnt/main does not exist. Create/import the TrueNAS main pool first."
  exit 1
fi

if ! zfs list main/userdata >/dev/null 2>&1; then
  echo "ERROR: main/userdata is not a ZFS dataset."
  echo "Create dataset main/userdata in the TrueNAS UI before running this block."
  echo "If the UI says /mnt/main/userdata already exists, use the recovery block below."
  exit 1
fi

if ! getent group homelab-users >/dev/null; then
  echo "ERROR: group homelab-users does not exist. Create it in the TrueNAS UI first."
  exit 1
fi

if ! id "${FIRST_USER}" >/dev/null 2>&1; then
  echo "ERROR: user ${FIRST_USER} does not exist. Create it in the TrueNAS UI first."
  exit 1
fi

chown root:homelab-users "${USERDATA_ROOT}"
chmod 0750 "${USERDATA_ROOT}"
install -d -o root -g homelab-users -m 0710 "${USERDATA_ROOT}/users"

install -d -o "${FIRST_USER}" -g homelab-users -m 0700 "${USERDATA_ROOT}/users/${FIRST_USER}"
install -d -o "${FIRST_USER}" -g homelab-users -m 0700 "${USERDATA_ROOT}/users/${FIRST_USER}/documents"
install -d -o "${FIRST_USER}" -g homelab-users -m 0700 "${USERDATA_ROOT}/users/${FIRST_USER}/photos"
install -d -o "${FIRST_USER}" -g homelab-users -m 0700 "${USERDATA_ROOT}/users/${FIRST_USER}/scans"
install -d -o "${FIRST_USER}" -g homelab-users -m 0700 "${USERDATA_ROOT}/users/${FIRST_USER}/personal"

install -d -o root -g homelab-users -m 2770 "${USERDATA_ROOT}/shared"
install -d -o root -g homelab-users -m 2770 "${USERDATA_ROOT}/shared/family"
install -d -o root -g homelab-users -m 2770 "${USERDATA_ROOT}/shared/scans"
install -d -o root -g homelab-users -m 2770 "${USERDATA_ROOT}/shared/transfer"

find "${USERDATA_ROOT}/users/${FIRST_USER}" -type d -exec chmod 0700 {} \;
find "${USERDATA_ROOT}/users/${FIRST_USER}" -type f -exec chmod 0600 {} \;
find "${USERDATA_ROOT}/shared" -type d -exec chmod 2770 {} \;
find "${USERDATA_ROOT}/shared" -type f -exec chmod 0660 {} \;

ls -ld "${USERDATA_ROOT}" "${USERDATA_ROOT}/users" "${USERDATA_ROOT}/users/${FIRST_USER}" "${USERDATA_ROOT}/shared"
EOF
```

Do not paste `sudo FIRST_USER="alice"` before the block. That only runs `sudo` with an environment assignment and does not make the following commands run as root.

If you see this:

```text
usage: sudo ...
groupadd: Permission denied
mkdir: cannot create directory '/mnt/main/userdata': Permission denied
```

the commands were not running as root. Use the full `sudo bash <<'EOF' ... EOF` block above, or run `sudo -i` first and then paste only the commands inside the block.

If the TrueNAS UI shows this while creating `main/userdata`:

```text
Path /mnt/main/userdata already exists
```

then `/mnt/main/userdata` is currently a plain directory, not a dataset. Move the plain directory aside first:

```bash
sudo bash <<'EOF'
set -euo pipefail

USERDATA_ROOT="/mnt/main/userdata"

if zfs list main/userdata >/dev/null 2>&1; then
  echo "OK: main/userdata already exists as a ZFS dataset."
  exit 0
fi

if [ -e "${USERDATA_ROOT}" ]; then
  BACKUP_PATH="/mnt/main/userdata.plain-dir.$(date +%Y%m%d-%H%M%S)"
  mv "${USERDATA_ROOT}" "${BACKUP_PATH}"
  echo "Moved plain directory to: ${BACKUP_PATH}"
  echo "Now create dataset main/userdata in the TrueNAS UI."
else
  echo "No existing /mnt/main/userdata path found."
  echo "Create dataset main/userdata in the TrueNAS UI."
fi
EOF
```

After that, go back to the TrueNAS UI and create dataset:

```text
main/userdata
```

If the moved plain directory had files you want to keep, copy them back after the dataset exists:

```bash
sudo bash <<'EOF'
set -euo pipefail

USERDATA_ROOT="/mnt/main/userdata"
BACKUP_PATH="$(find /mnt/main -maxdepth 1 -type d -name 'userdata.plain-dir.*' | sort | tail -n 1)"

if ! zfs list main/userdata >/dev/null 2>&1; then
  echo "ERROR: main/userdata is still not a ZFS dataset."
  exit 1
fi

if [ -z "${BACKUP_PATH}" ]; then
  echo "No moved userdata.plain-dir backup found. Nothing to copy back."
  exit 0
fi

cp -a "${BACKUP_PATH}/." "${USERDATA_ROOT}/"
echo "Copied contents from ${BACKUP_PATH} back into ${USERDATA_ROOT}."
echo "Leave ${BACKUP_PATH} in place until you have verified the files."
EOF
```

Then create the SMB share in the **TrueNAS UI**:

1. Go to **Shares -> Windows (SMB) Shares**.
2. Add path:

   ```text
   /mnt/main/userdata
   ```

3. Name it:

   ```text
   UserData
   ```

4. Enable the SMB service if prompted.

Run this block on the **Ubuntu Docker VM** to verify the storage mounts and app-write paths:

```bash
findmnt /mnt/main
findmnt /mnt/media/data
df -h /mnt/main /mnt/media/data
id mediauser

sudo -u mediauser touch /mnt/main/appdata/.docker-vm-write-test
sudo -u mediauser rm /mnt/main/appdata/.docker-vm-write-test

sudo -u mediauser touch /mnt/media/data/.docker-vm-write-test
sudo -u mediauser rm /mnt/media/data/.docker-vm-write-test
```

From Windows, test:

```text
\\192.168.1.10\UserData\users\alice
\\192.168.1.10\UserData\shared
```

If Windows previously connected as `mediauser`, clear the cached SMB session before testing as `alice`.

Open **Command Prompt** on Windows and run:

```bat
net use
net use \\192.168.1.10\UserData /delete
net use \\192.168.1.10\IPC$ /delete
cmdkey /delete:192.168.1.10
```

If Windows says a connection does not exist, continue.

Then reconnect as `alice`:

```bat
net use \\192.168.1.10\UserData /user:alice *
```

Enter `alice`'s TrueNAS SMB password when prompted.

If Windows still uses the wrong account, remove it from **Credential Manager**:

1. Open **Control Panel -> Credential Manager**.
2. Open **Windows Credentials**.
3. Remove saved entries for `192.168.1.10`, `truenas`, or the TrueNAS hostname.
4. Sign out of Windows and sign back in, or reboot.
5. Reconnect to `\\192.168.1.10\UserData` as `alice`.

From macOS Finder, test:

```text
smb://192.168.1.10/UserData
```

### Add Another User Later

For the next user, first create the user in the **TrueNAS UI** and add that user to `homelab-users` if they should access shared folders. Then change only `NEW_USER` and run this in the **TrueNAS Shell**:

```bash
sudo bash <<'EOF'
set -euo pipefail

NEW_USER="bob"
USERDATA_ROOT="/mnt/main/userdata"

if ! zfs list main/userdata >/dev/null 2>&1; then
  echo "ERROR: main/userdata is not a ZFS dataset."
  echo "Create dataset main/userdata in the TrueNAS UI before running this block."
  exit 1
fi

if ! id "${NEW_USER}" >/dev/null 2>&1; then
  echo "ERROR: user ${NEW_USER} does not exist. Create it in the TrueNAS UI first."
  exit 1
fi

install -d -o "${NEW_USER}" -g homelab-users -m 0700 "${USERDATA_ROOT}/users/${NEW_USER}"
install -d -o "${NEW_USER}" -g homelab-users -m 0700 "${USERDATA_ROOT}/users/${NEW_USER}/documents"
install -d -o "${NEW_USER}" -g homelab-users -m 0700 "${USERDATA_ROOT}/users/${NEW_USER}/photos"
install -d -o "${NEW_USER}" -g homelab-users -m 0700 "${USERDATA_ROOT}/users/${NEW_USER}/scans"
install -d -o "${NEW_USER}" -g homelab-users -m 0700 "${USERDATA_ROOT}/users/${NEW_USER}/personal"

find "${USERDATA_ROOT}/users/${NEW_USER}" -type d -exec chmod 0700 {} \;
find "${USERDATA_ROOT}/users/${NEW_USER}" -type f -exec chmod 0600 {} \;

ls -ld "${USERDATA_ROOT}/users/${NEW_USER}"
EOF
```

Then verify the new user can open their own folder and cannot open another user's private folder.

## Phase 1: Confirm TrueNAS Foundation

Finish the TrueNAS storage guide first. Before continuing, confirm:

- TrueNAS is reachable at `https://192.168.1.10`.
- The Docker VM is `192.168.1.20`.
- The `main` pool exists.
- `/mnt/main/appdata` exists.
- `/mnt/main/backups` exists.
- `/mnt/main/nextcloud` exists if you plan to deploy Nextcloud.
- `/mnt/media/data` exists, or you are using the one-pool fallback from the TrueNAS guide.
- NFS exports are restricted to the Docker VM only: `192.168.1.20/32`.
- SMB is password-protected and does not allow guest access.
- `mediauser` owns app and media datasets.
- Human users are separate TrueNAS accounts, for example `alice`, `bob`, etc.

Create a shared group first:

1. Go to **Credentials -> Local Groups**.
2. Create a group named:

   ```text
   homelab-users
   ```

Then create `/mnt/main/userdata` in TrueNAS as the parent dataset for all human data:

1. Go to **Datasets**.
2. Select the `main` pool.
3. Add a dataset named:

   ```text
   userdata
   ```

4. Keep compression enabled.
5. Keep deduplication disabled.
6. Set owner to an admin-capable account or `root`.
7. Set group to a shared group such as:

   ```text
   homelab-users
   ```

8. Use simple parent permissions:

   ```text
   Owner: read/write/execute
   Group: read/execute
   Other: no access
   ```

Create one TrueNAS local user per person:

| User | Owns | Purpose |
|---|---|---|
| `alice` | `/mnt/main/userdata/users/alice` | First person's private files |
| `bob` | `/mnt/main/userdata/users/bob` | Second person's private files |
| `user3` | `/mnt/main/userdata/users/user3` | Future user, same pattern |

In TrueNAS:

1. Go to **Credentials -> Local Users**.
2. Add `alice`, `bob`, etc.
3. Give each user a strong unique password.
4. Add each person to the `homelab-users` group if you want shared folder access.
5. Do not use `mediauser` as a normal person's SMB login.

Create this multi-user folder layout:

```text
/mnt/main/userdata/
  users/
    alice/
      documents/
      photos/
      scans/
      personal/
    bob/
      documents/
      photos/
      scans/
      personal/
  shared/
    family/
    scans/
    transfer/
```

Recommended ownership:

| Path | Owner | Group | Access model |
|---|---|---|---|
| `/mnt/main/userdata/users/alice` | `alice` | `alice` or `homelab-users` | Private to `alice`, plus admin if needed |
| `/mnt/main/userdata/users/bob` | `bob` | `bob` or `homelab-users` | Private to `bob`, plus admin if needed |
| `/mnt/main/userdata/shared` | admin or `root` | `homelab-users` | Writable by all intended human users |

For private user folders, use permissions equivalent to:

```text
Owner: read/write/execute
Group: no access, unless you intentionally grant family/admin access
Other: no access
```

For shared folders, use permissions equivalent to:

```text
Owner: read/write/execute
Group: read/write/execute
Other: no access
```

If TrueNAS uses the ACL editor, create the same result with ACL entries:

- `alice` has full control of `users/alice`.
- `bob` has full control of `users/bob`.
- `homelab-users` has modify access to `shared`.
- `mediauser` is not granted access to private user folders unless a Docker service explicitly needs it.
- `mediauser` is granted access to `shared` only if a Docker service needs to read or write shared files.

When adding a future user, repeat the same pattern:

1. Create the TrueNAS user, for example `user3`.
2. Add `/mnt/main/userdata/users/user3`.
3. Set owner to `user3`.
4. Give only `user3` access to that private folder.
5. Add `user3` to `homelab-users` if they should use `/mnt/main/userdata/shared`.

## Phase 2: SMB Access From Desktops

SMB belongs on TrueNAS in this design. Do not install Samba on the Docker VM for these folders.

Recommended SMB shares:

| SMB share | TrueNAS path | Purpose |
|---|---|---|
| `UserData` | `/mnt/main/userdata` | Parent share for per-user folders and shared folders |
| `Media` | `/mnt/media/data` or `/mnt/main/media/data` | Media library and downloads |
| `Backups` | `/mnt/main/backups` | Recovery files, exports, database dumps |

In TrueNAS:

1. Go to **Shares -> Windows (SMB) Shares**.
2. Add a share for `/mnt/main/userdata`.
3. Name it:

   ```text
   UserData
   ```

4. Save and enable SMB if prompted.
5. Confirm the SMB service starts automatically.

From Windows:

```text
\\192.168.1.10\UserData
```

Per-user paths then look like:

```text
\\192.168.1.10\UserData\users\alice
\\192.168.1.10\UserData\users\bob
\\192.168.1.10\UserData\shared
```

From macOS Finder:

```text
smb://192.168.1.10/UserData
```

Log in as the person's own TrueNAS user, such as `alice` or `bob`. Do not use `mediauser`, TrueNAS `root`, or your TrueNAS admin account for normal file work.

Expected access:

| Login | Should access | Should not access |
|---|---|---|
| `alice` | `users/alice`, `shared` | `users/bob` |
| `bob` | `users/bob`, `shared` | `users/alice` |
| `mediauser` | App/media paths only | Private human folders |

At this point you already have local-first storage without Nextcloud.

## Phase 3: Docker VM NFS Mounts

The Docker VM should mount TrueNAS storage through NFS. The expected mounts are:

```text
192.168.1.10:/mnt/main       -> /mnt/main
192.168.1.10:/mnt/media/data -> /mnt/media/data
```

If you are using the one-pool fallback, the media mount is:

```text
192.168.1.10:/mnt/main/media/data -> /mnt/media/data
```

Verify from the Docker VM:

```bash
findmnt /mnt/main
findmnt /mnt/media/data
df -h /mnt/main /mnt/media/data
id mediauser
```

Run write tests:

```bash
sudo -u mediauser touch /mnt/main/appdata/.docker-vm-write-test
sudo -u mediauser rm /mnt/main/appdata/.docker-vm-write-test

sudo -u mediauser touch /mnt/media/data/.docker-vm-write-test
sudo -u mediauser rm /mnt/media/data/.docker-vm-write-test
```

Do not deploy apps until these write tests pass. If they fail, fix TrueNAS dataset permissions or NFS `Mapall User` / `Mapall Group` before continuing.

Do not require `mediauser` to write to private folders such as:

```text
/mnt/main/userdata/users/alice
/mnt/main/userdata/users/bob
```

Those folders should be owned by their human users. Only grant `mediauser` access to a user folder if a Docker service truly needs it.

If a Docker service needs shared-userdata access, test only the shared folder:

```bash
sudo -u mediauser touch /mnt/main/userdata/shared/.docker-vm-write-test
sudo -u mediauser rm /mnt/main/userdata/shared/.docker-vm-write-test
```

Recommended NFS export settings on TrueNAS:

```text
Path: /mnt/main
Authorized client: 192.168.1.20/32
Mapall User: mediauser
Mapall Group: mediauser
```

Because this export maps Docker VM NFS access to `mediauser`, TrueNAS permissions still matter. Keep private human folders closed to `mediauser` unless you intentionally want Docker-hosted apps to read or write them.

For media:

```text
Path: /mnt/media/data
Authorized client: 192.168.1.20/32
Mapall User: mediauser
Mapall Group: mediauser
```

If you are using one pool:

```text
Path: /mnt/main/media/data
Authorized client: 192.168.1.20/32
Mapall User: mediauser
Mapall Group: mediauser
```

## Phase 4: Store Docker App Data Correctly

Compose files live on the Docker VM:

```text
/opt/docker/SERVICE
```

Persistent service data lives on TrueNAS:

```text
/mnt/main/appdata/SERVICE
```

Human files live outside hidden Docker volumes:

```text
/mnt/main/userdata/users/alice
/mnt/main/userdata/users/bob
/mnt/main/userdata/shared
/mnt/main/nextcloud
/mnt/media/data
```

Examples:

```yaml
services:
  jellyfin:
    image: jellyfin/jellyfin:<pinned-version>
    container_name: jellyfin
    restart: unless-stopped
    volumes:
      - /mnt/main/appdata/jellyfin/config:/config
      - /mnt/main/appdata/jellyfin/cache:/cache
      - /mnt/media/data/media:/media:ro
```

```yaml
services:
  syncthing:
    image: syncthing/syncthing:<pinned-version>
    container_name: syncthing
    restart: unless-stopped
    ports:
      - "8384:8384"
      - "22000:22000/tcp"
      - "22000:22000/udp"
      - "21027:21027/udp"
    volumes:
      - /mnt/main/appdata/syncthing:/var/syncthing/config
      - /mnt/main/userdata/shared:/data/shared
```

Rule: do not bury important personal data only inside anonymous Docker volumes. Use visible bind mounts under `/mnt/main` or `/mnt/media/data`.

For multi-user storage, avoid mounting all of `/mnt/main/userdata` into a container. Mount only the specific folder that service needs, such as `/mnt/main/userdata/shared` or `/mnt/main/userdata/users/alice/photos`.

## Phase 5: Optional Device Sync With Syncthing

Use Syncthing when you want selected folders to sync between devices without depending on a cloud account.

Good use cases:

- Laptop documents.
- Notes folders.
- Project folders.
- Phone photo backup into a specific folder.
- A small personal folder that should exist on multiple devices.

Avoid syncing the full media library unless you intentionally want copies on every device.

If you deploy Syncthing on the Docker VM, mount only the folders it should manage:

```yaml
volumes:
  - /mnt/main/appdata/syncthing:/var/syncthing/config
  - /mnt/main/userdata/users/alice/documents:/data/alice-documents
  - /mnt/main/userdata/users/alice/photos:/data/alice-photos
  - /mnt/main/userdata/shared:/data/shared
```

For `bob`, either add separate mounts for `bob` or run a separate Syncthing instance with a separate config path:

```text
/mnt/main/appdata/syncthing-bob
/mnt/main/userdata/users/bob/documents
/mnt/main/userdata/users/bob/photos
```

Only grant `mediauser` access to the specific user folders Syncthing must sync. If you do not want the Docker VM to touch a person's private files, run Syncthing directly on that person's devices and use SMB only for manual access.

After first start:

1. Open `http://192.168.1.20:8384` if exposed on the LAN.
2. Set a GUI username and password.
3. Add devices explicitly.
4. Share only intended folders.
5. Keep large folders separate from small document folders.

## Phase 6: Back Up User Data

Snapshots are useful, but they are not complete backups.

Minimum backup plan:

- TrueNAS snapshots for `/mnt/main/userdata`.
- TrueNAS snapshots for `/mnt/main/appdata`.
- TrueNAS snapshots for `/mnt/main/nextcloud` if Nextcloud is used.
- TrueNAS snapshots for `/mnt/main/backups`.
- Logical database dumps into `/mnt/main/backups/db`.
- Off-site backup or cloud sync for irreplaceable data.

Recommended snapshot starting point:

| Dataset | Schedule | Retention |
|---|---|---|
| `main/userdata` | Daily | 30 days |
| `main/appdata` | Every 6 hours | 14 days |
| `main/nextcloud` | Daily | 30 days |
| `main/backups` | Daily | 30 days |
| `media/data` | Daily or weekly | 7-14 days |

Database files need extra care. A ZFS snapshot of a live database is useful, but a logical dump is easier to restore cleanly. Use the existing backup script:

```text
scripts/backup/db-backup.sh
```

The intended flow is:

1. Dump databases to `/mnt/main/backups/db`.
2. Let the TrueNAS snapshot task snapshot the dump files.
3. Include those dumps in off-site backup.

Do not consider a backup real until you have restored from it once.

## Phase 7: Optional Nextcloud Handoff

The local-first storage foundation is complete without Nextcloud. Add Nextcloud
only if you need its web UI, sharing, mobile upload, desktop sync, calendar, or
contacts features.

Continue with the dedicated
[Nextcloud local-first setup guide](nextcloud-local-first-setup.md). That guide
contains the TrueNAS child-dataset locations, permissions, container deployment,
local DNS, backup, and verification steps.

Keep normal user storage and Nextcloud-managed storage separate:

```text
/mnt/main/userdata   normal SMB and optional Syncthing storage
/mnt/main/nextcloud  Nextcloud-managed primary data
```

Do not point Nextcloud's primary data directory at `/mnt/main/userdata`, and do
not create the Nextcloud dataset paths with `mkdir` on the Docker VM.

## Operational Checklist

Storage:

- `/mnt/main/userdata` exists on TrueNAS.
- `/mnt/main/userdata/users/alice` exists and is owned by `alice`.
- `/mnt/main/userdata/users/bob` exists and is owned by `bob`.
- `/mnt/main/userdata/shared` exists and is writable by `homelab-users`.
- `/mnt/main/appdata` exists on TrueNAS.
- `/mnt/main/backups` exists on TrueNAS.
- `/mnt/media/data` exists, or the one-pool fallback is documented.
- `mediauser` owns the datasets that Docker writes to.
- `mediauser` does not have access to private human folders unless intentionally granted.

Shares:

- SMB `UserData` points to `/mnt/main/userdata`.
- `alice` can access `UserData\users\alice`.
- `bob` can access `UserData\users\bob`.
- `alice` cannot access `UserData\users\bob`.
- `bob` cannot access `UserData\users\alice`.
- Intended users can access `UserData\shared`.
- SMB is password-protected.
- NFS exports are restricted to `192.168.1.20/32`.

Docker VM:

- `findmnt /mnt/main` shows the TrueNAS NFS export.
- `findmnt /mnt/media/data` shows the TrueNAS media export.
- `sudo -u mediauser` can write to `/mnt/main/appdata`.
- `sudo -u mediauser` can write to `/mnt/media/data`.
- `sudo -u mediauser` can write to `/mnt/main/userdata/shared` only if a Docker service needs shared-userdata access.
- Compose files live in `/opt/docker`.
- Persistent data uses bind mounts under `/mnt/main` or `/mnt/media/data`.

Backups:

- TrueNAS snapshots exist for important datasets.
- Database dumps land in `/mnt/main/backups/db`.
- A restore test has succeeded.
- One backup copy exists away from the main server.

Nextcloud, if used:

- Runs on the Docker VM, not TrueNAS.
- Stores user files in `/mnt/main/nextcloud`.
- Has separate Nextcloud accounts for daily users, for example `alice` and `bob`.
- Stores MariaDB files in `/mnt/main/appdata/nextcloud-db`.
- Has a backup plan for the `nextcloud_app` Docker named volume, or that state has been intentionally moved to a bind mount.
- Uses cron background jobs.
- Is not exposed publicly before backups and HTTPS are proven.

## Recommended Implementation Path

If starting from the current TrueNAS system, do this:

1. Finish the TrueNAS storage pool and NFS setup.
2. Add `/mnt/main/userdata` as a TrueNAS parent dataset.
3. Create TrueNAS users such as `alice` and `bob`.
4. Create `/mnt/main/userdata/users/alice`, `/mnt/main/userdata/users/bob`, and `/mnt/main/userdata/shared`.
5. Set private folder permissions so each person can access only their own folder.
6. Create the `UserData` SMB share in TrueNAS.
7. Verify `alice` and `bob` SMB access from a desktop.
8. Verify the Docker VM can write to `/mnt/main/appdata` and `/mnt/media/data` over NFS.
9. Put app state under `/mnt/main/appdata`.
10. Put media under `/mnt/media/data`.
11. Add snapshots, database dumps, and off-site backup.
12. Add Syncthing only for specific user or shared folders that need device sync.
13. Add Nextcloud only if you still want its web UI, sharing, mobile app, calendar, contacts, or desktop sync.

## Practical Recommendation

Do not start by asking "Do I need Nextcloud?"

Start with:

```text
Where should my data live if every app breaks?
```

For this system, the answer should be:

```text
TrueNAS datasets:
/mnt/main/userdata/users/alice
/mnt/main/userdata/users/bob
/mnt/main/userdata/shared
/mnt/main/appdata
/mnt/main/backups
/mnt/media/data
```

Once that base is clean, Nextcloud becomes optional instead of critical.
