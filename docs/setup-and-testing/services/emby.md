# Emby Setup And Testing

Adds Emby as an additional media server at `https://emby.example.com` through Traefik, without touching the existing Jellyfin deployment. See [docs/services/emby.md](../../services/emby.md) for the resulting architecture.

Do this after:

1. SSL/TLS for the homestack with Traefik and Cloudflare.
2. The ARR stack / local-first media setup.
3. The Jellyfin Intel iGPU passthrough guide, if you want Quick Sync in Emby too.

## Step 1: SSH to the Docker VM

```bash
ssh <docker-vm-user>@192.168.1.20
```

Set helper variables:

```bash
export DOMAIN="example.com"
export EMBY_HOST="emby.${DOMAIN}"
export EMBY_DIR="/opt/stacks/emby-stack"
export EMBY_CONFIG="/srv/appdata/emby"
export DATA_PATH="/mnt/media/data"
```

Confirm baseline:

```bash
hostname
docker --version
docker compose version
findmnt -T /mnt/media/data
findmnt -T /srv/appdata
id mediauser
```

Expect Docker working, `/mnt/media/data` as the TrueNAS media mount, `/srv/appdata` as local storage, and `mediauser` existing (normally UID/GID `3000:3000`).

## Step 2: Confirm Traefik and the proxy network

```bash
cd /opt/docker/traefik
docker compose ps
docker compose logs --tail=100 traefik
docker network inspect proxy >/dev/null && echo "OK: proxy network exists"
```

Expect `traefik` and `socket-proxy` running, the `proxy` network present, and no Cloudflare DNS challenge errors in the logs.

## Step 3: Create Emby directories

```bash
sudo mkdir -p "$EMBY_DIR" "$EMBY_CONFIG"
sudo chown -R "$USER":"$USER" "$EMBY_DIR"
sudo chown -R 3000:3000 "$EMBY_CONFIG"

sudo -u mediauser test -r "$DATA_PATH/media/movies" && echo "movies readable"
sudo -u mediauser test -r "$DATA_PATH/media/tv" && echo "tv readable"
sudo -u mediauser test -r "$DATA_PATH/media/music" && echo "music readable"
```

Create any missing media directories as `mediauser`:

```bash
sudo -u mediauser mkdir -p /mnt/media/data/media/movies /mnt/media/data/media/tv /mnt/media/data/media/music
```

## Step 4: Create the Emby environment file

```bash
cd "$EMBY_DIR"
nano .env
```

```text
DOMAIN=example.com
TZ=Europe/Berlin
EMBY_UID=3000
EMBY_GID=3000
GIDLIST=44,991
EMBY_CONFIG=/srv/appdata/emby
DATA_PATH=/mnt/media/data
```

`EMBY_UID`/`EMBY_GID` map to Emby's official `UID`/`GID` container variables — do not use `PUID`/`PGID`. `GIDLIST` should contain the numeric `video`/`render` groups that own `/dev/dri`; verify with:

```bash
getent group video
getent group render
```

If you're not using hardware transcoding yet, `GIDLIST=44,991` is harmless to leave in place — it has no effect unless the compose file also mounts `/dev/dri`.

## Step 5: Create the Docker Compose file

```bash
nano docker-compose.yml
```

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

There is intentionally no `ports:` section and no `network_mode: host`. If `/dev/dri` does not exist yet, remove the `devices:` block temporarily and add it back once GPU passthrough works.

## Step 6: Validate and start Emby

```bash
cd "$EMBY_DIR"
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=100 emby
```

Check mounts and port bindings:

```bash
docker inspect emby --format '{{range .Mounts}}{{println .Source "->" .Destination "RW=" .RW}}{{end}}'
docker inspect emby --format '{{json .HostConfig.PortBindings}}'
```

Expect the four bind mounts (config RW=true, media RW=false) and `null` or `{}` for port bindings (no raw host ports).

## Step 7: Add local DNS

In Pi-hole, **Local DNS → DNS Records**, add `emby.example.com -> 192.168.1.20`. From a LAN client:

```bash
nslookup emby.example.com
curl -I https://emby.example.com
```

Expect DNS to resolve on LAN and a trusted Let's Encrypt cert from Traefik (not a `404`). If local DNS isn't ready yet, test with SNI from the Docker VM instead:

```bash
curl -kI --resolve "${EMBY_HOST}:443:192.168.1.20" "https://${EMBY_HOST}/"
```

## Step 8: Complete the Emby first-run setup

Open `https://emby.example.com`, create the first admin user, and add libraries:

| Library | Emby folder |
|---|---|
| Movies | `/media/movies` |
| TV Shows | `/media/tv` |
| Music | `/media/music` |

Use a strong unique admin password, create non-admin accounts for watching, disable remote access for users who don't need it, match metadata language/country to the Jellyfin setup, and leave automatic port mapping/UPnP disabled. If Emby prompts about remote access, remember Traefik is the access path — do not open router ports directly to Emby.

## Step 9: Configure hardware transcoding

Only after the Intel iGPU passthrough guide works. Confirm the device:

```bash
ls -l /dev/dri
docker exec emby ls -l /dev/dri
docker exec emby id
```

In Emby, **Dashboard → Playback → Transcoding**:

| Option | Value |
|---|---|
| Hardware acceleration | Advanced or VAAPI |
| VAAPI device | `/dev/dri/renderD128` |
| Hardware decoding | H.264, HEVC, MPEG-2, VC-1, VP8, VP9 |
| AV1 decoding | Disabled |
| Hardware encoding | Enabled |
| Tone mapping | Disabled initially |

## Step 10: Back up Emby

```bash
sudo -u mediauser mkdir -p /mnt/main/backups/docker-volumes/emby

cd "$EMBY_DIR"
docker compose stop emby
sudo tar --xattrs --acls \
  -czf "/mnt/main/backups/docker-volumes/emby/emby-config-$(date +%F-%H%M).tar.gz" \
  -C /srv/appdata emby
docker compose start emby

ls -lh /mnt/main/backups/docker-volumes/emby
sudo tar -tzf /mnt/main/backups/docker-volumes/emby/emby-config-YYYY-MM-DD-HHMM.tar.gz | head
```

## Step 11: Optional public access via Cloudflare Tunnel

Only after local HTTPS, login, playback, backups, and user permissions all work. Reuse the Jellyfin Cloudflare Tunnel and add a second public hostname:

`Zero Trust -> Networks -> Tunnels -> homestack-docker-vm -> Public Hostnames -> Add a public hostname`

| Field | Value |
|---|---|
| Subdomain | `emby` |
| Domain | `example.com` |
| Type | `HTTPS` |
| URL | `traefik:443` |
| HTTP Host Header | `emby.example.com` |
| Origin Server Name | `emby.example.com` |
| No TLS Verify | off |

Add a Cloudflare cache rule: bypass cache when hostname equals `emby.example.com`. Never forward router ports `8096`/`8920` directly to Emby.

## Step 12: Safety checks

```bash
docker ps --format 'table {{.Names}}\t{{.Ports}}'
sudo ss -tulpn | grep -E ':(80|443|8096|8920)\b'
docker network inspect proxy --format '{{range $id,$c := .Containers}}{{println $c.Name}}{{end}}' | sort

docker inspect emby --format 'Privileged={{.HostConfig.Privileged}} SecurityOpt={{json .HostConfig.SecurityOpt}}'
docker inspect emby --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' | grep -E 'docker.sock|/var/run' || echo "OK: no Docker socket mount"
```

Expect Traefik publishing `80`/`443` only, Emby publishing nothing and attached only to `proxy`, `Privileged=false`, and no Docker socket mount.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Traefik returns 404 | Wrong `DOMAIN` in `.env`; Emby not on `proxy` network; router rule not matching `emby.example.com`. Check `docker inspect emby --format '{{json .Config.Labels}}'` and `docker network inspect proxy`. |
| Traefik returns 502/504 | Emby still starting; `/config` permission error; wrong Traefik service port. Check `docker compose logs --tail=100 emby`. |
| Browser certificate warning | LAN DNS not pointing to `192.168.1.20`; Traefik hasn't issued a cert yet; wrong/expired Cloudflare API token; placeholder domain still in `traefik.yml`. Check `docker compose logs --tail=200 traefik \| grep -i -E 'acme\|certificate\|cloudflare\|error'`. |
| Emby cannot see media | TrueNAS NFS mount missing; media folders not created; folders not readable by UID/GID `3000:3000`. Check `docker exec emby ls -la /media*`. |
| Hardware transcoding fails | iGPU not passed through to VM `111`; compose missing `/dev/dri` mount; `GIDLIST` missing `video`/`render`; wrong render device selected in Emby. |

## Pass/fail checklist

| Check | Pass condition |
|---|---|
| Traefik | `traefik` and `socket-proxy` running |
| Proxy network | `proxy` exists and Emby joins it |
| Local DNS | `emby.example.com` resolves to `192.168.1.20` on LAN |
| HTTPS | Loads without certificate warning |
| Raw ports | Emby publishes no host ports |
| Media mounts | Read-only |
| Config mount | `/srv/appdata/emby` maps to `/config` |
| Users | Watching uses non-admin accounts |
| UPnP | Not auto-opened |
| Docker socket | Not mounted |
| Backup | `/srv/appdata/emby` covered by VM backup + TrueNAS copy |
| Public access | Points at `https://traefik:443`, never directly at Emby |

## References

- Emby Linux server install: <https://emby.media/linux-server.html>
- Emby Docker image: <https://hub.docker.com/r/emby/embyserver>
