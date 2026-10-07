# ARR Stack Setup And Testing

Consolidated setup, configuration, VPN gateway migration, and leak/kill-switch testing for the ARR stack (Prowlarr, Radarr, Sonarr, qBittorrent, Jellyfin, Seerr). For architecture and current configuration, see [ARR Stack](../../services/arr-stack.md).

Assumptions: Proxmox and TrueNAS storage are already set up; Tailscale reaches Proxmox for remote management; the Docker VM is `192.168.1.20`; Hermes is isolated at `10.10.100.2`.

## Phase 0: Confirm Prerequisites

Record before continuing:

```text
TrueNAS IP:
Docker VM IP:
Docker VM username:
TrueNAS pool names:
Tailscale device name for Proxmox:
VPN provider:
```

### Verify Hermes Isolation

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

If Hermes can reach TrueNAS or the Docker VM, fix the Proxmox `vmbr1` firewall/NAT rules before proceeding.

## Phase 1: TrueNAS Storage

1. Under `Credentials -> Local Users`, add a dedicated `mediauser` (and group), record its UID/GID (example: `3000:3000`).
2. Create datasets `/mnt/main`, `/mnt/main/appdata`, `/mnt/media`. Under `/mnt/media`, create **directories** (not child datasets) for `data/torrents/{incomplete,movies,tv}`, `data/usenet/{incomplete,movies,tv}`, `data/media/{movies,tv,music}` — hardlinks cannot cross datasets, so downloads and final media must share one dataset.
3. Set owner/group to `mediauser:mediauser` on `/mnt/main/appdata` and `/mnt/media/data`.
4. Create NFS exports restricted to the Docker VM IP (`192.168.1.20/32`):
   - `/mnt/main/appdata`
   - `/mnt/media/data` (or `/mnt/main/media/data` if using a single pool; the Docker VM still mounts it at `/mnt/media/data`)
5. Use NFSv4, map all access to `mediauser:mediauser` via Mapall if offered, enable NFS autostart, and restart/reload NFS after changes.
6. Optional SMB share of `/mnt/media/data` for desktop browsing only, logged in as `mediauser` — never as TrueNAS admin/root.

## Phase 2: Docker VM Foundation

### Create Matching Media User

```bash
sudo groupadd -g 3000 mediauser
sudo useradd -u 3000 -g 3000 -M -s /usr/sbin/nologin mediauser
id mediauser
```

Matching UIDs/GIDs between TrueNAS and the Docker VM avoids permission confusion, since containers write using numeric IDs.

### Install Tools And Mount Storage

```bash
sudo apt update
sudo apt install -y nfs-common ufw curl ca-certificates
sudo mkdir -p /mnt/main/appdata /mnt/media/data
```

Add to `/etc/fstab` (adjust if using the single-pool fallback):

```fstab
192.168.1.10:/mnt/main/appdata /mnt/main/appdata nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
192.168.1.10:/mnt/main/media/data /mnt/media/data nfs4 rw,hard,noatime,_netdev,x-systemd.automount,nfsvers=4.2,rsize=1048576,wsize=1048576 0 0
```

Apply and verify:

```bash
sudo systemctl daemon-reload
sudo mount -a
df -h | grep /mnt
sudo -u mediauser touch /mnt/main/appdata/.docker-vm-write-test && sudo -u mediauser rm /mnt/main/appdata/.docker-vm-write-test
sudo -u mediauser touch /mnt/media/data/.docker-vm-write-test && sudo -u mediauser rm /mnt/media/data/.docker-vm-write-test
```

If the write test fails, fix TrueNAS permissions/NFS mapping before continuing.

### Create Directories As `mediauser`

Always create NFS-backed directories as `mediauser`, not `sudo mkdir`/`chown`/`chmod` — many NFS exports squash or restrict root, so `sudo` operations can fail even when the container-facing permissions are correct:

```bash
sudo -u mediauser mkdir -p \
  /mnt/main/appdata/arr-stack/{prowlarr,radarr,sonarr,seerr,jellyfin,qbittorrent/wireguard,flaresolverr,bazarr,recyclarr,unpackerr}

sudo -u mediauser mkdir -p \
  /mnt/media/data/torrents/{incomplete,movies,tv} \
  /mnt/media/data/usenet/{incomplete,movies,tv} \
  /mnt/media/data/media/{movies,tv,music}
```

**Troubleshooting permission-denied on directory creation or Docker bind mounts:**

| Symptom | Likely cause | Fix |
|---|---|---|
| `sudo -u mediauser mkdir -p ...` returns `Permission denied` | TrueNAS dataset ACL/Mapall settings are wrong | Fix in the TrueNAS UI, restart NFS, remount, retry |
| `mediauser mkdir` works, `sudo ls -ld` as root fails | NFS squashes client root to `nobody` | In TrueNAS, set the export's `Maproot User`/`Maproot Group` (and `Mapall` if dedicated) to `mediauser`, restart NFS, remount |
| Docker error `mkdir ... permission denied` while starting a container | Docker (running as root) tried to auto-create a missing bind-mount source directory | Pre-create the directory as `mediauser` first, then retry `docker compose up` |
| A specific child directory (e.g. `media/movies`) denies access even though the parent is writable | Stale ACL on that child path | Fix the ACL recursively on the TrueNAS dataset, restart NFS, remount |

Never run `sudo chown -R` against these NFS paths from the Docker VM — ownership/ACL fixes belong on the TrueNAS side.

### Firewall: LAN First

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

Add `100.64.0.0/10` rules for the same ports only if Tailscale is later installed directly on the Docker VM or a subnet router preserving source IPs is configured.

### Harden Docker VM DNS Before VPN Bootstrap

The VPN container needs normal internet access before its tunnel exists, so bootstrap DNS lookups can otherwise go out in plaintext via the router/ISP resolver. Harden host DNS first:

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo nano /etc/systemd/resolved.conf.d/secure-dns.conf
```

```ini
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net
FallbackDNS=
DNSOverTLS=yes
Domains=~.
```

```bash
sudo systemctl restart systemd-resolved
resolvectl status
```

Revert (`sudo rm /etc/systemd/resolved.conf.d/secure-dns.conf && sudo systemctl restart systemd-resolved`) if this breaks DNS on your Ubuntu version.

### Check Tailscale / Remote Access

```bash
tailscale status
tailscale ip -4
```

If not installed on the Docker VM, use Tailscale-to-Proxmox-then-console/SSH, or an SSH tunnel through Proxmox, for remote management; LAN UFW rules are sufficient for those paths. Avoid Tailscale Funnel for ARR management UIs, and advertise only the subnet actually needed if using a subnet router.

### Optional: Dockge

```bash
sudo mkdir -p /opt/dockge /opt/stacks
sudo chown -R "$USER":"$USER" /opt/dockge /opt/stacks
cd /opt/dockge
```

`compose.yaml`:

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

```bash
docker compose up -d
```

Open `http://192.168.1.20:5001`, set a strong password, and never expose it through a public tunnel.

## Phase 3: Create The ARR Stack (hotio VPN Variant)

```bash
mkdir -p /opt/stacks/arr-stack
cd /opt/stacks/arr-stack
```

### `.env`

```bash
TZ=Europe/Berlin
DOCKER_IP=192.168.1.20
LAN=192.168.1.0/24
PUID=3000
PGID=3000
CONFIG_PATH=/mnt/main/appdata/arr-stack
DATA_PATH=/mnt/media/data
QBITTORRENT_VERSION=release-5.1.2
PIA_USER=p1234567
PIA_PASS=replace_with_your_pia_password
PIA_REGION=
PIA_PORT_FORWARD=true
```

```bash
chmod 600 .env
```

PIA usernames start with `p`; never use the account email. Avoid `$`, `#`, quotes, and spaces in `PIA_PASS`. Create the WireGuard config directory so the container can write into it:

```bash
sudo -u mediauser mkdir -p /mnt/main/appdata/arr-stack/qbittorrent/wireguard
sudo -u mediauser test -w /mnt/main/appdata/arr-stack/qbittorrent/wireguard
```

Let hotio's PIA mode (`VPN_PROVIDER=pia`) generate `wg0.conf` on first boot — do not paste a manually-downloaded PIA config.

### `compose.yaml`

Core services (qBittorrent owns the VPN; Prowlarr/Radarr/Sonarr/FlareSolverr/Bazarr/Recyclarr/Unpackerr use `network_mode: "service:qbittorrent"` and reach each other over `127.0.0.1`; Jellyfin/Seerr stay on the normal `arr` bridge):

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

networks:
  arr:
    name: arr
    driver: bridge
```

Optional services (`bazarr`, `recyclarr`, `unpackerr`) use `profiles: [optional]` and the same `network_mode: "service:qbittorrent"` pattern; add them only after the core stack passes the leak/kill-switch test.

Validate and start:

```bash
docker compose config
docker compose pull
docker compose up -d
docker compose ps
```

Start optional services individually after reading their config requirements:

```bash
docker compose --profile optional up -d bazarr
docker compose --profile optional up -d recyclarr
docker compose --profile optional up -d unpackerr
```

### First-Boot Troubleshooting

If `wg0.conf` is not created or qBittorrent fails to start, check logs first:

```bash
docker logs --tail 200 qbittorrent
```

Common causes: `PIA_USER` set to an email instead of `p...`; special characters in `PIA_PASS` mis-parsed; DNS failure during PIA bootstrap; the qBittorrent config path not writable by `mediauser`; invalid `PIA_REGION`.

If status is `created` with empty logs, the failure is at the Docker/Compose layer (port conflict, missing mount, missing capability) — run `docker compose up qbittorrent` in the foreground to surface the real error.

Do not proceed to indexers/downloads until the full leak and kill-switch test (below) passes.

## Phase 4: Configure The Apps

### qBittorrent

Open `http://192.168.1.20:8080`, sign in, then under `Tools -> Options -> Web UI` set a strong permanent password (replace any generated/temporary value).

Under `Tools -> Options -> Downloads`:

- Incomplete downloads: `/data/torrents/incomplete`
- Default save path: `/data/torrents`

Create categories:

| Category | Save path |
|---|---|
| `movies` | `/data/torrents/movies` |
| `tv` | `/data/torrents/tv` |

These names must exactly match the Radarr/Sonarr download-client category settings. Set queueing/seeding limits appropriate to storage, connection, and VPN provider rules (starting point: 3 active downloads, 3 active uploads, 8 active torrents total).

Verify container visibility of the paths:

```bash
docker exec qbittorrent ls -la /data /data/torrents /data/torrents/incomplete /data/torrents/movies /data/torrents/tv
```

### Radarr

Open `http://192.168.1.20:7878`.

1. `Settings -> General`: enable authentication.
2. `Settings -> Media Management -> Advanced Settings`: enable `Use Hardlinks instead of Copy`.
3. `Movies -> Add New/Library Import`: add root folder `/data/media/movies` (not the host path, not Jellyfin's `/media/movies`).
4. `Settings -> Download Clients -> Add -> qBittorrent`: Host `127.0.0.1`, Port `8080`, qBittorrent username/password, Category `movies`. Test, then Save.

No remote path mapping is needed — Radarr and qBittorrent both see `/data`.

### Sonarr

Open `http://192.168.1.20:8989`. Same steps as Radarr, with root folder `/data/media/tv` and download-client category `tv`.

### Prowlarr

Open `http://192.168.1.20:9696`.

1. `Settings -> General`: enable authentication.
2. Copy the API key from Radarr and Sonarr (`Settings -> General`).
3. `Settings -> Apps -> Add Application -> Radarr`: Prowlarr Server `http://127.0.0.1:9696`, Radarr Server `http://127.0.0.1:7878`, Sync Level `Full Sync`, paste the API key. Test, Save.
4. Repeat for Sonarr (`http://127.0.0.1:8989`).
5. `Indexers -> Add Indexer`: add only indexers you are legally allowed to use; test and save only working ones.
6. Add FlareSolverr (`http://127.0.0.1:8191`) only for the specific indexers that require it — not globally.

### Jellyfin

Open `http://192.168.1.20:8096`, complete the first-run wizard (create admin user, skip remote access for now).

Add libraries:

| Content type | Display name | Folder |
|---|---|---|
| Movies | Movies | `/media/movies` |
| Shows | TV Shows | `/media/tv` |
| Music | Music | `/media/music` |

Run `Scan All Libraries`. Verify container access:

```bash
docker exec jellyfin ls -la /media /media/movies /media/tv /media/music
```

Check hardware transcoding support before enabling it:

```bash
ls -l /dev/dri
docker exec jellyfin ls -l /dev/dri
```

If `/dev/dri` is missing on the host or in the container, leave hardware transcoding disabled and use direct play; revisit Proxmox iGPU passthrough later. For the tested Intel iGPU passthrough path, see the dedicated Jellyfin iGPU guide.

### Seerr

Open `http://192.168.1.20:5055`, complete first-run setup choosing Jellyfin as the media server.

| Setting | Value |
|---|---|
| Jellyfin Server URL | `http://jellyfin:8096` (fall back to `http://192.168.1.20:8096` if the service name doesn't resolve/test) |
| Radarr Server URL | `http://192.168.1.20:7878` |
| Sonarr Server URL | `http://192.168.1.20:8989` |
| Radarr/Sonarr root folders | `/data/media/movies`, `/data/media/tv` |

Do not use `127.0.0.1` for Radarr/Sonarr from Seerr — Seerr is not in the VPN namespace, so `127.0.0.1` means Seerr itself. Recommended request defaults: auto-approve admin requests on, auto-approve normal users off until proven, 4K off unless separate profiles/storage exist.

### Enable Authentication Everywhere

Before adding indexers, confirm authentication is enabled on Prowlarr, Radarr, Sonarr, Jellyfin, Seerr, and Bazarr (if enabled) — even though these are LAN-only.

## Phase 5: End-To-End Local Test

```bash
cd /opt/stacks/arr-stack
docker compose ps
df -h /mnt/main /mnt/media/data
docker exec radarr ls -la /data/media/movies
docker exec sonarr ls -la /data/media/tv
docker exec qbittorrent ls -la /data/torrents
docker exec jellyfin ls -la /media/movies /media/tv
```

Check VPN egress (all four should return the same VPN-provider public IP, never the home WAN IP):

```bash
docker exec qbittorrent curl -4 -s https://ifconfig.me
docker exec prowlarr curl -4 -s https://ifconfig.me
docker exec radarr curl -4 -s https://ifconfig.me
docker exec sonarr curl -4 -s https://ifconfig.me
```

Add one legal/public-domain movie in Radarr and one legal/public-domain show in Sonarr; confirm the torrent appears in qBittorrent under the correct category/path, confirm the file imports into `/data/media/...`, run `Scan All Libraries` in Jellyfin, and play it from a LAN client. Then test a Seerr request end to end and confirm it reaches Radarr/Sonarr with the right root folder and category.

Test the chosen remote-management path (Proxmox over Tailscale, SSH tunnel, or subnet route) before considering the stack done.

## Leak And Kill-Switch Testing (hotio VPN)

Run this before adding indexers, real downloads, or debrid automation. It is the strict pass/fail gate for the hotio qBittorrent VPN design.

Scope — protected: qBittorrent, Prowlarr, Radarr, Sonarr, FlareSolverr, and any enabled Bazarr/Recyclarr/Unpackerr/RDTClient. Not protected (by design): Jellyfin, Seerr, Dockge — they use normal Docker networking.

Safety rules: no real downloads during this runbook, only a leak-test magnet; run on the Docker VM, not TrueNAS; stop immediately if any protected service returns the home WAN IP or the DNS watch shows leakage; keep any `.env` backup until the stack is restored.

### Variables And Clean Rerun

```bash
cd /opt/stacks/arr-stack
ARR_VPN_SERVICES="qbittorrent prowlarr radarr sonarr flaresolverr"
# ARR_VPN_SERVICES="$ARR_VPN_SERVICES bazarr recyclarr unpackerr rdt-client"

HOME_WAN_IP="$(curl -4 -fsS --max-time 15 https://ifconfig.me)"
printf 'Home WAN IPv4: %s\n' "$HOME_WAN_IP"
```

If rerunning after a failed region/password test, start qBittorrent alone, wait for `wg0`, verify its IP, then start dependents:

```bash
docker compose stop qbittorrent prowlarr radarr sonarr flaresolverr
docker compose up -d qbittorrent

for i in $(seq 1 60); do
  docker exec qbittorrent sh -lc 'ip link show wg0 >/dev/null 2>&1' && { echo "wg0 is present"; break; }
  echo "waiting for wg0..."; sleep 2
done

docker exec qbittorrent wg show
docker exec qbittorrent curl -4 -fsS --max-time 15 https://ifconfig.me
docker compose up -d
```

### Phase 1 — Compose And Namespace Check

```bash
docker compose config | sed -n '/qbittorrent:/,/^[[:space:]]*[a-zA-Z0-9_-]*:/p'
docker compose config | grep -A4 -E '^[[:space:]]+(prowlarr|radarr|sonarr|flaresolverr|bazarr|recyclarr|unpackerr|rdt-client):'
docker compose ps
```

Pass: `VPN_ENABLED=true`, `VPN_PROVIDER=pia`, `VPN_NAMESERVERS=wg`, `VPN_LAN_LEAK_ENABLED=false`, `NET_ADMIN` present on qBittorrent; all protected services use `network_mode: service:qbittorrent`.

### Phase 2 — Baseline VPN Health

```bash
docker logs --tail 150 qbittorrent
docker exec qbittorrent wg show
docker exec qbittorrent ip route
docker exec qbittorrent ip addr show wg0
```

Pass: `wg0` present with a recent handshake; no default route that bypasses the VPN.

### Phase 3 — Public IPv4 Leak Test

```bash
for service in $ARR_VPN_SERVICES; do
  docker inspect "$service" >/dev/null 2>&1 && {
    printf '\n[%s] public IPv4: ' "$service"
    docker exec "$service" sh -lc 'curl -4 -fsS --max-time 15 https://ifconfig.me || curl -4 -fsS --max-time 15 https://api.ipify.org' || echo "FAILED"
  }
done
```

Pass: every result is a VPN-provider IPv4; none equal `$HOME_WAN_IP`. IPs may differ between services (the provider can use different exit IPs per request).

### Phase 4 — IPv6 Leak Test

```bash
for service in $ARR_VPN_SERVICES; do
  docker inspect "$service" >/dev/null 2>&1 && {
    printf '\n[%s] IPv6: ' "$service"
    docker exec "$service" sh -lc 'curl -6 -fsS --max-time 10 https://ifconfig.me && echo "IPv6 LEAK: investigate" || echo "IPv6 blocked as expected"'
  }
done
```

Pass: every service prints `IPv6 blocked as expected`.

### Phase 5 — Resolver Check

```bash
docker exec qbittorrent cat /etc/resolv.conf
for service in $ARR_VPN_SERVICES; do
  docker inspect "$service" >/dev/null 2>&1 && {
    printf '\n[%s] resolver lookup:\n' "$service"
    docker exec "$service" sh -lc 'getent hosts example.com; getent hosts privateinternetaccess.com' || echo "FAILED"
  }
done
```

Pass: resolver is the VPN namespace's own resolver (`nameserver 127.0.0.1` is normal with `VPN_NAMESERVERS=wg`), never the router or ISP DNS; lookups succeed while the VPN is healthy.

### Phase 6 — Live Plaintext DNS Leak Watch

Terminal 1:

```bash
QB_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' qbittorrent)"
sudo tcpdump -l -nn -vv -ni any "host $QB_IP and (udp port 53 or tcp port 53 or tcp port 853)"
```

Terminal 2 — trigger DNS activity and test one indexer in Prowlarr in the browser:

```bash
for service in $ARR_VPN_SERVICES; do
  docker inspect "$service" >/dev/null 2>&1 && {
    printf '\n[%s] DNS trigger:\n' "$service"
    docker exec "$service" sh -lc 'getent hosts example.com; getent hosts debian.org; curl -4 -fsS --max-time 15 https://example.com >/dev/null && echo ok' || echo "FAILED"
  }
done
```

Pass: no plaintext DNS or DoT (port 853) packets leave `$QB_IP` outside the tunnel; `0 packets captured` is an acceptable pass if the public-IP checks also show VPN IPs. WireGuard traffic to the VPN endpoint is normal and separate from this DNS-only capture.

### Phase 7 — Torrent Leak Test

Use a leak-test magnet from a reputable site such as `ipleak.net` (never a real torrent). Add it in qBittorrent, wait for the leak-test page to report the client IP, then delete the test torrent/data.

Pass: reported IP is the VPN provider's, not `$HOME_WAN_IP` (it may differ from the HTTPS `ifconfig.me` IP since web and torrent flows can use different exits).

### Phase 8 — Live Tunnel-Drop Kill-Switch Test

Terminal 1 — DNS capture (same command as Phase 6).

Terminal 2 — drop the tunnel and test immediately:

```bash
docker exec qbittorrent sh -lc 'ip link set wg0 down'

KILLSWITCH_DNS_NAME="arr-killswitch-$(date +%s).example.com"
for service in $ARR_VPN_SERVICES; do
  docker inspect "$service" >/dev/null 2>&1 && {
    printf '\n[%s] kill-switch IPv4: ' "$service"
    docker exec "$service" sh -lc 'curl -4 -fsS --max-time 10 https://ifconfig.me && echo "LEAK: investigate" || echo "blocked as expected"'
    printf '[%s] kill-switch DNS trigger: ' "$service"
    docker exec "$service" sh -lc "getent hosts $KILLSWITCH_DNS_NAME >/dev/null 2>&1 && echo \"unexpected DNS answer\" || echo \"lookup failed as expected\""
  }
done
```

Pass: every protected service fails closed or is unreachable; none return the home WAN IP; DNS capture stays quiet after `wg0` is down.

Restore:

```bash
docker compose stop qbittorrent prowlarr radarr sonarr flaresolverr
docker compose up -d qbittorrent

for i in $(seq 1 60); do
  docker exec qbittorrent sh -lc 'ip link show wg0 >/dev/null 2>&1' && { echo "wg0 is present"; break; }
  echo "waiting for wg0..."; sleep 2
done

docker exec qbittorrent wg show
docker exec qbittorrent curl -4 -fsS --max-time 15 https://ifconfig.me
docker compose up -d
```

Do not run the restore `curl` before `wg0` exists — Docker can report "started" before hotio finishes WireGuard/firewall initialization.

### Phase 9 — Cold-Start Kill-Switch Test

Verifies a broken VPN config doesn't fall back to the home WAN on startup.

```bash
cd /opt/stacks/arr-stack
cp -a .env .env.before-killswitch-test
chmod 600 .env.before-killswitch-test
nano .env   # set PIA_PASS=definitely_wrong_for_killswitch_test, or PIA_REGION=definitely-invalid-region
docker compose up -d --force-recreate qbittorrent
docker compose up -d
docker compose ps
docker logs --tail 150 qbittorrent
```

If qBittorrent still starts cleanly with a valid `wg0` handshake, it likely reused an already-generated `wg0.conf` instead of regenerating from the broken values — that does not count as a valid cold-start failure test; restore `.env` and rely on the Phase 8 result instead, or deliberately move the existing WireGuard config aside first.

```bash
for service in $ARR_VPN_SERVICES; do
  docker inspect "$service" >/dev/null 2>&1 && {
    printf '\n[%s] cold-start IPv4: ' "$service"
    docker exec "$service" sh -lc 'curl -4 -fsS --max-time 10 https://ifconfig.me && echo "LEAK: investigate" || echo "blocked as expected"' || echo "blocked as expected"
  }
done
```

Pass: no protected service returns `$HOME_WAN_IP` or reaches the internet through the normal path.

Restore:

```bash
cp -a .env.before-killswitch-test .env
chmod 600 .env
docker compose up -d --force-recreate qbittorrent

for i in $(seq 1 60); do
  docker exec qbittorrent sh -lc 'ip link show wg0 >/dev/null 2>&1' && { echo "wg0 is present"; break; }
  echo "waiting for wg0..."; sleep 2
done

docker exec qbittorrent wg show
docker exec qbittorrent curl -4 -fsS --max-time 15 https://ifconfig.me
docker compose up -d
docker compose ps
rm .env.before-killswitch-test   # only after the stack is confirmed healthy
```

### Final Pass Checklist (hotio VPN)

- [ ] `wg0` active with recent handshake.
- [ ] qBittorrent, Prowlarr, Radarr, Sonarr, FlareSolverr (and enabled optional helpers) return VPN public IPv4 addresses, never the home WAN IP.
- [ ] IPv6 is blocked from every protected service.
- [ ] Resolvers do not point at the router or ISP DNS.
- [ ] Live DNS watch shows no plaintext DNS/DoT leaving the protected namespace.
- [ ] Torrent leak-test magnet reports a VPN IP.
- [ ] Live `wg0` tunnel-drop test blocks internet and DNS.
- [ ] Cold-start broken-credential test does not fall back to the home WAN.
- [ ] Stack restores cleanly after both kill-switch tests.

### Failure Response

If any protected service leaks the home WAN IP: stop the shared-namespace services, do not add indexers or downloads, re-check `network_mode: "service:qbittorrent"` on every protected service, re-check the VPN environment variables (`VPN_ENABLED`, `VPN_PROVIDER`, `VPN_NAMESERVERS`, `VPN_LAN_LEAK_ENABLED`, credentials, region), and re-run from Phase 1.

```bash
docker compose stop qbittorrent prowlarr radarr sonarr flaresolverr
```

If the design falls back to the home WAN when `wg0` is down, do not use this stack for torrenting — migrate to the Gluetun gateway design below and re-run the full test.

## Migrating To A Gluetun VPN Gateway

Use this when the hotio design should be replaced with a dedicated Gluetun gateway. Do not migrate during active troubleshooting — get the hotio stack stable first.

References: [Gluetun connect-a-container](https://github.com/qdm12/gluetun-wiki/blob/main/setup/connect-a-container-to-gluetun.md), [port mapping](https://github.com/qdm12/gluetun-wiki/blob/main/setup/port-mapping.md), [PIA provider page](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/private-internet-access.md), [DNS options](https://github.com/qdm12/gluetun-wiki/blob/main/setup/options/dns.md), [VPN port forwarding](https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md).

Migration rules: never run the hotio VPN and Gluetun simultaneously for the same qBittorrent container; use a non-VPN qBittorrent image under Gluetun; publish UI ports on `gluetun`, not on the containers sharing its namespace; keep all the same LAN-only exposure rules; run the full leak/kill-switch test again after migrating, before adding real downloads.

### Prepare

```bash
cd /opt/stacks/arr-stack
cp -a compose.yaml compose.hotio-vpn.backup.yaml
cp -a .env .env.before-gluetun
sudo -u mediauser mkdir -p /mnt/main/appdata/arr-stack/gluetun
sudo -u mediauser test -w /mnt/main/appdata/arr-stack/gluetun && echo "gluetun appdata writable"
```

Add to `.env`:

```env
GLUETUN_VERSION=latest
QBITTORRENT_VERSION=latest
PIA_USER=p1234567
PIA_PASS=replace_with_your_pia_password
PIA_REGION=Netherlands
PIA_PORT_FORWARDING=on
```

### Compose

```yaml
services:
  gluetun:
    image: qmcgaw/gluetun:${GLUETUN_VERSION}
    container_name: gluetun
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - TZ=${TZ}
      - VPN_SERVICE_PROVIDER=private internet access
      - VPN_TYPE=openvpn
      - OPENVPN_USER=${PIA_USER}
      - OPENVPN_PASSWORD=${PIA_PASS}
      - SERVER_REGIONS=${PIA_REGION}
      - PORT_FORWARD_ONLY=true
      - VPN_PORT_FORWARDING=${PIA_PORT_FORWARDING}
      - VPN_PORT_FORWARDING_PROVIDER=private internet access
      - VPN_PORT_FORWARDING_USERNAME=${PIA_USER}
      - VPN_PORT_FORWARDING_PASSWORD=${PIA_PASS}
      - DNS_UPSTREAM_RESOLVER_TYPE=dot
      - DNS_UPSTREAM_RESOLVERS=cloudflare,quad9
      - DNS_UPSTREAM_IPV6=off
      - BLOCK_MALICIOUS=on
      - BLOCK_SURVEILLANCE=off
      - BLOCK_ADS=off
    volumes:
      - ${CONFIG_PATH}/gluetun:/gluetun
    ports:
      - "${DOCKER_IP}:8080:8080"
      - "${DOCKER_IP}:9696:9696"
      - "${DOCKER_IP}:7878:7878"
      - "${DOCKER_IP}:8989:8989"
      - "${DOCKER_IP}:6767:6767"
    networks:
      - arr
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- --timeout=10 https://ifconfig.me >/dev/null 2>&1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 90s

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:${QBITTORRENT_VERSION}
    container_name: qbittorrent
    restart: unless-stopped
    network_mode: "service:gluetun"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - UMASK=002
      - TZ=${TZ}
      - WEBUI_PORT=8080
    volumes:
      - ${CONFIG_PATH}/qbittorrent:/config
      - ${DATA_PATH}:/data
    depends_on:
      gluetun:
        condition: service_healthy

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    restart: unless-stopped
    network_mode: "service:gluetun"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${CONFIG_PATH}/prowlarr:/config
    depends_on:
      gluetun:
        condition: service_healthy

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    network_mode: "service:gluetun"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${CONFIG_PATH}/radarr:/config
      - ${DATA_PATH}:/data
    depends_on:
      gluetun:
        condition: service_healthy
      prowlarr:
        condition: service_started

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    network_mode: "service:gluetun"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${CONFIG_PATH}/sonarr:/config
      - ${DATA_PATH}:/data
    depends_on:
      gluetun:
        condition: service_healthy
      prowlarr:
        condition: service_started

  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    restart: unless-stopped
    network_mode: "service:gluetun"
    environment:
      - LOG_LEVEL=info
      - LOG_HTML=false
      - CAPTCHA_SOLVER=none
      - TZ=${TZ}
    depends_on:
      gluetun:
        condition: service_healthy

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
      - jellyfin

networks:
  arr:
    name: arr
```

Key differences from the hotio compose: `gluetun` publishes the UI ports; VPN-routed services define no `ports`/`networks` of their own; qBittorrent carries no VPN variables and uses a non-VPN image; Seerr no longer shares a namespace with Radarr/Sonarr, so it must use the LAN-published URLs.

Optional services (Bazarr, Recyclarr, Unpackerr, RDTClient) follow the same `profiles: [optional]` + `network_mode: "service:gluetun"` pattern as the hotio variant; for RDTClient also publish port `6500` on `gluetun`.

### Start Order

```bash
cd /opt/stacks/arr-stack
docker compose down
docker compose config
docker compose up -d gluetun
docker logs -f gluetun
```

Wait for the healthcheck, then in another terminal:

```bash
docker compose ps gluetun
docker exec gluetun wget -qO- --timeout=15 https://ifconfig.me
docker compose up -d qbittorrent prowlarr radarr sonarr flaresolverr
docker compose up -d jellyfin seerr
```

### qBittorrent Port Forwarding (Optional)

```bash
docker exec gluetun sh -lc 'cat /tmp/gluetun/forwarded_port 2>/dev/null || true'
docker logs gluetun | grep -i port
```

If no forwarded port appears, confirm `PIA_PORT_FORWARDING=on`, `PORT_FORWARD_ONLY=true`, and that the chosen PIA region supports port forwarding.

### Gluetun Leak And Kill-Switch Test

Same structure as the hotio test, substituting the Gluetun service list:

```bash
cd /opt/stacks/arr-stack
ARR_VPN_SERVICES="gluetun qbittorrent prowlarr radarr sonarr flaresolverr"
HOME_WAN_IP="$(curl -4 -fsS --max-time 15 https://ifconfig.me)"
```

**Gluetun health:**

```bash
docker compose ps gluetun
docker logs --tail 200 gluetun
docker exec gluetun ip route
docker exec gluetun wget -qO- --timeout=15 https://ifconfig.me
```

**Protected-service IPv4 / IPv6 / resolver / live DNS watch**: identical commands and pass criteria to Phases 2-5 of the hotio test above, run against `$ARR_VPN_SERVICES` and `gluetun`'s own Docker IP (`docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' gluetun`) instead of qBittorrent's.

**Torrent leak test**: same as hotio — use a leak-test magnet, confirm a VPN IP, never the home WAN IP.

**Kill-switch test** — stop Gluetun directly instead of dropping an interface inside the namespace:

```bash
GLUETUN_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' gluetun)"
sudo tcpdump -l -nn -vv -ni any "host $GLUETUN_IP and (udp port 53 or tcp port 53 or tcp port 853)"
```

```bash
docker stop gluetun

KILLSWITCH_DNS_NAME="arr-gluetun-killswitch-$(date +%s).example.com"
for service in qbittorrent prowlarr radarr sonarr flaresolverr; do
  docker inspect "$service" >/dev/null 2>&1 && {
    printf '\n[%s] kill-switch IPv4: ' "$service"
    docker exec "$service" sh -lc 'curl -4 -fsS --max-time 10 https://ifconfig.me && echo "LEAK: investigate" || echo "blocked or namespace unavailable as expected"' || echo "blocked or namespace unavailable as expected"
    printf '[%s] kill-switch DNS trigger: ' "$service"
    docker exec "$service" sh -lc "getent hosts $KILLSWITCH_DNS_NAME >/dev/null 2>&1 && echo \"unexpected DNS answer\" || echo \"lookup failed or namespace unavailable as expected\"" || echo "lookup failed or namespace unavailable as expected"
  }
done
```

Restore:

```bash
docker compose up -d gluetun

for i in $(seq 1 60); do
  docker inspect -f '{{.State.Health.Status}}' gluetun 2>/dev/null | grep -q healthy && { echo "gluetun healthy"; break; }
  echo "waiting for gluetun health..."; sleep 2
done

docker compose up -d qbittorrent prowlarr radarr sonarr flaresolverr
docker exec gluetun wget -qO- --timeout=15 https://ifconfig.me
```

**Cold-start broken-credential test:**

```bash
cd /opt/stacks/arr-stack
cp -a .env .env.before-gluetun-killswitch-test
chmod 600 .env.before-gluetun-killswitch-test
nano .env   # e.g. PIA_PASS=definitely_wrong_for_gluetun_killswitch_test
docker compose up -d --force-recreate gluetun
docker compose ps
docker logs --tail 150 gluetun

for service in gluetun qbittorrent prowlarr radarr sonarr flaresolverr; do
  docker inspect "$service" >/dev/null 2>&1 && {
    printf '\n[%s] broken-auth IPv4: ' "$service"
    docker exec "$service" sh -lc 'curl -4 -fsS --max-time 10 https://ifconfig.me && echo "LEAK: investigate" || echo "blocked as expected"' || echo "blocked as expected"
  }
done
```

Pass: Gluetun fails to establish the VPN or becomes unhealthy; protected services fail closed; none return the home WAN IP.

Restore:

```bash
cp -a .env.before-gluetun-killswitch-test .env
chmod 600 .env
docker compose up -d --force-recreate gluetun
docker compose up -d
docker compose ps
docker exec gluetun wget -qO- --timeout=15 https://ifconfig.me
rm .env.before-gluetun-killswitch-test
```

### Gluetun Final Pass Checklist

- [ ] `docker compose config` is valid.
- [ ] Gluetun starts healthy and returns a VPN IPv4.
- [ ] qBittorrent, Prowlarr, Radarr, Sonarr, FlareSolverr return VPN IPv4, never the home WAN IP.
- [ ] IPv6 does not connect from protected services.
- [ ] DNS leak watch is clean.
- [ ] Torrent leak-test magnet reports a VPN IP.
- [ ] Stopping Gluetun blocks protected services.
- [ ] Broken credentials do not fall back to the home WAN.
- [ ] Stack restores cleanly after both kill-switch tests.
- [ ] Seerr reaches Radarr/Sonarr via LAN-published URLs.
- [ ] qBittorrent import paths still work with Radarr/Sonarr.

### Gluetun Failure Response And Rollback

```bash
docker compose stop gluetun qbittorrent prowlarr radarr sonarr flaresolverr
docker compose config | grep -E 'network_mode|VPN_SERVICE_PROVIDER|OPENVPN_USER|SERVER_REGIONS|FIREWALL|DNS_UPSTREAM'
docker logs --tail 250 gluetun
docker exec gluetun ip route
```

Roll back to the hotio design if Gluetun does not work cleanly:

```bash
cd /opt/stacks/arr-stack
docker compose down
cp -a compose.hotio-vpn.backup.yaml compose.yaml
cp -a .env.before-gluetun .env
docker compose up -d qbittorrent

for i in $(seq 1 60); do
  docker exec qbittorrent sh -lc 'ip link show wg0 >/dev/null 2>&1' && { echo "wg0 is present"; break; }
  echo "waiting for wg0..."; sleep 2
done

docker exec qbittorrent curl -4 -fsS --max-time 15 https://ifconfig.me
docker compose up -d
```

Re-run the full hotio leak and kill-switch test after rollback.

## Ongoing Troubleshooting

| Symptom | Check |
|---|---|
| qBittorrent test fails in Radarr/Sonarr | UI reachable at `192.168.1.20:8080`; host `127.0.0.1`; port `8080`; correct username/password; category exactly `movies`/`tv`. Run `docker exec radarr curl -s http://127.0.0.1:8080` |
| Imports fail or copy instead of hardlink | Download/media paths both under `/data/...`; same filesystem; hardlinks enabled in Radarr/Sonarr |
| Prowlarr cannot reach Radarr/Sonarr | Use `http://127.0.0.1:7878` / `:8989` inside Prowlarr (shared namespace) |
| Seerr cannot reach Radarr/Sonarr | Use `http://192.168.1.20:7878` / `:8989` (Seerr does not share the VPN namespace) |
| Jellyfin shows no media | Confirm library paths `/media/movies`/`/media/tv`, that ARR wrote to `/data/media/...`, and that Jellyfin's mount maps the same folders |
| VPN IP check fails | Do not download; check VPN container logs, provider credentials/region, network mode on dependents, provider endpoint blocking |

## Appendix: Backups And Updates

Back up `/mnt/main/appdata/arr-stack`, `/opt/stacks/arr-stack/compose.yaml`, and `.env`; snapshot `/mnt/main/appdata` (optionally `/mnt/media/data`). Do not rely on media re-downloads as a database backup.

Manual updates only (no Watchtower initially):

```bash
cd /opt/stacks/arr-stack
docker compose pull
docker compose up -d
docker compose ps
```

Snapshot appdata before big updates; test UIs/imports after; roll back the snapshot if a migration breaks.

## Appendix: Internet Exposure (Last Phase)

Public exposure is optional and comes last. If pursued:

| Service | Public? | Notes |
|---|---:|---|
| Jellyfin | Optional | Strong accounts; consider Cloudflare Access |
| Seerr | Optional | Put behind Cloudflare Access or Authelia |
| Radarr/Sonarr/Prowlarr/qBittorrent/Dockge/TrueNAS/Proxmox | No | Private remote path only, never public |

Keep router port forwards disabled; run Cloudflare Tunnel on the Docker VM (not TrueNAS); route only public hostnames to selected services; test externally from a phone on cellular before trusting the setup.
