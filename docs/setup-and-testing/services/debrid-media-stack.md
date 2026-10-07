# Debrid Media Stack Setup And Testing

Setup for both debrid workflows: the independent RDTClient debrid stack (local-disk automation) and the Zurg/rclone cloud-first mount (streaming). For architecture and design rationale, see [Debrid Media Stack](../../services/debrid-media-stack.md).

## Part 1: Independent RDTClient Debrid Stack

Use this when the base ARR stack already works and debrid tooling should be able to stop/restart/rebuild independently of qBittorrent, Radarr, Sonarr, Prowlarr, and Jellyfin.

### Create Directories

Run on the **Ubuntu Docker VM**, not TrueNAS:

```bash
sudo -u mediauser mkdir -p /mnt/main/appdata/debrid-stack/rdt-client
sudo -u mediauser mkdir -p /mnt/main/appdata/debrid-stack/gluetun
sudo -u mediauser mkdir -p /mnt/media/data/debrid/incomplete
sudo -u mediauser mkdir -p /mnt/media/data/debrid/movies
sudo -u mediauser mkdir -p /mnt/media/data/debrid/tv
```

If pasted into the TrueNAS shell by mistake, stop and switch to the Docker VM:

```bash
ssh dockeradmin@192.168.1.20
findmnt /mnt/main
findmnt /mnt/media/data
id mediauser
```

Do not create `/mnt/media` manually on TrueNAS — `/mnt/media/data` there must come from the existing media pool/dataset.

### Create The Stack Files

```bash
sudo mkdir -p /opt/stacks/debrid-stack
sudo chown -R "$USER":"$USER" /opt/stacks/debrid-stack
cd /opt/stacks/debrid-stack
```

`.env`:

```env
PUID=3000
PGID=3000
TZ=Europe/Berlin
DOCKER_IP=192.168.1.20

CONFIG_PATH=/mnt/main/appdata/debrid-stack
DATA_PATH=/mnt/media/data

GLUETUN_VERSION=latest
RDTCLIENT_VERSION=latest

PIA_USER=p1234567
PIA_PASS=replace_with_your_pia_password
PIA_REGION=Netherlands
PIA_PORT_FORWARDING=off
```

`docker-compose.yml`:

```yaml
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
```

```bash
chmod 600 .env
docker compose config
```

RDTClient's port is published on `debrid-gluetun`, not on `rdt-client`, because RDTClient shares Gluetun's network namespace.

### Start

```bash
docker compose up -d gluetun
docker compose ps
docker logs --tail 150 debrid-gluetun
docker exec debrid-gluetun wget -qO- --timeout=15 https://ifconfig.me
```

The IPv4 must be a VPN IP, not the home WAN IP.

```bash
docker compose up -d rdt-client
docker compose ps
docker logs --tail 100 debrid-rdt-client
```

Open RDTClient from the LAN at `http://192.168.1.20:6500`.

Stop/restart only this stack without affecting the main ARR stack:

```bash
cd /opt/stacks/debrid-stack
docker compose stop
docker compose up -d
```

### Independent Stack Network Tests

```bash
HOME_WAN_IP="$(curl -4 -fsS --max-time 15 https://ifconfig.me)"
printf 'Home WAN IPv4: %s\n' "$HOME_WAN_IP"

cd /opt/stacks/debrid-stack
docker exec debrid-gluetun wget -qO- --timeout=15 https://ifconfig.me
```

Pass: `debrid-gluetun` returns a VPN IP, never `$HOME_WAN_IP`; RDTClient shares this namespace via `network_mode: "service:gluetun"`.

```bash
docker exec debrid-rdt-client sh -lc 'curl -4 -fsS --max-time 15 https://ifconfig.me || wget -qO- --timeout=15 https://ifconfig.me'
curl -fsS --max-time 10 http://192.168.1.20:6500 || wget -qO- --timeout=10 http://192.168.1.20:6500
```

Check whether Radarr/Sonarr can reach the independent stack (if they already moved to `arr-control-stack`; if they're still inside the qBittorrent VPN namespace, this is expected to time out):

```bash
cd /opt/stacks/arr-control-stack
docker exec radarr sh -lc 'curl -fsS --max-time 10 http://192.168.1.20:6500 || wget -qO- --timeout=10 http://192.168.1.20:6500' >/dev/null && echo "radarr can reach RDTClient"
docker exec sonarr sh -lc 'curl -fsS --max-time 10 http://192.168.1.20:6500 || wget -qO- --timeout=10 http://192.168.1.20:6500' >/dev/null && echo "sonarr can reach RDTClient"
```

If these time out, Radarr/Sonarr cannot reach the independent debrid stack from their current VPN namespace. Do not broadly loosen the VPN firewall — instead, keep RDTClient in the existing qBittorrent VPN namespace, or move Radarr/Sonarr into `arr-control-stack` on normal Docker networking so they can reach both `torrent-stack` and `debrid-stack` over LAN ports.

If the commands pass, add RDTClient in Radarr/Sonarr as a qBittorrent-type download client at `192.168.1.20:6500` with categories `movies`/`tv`, download path `/data/debrid`. No remote path mapping is needed if RDTClient reports paths under `/data/debrid` and Radarr/Sonarr see `/mnt/media/data` as `/data`.

### Independent Stack Kill-Switch Test

```bash
cd /opt/stacks/debrid-stack
docker stop debrid-gluetun

docker exec debrid-rdt-client sh -lc 'curl -4 -fsS --max-time 10 https://ifconfig.me && echo "LEAK: investigate" || echo "blocked or namespace unavailable as expected"' || echo "blocked or namespace unavailable as expected"
```

Pass: RDTClient cannot reach the internet while `debrid-gluetun` is stopped, and never returns the home WAN IP.

Restore:

```bash
docker compose up -d gluetun

for i in $(seq 1 60); do
  docker inspect -f '{{.State.Health.Status}}' debrid-gluetun 2>/dev/null | grep -q healthy && { echo "debrid-gluetun healthy"; break; }
  echo "waiting for debrid-gluetun health..."; sleep 2
done

docker compose up -d rdt-client
docker exec debrid-gluetun wget -qO- --timeout=15 https://ifconfig.me
```

## Part 2: Adding RDTClient Inside The Main ARR Stack (Alternative)

If isolating debrid into its own Compose project isn't needed yet, RDTClient can instead share qBittorrent's existing VPN namespace in `/opt/stacks/arr-stack`.

Create the staging directories:

```bash
sudo -u mediauser mkdir -p /mnt/media/data/debrid/incomplete
sudo -u mediauser mkdir -p /mnt/media/data/debrid/movies
sudo -u mediauser mkdir -p /mnt/media/data/debrid/tv
sudo -u mediauser mkdir -p /mnt/main/appdata/arr-stack/rdt-client
```

Add port `6500` to the existing `qbittorrent` service's `ports:` list:

```yaml
    ports:
      - "${DOCKER_IP}:8080:8080"
      - "${DOCKER_IP}:9696:9696"
      - "${DOCKER_IP}:7878:7878"
      - "${DOCKER_IP}:8989:8989"
      - "${DOCKER_IP}:6767:6767"
      - "${DOCKER_IP}:6500:6500"
```

Add the service:

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

```bash
cd /opt/stacks/arr-stack
docker compose config
docker compose up -d rdt-client
docker compose ps
```

Open `http://192.168.1.20:6500`.

### Configure Radarr And Sonarr

Because RDTClient shares qBittorrent's namespace here, Radarr/Sonarr reach it over `127.0.0.1`:

**Radarr** — root folder `/data/media/movies`; download client: Type `qBittorrent`, Name `RDTClient Debrid Movies`, Host `127.0.0.1`, Port `6500`, Category `movies`.

**Sonarr** — root folder `/data/media/tv`; download client: Type `qBittorrent`, Name `RDTClient Debrid TV`, Host `127.0.0.1`, Port `6500`, Category `tv`.

Keep the existing qBittorrent download client too if true torrenting is still wanted, with distinct names so grabs can be told apart.

### Verification

```bash
cd /opt/stacks/arr-stack
docker compose ps rdt-client
docker logs --tail 100 rdt-client
docker exec rdt-client ls -la /data/debrid
docker exec rdt-client curl -4 -s https://ifconfig.me
docker exec radarr ls -la /data/debrid
docker exec sonarr ls -la /data/debrid
```

Expected: RDTClient running; `/data/debrid` visible in RDTClient, Radarr, and Sonarr; RDTClient's public IPv4 is the VPN IP if sharing the qBittorrent VPN namespace.

Run one end-to-end test: add one legal/public-domain movie or episode, confirm RDTClient downloads under `/data/debrid/movies` or `/data/debrid/tv`, confirm Radarr/Sonarr imports into `/data/media/...`, confirm Jellyfin scans the final file, confirm local playback. Do not enable large wanted lists until this passes.

Before enabling broad debrid automation, run the full [ARR Stack leak and kill-switch test](arr-stack.md#leak-and-kill-switch-testing-hotio-vpn) with `rdt-client` included in `ARR_VPN_SERVICES`. RDTClient must show a VPN public IPv4 and fail closed when the VPN tunnel is dropped.

### Troubleshooting

| Symptom | Check |
|---|---|
| Radarr cannot reach RDTClient | Use `127.0.0.1:6500` only when RDTClient shares qBittorrent's namespace |
| RDTClient UI unavailable on LAN | If namespace-shared, confirm `${DOCKER_IP}:6500:6500` is on the `qbittorrent` service; if separate, confirm the port is published by `rdt-client` or its own Gluetun |
| Imports fail with path errors | RDTClient download path must be `/data/debrid`, not an unmapped path |
| Duplicate disk usage | Confirm downloads/media share a TrueNAS dataset and hardlinks are enabled |
| `429 Too Many Requests` | Stop retrying; wait for provider cooldown, reduce concurrency, retry one item |
| 5-second HTTP timeouts / transport EOF | Check `debrid-gluetun` logs for DNS TLS resets; switch DNS mode to `doh` if present |
| RDTClient shows home WAN IP | Not using the shared VPN namespace — fix Compose before assuming privacy |

## Part 3: Zurg/rclone Cloud-First Mount

Use when fast playback from a debrid library is wanted without downloading every file first. Keep separate from RDTClient/qBittorrent paths.

### Create Directories

```bash
sudo mkdir -p /opt/stacks/debrid-mount-stack
sudo chown -R "$USER":"$USER" /opt/stacks/debrid-mount-stack

sudo mkdir -p /mnt/main/appdata/debrid-mount-stack/zurg
sudo mkdir -p /mnt/main/appdata/debrid-mount-stack/rclone
sudo mkdir -p /mnt/debrid/zurg

sudo chown -R mediauser:mediauser /mnt/main/appdata/debrid-mount-stack
sudo chown -R mediauser:mediauser /mnt/debrid
```

Use the same UID/GID already used for media services if `mediauser` differs.

### Zurg Config

`/opt/stacks/debrid-mount-stack/config.yml`:

```yaml
zurg: v1
token: replace_with_real_debrid_token
check_for_changes_every_secs: 10
enable_repair: true
auto_delete_rar_torrents: true

directories:
  shows:
    group_order: 20
    group: media
    filters:
      - has_episodes: true

  movies:
    group_order: 30
    group: media
    only_show_the_biggest_file: true
    filters:
      - regex: /.*/
```

Never commit the real token to git. The public Zurg image is `zurg-testing`; the sponsor/private image is different — start with the public image unless deliberately choosing the sponsor release. Keep Zurg bound to the Docker VM LAN IP for the first Jellyfin-based setup; add WebDAV username/password only if later exposing Zurg to Tailscale clients directly.

### rclone Config

`/opt/stacks/debrid-mount-stack/rclone.conf` (rclone running in the same Compose project as Zurg):

```ini
[zurg]
type = webdav
url = http://zurg:9999/dav
vendor = other
pacer_min_sleep = 0
```

### Compose

`/opt/stacks/debrid-mount-stack/compose.yaml`:

```yaml
services:
  zurg:
    image: ghcr.io/debridmediamanager/zurg-testing:latest
    container_name: zurg
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "192.168.1.20:9999:9999"
    volumes:
      - ./config.yml:/app/config.yml:ro
      - /mnt/main/appdata/debrid-mount-stack/zurg:/app/data
    networks:
      - debrid-mount
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  rclone:
    image: rclone/rclone:latest
    container_name: zurg-rclone
    restart: unless-stopped
    environment:
      TZ: Europe/Berlin
      PUID: "3000"
      PGID: "3000"
    volumes:
      - /mnt/debrid/zurg:/data:rshared
      - ./rclone.conf:/config/rclone/rclone.conf:ro
      - /mnt/main/appdata/debrid-mount-stack/rclone:/cache
    cap_add:
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    devices:
      - /dev/fuse:/dev/fuse:rwm
    depends_on:
      - zurg
    command: >
      mount zurg: /data
      --allow-other
      --allow-non-empty
      --dir-cache-time 10s
      --poll-interval 10s
      --vfs-cache-mode full
      --vfs-cache-max-size 50G
      --vfs-cache-max-age 24h
      --cache-dir /cache
      --buffer-size 64M
      --log-level INFO
    networks:
      - debrid-mount
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  debrid-mount:
    name: debrid-mount
    driver: bridge
```

Adjust `192.168.1.20` to the real Docker VM IP, `PUID`/`PGID` to the media UID/GID, and `50G` to whatever fits the appdata pool. The rclone container needs FUSE access (`/dev/fuse`, `SYS_ADMIN`, `apparmor:unconfined`); keep this stack LAN-only.

### Start And Verify

```bash
cd /opt/stacks/debrid-mount-stack
docker compose config
docker compose up -d
docker compose ps

curl -fsS http://192.168.1.20:9999/dav/ | head
find /mnt/debrid/zurg -maxdepth 2 -type f | head -20
docker logs --tail 100 zurg
docker logs --tail 100 zurg-rclone
```

If `/mnt/debrid/zurg` is empty, add one legal/public-domain test item to the debrid account first and wait for Zurg to detect it.

### Jellyfin Integration

Add read-only mounts to the Jellyfin service:

```yaml
      - /mnt/debrid/zurg/movies:/media/debrid/movies:ro
      - /mnt/debrid/zurg/shows:/media/debrid/tv:ro
```

```bash
cd /opt/stacks/jellyfin-stack
docker compose up -d
```

In Jellyfin: add a movie library `Debrid Movies` pointed at `/media/debrid/movies`, add a TV library `Debrid TV` pointed at `/media/debrid/tv`, disable aggressive real-time monitoring if scans cause provider/API churn, and run one manual scan.

### Infuse On iPhone

In Infuse: add a media server, choose Jellyfin, use the LAN or Tailscale Jellyfin URL (`http://docker-vm-tailnet-name:8096`), sign in, let it index/sync. Only expose Jellyfin publicly later as a deliberate choice.

Alternative direct-WebDAV path (LAN/Tailscale testing only, never exposed publicly): point Infuse at `http://192.168.1.20:9999/dav`.

### Verification Checklist

- [ ] Existing torrent stack still routes qBittorrent through its VPN.
- [ ] Existing RDTClient debrid stack still works or is intentionally stopped.
- [ ] `debrid-mount-stack` starts independently.
- [ ] Zurg WebDAV responds on LAN only.
- [ ] `/mnt/debrid/zurg` lists one legal/public-domain test item.
- [ ] Jellyfin has separate `Debrid Movies` and `Debrid TV` libraries.
- [ ] Infuse connects to Jellyfin and plays one test item.
- [ ] Remote playback uses Tailscale before any public exposure.

### Troubleshooting

| Symptom | Check |
|---|---|
| RDTClient is slow | Compare VPN-routed speed against Docker VM direct speed; try a different VPN region |
| Zurg WebDAV works but mount is empty | Check `rclone.conf`, Zurg token, and whether the debrid library has test content |
| Jellyfin sees folders but no playback | Check permissions and that the rclone mount is still active |
| Playback buffers in Infuse | Test direct Jellyfin web playback, increase rclone VFS cache size, or avoid VPN for Zurg |
| Jellyfin scan very slow | Split movies/shows, reduce scan frequency, keep mounted library separate |
| Mount disappears after reboot | Start `debrid-mount-stack` before Jellyfin, or restart Jellyfin after the mount is ready |
| Permission denied from rclone | Check `/dev/fuse`, `SYS_ADMIN`, `apparmor:unconfined`, and `/mnt/debrid` ownership |
| Account complains about multiple IPs | Avoid simultaneous direct and VPN streams for the same debrid account |

## External References

- [RDTClient](https://github.com/rogerfar/rdt-client)
- [Zurg](https://github.com/debridmediamanager/zurg-testing)
- [rclone mount](https://rclone.org/commands/rclone_mount/)
- [Jellyfin Docker/container docs](https://jellyfin.org/docs/general/installation/container/)
- [TRaSH Guides](https://trash-guides.info/)
