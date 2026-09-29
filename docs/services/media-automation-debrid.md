# Media Automation With Debrid

Last updated: 2026-06-10

This is an optional add-on guide for the current ARR stack. The source of truth is
[ARR Stack Local-First Homelab Setup Guide](arr-stack-homelab-fit-review-and-setup.md).

Use this only if you intentionally want a debrid workflow such as Real-Debrid,
TorBox, AllDebrid, Premiumize, or DebridLink. The current default ARR stack is
still qBittorrent through PIA with Radarr, Sonarr, Prowlarr, and FlareSolverr
sharing qBittorrent's VPN namespace.

## Current Homelab Fit

This guide assumes the ARR guide has already been followed:

- TrueNAS is storage only.
- Docker services run on the Ubuntu Docker VM.
- App configs live under `/mnt/main/appdata/arr-stack`.
- Media data lives under `/mnt/media/data`.
- ARR containers see the media data path as `/data`.
- Jellyfin reads final libraries from `/media/movies`, `/media/tv`, and
  `/media/music`.
- The stack is local-first. Internet exposure comes later and only for selected
  services such as Jellyfin or Seerr.
- Tailscale currently reaches Proxmox for remote management. Direct Docker VM
  Tailnet access is optional later.

Do not use the old paths from earlier media drafts:

| Old path | Current path |
|---|---|
| `/mnt/media/movies` | `/mnt/media/data/media/movies` |
| `/mnt/media/tv-shows` | `/mnt/media/data/media/tv` |
| `/mnt/media/downloads` | `/mnt/media/data/debrid` or `/mnt/media/data/torrents` |
| `/mnt/main/appdata/radarr` | `/mnt/main/appdata/arr-stack/radarr` |

Container path rule:

| Service | Container path |
|---|---|
| Radarr | `/data/media/movies` |
| Sonarr | `/data/media/tv` |
| qBittorrent | `/data/torrents` |
| RDTClient | `/data/debrid` |
| Jellyfin movies | `/media/movies` |
| Jellyfin TV | `/media/tv` |

Jellyfin does not fetch or download movies. It only scans and plays final media
files. Use Radarr for movies, Sonarr for TV, Prowlarr for indexers, and
qBittorrent or RDTClient as the download client. Optional request tools such as
Jellyseerr can be added later after Radarr, Sonarr, and Jellyfin imports work.

## Recommendation

For this homelab, use debrid as a second download client only after the base ARR
stack works locally.

Recommended mode:

```text
Prowlarr -> Radarr/Sonarr -> RDTClient -> Debrid provider -> /data/debrid
                                      |
                                      v
                         Radarr/Sonarr import to /data/media
                                      |
                                      v
                                  Jellyfin
```

Keep the existing PIA/qBittorrent stack in place unless you deliberately want to
replace it. The cleanest fit is to run RDTClient inside the same qBittorrent VPN
network namespace as Radarr and Sonarr. That keeps the current privacy model:
indexer searches, ARR metadata/download-client calls, qBittorrent, and RDTClient
all use the PIA-routed namespace.

Debrid reduces BitTorrent swarm exposure because your server downloads over
HTTPS from the debrid provider instead of joining the swarm directly. It does
not remove the need for privacy planning: your ISP can still see connections to
PIA, and without VPN routing it could see connections to debrid provider IPs.

## Same Stack Or Separate Debrid Stack?

Start with RDTClient in the existing ARR stack unless you have a specific reason
to isolate it. That keeps Radarr/Sonarr/RDTClient on the same `/data` path and,
in the current design, lets Radarr and Sonarr reach RDTClient at
`127.0.0.1:6500`.

A separate debrid compose project can be smart later if you want:

- independent start/stop for debrid experiments;
- a clean rollback path if the provider or RDTClient config breaks;
- a separate Gluetun/VPN gateway for debrid traffic;
- testing cloud-first tools such as Decypharr, Zurg, or rclone without touching
  the normal torrent stack.

For the first local-disk debrid setup, avoid duplicating Radarr and Sonarr.
Duplicate ARR instances create duplicate databases, root-folder decisions,
quality profiles, API keys, import history, and troubleshooting paths. Keep one
Radarr/Sonarr pair and add debrid as another download client.

If you do split RDTClient into its own compose project, keep these rules:

- Mount the same host data root as `/data`, usually `/mnt/media/data:/data`.
- Keep the RDTClient download path under `/data/debrid`.
- Publish `6500` from the namespace that actually owns RDTClient networking.
- Do not use `127.0.0.1:6500` from Radarr/Sonarr unless RDTClient shares their
  network namespace.
- Re-run the leak and kill-switch test with `rdt-client` included if you route
  it through the VPN.

For true independence, use a separate Gluetun plus RDTClient stack. For lower
complexity, keep RDTClient in the existing qBittorrent or Gluetun namespace and
treat it as an optional service in the ARR stack.

Recommended path:

1. If you want simplest networking: add RDTClient to the existing ARR stack.
2. If you want independent start/stop now: use the separate Gluetun debrid stack
   below.
3. Keep one Radarr/Sonarr pair either way. Do not duplicate ARR databases unless
   you are intentionally building a separate lab.

## Target Split: Independent Playback, Torrent, And Debrid

If the goal is:

- torrenting can start/stop independently;
- debrid can start/stop independently;
- playback keeps working while either download path is down;
- Radarr/Sonarr can use both qBittorrent and RDTClient;

then use separate stacks by lifecycle:

```text
jellyfin-stack
  jellyfin

arr-control-stack
  radarr
  sonarr
  optional: prowlarr

torrent-stack
  torrent-gluetun
  qbittorrent
  optional: prowlarr, flaresolverr

debrid-stack
  debrid-gluetun
  rdt-client
```

Use two Gluetun instances:

| Stack | Gluetun instance | Protects | Can restart without stopping |
|---|---|---|---|
| `torrent-stack` | `torrent-gluetun` | qBittorrent and torrent/indexer path | Jellyfin, debrid |
| `debrid-stack` | `debrid-gluetun` | RDTClient/debrid provider traffic | Jellyfin, torrent |

Do not share one Gluetun container between torrent and debrid if the goal is
independent start/stop. A shared Gluetun couples both paths: stopping or breaking
that one VPN gateway breaks every service attached to it.

Radarr and Sonarr should not live inside either VPN namespace in this split.
They should run in an `arr-control-stack` on normal Docker networking and talk
to each download client through the Docker VM LAN-published ports:

| From | To | URL |
|---|---|---|
| Radarr/Sonarr | qBittorrent | `http://192.168.1.20:8080` |
| Radarr/Sonarr | RDTClient | `http://192.168.1.20:6500` |
| Jellyfin | final media only | `/media/movies`, `/media/tv`, `/media/music` |

This is different from the current initial ARR guide, where Radarr and Sonarr
share qBittorrent's VPN namespace and use `127.0.0.1` for internal app
communication. That initial design is privacy-strict and simple, but it is not
the right shape when torrent and debrid must be independently restartable.

Tradeoff:

- Radarr/Sonarr on normal Docker networking can coordinate both download stacks.
- qBittorrent and RDTClient traffic still go through their own Gluetun gateways.
- Radarr/Sonarr metadata traffic uses the Docker VM's normal network unless you
  add a separate proxy/VPN strategy later.
- Prowlarr can stay in `arr-control-stack` for simpler networking, or move into
  `torrent-stack` if you want indexer traffic behind `torrent-gluetun`. If
  Prowlarr is in `torrent-stack`, it may need an intentional Gluetun LAN
  outbound allowance to sync apps back to Radarr/Sonarr.

For this homelab, the clean independent target is:

```text
Playback:        jellyfin-stack, never behind torrent/debrid VPN
Automation:      arr-control-stack, one Radarr/Sonarr pair
Torrenting:      torrent-stack with its own Gluetun
Debrid:          debrid-stack with its own Gluetun
```

Do not try to make the current shared qBittorrent VPN namespace reach across to
the independent debrid stack by broadly loosening firewall rules. If Radarr and
Sonarr need both download clients, move Radarr/Sonarr to the control stack
instead.

### Migration Order From The Current ARR Stack

If Jellyfin, Radarr, Sonarr, Prowlarr, qBittorrent, and FlareSolverr are
currently all in `/opt/stacks/arr-stack`, split them in this order:

1. Split Jellyfin first.
   - Stop only the `jellyfin` service in the ARR stack.
   - Move the Jellyfin compose definition into `/opt/stacks/jellyfin-stack`.
   - Keep the existing config path, for example
     `/mnt/main/appdata/arr-stack/jellyfin`, so the Jellyfin database and users
     are preserved.
   - Start `jellyfin-stack` and confirm playback still works.

2. Keep the current ARR/qBittorrent stack working while you test debrid.
   - Your current timeout from Radarr/Sonarr to `192.168.1.20:6500` is expected
     while Radarr/Sonarr still share qBittorrent's VPN namespace.
   - Use the independent debrid stack for manual RDTClient testing first.

3. Create the final `arr-control-stack`.
   - Move Radarr and Sonarr out of the qBittorrent VPN namespace.
   - Remove `network_mode: "service:qbittorrent"` from Radarr/Sonarr.
   - Put them on normal Docker networking with LAN-published UI ports.
   - Configure download clients by Docker VM LAN IP:

     ```text
     qBittorrent: 192.168.1.20:8080
     RDTClient:   192.168.1.20:6500
     ```

4. Create or migrate to `torrent-stack`.
   - Use `torrent-gluetun` plus qBittorrent.
   - Publish qBittorrent WebUI on `torrent-gluetun`.
   - Keep qBittorrent downloads at `/data/torrents`.

5. Keep `debrid-stack` as already built.
   - Use `debrid-gluetun` plus RDTClient.
   - Publish RDTClient on `debrid-gluetun`.
   - Keep RDTClient downloads at `/data/debrid`.

After this split:

```text
Stopping torrent-stack does not stop debrid or playback.
Stopping debrid-stack does not stop torrenting or playback.
Stopping arr-control-stack stops automation decisions, but not playback.
Stopping jellyfin-stack stops playback only.
```

### Pasteable Commands: Split Playback And Control Stacks

Run these on the **Ubuntu Docker VM**. These commands preserve the existing
appdata folders under `/mnt/main/appdata/arr-stack`, so Jellyfin, Radarr, Sonarr,
and Prowlarr keep their databases.

First record the current state:

```bash
cd /opt/stacks/arr-stack
docker compose ps
df -h /mnt/main /mnt/media/data
id mediauser
```

Create Jellyfin as its own stack:

```bash
cd /opt/stacks/arr-stack
docker compose stop jellyfin
docker compose rm -f jellyfin

sudo mkdir -p /opt/stacks/jellyfin-stack
sudo chown -R "$USER":"$USER" /opt/stacks/jellyfin-stack
cd /opt/stacks/jellyfin-stack

cat > .env <<'EOF'
PUID=3000
PGID=3000
TZ=Europe/Berlin
DOCKER_IP=192.168.1.20
JELLYFIN_CONFIG=/mnt/main/appdata/arr-stack/jellyfin
DATA_PATH=/mnt/media/data
EOF

cat > docker-compose.yml <<'EOF'
services:
  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${JELLYFIN_CONFIG}:/config
      - ${DATA_PATH}/media/movies:/media/movies:ro
      - ${DATA_PATH}/media/tv:/media/tv:ro
      - ${DATA_PATH}/media/music:/media/music:ro
    devices:
      - /dev/dri:/dev/dri
    ports:
      - "${DOCKER_IP}:8096:8096"
EOF

docker compose config
docker compose up -d
docker compose ps
```

Open Jellyfin:

```text
http://192.168.1.20:8096
```

Then create the control stack for Radarr, Sonarr, and Prowlarr:

```bash
cd /opt/stacks/arr-stack
docker compose stop radarr sonarr prowlarr
docker compose rm -f radarr sonarr prowlarr

sudo mkdir -p /opt/stacks/arr-control-stack
sudo chown -R "$USER":"$USER" /opt/stacks/arr-control-stack
cd /opt/stacks/arr-control-stack

cat > .env <<'EOF'
PUID=3000
PGID=3000
TZ=Europe/Berlin
DOCKER_IP=192.168.1.20
CONFIG_PATH=/mnt/main/appdata/arr-stack
DATA_PATH=/mnt/media/data
EOF

cat > docker-compose.yml <<'EOF'
services:
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    restart: unless-stopped
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${CONFIG_PATH}/prowlarr:/config
    ports:
      - "${DOCKER_IP}:9696:9696"
    networks:
      - arr-control

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${CONFIG_PATH}/radarr:/config
      - ${DATA_PATH}:/data
    ports:
      - "${DOCKER_IP}:7878:7878"
    networks:
      - arr-control
    depends_on:
      - prowlarr

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${CONFIG_PATH}/sonarr:/config
      - ${DATA_PATH}:/data
    ports:
      - "${DOCKER_IP}:8989:8989"
    networks:
      - arr-control
    depends_on:
      - prowlarr

networks:
  arr-control:
    name: arr-control
    driver: bridge
EOF

docker compose config
docker compose up -d
docker compose ps
```

After this split, do not start `radarr`, `sonarr`, `prowlarr`, or `jellyfin`
from the old `/opt/stacks/arr-stack` compose again. Remove or comment those
services from the old ARR compose before running a broad `docker compose up -d`
there. The old ARR stack should temporarily own only the torrent/VPN side, such
as qBittorrent and FlareSolverr.

If `arr-control-stack` fails with a port error like this:

```text
Bind for 192.168.1.20:9696 failed: port is already allocated
```

the old ARR stack is still publishing the moved app's port, usually on the
`qbittorrent` service because the previous design published shared-namespace app
ports there. Fix that before starting `arr-control-stack`:

```bash
docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep -E '9696|7878|8989'

cd /opt/stacks/arr-control-stack
docker compose down

cd /opt/stacks/arr-stack
nano compose.yaml
```

In the old ARR compose, remove or comment these port mappings from the
`qbittorrent` service:

```yaml
# remove after moving these apps to arr-control-stack
# - "${DOCKER_IP}:9696:9696"
# - "${DOCKER_IP}:7878:7878"
# - "${DOCKER_IP}:8989:8989"
```

Also remove or comment the old `prowlarr:`, `radarr:`, and `sonarr:` service
blocks from `/opt/stacks/arr-stack/compose.yaml`, because those containers now
belong to `/opt/stacks/arr-control-stack`.

Then apply the old ARR stack change and start the control stack:

```bash
cd /opt/stacks/arr-stack
docker compose config
docker compose up -d qbittorrent flaresolverr

cd /opt/stacks/arr-control-stack
docker compose up -d
docker compose ps
```

Verify control stack access:

```bash
curl -fsS --max-time 10 http://192.168.1.20:7878 >/dev/null && echo "radarr UI reachable"
curl -fsS --max-time 10 http://192.168.1.20:8989 >/dev/null && echo "sonarr UI reachable"
curl -fsS --max-time 10 http://192.168.1.20:9696 >/dev/null && echo "prowlarr UI reachable"
```

Verify Radarr/Sonarr can reach both independent download stacks:

```bash
docker exec radarr sh -lc 'curl -fsS --max-time 10 http://192.168.1.20:8080 || wget -qO- --timeout=10 http://192.168.1.20:8080' >/dev/null && echo "radarr can reach qBittorrent"
docker exec sonarr sh -lc 'curl -fsS --max-time 10 http://192.168.1.20:8080 || wget -qO- --timeout=10 http://192.168.1.20:8080' >/dev/null && echo "sonarr can reach qBittorrent"
docker exec radarr sh -lc 'curl -fsS --max-time 10 http://192.168.1.20:6500 || wget -qO- --timeout=10 http://192.168.1.20:6500' >/dev/null && echo "radarr can reach RDTClient"
docker exec sonarr sh -lc 'curl -fsS --max-time 10 http://192.168.1.20:6500 || wget -qO- --timeout=10 http://192.168.1.20:6500' >/dev/null && echo "sonarr can reach RDTClient"
```

In Radarr and Sonarr, configure download clients with LAN URLs:

```text
qBittorrent
  Host: 192.168.1.20
  Port: 8080
  Category: movies or tv

RDTClient
  Host: 192.168.1.20
  Port: 6500
  Category: movies or tv
```

Keep root folders:

```text
Radarr root folder: /data/media/movies
Sonarr root folder: /data/media/tv
```

### Pasteable Commands: Current ARR Torrent-Only Stack

Use this now if you already split Jellyfin, Radarr/Sonarr/Prowlarr, and debrid
into their own stacks. In that layout, `/opt/stacks/arr-stack` should only run
the torrent side: one Gluetun VPN gateway and qBittorrent inside that gateway.

Your current port check shows `debrid-gluetun` already owns `192.168.1.20:6500`
and nothing owns `8080`, so this stack can safely publish qBittorrent at
`192.168.1.20:8080`.

```bash
cd /opt/stacks/arr-stack

cp -a compose.yaml compose.before-torrent-only.$(date +%Y%m%d-%H%M%S).yaml 2>/dev/null || true
cp -a docker-compose.yml docker-compose.before-torrent-only.$(date +%Y%m%d-%H%M%S).yml 2>/dev/null || true
cp -a .env .env.before-torrent-only.$(date +%Y%m%d-%H%M%S) 2>/dev/null || true

docker compose down

sudo -u mediauser mkdir -p /mnt/main/appdata/arr-stack/gluetun
sudo -u mediauser mkdir -p /mnt/main/appdata/arr-stack/qbittorrent
sudo -u mediauser mkdir -p /mnt/media/data/torrents/incomplete
sudo -u mediauser mkdir -p /mnt/media/data/torrents/movies
sudo -u mediauser mkdir -p /mnt/media/data/torrents/tv
```

Create the ARR stack environment file. Replace the PIA username and password
before starting the stack.

```bash
cat > .env <<'EOF'
PUID=3000
PGID=3000
TZ=Europe/Berlin
DOCKER_IP=192.168.1.20

CONFIG_PATH=/mnt/main/appdata/arr-stack
GLUETUN_CONFIG_PATH=/mnt/main/appdata/arr-stack
DATA_PATH=/mnt/media/data

GLUETUN_VERSION=latest
QBITTORRENT_VERSION=latest

PIA_USER=p1234567
PIA_PASS=replace_with_your_pia_password
PIA_REGION=Netherlands
PIA_PORT_FORWARDING=on
EOF

chmod 600 .env
```

Create the new torrent-only ARR stack compose file:

```bash
cat > compose.yaml <<'EOF'
services:
  gluetun:
    image: qmcgaw/gluetun:${GLUETUN_VERSION}
    container_name: arr-gluetun
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
      - VPN_PORT_FORWARDING=${PIA_PORT_FORWARDING}
      - VPN_PORT_FORWARDING_PROVIDER=private internet access
      - VPN_PORT_FORWARDING_USERNAME=${PIA_USER}
      - VPN_PORT_FORWARDING_PASSWORD=${PIA_PASS}
      - DNS_UPSTREAM_RESOLVER_TYPE=${DNS_UPSTREAM_RESOLVER_TYPE:-doh}
      - DNS_UPSTREAM_RESOLVERS=${DNS_UPSTREAM_RESOLVERS:-cloudflare}
      - DNS_UPSTREAM_IPV6=off
      - BLOCK_MALICIOUS=on
      - BLOCK_SURVEILLANCE=off
      - BLOCK_ADS=off
    volumes:
      - ${GLUETUN_CONFIG_PATH}/gluetun:/gluetun
    ports:
      - "${DOCKER_IP}:8080:8080"
    networks:
      - arr-torrent
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- --timeout=10 https://ifconfig.me >/dev/null 2>&1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 90s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

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
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  arr-torrent:
    name: arr-torrent
    driver: bridge
EOF
```

Start and verify the ARR torrent stack:

```bash
docker compose config
docker compose up -d gluetun
docker logs --tail 150 arr-gluetun
docker exec arr-gluetun wget -qO- --timeout=15 https://ifconfig.me
docker compose up -d qbittorrent
docker compose ps
```

Verify the split from the control stack:

```bash
cd /opt/stacks/arr-control-stack

docker exec radarr sh -lc 'curl -fsS --max-time 10 http://192.168.1.20:8080 || wget -qO- --timeout=10 http://192.168.1.20:8080' >/dev/null && echo "radarr can reach qBittorrent"
docker exec sonarr sh -lc 'curl -fsS --max-time 10 http://192.168.1.20:8080 || wget -qO- --timeout=10 http://192.168.1.20:8080' >/dev/null && echo "sonarr can reach qBittorrent"
docker exec radarr sh -lc 'curl -fsS --max-time 10 http://192.168.1.20:6500 || wget -qO- --timeout=10 http://192.168.1.20:6500' >/dev/null && echo "radarr can reach RDTClient"
docker exec sonarr sh -lc 'curl -fsS --max-time 10 http://192.168.1.20:6500 || wget -qO- --timeout=10 http://192.168.1.20:6500' >/dev/null && echo "sonarr can reach RDTClient"
```

Use these download client settings in Radarr and Sonarr:

```text
qBittorrent
  Host: 192.168.1.20
  Port: 8080

RDTClient
  Host: 192.168.1.20
  Port: 6500
```

After this split, stopping `/opt/stacks/arr-stack` only stops torrenting.
Playback stays in `jellyfin-stack`, ARR management stays in `arr-control-stack`,
and debrid stays in `debrid-stack`.

### Pasteable Commands: Later Torrent Gluetun Stack

Use this later if you want torrenting to have its own independent Gluetun stack,
separate from `debrid-stack`. Do this only after the current qBittorrent path is
stable or you have a backup of its config.

```bash
sudo mkdir -p /opt/stacks/torrent-stack
sudo chown -R "$USER":"$USER" /opt/stacks/torrent-stack
sudo -u mediauser mkdir -p /mnt/main/appdata/torrent-stack/gluetun

cd /opt/stacks/torrent-stack

cat > .env <<'EOF'
PUID=3000
PGID=3000
TZ=Europe/Berlin
DOCKER_IP=192.168.1.20
CONFIG_PATH=/mnt/main/appdata/arr-stack
GLUETUN_CONFIG_PATH=/mnt/main/appdata/torrent-stack
DATA_PATH=/mnt/media/data

GLUETUN_VERSION=latest
QBITTORRENT_VERSION=latest

PIA_USER=p1234567
PIA_PASS=replace_with_your_pia_password
PIA_REGION=Netherlands
PIA_PORT_FORWARDING=on
EOF

cat > docker-compose.yml <<'EOF'
services:
  gluetun:
    image: qmcgaw/gluetun:${GLUETUN_VERSION}
    container_name: torrent-gluetun
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
      - VPN_PORT_FORWARDING=${PIA_PORT_FORWARDING}
      - VPN_PORT_FORWARDING_PROVIDER=private internet access
      - VPN_PORT_FORWARDING_USERNAME=${PIA_USER}
      - VPN_PORT_FORWARDING_PASSWORD=${PIA_PASS}
      - DNS_UPSTREAM_RESOLVER_TYPE=${DNS_UPSTREAM_RESOLVER_TYPE:-doh}
      - DNS_UPSTREAM_RESOLVERS=${DNS_UPSTREAM_RESOLVERS:-cloudflare}
      - DNS_UPSTREAM_IPV6=off
      - BLOCK_MALICIOUS=on
      - BLOCK_SURVEILLANCE=off
      - BLOCK_ADS=off
    volumes:
      - ${GLUETUN_CONFIG_PATH}/gluetun:/gluetun
    ports:
      - "${DOCKER_IP}:8080:8080"
    networks:
      - torrent
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

networks:
  torrent:
    name: torrent
    driver: bridge
EOF

docker compose config
```

Before starting this `torrent-stack`, stop qBittorrent in the old ARR stack so
there is no container-name or port conflict:

```bash
cd /opt/stacks/arr-stack
docker compose stop qbittorrent flaresolverr
docker compose rm -f qbittorrent flaresolverr
```

Then start the new torrent stack:

```bash
cd /opt/stacks/torrent-stack
docker compose up -d gluetun
docker logs --tail 150 torrent-gluetun
docker exec torrent-gluetun wget -qO- --timeout=15 https://ifconfig.me
docker compose up -d qbittorrent
docker compose ps
```

The `torrent-gluetun` IP must be a PIA/VPN IP, not your home WAN IP. After this,
Radarr/Sonarr in `arr-control-stack` should still use:

```text
qBittorrent: 192.168.1.20:8080
```

## Independent Option: Separate Gluetun Debrid Stack

Use this when the base ARR stack already works and you want to stop, restart, or
rebuild debrid tooling without touching qBittorrent, Radarr, Sonarr, Prowlarr,
or Jellyfin.

This repo includes a ready stack:

```text
configs/docker/debrid-stack/docker-compose.yml
configs/docker/debrid-stack/.env.example
```

What runs independently:

| Service | Purpose |
|---|---|
| `debrid-gluetun` | Own VPN gateway, DNS path, and kill switch for debrid traffic. |
| `debrid-rdt-client` | RDTClient sharing the `debrid-gluetun` network namespace. |

What does not run in this debrid stack:

| Service | Reason |
|---|---|
| Radarr | Keep one movie database and one import history in `arr-control-stack`. |
| Sonarr | Keep one TV database and one import history in `arr-control-stack`. |
| Prowlarr | Keep one indexer manager; place it in control or torrent stack deliberately. |
| Jellyfin | Keep playback isolated in `jellyfin-stack`. |
| qBittorrent | Keep torrenting isolated in `torrent-stack`. |

Recommended separate project layout:

```text
/opt/stacks/debrid-stack
  docker-compose.yml
  .env

/mnt/main/appdata/debrid-stack
  rdt-client
  gluetun

/mnt/media/data
  debrid
  media
  torrents
  usenet
```

Create the appdata and debrid directories on the **Ubuntu Docker VM**, not in
the TrueNAS shell. These paths should already be mounted on the Docker VM over
NFS:

```bash
sudo -u mediauser mkdir -p /mnt/main/appdata/debrid-stack/rdt-client
sudo -u mediauser mkdir -p /mnt/main/appdata/debrid-stack/gluetun
sudo -u mediauser mkdir -p /mnt/media/data/debrid/incomplete
sudo -u mediauser mkdir -p /mnt/media/data/debrid/movies
sudo -u mediauser mkdir -p /mnt/media/data/debrid/tv
```

If you accidentally pasted this block into the TrueNAS shell, stop and switch to
the Docker VM:

```bash
ssh dockeradmin@192.168.1.20
findmnt /mnt/main
findmnt /mnt/media/data
id mediauser
```

Do not create `/mnt/media` manually on TrueNAS. On TrueNAS, `/mnt/media/data`
must come from the existing media pool/dataset layout. If it does not exist
there, go back to the TrueNAS storage setup and create or verify the media pool
and dataset first.

Copy the stack from your workstation to the Docker VM:

```bash
scp -r configs/docker/debrid-stack dockeradmin@192.168.1.20:/opt/stacks/
```

Or create the files directly on the **Ubuntu Docker VM** with this pasteable
block. Review the `.env` values after pasting and replace the PIA placeholders
before starting the stack:

```bash
sudo mkdir -p /opt/stacks/debrid-stack
sudo chown -R "$USER":"$USER" /opt/stacks/debrid-stack
cd /opt/stacks/debrid-stack

cat > .env <<'EOF'
# Independent debrid stack environment
# Keep this file on the Docker VM. Do not commit real secrets to git.

PUID=3000
PGID=3000
TZ=Europe/Berlin

# Docker VM LAN IP. Ports are bound to this IP only, not all interfaces.
DOCKER_IP=192.168.1.20

# TrueNAS-backed paths mounted on the Docker VM.
CONFIG_PATH=/mnt/main/appdata/debrid-stack
DATA_PATH=/mnt/media/data

# Image versions. Pin tighter after you have a known-good version.
GLUETUN_VERSION=latest
RDTCLIENT_VERSION=latest

# Private Internet Access credentials.
# PIA usernames usually start with "p". Do not use your PIA account email.
PIA_USER=p1234567
PIA_PASS=replace_with_your_pia_password

# Pick a nearby region. For this debrid stack, port forwarding is not required.
PIA_REGION=Netherlands
PIA_PORT_FORWARDING=off
EOF

cat > docker-compose.yml <<'EOF'
# Independent Debrid Stack
#
# Purpose:
# - Run debrid tooling independently from the main ARR/qBittorrent stack.
# - Give RDTClient its own Gluetun VPN gateway and kill switch.
# - Keep Radarr/Sonarr/Jellyfin in the main ARR stack; do not duplicate them.

services:
  gluetun:
    image: qmcgaw/gluetun:${GLUETUN_VERSION}
    container_name: debrid-gluetun
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
      - VPN_PORT_FORWARDING=${PIA_PORT_FORWARDING}
      - VPN_PORT_FORWARDING_PROVIDER=private internet access
      - VPN_PORT_FORWARDING_USERNAME=${PIA_USER}
      - VPN_PORT_FORWARDING_PASSWORD=${PIA_PASS}
      - DNS_UPSTREAM_RESOLVER_TYPE=${DNS_UPSTREAM_RESOLVER_TYPE:-doh}
      - DNS_UPSTREAM_RESOLVERS=${DNS_UPSTREAM_RESOLVERS:-cloudflare}
      - DNS_UPSTREAM_IPV6=off
      - BLOCK_MALICIOUS=on
      - BLOCK_SURVEILLANCE=off
      - BLOCK_ADS=off
    volumes:
      - ${CONFIG_PATH}/gluetun:/gluetun
    ports:
      - "${DOCKER_IP}:6500:6500"
    networks:
      - debrid
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- --timeout=10 https://ifconfig.me >/dev/null 2>&1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 90s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  rdt-client:
    image: rogerfar/rdtclient:${RDTCLIENT_VERSION}
    container_name: debrid-rdt-client
    restart: unless-stopped
    network_mode: "service:gluetun"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${CONFIG_PATH}/rdt-client:/data/db
      - ${DATA_PATH}:/data
    depends_on:
      gluetun:
        condition: service_healthy
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  debrid:
    name: debrid
    driver: bridge
EOF

cat > README.md <<'EOF'
# Independent Debrid Stack

This stack runs RDTClient behind its own Gluetun VPN gateway so it can be
started, stopped, tested, or rebuilt independently from the main ARR stack.

It does not include Radarr, Sonarr, Prowlarr, Jellyfin, or qBittorrent. Keep
those in the main ARR stack and add this RDTClient instance as an additional
download client if the networking test passes.

Open RDTClient:

http://192.168.1.20:6500

Verify VPN:

docker exec debrid-gluetun wget -qO- --timeout=15 https://ifconfig.me

The returned IPv4 must be a VPN IP, not your home WAN IP.
EOF

chmod 600 .env
docker compose config
```

If you copied the stack from the repo instead of using the pasteable block, then
on the Docker VM:

```bash
cd /opt/stacks/debrid-stack
cp .env.example .env
nano .env
```

Set these values:

| Setting | Value |
|---|---|
| `PUID` / `PGID` | Numeric `mediauser` UID/GID, normally `3000:3000`. |
| `DOCKER_IP` | Docker VM LAN IP, normally `192.168.1.20`. |
| `CONFIG_PATH` | `/mnt/main/appdata/debrid-stack`. |
| `DATA_PATH` | `/mnt/media/data`. |
| `PIA_USER` | PIA username, usually starts with `p`. |
| `PIA_PASS` | PIA password. |
| `PIA_REGION` | A nearby PIA region. |

Validate:

```bash
docker compose config
```

Start Gluetun first:

```bash
docker compose up -d gluetun
docker compose ps
docker logs --tail 150 debrid-gluetun
docker exec debrid-gluetun wget -qO- --timeout=15 https://ifconfig.me
```

The public IPv4 must be a PIA/VPN IP, not your home WAN IP.

Start RDTClient:

```bash
docker compose up -d rdt-client
docker compose ps
docker logs --tail 100 debrid-rdt-client
```

Open RDTClient from the LAN:

```text
http://192.168.1.20:6500
```

If your Docker VM IP differs, use `DOCKER_IP` from `.env`.

The compose pattern is:

```yaml
services:
  gluetun:
    image: qmcgaw/gluetun:${GLUETUN_VERSION}
    container_name: debrid-gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - "${DOCKER_IP}:6500:6500"

  rdt-client:
    image: rogerfar/rdtclient:${RDTCLIENT_VERSION}
    container_name: debrid-rdt-client
    restart: unless-stopped
    network_mode: "service:gluetun"
    volumes:
      - ${CONFIG_PATH}/rdt-client:/data/db
      - ${DATA_PATH}:/data
```

RDTClient's port is published on `debrid-gluetun`, not on `rdt-client`, because
RDTClient shares Gluetun's network namespace.

Stop or restart only the debrid stack:

```bash
cd /opt/stacks/debrid-stack
docker compose stop
docker compose up -d
```

This does not stop qBittorrent, Radarr, Sonarr, Prowlarr, Jellyfin, or Seerr in
the main ARR stack.

### Independent Stack Network Tests

Record the home WAN IP from the Docker VM:

```bash
HOME_WAN_IP="$(curl -4 -fsS --max-time 15 https://ifconfig.me)"
printf 'Home WAN IPv4: %s\n' "$HOME_WAN_IP"
```

Check Gluetun and RDTClient public IPv4:

```bash
cd /opt/stacks/debrid-stack
docker exec debrid-gluetun wget -qO- --timeout=15 https://ifconfig.me
```

Pass criteria:

- `debrid-gluetun` returns a PIA/VPN IP.
- It does not return `$HOME_WAN_IP`.
- RDTClient shares this same network namespace through
  `network_mode: "service:gluetun"`.

If the RDTClient image has `curl` or `wget`, you can also check from inside it:

```bash
docker exec debrid-rdt-client sh -lc 'curl -4 -fsS --max-time 15 https://ifconfig.me || wget -qO- --timeout=15 https://ifconfig.me'
```

Check the RDTClient UI from the Docker VM:

```bash
curl -fsS --max-time 10 http://192.168.1.20:6500 || wget -qO- --timeout=10 http://192.168.1.20:6500
```

Then check whether the Radarr and Sonarr containers can reach the separate
debrid stack. If you already moved Radarr/Sonarr into `arr-control-stack`, run
this from that stack path. If they are still in the old qBittorrent VPN
namespace, this test is expected to time out.

```bash
cd /opt/stacks/arr-control-stack
docker exec radarr sh -lc 'curl -fsS --max-time 10 http://192.168.1.20:6500 || wget -qO- --timeout=10 http://192.168.1.20:6500' >/dev/null && echo "radarr can reach RDTClient"
docker exec sonarr sh -lc 'curl -fsS --max-time 10 http://192.168.1.20:6500 || wget -qO- --timeout=10 http://192.168.1.20:6500' >/dev/null && echo "sonarr can reach RDTClient"
```

If those commands fail, Radarr/Sonarr cannot reach the independent debrid stack
from their current VPN namespace. Do not broadly loosen the VPN firewall. Use
one of these designs instead:

- Keep RDTClient in the existing qBittorrent VPN namespace.
- Move Radarr/Sonarr into an `arr-control-stack` on normal Docker networking so
  they can reach both `torrent-stack` and `debrid-stack` through LAN-published
  ports.
- Migrate the whole ARR search/download side to one shared Gluetun namespace if
  you prefer privacy-strict simplicity over independent torrent/debrid restart.
- Keep the independent debrid stack for manual testing only until you redesign
  the ARR networking deliberately.

Your observed result:

```text
curl: (28) Connection timed out after 10002 milliseconds
wget: download timed out
```

means the current Radarr/Sonarr containers are blocked from reaching
`192.168.1.20:6500` from inside the qBittorrent VPN namespace. That is expected
with the initial strict VPN model. Do not keep retrying the same command until
you change the stack layout.

If the commands pass, add RDTClient in Radarr/Sonarr as a qBittorrent download
client:

```text
Host: 192.168.1.20
Port: 6500
```

Use categories:

```text
movies
tv
```

Use the download path inside RDTClient:

```text
/data/debrid
```

No remote path mapping should be needed if RDTClient reports paths under
`/data/debrid` and Radarr/Sonarr also see `/mnt/media/data` as `/data`.

### Independent Stack Kill-Switch Test

This intentionally interrupts only the debrid stack.

```bash
cd /opt/stacks/debrid-stack
docker stop debrid-gluetun

docker exec debrid-rdt-client sh -lc 'curl -4 -fsS --max-time 10 https://ifconfig.me && echo "LEAK: investigate" || echo "blocked or namespace unavailable as expected"' || echo "blocked or namespace unavailable as expected"
```

Pass criteria:

- RDTClient cannot reach the internet while `debrid-gluetun` is stopped.
- It does not return your home WAN IP.

Restore:

```bash
docker compose up -d gluetun

for i in $(seq 1 60); do
  if docker inspect -f '{{.State.Health.Status}}' debrid-gluetun 2>/dev/null | grep -q healthy; then
    echo "debrid-gluetun healthy"
    break
  fi

  echo "waiting for debrid-gluetun health..."
  sleep 2
done

docker compose up -d rdt-client
docker exec debrid-gluetun wget -qO- --timeout=15 https://ifconfig.me
```

## Architecture Choices

### Option A: Local Disk Debrid

Use this for the current homelab.

| Component | Role |
|---|---|
| Prowlarr | Indexer management. |
| Radarr | Movie automation. |
| Sonarr | TV automation. |
| RDTClient | qBittorrent-compatible debrid downloader. |
| Jellyfin | Local playback from TrueNAS-backed files. |
| Seerr | Optional request UI after Jellyfin/Radarr/Sonarr work. |

Files are downloaded to local disk first, then imported into the normal ARR
library paths:

```text
/mnt/media/data/debrid/movies
/mnt/media/data/debrid/tv
/mnt/media/data/media/movies
/mnt/media/data/media/tv
```

Because `/data/debrid` and `/data/media` are under the same mounted data tree,
Radarr/Sonarr can use hardlinks or atomic moves when the underlying TrueNAS
dataset layout supports it.

### Option B: Cloud-First Mounts

Tools such as Decypharr, Zurg, and rclone can expose a cloud-first library where
Jellyfin streams from a debrid mount or symlink tree.

That is not the recommended fit for this setup because:

- files are not guaranteed to persist locally;
- playback depends on debrid/cloud availability;
- symlink and mount behavior adds another failure mode;
- it diverges from the current Jellyfin local-library design.

Use this only as a separate experiment, not as the default media library.

## Directory Layout

Create one optional debrid staging tree under the existing data root:

```text
/mnt/media/data
+-- debrid
|   +-- incomplete
|   +-- movies
|   +-- tv
+-- media
|   +-- movies
|   +-- tv
|   +-- music
+-- torrents
|   +-- incomplete
|   +-- movies
|   +-- tv
+-- usenet
    +-- incomplete
    +-- movies
    +-- tv

/mnt/main/appdata/arr-stack
+-- rdt-client
+-- radarr
+-- sonarr
+-- prowlarr
+-- qbittorrent
+-- jellyfin
+-- seerr
```

Create the new directories on the Docker VM:

```bash
sudo -u mediauser mkdir -p /mnt/media/data/debrid/incomplete
sudo -u mediauser mkdir -p /mnt/media/data/debrid/movies
sudo -u mediauser mkdir -p /mnt/media/data/debrid/tv
sudo -u mediauser mkdir -p /mnt/main/appdata/arr-stack/rdt-client
```

Check ownership:

```bash
ls -ln /mnt/media/data/debrid
ls -ln /mnt/main/appdata/arr-stack/rdt-client
```

The numeric UID/GID should match the `PUID` and `PGID` used by the ARR stack.

## Compose Add-On

Edit the existing stack:

```text
/opt/stacks/arr-stack/compose.yaml
```

Add port `6500` to the existing `qbittorrent` service because RDTClient will
share qBittorrent's network namespace:

```yaml
    ports:
      - "${DOCKER_IP}:8080:8080"
      - "${DOCKER_IP}:9696:9696"
      - "${DOCKER_IP}:7878:7878"
      - "${DOCKER_IP}:8989:8989"
      - "${DOCKER_IP}:6767:6767"
      - "${DOCKER_IP}:6500:6500"
```

Then add this service beside the other optional services:

```yaml
  rdt-client:
    image: rogerfar/rdtclient:latest
    container_name: rdt-client
    restart: unless-stopped
    network_mode: "service:qbittorrent"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${CONFIG_PATH}/rdt-client:/data/db
      - ${DATA_PATH}:/data
    depends_on:
      qbittorrent:
        condition: service_healthy
```

Validate and start:

```bash
cd /opt/stacks/arr-stack
docker compose config
docker compose up -d rdt-client
docker compose ps
```

Open RDTClient from the LAN:

```text
http://192.168.1.20:6500
```

If your Docker VM IP differs, use the value from `DOCKER_IP` in `.env`.

## RDTClient Setup

In RDTClient:

| Setting | Value |
|---|---|
| Provider | Real-Debrid, TorBox, AllDebrid, Premiumize, or DebridLink |
| API token | Store only in the app/config, never in git |
| Download path | `/data/debrid` |
| qBittorrent-compatible API | Enabled |
| Port | `6500` |

RDTClient's Docker image commonly documents `/data/downloads` as the default
download volume. In this homelab compose, `${DATA_PATH}` is mounted at `/data`
instead so `/data/debrid`, `/data/torrents`, and `/data/media` remain visible
under the same internal root.

Use provider support as a current-state decision. Provider features, legal
pressure, API behavior, and content filtering can change. Verify the provider
before paying for a long subscription.

Practical starting point:

- Use one provider first.
- Test one legal/public-domain item before enabling automation.
- Add a second provider only after the first import path is proven.

## Radarr And Sonarr

Because RDTClient, Radarr, and Sonarr all share qBittorrent's VPN namespace in
the recommended compose, connect to RDTClient through localhost from Radarr and
Sonarr.

### Radarr

Root folder:

```text
/data/media/movies
```

Download client:

| Setting | Value |
|---|---|
| Type | qBittorrent |
| Name | `RDTClient Debrid Movies` |
| Host | `127.0.0.1` |
| Port | `6500` |
| Category | `movies` |

No remote path mapping should be needed when RDTClient reports paths under
`/data/debrid` and Radarr also sees `${DATA_PATH}` as `/data`.

### Sonarr

Root folder:

```text
/data/media/tv
```

Download client:

| Setting | Value |
|---|---|
| Type | qBittorrent |
| Name | `RDTClient Debrid TV` |
| Host | `127.0.0.1` |
| Port | `6500` |
| Category | `tv` |

Keep the existing qBittorrent download client if you still want traditional
PIA-routed torrents. Give the debrid and torrent clients clear names so you can
tell which path each grab used.

## Prowlarr

Prowlarr does not need a separate debrid-specific layout. Keep the current ARR
guide's connections:

| App | URL from Prowlarr |
|---|---|
| Radarr | `http://127.0.0.1:7878` |
| Sonarr | `http://127.0.0.1:8989` |

Use Prowlarr tags or Radarr/Sonarr download-client priority if you want specific
indexers or release profiles to prefer debrid.

## Jellyfin And Seerr

Do not change Jellyfin library paths:

| Library | Path |
|---|---|
| Movies | `/media/movies` |
| TV Shows | `/media/tv` |
| Music | `/media/music` |

Jellyfin still reads only the final imported media directories. It should not
scan `/data/debrid`.

Seerr stays on normal Docker networking, as in the ARR guide. It talks to:

| Service | URL |
|---|---|
| Jellyfin | `http://jellyfin:8096` |
| Radarr | `http://192.168.1.20:7878` |
| Sonarr | `http://192.168.1.20:8989` |

## Security Notes

| Concern | Current-fit guidance |
|---|---|
| RDTClient UI | Keep LAN/private only. Do not expose publicly. |
| Debrid API keys | Keep in RDTClient config/appdata. Do not commit them. |
| VPN path | Recommended compose routes RDTClient through the qBittorrent PIA namespace. |
| Swarm exposure | Debrid provider joins/fetches from the swarm; your server downloads from provider HTTPS. |
| ISP visibility | ISP can see PIA traffic. If RDTClient is not VPN-routed, ISP may see debrid provider connections. |
| DNS | Keep the ARR guide's DNS leak checks. |
| Public access | Use Tailscale/private access first. Cloudflare Tunnel comes later only for Jellyfin/Seerr if needed. |
| Disk budget | Debrid can fill the local media pool quickly. Test retention rules before broad automation. |

Do not expose Radarr, Sonarr, Prowlarr, qBittorrent, RDTClient, Dockge, TrueNAS,
or Proxmox to the public internet.

Before enabling debrid automation, run the full
[ARR Stack Leak And Kill-Switch Test](arr-stack-leak-and-killswitch-test.md)
with `rdt-client` included in `ARR_VPN_SERVICES`. RDTClient should show a
PIA/VPN public IPv4 and should fail closed when the qBittorrent VPN tunnel is
dropped.

## Verification

After starting RDTClient:

```bash
cd /opt/stacks/arr-stack
docker compose ps rdt-client
docker logs --tail 100 rdt-client
docker exec rdt-client ls -la /data/debrid
docker exec rdt-client curl -4 -s https://ifconfig.me
docker exec radarr ls -la /data/debrid
docker exec sonarr ls -la /data/debrid
```

Expected results:

- RDTClient is running.
- `/data/debrid` exists inside RDTClient, Radarr, and Sonarr.
- If using the recommended shared VPN namespace, the RDTClient public IPv4 is a
  PIA/VPN IP, not your home WAN IP.

Then run one end-to-end test:

1. Add one legal/public-domain movie or episode.
2. Confirm RDTClient downloads under `/data/debrid/movies` or `/data/debrid/tv`.
3. Confirm Radarr/Sonarr imports into `/data/media/movies` or `/data/media/tv`.
4. Confirm Jellyfin scans the final imported file.
5. Confirm playback works locally.

Do not enable large wanted lists until this one-item test works.

## Troubleshooting

| Symptom | Check |
|---|---|
| Radarr cannot reach RDTClient | Use `127.0.0.1:6500` only when RDTClient shares qBittorrent's network namespace. |
| RDTClient UI is unavailable on LAN | If RDTClient shares qBittorrent's namespace, confirm `${DOCKER_IP}:6500:6500` is on the `qbittorrent` service ports. If RDTClient is in a separate compose project, confirm the port is published by `rdt-client` or its separate Gluetun gateway. |
| Imports fail with path errors | RDTClient download path must be `/data/debrid`, not an unmapped path such as `/downloads`. |
| Files import but duplicate disk usage | Confirm downloads and final media are under the same TrueNAS dataset and enable hardlinks in Radarr/Sonarr. |
| Provider rejects releases | Try another legal/public-domain test item, review provider filtering, or add a second provider. |
| RDTClient shows `429 Too Many Requests` | Stop retrying multiple failed items. Wait for the provider cooldown, reduce RDTClient/provider concurrency, then retry one item. |
| RDTClient shows 5-second HTTP timeouts or transport EOF | Check `docker logs --tail 100 debrid-gluetun` for DNS TLS resets. If present, switch the debrid Gluetun DNS mode to `doh`. |
| RDTClient shows home WAN IP | It is not using the shared VPN namespace; stop and fix compose before assuming privacy. |

## Deployment Checklist

For the first same-stack deployment:

- [ ] Base ARR stack works using the current ARR guide.
- [ ] `/mnt/media/data/debrid/{incomplete,movies,tv}` exists.
- [ ] `/mnt/main/appdata/arr-stack/rdt-client` exists.
- [ ] `6500` is published on the `qbittorrent` service.
- [ ] `rdt-client` uses `network_mode: "service:qbittorrent"`.
- [ ] RDTClient download path is `/data/debrid`.
- [ ] Radarr root folder remains `/data/media/movies`.
- [ ] Sonarr root folder remains `/data/media/tv`.
- [ ] Radarr/Sonarr connect to RDTClient as qBittorrent at `127.0.0.1:6500`.
- [ ] RDTClient public IPv4 is a PIA/VPN IP if using the recommended compose.
- [ ] One local end-to-end test succeeds before broad automation.

For the independent Gluetun debrid stack:

- [ ] Base ARR stack already works before adding independent debrid.
- [ ] `/opt/stacks/debrid-stack` exists.
- [ ] `/mnt/main/appdata/debrid-stack/rdt-client` exists.
- [ ] `/mnt/main/appdata/debrid-stack/gluetun` exists.
- [ ] The same `/mnt/media/data` host path is mounted as `/data`.
- [ ] RDTClient download path remains `/data/debrid`.
- [ ] Port `6500` is published by `debrid-gluetun`.
- [ ] `debrid-rdt-client` uses `network_mode: "service:gluetun"`.
- [ ] Radarr/Sonarr use `192.168.1.20:6500`, not `127.0.0.1:6500`, unless the services share a namespace.
- [ ] The independent debrid stack passes its own network and kill-switch tests.

## External References

- RDTClient: https://github.com/rogerfar/rdt-client
- Decypharr: https://i-am-puid-0.github.io/DMB/services/decypharr/
- Debrid services comparison: https://github.com/fynks/debrid-services-comparison
- TRaSH Guides: https://trash-guides.info/
