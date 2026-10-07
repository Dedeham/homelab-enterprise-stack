# Bitmagnet

Bitmagnet is a self-hosted BitTorrent DHT crawler and metadata indexer exposed to Prowlarr as a Generic Torznab indexer. It runs inside the independent debrid stack (not the main ARR stack) and discovers torrent metadata; it does not download anything itself.

## Role In The Pipeline

```text
Bitmagnet -> Prowlarr -> Radarr/Sonarr -> RDTClient -> debrid provider
```

Bitmagnet discovers torrent metadata via the public BitTorrent DHT. Prowlarr exposes its results to Radarr and Sonarr like any other indexer. RDTClient sends the selected magnet to the debrid provider and downloads the provider-cached result over HTTPS. Bitmagnet does not replace RDTClient and does not touch the media library directly — it has no media volume mounted.

## VPN Requirement

Bitmagnet's crawler directly participates in the public DHT and asks peers for torrent metadata, which can expose the home public IP to DHT nodes and metadata peers. This is different from RDTClient's provider-HTTPS download path. For that reason, Bitmagnet is routed through the existing `debrid-gluetun` VPN namespace (`network_mode: "service:gluetun"`), while RDTClient deliberately stays on the direct Docker network for better throughput:

| Mode | Result |
|---|---|
| Bitmagnet through `debrid-gluetun` | Current design — hides the home IP from DHT/metadata peers and fails closed with Gluetun |
| Bitmagnet without VPN | Works, but exposes the home IP to DHT/metadata traffic |
| RDTClient without VPN (current) | Direct provider HTTPS path for better routing/throughput |
| RDTClient through `debrid-gluetun` | Optional, not used — would add ISP privacy at the cost of throughput |

## Current Configuration

| Item | Value |
|---|---|
| Docker VM | `192.168.1.20` |
| Independent debrid stack | `/opt/stacks/debrid-stack` |
| Compose file | `/opt/stacks/debrid-stack/docker-compose.yml` |
| Debrid Gluetun container | `debrid-gluetun` |
| RDTClient container | `debrid-rdt-client` |
| Bitmagnet container | `debrid-bitmagnet` |
| PostgreSQL container | `debrid-bitmagnet-postgres` |
| Live database storage | `/srv/appdata/bitmagnet/postgres` (local ext4, not NFS) |
| Bitmagnet config | `/srv/appdata/bitmagnet/config` |
| Bitmagnet WebUI | `http://192.168.1.20:3333` |
| Prowlarr Torznab URL | `http://192.168.1.20:3333/torznab/` |

Bitmagnet shares `debrid-gluetun`'s network namespace, so its port (`3333`, serving both WebUI and Torznab) is published on the Gluetun container, not on Bitmagnet itself. PostgreSQL stays on the internal `debrid` bridge network with no published port (`5432` is never exposed).

The live PostgreSQL data directory is kept on the Docker VM's local ext4 disk rather than the TrueNAS NFS mount, because the database needs local block-storage semantics and performs frequent small writes; it is protected instead by Proxmox VM backups and scheduled `pg_dump` exports to TrueNAS (`/mnt/main/appdata/backups/bitmagnet`).

## Integration With Prowlarr

Prowlarr reaches Bitmagnet over the Docker VM's LAN address (`192.168.1.20:3333`), not `127.0.0.1` or a Docker service name — Prowlarr (in the main ARR stack) and Bitmagnet (in the independent debrid stack) are different Compose projects on different network namespaces:

```text
Prowlarr in main ARR stack
  -> Docker VM LAN 192.168.1.20:3333
  -> debrid-gluetun published port
  -> Bitmagnet shared Gluetun namespace
```

Prowlarr's built-in "Bitmagnet" indexer type is not used for this layout, because its URL field only offers same-network addresses (`http://bitmagnet:3333`, `http://127.0.0.1:3333`) that cannot reach the independent stack. Instead, Prowlarr is configured with a Generic Torznab indexer pointed at the LAN URL.

## Search Behavior

Bitmagnet starts with an empty local index and learns from DHT traffic over time, so search coverage is sparse immediately after deployment and improves as the crawler runs continuously. A personal TMDB API key (optional, set via `BITMAGNET_TMDB_API_KEY`) does not discover more torrents but substantially improves movie/TV classification throughput; an empty key value is left commented out in Compose rather than passed, since passing it empty would override Bitmagnet's built-in shared default key. The default `DHT_CRAWLER_SCALING_FACTOR` of `10` is kept — Bitmagnet's own documentation warns of diminishing returns above that value.

## References

- [Bitmagnet installation](https://bitmagnet.io/setup/installation.html)
- [Bitmagnet configuration](https://bitmagnet.io/setup/configuration.html)
- [Bitmagnet Servarr integration](https://bitmagnet.io/guides/servarr-integration.html)
- [Gluetun Docker port mapping](https://github.com/qdm12/gluetun-wiki/blob/main/setup/port-mapping.md)
