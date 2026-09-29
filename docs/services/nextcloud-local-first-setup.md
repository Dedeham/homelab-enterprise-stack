# Nextcloud Local-First Setup Guide

This is the dedicated Nextcloud guide for the current homelab. Nextcloud runs on
the Ubuntu Docker VM, while TrueNAS provides its persistent storage.

If you want Nextcloud isolated from compromise of the general Docker VM, use
[Nextcloud Dedicated VM Setup](nextcloud-dedicated-vm-setup.md) instead. That
variant gives Nextcloud its own VM, its own TrueNAS service account, and narrow
NFS exports.

Use this guide only after:

1. The `main` pool exists on TrueNAS.
2. The Docker VM mounts `192.168.1.10:/mnt/main` at `/mnt/main`.
3. Docker and Compose work on the Ubuntu Docker VM.
4. The Docker VM can write to `/mnt/main` as `mediauser`.

Do not install Nextcloud as a TrueNAS app. Do not expose it publicly during the
first deployment. Get LAN and Tailscale access, backups, and a restore test
working first.

## Final Placement

| Item | Create it on | Dataset or directory | Final path |
|---|---|---|---|
| Nextcloud user files | TrueNAS | Dataset `main/nextcloud` | `/mnt/main/nextcloud` |
| MariaDB files | TrueNAS | Child dataset `main/appdata/nextcloud-db` | `/mnt/main/appdata/nextcloud-db` |
| Nextcloud app/config | Docker VM | Docker named volume `nextcloud_app` | Docker-managed |
| Compose and `.env` | Docker VM | Normal directory | `/opt/docker/nextcloud` |
| Database dumps | TrueNAS | Directory inside `main/backups` | `/mnt/main/backups/db` |

In TrueNAS terminology these are **datasets** and **child datasets**, not
"subsets." A child dataset has its own permissions, snapshot policy, quota, and
ZFS properties even though it appears as a normal folder after NFS is mounted.

The required TrueNAS tree is:

```text
main                         pool
├── appdata                  existing dataset
│   └── nextcloud-db         create this child dataset
├── backups                  existing dataset
└── nextcloud                create this dataset directly under main
```

Do not create `/mnt/main/nextcloud` or
`/mnt/main/appdata/nextcloud-db` with `mkdir`. TrueNAS must create those two
mount points when it creates the datasets.

## Step 1: Create The TrueNAS Datasets

Open the TrueNAS web UI at `192.168.1.10`.

### Create `main/nextcloud`

1. Go to **Datasets**.
2. Select the `main` pool in the dataset tree.
3. Click **Add Dataset**.
4. Set **Name** to `nextcloud`.
5. Use the **Generic** preset, leave compression enabled, and leave
   deduplication disabled.
6. Save.

The result must be:

```text
Dataset: main/nextcloud
Path:    /mnt/main/nextcloud
```

### Create `main/appdata/nextcloud-db`

1. In **Datasets**, expand `main`.
2. Select the existing `main/appdata` dataset. This selection is important.
3. Click **Add Dataset**.
4. Set **Name** to `nextcloud-db`.
5. Use the **Generic** preset, leave compression enabled, and leave
   deduplication disabled.
6. Save.

The result must be:

```text
Dataset: main/appdata/nextcloud-db
Path:    /mnt/main/appdata/nextcloud-db
```

If you select `main` instead of `main/appdata`, TrueNAS creates the wrong path:

```text
/mnt/main/nextcloud-db
```

Delete that empty, incorrectly placed dataset in the TrueNAS UI and recreate it
under `main/appdata`. Never delete a dataset that already contains data.

## Step 2: Set Dataset Permissions In TrueNAS

For both `main/nextcloud` and `main/appdata/nextcloud-db`:

1. Select the dataset in **Datasets**.
2. Open **Permissions** and click **Edit**.
3. Set **Owner** to `mediauser`.
4. Set **Owner Group** to `mediauser`.
5. Use Unix permissions equivalent to:

   ```text
   Owner: read / write / execute
   Group: read / write / execute
   Other: no access
   Mode:  770
   ```

6. Save. Apply recursively only if the dataset already contains files whose
   ownership must be corrected.

This follows the existing UID/GID convention: `mediauser:mediauser`, normally
`3000:3000`, on TrueNAS and the Docker VM.

Do not make either dataset an SMB share. Nextcloud manages its data directory,
and direct file changes over SMB can leave the database index out of sync.

## Step 3: Confirm NFS Access From The Docker VM

The existing TrueNAS NFS export for `/mnt/main` must be restricted to the Docker
VM at `192.168.1.20`. The Docker VM should already mount it at `/mnt/main`.

On the Docker VM, verify the mount and both dataset paths:

```bash
findmnt /mnt/main
findmnt -T /mnt/main/nextcloud
findmnt -T /mnt/main/appdata/nextcloud-db
ls -ldn /mnt/main/nextcloud /mnt/main/appdata/nextcloud-db
```

Expected ownership is normally numeric UID/GID `3000 3000`. Run write tests:

```bash
sudo -u mediauser touch /mnt/main/nextcloud/.write-test
sudo -u mediauser rm /mnt/main/nextcloud/.write-test
sudo -u mediauser touch /mnt/main/appdata/nextcloud-db/.write-test
sudo -u mediauser rm /mnt/main/appdata/nextcloud-db/.write-test
```

Do not continue if either write test fails. Fix the TrueNAS dataset permissions,
the NFS export, or the matching `mediauser` UID/GID first.

## Step 4: Review The Compose Version

The compose file is:

```text
configs/docker/nextcloud/docker-compose.yml
```

Confirm that its Nextcloud image uses a currently supported major before every
new install or upgrade. The repository currently pins a major instead of using
`latest`. For an existing installation, upgrade one supported major at a time
and take backups before each major upgrade.

## Step 5: Copy And Configure The Stack

From the workstation:

```bash
scp -r configs/docker/nextcloud dockeradmin@192.168.1.20:/opt/docker/
ssh dockeradmin@192.168.1.20
```

On the Docker VM:

```bash
cd /opt/docker/nextcloud
cp .env.example .env
nano .env
```

Set strong, unique values for:

```text
NEXTCLOUD_ADMIN_PASSWORD
NEXTCLOUD_DB_PASSWORD
NEXTCLOUD_DB_ROOT_PASSWORD
REDIS_PASSWORD
```

Also set the domain values required by the compose file. Do not reuse TrueNAS,
Proxmox, router, or Vaultwarden credentials.

## Step 6: Confirm Traefik And Local DNS

The compose expects the external Docker network `proxy`:

```bash
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy
```

Create a local DNS record that points to the Docker VM, not TrueNAS:

```text
cloud.example.com -> 192.168.1.20
```

Use Pi-hole local DNS if it is available. Otherwise use a temporary hosts-file
entry for the first test. Do not add router port forwards.

## Step 7: Start Nextcloud

On the Docker VM:

```bash
cd /opt/docker/nextcloud
docker compose config
docker compose pull
docker compose up -d
docker compose ps
```

Watch the first startup:

```bash
docker compose logs -f nextcloud nextcloud-db nextcloud-redis
```

Then open:

```text
https://cloud.example.com
```

## Step 8: Complete The First Login

1. Open **Administration settings -> Overview** and resolve critical warnings.
2. Confirm background jobs use cron.
3. Enable Nextcloud 2FA for the admin account.
4. Create a non-admin daily account for each person.
5. Use app passwords for desktop and mobile clients.

Nextcloud accounts and TrueNAS SMB accounts are separate. They may share a
recognizable username, but they have separate passwords and permissions.

Do not put Authelia in front of Nextcloud unless its desktop and mobile client
flows have been tested. Nextcloud already provides login, 2FA, and app passwords.

## Step 9: Keep Local User Data Separate

Use this split:

```text
/mnt/main/userdata   normal SMB and optional Syncthing storage
/mnt/main/nextcloud  Nextcloud-managed primary data
```

Do not point Nextcloud's primary data directory at `/mnt/main/userdata`, and do
not edit `/mnt/main/nextcloud` directly through SMB. Nextcloud tracks files in
its database.

If Nextcloud must show an existing shared folder, configure that folder later as
restricted external storage. Mount only the specific shared folder into the
container; never expose all of `/mnt/main/userdata/users` to Nextcloud.

## Step 10: Configure Snapshots And Backups

In **TrueNAS -> Data Protection -> Periodic Snapshot Tasks**, create:

| Dataset | Recursive | Starting schedule | Retention |
|---|---:|---|---|
| `main/nextcloud` | Yes | Daily | 30 days |
| `main/appdata/nextcloud-db` | Yes | Every 6 hours | 14 days |
| `main/backups` | Yes | Daily, after the DB dump | 30 days |

Also protect the Docker named volume `nextcloud_app`. It contains Nextcloud
configuration and installed app state and is not covered by TrueNAS snapshots.

Use `scripts/backup/db-backup.sh` on the Docker VM to create a logical MariaDB
dump under `/mnt/main/backups/db`. A live filesystem snapshot does not replace a
logical database dump. Follow the repository's
[storage and backup plan](../backup-strategy/storage-and-backup-plan.md) for the
off-server copy and restore procedure.

## Step 11: Verify Before Public Exposure

Complete all of these checks:

- `docker compose ps` shows the Nextcloud, MariaDB, Redis, and cron containers
  healthy or running as expected.
- A test file uploads and downloads over LAN.
- Tailscale access works if required.
- A logical MariaDB dump exists under `/mnt/main/backups/db`.
- The `nextcloud_app` named volume has a documented backup.
- One test file has been restored successfully.
- Nextcloud runs a currently supported major.
- Admin 2FA is enabled and placeholder passwords are gone.
- HTTPS works through Traefik.

Public access is a separate final step. Do not expose Proxmox, TrueNAS, SSH,
Grafana, or other management services with Nextcloud.
