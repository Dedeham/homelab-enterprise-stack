# Bitmagnet With The Debrid Stack And Prowlarr

Last updated: 2026-06-21

This guide adds Bitmagnet to the independent debrid stack on the Ubuntu Docker
VM and connects it to Prowlarr as a Generic Torznab indexer.

It follows the deployment already documented in:

- [Media Automation With Debrid](media-automation-debrid.md)
- [`debrid-stack` deployment README](../../configs/docker/debrid-stack/README.md)

The existing roles remain separate:

```text
Bitmagnet -> Prowlarr -> Radarr/Sonarr -> RDTClient -> debrid provider
```

Bitmagnet discovers torrent metadata. Prowlarr exposes its results to Radarr and
Sonarr. RDTClient sends the selected magnet to the debrid provider and downloads
the provider-cached result over HTTPS. Bitmagnet does not replace RDTClient and
does not download media into the library.

## Is A VPN Necessary?

For RDTClient's debrid download: **no, not technically**. RDTClient normally
downloads from the debrid provider over HTTPS. Without a VPN, the ISP can see a
connection to the provider, but the home server does not join the torrent swarm
for that provider download.

For Bitmagnet: **not technically required, but strongly recommended**.
Bitmagnet's crawler directly participates in the public BitTorrent DHT and asks
peers for torrent metadata. Without a VPN, the home public IP can be visible to
DHT nodes and metadata peers. This is different from RDTClient's HTTPS path.

For this homelab, route Bitmagnet through the existing `debrid-gluetun` VPN
namespace. The Gluetun instance is functional but RDTClient does not use it.
Bitmagnet can use its VPN route and kill switch without changing RDTClient's
direct debrid HTTPS path.

Tradeoff:

| Mode | Result |
|---|---|
| Bitmagnet through `debrid-gluetun` | Recommended. Hides the home public IP from DHT/metadata peers and fails closed with Gluetun. |
| Bitmagnet without VPN | Works, but exposes the home public IP to its DHT/metadata traffic. |
| RDTClient without VPN | Current setup. Uses the direct provider HTTPS path for better routing and throughput. |
| RDTClient through `debrid-gluetun` | Optional, but not used here. Adds privacy from the ISP and may reduce debrid HTTPS speed. |

This guide routes only Bitmagnet through `debrid-gluetun`. RDTClient remains on
its current direct Docker network.

## Current Homelab Values

| Item | Value |
|---|---|
| Docker VM | `192.168.1.20` |
| Independent debrid stack | `/opt/stacks/debrid-stack` |
| Compose file | `/opt/stacks/debrid-stack/docker-compose.yml` |
| Debrid Gluetun container | `debrid-gluetun` |
| RDTClient container | `debrid-rdt-client` |
| Bitmagnet container | `debrid-bitmagnet` |
| PostgreSQL container | `debrid-bitmagnet-postgres` |
| Local database storage | `/srv/appdata/bitmagnet/postgres` |
| Bitmagnet WebUI | `http://192.168.1.20:3333` |
| Prowlarr Torznab URL | `http://192.168.1.20:3333/torznab/` |

Do not use `127.0.0.1:3333` in Prowlarr. Prowlarr is in the main ARR stack,
while Bitmagnet is in the independent debrid stack. They do not share a network
namespace. The Docker VM LAN address is the deliberate cross-stack path, just
like the existing independent RDTClient connection on port `6500`.

## Storage Decision

Keep the live PostgreSQL database on the Docker VM's local ext4 appdata disk:

```text
/srv/appdata/bitmagnet/postgres
```

Do not put the active PostgreSQL data directory on the TrueNAS NFS mount. The
database needs local block-storage semantics and performs frequent small writes.
Protect it with Proxmox VM backups and application-consistent `pg_dump` backups
to TrueNAS.

The small Bitmagnet configuration directory can also remain local:

```text
/srv/appdata/bitmagnet/config
```

## Phase 1: Back Up And Check The Current Stack

SSH to the Docker VM:

```bash
ssh dockeradmin@192.168.1.20
```

Confirm the independent debrid stack is healthy:

```bash
cd /opt/stacks/debrid-stack
docker compose ps

HOME_WAN_IP="$(curl -4 -fsS --max-time 15 https://ifconfig.me/ip)"
GLUETUN_IP="$(docker exec debrid-gluetun wget -qO- --timeout=15 https://ifconfig.me/ip)"
printf 'Home WAN IP: %s\nGluetun IP: %s\n' "$HOME_WAN_IP" "$GLUETUN_IP"
test "$HOME_WAN_IP" != "$GLUETUN_IP" \
  && echo "Gluetun uses a different public IP" \
  || echo "STOP: Gluetun matches the home WAN IP"
```

The Gluetun address must differ from the home WAN address and match the expected
PIA exit region. Use the `/ip` endpoint exactly as shown; requesting the
ifconfig.me homepage with `wget` returns HTML instead of a single address.

Record RDTClient's direct network mode before editing anything:

```bash
docker inspect -f '{{.HostConfig.NetworkMode}}' debrid-rdt-client
```

It must not report `container:<debrid-gluetun-container-id>`. Do not change
RDTClient's `network_mode`, `networks`, or published port while following this
guide.

Confirm `/srv/appdata` is local ext4 storage, not NFS:

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

Do not assign these directories to `mediauser` UID/GID `3000:3000` by default.
Bitmagnet and PostgreSQL use their own image users and do not need access to the
media dataset. Let the image entrypoints initialize their bind mounts first.

If a container reports a permission error, inspect its actual runtime UID before
changing ownership:

```bash
docker run --rm --entrypoint id ghcr.io/bitmagnet-io/bitmagnet:v0.10.0
docker run --rm --entrypoint id postgres:16-alpine
```

## Phase 3: Add Environment Values

Generate a separate PostgreSQL password:

```bash
openssl rand -hex 32
```

Edit `/opt/stacks/debrid-stack/.env` and add:

```env
BITMAGNET_VERSION=v0.10.0
BITMAGNET_POSTGRES_VERSION=16-alpine
BITMAGNET_POSTGRES_PASSWORD=REPLACE_WITH_THE_GENERATED_PASSWORD
BITMAGNET_TMDB_API_KEY=
```

`v0.10.0` is the latest published Bitmagnet release as of this guide's update.
Review release notes before changing it. A personal TMDB API key is optional but
recommended for sustained classification.

Protect the environment file:

```bash
chmod 600 /opt/stacks/debrid-stack/.env
```

## Phase 4: Extend The Debrid Compose File

Edit:

```text
/opt/stacks/debrid-stack/docker-compose.yml
```

### 4.1 Publish Bitmagnet Through Debrid Gluetun

Keep all the existing Gluetun environment values. Add only the Bitmagnet port to
the existing Gluetun `ports:` list:

```yaml
    ports:
      - "${DOCKER_IP}:3333:3333"
```

This snippet shows the new entry, not a replacement for the entire list. Keep
any other ports already published by this Gluetun instance. RDTClient's port
`6500` remains published by the direct RDTClient service, not by Gluetun.

Port `3333` serves both the Bitmagnet WebUI and Torznab endpoint. Do not publish
PostgreSQL port `5432`.

Do not add `FIREWALL_INPUT_PORTS` for this Docker Compose layout. Gluetun's
documented Docker sidecar pattern only requires publishing the shared-container
port on the Gluetun service. Keep the current debrid firewall behavior intact.

Do not publish Bitmagnet's DHT port `3334` on the Docker VM. A LAN-bound host
port does not create useful incoming connectivity through PIA, while outbound
DHT crawling still uses the VPN. PIA port forwarding can be designed separately
later if incoming DHT reachability is deliberately required.

### 4.2 Add Bitmagnet

Add this service under the existing `services:` key:

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

Bitmagnet shares `debrid-gluetun`'s network namespace. It therefore receives the
VPN route, encrypted DNS path, and Gluetun kill switch. RDTClient remains
outside this namespace.

Leave the `TMDB_API_KEY` line commented while the `.env` value is empty. Passing
an empty value would override Bitmagnet's built-in shared default key.

### 4.3 Add PostgreSQL

Add this service under the same `services:` key:

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

PostgreSQL stays on the internal `debrid` bridge. Gluetun is also attached to
that bridge, so the shared Gluetun namespace can resolve and reach
`bitmagnet-postgres`. Nothing outside the Docker network can connect to port
`5432`.

### 4.4 Validate The Compose File

```bash
cd /opt/stacks/debrid-stack
docker compose config --quiet
docker compose config | grep -A10 -E '^  bitmagnet:|^  bitmagnet-postgres:'
```

Stop if Compose reports a missing variable, duplicate service, or YAML error.

## Phase 5: Start Bitmagnet

Pull the new images:

```bash
cd /opt/stacks/debrid-stack
docker compose pull bitmagnet bitmagnet-postgres
```

Recreate Gluetun so port `3333` is published. This does not interrupt the
direct-networked RDTClient:

```bash
docker compose up -d gluetun

for i in $(seq 1 60); do
  if docker inspect -f '{{.State.Health.Status}}' debrid-gluetun 2>/dev/null | grep -q healthy; then
    echo "debrid Gluetun is healthy"
    break
  fi
  sleep 2
done

docker compose up -d bitmagnet-postgres bitmagnet
docker compose ps
```

Watch initial migrations and crawler startup:

```bash
docker compose logs -f --tail=150 bitmagnet-postgres bitmagnet
```

Exit with `Ctrl+C` after both services are stable.

## Phase 6: Verify VPN And Torznab

Confirm Bitmagnet uses the same PIA/VPN address as Gluetun:

```bash
docker exec debrid-bitmagnet curl -4 -fsS --max-time 15 https://ifconfig.me/ip
docker exec debrid-gluetun wget -qO- --timeout=15 https://ifconfig.me/ip
```

Both results must be the VPN address, not the home WAN address.

Do not use RDTClient's public IP as a Bitmagnet VPN test. RDTClient intentionally
uses the direct path and may report the home WAN IP.

Test Bitmagnet from the Docker VM:

```bash
curl -fsS --max-time 15 \
  'http://192.168.1.20:3333/torznab/?t=caps' | head
```

The response should be XML containing Torznab capabilities. Open the WebUI:

```text
http://192.168.1.20:3333
```

The local database starts empty. DHT-discovered items should begin appearing
after the crawler warms up, but useful search coverage takes longer to build.

## Phase 7: Connect Prowlarr

Open:

```text
http://192.168.1.20:9696
```

In Prowlarr:

1. Go to **Indexers**.
2. Select **Add Indexer**.
3. Search for and select **Generic Torznab**.
4. Set **Name** to `Bitmagnet`.
5. Set **URL** to `http://192.168.1.20:3333/torznab/`.
6. Leave **API Key** empty.
7. Keep the default categories initially.
8. Select **Test** and require a successful result.
9. Select **Save**.

Do not select Prowlarr's built-in **Bitmagnet** indexer for this layout. Its URL
field offers fixed same-network addresses such as `http://bitmagnet:3333` and
`http://127.0.0.1:3333`; neither reaches the independent debrid stack from this
Prowlarr container. If those are the only URL choices shown, cancel that form
and add **Generic Torznab** instead.

The LAN URL is required because the services are in different Compose projects
and network namespaces:

```text
Prowlarr in main ARR stack
  -> Docker VM LAN 192.168.1.20:3333
  -> debrid-gluetun published port
  -> Bitmagnet shared Gluetun namespace
```

If Prowlarr itself is still behind the main ARR VPN namespace, the existing LAN
allow rule must include `192.168.1.0/24`. This also permits the existing direct
RDTClient connection at `192.168.1.20:6500`.

If Prowlarr applications use **Full Sync**, run **Settings > Apps > Sync App
Indexers**. Confirm `Bitmagnet (Prowlarr)` then appears in Radarr and Sonarr.

## Phase 8: Verify The Debrid Workflow

Run one manual search in Prowlarr. Then test one legal or public-domain item:

1. Radarr or Sonarr receives a Bitmagnet result through Prowlarr.
2. The selected magnet is sent to RDTClient's qBittorrent-compatible API.
3. RDTClient submits it to the configured debrid provider.
4. RDTClient downloads the provider result under `/data/debrid`.
5. Radarr or Sonarr imports it into `/data/media/movies` or `/data/media/tv`.
6. Jellyfin scans the final library path.

Bitmagnet needs no media volume. Do not mount `/mnt/media/data` into it and do
not point it at the RDTClient download directory.

## Phase 9: Run The Leak And Kill-Switch Test

Complete the separate
[Bitmagnet Gluetun IP Leak Test](bitmagnet-gluetun-ip-leak-test.md).

It verifies the Docker namespace, public IPv4, IPv6, DNS sanity, and a real
Gluetun stop test. It also confirms the direct RDTClient remains available.
Do not enable Bitmagnet automation until every pass criterion succeeds.

## Phase 10: Back Up PostgreSQL

This homelab already has the TrueNAS-backed `/mnt/main/appdata` dataset. Store
Bitmagnet's logical dumps in a dedicated backup directory inside it. The live
database remains on the Docker VM's local `/srv/appdata`; this target is a
separate TrueNAS copy protected by the `main/appdata` snapshots.

Verify the NFS mount and create the Bitmagnet backup target:

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

Do not create or use the backup directory while `/mnt/main` is unmounted. That
would write the dump to the Docker VM's local root filesystem instead of
TrueNAS.

Create and verify a compressed database dump:

```bash
set -o pipefail
BACKUP_FILE="/mnt/main/appdata/backups/bitmagnet/bitmagnet-$(date +%F-%H%M%S).sql.gz"
docker exec debrid-bitmagnet-postgres pg_dump -U postgres -d bitmagnet \
  | gzip \
  | sudo -u mediauser tee "$BACKUP_FILE" > /dev/null
test -s "$BACKUP_FILE"
gzip -t "$BACKUP_FILE"
ls -lh "$BACKUP_FILE"
```

Back up the configuration directory:

```bash
CONFIG_BACKUP="/mnt/main/appdata/backups/bitmagnet/config-$(date +%F-%H%M%S).tar.gz"
sudo tar -C /srv/appdata/bitmagnet -czf - config \
  | sudo -u mediauser tee "$CONFIG_BACKUP" > /dev/null
gzip -t "$CONFIG_BACKUP"
```

Do not rely only on a raw copy of a running PostgreSQL data directory. Schedule
`pg_dump`, retain multiple generations, and include the backup directory in
TrueNAS snapshots and off-server backups.

## Updates

Before changing `BITMAGNET_VERSION`:

1. Read the Bitmagnet release and migration notes.
2. Create a fresh `pg_dump`.
3. Back up the Docker VM in Proxmox.
4. Pull and recreate only Bitmagnet.

```bash
cd /opt/stacks/debrid-stack
docker compose pull bitmagnet
docker compose up -d bitmagnet
docker compose logs --tail=150 bitmagnet
(
  for attempt in $(seq 1 30); do
    if CAPS_XML="$(curl -fsS --max-time 15 \
      'http://192.168.1.20:3333/torznab/?t=caps' 2>/dev/null)"; then
      printf '%s\n' "$CAPS_XML" | head
      exit 0
    fi
    sleep 2
  done
  echo "ERROR: Bitmagnet Torznab did not become ready"
  docker compose ps gluetun bitmagnet-postgres bitmagnet
  docker compose logs --tail=150 gluetun bitmagnet-postgres bitmagnet
  exit 1
)
```

Use the repository's
[controlled update procedure](../monitoring/monitoring-and-updates-start-here.md)
for backup, validation, verification, and rollback.

## Rollback

If Bitmagnet disrupts the debrid stack:

```bash
cd /opt/stacks/debrid-stack
docker compose stop bitmagnet bitmagnet-postgres
cp -a docker-compose.before-bitmagnet.yml docker-compose.yml
cp -a .env.before-bitmagnet .env
docker compose up -d
docker compose ps
```

Remove or disable the Bitmagnet indexer in Prowlarr. Keep
`/srv/appdata/bitmagnet` until rollback is verified and its backup retention
period has passed.

## Troubleshooting

### Prowlarr Cannot Reach Bitmagnet

Test from the Docker VM and then from Prowlarr:

```bash
curl -v --max-time 15 'http://192.168.1.20:3333/torznab/?t=caps'
docker exec prowlarr curl -v --max-time 15 \
  'http://192.168.1.20:3333/torznab/?t=caps'
```

Check the published ports:

```bash
docker port debrid-gluetun
```

Expected output includes port `3333` bound to the Docker VM LAN IP. RDTClient's
port `6500` will not appear here because RDTClient publishes it directly. Do not
replace the Prowlarr URL with `127.0.0.1`; loopback points at Prowlarr's own
namespace, not the debrid stack.

### Bitmagnet Stayed Up While Gluetun Restarted

If Gluetun restarted but Bitmagnet did not, Bitmagnet logs may show DNS failures
against `127.0.0.1:53`, PostgreSQL hostname lookup failures, and no listener on
published port `3333`. Recreate only Bitmagnet so it starts inside the healthy
Gluetun namespace again. Its PostgreSQL data and configuration are preserved:

```bash
cd /opt/stacks/debrid-stack
docker compose up -d --force-recreate --no-deps bitmagnet
docker compose logs --tail=150 bitmagnet
for attempt in $(seq 1 30); do
  if CAPS_XML="$(curl -fsS --max-time 15 \
    'http://192.168.1.20:3333/torznab/?t=caps' 2>/dev/null)"; then
    printf '%s\n' "$CAPS_XML" | head
    break
  fi
  sleep 2
done
```

### Bitmagnet Cannot Reach PostgreSQL

```bash
cd /opt/stacks/debrid-stack
docker compose ps bitmagnet-postgres
docker compose logs --tail=200 bitmagnet-postgres bitmagnet
docker exec debrid-gluetun getent hosts bitmagnet-postgres
```

Confirm PostgreSQL is attached to the `debrid` network and that port `5432` is
not published.

### Confirm RDTClient Was Not Rerouted

```bash
docker inspect -f '{{.HostConfig.NetworkMode}}' debrid-rdt-client
curl -fsS --max-time 15 http://192.168.1.20:6500
```

RDTClient must retain its original direct network mode and its own port
publication. It must not report Gluetun's container namespace. Adding Bitmagnet
does not require any RDTClient Compose change.

### Search Results Are Sparse

Bitmagnet starts with an empty local index and learns from DHT traffic over time.
Confirm `dht_crawler` is enabled and inspect logs:

```bash
docker compose logs --tail=250 bitmagnet
```

Sparse early results do not indicate a Prowlarr integration failure if the
Torznab capability test passes.

Do not add tracker lists or publish DHT port `3334` to increase coverage. Leave
the crawler running continuously so its local index grows. The default
`DHT_CRAWLER_SCALING_FACTOR` is already `10`; Bitmagnet's documentation warns of
diminishing returns above that value, so keep the default until CPU, memory,
PostgreSQL storage growth, and VPN traffic have been measured.

A personal TMDB API key does not discover more torrents, but it substantially
improves movie and TV classification throughput. Add the key to `.env`,
uncomment the existing `TMDB_API_KEY` Compose environment line, and recreate
only Bitmagnet. For immediate bulk population, Bitmagnet also provides an
`/import` endpoint for legally obtained torrent metadata; large imports increase
database use and can leave the classification queue busy for hours.

## Completion Checklist

- [ ] The independent debrid stack works before Bitmagnet is added.
- [ ] `/srv/appdata` is local ext4 storage.
- [ ] Compose and `.env` backups exist.
- [ ] Bitmagnet shares `debrid-gluetun`'s network namespace.
- [ ] Gluetun publishes `3333` for Bitmagnet.
- [ ] RDTClient retains its direct network and publishes its own port `6500`.
- [ ] PostgreSQL port `5432` is not published.
- [ ] Bitmagnet reports the PIA/VPN public IP, not the home WAN IP.
- [ ] The Bitmagnet kill-switch test fails closed.
- [ ] Prowlarr passes the Generic Torznab test with
      `http://192.168.1.20:3333/torznab/`.
- [ ] Prowlarr syncs Bitmagnet to Radarr and Sonarr.
- [ ] A legal/public-domain item completes through RDTClient and imports.
- [ ] A verified PostgreSQL dump exists on TrueNAS.
- [ ] Bitmagnet is not exposed through a router port forward, public proxy, or
      Cloudflare Tunnel.

## Official References

- [Bitmagnet installation](https://bitmagnet.io/setup/installation.html)
- [Bitmagnet configuration](https://bitmagnet.io/setup/configuration.html)
- [Bitmagnet Servarr integration](https://bitmagnet.io/guides/servarr-integration.html)
- [Bitmagnet v0.10.0 release](https://github.com/bitmagnet-io/bitmagnet/releases/tag/v0.10.0)
- [Gluetun Docker port mapping](https://github.com/qdm12/gluetun-wiki/blob/main/setup/port-mapping.md)
