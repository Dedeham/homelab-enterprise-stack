# Emby With Traefik And Your Domain

Last updated: 2026-06-23

This guide adds Emby as an additional media server at
`https://emby.example.com` while keeping Jellyfin untouched. It follows the
current homestack rules:

- Docker services run on the Ubuntu Docker VM at `192.168.1.20`.
- Traefik is the only HTTPS entrypoint.
- Local access comes first through Pi-hole split DNS.
- Public access, if needed, comes later through Cloudflare Tunnel.
- Media stays on TrueNAS under `/mnt/media/data`.
- Active application databases stay on local Docker VM storage under
  `/srv/appdata`.

Use this after:

1. [SSL/TLS For The Homestack With Traefik And Cloudflare](../networking/ssl-traefik-cloudflare-guide.md)
2. [ARR Stack Local-First Homelab Setup](arr-stack-homelab-fit-review-and-setup.md)
3. [Jellyfin Intel iGPU Passthrough And Local Appdata Guide](jellyfin-intel-igpu-passthrough-and-local-appdata-guide.md), if you want Intel Quick Sync

## Current Homestack Values

Replace only if your live values differ.

| Item | Value |
|---|---|
| Docker VM SSH user | `alice` |
| Docker VM IP | `192.168.1.20` |
| Docker VM | VM `111` |
| Traefik stack path | `/opt/docker/traefik` |
| Emby stack path | `/opt/stacks/emby-stack` |
| Emby config path | `/srv/appdata/emby` |
| Media data root | `/mnt/media/data` |
| Movies path | `/mnt/media/data/media/movies` |
| TV path | `/mnt/media/data/media/tv` |
| Music path | `/mnt/media/data/media/music` |
| Container UID/GID | `3000:3000` |
| Shared Docker proxy network | `proxy` |
| Emby hostname | `emby.example.com` |
| Emby internal HTTP port | `8096` |

Do not reuse `media.example.com` if Jellyfin already owns it. Use
`emby.example.com` so both services can run side by side.

## Security Position

Default decision:

- Do not publish Emby host ports `8096` or `8920`.
- Do not use Docker `network_mode: host` for this Traefik setup.
- Do not place Emby behind the torrent/VPN container network.
- Mount media libraries read-only.
- Use a separate Emby account for each person.
- Keep the admin account for administration only.
- Do not put Authelia in front of Emby by default unless every Emby client you
  use works with that extra login layer.

The official Emby Docker examples often show host networking and direct port
publishing because that helps DLNA and Wake-on-LAN. This guide intentionally
uses bridge networking because the goal is domain access through Traefik.

## Step 1: SSH To The Docker VM

From your workstation:

```bash
ssh alice@192.168.1.20
```

Set helper variables on the Docker VM:

```bash
export DOMAIN="example.com"
export EMBY_HOST="emby.${DOMAIN}"
export EMBY_DIR="/opt/stacks/emby-stack"
export EMBY_CONFIG="/srv/appdata/emby"
export DATA_PATH="/mnt/media/data"
```

Confirm the baseline:

```bash
hostname
docker --version
docker compose version
findmnt -T /mnt/media/data
findmnt -T /srv/appdata
id mediauser
```

Expected:

- Docker works.
- `/mnt/media/data` is the TrueNAS media mount.
- `/srv/appdata` is local Docker VM storage.
- `mediauser` exists, normally as UID/GID `3000:3000`.

## Step 2: Confirm Traefik And The Proxy Network

```bash
cd /opt/docker/traefik
docker compose ps
docker compose logs --tail=100 traefik
docker network inspect proxy >/dev/null && echo "OK: proxy network exists"
```

Expected:

- `traefik` is running.
- `socket-proxy` is running.
- The `proxy` Docker network exists.
- Traefik logs do not show Cloudflare DNS challenge errors.

## Step 3: Create Emby Directories

The Emby database, metadata, logs, and cache should live on local VM storage,
not on NFS. The media library remains on TrueNAS.

```bash
sudo mkdir -p "$EMBY_DIR" "$EMBY_CONFIG"
sudo chown -R "$USER":"$USER" "$EMBY_DIR"
sudo chown -R 3000:3000 "$EMBY_CONFIG"

sudo -u mediauser test -r "$DATA_PATH/media/movies" && echo "movies readable"
sudo -u mediauser test -r "$DATA_PATH/media/tv" && echo "tv readable"
sudo -u mediauser test -r "$DATA_PATH/media/music" && echo "music readable"
```

If one media directory is missing because you do not use that library yet,
create it from the Docker VM as `mediauser`:

```bash
sudo -u mediauser mkdir -p \
  /mnt/media/data/media/movies \
  /mnt/media/data/media/tv \
  /mnt/media/data/media/music
```

## Step 4: Create The Emby Environment File

```bash
cd "$EMBY_DIR"
nano .env
```

Put this in `.env`:

```text
DOMAIN=example.com
TZ=Europe/Berlin
EMBY_UID=3000
EMBY_GID=3000
GIDLIST=44,991
EMBY_CONFIG=/srv/appdata/emby
DATA_PATH=/mnt/media/data
```

Notes:

- `EMBY_UID` and `EMBY_GID` are compose interpolation variables. The compose
  file passes them into the container as Emby's official `UID` and `GID`
  environment variables.
- Do not use `PUID` and `PGID` for the official Emby image.
- `GIDLIST` should include the numeric groups that can access `/dev/dri`.
- On the tested Docker VM, `video` was `44` and `render` was `991`.
- Verify your values with:

```bash
getent group video
getent group render
```

If you are not using hardware transcoding yet, you can leave `GIDLIST=44,991`
in place. It does not expose the GPU unless the compose file also mounts
`/dev/dri`.

## Step 5: Create The Docker Compose File

Create:

```bash
nano docker-compose.yml
```

Use this compose file:

```yaml
services:
  emby:
    image: emby/embyserver:latest
    container_name: emby
    restart: unless-stopped
    environment:
      UID: "${EMBY_UID}"
      GID: "${EMBY_GID}"
      GIDLIST: "${GIDLIST}"
      TZ: "${TZ}"
    volumes:
      - ${EMBY_CONFIG}:/config
      - ${DATA_PATH}/media/movies:/media/movies:ro
      - ${DATA_PATH}/media/tv:/media/tv:ro
      - ${DATA_PATH}/media/music:/media/music:ro
    devices:
      - /dev/dri:/dev/dri
    security_opt:
      - no-new-privileges:true
    networks:
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.emby.rule=Host(`emby.${DOMAIN}`)"
      - "traefik.http.routers.emby.entrypoints=websecure"
      - "traefik.http.routers.emby.tls.certresolver=cloudflare"
      - "traefik.http.routers.emby.middlewares=security-headers@file,rate-limit@file"
      - "traefik.http.services.emby.loadbalancer.server.port=8096"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  proxy:
    external: true
```

Important:

- There is no `ports:` section.
- There is no `network_mode: host`.
- Traefik reaches Emby on container port `8096`.
- The `8920` HTTPS port is not needed because Traefik handles HTTPS.

If `/dev/dri` does not exist yet, remove the `devices:` block temporarily and
add it back after GPU passthrough is working.

## Step 6: Validate And Start Emby

```bash
cd "$EMBY_DIR"
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=100 emby
```

Expected:

- The rendered Traefik rule uses `emby.example.com`.
- The `emby` container starts.
- The logs do not show permission errors for `/config`.

Check mounts:

```bash
docker inspect emby \
  --format '{{range .Mounts}}{{println .Source "->" .Destination "RW=" .RW}}{{end}}'
```

Expected:

```text
/srv/appdata/emby -> /config RW= true
/mnt/media/data/media/movies -> /media/movies RW= false
/mnt/media/data/media/tv -> /media/tv RW= false
/mnt/media/data/media/music -> /media/music RW= false
```

Confirm Emby has no raw host port publishing:

```bash
docker inspect emby --format '{{json .HostConfig.PortBindings}}'
```

Expected:

```text
null
```

or:

```text
{}
```

## Step 7: Add Local DNS

In Pi-hole:

```text
Local DNS -> DNS Records
```

Add:

```text
emby.example.com -> 192.168.1.20
```

Then test from a LAN client:

```bash
nslookup emby.example.com
curl -I https://emby.example.com
```

Expected:

- DNS returns `192.168.1.20` on LAN.
- HTTPS uses a trusted Let's Encrypt certificate from Traefik.
- The response is from Emby, not a Traefik `404`.

If local DNS is not ready yet, test from the Docker VM with SNI:

```bash
curl -kI --resolve "${EMBY_HOST}:443:192.168.1.20" "https://${EMBY_HOST}/"
```

## Step 8: Complete The Emby First-Run Setup

Open:

```text
https://emby.example.com
```

Create the first admin user and add libraries:

| Library | Emby folder |
|---|---|
| Movies | `/media/movies` |
| TV Shows | `/media/tv` |
| Music | `/media/music` |

Recommended first-run settings:

- Use a strong unique admin password.
- Create non-admin user accounts for watching.
- Disable remote access for users who do not need it.
- Keep metadata language and country consistent with your Jellyfin setup.
- Do not enable automatic port mapping or UPnP.

If Emby asks about remote access, remember that Traefik is the access path.
Do not open router ports directly to Emby.

## Step 9: Configure Hardware Transcoding

Only do this after the Intel iGPU passthrough guide is working.

Confirm the device exists:

```bash
ls -l /dev/dri
docker exec emby ls -l /dev/dri
docker exec emby id
```

Expected:

- `/dev/dri/renderD128` exists on the Docker VM.
- `/dev/dri/renderD128` is visible inside the Emby container.
- The Emby process has the numeric `video` and `render` group IDs through
  `GIDLIST`.

In Emby:

```text
Dashboard -> Playback -> Transcoding
```

Recommended starting point for Intel P630:

| Option | Value |
|---|---|
| Hardware acceleration | Advanced or VAAPI, depending on Emby UI options |
| VAAPI device | `/dev/dri/renderD128` |
| Hardware decoding | Enable H.264, HEVC, MPEG-2, VC-1, VP8, VP9 |
| AV1 decoding | Disabled |
| Hardware encoding | Enabled |
| Tone mapping | Disabled initially |

Start conservative. After one known-good transcode works, adjust quality and
tone mapping settings if needed.

## Step 10: Back Up Emby

Because `/srv/appdata/emby` is local VM storage, protect it in two ways:

1. Include the Docker VM in Proxmox backups.
2. Copy an application backup to TrueNAS.

Manual backup:

```bash
sudo -u mediauser mkdir -p /mnt/main/backups/docker-volumes/emby

cd "$EMBY_DIR"
docker compose stop emby
sudo tar --xattrs --acls \
  -czf "/mnt/main/backups/docker-volumes/emby/emby-config-$(date +%F-%H%M).tar.gz" \
  -C /srv/appdata emby
docker compose start emby
```

Verify:

```bash
ls -lh /mnt/main/backups/docker-volumes/emby
sudo tar -tzf /mnt/main/backups/docker-volumes/emby/emby-config-YYYY-MM-DD-HHMM.tar.gz | head
```

Do not rely only on the anonymous container filesystem. Emby state belongs in
the visible bind mount `/srv/appdata/emby`.

## Step 11: Optional Public Access Through Cloudflare Tunnel

Do this only after local HTTPS, login, playback, backups, and user permissions
are working.

If you already created the Cloudflare Tunnel from the Jellyfin public access
guide, reuse the same tunnel and add a second public hostname.

In Cloudflare:

```text
Zero Trust -> Networks -> Tunnels -> homestack-docker-vm -> Public Hostnames -> Add a public hostname
```

Set:

| Field | Value |
|---|---|
| Subdomain | `emby` |
| Domain | `example.com` |
| Path | blank |
| Type | `HTTPS` |
| URL | `traefik:443` |

Additional settings:

| Setting | Value |
|---|---|
| HTTP Host Header | `emby.example.com` |
| Origin Server Name | `emby.example.com` |
| No TLS Verify | off |

Create a Cloudflare cache rule:

```text
Rule name: Bypass cache for Emby
If: Hostname equals emby.example.com
Then: Bypass cache
```

Do not expose Emby by forwarding router ports `8096` or `8920`.

## Step 12: Safety Checks

Run on the Docker VM:

```bash
docker ps --format 'table {{.Names}}\t{{.Ports}}'
sudo ss -tulpn | grep -E ':(80|443|8096|8920)\b'
docker network inspect proxy \
  --format '{{range $id,$c := .Containers}}{{println $c.Name}}{{end}}' \
  | sort
```

Expected:

- Traefik may publish `80` and `443`.
- Emby does not publish `8096` or `8920`.
- Emby is attached to the `proxy` network.
- Emby is not attached to a torrent VPN network.

Check privilege posture:

```bash
docker inspect emby \
  --format 'Privileged={{.HostConfig.Privileged}} SecurityOpt={{json .HostConfig.SecurityOpt}}'

docker inspect emby \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' \
  | grep -E 'docker.sock|/var/run' || echo "OK: no Docker socket mount"
```

Expected:

```text
Privileged=false
OK: no Docker socket mount
```

## Troubleshooting

### Traefik returns 404

Traefik is reachable, but no router matched the hostname.

Check:

```bash
docker inspect emby --format '{{json .Config.Labels}}'
docker network inspect proxy
```

Likely causes:

- `.env` has the wrong `DOMAIN`.
- Emby is not on the `proxy` network.
- The router rule is not set to `Host` for `emby.example.com`.

### Traefik returns 502 or 504

The router matched, but Traefik cannot reach Emby.

Check:

```bash
cd /opt/stacks/emby-stack
docker compose ps
docker compose logs --tail=100 emby
```

Likely causes:

- Emby is still starting.
- The container is unhealthy due to `/config` permissions.
- The Traefik service port is not `8096`.

### Browser certificate warning

Check:

```bash
nslookup emby.example.com
cd /opt/docker/traefik
docker compose logs --tail=200 traefik | grep -i -E 'acme|certificate|cloudflare|error'
```

Likely causes:

- LAN DNS does not point `emby.example.com` to `192.168.1.20`.
- Traefik has not issued a certificate yet.
- The Cloudflare DNS API token is wrong or expired.
- `traefik.yml` still contains placeholder domain values.

### Emby cannot see media

Check:

```bash
sudo -u mediauser ls -la /mnt/media/data/media
docker exec emby ls -la /media
docker exec emby ls -la /media/movies
docker exec emby ls -la /media/tv
docker exec emby ls -la /media/music
```

Likely causes:

- The TrueNAS NFS mount is missing.
- The media folders were not created.
- The media folders are not readable by UID/GID `3000:3000`.

### Hardware transcoding does not work

Check:

```bash
ls -l /dev/dri
getent group video
getent group render
docker exec emby ls -l /dev/dri
docker exec emby id
```

Likely causes:

- The iGPU is not passed through to VM `111`.
- The compose file does not mount `/dev/dri`.
- `GIDLIST` does not include the numeric `video` or `render` group.
- Emby transcoding settings point to the wrong render device.

## Pass/Fail Checklist

Do not consider the Emby setup complete until all pass.

| Check | Pass condition |
|---|---|
| Traefik | `traefik` and `socket-proxy` are running |
| Proxy network | `proxy` exists and Emby joins it |
| Local DNS | `emby.example.com` resolves to `192.168.1.20` on LAN |
| HTTPS | `https://emby.example.com` loads without certificate warning |
| Raw ports | Emby publishes no host ports |
| Media mounts | Movies, TV, and music mounts are read-only |
| Config mount | `/srv/appdata/emby` maps to `/config` |
| Users | Watching uses non-admin accounts |
| UPnP | Emby does not auto-open router ports |
| Docker socket | Emby does not mount Docker socket |
| Backup | `/srv/appdata/emby` is covered by VM backup and a TrueNAS copy |
| Public access | If enabled, Cloudflare Tunnel points to `https://traefik:443`, not directly to Emby |

## References

- Emby Linux server install page: <https://emby.media/linux-server.html>
- Emby Docker image: <https://hub.docker.com/r/emby/embyserver>
- Homestack Traefik and Cloudflare TLS guide: [../networking/ssl-traefik-cloudflare-guide.md](../networking/ssl-traefik-cloudflare-guide.md)
- Jellyfin public access pattern to reuse for Emby: [../networking/jellyfin-cloudflare-tunnel-public-access-guide.md](../networking/jellyfin-cloudflare-tunnel-public-access-guide.md)
