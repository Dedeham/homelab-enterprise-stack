# Independent Debrid Stack

This stack runs RDTClient behind its own Gluetun VPN gateway so it can be
started, stopped, tested, or rebuilt independently from the main ARR stack.

It does not include Radarr, Sonarr, Prowlarr, Jellyfin, or qBittorrent. Keep
those in the main ARR stack and add this RDTClient instance as an additional
download client if the networking test passes.

## Deploy

```bash
sudo -u mediauser mkdir -p /mnt/main/appdata/debrid-stack/gluetun
sudo -u mediauser mkdir -p /mnt/main/appdata/debrid-stack/rdt-client
sudo -u mediauser mkdir -p /mnt/media/data/debrid/incomplete
sudo -u mediauser mkdir -p /mnt/media/data/debrid/movies
sudo -u mediauser mkdir -p /mnt/media/data/debrid/tv

cd /opt/stacks/debrid-stack
cp .env.example .env
nano .env
docker compose config
docker compose up -d gluetun
docker compose up -d rdt-client
docker compose ps
```

Open:

```text
http://192.168.1.20:6500
```

Use your actual `DOCKER_IP` if different.

## Verify

```bash
docker exec debrid-gluetun wget -qO- --timeout=15 https://ifconfig.me
```

The returned IPv4 must be a VPN IP, not your home WAN IP.

Check for DNS transport errors:

```bash
docker logs --tail 100 debrid-gluetun | grep -E 'dns|api\.torbox|connection reset|TLS handshake' || true
```

Repeated `TLS handshake` resets to `:853` mean DNS over TLS is unstable through
the current VPN path. Keep DNS encrypted but switch the debrid stack to DoH:

```env
DNS_UPSTREAM_RESOLVER_TYPE=doh
DNS_UPSTREAM_RESOLVERS=cloudflare
```

Then recreate the stack:

```bash
cd /opt/stacks/debrid-stack
docker compose up -d
```

From the main ARR stack, Radarr and Sonarr must be able to reach:

```text
http://192.168.1.20:6500
```

If they cannot, keep RDTClient in the main ARR VPN namespace or redesign the ARR
networking deliberately. Do not broadly loosen VPN firewall rules.
