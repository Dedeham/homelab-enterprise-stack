# Bitmagnet Setup And Testing

Setup for adding Bitmagnet to the independent debrid stack and connecting it to Prowlarr, plus the Gluetun IP-leak/kill-switch test for its network namespace. For architecture and current configuration, see [Bitmagnet](../../services/bitmagnet.md).

This builds on an already-deployed debrid stack (see [Debrid Media Stack Setup And Testing](debrid-media-stack.md)).

## Phase 1: Back Up And Check The Current Stack

```bash
ssh dockeradmin@192.168.1.20
cd /opt/stacks/debrid-stack
docker compose ps

HOME_WAN_IP="$(curl -4 -fsS --max-time 15 https://ifconfig.me/ip)"
GLUETUN_IP="$(docker exec debrid-gluetun wget -qO- --timeout=15 https://ifconfig.me/ip)"
printf 'Home WAN IP: %s\nGluetun IP: %s\n' "$HOME_WAN_IP" "$GLUETUN_IP"
test "$HOME_WAN_IP" != "$GLUETUN_IP" && echo "Gluetun uses a different public IP" || echo "STOP: Gluetun matches the home WAN IP"
```

Use the `/ip` endpoint exactly as shown — requesting the plain `ifconfig.me` homepage with `wget` returns HTML, not a single address.

Record RDTClient's network mode before editing anything — it must not report `container:<debrid-gluetun-id>`, and this guide never changes RDTClient's `network_mode`, `networks`, or published port:

```bash
docker inspect -f '{{.HostConfig.NetworkMode}}' debrid-rdt-client
```

Confirm `/srv/appdata` is local ext4, not NFS:

```bash
findmnt -T /srv/appdata
df -h /srv/appdata
```

Back up the working files:

```bash
cd /opt/stacks/debrid-stack
cp -a docker-compose.yml docker-compose.before-bitmagnet.yml
cp -a .env .env.before-bitmagnet
```

## Phase 2: Create Local Appdata

```bash
sudo mkdir -p /srv/appdata/bitmagnet/config
sudo mkdir -p /srv/appdata/bitmagnet/postgres
sudo chmod 700 /srv/appdata/bitmagnet
```

Do not assign these to the `mediauser` UID/GID by default — Bitmagnet and PostgreSQL use their own image users and don't need media-dataset access. If a container reports a permission error, inspect its actual runtime UID before changing ownership:

```bash
docker run --rm --entrypoint id ghcr.io/bitmagnet-io/bitmagnet:v0.10.0
docker run --rm --entrypoint id postgres:16-alpine
```

## Phase 3: Add Environment Values

```bash
openssl rand -hex 32   # generate a PostgreSQL password
```

Edit `/opt/stacks/debrid-stack/.env` and add:

```env
BITMAGNET_VERSION=v0.10.0
BITMAGNET_POSTGRES_VERSION=16-alpine
BITMAGNET_POSTGRES_PASSWORD=REPLACE_WITH_THE_GENERATED_PASSWORD
BITMAGNET_TMDB_API_KEY=
```

Check Bitmagnet's release notes before changing the pinned version. A personal TMDB API key is optional.

```bash
chmod 600 /opt/stacks/debrid-stack/.env
```

## Phase 4: Extend The Debrid Compose File

Edit `/opt/stacks/debrid-stack/docker-compose.yml`.

### Publish Bitmagnet Through Debrid Gluetun

Add only the new port to the existing Gluetun `ports:` list — keep any ports already published there; RDTClient's `6500` stays published by the `rdt-client` service itself:

```yaml
    ports:
      - "${DOCKER_IP}:3333:3333"
```

Port `3333` serves both the WebUI and Torznab endpoint. Never publish PostgreSQL's `5432`, and never publish Bitmagnet's DHT port `3334` on the Docker VM — a LAN-bound host port there creates no useful incoming connectivity through PIA while outbound DHT crawling already works through the VPN. Do not add `FIREWALL_INPUT_PORTS`; Gluetun's documented sidecar pattern only needs the shared-container port published on the Gluetun service.

### Add Bitmagnet

```yaml
  bitmagnet:
    image: ghcr.io/bitmagnet-io/bitmagnet:${BITMAGNET_VERSION}
    container_name: debrid-bitmagnet
    restart: unless-stopped
    network_mode: "service:gluetun"
    environment:
      - POSTGRES_HOST=bitmagnet-postgres
      - POSTGRES_NAME=bitmagnet
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=${BITMAGNET_POSTGRES_PASSWORD}
      # Add only after setting a personal key in .env:
      # - TMDB_API_KEY=${BITMAGNET_TMDB_API_KEY}
    volumes:
      - /srv/appdata/bitmagnet/config:/root/.config/bitmagnet
    command:
      - worker
      - run
      - --keys=http_server
      - --keys=queue_server
      - --keys=dht_crawler
    depends_on:
      gluetun:
        condition: service_healthy
      bitmagnet-postgres:
        condition: service_healthy
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

Leave the `TMDB_API_KEY` line commented while the `.env` value is empty — passing an empty value overrides Bitmagnet's built-in shared default key.

### Add PostgreSQL

```yaml
  bitmagnet-postgres:
    image: postgres:${BITMAGNET_POSTGRES_VERSION}
    container_name: debrid-bitmagnet-postgres
    restart: unless-stopped
    shm_size: 1g
    environment:
      - POSTGRES_DB=bitmagnet
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=${BITMAGNET_POSTGRES_PASSWORD}
      - PGUSER=postgres
    volumes:
      - /srv/appdata/bitmagnet/postgres:/var/lib/postgresql/data
    networks:
      - debrid
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d bitmagnet"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

### Validate

```bash
cd /opt/stacks/debrid-stack
docker compose config --quiet
docker compose config | grep -A10 -E '^  bitmagnet:|^  bitmagnet-postgres:'
```

## Phase 5: Start Bitmagnet

```bash
cd /opt/stacks/debrid-stack
docker compose pull bitmagnet bitmagnet-postgres
docker compose up -d gluetun   # recreate so port 3333 is published; does not interrupt RDTClient

for i in $(seq 1 60); do
  docker inspect -f '{{.State.Health.Status}}' debrid-gluetun 2>/dev/null | grep -q healthy && { echo "debrid Gluetun is healthy"; break; }
  sleep 2
done

docker compose up -d bitmagnet-postgres bitmagnet
docker compose ps
docker compose logs -f --tail=150 bitmagnet-postgres bitmagnet
```

## Phase 6: Verify VPN And Torznab

```bash
docker exec debrid-bitmagnet curl -4 -fsS --max-time 15 https://ifconfig.me/ip
docker exec debrid-gluetun wget -qO- --timeout=15 https://ifconfig.me/ip
```

Both must match and be the VPN address, not the home WAN address. Do not use RDTClient's IP as a Bitmagnet VPN check — RDTClient intentionally uses the direct path.

```bash
curl -fsS --max-time 15 'http://192.168.1.20:3333/torznab/?t=caps' | head
```

The response should be XML with Torznab capabilities. The local database starts empty; DHT-discovered items appear gradually as the crawler warms up.

## Phase 7: Connect Prowlarr

Open `http://192.168.1.20:9696`.

1. `Indexers -> Add Indexer -> Generic Torznab`.
2. Name: `Bitmagnet`.
3. URL: `http://192.168.1.20:3333/torznab/`.
4. Leave API Key empty.
5. Keep default categories initially.
6. `Test`, require success, then `Save`.

Do not select Prowlarr's built-in **Bitmagnet** indexer — its only URL choices (`http://bitmagnet:3333`, `http://127.0.0.1:3333`) don't reach the independent debrid stack from this Prowlarr container.

If Prowlarr itself is still behind the main ARR VPN namespace, confirm its LAN allow rule includes `192.168.1.0/24` (it already needs this for the direct RDTClient connection on `6500`). If using Full Sync, run `Settings -> Apps -> Sync App Indexers` and confirm `Bitmagnet (Prowlarr)` appears in Radarr and Sonarr.

## Phase 8: Verify The Debrid Workflow

Run one manual search in Prowlarr, then test one legal/public-domain item end to end: Radarr or Sonarr receives a Bitmagnet result through Prowlarr, the magnet goes to RDTClient's qBittorrent-compatible API, RDTClient submits it to the debrid provider, downloads under `/data/debrid`, Radarr/Sonarr imports to `/data/media/movies` or `/data/media/tv`, and Jellyfin scans the final path. Bitmagnet needs no media volume — never mount `/mnt/media/data` or the RDTClient download directory into it.

## Phase 9: Leak And Kill-Switch Test

Run all commands on the Ubuntu Docker VM after initial deployment, and again after any change to Compose networking, Gluetun, VPN credentials, or container images.

### Expected Topology

| Service | Expected path |
|---|---|
| Bitmagnet | `network_mode: "service:gluetun"` through `debrid-gluetun` |
| RDTClient | Direct Docker networking; intentionally not protected by this test |
| PostgreSQL | Internal `debrid` network; no published port |

### 1. Check Container State

```bash
cd /opt/stacks/debrid-stack
docker compose ps
```

Pass: `debrid-gluetun` healthy, `debrid-bitmagnet` running, `debrid-bitmagnet-postgres` healthy, RDTClient still available on `192.168.1.20:6500`.

### 2. Prove The Shared Network Namespace

```bash
GLUETUN_ID="$(docker inspect -f '{{.Id}}' debrid-gluetun)"
BITMAGNET_MODE="$(docker inspect -f '{{.HostConfig.NetworkMode}}' debrid-bitmagnet)"
RDT_MODE="$(docker inspect -f '{{.HostConfig.NetworkMode}}' debrid-rdt-client)"

test "$BITMAGNET_MODE" = "container:$GLUETUN_ID" && echo "PASS: Bitmagnet shares Gluetun" || echo "FAIL: Bitmagnet is not using Gluetun"
test "$RDT_MODE" != "container:$GLUETUN_ID" && echo "PASS: RDTClient remains direct" || echo "FAIL: RDTClient was unexpectedly routed through Gluetun"
```

Stop if either prints `FAIL`.

### 3. Compare Public IPv4 Addresses

```bash
HOME_WAN_IP="$(curl -4 -fsS --max-time 15 https://ifconfig.me/ip)"
GLUETUN_IP="$(docker exec debrid-gluetun wget -qO- --timeout=15 https://ifconfig.me/ip)"
BITMAGNET_IP="$(docker exec debrid-bitmagnet curl -4 -fsS --max-time 15 https://ifconfig.me/ip)"

test "$GLUETUN_IP" != "$HOME_WAN_IP" && test "$BITMAGNET_IP" = "$GLUETUN_IP" \
  && echo "PASS: Bitmagnet public IPv4 uses Gluetun" \
  || echo "FAIL: stop Bitmagnet and inspect its networking"
```

An IP match alone does not prove the kill switch — complete step 6.

### 4. Check IPv6

```bash
if docker exec debrid-bitmagnet curl -6 -fsS --max-time 10 https://ifconfig.me/ip; then
  echo "FAIL: Bitmagnet has working public IPv6"
else
  echo "PASS: Bitmagnet public IPv6 is blocked"
fi
```

### 5. Check DNS Sanity

```bash
docker exec debrid-gluetun cat /etc/resolv.conf
docker exec debrid-bitmagnet cat /etc/resolv.conf
docker logs --tail 150 debrid-gluetun | grep -Ei 'dns|doh|listening|ready' | tail -30
docker exec debrid-bitmagnet sh -lc 'getent hosts example.com || nslookup example.com'
```

Pass: Bitmagnet resolves names while Gluetun is healthy; Gluetun reports DNS ready; no repeated resolver failures; Bitmagnet is not configured with the router/ISP DNS directly. This is a resolver sanity check, not a packet-level audit.

### 6. Prove The Kill Switch

```bash
docker stop debrid-gluetun
sleep 3

if docker exec debrid-bitmagnet curl -4 -fsS --max-time 10 https://ifconfig.me/ip; then
  echo "FAIL: Bitmagnet still has internet access"
else
  echo "PASS: Bitmagnet failed closed"
fi

curl -fsS --max-time 15 http://192.168.1.20:6500 >/dev/null && echo "PASS: direct RDTClient stayed available" || echo "CHECK: RDTClient was unavailable"
```

A failed `docker exec` is acceptable (the namespace may be unavailable); the only unacceptable result is a public IP response.

Restore:

```bash
cd /opt/stacks/debrid-stack
docker compose up -d gluetun

for i in $(seq 1 60); do
  docker inspect -f '{{.State.Health.Status}}' debrid-gluetun 2>/dev/null | grep -q healthy && { echo "Gluetun is healthy"; break; }
  sleep 2
done

docker compose up -d --force-recreate --no-deps bitmagnet

BITMAGNET_IP=""
for i in $(seq 1 30); do
  BITMAGNET_IP="$(docker exec debrid-bitmagnet curl -4 -fsS --max-time 15 https://ifconfig.me/ip 2>/dev/null)" && { printf 'Bitmagnet public IPv4: %s\n' "$BITMAGNET_IP"; break; }
  sleep 2
done

[ -z "$BITMAGNET_IP" ] && { echo "FAIL: Bitmagnet did not recover after Gluetun restoration"; docker compose logs --tail=150 gluetun bitmagnet; }
```

### Failure Response

```bash
cd /opt/stacks/debrid-stack
docker compose stop bitmagnet
docker inspect -f '{{.HostConfig.NetworkMode}}' debrid-bitmagnet
docker compose config | grep -A12 '^  bitmagnet:'
docker logs --tail 250 debrid-gluetun
```

Do not restart Bitmagnet until the rendered config shows `network_mode: "service:gluetun"` and the full test passes:

```bash
docker compose up -d --force-recreate --no-deps bitmagnet
for i in $(seq 1 30); do
  docker exec debrid-bitmagnet curl -4 -fsS --max-time 15 https://ifconfig.me/ip && break
  sleep 2
done
```

### Pass Checklist

- [ ] Bitmagnet shares the exact `debrid-gluetun` container namespace.
- [ ] RDTClient remains direct.
- [ ] Gluetun IPv4 differs from the home WAN IPv4.
- [ ] Bitmagnet IPv4 equals the Gluetun IPv4.
- [ ] Bitmagnet has no working public IPv6 path.
- [ ] Gluetun DNS is healthy and Bitmagnet resolves through it.
- [ ] Stopping Gluetun blocks Bitmagnet internet access.
- [ ] RDTClient remains available during the Gluetun stop test.
- [ ] Bitmagnet returns to the VPN IPv4 after restoration.

## Phase 10: Back Up PostgreSQL

```bash
(
  set -e
  case "$(findmnt -n -o FSTYPE -T /mnt/main)" in
    nfs|nfs4) ;;
    *) echo "STOP: /mnt/main is not the TrueNAS NFS mount"; exit 1 ;;
  esac
  sudo -u mediauser touch /mnt/main/appdata/.bitmagnet-write-test
  sudo -u mediauser rm /mnt/main/appdata/.bitmagnet-write-test
  sudo -u mediauser mkdir -p /mnt/main/appdata/backups/bitmagnet
  sudo -u mediauser test -w /mnt/main/appdata/backups/bitmagnet
)
```

```bash
set -o pipefail
BACKUP_FILE="/mnt/main/appdata/backups/bitmagnet/bitmagnet-$(date +%F-%H%M%S).sql.gz"
docker exec debrid-bitmagnet-postgres pg_dump -U postgres -d bitmagnet | gzip | sudo -u mediauser tee "$BACKUP_FILE" > /dev/null
test -s "$BACKUP_FILE"
gzip -t "$BACKUP_FILE"

CONFIG_BACKUP="/mnt/main/appdata/backups/bitmagnet/config-$(date +%F-%H%M%S).tar.gz"
sudo tar -C /srv/appdata/bitmagnet -czf - config | sudo -u mediauser tee "$CONFIG_BACKUP" > /dev/null
gzip -t "$CONFIG_BACKUP"
```

Schedule `pg_dump`, retain multiple generations, and include the backup directory in TrueNAS snapshots/off-server backups — a raw copy of a running PostgreSQL data directory is not sufficient on its own.

## Updates

```bash
cd /opt/stacks/debrid-stack
docker compose pull bitmagnet
docker compose up -d bitmagnet
docker compose logs --tail=150 bitmagnet

for attempt in $(seq 1 30); do
  CAPS_XML="$(curl -fsS --max-time 15 'http://192.168.1.20:3333/torznab/?t=caps' 2>/dev/null)" && { printf '%s\n' "$CAPS_XML" | head; break; }
  sleep 2
done
```

Before changing `BITMAGNET_VERSION`: read release/migration notes, create a fresh `pg_dump`, and back up the Docker VM in Proxmox first.

## Rollback

```bash
cd /opt/stacks/debrid-stack
docker compose stop bitmagnet bitmagnet-postgres
cp -a docker-compose.before-bitmagnet.yml docker-compose.yml
cp -a .env.before-bitmagnet .env
docker compose up -d
docker compose ps
```

Remove/disable the Bitmagnet indexer in Prowlarr. Keep `/srv/appdata/bitmagnet` until rollback is verified and its backup retention period has passed.

## Troubleshooting

| Symptom | Check |
|---|---|
| Prowlarr cannot reach Bitmagnet | `curl -v 'http://192.168.1.20:3333/torznab/?t=caps'` from the host and from inside `prowlarr`; `docker port debrid-gluetun` should show `3333`; never use `127.0.0.1` from Prowlarr |
| Bitmagnet stayed up while Gluetun restarted | Recreate only Bitmagnet so it starts inside the healthy Gluetun namespace: `docker compose up -d --force-recreate --no-deps bitmagnet` (data/config preserved) |
| Bitmagnet cannot reach PostgreSQL | `docker compose logs bitmagnet-postgres bitmagnet`; `docker exec debrid-gluetun getent hosts bitmagnet-postgres`; confirm PostgreSQL is on the `debrid` network with port `5432` not published |
| RDTClient rerouted unexpectedly | `docker inspect -f '{{.HostConfig.NetworkMode}}' debrid-rdt-client`; must retain its direct mode and own port publication |
| Search results sparse | Normal — Bitmagnet starts empty and learns from DHT over time; confirm `dht_crawler` is enabled in logs; do not add tracker lists or publish DHT port `3334` |

## Completion Checklist

- [ ] The independent debrid stack works before Bitmagnet is added.
- [ ] `/srv/appdata` is local ext4 storage.
- [ ] Compose and `.env` backups exist.
- [ ] Bitmagnet shares `debrid-gluetun`'s network namespace.
- [ ] Gluetun publishes `3333` for Bitmagnet.
- [ ] RDTClient retains its direct network and publishes its own port `6500`.
- [ ] PostgreSQL port `5432` is not published.
- [ ] Bitmagnet reports the VPN public IP, not the home WAN IP.
- [ ] The Bitmagnet kill-switch test fails closed.
- [ ] Prowlarr passes the Generic Torznab test with `http://192.168.1.20:3333/torznab/`.
- [ ] Prowlarr syncs Bitmagnet to Radarr and Sonarr.
- [ ] A legal/public-domain item completes through RDTClient and imports.
- [ ] A verified PostgreSQL dump exists on TrueNAS.
- [ ] Bitmagnet is not exposed through a router port forward, public proxy, or Cloudflare Tunnel.

## References

- [Bitmagnet v0.10.0 release](https://github.com/bitmagnet-io/bitmagnet/releases/tag/v0.10.0)
- [Gluetun Docker port mapping](https://github.com/qdm12/gluetun-wiki/blob/main/setup/port-mapping.md)
