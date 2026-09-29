# Nextcloud Dedicated VM Setup Guide

This guide deploys Nextcloud in its own Proxmox VM so a compromise of the
general Ubuntu Docker VM does not automatically give write access to Nextcloud
files or its database.

The design stays consistent with the rest of the homelab:

1. TrueNAS owns storage, datasets, snapshots, and backups.
2. The dedicated Nextcloud VM runs only Nextcloud, MariaDB, Redis, and cron.
3. The general Docker VM still runs Traefik and other services.
4. The Nextcloud VM mounts only the TrueNAS paths it needs.
5. Nextcloud remains a sync/web layer, not the base storage layer for all human
   data.

Use this guide instead of
[Nextcloud Local-First Setup](nextcloud-local-first-setup.md) when isolation
from the general Docker VM is more important than keeping every app in one VM.

## Target Layout

| Item | Location | Notes |
|---|---|---|
| TrueNAS VM | `192.168.1.10` | Storage only |
| Docker VM | `192.168.1.20` | Traefik and non-Nextcloud services |
| Nextcloud VM | `192.168.1.30` | New dedicated VM |
| Nextcloud VM ID | `112` | Suggested Proxmox ID |
| Nextcloud service user | `nextcloudsvc` | Suggested UID/GID `3100:3100` |
| Nextcloud user files | TrueNAS dataset `main/nextcloud` | Mounted on VM as `/mnt/nc-data` |
| MariaDB files | TrueNAS child dataset `main/appdata/nextcloud-db` | Mounted as `/mnt/nc-db` |
| Nextcloud DB/app backups | TrueNAS directory `/mnt/main/backups/nextcloud-db` | Mounted as `/mnt/nc-backups` |
| Nextcloud app/config | VM local SSD | `/opt/docker/nextcloud/html` |
| Public hostname | `cloud.example.com` | Routed by Traefik on Docker VM |

The important isolation change is the service account. The Docker VM normally
writes to TrueNAS as `mediauser`. This guide makes the Nextcloud datasets owned
by `nextcloudsvc` instead, and the NFS exports are restricted to
`192.168.1.30/32`. Do not add `mediauser` to the `nextcloudsvc` group.

## Phase 0: Do Not Migrate Blindly

If you already deployed Nextcloud on the Docker VM, stop here and plan a
migration window. Do not run two Nextcloud instances against the same data
directory or database.

Clean first deployment:

1. Follow this guide from the start.
2. Do not start the old Docker-VM Nextcloud stack.
3. Do not expose `cloud.example.com` publicly until backup and restore checks
   pass.

Existing deployment migration:

1. Take a logical MariaDB dump.
2. Stop the old Nextcloud stack.
3. Snapshot `main/nextcloud`, `main/appdata/nextcloud-db`, and backups.
4. Change ownership and NFS access to `nextcloudsvc`.
5. Start the dedicated VM stack.
6. Run `occ maintenance:repair` and verify file access.

## Phase 1: Create The Nextcloud VM

In Proxmox, create a small Ubuntu Server or Debian VM.

Suggested VM settings:

| Setting | Value |
|---|---|
| VM ID | `112` |
| Name | `nextcloud` |
| vCPU | `2` to `4` |
| RAM | `4 GB` minimum, `6 GB` better |
| Boot disk | `32 GB` on `ssd-fast` |
| Network | LAN bridge, static IP `192.168.1.30` |
| Start order | After TrueNAS and before or alongside Docker VM |

Do not pass through disks. Do not mount the whole `main` pool. Do not install
Samba on this VM.

Set the static IP in the VM:

```text
IP:      192.168.1.30/24
Gateway: 192.168.1.1
DNS:     192.168.1.1 or Pi-hole
```

Update the router or DHCP server so `192.168.1.30` is reserved for this VM.

## Phase 2: Harden The VM Base

Run these on the Nextcloud VM:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y ca-certificates curl gnupg nfs-common ufw fail2ban
sudo timedatectl set-timezone Europe/Berlin
```

Create the service account with the same UID/GID that will exist on TrueNAS:

```bash
sudo groupadd -g 3100 nextcloudsvc
sudo useradd -u 3100 -g 3100 -M -s /usr/sbin/nologin nextcloudsvc
id nextcloudsvc
```

Install Docker and Compose using the same Docker method used in the Ubuntu
Docker VM guide:

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker "$USER"
```

Log out and log back in so the `docker` group membership applies. If you want
to apply it in the current shell without logging out, run:

```bash
newgrp docker
```

Verify:

```bash
docker --version
docker compose version
docker run --rm hello-world
```

Only trusted admin users should be in the `docker` group. Docker access is root
equivalent on this VM.

## Phase 3: Create TrueNAS Account, Datasets, And Permissions

In the TrueNAS UI, create:

| Item | Value |
|---|---|
| Group | `nextcloudsvc`, GID `3100` |
| User | `nextcloudsvc`, UID `3100`, primary group `nextcloudsvc` |

Create or confirm these datasets:

```text
main/nextcloud
main/appdata/nextcloud-db
```

Create this backup directory:

```text
/mnt/main/backups/nextcloud-db
```

For `main/nextcloud` and `main/appdata/nextcloud-db`, set:

```text
Owner: nextcloudsvc
Group: nextcloudsvc
Mode:  770
```

For `/mnt/main/backups/nextcloud-db`, set the same owner and mode. If using the
TrueNAS ACL editor, remove broad entries that let `mediauser`, guest, or
everyone write.

Do not make `main/nextcloud` an SMB share. Direct SMB edits under the Nextcloud
data directory can desync the Nextcloud database.

## Phase 4: Create Narrow NFS Exports

Create three NFS shares in TrueNAS, each restricted to the Nextcloud VM only.
Do not use `Mapall` for these exports. Docker images such as MariaDB and
Nextcloud need to `chown` their data directories during first startup, and
`Mapall` blocks that.

| TrueNAS path | Authorized host | Mapping |
|---|---|---|
| `/mnt/main/nextcloud` | `192.168.1.30/32` | `Maproot User: root`, `Maproot Group: root` |
| `/mnt/main/appdata/nextcloud-db` | `192.168.1.30/32` | `Maproot User: root`, `Maproot Group: root` |
| `/mnt/main/backups/nextcloud-db` | `192.168.1.30/32` | `Maproot User: root`, `Maproot Group: root` |

If TrueNAS offers `wheel` instead of `root` as the root group, use that. Leave
`Mapall User` and `Mapall Group` unset.

Do not add the Docker VM IP to these exports. The whole point is that a
compromised Docker VM should not have NFS write access to Nextcloud storage.

If the Docker VM already mounts `/mnt/main`, keep the Nextcloud datasets closed
to `mediauser`. The Docker VM may still see that paths exist, but it should not
be able to read or write them.

## Phase 5: Mount Only The Needed Paths

On the Nextcloud VM:

```bash
sudo mkdir -p /mnt/nc-data /mnt/nc-db /mnt/nc-backups
sudo chown root:root /mnt/nc-data /mnt/nc-db /mnt/nc-backups
```

Add mounts to `/etc/fstab`:

```text
192.168.1.10:/mnt/main/nextcloud /mnt/nc-data nfs4 defaults,_netdev,noatime,hard,timeo=600,retrans=2 0 0
192.168.1.10:/mnt/main/appdata/nextcloud-db /mnt/nc-db nfs4 defaults,_netdev,noatime,hard,timeo=600,retrans=2 0 0
192.168.1.10:/mnt/main/backups/nextcloud-db /mnt/nc-backups nfs4 defaults,_netdev,noatime,hard,timeo=600,retrans=2 0 0
```

Mount and verify:

```bash
sudo mount -a
findmnt /mnt/nc-data
findmnt /mnt/nc-db
findmnt /mnt/nc-backups
ls -ldn /mnt/nc-data /mnt/nc-db /mnt/nc-backups
```

Run write tests:

```bash
sudo -u nextcloudsvc touch /mnt/nc-data/.write-test
sudo -u nextcloudsvc rm /mnt/nc-data/.write-test
sudo -u nextcloudsvc touch /mnt/nc-db/.write-test
sudo -u nextcloudsvc rm /mnt/nc-db/.write-test
sudo -u nextcloudsvc touch /mnt/nc-backups/.write-test
sudo -u nextcloudsvc rm /mnt/nc-backups/.write-test
```

Also verify root can change ownership on the mounted paths. This is required by
the MariaDB and Nextcloud container entrypoints:

```bash
sudo touch /mnt/nc-db/.chown-test
sudo chown 999:999 /mnt/nc-db/.chown-test
sudo rm /mnt/nc-db/.chown-test

sudo touch /mnt/nc-data/.chown-test
sudo chown 33:33 /mnt/nc-data/.chown-test
sudo rm /mnt/nc-data/.chown-test
```

Do not continue until the write and `chown` tests pass.

## Phase 6: Install The Nextcloud Stack

Copy the dedicated VM config folder to the Nextcloud VM by SSH/SFTP:

```text
configs/docker/nextcloud-dedicated-vm
```

If pasting over SSH instead of copying files, create the destination first:

```bash
sudo mkdir -p /opt/docker/nextcloud
sudo chown -R "$USER":"$USER" /opt/docker/nextcloud
cd /opt/docker/nextcloud
```

Then create each file and paste the matching local file contents:

```bash
nano docker-compose.yml
nano .env
chmod 600 .env
mkdir -p html
```

The `.env` file should follow the same fields as:

```text
configs/docker/nextcloud-dedicated-vm/.env.example
```

Generate the secret values on the Nextcloud VM:

```bash
openssl rand -hex 32
openssl rand -hex 32
openssl rand -hex 32
openssl rand -hex 32
```

Use one generated value for each secret:

```text
NEXTCLOUD_ADMIN_PASSWORD=first-login admin password for the Nextcloud web UI
NEXTCLOUD_DB_PASSWORD=password for the MariaDB nextcloud database user
NEXTCLOUD_DB_ROOT_PASSWORD=MariaDB root password, not the Debian root password
REDIS_PASSWORD=password Nextcloud uses to talk to Redis
```

Set `DOMAIN` to your real base domain:

```text
DOMAIN=example.com
```

Do not reuse TrueNAS, Proxmox, router, Vaultwarden, Debian user, or personal
account passwords.

If using `scp` from the workstation instead of pasting files, the command is:

```bash
scp -r configs/docker/nextcloud-dedicated-vm dockeradmin@192.168.1.30:/tmp/nextcloud-dedicated-vm
```

Then run this on the Nextcloud VM:

```bash
sudo mkdir -p /opt/docker
sudo mv /tmp/nextcloud-dedicated-vm /opt/docker/nextcloud
sudo chown -R "$USER":"$USER" /opt/docker/nextcloud
cd /opt/docker/nextcloud
cp .env.example .env
nano .env
chmod 600 .env
mkdir -p html
```

Review the pinned images before first deployment:

```bash
docker compose config
```

Start Nextcloud:

```bash
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f nextcloud nextcloud-db nextcloud-redis
```

The first startup can take a few minutes while MariaDB initializes and
Nextcloud copies application files into `/opt/docker/nextcloud/html`.

## Phase 7: Lock Down The Nextcloud VM Firewall

Use UFW on the Nextcloud VM:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 192.168.1.0/24 to any port 22 proto tcp
sudo ufw allow from 192.168.1.20 to any port 8080 proto tcp
sudo ufw enable
sudo ufw status verbose
```

This allows SSH from the LAN and allows Traefik on the Docker VM to reach the
Nextcloud web container. It does not allow arbitrary inbound access to MariaDB,
Redis, Docker, or the NFS mounts.

Docker also creates its own iptables rules for published ports, so add
`DOCKER-USER` rules as well. This assumes the dedicated VM only runs this
Nextcloud stack.

Create the firewall script:

```bash
sudo nano /usr/local/sbin/nextcloud-docker-firewall.sh
```

Paste:

```bash
#!/bin/sh
set -eu

iptables -F DOCKER-USER
iptables -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
iptables -A DOCKER-USER -i lo -j RETURN
iptables -A DOCKER-USER -p tcp -s 192.168.1.20 -d 172.30.20.0/24 --dport 80 -j RETURN
iptables -A DOCKER-USER -p tcp -d 172.30.20.0/24 --dport 80 -j DROP
iptables -A DOCKER-USER -j RETURN
```

Install it:

```bash
sudo chmod 750 /usr/local/sbin/nextcloud-docker-firewall.sh
sudo /usr/local/sbin/nextcloud-docker-firewall.sh
```

Persist it with systemd:

```bash
sudo nano /etc/systemd/system/nextcloud-docker-firewall.service
```

Paste:

```ini
[Unit]
Description=Nextcloud Docker firewall rules
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nextcloud-docker-firewall.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nextcloud-docker-firewall.service
sudo systemctl status nextcloud-docker-firewall.service
```

Why port `80` here instead of `8080`: Docker translates host port `8080` to the
container's port `80` before traffic reaches the `DOCKER-USER` chain. The
compose file pins the frontend Docker subnet to `172.30.20.0/24` so these rules
target only inbound traffic to this stack.

If you later install Tailscale on this VM, allow SSH from your Tailscale admin
range and narrow LAN SSH if desired.

## Phase 8: Route Traefik To The Dedicated VM

Traefik stays on the Docker VM at `192.168.1.20`. Because Nextcloud now runs on
a different Docker engine, Traefik cannot discover it through Docker labels.
Use the Traefik file provider instead.

From the workstation:

```bash
scp configs/docker/nextcloud-dedicated-vm/traefik-nextcloud-vm.yml dockeradmin@192.168.1.20:/tmp/nextcloud-vm.yml
```

On the Docker VM:

```bash
sudo mv /tmp/nextcloud-vm.yml /opt/docker/traefik/dynamic/nextcloud-vm.yml
sudo nano /opt/docker/traefik/dynamic/nextcloud-vm.yml
```

Replace:

```text
cloud.example.com
example.com
```

with the real hostname and domain.

Make sure there is no old Docker-label Nextcloud route still running. If the old
Nextcloud stack exists on the Docker VM, stop it before testing:

```bash
cd /opt/docker/nextcloud
docker compose down
```

Then test from the Docker VM:

```bash
curl -I http://192.168.1.30:8080/status.php
```

Expected result is an HTTP response from Nextcloud, not a connection failure.

Create or update local DNS:

```text
cloud.example.com -> 192.168.1.20
```

The hostname should still point to Traefik on the Docker VM, not directly to the
Nextcloud VM.

Nextcloud's own setup checks also need to resolve the public hostname from
inside the Nextcloud container. The dedicated compose file includes:

```yaml
extra_hosts:
  - "cloud.${DOMAIN}:192.168.1.20"
```

After starting the stack, verify from the Nextcloud VM:

```bash
cd /opt/docker/nextcloud
docker exec nextcloud getent hosts cloud.${DOMAIN}
docker exec nextcloud curl -Ik https://cloud.${DOMAIN}
```

The `curl` output should include:

```text
strict-transport-security: max-age=15552000
```

Do not attach the generic `security-headers@file` middleware to the Nextcloud
router. It sets `X-Frame-Options: DENY`, while Nextcloud expects
`X-Frame-Options: SAMEORIGIN` for parts of its web UI.

## Phase 9: First Login And Nextcloud Settings

Open:

```text
https://cloud.example.com
```

Complete these checks:

1. Log in with the admin account from `.env`.
2. Open **Administration settings -> Overview**.
3. Resolve critical warnings.
4. Confirm background jobs use cron.
5. Enable 2FA for the admin account.
6. Create daily non-admin accounts for real use.
7. Use app passwords for desktop and mobile clients.

Nextcloud accounts and TrueNAS SMB accounts are separate. They can use similar
names, but they should not share passwords.

Do not put Authelia in front of Nextcloud unless desktop and mobile sync clients
have been tested. Nextcloud already has its own login, 2FA, and app passwords.

## Phase 10: Keep Human Storage Separate

Use this split:

```text
/mnt/main/userdata   normal SMB and optional Syncthing storage
/mnt/main/nextcloud  Nextcloud-managed primary data
```

Do not point Nextcloud's primary data directory at `/mnt/main/userdata`.
Do not edit `/mnt/main/nextcloud` directly through SMB.

If Nextcloud must show an existing shared folder, add that specific folder later
as restricted external storage. Do not mount all of `/mnt/main/userdata/users`
into Nextcloud.

## Phase 11: Backups

Copy the dedicated backup helper to the Nextcloud VM:

```bash
scp scripts/backup/nextcloud-vm-backup.sh dockeradmin@192.168.1.30:/tmp/
```

On the Nextcloud VM:

```bash
sudo mv /tmp/nextcloud-vm-backup.sh /usr/local/sbin/nextcloud-vm-backup.sh
sudo chmod 750 /usr/local/sbin/nextcloud-vm-backup.sh
sudo /usr/local/sbin/nextcloud-vm-backup.sh
ls -lah /mnt/nc-backups
```

Add a daily cron job before the TrueNAS snapshot window:

```bash
sudo crontab -e
```

Add:

```text
30 1 * * * /usr/local/sbin/nextcloud-vm-backup.sh
```

In TrueNAS, create snapshot tasks:

| Dataset or path | Schedule | Retention |
|---|---|---|
| `main/nextcloud` | Daily | 30 days |
| `main/appdata/nextcloud-db` | Every 6 hours | 14 days |
| `main/backups` | Daily after the DB dump | 30 days |

Also include `main/nextcloud` and `main/backups` in off-site backup or
replication. A mirror and a snapshot are not enough for irreplaceable data.

## Phase 12: Restore Test

Before public exposure, prove recovery works.

Minimum restore checks:

```bash
ls -lah /mnt/nc-backups
gzip -t /mnt/nc-backups/nextcloud_*.sql.gz
gzip -t /mnt/nc-backups/nextcloud_app_*.tar.gz
```

Then restore one test file from a TrueNAS snapshot:

1. Upload a harmless test file through Nextcloud.
2. Delete it through Nextcloud.
3. Restore it from a TrueNAS snapshot into a temporary location.
4. Upload it again through Nextcloud or run an `occ files:scan` only for the
   affected user if you intentionally restore directly into the data directory.

Do not count the setup as protected until this has been tested once.

## Phase 13: Updates And Watchtower

Do not manage this VM by exposing its Docker socket to Watchtower on the Docker
VM. That would create a cross-VM control path and weaken the isolation this
guide is trying to create.

Recommended approach: update Nextcloud manually on the Nextcloud VM.

Before each update:

```bash
cd /opt/docker/nextcloud
docker compose ps
sudo /usr/local/sbin/nextcloud-vm-backup.sh
```

Enable maintenance mode:

```bash
docker exec --user www-data nextcloud php occ maintenance:mode --on
```

Pull and restart the pinned images:

```bash
docker compose pull
docker compose up -d
docker compose ps
```

Run Nextcloud maintenance tasks:

```bash
docker exec --user www-data nextcloud php occ upgrade
docker exec --user www-data nextcloud php occ maintenance:repair
docker exec --user www-data nextcloud php occ db:add-missing-indices
docker exec --user www-data nextcloud php occ maintenance:mode --off
```

Verify:

```bash
docker compose logs --tail=100 nextcloud nextcloud-db nextcloud-redis
docker exec --user www-data nextcloud php occ status
```

The compose file pins the Nextcloud major version, for example
`nextcloud:33-apache`. A normal `docker compose pull` updates within that image
tag. For a future major upgrade, change the image tag deliberately and upgrade
one supported major at a time. Do not jump multiple Nextcloud majors in one
maintenance window.

Optional: if you want update notifications, run a separate Watchtower instance
on the Nextcloud VM in monitor-only mode. It should monitor only this VM's local
Docker daemon and should not auto-update Nextcloud.

## Phase 14: Public Exposure Gate

Only expose Nextcloud outside the LAN after all checks pass:

- Nextcloud works through `https://cloud.example.com`.
- The hostname points to Traefik at `192.168.1.20`.
- Traefik forwards only to `192.168.1.30:8080`.
- The Nextcloud VM firewall allows port `8080` only from `192.168.1.20`.
- The Docker VM cannot write to `main/nextcloud` or `main/appdata/nextcloud-db`.
- Nextcloud admin 2FA is enabled.
- Placeholder passwords are gone.
- A logical MariaDB backup exists under `/mnt/nc-backups`.
- TrueNAS snapshots exist.
- One restore test has succeeded.
- Off-site backup or replication includes irreplaceable data.

Do not expose Proxmox, TrueNAS, SSH, Grafana, Portainer, databases, or Docker
APIs together with Nextcloud.

## Quick Validation Commands

Run on the Nextcloud VM:

```bash
findmnt /mnt/nc-data
findmnt /mnt/nc-db
findmnt /mnt/nc-backups
docker compose -f /opt/docker/nextcloud/docker-compose.yml ps
curl -I http://127.0.0.1:8080/status.php
sudo /usr/local/sbin/nextcloud-vm-backup.sh
```

Run on the Docker VM:

```bash
curl -I http://192.168.1.30:8080/status.php
docker exec traefik traefik healthcheck --ping
```

Run from a LAN client:

```text
https://cloud.example.com
```

The final result should be:

```text
TrueNAS        owns storage and snapshots
Nextcloud VM   owns only the Nextcloud application stack
Docker VM      owns Traefik and other services
Docker VM      cannot write to Nextcloud datasets as mediauser
```
