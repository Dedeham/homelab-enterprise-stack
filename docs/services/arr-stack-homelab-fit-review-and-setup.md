# ARR Stack Local-First Homelab Setup Guide

Last updated: 2026-06-10

This is the source-of-truth ARR stack guide for the current homelab. It replaces the older broad ARR guides for initial deployment.

Core assumptions:

- Everything is set up locally on the home network first.
- Internet exposure is a final, optional phase.
- Tailscale is already set up for remote management access through Proxmox. The Docker VM does not currently have Tailscale installed.
- TrueNAS is storage only. Docker containers do not run on TrueNAS.
- The Ubuntu Server Docker VM runs Docker/Dockge and all media services.
- Hermes is isolated on `10.10.100.2` and must not mount TrueNAS storage.
- Proxmox and the VM layout are already created.

External material reviewed:

- Servers@Home ARR compose and Dockge approach: https://github.com/serversathome/ServersatHome/blob/main/dockge-arr-stack-compose.yaml
- Servers@Home wiki: https://wiki.serversatho.me/
- Servarr Docker guide: https://wiki.servarr.com/docker-guide
- TRaSH hardlinks and atomic moves guide: https://trash-guides.info/File-and-Folder-Structure/Hardlinks-and-Instant-Moves/
- hotio qBittorrent VPN documentation: https://hotio.dev/containers/qbittorrent/
- Private Internet Access manual connection scripts and notes: https://github.com/pia-foss/manual-connections
- LinuxServer.io PUID/PGID guidance: https://docs.linuxserver.io/general/understanding-puid-and-pgid/
- Recyclarr documentation: https://recyclarr.dev/guide/
- Bazarr documentation: https://www.bazarr.media/
- Unpackerr documentation: https://unpackerr.zip/docs/introduction
- Gluetun container networking docs: https://github.com/qdm12/gluetun-wiki/blob/main/setup/connect-a-container-to-gluetun.md
- Tailscale subnet router docs: https://tailscale.com/kb/1019/subnets
- Docker Engine security docs: https://docs.docker.com/engine/security/

## Short Decision Summary

Use this stack order:

1. Local LAN first; remote management through Proxmox over Tailscale unless Tailscale is added to the Docker VM later.
2. TrueNAS provides NFS storage to the Docker VM.
3. Docker VM runs Dockge optionally, plus a plain Compose ARR stack.
4. qBittorrent is the PIA VPN anchor for the download/search side of the stack.
5. qBittorrent, Prowlarr, Radarr, Sonarr, FlareSolverr, and optional subtitle/profile/download helpers route through the PIA VPN namespace.
6. Jellyfin and Seerr stay on normal Docker networking because they are local playback/request services, not torrent/indexer clients.
7. Cloudflare Tunnel or public reverse proxy comes last and only for Jellyfin/Seerr if you really want it.

Recommended initial services:

| Service | Include initially | Reason |
|---|---:|---|
| Prowlarr | Yes | Central indexer management for Radarr/Sonarr. |
| Radarr | Yes | Movies. |
| Sonarr | Yes | TV shows. |
| qBittorrent with VPN | Yes | Download client with VPN enforcement. |
| Jellyfin | Yes | Local media playback and library validation. |
| Seerr | Yes, after Jellyfin works | Request UI, useful but not required for first import test. |
| FlareSolverr | Yes, internal only | Only used when specific indexers need it. No LAN port. |
| Bazarr | Optional profile | Subtitles; useful after Radarr/Sonarr are stable. |
| Recyclarr | Optional profile | Syncs TRaSH quality profiles; better after basic manual setup is understood. |
| Unpackerr | Optional profile | Extracts archived downloads; useful for some indexers/usenet, not needed on day one. |
| Qui | No for initial setup | Nice qBittorrent UI, but extra unauthenticated surface. |
| Profilarr | No for initial setup | Recyclarr is better documented for TRaSH sync. |
| Watchtower | No for initial setup | Auto-update risk. Use manual updates first. |
| Dozzle | No for initial setup | Requires Docker socket access. Use `docker compose logs` first. |
| Gluetun | Not initially | Excellent VPN gateway, but hotio qBittorrent VPN is simpler and can still share its VPN namespace with ARR search/download services. |
| DockSTARTer/YAMS/Saltbox-style installers | No | Good projects, but too much abstraction for learning and for this VM design. |

## Research Conclusion: What To Borrow From Other ARR Stacks

I reviewed common ARR stack patterns and pulled in only the pieces that improve security, simplicity, or stability for this homelab.

| Pattern/project | Useful idea | Keep or skip for this setup |
|---|---|---|
| Servers@Home Dockge stack | Dockge-managed Compose stacks are approachable and easy to inspect. | Keep the Dockge idea, but reduce the initial service count and avoid the TrueNAS-app UID assumption. |
| Servarr Docker guide | Use consistent paths, non-root users, and planned ownership. | Keep. This is the most important operational pattern. |
| TRaSH hardlink guide | Put downloads and final media under one shared data root so hardlinks/atomic moves can work. | Keep. Use `/mnt/media/data` on host and `/data` in containers. |
| DockSTARTer/YAMS-style installers | Fast all-in-one deployment. | Skip for now. They hide too much while you are learning and can install more than you need. |
| Gluetun gateway pattern | Strong VPN gateway for multiple VPN-routed apps. | Defer. Use hotio qBittorrent VPN first because it supports PIA and can share the VPN namespace with the ARR services that need privacy. |
| binhex qBittorrentVPN | Mature VPN-bundled qBittorrent alternative. | Viable fallback, but hotio is closer to the Servers@Home compose you referenced. |
| Recyclarr | Sync TRaSH quality profiles and naming once Radarr/Sonarr work. | Optional after base setup. |
| Bazarr | Subtitle automation tied to Radarr/Sonarr. | Optional, low-risk if you need subtitles. |
| Unpackerr | Handles archived releases automatically. | Optional only if your indexers/downloads need extraction. |
| Watchtower/Dozzle | Useful monitoring/convenience. | Skip initially due Docker socket exposure and update risk. |

The resulting stack is intentionally conservative: it starts with the minimum useful media workflow, keeps all management local-first, uses Proxmox as the current Tailscale remote entry point, and leaves public exposure and advanced automation until after the stack is stable.

## Current Fit Review

What fits:

- Separate storage and compute is the correct design.
- TrueNAS storage VM + Ubuntu Docker VM is cleaner and safer than running apps directly on TrueNAS.
- Tailscale is a good remote management layer and means you do not need to expose ARR management UIs to the internet. In the current layout, Tailscale reaches Proxmox first; direct Docker VM Tailnet access is optional.
- Hermes on `10.10.100.2` belongs on the isolated network and should stay separate.

What needed correction:

- Older docs still described TrueNAS as the app hub in places. That is wrong for the current build.
- Older ARR docs assumed NFS and permissions were already configured.
- Older ARR docs copied the Servers@Home `PUID=568` convention. That is not automatically correct for Ubuntu Docker.
- Older ARR docs exposed too many management ports as if that were the final state.
- The setup order needed to be local-first, with internet exposure last.

## Missing Configuration And Security Risks Right Now

Before deploying ARR, these are the important gaps:

| Gap | Risk | Required action |
|---|---|---|
| Docker VM firewall not finished | LAN services may be too broadly reachable | Enable UFW and allow LAN sources only for now. Add Tailscale sources only if Docker VM Tailscale or subnet routing is intentionally configured. |
| Tailscale ACLs not reviewed | Remote access to Proxmox may be too permissive | Confirm only your devices/users can reach Proxmox, and later any Docker VM route if added. |
| qBittorrent VPN not configured | Torrent traffic could leak home WAN IP | Do not download until VPN IP and kill switch are verified. |
| Docker VM DNS not hardened | PIA bootstrap or non-VPN containers may use ISP DNS | Configure encrypted DNS on the Docker VM before starting the ARR stack. |
| ARR metadata apps not VPN-routed | Indexer/search/subtitle DNS and HTTPS metadata could be visible to ISP | Use the PIA shared network namespace compose in this guide. |
| Appdata backups not configured | Loss of Radarr/Sonarr/Jellyfin databases means painful rebuild | Back up `/mnt/main/appdata/arr-stack`. |
| Old docs still conflict | You may follow wrong service placement or port exposure | Use this guide as source of truth. |
| Hermes isolation not re-tested after IP change | Isolated VM might reach LAN services | Verify `10.10.100.2` cannot reach `192.168.1.0/24`. |
| Docker socket tools not decided | Dockge/Dozzle/Watchtower can control Docker host | Keep Dockge private; avoid Dozzle/Watchtower at first. |
| Internet exposure not staged | Public attack surface too early | Complete local setup first, then remote via Tailscale, then optional Cloudflare. |

## DNS Leak And ISP Visibility Analysis

Short answer: the old draft did not fully meet your goal. It protected qBittorrent only after the VPN was up. It did not stop Prowlarr, Radarr, Sonarr, FlareSolverr, Bazarr, Recyclarr, Jellyfin metadata fetches, Seerr metadata calls, or Docker VM startup DNS from using the normal home internet path.

This updated guide uses a stricter default:

| Traffic type | Old draft | Updated default in this guide | What your ISP can still see |
|---|---|---|---|
| qBittorrent peer traffic | Through VPN only if `wg0.conf` worked | Through PIA WireGuard with hotio firewall and healthcheck | That your home IP connects to PIA. Not torrent peers/content. |
| qBittorrent DNS | Intended to use WireGuard DNS, but not deeply verified | `VPN_NAMESERVERS=wg`, IPv6 disabled, DNS tested after boot | That your home IP connects to PIA. Not qBittorrent DNS queries if tests pass. |
| Prowlarr indexer DNS/searches | Normal Docker/LAN path | Shares qBittorrent PIA network namespace | Nothing about indexer domains if the VPN namespace is healthy. |
| Radarr/Sonarr metadata and download-client calls | Normal Docker/LAN path | Shares qBittorrent PIA network namespace | Nothing about those app lookups if the VPN namespace is healthy. |
| FlareSolverr browser traffic | Normal Docker/LAN path | Shares qBittorrent PIA network namespace | Nothing about those requests if the VPN namespace is healthy. |
| Bazarr/Recyclarr/Unpackerr optional traffic | Normal Docker/LAN path | Shares qBittorrent PIA network namespace when enabled | Nothing about those requests if the VPN namespace is healthy. |
| Jellyfin metadata fetches | Normal Docker/LAN path | Normal Docker/LAN path | ISP can see upstream DNS/connection metadata unless you disable metadata fetchers or route Jellyfin through a separate VPN later. |
| Seerr external metadata/API calls | Normal Docker/LAN path | Normal Docker/LAN path | ISP can see upstream DNS/connection metadata unless you route Seerr through a separate VPN later. |
| Docker VM host DNS | Router/ISP-dependent | Must be hardened separately with encrypted DNS | ISP can see DNS if the Docker VM or router uses ISP DNS. |
| PIA bootstrap | Normal internet before tunnel exists | Normal internet before tunnel exists | ISP can see you connecting to PIA and may see PIA API DNS unless host DNS is encrypted. |

Important limits:

- No VPN setup can hide the fact that your home connection is talking to PIA. Your ISP can see the destination IP of the VPN server and encrypted UDP traffic volume.
- A torrent VPN does not automatically protect every container. Containers must either share the VPN network namespace or use a separate VPN/proxy path.
- DNS-over-HTTPS or DNS-over-TLS hides DNS query contents from the ISP, but it does not hide the final destination IPs of non-VPN traffic.
- The strict privacy target for this ARR guide is: no qBittorrent, indexer, search, subtitle, or ARR automation DNS/traffic leaves outside PIA after the VPN container is healthy.

For your stated preference, treat the PIA-routed compose below as the default. If you later decide Jellyfin and Seerr metadata should also be hidden from the ISP, either disable their internet metadata features or move them to a separate VPN/proxy design after the base stack works. Do not put Jellyfin playback behind the torrent VPN casually; it can break LAN playback, remote streaming, and service discovery.

## Network Model

Use this local-first model:

```text
Home LAN: 192.168.1.0/24
  Router:       192.168.1.1
  Proxmox:      192.168.1.2
  TrueNAS:      192.168.1.10
  Docker VM:    192.168.1.20

Isolated network: 10.10.100.0/24
  Gateway:      10.10.100.1
  Hermes:       10.10.100.2

Tailscale:
  Current remote entry point is Proxmox.
  Use 100.64.0.0/10 in Docker VM firewalls only if the Docker VM joins Tailscale directly
  or if subnet routing is intentionally configured to preserve Tailscale client source IPs.
```

Use `192.168.1.0/24` for the trusted home LAN and keep `10.10.100.0/24` only for the isolated bridge. If any real static IP differs, replace that one IP consistently everywhere.

## Storage Design

The ARR ecosystem is sensitive to paths. Servarr and TRaSH both recommend consistent paths so Radarr/Sonarr and the download client see the same files at the same internal paths.

Use one media data tree mounted as `/data` inside the ARR/download containers:

```text
/mnt/media/data
├── torrents
│   ├── incomplete
│   ├── movies
│   └── tv
├── usenet
│   ├── incomplete
│   ├── movies
│   └── tv
└── media
    ├── movies
    ├── tv
    └── music
```

Why this matters:

- Radarr, Sonarr, and qBittorrent all see the same root path: `/data`.
- Import path mapping is simpler.
- Moves stay predictable.
- If the source and destination are on the same underlying filesystem or dataset, hardlinks and atomic moves can work.
- If you create separate TrueNAS child datasets for downloads and media, hardlinks across those datasets will not work. For the first setup, keep downloads and media as directories under the same dataset.

App configs live separately:

```text
/mnt/main/appdata/arr-stack
```

This keeps databases/configs on protected storage while media can remain on your media pool.

## Phase 0: Confirm What Is Already Done

You said:

- Proxmox initial setup is complete.
- Proxmox phase 2 VM setup is complete.
- Ubuntu Docker setup is complete.
- TrueNAS storage setup is complete.
- Tailscale is already set up on Proxmox for remote management.
- Hermes is `10.10.100.2`.

Record the real values before continuing:

```text
TrueNAS IP:
Docker VM IP:
Docker VM username:
TrueNAS pool names:
Tailscale device name for Proxmox:
Tailscale device name for Docker VM, if installed later:
VPN provider:
```

## Phase 1: Verify Hermes Isolation

Hermes is not part of the ARR stack, but it affects your security posture.

From the Hermes VM at `10.10.100.2`, these should fail:

```bash
ping -c 3 192.168.1.1
ping -c 3 192.168.1.2
ping -c 3 192.168.1.10
ping -c 3 192.168.1.20
```

These should work:

```bash
ping -c 3 1.1.1.1
curl -I --connect-timeout 5 https://example.com
```

If Hermes can reach TrueNAS or Docker VM, stop and fix Proxmox `vmbr1` firewall/NAT rules before proceeding.

## Phase 2: Finish TrueNAS Storage

### 2.1 Create Dedicated Media User

In TrueNAS:

1. Go to `Credentials -> Local Users`.
2. Add user `mediauser`.
3. Create or assign group `mediauser`.
4. Set a strong password if you also want SMB access from Windows.
5. Record the numeric UID and GID.

Example:

```text
MEDIA_UID=3000
MEDIA_GID=3000
```

Use your actual values in every later command.

### 2.2 Create Or Confirm Datasets

Recommended datasets:

```text
/mnt/main
/mnt/main/appdata
/mnt/media
```

Inside `/mnt/media`, create directories, not separate datasets, for the first ARR deployment:

```text
/mnt/media/data/torrents/incomplete
/mnt/media/data/torrents/movies
/mnt/media/data/torrents/tv
/mnt/media/data/usenet/incomplete
/mnt/media/data/usenet/movies
/mnt/media/data/usenet/tv
/mnt/media/data/media/movies
/mnt/media/data/media/tv
/mnt/media/data/media/music
```

Why directories instead of child datasets here:

- Hardlinks cannot cross filesystems or datasets.
- ARR imports are simpler when downloads and final media are under the same dataset.
- You can still snapshot the parent media dataset.

### 2.3 Set Permissions

Set owner/group:

| Path | Owner | Group |
|---|---|---|
| `/mnt/main/appdata` | `mediauser` | `mediauser` |
| `/mnt/media/data` | `mediauser` | `mediauser` |

Use a simple permission model for first deployment:

- Owner: read/write/execute
- Group: read/write/execute
- Others: no access or read-only, depending on your LAN needs

Avoid using TrueNAS `root`, `admin`, or your personal admin account as the media service identity.

### 2.4 Create NFS Shares

Create NFS exports:

| Export | Authorized host/network | Purpose |
|---|---|---|
| `/mnt/main/appdata` | `192.168.1.20/32` | Appdata/config storage |
| `/mnt/media/data` | `192.168.1.20/32` | ARR media/download storage |

If you only created one mirrored TrueNAS pool named `main`, export `/mnt/main/media/data` instead of `/mnt/media/data`. The Docker VM should still mount it at `/mnt/media/data`.

If you also export `/mnt/main` for browsing or future services, keep the `/mnt/main/appdata` export too. Child datasets such as `main/appdata` can fail to appear or can deny access through the parent export unless they are exported directly.

Recommended settings:

- Restrict access to the Docker VM IP only.
- Use NFSv4 if available.
- Map all access to `mediauser:mediauser` if TrueNAS offers Mapall User/Group.
- Enable NFS service autostart.
- Restart or reload the NFS service after changing shares.

### 2.5 Optional SMB Share

SMB is for Windows or desktop file browsing, not for Docker containers.

If needed:

- Share `/mnt/media/data`.
- Login as `mediauser`.
- Do not login from Windows as TrueNAS admin/root.

## Phase 3: Finish Docker VM Foundation

### 3.1 Create Matching Media User

On the Docker VM, replace `3000` with your real TrueNAS UID/GID:

```bash
sudo groupadd -g 3000 mediauser
sudo useradd -u 3000 -g 3000 -M -s /usr/sbin/nologin mediauser
id mediauser
```

Why: containers write files using numeric IDs. Matching IDs between TrueNAS and Ubuntu prevents permission confusion.

### 3.2 Install NFS And Firewall Tools

```bash
sudo apt update
sudo apt install -y nfs-common ufw curl ca-certificates
```

### 3.3 Mount TrueNAS Storage

Create mount points:

```bash
sudo mkdir -p /mnt/main/appdata /mnt/media/data
```

Add to `/etc/fstab`:

```fstab
192.168.1.10:/mnt/main/appdata /mnt/main/appdata nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
192.168.1.10:/mnt/media/data /mnt/media/data nfs4  rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576  0  0
```

If using the one-pool fallback, replace the second line with:

```fstab
192.168.1.10:/mnt/main/media/data /mnt/media/data nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
```

If you instead mounted the whole single pool at `/mnt/main`, then `/mnt/main/appdata` is not its own mount point. In that layout, `/etc/fstab` has a parent mount like this:

```fstab
192.168.1.10:/mnt/main /mnt/main nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
```

For that parent-mount layout:

- Do not run `sudo mount /mnt/main/appdata`; it will fail with `can't find in /etc/fstab`.
- Remount `/mnt/main`, not `/mnt/main/appdata`.
- Keep `CONFIG_PATH=/mnt/main/appdata/arr-stack`.
- Either mount `/mnt/main/media/data` separately at `/mnt/media/data`, or change `DATA_PATH` to `/mnt/main/media/data` and update the media directory commands to match.

This fstab layout is valid and matches the compose defaults:

```fstab
192.168.1.10:/mnt/main /mnt/main nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
192.168.1.10:/mnt/main/media/data /mnt/media/data nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
```

With that layout, appdata comes from `/mnt/main/appdata`, and media comes from the explicit `/mnt/media/data` mount. Use `/mnt/media/data` consistently in Docker; do not mix it with `/mnt/main/media/data` inside compose.

Recommended single-pool choice for this guide: keep the appdata and media paths used by the compose by mounting both targets explicitly:

```fstab
192.168.1.10:/mnt/main/appdata /mnt/main/appdata nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
192.168.1.10:/mnt/main/media/data /mnt/media/data nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
```

This keeps the Docker paths the same whether TrueNAS has one pool or separate pools.

Apply:

```bash
sudo systemctl daemon-reload
sudo mount -a
df -h | grep /mnt
```

Write test as the service user:

```bash
sudo -u mediauser touch /mnt/main/appdata/.docker-vm-write-test
sudo -u mediauser rm /mnt/main/appdata/.docker-vm-write-test
sudo -u mediauser touch /mnt/media/data/.docker-vm-write-test
sudo -u mediauser rm /mnt/media/data/.docker-vm-write-test
```

If this fails, fix TrueNAS permissions/NFS mapping before continuing.

### 3.4 Create Directories

Create NFS-backed directories as `mediauser`, not with `sudo mkdir`. TrueNAS owns the permissions model for these datasets, and many NFS setups map or restrict root. In that case `sudo mkdir`, `sudo chown`, or `sudo chmod` from the Docker VM can fail even when normal container access is correctly configured.

```bash
sudo -u mediauser mkdir -p \
  /mnt/main/appdata/arr-stack/prowlarr \
  /mnt/main/appdata/arr-stack/radarr \
  /mnt/main/appdata/arr-stack/sonarr \
  /mnt/main/appdata/arr-stack/seerr \
  /mnt/main/appdata/arr-stack/jellyfin \
  /mnt/main/appdata/arr-stack/qbittorrent/wireguard \
  /mnt/main/appdata/arr-stack/flaresolverr \
  /mnt/main/appdata/arr-stack/bazarr \
  /mnt/main/appdata/arr-stack/recyclarr \
  /mnt/main/appdata/arr-stack/unpackerr

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
```

Verify from outside your login user's home directory:

```bash
sudo -u mediauser sh -c 'cd / && find /mnt/main/appdata/arr-stack -maxdepth 2 -type d' | sort
sudo -u mediauser sh -c 'cd / && find /mnt/media/data -maxdepth 3 -type d' | sort
```

Expected top-level media directories:

```text
/mnt/media/data/media
/mnt/media/data/torrents
/mnt/media/data/usenet
```

Do not run `sudo chown -R` against these NFS paths from the Docker VM. If ownership or mode changes are needed, do them in the TrueNAS UI on the dataset:

| Dataset/path | Owner | Group | Notes |
|---|---|---|---|
| `/mnt/main/appdata` | `mediauser` | `mediauser` | Apply recursively if `arr-stack` already exists. |
| `/mnt/media/data` | `mediauser` | `mediauser` | Keep downloads and final media under this one data root. |

If `sudo -u mediauser mkdir -p ...` still returns `Permission denied`, fix the TrueNAS dataset ACL/permissions or the NFS share Mapall settings, restart NFS in TrueNAS, then remount:

```bash
sudo umount /mnt/media/data 2>/dev/null || true
sudo umount /mnt/main 2>/dev/null || true
sudo mount /mnt/main
sudo mount /mnt/media/data
sudo -u mediauser test -w /mnt/main/appdata && echo "appdata writable"
sudo -u mediauser test -w /mnt/media/data && echo "media writable"
```

If `mkdir` works but `chmod` or `chown` returns `Operation not permitted`, continue. That is normal with TrueNAS ACLs or root mapping as long as `mediauser` can create, read, and write files.

If Docker later fails with an error like this:

```text
error while creating mount source path '/mnt/main/appdata/arr-stack/qbittorrent': mkdir /mnt/main/appdata/arr-stack: permission denied
```

or like this:

```text
error while creating mount source path '/mnt/media/data/media/movies': mkdir /mnt/media/data/media/movies: permission denied
```

it means Docker tried to auto-create a missing bind-mount source directory as root, and TrueNAS/NFS correctly denied it. Do not fix this with `sudo chown -R` from the Docker VM. Pre-create the missing directories as `mediauser`:

```bash
sudo -u mediauser mkdir -p \
  /mnt/main/appdata/arr-stack/prowlarr \
  /mnt/main/appdata/arr-stack/radarr \
  /mnt/main/appdata/arr-stack/sonarr \
  /mnt/main/appdata/arr-stack/seerr \
  /mnt/main/appdata/arr-stack/jellyfin \
  /mnt/main/appdata/arr-stack/qbittorrent/wireguard \
  /mnt/main/appdata/arr-stack/flaresolverr \
  /mnt/main/appdata/arr-stack/bazarr \
  /mnt/main/appdata/arr-stack/recyclarr \
  /mnt/main/appdata/arr-stack/unpackerr

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
```

Then retry:

```bash
cd /opt/stacks/arr-stack
docker compose up qbittorrent
```

If the `sudo -u mediauser mkdir -p ...` command gets `Permission denied`, the problem is not Docker. Fix the TrueNAS ownership/ACL or NFS Mapall settings for `/mnt/main/appdata` or `/mnt/media/data`, restart NFS, remount on the Docker VM, then retry the write test.

If `sudo -u mediauser mkdir -p ...` succeeds but Docker still fails with the same `mkdir ... permission denied` error, the directories exist but the Docker daemon cannot traverse them. Docker runs as root on the Docker VM, and many NFS exports squash client root to `nobody`. In that case `mediauser` can write, but Docker root cannot even prepare the bind mount.

Confirm:

```bash
sudo -u mediauser ls -ld /mnt/main/appdata/arr-stack /mnt/main/appdata/arr-stack/qbittorrent
sudo ls -ld /mnt/main/appdata/arr-stack /mnt/main/appdata/arr-stack/qbittorrent
sudo -u mediauser ls -ld /mnt/media/data/media /mnt/media/data/media/movies
sudo ls -ld /mnt/media/data/media /mnt/media/data/media/movies
```

If the `mediauser` command works and the `sudo ls` command fails with `Permission denied`, fix the TrueNAS NFS mapping for the affected export:

1. In TrueNAS, edit the NFS share for `/mnt/main/appdata` or `/mnt/media/data`, whichever path failed.
2. Set `Maproot User` to `mediauser`.
3. Set `Maproot Group` to `mediauser`.
4. If this export is dedicated to the Docker VM, also set `Mapall User` and `Mapall Group` to `mediauser`.
5. Confirm the dataset/path owner is `mediauser:mediauser`.
6. Restart or reload the TrueNAS NFS service.

Then remount and retry from the Docker VM:

```bash
sudo umount /mnt/media/data
sudo umount /mnt/main
sudo mount /mnt/main
sudo mount /mnt/media/data
sudo ls -ld /mnt/main/appdata/arr-stack /mnt/main/appdata/arr-stack/qbittorrent
sudo ls -ld /mnt/media/data/media /mnt/media/data/media/movies
cd /opt/stacks/arr-stack
docker compose up -d
docker compose ps
```

Do not use `sudo chown -R` from the Docker VM for this. The fix belongs in the TrueNAS dataset permissions and NFS root mapping.

If `/mnt/media/data` is writable but a child directory such as `/mnt/media/data/media/movies` still returns `Permission denied`, the parent export is mounted correctly but that child path has a stale ACL. Confirm:

```bash
sudo -u mediauser ls -ld /mnt/media/data/media /mnt/media/data/media/movies /mnt/media/data/media/tv /mnt/media/data/media/music
sudo ls -ld /mnt/media/data/media /mnt/media/data/media/movies /mnt/media/data/media/tv /mnt/media/data/media/music
```

If either command cannot read one of those child directories, fix the TrueNAS ACL recursively on the media data path:

1. In TrueNAS, open the dataset/path that backs `/mnt/main/media/data`.
2. Set owner and group to `mediauser:mediauser`.
3. Apply permissions/ACL recursively to child directories.
4. Make sure owner and group have read, write, and execute/traverse permission.
5. Restart/reload NFS, then remount `/mnt/media/data` on the Docker VM.

Then re-check:

```bash
sudo umount /mnt/media/data
sudo mount /mnt/media/data
sudo ls -ld /mnt/media/data/media /mnt/media/data/media/movies
```

### 3.5 Firewall: LAN First, Tailscale Optional

If `tailscale status` returns `command not found` on the Docker VM, the Docker VM is not a Tailscale node. That is fine. You can still reach the Docker VM shell by connecting to Proxmox over Tailscale and then using the Proxmox console or SSH from Proxmox to `192.168.1.20`.

In this current layout, do not add Docker VM UFW rules for `100.64.0.0/10` yet. Those rules only make sense after one of these is true:

- Tailscale is installed directly on the Docker VM.
- A Tailscale subnet router is configured and you intentionally preserve Tailscale client source IPs.

Default current firewall: allow SSH, Dockge, and ARR UIs from the LAN only. This includes Proxmox at `192.168.1.2`, so Proxmox can act as the remote jump host.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow from 192.168.1.0/24 to any port 22 proto tcp

sudo ufw allow from 192.168.1.0/24 to any port 5001 proto tcp

sudo ufw allow from 192.168.1.0/24 to any port 9696 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 7878 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 8989 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 5055 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 8080 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 8096 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 6767 proto tcp

sudo ufw enable
sudo ufw status verbose
```

Optional: if you later install Tailscale directly on the Docker VM, add the Tailscale source rules:

```bash
sudo ufw allow from 100.64.0.0/10 to any port 22 proto tcp
sudo ufw allow from 100.64.0.0/10 to any port 5001 proto tcp
sudo ufw allow from 100.64.0.0/10 to any port 9696 proto tcp
sudo ufw allow from 100.64.0.0/10 to any port 7878 proto tcp
sudo ufw allow from 100.64.0.0/10 to any port 8989 proto tcp
sudo ufw allow from 100.64.0.0/10 to any port 5055 proto tcp
sudo ufw allow from 100.64.0.0/10 to any port 8080 proto tcp
sudo ufw allow from 100.64.0.0/10 to any port 8096 proto tcp
sudo ufw allow from 100.64.0.0/10 to any port 6767 proto tcp
sudo ufw status verbose
```

Why ports:

| Port | Service |
|---:|---|
| 5001 | Dockge, if used |
| 9696 | Prowlarr |
| 7878 | Radarr |
| 8989 | Sonarr |
| 5055 | Seerr |
| 8080 | qBittorrent Web UI |
| 8096 | Jellyfin |
| 6767 | Bazarr optional |

FlareSolverr, Recyclarr, and Unpackerr do not need published LAN ports.

### 3.6 Harden Docker VM DNS Before VPN Bootstrap

The PIA container still needs normal internet access before the WireGuard tunnel exists. During that bootstrap it may resolve PIA API or server names using the Docker VM's normal DNS path. If the Docker VM uses your router and the router uses ISP DNS, those bootstrap lookups can be visible to the ISP.

Harden the Docker VM resolver before starting the ARR stack. This does not replace the VPN; it only prevents plaintext host DNS leaks before the VPN is up and for normal non-VPN containers.

Check current DNS:

```bash
resolvectl status
cat /etc/resolv.conf
```

If you already run Pi-hole with encrypted upstream DNS on the Docker VM, use that design later. For the first ARR setup, use systemd-resolved with DNS-over-TLS directly from the Docker VM:

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo nano /etc/systemd/resolved.conf.d/secure-dns.conf
```

Add:

```ini
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net
FallbackDNS=
DNSOverTLS=yes
Domains=~.
```

Apply:

```bash
sudo systemctl restart systemd-resolved
resolvectl status
```

Expected result:

- `DNSOverTLS` is enabled or opportunistic/yes depending on Ubuntu version.
- DNS servers are `1.1.1.1` and `9.9.9.9`, not your router or ISP resolver.
- `/etc/resolv.conf` points at the local systemd stub or systemd-managed resolver.

If this breaks DNS on your Ubuntu version, revert this small file and fix DNS before continuing:

```bash
sudo rm /etc/systemd/resolved.conf.d/secure-dns.conf
sudo systemctl restart systemd-resolved
```

## Phase 4: Check Tailscale

First check whether Tailscale is installed on the Docker VM:

```bash
tailscale status
tailscale ip -4
```

If those commands return `command not found`, use one of these remote management paths:

| Remote path | What it gives you | Firewall impact |
|---|---|---|
| Tailscale to Proxmox, then Proxmox console | Shell access to the Docker VM | LAN UFW rules are enough. |
| Tailscale to Proxmox, then SSH from Proxmox to Docker VM | Shell access to the Docker VM | LAN UFW rules are enough because Proxmox is `192.168.1.2`. |
| SSH tunnel through Proxmox to Docker VM | Browser access to one Docker VM service at a time | LAN UFW rules are enough. |
| Install Tailscale on Docker VM | Direct Tailnet access to Docker VM UIs | Add the optional `100.64.0.0/10` UFW rules above. |
| Tailscale subnet router | Remote access to LAN IPs such as `192.168.1.20` | Usually LAN UFW rules are enough if subnet-route SNAT is enabled. |

If Tailscale is installed directly on the Docker VM, then from a remote device on Tailscale test:

```text
http://<docker-vm-tailscale-name>:8096
http://<docker-vm-tailscale-name>:7878
```

Security notes:

- Tailscale is for management access.
- Do not use Tailscale Funnel for ARR management UIs.
- In the Tailscale admin console, avoid default allow-all for other users if anyone else joins your tailnet.
- If using a subnet router, advertise only the subnet you need. Tailscale docs require advertised subnet routes to be approved.
- Proxmox shell access over Tailscale is acceptable for administration, but do not move Docker containers onto Proxmox.

## Phase 5: Optional Dockge

Dockge is convenient and matches Servers@Home. It is still an admin tool with Docker socket access.

Install only on LAN. It can be reached remotely through Proxmox over Tailscale, or directly over Tailscale later if the Docker VM joins the Tailnet:

```bash
sudo mkdir -p /opt/dockge /opt/stacks
sudo chown -R "$USER":"$USER" /opt/dockge /opt/stacks
cd /opt/dockge
```

Create `/opt/dockge/compose.yaml`:

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
      - /opt/dockge/data:/app/data
      - /opt/stacks:/opt/stacks
    environment:
      - DOCKGE_STACKS_DIR=/opt/stacks
```

Start:

```bash
docker compose up -d
```

Open locally:

```text
http://192.168.1.20:5001
```

Set a strong password. Do not expose Dockge through Cloudflare Tunnel.

## Phase 6: Create ARR Stack Files

Create the stack directory:

```bash
mkdir -p /opt/stacks/arr-stack
cd /opt/stacks/arr-stack
```

This means the ARR stack files live here on the Docker VM:

```text
/opt/stacks/arr-stack/.env
/opt/stacks/arr-stack/compose.yaml
```

If you are using Dockge, create or edit the stack named `arr-stack` in Dockge and make sure its path is `/opt/stacks/arr-stack`. Dockge will store the same `compose.yaml` file in that directory.

### 6.1 Create `.env`

Replace UID/GID with your real values:

```bash
TZ=Europe/Berlin
DOCKER_IP=192.168.1.20
LAN=192.168.1.0/24

PUID=3000
PGID=3000

CONFIG_PATH=/mnt/main/appdata/arr-stack
DATA_PATH=/mnt/media/data

QBITTORRENT_VERSION=release-5.1.2

# Private Internet Access.
# PIA usernames usually look like p1234567. Do not use your account email here.
PIA_USER=p1234567
PIA_PASS=replace_with_your_pia_password

# Optional. Leave empty for first boot, then choose a region from
# the region list that appears under:
# /mnt/main/appdata/arr-stack/qbittorrent/wireguard/
# Use a non-US region if you want PIA port forwarding; PIA disables port
# forwarding server-side in the United States.
PIA_REGION=
PIA_PORT_FORWARD=true
```

Secure it:

```bash
chmod 600 .env
```

### 6.2 Configure Private Internet Access VPN

Use hotio's PIA mode, not generic WireGuard mode. With `VPN_PROVIDER=pia`, the qBittorrent container uses your PIA username/password to create `/config/wireguard/wg0.conf` automatically on first start.

What you need from PIA:

| Value | Where it goes | Notes |
|---|---|---|
| PIA username | `PIA_USER` in `.env` | Usually starts with `p`. Do not use your email address. |
| PIA password | `PIA_PASS` in `.env` | Keep `.env` mode `600`. Avoid `$`, `#`, quotes, and spaces if you can; Compose/env parsing can make those harder to troubleshoot. |
| PIA region | `PIA_REGION` in `.env` | Optional at first. Pick later from the region list written under the WireGuard config directory. |
| Port forwarding | `PIA_PORT_FORWARD=true` | Useful for torrent connectivity. Use a non-US PIA region because PIA disables port forwarding on US servers. |

Create the WireGuard config directory now so the container can write into it:

```bash
sudo -u mediauser mkdir -p /mnt/main/appdata/arr-stack/qbittorrent/wireguard
sudo -u mediauser test -w /mnt/main/appdata/arr-stack/qbittorrent/wireguard
```

Do not manually paste random PIA configs from the web. Let the container generate the config, then verify the resulting file after first boot:

```bash
sudo -u mediauser test -r /mnt/main/appdata/arr-stack/qbittorrent/wireguard/wg0.conf
sudo -u mediauser ls -la /mnt/main/appdata/arr-stack/qbittorrent/wireguard
```

If `wg0.conf` is not created, read qBittorrent logs before doing anything else:

```bash
docker logs qbittorrent --tail 200
```

Common causes:

- `PIA_USER` is your email instead of the `p...` username.
- `.env` has special characters in `PIA_PASS` that were copied or parsed incorrectly. If in doubt, set a PIA password with letters, numbers, hyphen, and underscore only.
- The Docker VM cannot resolve DNS during PIA bootstrap.
- The qBittorrent config directory is not writable by `mediauser`.
- `PIA_REGION` is set to an invalid region ID. Leave it empty for first boot if unsure.

Do not start downloads until Phase 7 confirms VPN IP, DNS behavior, and kill-switch behavior.

### 6.3 Create `compose.yaml`

Create this file on the Docker VM:

```bash
cd /opt/stacks/arr-stack
nano compose.yaml
```

Paste the YAML below into:

```text
/opt/stacks/arr-stack/compose.yaml
```

This compose is local-first, but strict about ISP visibility for the ARR search/download path.

Important networking detail:

- `qbittorrent` owns the PIA WireGuard tunnel and hotio VPN firewall.
- `prowlarr`, `radarr`, `sonarr`, `flaresolverr`, `bazarr`, `recyclarr`, and `unpackerr` use `network_mode: "service:qbittorrent"`.
- Those services do not get their own Docker network stack. Their internet traffic and DNS use the qBittorrent VPN namespace.
- Their LAN web UI ports are published on the `qbittorrent` service.
- Because they share one network namespace, configure cross-app URLs as `127.0.0.1`, not Docker service names, for the VPN-routed apps.
- `jellyfin` and `seerr` remain on the normal `arr` bridge network.
- Docker can mark the qBittorrent container as started before hotio has finished WireGuard and firewall initialization. For the strictest startup behavior, start qBittorrent first, wait for `wg0`, verify the VPN IP, and only then start the dependent VPN-routed apps. You can also add the optional healthcheck pattern below so Compose waits for qBittorrent to become healthy.

Optional services use Compose profiles so they do not start unless requested.

```yaml
services:
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    restart: unless-stopped
    network_mode: "service:qbittorrent"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${CONFIG_PATH}/prowlarr:/config
    depends_on:
      qbittorrent:
        condition: service_healthy

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    network_mode: "service:qbittorrent"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${CONFIG_PATH}/radarr:/config
      - ${DATA_PATH}:/data
    depends_on:
      qbittorrent:
        condition: service_healthy
      prowlarr:
        condition: service_started

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    network_mode: "service:qbittorrent"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${CONFIG_PATH}/sonarr:/config
      - ${DATA_PATH}:/data
    depends_on:
      qbittorrent:
        condition: service_healthy
      prowlarr:
        condition: service_started

  qbittorrent:
    image: ghcr.io/hotio/qbittorrent:${QBITTORRENT_VERSION}
    container_name: qbittorrent
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=1
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - UMASK=002
      - TZ=${TZ}
      - WEBUI_PORTS=8080/tcp,8080/udp
      - VPN_ENABLED=true
      - VPN_CONF=wg0
      - VPN_PROVIDER=pia
      - VPN_LAN_NETWORK=${LAN}
      - VPN_LAN_LEAK_ENABLED=false
      - VPN_EXPOSE_PORTS_ON_LAN=9696/tcp,7878/tcp,8989/tcp,6767/tcp
      - VPN_AUTO_PORT_FORWARD=${PIA_PORT_FORWARD}
      - VPN_PORT_REDIRECTS=
      - VPN_FIREWALL_TYPE=auto
      - VPN_HEALTHCHECK_ENABLED=true
      - VPN_NAMESERVERS=wg
      - VPN_PIA_USER=${PIA_USER}
      - VPN_PIA_PASS=${PIA_PASS}
      - VPN_PIA_PREFERRED_REGION=${PIA_REGION}
      - VPN_PIA_PORT_FORWARD_PERSIST=false
      - PRIVOXY_ENABLED=false
      - UNBOUND_ENABLED=false
    volumes:
      - ${CONFIG_PATH}/qbittorrent:/config
      - ${DATA_PATH}:/data
    ports:
      - "${DOCKER_IP}:8080:8080"
      - "${DOCKER_IP}:9696:9696"
      - "${DOCKER_IP}:7878:7878"
      - "${DOCKER_IP}:8989:8989"
      - "${DOCKER_IP}:6767:6767"
    networks:
      - arr
    healthcheck:
      test: ["CMD-SHELL", "ip link show wg0 >/dev/null 2>&1 && wg show wg0 >/dev/null 2>&1 && curl -4 -fsS --max-time 10 https://ifconfig.me >/dev/null"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 90s

  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${CONFIG_PATH}/jellyfin:/config
      - ${DATA_PATH}/media/movies:/media/movies:ro
      - ${DATA_PATH}/media/tv:/media/tv:ro
      - ${DATA_PATH}/media/music:/media/music:ro
    devices:
      - /dev/dri:/dev/dri
    ports:
      - "${DOCKER_IP}:8096:8096"
    networks:
      - arr

  seerr:
    image: ghcr.io/seerr-team/seerr:latest
    container_name: seerr
    restart: unless-stopped
    init: true
    user: "${PUID}:${PGID}"
    environment:
      - LOG_LEVEL=info
      - TZ=${TZ}
      - PORT=5055
    volumes:
      - ${CONFIG_PATH}/seerr:/app/config
    ports:
      - "${DOCKER_IP}:5055:5055"
    networks:
      - arr
    depends_on:
      - radarr
      - sonarr
      - jellyfin

  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    restart: unless-stopped
    network_mode: "service:qbittorrent"
    environment:
      - LOG_LEVEL=info
      - LOG_HTML=false
      - CAPTCHA_SOLVER=none
      - TZ=${TZ}
    depends_on:
      qbittorrent:
        condition: service_healthy

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    restart: unless-stopped
    profiles:
      - optional
    network_mode: "service:qbittorrent"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${CONFIG_PATH}/bazarr:/config
      - ${DATA_PATH}/media/movies:/movies
      - ${DATA_PATH}/media/tv:/tv
    depends_on:
      qbittorrent:
        condition: service_healthy
      radarr:
        condition: service_started
      sonarr:
        condition: service_started

  recyclarr:
    image: ghcr.io/recyclarr/recyclarr:8
    container_name: recyclarr
    restart: unless-stopped
    profiles:
      - optional
    network_mode: "service:qbittorrent"
    user: "${PUID}:${PGID}"
    environment:
      - TZ=${TZ}
    volumes:
      - ${CONFIG_PATH}/recyclarr:/config
    depends_on:
      qbittorrent:
        condition: service_healthy
      radarr:
        condition: service_started
      sonarr:
        condition: service_started

  unpackerr:
    image: golift/unpackerr:latest
    container_name: unpackerr
    restart: unless-stopped
    profiles:
      - optional
    network_mode: "service:qbittorrent"
    user: "${PUID}:${PGID}"
    environment:
      - TZ=${TZ}
    volumes:
      - ${CONFIG_PATH}/unpackerr:/config
      - ${DATA_PATH}:/data
    depends_on:
      qbittorrent:
        condition: service_healthy
      radarr:
        condition: service_started
      sonarr:
        condition: service_started

networks:
  arr:
    name: arr
    driver: bridge
```

Validate the file:

```bash
docker compose config
```

Start core services:

```bash
docker compose pull
docker compose up -d
docker compose ps
```

Start optional services later one at a time, after reading their section and creating their config:

```bash
docker compose --profile optional up -d bazarr
docker compose --profile optional up -d recyclarr
docker compose --profile optional up -d unpackerr
```

## Phase 7: First Boot Security

### 7.1 Verify PIA VPN, DNS, And Shared Namespace

Use the full validation runbook before adding indexers or real downloads:
[ARR Stack Leak And Kill-Switch Test](arr-stack-leak-and-killswitch-test.md).
The commands below are a quick first-pass check only; the dedicated runbook adds
the live DNS capture, torrent leak-test magnet, live tunnel-drop kill-switch
test, and cold-start failure test.

First confirm qBittorrent is actually running:

```bash
cd /opt/stacks/arr-stack
docker compose ps qbittorrent
docker inspect -f '{{.State.Status}}' qbittorrent
```

Expected status:

```text
running
```

If the status is `exited`, `restarting`, or anything other than `running`, do not run the IP/DNS leak tests yet. Read the logs and fix the startup problem first:

```bash
docker logs --tail 200 qbittorrent
docker compose logs --tail 200 qbittorrent
```

If the status is `created` and logs are empty, Docker created the container but never got it running. That usually means the failure is at the Docker/Compose start layer, before qBittorrent itself can write logs. Surface the real error with:

```bash
cd /opt/stacks/arr-stack
docker compose up qbittorrent
```

Or with Docker directly:

```bash
docker start qbittorrent
docker inspect -f '{{.State.Status}} {{.State.Error}}' qbittorrent
```

Common `created`-with-empty-logs causes are invalid Compose syntax that still created an old container, a port already in use, a missing mount path, a missing Docker capability/device needed for VPN startup, or starting the stack from Dockge/Compose without pressing start/up.

Common first-boot causes are wrong PIA username/password, an invalid `PIA_REGION`, DNS failure during PIA bootstrap, missing `NET_ADMIN`, or the qBittorrent config path not being writable by `mediauser`.

```bash
docker logs --tail 150 qbittorrent
docker exec qbittorrent curl -4 -s https://ifconfig.me
docker exec qbittorrent sh -c 'curl -6 -s --max-time 10 https://ifconfig.me && echo "IPv6 LEAK: investigate" || echo "IPv6 blocked as expected"'
```

The IPv4 address must be a PIA/VPN address, not your home WAN address. The IPv6 test is only valid when the container status is `running`; if `docker exec` says the container is not running, that is a startup failure, not a successful IPv6 block. When the container is running, the IPv6 test should fail because the compose disables IPv6 inside the VPN namespace. That is intentional; unhandled IPv6 is a common leak path.

Confirm the VPN-routed apps use PIA for IPv4:

```bash
docker exec qbittorrent curl -4 -s https://ifconfig.me
docker exec prowlarr curl -4 -s https://ifconfig.me
docker exec radarr curl -4 -s https://ifconfig.me
docker exec sonarr curl -4 -s https://ifconfig.me
```

Pass criteria:

- Every result must be a PIA/VPN public IP, not your home WAN IP.
- The IPs do not have to be identical. PIA can NAT/load-balance separate HTTPS requests through different exit IPs in the same region or provider network.
- If any result shows your home WAN IP, stop. That app is not protected by the VPN path.
- If any command says the container is not running, fix container startup before testing privacy.

Confirm IPv6 is blocked for all VPN-routed apps:

```bash
docker exec qbittorrent sh -c 'curl -6 -s --max-time 10 https://ifconfig.me && echo "IPv6 LEAK: investigate" || echo "IPv6 blocked as expected"'
docker exec prowlarr sh -c 'curl -6 -s --max-time 10 https://ifconfig.me && echo "IPv6 LEAK: investigate" || echo "IPv6 blocked as expected"'
docker exec radarr sh -c 'curl -6 -s --max-time 10 https://ifconfig.me && echo "IPv6 LEAK: investigate" || echo "IPv6 blocked as expected"'
docker exec sonarr sh -c 'curl -6 -s --max-time 10 https://ifconfig.me && echo "IPv6 LEAK: investigate" || echo "IPv6 blocked as expected"'
```

Pass criteria: every command prints `IPv6 blocked as expected`. DNS may still return IPv6 records, but IPv6 connections must fail.

Check the generated PIA files:

```bash
sudo -u mediauser test -r /mnt/main/appdata/arr-stack/qbittorrent/wireguard/wg0.conf && echo "wg0.conf exists"
sudo -u mediauser ls -la /mnt/main/appdata/arr-stack/qbittorrent/wireguard
```

Check for obvious DNS mistakes:

```bash
docker exec qbittorrent cat /etc/resolv.conf
docker exec qbittorrent getent hosts privateinternetaccess.com
docker exec prowlarr getent hosts example.com
```

Pass criteria:

- `/etc/resolv.conf` inside qBittorrent should show the resolver created by the VPN namespace. In this setup, `nameserver 127.0.0.1` is good because the container is using its internal resolver/Unbound path.
- It should not show your router, such as `192.168.1.1`.
- It should not show ISP DNS servers.
- `getent hosts privateinternetaccess.com` and `getent hosts example.com` should return records. Returning IPv6 records is not automatically a leak; the IPv6 curl tests above decide whether IPv6 can actually connect.

Run a live plaintext DNS leak watch on the Docker VM while you open Prowlarr and test an indexer:

```bash
sudo tcpdump -ni any '(udp port 53 or tcp port 53) and not host 127.0.0.1'
```

Use a second terminal for this. Leave it running, then in your browser open Prowlarr and test one indexer. You can stop `tcpdump` with `Ctrl+C`.

Pass criteria while testing Prowlarr/Radarr/Sonarr/qBittorrent:

- No plaintext DNS packets from the ARR stack to your router, ISP DNS, or public DNS.
- Seeing encrypted WireGuard traffic to the PIA endpoint is normal.
- Seeing unrelated DNS from the Docker host or unrelated containers is not an ARR leak, but you should identify it before assuming the whole VM is private.
- If you see DNS packets to `192.168.1.1`, your ISP router, or known public resolvers while the only thing you are testing is Prowlarr/Radarr/Sonarr/qBittorrent, stop and investigate.

Also test with a torrent leak-test magnet from a reputable leak-test site such as `ipleak.net`. Do not use real downloads for this first test.

Pass criteria:

- The torrent leak test reports a PIA/VPN IP, not your home WAN IP.
- The reported IP may differ from `curl https://ifconfig.me` because PIA can use different exit IPs for web and torrent traffic.
- If the leak test reports your home WAN IP, stop. Do not add real downloads.

### 7.2 Verify The Kill Switch

Use the full kill-switch procedure in
[ARR Stack Leak And Kill-Switch Test](arr-stack-leak-and-killswitch-test.md).
The quick test below is useful, but it does not replace the live `wg0` tunnel
drop and DNS watch in the dedicated runbook.

Do this before adding indexers or downloads:

```bash
docker exec qbittorrent wg show
docker exec qbittorrent ip route
```

Then temporarily break the PIA login or region, recreate the stack, and confirm the VPN-routed services cannot reach the internet. This test intentionally interrupts qBittorrent, Prowlarr, Radarr, and Sonarr:

```bash
cd /opt/stacks/arr-stack
cp -a .env .env.before-killswitch-test
nano .env
docker compose up -d
docker exec qbittorrent curl -4 -s --max-time 10 https://ifconfig.me || echo "blocked as expected"
docker exec prowlarr curl -4 -s --max-time 10 https://ifconfig.me || echo "blocked as expected"
cp -a .env.before-killswitch-test .env
docker compose up -d
```

For the temporary edit, change `PIA_PASS` to a deliberately wrong value, or set `PIA_REGION` to an invalid value such as `definitely-invalid-region`.

Pass criteria:

- qBittorrent may fail to start, restart, or report blocked connectivity.
- Prowlarr should also fail or be blocked because it shares qBittorrent's VPN namespace.
- Neither command should ever return your home WAN IP.
- After restoring `.env`, `docker compose up -d` should return the stack to normal PIA-routed operation.

If the container falls back to the home WAN, stop and replace this design with Gluetun or another VPN gateway before using the stack.

### 7.3 Change qBittorrent Password

Open from the LAN:

```text
http://192.168.1.20:8080
```

For remote access before the Docker VM has Tailscale, use a Proxmox-based SSH tunnel or Proxmox console workflow. Direct Tailnet URLs only work if the Docker VM is later added to Tailscale or reachable through an approved subnet route.

If qBittorrent shows an initial generated password, read it from logs:

```bash
docker logs qbittorrent
```

Then set a strong permanent password.

### 7.4 Enable App Authentication

Enable authentication before adding indexers:

- Prowlarr
- Radarr
- Sonarr
- Jellyfin
- Seerr
- Bazarr, if enabled

Do not leave any management UI unauthenticated, even on LAN.

## Phase 8: Configure qBittorrent

For detailed click-by-click setup of qBittorrent, Radarr, Sonarr, Prowlarr, Jellyfin, Seerr, and local end-to-end testing, use the companion guide: [ARR Stack App Configuration Guide](arr-stack-app-configuration-guide.md).

In qBittorrent:

| Setting | Value |
|---|---|
| Incomplete downloads | `/data/torrents/incomplete` |
| Default save path | `/data/torrents` |
| Movie category | `movies` -> `/data/torrents/movies` |
| TV category | `tv` -> `/data/torrents/tv` |

Set upload/seeding limits according to your needs and VPN provider rules.

## Phase 9: Configure Radarr, Sonarr, Prowlarr

### 9.1 Radarr

Root folder:

```text
/data/media/movies
```

Download client:

| Setting | Value |
|---|---|
| Type | qBittorrent |
| Host | `127.0.0.1` |
| Port | `8080` |
| Category | `movies` |

No remote path mapping should be needed because Radarr and qBittorrent both see `/data`. Use `127.0.0.1` because Radarr shares qBittorrent's VPN network namespace.

### 9.2 Sonarr

Root folder:

```text
/data/media/tv
```

Download client:

| Setting | Value |
|---|---|
| Type | qBittorrent |
| Host | `127.0.0.1` |
| Port | `8080` |
| Category | `tv` |

### 9.3 Prowlarr

Add apps:

| App | Prowlarr URL to app |
|---|---|
| Radarr | `http://127.0.0.1:7878` |
| Sonarr | `http://127.0.0.1:8989` |

Use API keys from each app.

Add FlareSolverr only for indexers that require it:

```text
http://127.0.0.1:8191
```

## Phase 10: Configure Jellyfin And Seerr

### 10.1 Jellyfin

Libraries:

| Library | Path |
|---|---|
| Movies | `/media/movies` |
| TV Shows | `/media/tv` |
| Music | `/media/music` |

Hardware transcoding:

```bash
ls -l /dev/dri
docker exec jellyfin ls -l /dev/dri
```

If `/dev/dri` is unavailable in the Docker VM, do not enable hardware transcoding yet. You may need Proxmox iGPU passthrough to VM 111.

### 10.2 Seerr

Connect:

| Service | URL |
|---|---|
| Jellyfin | `http://jellyfin:8096` |
| Radarr | `http://192.168.1.20:7878` |
| Sonarr | `http://192.168.1.20:8989` |

Use API keys from each app. Seerr is not in the VPN namespace, so it reaches Radarr and Sonarr through the Docker VM's LAN-published ports.

## Phase 11: Test Locally End To End

Run checks:

```bash
cd /opt/stacks/arr-stack
docker compose ps
df -h /mnt/main /mnt/media/data
docker exec radarr ls -la /data/media/movies
docker exec sonarr ls -la /data/media/tv
docker exec qbittorrent ls -la /data/torrents
docker exec qbittorrent curl -4 -s https://ifconfig.me
docker exec prowlarr curl -4 -s https://ifconfig.me
docker exec radarr curl -4 -s https://ifconfig.me
docker exec sonarr curl -4 -s https://ifconfig.me
```

The four public IP checks should match each other and should be a PIA/VPN IP.

Test with one legal/public-domain item:

1. Add it in Radarr/Sonarr.
2. Confirm qBittorrent downloads under `/data/torrents/...`.
3. Confirm Radarr/Sonarr imports into `/data/media/...`.
4. Confirm Jellyfin scans it.
5. Confirm playback works locally.
6. Confirm the intended remote path works: Proxmox over Tailscale for shell access, an SSH tunnel/subnet route for browser access, or direct Docker VM Tailscale only if installed later.

## Phase 12: Optional Enhancements

### Bazarr

Use if you care about subtitles. Keep it LAN-only for now, with Tailscale access only through the deliberate remote path you selected.

Start:

```bash
docker compose --profile optional up -d bazarr
```

Connect Bazarr to:

```text
Radarr: http://127.0.0.1:7878
Sonarr: http://127.0.0.1:8989
```

### Recyclarr

Use after you understand Radarr/Sonarr basics. It can sync TRaSH quality profiles and custom formats, but it is easier to troubleshoot after your base stack works.

First run should be preview/dry-run style:

```bash
docker compose --profile optional up -d recyclarr
docker exec recyclarr recyclarr sync --preview
```

### Unpackerr

Use if your indexers frequently provide archived releases. It monitors Radarr/Sonarr activity and extracts downloads.

Start only if needed:

```bash
docker compose --profile optional up -d unpackerr
```

### Gluetun Alternative

Gluetun is a strong general VPN gateway and is useful if multiple download clients need VPN routing. It uses `network_mode: service:gluetun` for dependent containers. For your initial stack, hotio qBittorrent VPN is simpler because it supports PIA WireGuard directly and this guide already routes the ARR search/download services through qBittorrent's VPN namespace.

Use the dedicated migration guide later if you want this architecture:
[ARR Stack Gluetun VPN Gateway Guide](arr-stack-gluetun-vpn-gateway-guide.md).

Choose Gluetun later if:

- you add multiple VPN-routed download clients;
- you need provider-specific Gluetun health behavior;
- you are comfortable moving port mappings onto the Gluetun service.

## Phase 13: Backups

Back up:

```text
/mnt/main/appdata/arr-stack
/opt/stacks/arr-stack/compose.yaml
/opt/stacks/arr-stack/.env
```

Snapshot:

- `/mnt/main/appdata`
- optionally `/mnt/media/data`

Do not rely on media re-downloads as a backup for service databases. Radarr/Sonarr databases are the automation state.

## Phase 14: Manual Updates

Do not use Watchtower auto-updates initially.

Manual update:

```bash
cd /opt/stacks/arr-stack
docker compose pull
docker compose up -d
docker compose ps
```

Rollback strategy:

1. Snapshot appdata before big updates.
2. Pull/update.
3. Test UIs and imports.
4. Roll back appdata snapshot if a migration breaks.

## Phase 15: Internet Exposure Comes Last

The secure default is no public exposure. Tailscale already gives you remote management through Proxmox, and you can add direct Docker VM Tailscale later if needed.

If you later want public access:

### Recommended Public Services

| Service | Public? | Notes |
|---|---:|---|
| Jellyfin | Optional | Use strong Jellyfin accounts. Consider Cloudflare Access only if clients support it. |
| Seerr | Optional | Put behind Cloudflare Access or Authelia. |
| Radarr | No | Private remote path only: Proxmox tunnel/subnet route/direct Docker VM Tailscale if added later. |
| Sonarr | No | Private remote path only: Proxmox tunnel/subnet route/direct Docker VM Tailscale if added later. |
| Prowlarr | No | Private remote path only: Proxmox tunnel/subnet route/direct Docker VM Tailscale if added later. |
| qBittorrent | No | Never public. |
| Dockge | No | Never public. |
| TrueNAS | No | Never public. |
| Proxmox | No | Never public. |

### Safer Internet Path

1. Keep router port forwards disabled.
2. Run Cloudflare Tunnel on the Docker VM, not TrueNAS.
3. Route only public hostnames to selected services.
4. Add Cloudflare Access for Seerr.
5. Keep management UIs private-only: LAN, Proxmox tunnel, approved subnet route, or direct Docker VM Tailscale if added later.
6. Add rate limits/security headers if using Traefik.
7. Test externally from a phone on cellular.

### Router Port Forwarding

Avoid it. If you must use router forwarding later, expose only `80/443` to a reverse proxy on the Docker VM. Never forward raw ARR service ports.

## Final Checklist

- [ ] Hermes at `10.10.100.2` cannot reach LAN services.
- [ ] TrueNAS is storage only.
- [ ] Docker VM is the only app host.
- [ ] Tailscale works for remote management.
- [ ] TrueNAS `mediauser` exists.
- [ ] Docker VM `mediauser` has matching UID/GID.
- [ ] NFS exports are restricted to Docker VM IP.
- [ ] `/mnt/main/appdata` and `/mnt/media/data` mount on Docker VM.
- [ ] `/mnt/main/appdata/arr-stack` and `/mnt/media/data` structure exists.
- [ ] Docker VM UFW allows only LAN sources, plus Tailscale sources only if Tailscale is installed on the Docker VM or routed intentionally.
- [ ] Docker VM host DNS is not using router/ISP plaintext DNS.
- [ ] Dockge is LAN-only, or reachable remotely only through the deliberate private remote path.
- [ ] `.env` contains the correct PIA `p...` username, password, and optional non-US region for port forwarding.
- [ ] ARR compose validates with `docker compose config`.
- [ ] qBittorrent, Prowlarr, Radarr, and Sonarr all show the same PIA/VPN public IPv4 before downloads.
- [ ] IPv6 is blocked inside the qBittorrent VPN namespace.
- [ ] Plaintext DNS leak watch shows no ARR search/download DNS leaving to router, ISP DNS, or public DNS.
- [ ] qBittorrent torrent leak test reports the PIA/VPN IP, not the home WAN IP.
- [ ] VPN kill-switch test blocks qBittorrent and Prowlarr when PIA auth/region is broken.
- [ ] App authentication is enabled everywhere.
- [ ] End-to-end local test succeeds.
- [ ] Remote management test succeeds through Proxmox over Tailscale, an SSH tunnel/subnet route, or direct Docker VM Tailscale if added later.
- [ ] Appdata backup is configured.
- [ ] Public exposure is deferred until the local setup is stable.
