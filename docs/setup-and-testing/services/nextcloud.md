# Nextcloud Setup And Testing

Covers both Nextcloud deployment options — local-first on the general Docker VM, and the isolated dedicated-VM variant — plus SMTP/user-onboarding configuration that applies to either. See [docs/services/nextcloud.md](../../services/nextcloud.md) for the resulting architecture and to decide which deployment option fits.

Do not install Nextcloud as a TrueNAS app. Do not expose it publicly during first deployment — get LAN/Tailscale access, backups, and a restore test working first.

## Option A: Local-First Setup (Docker VM)

Use this when isolating Nextcloud from the general Docker VM is not the priority. Prerequisites: the `main` pool exists on TrueNAS, the Docker VM mounts `192.168.1.10:/mnt/main` at `/mnt/main`, Docker/Compose work on the Docker VM, and the Docker VM can write to `/mnt/main` as `mediauser`.

### Step 1: Create the TrueNAS datasets

In the TrueNAS web UI (`192.168.1.10`):

**`main/nextcloud`**: Datasets → select `main` → Add Dataset → Name `nextcloud` → Generic preset, compression on, dedup off → Save. Result must be `Dataset: main/nextcloud`, `Path: /mnt/main/nextcloud`.

**`main/appdata/nextcloud-db`**: Datasets → expand `main` → select the existing `main/appdata` dataset (important) → Add Dataset → Name `nextcloud-db` → same preset → Save. Result must be `Dataset: main/appdata/nextcloud-db`, `Path: /mnt/main/appdata/nextcloud-db`.

If you select `main` instead of `main/appdata`, TrueNAS creates the wrong path `/mnt/main/nextcloud-db` — delete that empty dataset in the UI and recreate it under `main/appdata`. Never delete a dataset that already contains data. Do not create either path with `mkdir`; TrueNAS must create the mount points when it creates the datasets.

### Step 2: Set dataset permissions

For both datasets: Datasets → select → Permissions → Edit → Owner `mediauser`, Owner Group `mediauser`, mode `770` (owner+group rwx, other none). Apply recursively only if the dataset already has files needing ownership correction. Do not make either dataset an SMB share.

### Step 3: Confirm NFS access from the Docker VM

The existing `/mnt/main` NFS export must already be restricted to `192.168.1.20`.

```bash
findmnt /mnt/main
findmnt -T /mnt/main/nextcloud
findmnt -T /mnt/main/appdata/nextcloud-db
ls -ldn /mnt/main/nextcloud /mnt/main/appdata/nextcloud-db

sudo -u mediauser touch /mnt/main/nextcloud/.write-test
sudo -u mediauser rm /mnt/main/nextcloud/.write-test
sudo -u mediauser touch /mnt/main/appdata/nextcloud-db/.write-test
sudo -u mediauser rm /mnt/main/appdata/nextcloud-db/.write-test
```

Do not continue if either write test fails — fix TrueNAS permissions, the NFS export, or the `mediauser` UID/GID first.

### Step 4: Review the compose version

Confirm `configs/docker/nextcloud/docker-compose.yml` pins a currently supported Nextcloud major before every new install or upgrade. Upgrade one major at a time with a backup before each.

### Step 5: Copy and configure the stack

```bash
scp -r configs/docker/nextcloud <docker-vm-user>@192.168.1.20:/opt/docker/
ssh <docker-vm-user>@192.168.1.20

cd /opt/docker/nextcloud
cp .env.example .env
nano .env
```

Set strong unique values for `NEXTCLOUD_ADMIN_PASSWORD`, `NEXTCLOUD_DB_PASSWORD`, `NEXTCLOUD_DB_ROOT_PASSWORD`, `REDIS_PASSWORD`, plus the domain values the compose file requires. Do not reuse TrueNAS, Proxmox, router, or Vaultwarden credentials.

### Step 6: Confirm Traefik and local DNS

```bash
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy
```

Create a local DNS record `cloud.example.com -> 192.168.1.20` (Pi-hole, or a temporary hosts-file entry for the first test). Do not add router port forwards.

### Step 7: Start Nextcloud

```bash
cd /opt/docker/nextcloud
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f nextcloud nextcloud-db nextcloud-redis
```

Then open `https://cloud.example.com`. First startup can take a few minutes while MariaDB initializes and app files copy in.

### Step 8: Complete first login

1. **Administration settings → Overview** — resolve critical warnings.
2. Confirm background jobs use cron.
3. Enable 2FA for the admin account.
4. Create a non-admin daily account per person.
5. Use app passwords for desktop/mobile clients.

### Step 9: Keep human storage separate

```text
/mnt/main/userdata   normal SMB and optional Syncthing storage
/mnt/main/nextcloud  Nextcloud-managed primary data
```

Do not point Nextcloud's data directory at `/mnt/main/userdata`; do not edit `/mnt/main/nextcloud` over SMB. Add any existing shared folder later as restricted external storage rather than mounting all of `/mnt/main/userdata/users`.

### Step 10: Configure snapshots and backups

In TrueNAS → Data Protection → Periodic Snapshot Tasks:

| Dataset | Recursive | Schedule | Retention |
|---|---:|---|---|
| `main/nextcloud` | Yes | Daily | 30 days |
| `main/appdata/nextcloud-db` | Yes | Every 6 hours | 14 days |
| `main/backups` | Yes | Daily, after the DB dump | 30 days |

Also protect the Docker named volume `nextcloud_app` — it is not covered by TrueNAS snapshots. Use `scripts/backup/db-backup.sh` on the Docker VM for a logical MariaDB dump to `/mnt/main/backups/db`; a filesystem snapshot alone does not replace a logical dump.

### Step 11: Verify before public exposure

- [ ] `docker compose ps` shows Nextcloud/MariaDB/Redis/cron healthy.
- [ ] A test file uploads/downloads over LAN.
- [ ] Tailscale access works if required.
- [ ] A logical MariaDB dump exists under `/mnt/main/backups/db`.
- [ ] `nextcloud_app` has a documented backup.
- [ ] One test file has been restored successfully.
- [ ] Nextcloud runs a currently supported major.
- [ ] Admin 2FA is enabled, placeholders are gone.
- [ ] HTTPS works through Traefik.

## Option B: Dedicated-VM Setup (Isolated)

Use this instead of Option A when isolating Nextcloud from a Docker VM compromise matters more than one-VM simplicity. If Nextcloud already runs on the Docker VM, do not run both instances against the same data — plan a migration window (dump DB, stop old stack, snapshot data/DB/backups, re-home ownership to `nextcloudsvc`, start the dedicated VM stack, run `occ maintenance:repair`).

### Step 1: Create the Nextcloud VM

| Setting | Value |
|---|---|
| VM ID | `112` |
| Name | `nextcloud` |
| vCPU | `2`-`4` |
| RAM | `4` GB min, `6` GB better |
| Boot disk | `32` GB on `ssd-fast` |
| Network | LAN bridge, static IP `192.168.1.30` |
| Start order | After TrueNAS, before/alongside the Docker VM |

Do not pass through disks, mount the whole `main` pool, or install Samba on this VM. Set the static IP (`192.168.1.30/24`, gateway `192.168.1.1`, DNS `192.168.1.1` or Pi-hole) and reserve `192.168.1.30` in the router/DHCP.

### Step 2: Harden the VM base

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y ca-certificates curl gnupg nfs-common ufw fail2ban
sudo timedatectl set-timezone Europe/Berlin

sudo groupadd -g 3100 nextcloudsvc
sudo useradd -u 3100 -g 3100 -M -s /usr/sbin/nologin nextcloudsvc
id nextcloudsvc

curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker "$USER"
newgrp docker   # or log out/in

docker --version
docker compose version
docker run --rm hello-world
```

Only trusted admins should be in the `docker` group (it is root-equivalent on this VM).

### Step 3: Create TrueNAS account, datasets, and permissions

In TrueNAS, create group `nextcloudsvc` (GID `3100`) and user `nextcloudsvc` (UID `3100`, primary group `nextcloudsvc`). Create/confirm datasets `main/nextcloud` and `main/appdata/nextcloud-db`, plus directory `/mnt/main/backups/nextcloud-db`. For all three, set owner/group to `nextcloudsvc` and mode `770` (remove any broad ACL entries for `mediauser`/guest/everyone). Do not make `main/nextcloud` an SMB share.

### Step 4: Create narrow NFS exports

Create three NFS shares, each restricted to the Nextcloud VM only, with `Maproot User: root` / `Maproot Group: root` (not `wheel` unless that's what your TrueNAS offers) and no `Mapall` (Mapall blocks the `chown` MariaDB/Nextcloud need on first startup):

| TrueNAS path | Authorized host |
|---|---|
| `/mnt/main/nextcloud` | `192.168.1.30/32` |
| `/mnt/main/appdata/nextcloud-db` | `192.168.1.30/32` |
| `/mnt/main/backups/nextcloud-db` | `192.168.1.30/32` |

Do not add the Docker VM's IP to these exports — the point is that a compromised Docker VM has no NFS write access to Nextcloud storage.

### Step 5: Mount only the needed paths

```bash
sudo mkdir -p /mnt/nc-data /mnt/nc-db /mnt/nc-backups
sudo chown root:root /mnt/nc-data /mnt/nc-db /mnt/nc-backups
```

`/etc/fstab`:

```text
192.168.1.10:/mnt/main/nextcloud /mnt/nc-data nfs4 defaults,_netdev,noatime,hard,timeo=600,retrans=2 0 0
192.168.1.10:/mnt/main/appdata/nextcloud-db /mnt/nc-db nfs4 defaults,_netdev,noatime,hard,timeo=600,retrans=2 0 0
192.168.1.10:/mnt/main/backups/nextcloud-db /mnt/nc-backups nfs4 defaults,_netdev,noatime,hard,timeo=600,retrans=2 0 0
```

```bash
sudo mount -a
findmnt /mnt/nc-data; findmnt /mnt/nc-db; findmnt /mnt/nc-backups
ls -ldn /mnt/nc-data /mnt/nc-db /mnt/nc-backups

sudo -u nextcloudsvc touch /mnt/nc-data/.write-test && sudo -u nextcloudsvc rm /mnt/nc-data/.write-test
sudo -u nextcloudsvc touch /mnt/nc-db/.write-test && sudo -u nextcloudsvc rm /mnt/nc-db/.write-test
sudo -u nextcloudsvc touch /mnt/nc-backups/.write-test && sudo -u nextcloudsvc rm /mnt/nc-backups/.write-test
```

Also confirm root can `chown` on the mounted paths (required by the MariaDB/Nextcloud container entrypoints):

```bash
sudo touch /mnt/nc-db/.chown-test && sudo chown 999:999 /mnt/nc-db/.chown-test && sudo rm /mnt/nc-db/.chown-test
sudo touch /mnt/nc-data/.chown-test && sudo chown 33:33 /mnt/nc-data/.chown-test && sudo rm /mnt/nc-data/.chown-test
```

Do not continue until all write/chown tests pass.

### Step 6: Install the Nextcloud stack

Copy `configs/docker/nextcloud-dedicated-vm` to the VM (SCP or paste over SSH):

```bash
scp -r configs/docker/nextcloud-dedicated-vm <admin>@192.168.1.30:/tmp/nextcloud-dedicated-vm
```

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

Generate secrets:

```bash
openssl rand -hex 32   # NEXTCLOUD_ADMIN_PASSWORD
openssl rand -hex 32   # NEXTCLOUD_DB_PASSWORD
openssl rand -hex 32   # NEXTCLOUD_DB_ROOT_PASSWORD
openssl rand -hex 32   # REDIS_PASSWORD
```

Set `DOMAIN=example.com`. Do not reuse TrueNAS/Proxmox/router/Vaultwarden/personal passwords.

```bash
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f nextcloud nextcloud-db nextcloud-redis
```

### Step 7: Lock down the Nextcloud VM firewall

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 192.168.1.0/24 to any port 22 proto tcp
sudo ufw allow from 192.168.1.20 to any port 8080 proto tcp
sudo ufw enable
sudo ufw status verbose
```

Add `DOCKER-USER` iptables rules too, since Docker creates its own rules for published ports. `/usr/local/sbin/nextcloud-docker-firewall.sh`:

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

```bash
sudo chmod 750 /usr/local/sbin/nextcloud-docker-firewall.sh
sudo /usr/local/sbin/nextcloud-docker-firewall.sh
```

Persist with systemd (`/etc/systemd/system/nextcloud-docker-firewall.service`):

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

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nextcloud-docker-firewall.service
sudo systemctl status nextcloud-docker-firewall.service
```

Port `80` (not `8080`) is used in the rules because Docker translates host port `8080` to the container's port `80` before traffic reaches `DOCKER-USER`; the compose file pins the frontend Docker subnet to `172.30.20.0/24` so these rules target only this stack.

### Step 8: Route Traefik to the dedicated VM

```bash
scp configs/docker/nextcloud-dedicated-vm/traefik-nextcloud-vm.yml <admin>@192.168.1.20:/tmp/nextcloud-vm.yml
```

On the Docker VM:

```bash
sudo mv /tmp/nextcloud-vm.yml /opt/docker/traefik/dynamic/nextcloud-vm.yml
sudo nano /opt/docker/traefik/dynamic/nextcloud-vm.yml
```

Replace the placeholder `cloud.example.com` / `example.com` with the real hostname/domain. Stop any old Docker-label Nextcloud route first:

```bash
cd /opt/docker/nextcloud   # the OLD stack location, if it still exists on the Docker VM
docker compose down
```

Test:

```bash
curl -I http://192.168.1.30:8080/status.php
```

Create/update local DNS: `cloud.example.com -> 192.168.1.20` (still Traefik, not the Nextcloud VM directly). The dedicated compose file includes `extra_hosts: - "cloud.${DOMAIN}:192.168.1.20"` so Nextcloud's own setup checks can resolve the public hostname from inside its container. Verify:

```bash
cd /opt/docker/nextcloud
docker exec nextcloud getent hosts cloud.${DOMAIN}
docker exec nextcloud curl -Ik https://cloud.${DOMAIN}
```

Expect `strict-transport-security: max-age=15552000` in the output. Do not attach `security-headers@file` to the Nextcloud router — it sets `X-Frame-Options: DENY`, but Nextcloud needs `SAMEORIGIN`.

### Step 9: First login and settings

Open `https://cloud.example.com`: log in with the admin account from `.env`, resolve critical warnings under Administration → Overview, confirm cron background jobs, enable admin 2FA, create non-admin daily accounts, use app passwords for clients.

### Step 10: Keep human storage separate

Same split as Option A — `/mnt/main/userdata` for normal storage, `/mnt/main/nextcloud` for Nextcloud-managed data; add existing shared folders as restricted external storage rather than mounting all of `/mnt/main/userdata/users`.

### Step 11: Backups

```bash
scp scripts/backup/nextcloud-vm-backup.sh <admin>@192.168.1.30:/tmp/
```

```bash
sudo mv /tmp/nextcloud-vm-backup.sh /usr/local/sbin/nextcloud-vm-backup.sh
sudo chmod 750 /usr/local/sbin/nextcloud-vm-backup.sh
sudo /usr/local/sbin/nextcloud-vm-backup.sh
ls -lah /mnt/nc-backups
```

Cron (before the TrueNAS snapshot window):

```bash
sudo crontab -e
```

```text
30 1 * * * /usr/local/sbin/nextcloud-vm-backup.sh
```

TrueNAS snapshot tasks:

| Dataset/path | Schedule | Retention |
|---|---|---|
| `main/nextcloud` | Daily | 30 days |
| `main/appdata/nextcloud-db` | Every 6 hours | 14 days |
| `main/backups` | Daily after the DB dump | 30 days |

Include `main/nextcloud` and `main/backups` in off-site backup/replication — a mirror + snapshot alone is not enough for irreplaceable data.

### Step 12: Restore test

```bash
ls -lah /mnt/nc-backups
gzip -t /mnt/nc-backups/nextcloud_*.sql.gz
gzip -t /mnt/nc-backups/nextcloud_app_*.tar.gz
```

Then: upload a harmless test file through Nextcloud, delete it, restore it from a TrueNAS snapshot into a temporary location, and re-upload (or run a targeted `occ files:scan` if restoring directly into the data directory). Do not consider the setup protected until this has succeeded once.

### Step 13: Updates

Do not expose this VM's Docker socket to Watchtower on the general Docker VM — that creates a cross-VM control path and weakens the isolation. Update manually:

```bash
cd /opt/docker/nextcloud
docker compose ps
sudo /usr/local/sbin/nextcloud-vm-backup.sh

docker exec --user www-data nextcloud php occ maintenance:mode --on
docker compose pull
docker compose up -d
docker compose ps

docker exec --user www-data nextcloud php occ upgrade
docker exec --user www-data nextcloud php occ maintenance:repair
docker exec --user www-data nextcloud php occ db:add-missing-indices
docker exec --user www-data nextcloud php occ maintenance:mode --off

docker compose logs --tail=100 nextcloud nextcloud-db nextcloud-redis
docker exec --user www-data nextcloud php occ status
```

A normal `docker compose pull` updates within the pinned major (e.g. `nextcloud:33-apache`). For a major upgrade, change the image tag deliberately and upgrade one major at a time — never skip majors in one maintenance window. Optional: a separate Watchtower instance on the Nextcloud VM itself, in monitor-only mode, watching only its own local Docker daemon.

### Step 14: Public exposure gate

- [ ] Works through `https://cloud.example.com`.
- [ ] Hostname points to Traefik at `192.168.1.20`; Traefik forwards only to `192.168.1.30:8080`.
- [ ] Nextcloud VM firewall allows `8080` only from `192.168.1.20`.
- [ ] Docker VM cannot write to `main/nextcloud` or `main/appdata/nextcloud-db`.
- [ ] Admin 2FA enabled, placeholders gone.
- [ ] Logical MariaDB backup exists under `/mnt/nc-backups`; TrueNAS snapshots exist; one restore test succeeded; off-site backup includes irreplaceable data.

Do not expose Proxmox, TrueNAS, SSH, Grafana, Portainer, databases, or Docker APIs alongside Nextcloud.

### Quick validation commands

```bash
# On the Nextcloud VM:
findmnt /mnt/nc-data; findmnt /mnt/nc-db; findmnt /mnt/nc-backups
docker compose -f /opt/docker/nextcloud/docker-compose.yml ps
curl -I http://127.0.0.1:8080/status.php
sudo /usr/local/sbin/nextcloud-vm-backup.sh

# On the Docker VM:
curl -I http://192.168.1.30:8080/status.php
docker exec traefik traefik healthcheck --ping
```

## Part 2: SMTP And User Onboarding (Either Deployment)

Configures outbound email (password resets, activation, notifications) via Brevo. Use after Nextcloud works at `https://cloud.example.com`, you control DNS for `example.com` (normally Cloudflare), and you have a free Brevo account.

### Step 1: Create the Brevo account

Create a free account at `https://www.brevo.com/pricing/` using an account email you control (300 emails/day, SMTP relay included, no credit card). A personal mailbox is fine as the Brevo *login* — it only controls the Brevo account; it is never the visible Nextcloud sender address. After login, open **Transactional → Settings** and complete any requested account validation.

### Step 2: Choose and verify the sender

Use `nextcloud@example.com` (alternatives: `no-reply@example.com`, `cloud@example.com`) — same domain as the public Nextcloud hostname. In Brevo: **Senders, Domains & Dedicated IPs → Senders → Add a sender**, From name `Nextcloud`, From email `nextcloud@example.com`. Prefer domain authentication over single-sender verification (enables DKIM signing, better deliverability).

### Step 3: Add Brevo DNS records in Cloudflare

In Brevo: **Senders, Domains & Dedicated IPs → Domains → Add a domain**, enter `example.com`. Add the exact records Brevo shows in **Cloudflare → example.com → DNS → Records**:

| Record | Purpose |
|---|---|
| DKIM TXT | Lets receivers verify Brevo-signed mail |
| SPF TXT | Authorizes Brevo to send for your domain — merge with any existing SPF record at `@`, do not create a second one |
| DMARC TXT | `_dmarc` → `"v=DMARC1; p=none; adkim=s; aspf=s"` as a starter if you don't already have one |

Keep these DNS-only (not proxied through Cloudflare). Return to Brevo and click domain verification after DNS propagates.

### Step 4: Get Brevo SMTP credentials

**Brevo Dashboard → SMTP & API → SMTP**, generate/copy an SMTP key (use the SMTP key, not a normal API key or account password):

```text
SMTP host:     smtp-relay.brevo.com
SMTP port:     587 (Encryption: None/STARTTLS) — try this first
Alternative:   465 (Encryption: SSL)
```

### Step 5: Confirm connectivity from the Nextcloud host

```bash
SMTP_HOST="smtp-relay.brevo.com"
SMTP_PORT="587"
getent hosts "$SMTP_HOST"
openssl s_client -starttls smtp -connect "${SMTP_HOST}:${SMTP_PORT}" -servername "$SMTP_HOST" </dev/null
```

Expect DNS resolution, a successful TCP connection, and a certificate chain/SMTP capability banner. For port `465`:

```bash
openssl s_client -connect "smtp-relay.brevo.com:465" -servername "smtp-relay.brevo.com" </dev/null
```

### Step 6: Configure SMTP in Nextcloud

Prefer the web UI (avoids the password in shell history): **Admin avatar → Settings → Administration → Basic settings → Email server**:

| Field | Value |
|---|---|
| Send mode | `SMTP` |
| Encryption | `None/STARTTLS` for port `587` |
| From address | `nextcloud` |
| Mail domain | `example.com` |
| Authentication required | enabled |
| Server address | `smtp-relay.brevo.com` |
| Port | `587` |
| Authentication method | `LOGIN` |
| Username | Brevo SMTP login (from the SMTP & API page) |
| Password | Brevo SMTP key (never the Brevo account password) |

If the UI separates From address and domain, use `From address: nextcloud` / `Domain: example.com` rather than the full address in one field. If `587` fails, switch to `Encryption: SSL` / `Port: 465`.

### Step 7: Send a test email

Set an email address on the admin account (**Personal settings → Personal info → Email**), return to **Administration → Basic settings → Email server**, click **Send email**. Expect the UI to confirm sending, the message to arrive (not in spam) from `nextcloud@example.com`, and Brevo's transactional logs to show it. Fix SMTP here before relying on activation/registration mail.

### Step 8: Optional CLI configuration

Prefer the UI; use CLI only for recovery/repeatable rebuilds:

```bash
cd /opt/docker/nextcloud

docker exec --user www-data nextcloud php occ config:system:set mail_smtpmode --value="smtp"
docker exec --user www-data nextcloud php occ config:system:set mail_smtphost --value="smtp-relay.brevo.com"
docker exec --user www-data nextcloud php occ config:system:set mail_smtpport --type=integer --value=587
docker exec --user www-data nextcloud php occ config:system:set mail_smtpsecure --value=""
docker exec --user www-data nextcloud php occ config:system:set mail_smtpauth --type=boolean --value=true
docker exec --user www-data nextcloud php occ config:system:set mail_smtpauthtype --value="LOGIN"
docker exec --user www-data nextcloud php occ config:system:set mail_smtpname --value="your_brevo_smtp_login"
docker exec --user www-data nextcloud php occ config:system:set mail_from_address --value="nextcloud"
docker exec --user www-data nextcloud php occ config:system:set mail_domain --value="example.com"
```

Set the password last (exposes it in shell history otherwise — prefer the UI when possible):

```bash
read -rsp "SMTP password/token: " SMTP_PASS
echo
docker exec --user www-data nextcloud php occ config:system:set mail_smtppassword --value="$SMTP_PASS"
unset SMTP_PASS
```

For port `465`/SSL:

```bash
docker exec --user www-data nextcloud php occ config:system:set mail_smtpport --type=integer --value=465
docker exec --user www-data nextcloud php occ config:system:set mail_smtpsecure --value="ssl"
```

### Step 9: Invite users without setting their password

**Admin avatar → Users** → enable `Show email address` and `Send email to new users` in the lower-left settings area. Create the user:

| Field | Value |
|---|---|
| Login name | stable username |
| Email | user's real email address |
| Password | leave empty |
| Groups | normal non-admin group |
| Quota | set a sane quota |

Nextcloud emails an activation link; the user sets their own password and can then create app passwords for desktop/mobile clients. This is the recommended flow since it keeps account control with the admin without the admin ever knowing user passwords.

### Step 10: Optional self-signup with the Registration app

Only after invite-only onboarding works:

```bash
cd /opt/docker/nextcloud
docker exec --user www-data nextcloud php occ app:install registration
docker exec --user www-data nextcloud php occ app:enable registration
```

Configure in **Admin avatar → Administration settings → Registration**: require email verification, require admin approval, restrict allowed email domains if possible, set a default group/quota before opening registration, optionally require ToS acceptance. Never enable unrestricted public signup on an internet-exposed instance.

### Step 11: Password policy and 2FA

**Admin avatar → Administration settings → Security**: minimum password length ≥ 12, forbid common passwords, consider breached-password checks, require 2FA for admin, encourage 2FA for normal users, use app passwords for clients. Never reuse TrueNAS/Proxmox/router/Vaultwarden passwords for Nextcloud accounts.

### Step 12: Backup impact

SMTP settings live in Nextcloud's own config, not this repository (dedicated-VM path: `/opt/docker/nextcloud/html/config/config.php`). Once SMTP is set, the app/config backup archive contains that secret — keep `/mnt/nc-backups` (or the local-first equivalent) and any off-server copy protected accordingly. If the credential is exposed: rotate the Brevo SMTP key, update Nextcloud, send a test email, and check Brevo's transactional logs for unexpected sends.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Test email does not send | Wrong Brevo SMTP login; normal account password used instead of SMTP key; Brevo transactional sending not yet activated; sender/domain not verified; DNS can't resolve the SMTP host; outbound firewall tightened after setup. Check `docker logs --tail=100 nextcloud` and `occ log:watch`. |
| Brevo `525 5.7.1 Unauthorized IP address` | Brevo refused the account's public outbound WAN IP. Find it with `curl -4 https://ifconfig.me` from the Nextcloud host, then authorize it (or remove the SMTP key's IP restriction) under **SMTP & API → SMTP → Authorized IPs**. If your WAN IP changes often, consider an unrestricted key if your security policy allows it. |
| Brevo `502 5.7.0 Your SMTP account is not yet activated` | Credentials/server reachable, but Brevo hasn't activated transactional SMTP for the account. Mentions of `sendinblue.com` are expected legacy wording, not a sign of misconfiguration. Complete profile/sender/domain validation in the dashboard, or contact Brevo support from inside the dashboard. |
| Brevo rejects the sender | Confirm `nextcloud@example.com` is a verified Brevo sender or domain, SPF includes Brevo, DKIM passes, and the sender is allowed on the account. |
| Emails arrive in spam | Check SPF (single record), DKIM (matches Brevo's selector), DMARC exists, From domain matches the verified domain; new domains need time/low volume to build reputation. |
| Registration says email could not be sent | Fix the basic test email first — Registration uses the same mail path. |
| Password reset links use the wrong URL | Check `occ config:system:get overwrite.cli.url` and `overwriteprotocol` — expect `https://cloud.example.com` and `https`. The dedicated compose file sets `OVERWRITEPROTOCOL=https` / `OVERWRITECLIURL=https://cloud.${DOMAIN}`. |

## Validation checklist (SMTP/onboarding)

| Check | Expected |
|---|---|
| Brevo account | Free account created, transactional sending active |
| SMTP sender | `nextcloud@example.com` exists in Brevo |
| DNS SPF/DKIM/DMARC | Brevo authorized; single SPF record; DKIM verifies; at least monitor-only DMARC |
| Nextcloud SMTP | `smtp-relay.brevo.com`, port `587`, auth enabled |
| Test email | Arrives at admin address |
| Brevo logs | Test email appears in transactional logs |
| Invite flow | User sets their own password from the activation email |
| Password reset | Link uses `https://cloud.example.com` |
| Registration app | Disabled unless email verification + admin approval are configured |
| Secrets | SMTP credential not committed to git |
