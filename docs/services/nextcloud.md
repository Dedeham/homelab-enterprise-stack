# Nextcloud

Nextcloud provides a web UI, sync layer, sharing layer, and calendar/contacts server on top of the homelab's TrueNAS-backed storage. It is intentionally not the base storage layer — TrueNAS datasets remain the source of truth for user data, with Nextcloud as an optional layer on top (see [docs/services/user-data-storage.md](user-data-storage.md)).

Two architectures for running Nextcloud exist in this homelab's design: a **local-first** deployment on the general Ubuntu Docker VM, and a **dedicated-VM** deployment that isolates Nextcloud on its own Proxmox VM. The local-first deployment is the simpler, currently-documented default; the dedicated-VM variant is the recommended upgrade when isolating Nextcloud from a potential Docker VM compromise matters more than keeping every app on one VM.

## Local-First Deployment (Docker VM)

| Item | Location | Notes |
|---|---|---|
| Nextcloud user files | TrueNAS dataset `main/nextcloud` | Mounted on the Docker VM at `/mnt/main/nextcloud` |
| MariaDB files | TrueNAS child dataset `main/appdata/nextcloud-db` | At `/mnt/main/appdata/nextcloud-db` |
| Nextcloud app/config | Docker VM | Docker named volume `nextcloud_app` |
| Compose and `.env` | Docker VM | `/opt/docker/nextcloud` |
| Database dumps | TrueNAS, inside `main/backups` | `/mnt/main/backups/db` |
| Public hostname | `cloud.example.com` | Routed by Traefik on the Docker VM (`192.168.1.20`) |

Both TrueNAS datasets are owned by `mediauser` (normally UID/GID `3000:3000`), the same service account used for the rest of the Docker VM's NFS-backed storage. Nextcloud's data directory and the MariaDB dataset are never exposed as SMB shares, since direct SMB edits under Nextcloud's data directory can desync its database index.

## Dedicated-VM Deployment (Isolated)

| Item | Location | Notes |
|---|---|---|
| Nextcloud VM | `192.168.1.30`, Proxmox VM `112` | Runs only Nextcloud, MariaDB, Redis, cron |
| Nextcloud service user | `nextcloudsvc`, UID/GID `3100:3100` | Separate from the Docker VM's `mediauser` |
| Nextcloud user files | TrueNAS dataset `main/nextcloud` | Mounted on the Nextcloud VM as `/mnt/nc-data` |
| MariaDB files | TrueNAS child dataset `main/appdata/nextcloud-db` | Mounted as `/mnt/nc-db` |
| DB/app backups | `/mnt/main/backups/nextcloud-db` | Mounted as `/mnt/nc-backups` |
| App/config | Nextcloud VM local SSD | `/opt/docker/nextcloud/html` |
| Public hostname | `cloud.example.com` | Traefik stays on the Docker VM; reaches the Nextcloud VM via the Traefik file provider (not Docker labels, since it's a different Docker engine) |

The key isolation property: NFS exports for the three Nextcloud-related TrueNAS paths are restricted to `192.168.1.30/32` only — the general Docker VM (`192.168.1.20`) is never added to these exports, so a compromised Docker VM cannot read or write Nextcloud's data or database even though it may still see the paths exist. The Nextcloud VM's own UFW firewall allows SSH from the LAN and allows the Docker VM to reach the Nextcloud web container on port `8080` only; MariaDB, Redis, Docker, and the NFS mounts are not reachable from outside the VM. `DOCKER-USER` iptables rules narrow inbound access to the Nextcloud web container's Docker subnet specifically. Updates are performed manually on the Nextcloud VM rather than through Watchtower on the general Docker VM, to avoid creating a cross-VM control path that would undermine the isolation.

Running two Nextcloud instances against the same data directory/database (e.g. during a migration from local-first to dedicated-VM) is explicitly unsupported — a migration requires a maintenance window: dump the database, stop the old stack, snapshot the data, re-home ownership to `nextcloudsvc`, then start the dedicated VM stack.

## Reverse Proxy And Headers

In both deployments, Traefik is the only HTTPS entrypoint (`websecure`, Cloudflare cert resolver), and the generic `security-headers@file` middleware is deliberately **not** attached to the Nextcloud router — that middleware sets `X-Frame-Options: DENY`, while Nextcloud's web UI expects `X-Frame-Options: SAMEORIGIN` for some of its own UI elements.

## Keeping Human Storage Separate

```text
/mnt/main/userdata   normal SMB and optional Syncthing storage
/mnt/main/nextcloud  Nextcloud-managed primary data
```

Nextcloud's primary data directory is never pointed at `/mnt/main/userdata`, and `/mnt/main/nextcloud` is never edited directly over SMB. If an existing shared folder needs to be visible in Nextcloud, it is added later as restricted external storage for that specific folder rather than mounting all of `/mnt/main/userdata/users` into the container.

## Accounts, 2FA, And Onboarding

Nextcloud accounts are separate from TrueNAS SMB accounts (they may share a recognizable username but never a password). Admin 2FA is enabled; Authelia/Cloudflare Access are not placed in front of Nextcloud by default, since Nextcloud already has its own login/2FA/app-password flow that desktop and mobile sync clients depend on.

### Outbound Email (SMTP) And User Onboarding

Nextcloud sends password-reset, activation, and notification email through an outbound SMTP relay rather than a self-hosted mail server (residential IP reputation, reverse DNS, and blocked ports make self-hosting fragile). The current provider is **Brevo** (formerly Sendinblue), using its free-tier SMTP relay:

| Item | Value |
|---|---|
| Sender address | `nextcloud@example.com` |
| SMTP host | `smtp-relay.brevo.com` |
| Port | `587` (STARTTLS), fallback `465` (SSL) |
| Auth | Brevo SMTP key (not the Brevo account's login password) |

Domain authentication (SPF/DKIM/DMARC records added in Cloudflare DNS, DNS-only/not proxied) is used instead of simple per-address verification, for better deliverability. The Brevo account's own login email is unrelated to the Nextcloud sender identity — it only gates access to the Brevo dashboard, and can be any address the operator controls (a personal mailbox is fine for the login; it is never the visible "From" address Nextcloud mail uses).

Onboarding policy: invite-only. Public self-registration (the `registration` app) stays disabled unless there's a specific reason to open it, and when enabled it requires email verification and admin approval rather than open signup. New users are created with no password set — Nextcloud emails them an activation link, and they choose their own password, so the administrator never knows or handles user passwords. Password policy requires a minimum length of 12, forbids common passwords, and admin 2FA is mandatory.

The SMTP credential is stored in Nextcloud's own configuration (`config.php` in the dedicated-VM layout), not in this repository. Once SMTP is configured, the Nextcloud app/config backup archive contains that secret and is treated accordingly.

## Backups

| Deployment | Database dump | App/config backup | Schedule |
|---|---|---|---|
| Local-first | `/mnt/main/backups/db` (logical MariaDB dump) | `nextcloud_app` named volume (documented separately) | Daily snapshot of `main/nextcloud`; every-6-hours snapshot of `main/appdata/nextcloud-db` |
| Dedicated-VM | `/mnt/nc-backups` (logical dump + app archive) | Same mount | Daily cron dump before the TrueNAS snapshot window |

Both layouts rely on TrueNAS snapshots for the datasets plus a logical database dump (a ZFS snapshot of a live database is not a substitute for a clean logical dump), and both require at least one proven restore test before Nextcloud is exposed publicly. Public exposure is gated on: HTTPS working through Traefik, 2FA enabled, placeholder passwords removed, a successful restore test, and (dedicated-VM) confirmation that the general Docker VM cannot write to the Nextcloud datasets.
