# User Data Storage (Local-First)

This describes how human user data is stored in the homelab independent of any particular application — the durable storage foundation that Nextcloud and other apps sit on top of, rather than being replaced by them.

## Design

1. TrueNAS owns the disks, datasets, snapshots, SMB shares, and NFS exports.
2. The Ubuntu Docker VM runs applications only; it has no durable state of its own.
3. Docker containers reach TrueNAS storage through NFS mounts.
4. Windows, macOS, and Linux desktops reach TrueNAS directly through SMB shares.
5. Nextcloud is optional: a web UI, sync layer, sharing layer, and calendar/contacts server — not the base storage layer. (See [docs/services/nextcloud.md](nextcloud.md).)

## Current Layout

| Component | Value |
|---|---|
| TrueNAS VM | `192.168.1.10` |
| Ubuntu Docker/services VM | `192.168.1.20` |
| Main TrueNAS pool | `/mnt/main` |
| Media TrueNAS path | `/mnt/media/data` |
| Docker VM main mount | `/mnt/main` (NFS) |
| Docker VM media mount | `/mnt/media/data` (NFS) |
| Service user/group | `mediauser:mediauser`, normally UID/GID `3000:3000` |
| Human users | TrueNAS local users, e.g. `alice`, `bob` |

TrueNAS runs storage only — Nextcloud, Jellyfin, ARR apps, Pi-hole, Traefik, and other Docker services all run on the Ubuntu Docker VM, never on TrueNAS.

### Dataset tree

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

On the Docker VM, the same paths appear through NFS at `/mnt/main` and `/mnt/media/data`. Compose files bind-mount these TrueNAS-backed paths directly rather than relying on anonymous Docker volumes for anything that matters. `/srv/homelab` is not used — that convention belongs to a single-Debian-storage-server design, not this TrueNAS-backed one.

### What each layer is for

| Need | Use |
|---|---|
| ZFS pools, datasets, snapshots, scrubs, SMART checks | TrueNAS |
| LAN file shares for desktops | TrueNAS SMB |
| Storage for Docker containers | TrueNAS NFS, mounted on the Docker VM |
| App configs and databases | `/mnt/main/appdata` |
| Important user files outside Nextcloud | `/mnt/main/userdata/users/USERNAME` |
| Shared household/team files | `/mnt/main/userdata/shared` |
| Nextcloud user files | `/mnt/main/nextcloud` |
| Media library and downloader output | `/mnt/media/data` |
| Compose files and `.env` | `/opt/docker` on the Docker VM |
| Optional web file UI and sync clients | Nextcloud on the Docker VM |
| Backups and logical database dumps | `/mnt/main/backups` plus off-site backup |

## Multi-User Access Model

Each person has their own TrueNAS local user (`alice`, `bob`, etc.) and a private folder under `/mnt/main/userdata/users/<name>` (`documents/`, `photos/`, `scans/`, `personal/`), accessible only to that user (mode `0700`/owner-only, or an equivalent ACL granting that user full control and no one else access). A `homelab-users` group grants access to shared folders under `/mnt/main/userdata/shared` (`family/`, `scans/`, `transfer/`), set group-writable (mode `2770`/`0660`) for members of that group.

`mediauser` — the service account the Docker VM uses over NFS — is deliberately **not** granted access to private human folders by default, and is only granted access to `/mnt/main/userdata/shared` if a specific Docker service genuinely needs to read/write shared files. The NFS export for `/mnt/main` maps Docker VM access to `mediauser` (`Mapall User`/`Mapall Group: mediauser`), so TrueNAS dataset/ACL permissions are what actually keep `mediauser` out of private folders, not the NFS export itself.

| Login | Can access | Cannot access |
|---|---|---|
| `alice` | `users/alice`, `shared` | `users/bob` |
| `bob` | `users/bob`, `shared` | `users/alice` |
| `mediauser` | App/media paths, and `shared` only if a service needs it | Private human folders |

SMB shares exposed from TrueNAS:

| SMB share | TrueNAS path | Purpose |
|---|---|---|
| `UserData` | `/mnt/main/userdata` | Parent share for per-user and shared folders |
| `Media` | `/mnt/media/data` (or `/mnt/main/media/data` on the one-pool fallback) | Media library and downloads |
| `Backups` | `/mnt/main/backups` | Recovery files, exports, database dumps |

People log in to SMB as themselves (`alice`, `bob`), never as `mediauser`, TrueNAS `root`, or the TrueNAS admin account.

## NFS Exports

| Path | Authorized client | Mapping |
|---|---|---|
| `/mnt/main` | `192.168.1.20/32` | `Mapall User/Group: mediauser` |
| `/mnt/media/data` (or `/mnt/main/media/data` on one pool) | `192.168.1.20/32` | `Mapall User/Group: mediauser` |

NFS exports are restricted to the Docker VM only; SMB requires a password and does not allow guest access.

## Docker App Data Convention

Compose files live on the Docker VM under `/opt/docker/SERVICE`; persistent service state lives on TrueNAS under `/mnt/main/appdata/SERVICE`; human files live outside hidden Docker volumes, under `/mnt/main/userdata/...`, `/mnt/main/nextcloud`, or `/mnt/media/data`. For multi-user storage, containers mount only the specific folder they need (e.g. `/mnt/main/userdata/shared` or `/mnt/main/userdata/users/alice/photos`), never the whole `/mnt/main/userdata` tree.

## Optional Device Sync (Syncthing)

Syncthing, when deployed, syncs selected folders (laptop documents, notes, project folders, phone photo backup) between devices without a cloud account. It is not used to sync the full media library. Each managed folder is mounted explicitly (e.g. `/mnt/main/userdata/users/alice/documents`, `/mnt/main/userdata/users/alice/photos`, `/mnt/main/userdata/shared`); a second person (`bob`) gets either additional explicit mounts or a fully separate Syncthing instance/config path (`/mnt/main/appdata/syncthing-bob`) so `mediauser` only touches the specific folders Syncthing is meant to sync. People who don't want the Docker VM touching their private files run Syncthing directly between their own devices and use SMB only for manual access.

## Backups

Snapshots alone are not a complete backup. The baseline:

| Dataset | Schedule | Retention |
|---|---|---|
| `main/userdata` | Daily | 30 days |
| `main/appdata` | Every 6 hours | 14 days |
| `main/nextcloud` (if Nextcloud is used) | Daily | 30 days |
| `main/backups` | Daily | 30 days |
| `media/data` | Daily or weekly | 7-14 days |

Logical database dumps (via `scripts/backup/db-backup.sh`) land in `/mnt/main/backups/db` and are snapshotted alongside everything else; a live ZFS snapshot of a database is not treated as equivalent to a logical dump for restore purposes. Off-site backup or cloud sync covers irreplaceable data beyond the single server.

## Relationship To Nextcloud

This storage foundation is complete and usable without Nextcloud. Nextcloud is added on top only when its web UI, sharing, mobile upload, desktop sync, calendar, or contacts features are actually wanted — see [docs/services/nextcloud.md](nextcloud.md) for how it's layered in (`/mnt/main/nextcloud` for Nextcloud-managed data, kept separate from `/mnt/main/userdata`).
