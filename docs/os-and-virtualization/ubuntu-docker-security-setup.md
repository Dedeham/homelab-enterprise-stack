# Ubuntu Docker VM Local-First Setup

Last updated: 2026-06-10

This guide configures the Ubuntu Server VM that runs Docker services. In this homelab, TrueNAS is storage only and Docker containers run on the Ubuntu Docker VM.

Use this guide after:

1. [Proxmox manual initial setup](proxmox-manual-initial-setup.md)
2. Creating the Ubuntu Server VM in the Proxmox web UI
3. [TrueNAS storage pool setup](truenas-storage-pool-setup.md), at least through dataset creation

Current design:

| Component | Role |
|---|---|
| TrueNAS VM | Storage only: ZFS, NFS, SMB, snapshots |
| Ubuntu Docker VM | Docker, Dockge optional, ARR stack, other services later |
| Tailscale | Remote management access through Proxmox currently; direct Docker VM Tailscale is optional later |
| Cloudflare/Traefik/public access | Later phase only |

## Step 1: Confirm Network Identity

The examples assume:

```text
Docker VM: 192.168.1.20
TrueNAS:   192.168.1.10
Proxmox:   192.168.1.2
LAN:       192.168.1.0/24
Tailscale: 100.64.0.0/10, only for hosts that actually run Tailscale or intentional subnet routing
```

If your actual IPs differ, replace them consistently.

Check on the Docker VM:

```bash
ip addr
ip route
ping -c 3 192.168.1.10
```

## Step 2: Install Docker And Compose

Docker is the container runtime. Docker Compose reads `compose.yaml` files and starts multi-container stacks.

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER
```

Log out and log back in so group membership applies.

Verify:

```bash
docker --version
docker compose version
docker run --rm hello-world
```

## Step 3: Install Base Tools

```bash
sudo apt update
sudo apt install -y nfs-common ufw curl ca-certificates htop tmux
```

Why:

- `nfs-common`: mounts TrueNAS NFS exports.
- `ufw`: simple host firewall.
- `curl` and `ca-certificates`: needed by health checks and setup scripts.
- `htop` and `tmux`: practical administration tools.

## Step 4: Create Matching Media User

Create the same numeric user/group on TrueNAS and Ubuntu. Replace `3000` with the UID/GID you created in TrueNAS.

```bash
sudo groupadd -g 3000 mediauser
sudo useradd -u 3000 -g 3000 -M -s /usr/sbin/nologin mediauser
id mediauser
```

Why this matters:

- Containers write files using numeric IDs.
- TrueNAS permissions also resolve numeric IDs.
- Matching IDs prevent root-owned files and failed Radarr/Sonarr imports.

## Step 5: Mount TrueNAS Storage

Create mount points:

```bash
sudo mkdir -p /mnt/main /mnt/media/data
```

Add to `/etc/fstab`:

```fstab
192.168.1.10:/mnt/main  /mnt/main  nfs4  rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576  0  0
192.168.1.10:/mnt/main/media/data /mnt/media/data nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
```

This is the current one-pool layout. The Docker VM still uses `/mnt/media/data`, but that mount comes from the TrueNAS path `/mnt/main/media/data`.

Apply:

```bash
sudo systemctl daemon-reload
sudo mount -a
findmnt /mnt/main
findmnt /mnt/media/data
df -h /mnt/main /mnt/media/data
```

Write test:

```bash
sudo -u mediauser test -w /mnt/main/appdata
sudo -u mediauser touch /mnt/media/data/.docker-vm-write-test
sudo -u mediauser rm /mnt/media/data/.docker-vm-write-test
```

If either `findmnt` command is empty, that path is not mounted from TrueNAS. Fix `/etc/fstab` or the TrueNAS NFS export before continuing.

If the write test fails, fix TrueNAS NFS export mapping and dataset permissions before continuing. The `/mnt/main/appdata` path should come from the TrueNAS `main/appdata` dataset, not from a local Docker VM directory.

Verify the ARR media folders from the Docker VM:

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

In the one-pool TrueNAS layout, those Docker VM paths map to:

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

If checking directly from the TrueNAS shell, verify the real one-pool paths:

```bash
for path in \
  /mnt/main/media/data/torrents/incomplete \
  /mnt/main/media/data/torrents/movies \
  /mnt/main/media/data/torrents/tv \
  /mnt/main/media/data/usenet/incomplete \
  /mnt/main/media/data/usenet/movies \
  /mnt/main/media/data/usenet/tv \
  /mnt/main/media/data/media/movies \
  /mnt/main/media/data/media/tv \
  /mnt/main/media/data/media/music
do
  test -d "$path" && echo "OK  $path" || echo "MISS $path"
done
```

### If The Media Folder Check Shows `MISS`

If the folder check shows `MISS`, do not guess. First confirm what the Docker VM has mounted:

```bash
findmnt -T /mnt/media/data -o TARGET,SOURCE,FSTYPE,OPTIONS
ls -lah /mnt/media/data
```

Expected one-pool result:

```text
TARGET          SOURCE
/mnt/media/data 192.168.1.10:/mnt/main/media/data
```

If the mount is correct, inspect the actual directory tree:

```bash
sudo -u mediauser sh -c 'cd / && find /mnt/media/data -maxdepth 3 -type d' | sort
sudo -u mediauser sh -c 'cd / && ls -lah /mnt/media/data/torrents /mnt/media/data/usenet /mnt/media/data/media'
```

Correct ARR layout:

```text
/mnt/media/data
/mnt/media/data/torrents
/mnt/media/data/torrents/incomplete
/mnt/media/data/torrents/movies
/mnt/media/data/torrents/tv
/mnt/media/data/usenet
/mnt/media/data/usenet/incomplete
/mnt/media/data/usenet/movies
/mnt/media/data/usenet/tv
/mnt/media/data/media
/mnt/media/data/media/movies
/mnt/media/data/media/tv
/mnt/media/data/media/music
```

Common wrong layouts:

```text
/mnt/media/data/movies
/mnt/media/data/tv
/mnt/media/data/music
/mnt/media/data/downloads
/mnt/media/data/data
/mnt/media/data/media/media/movies
/mnt/media/data/torrents/torrents/movies
```

Do not delete or move existing files automatically. If you already have media or downloads in a wrong location, create the correct folders first, then move files intentionally after confirming what each folder contains.

If `SOURCE` is not `192.168.1.10:/mnt/main/media/data`, fix `/etc/fstab` so the media line is:

```fstab
192.168.1.10:/mnt/main/media/data /mnt/media/data nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
```

Then remount:

```bash
sudo systemctl daemon-reload
sudo umount /mnt/media/data
sudo mount -a
findmnt -T /mnt/media/data -o TARGET,SOURCE,FSTYPE,OPTIONS
```

If the mount source is correct but the nested folders are missing, create only the expected ARR folders from the Docker VM over the NFS mount:

```bash
sudo -u mediauser mkdir -p \
  /mnt/media/data/torrents/incomplete \
  /mnt/media/data/torrents/movies \
  /mnt/media/data/torrents/tv \
  /mnt/media/data/usenet/incomplete \
  /mnt/media/data/usenet/movies \
  /mnt/media/data/usenet/tv \
  /mnt/media/data/media/movies \
  /mnt/media/data/media/tv \
  /mnt/media/data/media/music

sudo -u mediauser find /mnt/media/data -type d -exec chmod 775 {} \;
```

Run the folder verification loop again. If it now shows `OK`, continue.

If `chmod` returns `Operation not permitted` but the `mkdir` command and write test work as `mediauser`, continue. TrueNAS ACLs can block chmod over NFS even when normal file access is correct. Fix mode/ACLs from the TrueNAS UI only if containers cannot read or write.

If `find` or `ls` returns `Permission denied` when run as your login user, but works with `sudo -u mediauser`, that is expected for `770` media folders. Docker containers will use `mediauser` or UID/GID `3000`, not the login user.

If `find` prints `Failed to restore initial working directory: /home/<user>: Permission denied`, the folder check still worked. It only means `mediauser` cannot access your login user's home directory. Use the `sh -c 'cd / && ...'` form above to avoid that warning.

If the top-level folders already exist like this:

```text
/mnt/media/data/media
/mnt/media/data/torrents
/mnt/media/data/usenet
```

that is fine. The command above only completes the expected child folders under them.

If `sudo -u mediauser mkdir -p ...` fails with `Permission denied`, fix the TrueNAS dataset and NFS share. In the TrueNAS UI, confirm:

| Setting | Value |
|---|---|
| Dataset path | `/mnt/main/media/data` |
| Owner | `mediauser` |
| Group | `mediauser` |
| Mode | `775` or equivalent ACL write permissions |
| NFS authorized client | `192.168.1.20/32` |
| NFS Mapall User | `mediauser` |
| NFS Mapall Group | `mediauser` |

Then restart or reload NFS in TrueNAS and remount from the Docker VM:

```bash
sudo umount /mnt/media/data
sudo mount /mnt/media/data
sudo -u mediauser touch /mnt/media/data/.docker-vm-write-test
sudo -u mediauser rm /mnt/media/data/.docker-vm-write-test
```

If you prefer to create the folders directly on TrueNAS, use the real one-pool path from the TrueNAS shell:

```bash
mkdir -p \
  /mnt/main/media/data/torrents/incomplete \
  /mnt/main/media/data/torrents/movies \
  /mnt/main/media/data/torrents/tv \
  /mnt/main/media/data/usenet/incomplete \
  /mnt/main/media/data/usenet/movies \
  /mnt/main/media/data/usenet/tv \
  /mnt/main/media/data/media/movies \
  /mnt/main/media/data/media/tv \
  /mnt/main/media/data/media/music

chown -R mediauser:mediauser /mnt/main/media/data
chmod -R 775 /mnt/main/media/data
```

Then verify again from the Docker VM:

```bash
findmnt -T /mnt/media/data -o TARGET,SOURCE,FSTYPE,OPTIONS
ls -lah /mnt/media/data
sudo -u mediauser touch /mnt/media/data/.docker-vm-write-test
sudo -u mediauser rm /mnt/media/data/.docker-vm-write-test
```

If the folders exist on TrueNAS but still show `MISS` from the Docker VM, the VM is mounted to the wrong export or wrong local target. Compare both sides:

```bash
# TrueNAS shell
ls -lah /mnt/main/media/data
```

```bash
# Docker VM
findmnt -R /mnt/media
findmnt -T /mnt/media/data -o TARGET,SOURCE,FSTYPE,OPTIONS
ls -lah /mnt/media/data
```

The Docker VM target must be `/mnt/media/data`, not `/mnt/media`, and the source must be `192.168.1.10:/mnt/main/media/data`.

## Step 6: Create Local Docker Directories

Compose files live on the Docker VM. Persistent app data lives on TrueNAS.

```bash
sudo mkdir -p /opt/stacks
sudo chown -R "$USER":"$USER" /opt/stacks
```

Do not create `/mnt/main/appdata` locally on the Docker VM. If `/mnt/main` is mounted from TrueNAS, create or fix `/mnt/main/appdata` from the TrueNAS UI/storage guide, then confirm it is visible through the `/mnt/main` NFS mount:

```bash
findmnt /mnt/main
ls -ld /mnt/main/appdata
sudo -u mediauser test -w /mnt/main/appdata
```

If `/mnt/main/appdata` is missing or read-only, go back to the TrueNAS storage guide and create/fix the `main/appdata` dataset and NFS export.

### If `/mnt/main/appdata` Is Missing Or Read-Only

First verify the Docker VM is really using the TrueNAS `/mnt/main` export:

```bash
findmnt -T /mnt/main -o TARGET,SOURCE,FSTYPE,OPTIONS
ls -ld /mnt/main
```

Expected result:

```text
TARGET    SOURCE
/mnt/main 192.168.1.10:/mnt/main
```

If `findmnt` is empty or the source is wrong, fix `/etc/fstab` so the main line is:

```fstab
192.168.1.10:/mnt/main /mnt/main nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
```

Then remount:

```bash
sudo systemctl daemon-reload
sudo mount -a
findmnt -T /mnt/main -o TARGET,SOURCE,FSTYPE,OPTIONS
```

If `/mnt/main` is mounted correctly but `/mnt/main/appdata` is missing, create the `appdata` dataset in the TrueNAS UI:

```text
Datasets -> main -> Add Dataset -> Name: appdata
Owner: mediauser
Group: mediauser
Permissions: owner/group read-write-execute
```

If using the TrueNAS shell instead, create the path and permissions there:

```bash
mkdir -p /mnt/main/appdata
chown mediauser:mediauser /mnt/main/appdata
chmod 770 /mnt/main/appdata
```

The UI dataset method is better because it gives `appdata` its own snapshots and permissions.

If `/mnt/main/appdata` exists but the Docker VM says it is read-only, check the NFS share in TrueNAS:

| Setting | Value |
|---|---|
| NFS export path | `/mnt/main` |
| Authorized client | `192.168.1.20/32` |
| Read-only | Disabled |
| Mapall User | `mediauser` |
| Mapall Group | `mediauser` |

Then remount and test from the Docker VM:

```bash
sudo umount /mnt/main
sudo mount /mnt/main
ls -ld /mnt/main/appdata
sudo -u mediauser test -w /mnt/main/appdata
```

Do not continue until `/mnt/main/appdata` is writable by `mediauser`.

For ARR specifically, the ARR guide creates:

```text
/mnt/main/appdata/arr-stack
/mnt/media/data
```

## Step 7: Configure UFW Firewall

Local-first rule: allow management from the LAN. If the Docker VM does not have Tailscale installed, do not add `100.64.0.0/10` rules yet. Remote shell access can still go through Proxmox over Tailscale, then from Proxmox to the Docker VM.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow from 192.168.1.0/24 to any port 22 proto tcp

sudo ufw allow from 192.168.1.0/24 to any port 5001 proto tcp

sudo ufw enable
sudo ufw status verbose
```

Port `5001` is for Dockge if you choose to use it. Service-specific ARR ports are added in the ARR guide.

If you later install Tailscale directly on the Docker VM, add:

```bash
sudo ufw allow from 100.64.0.0/10 to any port 22 proto tcp
sudo ufw allow from 100.64.0.0/10 to any port 5001 proto tcp
sudo ufw status verbose
```

If you only access the Docker VM through Proxmox over Tailscale, the LAN rules are enough because Proxmox reaches the Docker VM from the LAN side.

## Step 8: Optional Dockge

Dockge is a Docker Compose management UI. It is useful, but it has Docker socket access, so keep it LAN-only for now. Reach it remotely only through Proxmox over Tailscale, an intentional SSH tunnel/subnet route, or direct Docker VM Tailscale if installed later.

```bash
mkdir -p /opt/stacks/dockge
cd /opt/stacks/dockge
```

Create `compose.yaml`:

```yaml
services:
  dockge:
    image: louislam/dockge:latest
    container_name: dockge
    restart: unless-stopped
    ports:
      - "192.168.1.20:5001:5001"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/stacks/dockge/data:/app/data
      - /opt/stacks:/opt/stacks
    environment:
      - DOCKGE_STACKS_DIR=/opt/stacks
```

Start:

```bash
docker compose up -d
```

Open:

```text
http://192.168.1.20:5001
```

Set a strong password immediately.

## Step 9: Enable Automatic Security Updates

Install Ubuntu security updates automatically, but keep reboots manual so a host
restart cannot interrupt storage or stateful containers unexpectedly:

```bash
sudo apt update
sudo apt install -y unattended-upgrades apt-listchanges

sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

sudo tee /etc/apt/apt.conf.d/52unattended-upgrades-local >/dev/null <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF

sudo unattended-upgrade --dry-run --debug
systemctl status unattended-upgrades --no-pager
```

Review `/var/log/unattended-upgrades/` weekly. Handle packages that require a
reboot during the maintenance window in the monitoring and updates guide.

## Step 10: What Not To Deploy Yet

Do not deploy these at this stage:

- Traefik
- Cloudflare Tunnel
- public reverse proxy routes
- Watchtower auto-updates
- Dozzle
- Portainer if Dockge is already used

Reason: the current goal is a stable local setup first. Public exposure and extra Docker socket tools come later.

## Step 11: Next Guide

After this Docker VM guide, follow:

```text
docs/services/arr-stack-homelab-fit-review-and-setup.md
```

That guide adds the ARR stack ports, qBittorrent VPN, media directory layout, and end-to-end local testing.
