# Ubuntu Docker VM Local-First Setup

Last updated: 2026-06-10

This guide configures the Ubuntu Server VM that runs Docker services. In this homelab, TrueNAS is storage only and Docker containers run on the Ubuntu Docker VM.

Use this guide after the [Proxmox initial setup](proxmox-initial-setup.md), creating the Ubuntu Server VM in the Proxmox web UI, and the [TrueNAS storage setup](truenas-storage-setup.md) at least through dataset creation.

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

If actual IPs differ, replace them consistently. Check on the Docker VM:

```bash
ip addr
ip route
ping -c 3 192.168.1.10
```

## Step 2: Install Docker And Compose

Docker is the container runtime; Docker Compose reads `compose.yaml` files and starts multi-container stacks.

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER
```

Log out and back in so group membership applies. Verify:

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

`nfs-common` mounts TrueNAS NFS exports, `ufw` is a simple host firewall, `curl`/`ca-certificates` are needed by health checks and setup scripts, and `htop`/`tmux` are practical administration tools.

## Step 4: Create Matching Media User

Create the same numeric user/group on TrueNAS and Ubuntu. Replace `3000` with the UID/GID created in TrueNAS.

```bash
sudo groupadd -g 3000 mediauser
sudo useradd -u 3000 -g 3000 -M -s /usr/sbin/nologin mediauser
id mediauser
```

Containers write files using numeric IDs, and TrueNAS permissions also resolve numeric IDs — matching IDs prevents root-owned files and failed Radarr/Sonarr imports.

## Step 5: Mount TrueNAS Storage

```bash
sudo mkdir -p /mnt/main /mnt/media/data
```

Add to `/etc/fstab`:

```fstab
192.168.1.10:/mnt/main  /mnt/main  nfs4  rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576  0  0
192.168.1.10:/mnt/main/media/data /mnt/media/data nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
```

This is the current one-pool layout — the Docker VM still uses `/mnt/media/data`, but that mount comes from the TrueNAS path `/mnt/main/media/data`.

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

If either `findmnt` is empty, fix `/etc/fstab` or the TrueNAS NFS export before continuing. If the write test fails, fix the TrueNAS NFS export mapping and dataset permissions — `/mnt/main/appdata` should come from the TrueNAS `main/appdata` dataset, not a local Docker VM directory.

Verify the ARR media folders:

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

In the one-pool TrueNAS layout, those paths map to the equivalent `/mnt/main/media/data/...` tree, which can also be checked directly from the TrueNAS shell by dropping the `sudo -u mediauser` prefix and using the real paths.

### If The Media Folder Check Shows `MISS`

Don't guess — first confirm what's mounted:

```bash
findmnt -T /mnt/media/data -o TARGET,SOURCE,FSTYPE,OPTIONS
ls -lah /mnt/media/data
```

Expected one-pool result: target `/mnt/media/data`, source `192.168.1.10:/mnt/main/media/data`. If the mount is correct, inspect the directory tree:

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

Common wrong layouts to watch for: `/mnt/media/data/movies`, `/mnt/media/data/tv`, `/mnt/media/data/music`, `/mnt/media/data/downloads`, `/mnt/media/data/data`, `/mnt/media/data/media/media/movies`, `/mnt/media/data/torrents/torrents/movies`. Don't delete or move existing files automatically — create correct folders first, then move files intentionally after confirming what each folder contains.

If `SOURCE` isn't `192.168.1.10:/mnt/main/media/data`, fix `/etc/fstab` accordingly and remount:

```bash
sudo systemctl daemon-reload
sudo umount /mnt/media/data
sudo mount -a
findmnt -T /mnt/media/data -o TARGET,SOURCE,FSTYPE,OPTIONS
```

If the mount source is correct but nested folders are missing, create the expected ARR folders from the Docker VM over the NFS mount:

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

Rerun the folder verification loop. If `chmod` returns `Operation not permitted` but `mkdir` and the write test work as `mediauser`, that's fine — TrueNAS ACLs can block chmod over NFS even when normal file access is correct; fix mode/ACLs from the TrueNAS UI only if containers can't read or write. If `find`/`ls` return `Permission denied` for the login user but work via `sudo -u mediauser`, that's expected for `770` media folders.

If `sudo -u mediauser mkdir -p ...` fails with `Permission denied`, fix the TrueNAS dataset and NFS share: dataset path `/mnt/main/media/data`, owner/group `mediauser`, mode `775` or equivalent ACL write permissions, NFS authorized client `192.168.1.20/32`, NFS Mapall User/Group `mediauser`. Then restart/reload NFS in TrueNAS and remount:

```bash
sudo umount /mnt/media/data
sudo mount /mnt/media/data
sudo -u mediauser touch /mnt/media/data/.docker-vm-write-test
sudo -u mediauser rm /mnt/media/data/.docker-vm-write-test
```

If the folders exist on TrueNAS but still show `MISS` from the Docker VM, the VM is mounted to the wrong export or local target — compare `ls -lah /mnt/main/media/data` on TrueNAS against `findmnt -R /mnt/media`, `findmnt -T /mnt/media/data`, and `ls -lah /mnt/media/data` on the Docker VM. The Docker VM target must be `/mnt/media/data` (not `/mnt/media`), sourced from `192.168.1.10:/mnt/main/media/data`.

## Step 6: Create Local Docker Directories

Compose files live on the Docker VM; persistent app data lives on TrueNAS.

```bash
sudo mkdir -p /opt/stacks
sudo chown -R "$USER":"$USER" /opt/stacks
```

Do not create `/mnt/main/appdata` locally on the Docker VM. If `/mnt/main` is mounted from TrueNAS, create or fix `/mnt/main/appdata` from the TrueNAS storage guide, then confirm it's visible through the mount:

```bash
findmnt /mnt/main
ls -ld /mnt/main/appdata
sudo -u mediauser test -w /mnt/main/appdata
```

### If `/mnt/main/appdata` Is Missing Or Read-Only

First verify the Docker VM is really using the TrueNAS `/mnt/main` export:

```bash
findmnt -T /mnt/main -o TARGET,SOURCE,FSTYPE,OPTIONS
ls -ld /mnt/main
```

Expected source: `192.168.1.10:/mnt/main`. If empty or wrong, fix `/etc/fstab` and remount:

```bash
sudo systemctl daemon-reload
sudo mount -a
findmnt -T /mnt/main -o TARGET,SOURCE,FSTYPE,OPTIONS
```

If `/mnt/main` is mounted correctly but `appdata` is missing, create the dataset in the TrueNAS UI (Datasets → `main` → Add Dataset → Name `appdata`, Owner/Group `mediauser`, owner/group read-write-execute) — the UI method is preferred over shell `mkdir` because it gives `appdata` its own snapshots and permissions.

If `/mnt/main/appdata` exists but is read-only, check the NFS share settings (export path `/mnt/main`, authorized client `192.168.1.20/32`, read-only disabled, Mapall User/Group `mediauser`), then remount and retest:

```bash
sudo umount /mnt/main
sudo mount /mnt/main
ls -ld /mnt/main/appdata
sudo -u mediauser test -w /mnt/main/appdata
```

Do not continue until `/mnt/main/appdata` is writable by `mediauser`. For ARR specifically, the ARR guide creates `/mnt/main/appdata/arr-stack` and `/mnt/media/data`.

## Step 7: Configure UFW Firewall

Local-first rule: allow management from the LAN. If Tailscale isn't installed on the Docker VM, don't add `100.64.0.0/10` rules yet — remote shell access can go through Proxmox over Tailscale, then from Proxmox to the Docker VM.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow from 192.168.1.0/24 to any port 22 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 5001 proto tcp

sudo ufw enable
sudo ufw status verbose
```

Port `5001` is for Dockge if used. Service-specific ARR ports are added in the ARR guide. If Tailscale is later installed directly on the Docker VM, add equivalent `100.64.0.0/10` rules for ports 22 and 5001.

## Step 8: Optional Dockge

Dockge is a Docker Compose management UI with Docker socket access, so it's kept LAN-only. Reach it remotely only through Proxmox over Tailscale, an SSH tunnel/subnet route, or direct Docker VM Tailscale if installed later.

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

```bash
docker compose up -d
```

Open `http://192.168.1.20:5001` and set a strong password immediately.

## Step 9: Enable Automatic Security Updates

Ubuntu security updates install automatically, but reboots stay manual so a host restart can't interrupt storage or stateful containers unexpectedly:

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

Review `/var/log/unattended-upgrades/` weekly. Packages requiring a reboot are handled during the maintenance window described in `docs/setup-and-testing/monitoring-and-updates.md`.

## Step 10: What Not To Deploy Yet

Not deployed at this stage: Traefik, Cloudflare Tunnel, public reverse proxy routes, Watchtower auto-updates, Dozzle, and Portainer (if Dockge is already used). The current goal is a stable local setup first — public exposure and extra Docker socket tools come later.

## Step 11: Next Guide

After this Docker VM guide, follow:

```text
docs/services/arr-stack-homelab-fit-review-and-setup.md
```

That guide adds the ARR stack ports, qBittorrent VPN, media directory layout, and end-to-end local testing.
