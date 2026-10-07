# User Data Storage Setup And Testing

Builds the local-first storage foundation on TrueNAS (datasets, per-user SMB access, Docker VM NFS verification, snapshots/backups) before any app — including Nextcloud — is deployed on top of it. See [docs/services/user-data-storage.md](../../services/user-data-storage.md) for the resulting layout.

This guide can be followed before Nextcloud. Do not start Nextcloud containers until this guide's storage checks pass and the Nextcloud compose has been reviewed for a supported major version.

## Pasteable Fast Path For The First User (`alice`)

Use this after the `main` pool exists in TrueNAS and the Docker VM already mounts `/mnt/main` and `/mnt/media/data`.

In the **TrueNAS UI**, create:

| Type | Name | Notes |
|---|---|---|
| Group | `homelab-users` | Shared group for `/mnt/main/userdata/shared` access |
| User | `alice` | Add to `homelab-users`; enable SMB/password login |
| Dataset | `main/userdata` | Creates `/mnt/main/userdata` as a real ZFS dataset |

Do not create `/mnt/main/userdata` with `mkdir` — if it exists as a plain folder, TrueNAS cannot create the dataset there.

In the **TrueNAS Shell**, paste as one `sudo bash <<'EOF' ... EOF` block (a bare `sudo FIRST_USER="alice"` prefix does **not** run the following commands as root):

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
  echo "ERROR: main/userdata is not a ZFS dataset. Create it in the TrueNAS UI first."
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

If you see `groupadd: Permission denied` / `mkdir: cannot create directory '/mnt/main/userdata': Permission denied`, the commands were not running as root — use the full `sudo bash <<'EOF'` block, or `sudo -i` first.

If the TrueNAS UI says `Path /mnt/main/userdata already exists` while creating the dataset, `/mnt/main/userdata` is a plain directory, not yet a dataset. Move it aside first:

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
  echo "No existing /mnt/main/userdata path found. Create dataset main/userdata in the TrueNAS UI."
fi
EOF
```

Then create dataset `main/userdata` in the TrueNAS UI. If the moved directory had files worth keeping, copy them back once the dataset exists:

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
echo "Leave ${BACKUP_PATH} in place until verified."
EOF
```

Create the SMB share in the **TrueNAS UI**: **Shares → Windows (SMB) Shares** → path `/mnt/main/userdata`, name `UserData` → enable the SMB service if prompted.

On the **Ubuntu Docker VM**, verify mounts and app-write paths:

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

From Windows: `\\192.168.1.10\UserData\users\alice` and `\\192.168.1.10\UserData\shared`. If Windows previously connected as `mediauser`, clear the cached SMB session first:

```bat
net use
net use \\192.168.1.10\UserData /delete
net use \\192.168.1.10\IPC$ /delete
cmdkey /delete:192.168.1.10
```

Then reconnect as `alice`:

```bat
net use \\192.168.1.10\UserData /user:alice *
```

If Windows still uses the wrong account, remove saved entries for `192.168.1.10`/`truenas` from **Control Panel → Credential Manager → Windows Credentials**, sign out/in (or reboot), and reconnect.

From macOS Finder: `smb://192.168.1.10/UserData`.

### Adding another user later

Create the user in the TrueNAS UI (add to `homelab-users` if they need shared access), then in the **TrueNAS Shell**:

```bash
sudo bash <<'EOF'
set -euo pipefail

NEW_USER="bob"
USERDATA_ROOT="/mnt/main/userdata"

if ! zfs list main/userdata >/dev/null 2>&1; then
  echo "ERROR: main/userdata is not a ZFS dataset. Create it first."
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

Verify the new user can open their own folder and cannot open anyone else's.

## Phase 1: Confirm The TrueNAS Foundation

Before continuing, confirm: TrueNAS reachable at `https://192.168.1.10`; Docker VM at `192.168.1.20`; the `main` pool exists; `/mnt/main/appdata` and `/mnt/main/backups` exist; `/mnt/main/nextcloud` exists if Nextcloud is planned; `/mnt/media/data` exists (or the one-pool fallback is in use); NFS exports restricted to `192.168.1.20/32`; SMB is password-protected with no guest access; `mediauser` owns app/media datasets; human users are separate TrueNAS accounts.

Create the shared group: **Credentials → Local Groups** → `homelab-users`.

Create `/mnt/main/userdata` as the parent dataset: **Datasets** → select `main` → Add Dataset → name `userdata`, compression on, dedup off, owner an admin-capable account or `root`, group `homelab-users`, permissions owner rwx / group r-x / other none.

Create one TrueNAS local user per person (**Credentials → Local Users**): `alice`, `bob`, etc., each with a strong unique password, added to `homelab-users` for shared access. Never use `mediauser` as a person's SMB login.

Create the folder layout under `/mnt/main/userdata/` (`users/<name>/{documents,photos,scans,personal}`, `shared/{family,scans,transfer}`) with the ownership model described in [docs/services/user-data-storage.md](../../services/user-data-storage.md): private folders owned by their user (rwx owner, no group/other access unless intentionally granted), shared folders owned by admin/`root` with `homelab-users` group rwx. `mediauser` gets access to `shared` only if a Docker service specifically needs it, and never gets access to private user folders by default.

Repeat the same pattern for each future user (`user3`, etc.): create the TrueNAS user, add their private folder, set ownership, add to `homelab-users` if they need `shared`.

## Phase 2: SMB Access From Desktops

Samba is not installed on the Docker VM for these folders — SMB belongs on TrueNAS. Shares:

| SMB share | TrueNAS path |
|---|---|
| `UserData` | `/mnt/main/userdata` |
| `Media` | `/mnt/media/data` (or `/mnt/main/media/data`) |
| `Backups` | `/mnt/main/backups` |

**Shares → Windows (SMB) Shares** → add `/mnt/main/userdata` as `UserData` → save, enable SMB if prompted, confirm the service starts automatically.

Windows: `\\192.168.1.10\UserData`, per-user paths `\\192.168.1.10\UserData\users\alice` etc. macOS: `smb://192.168.1.10/UserData`. Log in as the person's own TrueNAS user, never `mediauser`/`root`/admin.

At this point local-first storage works without Nextcloud at all.

## Phase 3: Docker VM NFS Mounts

Expected mounts:

```text
192.168.1.10:/mnt/main       -> /mnt/main
192.168.1.10:/mnt/media/data -> /mnt/media/data
```

(or, on the one-pool fallback, `192.168.1.10:/mnt/main/media/data -> /mnt/media/data`).

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

Do not deploy apps until these pass — fix TrueNAS dataset permissions or NFS `Mapall User`/`Mapall Group` first. Do not require `mediauser` to write to private folders (`users/alice`, `users/bob`); only test/grant shared access if a service truly needs it:

```bash
sudo -u mediauser touch /mnt/main/userdata/shared/.docker-vm-write-test
sudo -u mediauser rm /mnt/main/userdata/shared/.docker-vm-write-test
```

Recommended NFS export settings on TrueNAS:

```text
Path: /mnt/main                    (or /mnt/main/media/data for one-pool)
Authorized client: 192.168.1.20/32
Mapall User: mediauser
Mapall Group: mediauser
```

```text
Path: /mnt/media/data
Authorized client: 192.168.1.20/32
Mapall User: mediauser
Mapall Group: mediauser
```

Because the export maps all Docker VM NFS access to `mediauser`, TrueNAS dataset/ACL permissions are what actually keeps `mediauser` out of private folders — the NFS export alone does not.

## Phase 4: Store Docker App Data Correctly

Compose files: `/opt/docker/SERVICE`. Persistent service data: `/mnt/main/appdata/SERVICE`. Human files, outside anonymous Docker volumes: `/mnt/main/userdata/users/<name>`, `/mnt/main/userdata/shared`, `/mnt/main/nextcloud`, `/mnt/media/data`.

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

For multi-user storage, mount only the specific folder a service needs — never all of `/mnt/main/userdata`.

## Phase 5: Optional Device Sync With Syncthing

Good use cases: laptop documents, notes, project folders, phone photo backup into a specific folder, a small personal folder synced across devices. Avoid syncing the full media library unless copies on every device are actually wanted.

```yaml
volumes:
  - /mnt/main/appdata/syncthing:/var/syncthing/config
  - /mnt/main/userdata/users/alice/documents:/data/alice-documents
  - /mnt/main/userdata/users/alice/photos:/data/alice-photos
  - /mnt/main/userdata/shared:/data/shared
```

For a second person (`bob`), either add separate mounts or run a fully separate instance/config path:

```text
/mnt/main/appdata/syncthing-bob
/mnt/main/userdata/users/bob/documents
/mnt/main/userdata/users/bob/photos
```

Only grant `mediauser` access to the specific folders Syncthing must sync. If you don't want the Docker VM touching a person's private files at all, run Syncthing directly between their own devices and use SMB only for manual access.

After first start: open `http://192.168.1.20:8384` on the LAN, set a GUI username/password, add devices explicitly, share only intended folders, keep large and small folders separate.

## Phase 6: Back Up User Data

Minimum plan: TrueNAS snapshots for `/mnt/main/userdata`, `/mnt/main/appdata`, `/mnt/main/nextcloud` (if used), and `/mnt/main/backups`; logical database dumps into `/mnt/main/backups/db`; off-site backup/cloud sync for irreplaceable data.

| Dataset | Schedule | Retention |
|---|---|---|
| `main/userdata` | Daily | 30 days |
| `main/appdata` | Every 6 hours | 14 days |
| `main/nextcloud` | Daily | 30 days |
| `main/backups` | Daily | 30 days |
| `media/data` | Daily or weekly | 7-14 days |

Use `scripts/backup/db-backup.sh` to dump databases to `/mnt/main/backups/db`, let the TrueNAS snapshot task capture the dumps, and include them in off-site backup. Do not consider a backup real until it has been restored once.

## Phase 7: Optional Nextcloud Handoff

The storage foundation is complete without Nextcloud. Add it only for its web UI, sharing, mobile upload, desktop sync, calendar, or contacts features — continue with [docs/setup-and-testing/services/nextcloud.md](nextcloud.md), which covers the TrueNAS child-dataset locations, permissions, container deployment, local DNS, backup, and verification. Keep `/mnt/main/userdata` (normal storage) and `/mnt/main/nextcloud` (Nextcloud-managed) separate — do not point Nextcloud's primary data directory at `/mnt/main/userdata`, and do not create the Nextcloud dataset paths with `mkdir` on the Docker VM.

## Operational Checklist

Storage:

- [ ] `/mnt/main/userdata` exists on TrueNAS.
- [ ] `/mnt/main/userdata/users/alice` exists, owned by `alice`.
- [ ] `/mnt/main/userdata/users/bob` exists, owned by `bob`.
- [ ] `/mnt/main/userdata/shared` exists, writable by `homelab-users`.
- [ ] `/mnt/main/appdata` and `/mnt/main/backups` exist on TrueNAS.
- [ ] `/mnt/media/data` exists (or the one-pool fallback is documented).
- [ ] `mediauser` owns the datasets Docker writes to, and has no access to private human folders unless intentionally granted.

Shares:

- [ ] SMB `UserData` points to `/mnt/main/userdata`.
- [ ] `alice` can access `UserData\users\alice` but not `UserData\users\bob` (and vice versa for `bob`).
- [ ] Intended users can access `UserData\shared`.
- [ ] SMB is password-protected; NFS exports restricted to `192.168.1.20/32`.

Docker VM:

- [ ] `findmnt /mnt/main` and `findmnt /mnt/media/data` show the TrueNAS NFS exports.
- [ ] `sudo -u mediauser` can write to `/mnt/main/appdata` and `/mnt/media/data`.
- [ ] `sudo -u mediauser` can write to `/mnt/main/userdata/shared` only if a service needs it.
- [ ] Compose files live in `/opt/docker`; persistent data uses bind mounts under `/mnt/main` or `/mnt/media/data`.

Backups:

- [ ] TrueNAS snapshots exist for important datasets.
- [ ] Database dumps land in `/mnt/main/backups/db`.
- [ ] A restore test has succeeded.
- [ ] One backup copy exists away from the main server.

Nextcloud, if used:

- [ ] Runs on the Docker VM (or a dedicated VM), not TrueNAS.
- [ ] Stores user files in `/mnt/main/nextcloud`, MariaDB files in `/mnt/main/appdata/nextcloud-db`.
- [ ] Separate Nextcloud accounts exist for daily users.
- [ ] `nextcloud_app` named volume has a documented backup, or that state has been moved to a bind mount.
- [ ] Uses cron background jobs.
- [ ] Not exposed publicly before backups and HTTPS are proven.

## Recommended Implementation Path

1. Finish the TrueNAS storage pool and NFS setup.
2. Add `/mnt/main/userdata` as a TrueNAS parent dataset.
3. Create TrueNAS users (`alice`, `bob`, ...).
4. Create each user's private folder and `/mnt/main/userdata/shared`.
5. Set private-folder permissions so each person can access only their own folder.
6. Create the `UserData` SMB share.
7. Verify SMB access from a desktop for each user.
8. Verify the Docker VM can write to `/mnt/main/appdata` and `/mnt/media/data` over NFS.
9. Put app state under `/mnt/main/appdata`, media under `/mnt/media/data`.
10. Add snapshots, database dumps, and off-site backup.
11. Add Syncthing only for specific user/shared folders that need device sync.
12. Add Nextcloud only if its web UI, sharing, mobile app, calendar, contacts, or desktop sync is actually wanted.
