# ARR Stack Gluetun VPN Gateway Guide

Last updated: 2026-06-11

Use this later if you want to replace the current hotio qBittorrent-bundled VPN
with a dedicated Gluetun VPN gateway.

This is not required while the current hotio qBittorrent PIA setup passes the
leak and kill-switch tests. Gluetun is useful when you want one explicit VPN
gateway container for qBittorrent, Prowlarr, Radarr, Sonarr, FlareSolverr, and
optional helpers.

## Why Switch Later

Current working design:

```text
qBittorrent hotio container
+-- owns PIA WireGuard
+-- publishes qBittorrent and ARR UI ports
+-- shared by Prowlarr, Radarr, Sonarr, FlareSolverr
```

Gluetun design:

```text
Gluetun
+-- owns VPN tunnel and firewall
+-- publishes qBittorrent and ARR UI ports
+-- shared by qBittorrent, Prowlarr, Radarr, Sonarr, FlareSolverr
```

Use Gluetun if:

- you want the VPN gateway separated from the download client;
- you plan to add more VPN-routed download clients;
- you want one place to manage VPN firewall, DNS, and port forwarding behavior;
- you want to switch VPN providers later without replacing qBittorrent.

Do not switch during active troubleshooting. Finish the current ARR stack first,
then migrate deliberately.

## Important PIA Note

For Private Internet Access, Gluetun's straightforward documented path is
OpenVPN with `VPN_SERVICE_PROVIDER=private internet access`,
`OPENVPN_USER`, and `OPENVPN_PASSWORD`.

Gluetun's PIA WireGuard path is not as direct. The official PIA page says native
PIA WireGuard support is not currently available and points to extracting a
WireGuard config for the custom provider path. Treat that as an advanced later
variant, not the first Gluetun migration.

Recommended first Gluetun migration for this homelab:

```text
PIA OpenVPN through Gluetun
```

Tradeoff:

- OpenVPN is usually slower than WireGuard.
- The architecture is cleaner and easier to reason about.
- If speed becomes a problem, either stay on hotio PIA WireGuard or build a
  separate Gluetun custom WireGuard variant later.

## Official References

- Gluetun connect-container pattern:
  https://github.com/qdm12/gluetun-wiki/blob/main/setup/connect-a-container-to-gluetun.md
- Gluetun port mapping pattern:
  https://github.com/qdm12/gluetun-wiki/blob/main/setup/port-mapping.md
- Gluetun PIA provider page:
  https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/private-internet-access.md
- Gluetun DNS options:
  https://github.com/qdm12/gluetun-wiki/blob/main/setup/options/dns.md
- Gluetun VPN port forwarding:
  https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md

## Scope

VPN-routed through Gluetun:

| Service | Network mode |
|---|---|
| qBittorrent | `network_mode: "service:gluetun"` |
| Prowlarr | `network_mode: "service:gluetun"` |
| Radarr | `network_mode: "service:gluetun"` |
| Sonarr | `network_mode: "service:gluetun"` |
| FlareSolverr | `network_mode: "service:gluetun"` |
| Bazarr, optional | `network_mode: "service:gluetun"` |
| Recyclarr, optional | `network_mode: "service:gluetun"` |
| Unpackerr, optional | `network_mode: "service:gluetun"` |
| RDTClient, optional | `network_mode: "service:gluetun"` |

Not VPN-routed by default:

| Service | Network mode |
|---|---|
| Jellyfin | normal `arr` network |
| Seerr | normal `arr` network |
| Dockge | normal Docker/Dockge network |

## Migration Rules

- Do not run hotio qBittorrent VPN and Gluetun VPN at the same time for the same
  qBittorrent container.
- Use a non-VPN qBittorrent image or explicitly disable qBittorrent's bundled
  VPN.
- Publish ARR UI ports on `gluetun`, not on the containers sharing Gluetun's
  network namespace.
- Keep LAN access private. Do not expose qBittorrent, Prowlarr, Radarr, Sonarr,
  FlareSolverr, RDTClient, Dockge, TrueNAS, or Proxmox to the public internet.
- Run the full leak and kill-switch test after migration before adding real
  downloads.

## qBittorrent Interface Binding With Gluetun

It is possible to use Gluetun's kill switch and also bind qBittorrent to the VPN
interface, but the Gluetun firewall is the primary protection in this design.

Recommended default:

- Put qBittorrent in Gluetun's network namespace with
  `network_mode: "service:gluetun"`.
- Let Gluetun own the VPN tunnel, routing, DNS, and firewall.
- Prove protection with the Gluetun leak and kill-switch tests in this guide.

Optional extra hardening:

- In qBittorrent, bind the network interface only after Gluetun is working.
- Bind to the actual VPN interface visible inside the shared namespace, such as
  `tun0` for OpenVPN or `wg0` for WireGuard.
- Re-check this after changing VPN type or provider, because the interface name
  can change.

Do not bind qBittorrent to `eth0` in the Gluetun namespace. That is the Docker
side, not the VPN tunnel. If the bind setting is wrong, qBittorrent may simply
stop connecting; that is safer than leaking, but it can look like a broken
download client. Treat binding as defense in depth, not as a replacement for
Gluetun's firewall and the kill-switch runbook.

## Files And Directories

This guide keeps the same paths:

```text
/opt/stacks/arr-stack/compose.yaml
/opt/stacks/arr-stack/.env
/mnt/main/appdata/arr-stack
/mnt/main/appdata/arr-stack/gluetun
/mnt/main/appdata/arr-stack/qbittorrent
/mnt/media/data
```

Create Gluetun appdata:

```bash
sudo -u mediauser mkdir -p /mnt/main/appdata/arr-stack/gluetun
sudo -u mediauser test -w /mnt/main/appdata/arr-stack/gluetun && echo "gluetun appdata writable"
```

## `.env` Additions

Keep your existing base values:

```env
PUID=3000
PGID=3000
TZ=Europe/Berlin
DOCKER_IP=192.168.1.20
LAN=192.168.1.0/24
CONFIG_PATH=/mnt/main/appdata/arr-stack
DATA_PATH=/mnt/media/data
```

Add Gluetun-specific values:

```env
GLUETUN_VERSION=latest
QBITTORRENT_VERSION=latest

PIA_USER=p1234567
PIA_PASS=replace_with_your_pia_password

# Pick a nearby non-US region if you want PIA port forwarding.
# Examples depend on Gluetun's current server list.
PIA_REGION=Netherlands

# Use on only if you want a VPN forwarded port for qBittorrent.
PIA_PORT_FORWARDING=on
```

PIA usernames usually start with `p`. Do not use your PIA account email.

## Compose Pattern

Back up the current compose first:

```bash
cd /opt/stacks/arr-stack
cp -a compose.yaml compose.hotio-vpn.backup.yaml
cp -a .env .env.before-gluetun
```

Use this as the Gluetun pattern. It shows the core services only; optional
services are listed later.

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

Key differences from the hotio VPN compose:

- `gluetun` publishes the UI ports.
- VPN-routed services use `network_mode: "service:gluetun"`.
- VPN-routed services do not define their own `ports` or `networks`.
- qBittorrent no longer has VPN variables.
- qBittorrent uses a non-VPN image in this example.
- Seerr no longer depends directly on Radarr/Sonarr because it is not sharing
  their network namespace; configure Seerr to use the LAN-published URLs.

Do not set `FIREWALL_OUTBOUND_SUBNETS=${LAN}` by default. Published UI ports on
`gluetun` are enough for LAN browser access. Add `FIREWALL_OUTBOUND_SUBNETS`
only if a VPN-routed container must initiate connections to a LAN service, and
keep it narrowed to the exact subnet required.

## Optional Services

Add these only after the core stack passes leak and kill-switch tests.

```yaml
  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    restart: unless-stopped
    profiles:
      - optional
    network_mode: "service:gluetun"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${CONFIG_PATH}/bazarr:/config
      - ${DATA_PATH}/media/movies:/movies
      - ${DATA_PATH}/media/tv:/tv
    depends_on:
      gluetun:
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
    network_mode: "service:gluetun"
    user: "${PUID}:${PGID}"
    environment:
      - TZ=${TZ}
    volumes:
      - ${CONFIG_PATH}/recyclarr:/config
    depends_on:
      gluetun:
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
    network_mode: "service:gluetun"
    user: "${PUID}:${PGID}"
    environment:
      - TZ=${TZ}
    volumes:
      - ${CONFIG_PATH}/unpackerr:/config
      - ${DATA_PATH}:/data
    depends_on:
      gluetun:
        condition: service_healthy
      radarr:
        condition: service_started
      sonarr:
        condition: service_started
```

For RDTClient, publish port `6500` on `gluetun`:

```yaml
    ports:
      - "${DOCKER_IP}:8080:8080"
      - "${DOCKER_IP}:9696:9696"
      - "${DOCKER_IP}:7878:7878"
      - "${DOCKER_IP}:8989:8989"
      - "${DOCKER_IP}:6767:6767"
      - "${DOCKER_IP}:6500:6500"
```

Then use:

```yaml
  rdt-client:
    image: rogerfar/rdtclient:latest
    container_name: rdt-client
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
```

## Start Order

Stop the current stack:

```bash
cd /opt/stacks/arr-stack
docker compose down
```

Validate the new compose:

```bash
docker compose config
```

Start Gluetun alone:

```bash
docker compose up -d gluetun
docker logs -f gluetun
```

Wait for logs showing that the VPN is up and Gluetun's healthcheck is healthy.
In another terminal:

```bash
docker compose ps gluetun
docker exec gluetun wget -qO- --timeout=15 https://ifconfig.me
```

The returned IP must be a PIA/VPN IP, not your home WAN IP.

Start the VPN-routed apps:

```bash
docker compose up -d qbittorrent prowlarr radarr sonarr flaresolverr
docker compose ps
```

Start normal-network apps:

```bash
docker compose up -d jellyfin seerr
```

## App URLs

Because UI ports are published on `gluetun`, open:

| App | LAN URL |
|---|---|
| qBittorrent | `http://192.168.1.20:8080` |
| Prowlarr | `http://192.168.1.20:9696` |
| Radarr | `http://192.168.1.20:7878` |
| Sonarr | `http://192.168.1.20:8989` |
| FlareSolverr | `http://192.168.1.20:6767` |
| RDTClient, optional | `http://192.168.1.20:6500` |
| Jellyfin | `http://192.168.1.20:8096` |
| Seerr | `http://192.168.1.20:5055` |

If your Docker VM IP differs, use `DOCKER_IP` from `.env`.

Inside the VPN namespace, apps still talk to each other through localhost:

| From | To | URL |
|---|---|---|
| Radarr | qBittorrent | `127.0.0.1:8080` |
| Sonarr | qBittorrent | `127.0.0.1:8080` |
| Prowlarr | Radarr | `http://127.0.0.1:7878` |
| Prowlarr | Sonarr | `http://127.0.0.1:8989` |
| Prowlarr | FlareSolverr | `http://127.0.0.1:6767` |
| Radarr/Sonarr | RDTClient, optional | `127.0.0.1:6500` |

Seerr is not in the VPN namespace. Configure Seerr to reach Radarr and Sonarr
through the LAN-published URLs:

```text
http://192.168.1.20:7878
http://192.168.1.20:8989
```

## qBittorrent Settings

Open qBittorrent and set:

| Setting | Value |
|---|---|
| Default save path | `/data/torrents` |
| Incomplete path | `/data/torrents/incomplete` |
| Movies category path | `/data/torrents/movies` |
| TV category path | `/data/torrents/tv` |
| WebUI port | `8080` |

If you use Gluetun port forwarding, qBittorrent's listen port should match the
Gluetun forwarded port. The official Gluetun port-forwarding page includes a
qBittorrent Web API command pattern, but it requires qBittorrent WebUI localhost
auth bypass. For a first migration, prove the VPN path first, then automate port
updates later.

Manual check for the forwarded port:

```bash
docker exec gluetun sh -lc 'cat /tmp/gluetun/forwarded_port 2>/dev/null || true'
docker logs gluetun | grep -i port
```

If no forwarded port appears:

- confirm `PIA_PORT_FORWARDING=on`;
- confirm `PORT_FORWARD_ONLY=true`;
- choose a PIA region that supports port forwarding;
- read `docker logs gluetun`.

## Leak Test Variables

For Gluetun, use this service list:

```bash
cd /opt/stacks/arr-stack

ARR_VPN_SERVICES="gluetun qbittorrent prowlarr radarr sonarr flaresolverr"

# Optional:
# ARR_VPN_SERVICES="$ARR_VPN_SERVICES bazarr recyclarr unpackerr"
# ARR_VPN_SERVICES="$ARR_VPN_SERVICES rdt-client"
```

Record the home WAN:

```bash
HOME_WAN_IP="$(curl -4 -fsS --max-time 15 https://ifconfig.me)"
printf 'Home WAN IPv4: %s\n' "$HOME_WAN_IP"
```

The home WAN must never appear from `gluetun` or any service sharing Gluetun's
network namespace.

## Phase 1: Gluetun Health

```bash
docker compose ps gluetun
docker logs --tail 200 gluetun
docker exec gluetun ip route
docker exec gluetun wget -qO- --timeout=15 https://ifconfig.me
```

Pass criteria:

- Gluetun is `running` or `healthy`.
- Logs show the VPN tunnel is established.
- Public IP is a PIA/VPN IP.
- Public IP is not `$HOME_WAN_IP`.

## Phase 2: Protected-Service IPv4 Test

```bash
for service in $ARR_VPN_SERVICES; do
  if docker inspect "$service" >/dev/null 2>&1; then
    printf '\n[%s] public IPv4: ' "$service"
    docker exec "$service" sh -lc 'wget -qO- --timeout=15 https://ifconfig.me || curl -4 -fsS --max-time 15 https://ifconfig.me' || echo "FAILED"
  fi
done
```

Pass criteria:

- Every protected service returns a PIA/VPN public IPv4.
- No protected service returns `$HOME_WAN_IP`.
- IPs may differ because PIA can NAT/load-balance requests.

## Phase 3: IPv6 Test

```bash
for service in $ARR_VPN_SERVICES; do
  if docker inspect "$service" >/dev/null 2>&1; then
    printf '\n[%s] IPv6: ' "$service"
    docker exec "$service" sh -lc 'curl -6 -fsS --max-time 10 https://ifconfig.me && echo "IPv6 LEAK: investigate" || echo "IPv6 blocked as expected"'
  fi
done
```

Pass criteria:

- Every protected service prints `IPv6 blocked as expected`, or the container
  lacks IPv6 tooling and the request fails.

## Phase 4: Resolver Check

```bash
docker exec gluetun cat /etc/resolv.conf

for service in $ARR_VPN_SERVICES; do
  if docker inspect "$service" >/dev/null 2>&1; then
    printf '\n[%s] DNS lookup:\n' "$service"
    docker exec "$service" sh -lc 'getent hosts example.com || nslookup example.com || true'
  fi
done
```

Pass criteria:

- Protected services resolve names while Gluetun is healthy.
- They do not use your router or ISP DNS directly.
- Do not set `DNS_UPSTREAM_PLAIN_ADDRESSES` to a LAN DNS server, because that
  intentionally sends DNS outside the tunnel.

## Phase 5: Live DNS Leak Watch

Get Gluetun's Docker IP:

```bash
GLUETUN_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' gluetun)"
printf 'Gluetun Docker IP: %s\n' "$GLUETUN_IP"
```

First terminal:

```bash
sudo tcpdump -l -nn -vv -ni any "host $GLUETUN_IP and (udp port 53 or tcp port 53 or tcp port 853)"
```

Second terminal:

```bash
for service in $ARR_VPN_SERVICES; do
  if docker inspect "$service" >/dev/null 2>&1; then
    printf '\n[%s] DNS trigger:\n' "$service"
    docker exec "$service" sh -lc 'getent hosts example.com || nslookup example.com || true'
  fi
done
```

Also open Prowlarr and test one indexer.

Pass criteria:

- No plaintext DNS or DoT packets leave from `$GLUETUN_IP` to the router, ISP
  DNS, or public DNS outside the tunnel.
- `tcpdump` may show no packets at all. That is acceptable.

## Phase 6: Torrent Leak Test

Use a torrent leak-test magnet from a reputable leak-test site such as
`ipleak.net`. Do not use a real torrent.

Pass criteria:

- The torrent leak page reports a PIA/VPN IP.
- It does not report `$HOME_WAN_IP`.

## Phase 7: Kill-Switch Test

This intentionally interrupts the VPN gateway.

Start DNS watch:

```bash
GLUETUN_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' gluetun)"
sudo tcpdump -l -nn -vv -ni any "host $GLUETUN_IP and (udp port 53 or tcp port 53 or tcp port 853)"
```

In another terminal, stop Gluetun:

```bash
docker stop gluetun
```

Test protected services:

```bash
KILLSWITCH_DNS_NAME="arr-gluetun-killswitch-$(date +%s).example.com"

for service in qbittorrent prowlarr radarr sonarr flaresolverr; do
  if docker inspect "$service" >/dev/null 2>&1; then
    printf '\n[%s] kill-switch IPv4: ' "$service"
    docker exec "$service" sh -lc 'curl -4 -fsS --max-time 10 https://ifconfig.me && echo "LEAK: investigate" || echo "blocked or namespace unavailable as expected"' || echo "blocked or namespace unavailable as expected"

    printf '[%s] kill-switch DNS trigger: ' "$service"
    docker exec "$service" sh -lc "getent hosts $KILLSWITCH_DNS_NAME >/dev/null 2>&1 && echo \"unexpected DNS answer\" || echo \"lookup failed or namespace unavailable as expected\"" || echo "lookup failed or namespace unavailable as expected"
  fi
done
```

Pass criteria:

- Protected services cannot reach the internet.
- No protected service returns `$HOME_WAN_IP`.
- DNS watch shows no DNS leaving to router, ISP DNS, or public DNS.

Restore:

```bash
docker compose up -d gluetun

for i in $(seq 1 60); do
  if docker inspect -f '{{.State.Health.Status}}' gluetun 2>/dev/null | grep -q healthy; then
    echo "gluetun healthy"
    break
  fi

  echo "waiting for gluetun health..."
  sleep 2
done

docker compose up -d qbittorrent prowlarr radarr sonarr flaresolverr
docker exec gluetun wget -qO- --timeout=15 https://ifconfig.me
```

## Phase 8: Broken-Credential Cold Start

Back up `.env`:

```bash
cd /opt/stacks/arr-stack
cp -a .env .env.before-gluetun-killswitch-test
chmod 600 .env.before-gluetun-killswitch-test
```

Temporarily break PIA auth:

```bash
nano .env
```

Example temporary change:

```env
PIA_PASS=definitely_wrong_for_gluetun_killswitch_test
```

Recreate Gluetun:

```bash
docker compose up -d --force-recreate gluetun
docker compose ps
docker logs --tail 150 gluetun
```

Test:

```bash
for service in gluetun qbittorrent prowlarr radarr sonarr flaresolverr; do
  if docker inspect "$service" >/dev/null 2>&1; then
    printf '\n[%s] broken-auth IPv4: ' "$service"
    docker exec "$service" sh -lc 'curl -4 -fsS --max-time 10 https://ifconfig.me && echo "LEAK: investigate" || echo "blocked as expected"' || echo "blocked as expected"
  fi
done
```

Pass criteria:

- Gluetun fails to establish VPN or becomes unhealthy.
- Protected services fail closed or are unavailable.
- No protected service returns `$HOME_WAN_IP`.

Restore:

```bash
cp -a .env.before-gluetun-killswitch-test .env
chmod 600 .env
docker compose up -d --force-recreate gluetun
docker compose up -d
docker compose ps
docker exec gluetun wget -qO- --timeout=15 https://ifconfig.me
```

Delete the temporary backup only after the stack is healthy:

```bash
rm .env.before-gluetun-killswitch-test
```

## Final Pass Checklist

- [ ] `docker compose config` is valid.
- [ ] Gluetun starts and becomes healthy.
- [ ] Gluetun public IPv4 is a PIA/VPN IP.
- [ ] qBittorrent, Prowlarr, Radarr, Sonarr, and FlareSolverr return PIA/VPN
      IPv4 addresses.
- [ ] None of the protected services return the home WAN IP.
- [ ] IPv6 does not connect from protected services.
- [ ] DNS leak watch shows no plaintext DNS to router, ISP DNS, or public DNS.
- [ ] qBittorrent torrent leak-test magnet reports a PIA/VPN IP.
- [ ] Stopping Gluetun blocks protected services.
- [ ] Broken PIA credentials do not fall back to home WAN.
- [ ] Stack restores cleanly after kill-switch tests.
- [ ] Seerr can reach Radarr/Sonarr through LAN-published URLs.
- [ ] qBittorrent import paths still work with Radarr/Sonarr.

## Failure Response

If any protected service returns the home WAN IP:

```bash
docker compose stop gluetun qbittorrent prowlarr radarr sonarr flaresolverr
```

Then check:

```bash
docker compose config | grep -E 'network_mode|VPN_SERVICE_PROVIDER|OPENVPN_USER|SERVER_REGIONS|FIREWALL|DNS_UPSTREAM'
docker logs --tail 250 gluetun
docker exec gluetun ip route
```

Do not restart downloads until the full test passes.

## Rollback To Hotio VPN

If Gluetun does not work cleanly, roll back:

```bash
cd /opt/stacks/arr-stack
docker compose down
cp -a compose.hotio-vpn.backup.yaml compose.yaml
cp -a .env.before-gluetun .env
docker compose up -d qbittorrent
```

Wait for `wg0`, verify the VPN IP, then start the rest:

```bash
for i in $(seq 1 60); do
  if docker exec qbittorrent sh -lc 'ip link show wg0 >/dev/null 2>&1'; then
    echo "wg0 is present"
    break
  fi

  echo "waiting for wg0..."
  sleep 2
done

docker exec qbittorrent curl -4 -fsS --max-time 15 https://ifconfig.me
docker compose up -d
```

Run [ARR Stack Leak And Kill-Switch Test](arr-stack-leak-and-killswitch-test.md)
again after rollback.
