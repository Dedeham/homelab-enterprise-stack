# Pi-hole Setup And Testing

Deploys Pi-hole as the LAN DNS filter. See [docs/services/pihole.md](../../services/pihole.md) for the resulting configuration.

Do this after the Ubuntu Docker VM is stable. Do not run Pi-hole on TrueNAS.

Design rules followed by this setup:

1. Router stays the default gateway.
2. Router DHCP hands out Pi-hole as DNS.
3. Pi-hole forwards upstream to reputable resolvers.
4. Pi-hole blocks ads, trackers, malware, phishing, and known bypass methods.
5. Firewall rules prevent clients from quietly bypassing Pi-hole.
6. Filtering starts moderate, then tightens after false positives are understood — do not add every blocklist you can find at once.

## Step 1: Reserve the Docker VM IP

In the router, confirm the Docker VM has a DHCP reservation at `192.168.1.20`. If this IP changes later, every client DNS setting and local DNS record breaks.

## Step 2: Check port 53 on the Docker VM

```bash
sudo ss -tulpn | grep ':53 '
```

If `systemd-resolved` is binding DNS locally and blocking Docker from publishing port `53`, disable only the local stub listener. If DNS-over-TLS is already configured on the Docker VM, preserve it rather than falling back to router/ISP DNS:

```bash
sudo nano /etc/systemd/resolved.conf
```

```ini
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net
FallbackDNS=
DNSOverTLS=yes
DNSStubListener=no
```

```bash
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
sudo systemctl restart systemd-resolved
```

Re-check port `53` before starting Pi-hole. Do not point the Docker VM's own host resolver at `192.168.1.20` while Pi-hole runs on that same VM — keep the host resolver independent so Docker can pull images and recover Pi-hole if the container stops.

## Step 3: Create the compose folder

```bash
sudo mkdir -p /opt/stacks/pihole/etc-pihole
sudo chown -R "$USER":"$USER" /opt/stacks/pihole
cd /opt/stacks/pihole
```

This path is deliberately not under `/mnt/main/appdata`, so a TrueNAS/NFS outage doesn't take DNS down with it.

`.env`:

```env
PIHOLE_WEB_PASSWORD=replace-with-a-long-random-password
TZ=Europe/Berlin
```

Use a strong unique password; do not reuse router, Proxmox, TrueNAS, SSH, or Vaultwarden passwords.

## Step 4: Create `docker-compose.yml`

```yaml
services:
  pihole:
    image: pihole/pihole:latest
    container_name: pihole
    restart: unless-stopped
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "8081:80/tcp"
    environment:
      TZ: ${TZ}
      FTLCONF_webserver_api_password: ${PIHOLE_WEB_PASSWORD}
      FTLCONF_dns_listeningMode: "ALL"
      FTLCONF_dns_upstreams: "9.9.9.9;149.112.112.112;1.1.1.2;1.0.0.2"
      FTLCONF_dns_dnssec: "true"
    volumes:
      - ./etc-pihole:/etc/pihole
    cap_add:
      - SYS_NICE
```

Notes: `FTLCONF_dns_listeningMode: "ALL"` is intentional for Docker bridge networking — safety comes from LAN-only routing and firewall rules, not from the listening mode. `1.1.1.2`/`1.0.0.2` are Cloudflare malware-blocking resolvers; `9.9.9.9`/`149.112.112.112` are Quad9 filtered resolvers. Do not map port `443` (reserved for Traefik). Do not enable Pi-hole's own DHCP for the first deployment.

## Step 5: Start Pi-hole

```bash
cd /opt/stacks/pihole
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=100 pihole
```

Open `http://192.168.1.20:8081/admin` and log in with `PIHOLE_WEB_PASSWORD`.

## Step 6: First DNS test

From a LAN workstation:

```bash
nslookup pi-hole.net 192.168.1.20
nslookup doubleclick.net 192.168.1.20
```

From the Docker VM:

```bash
docker exec pihole pihole status
docker exec pihole pihole -g
```

In the UI, confirm the dashboard shows incoming queries, the Query Log shows expected client IPs, Tools → Update Gravity completes, and Settings → DNS shows the configured upstreams.

## Step 7: Point the LAN to Pi-hole

In the router DHCP settings:

```text
Primary DNS: 192.168.1.20
Secondary DNS: blank
```

Do not set router/ISP/Google/Cloudflare DNS as secondary — many clients treat secondary as "use either," not failover-only.

Renew one client's lease and confirm it only uses `192.168.1.20`:

```bash
ipconfig /release
ipconfig /renew
ipconfig /all
```

```bash
sudo resolvectl flush-caches
nmcli networking off
nmcli networking on
resolvectl dns
```

## Step 8: Add local DNS records

In Pi-hole, **Local DNS → DNS Records**, add entries such as:

| Domain | IP | Purpose |
|---|---:|---|
| `proxmox.local` | `192.168.1.2` | Proxmox UI and SSH |
| `truenas.local` | `192.168.1.10` | TrueNAS UI and storage |
| `docker.local` | `192.168.1.20` | Docker VM |
| `pihole.local` | `192.168.1.20` | Pi-hole UI |
| `media.example.com` | `192.168.1.20` | Jellyfin via Traefik |
| `cloud.example.com` | `192.168.1.20` | Nextcloud via Traefik |
| `vault.example.com` | `192.168.1.20` | Vaultwarden via Traefik |
| `dash.example.com` | `192.168.1.20` | Dashboard via Traefik |

## Step 9: Choose a blocklist profile

Start with exactly one profile:

| Profile | Lists | Use when |
|---|---|---|
| Conservative | Pi-hole default + [OISD Big](https://big.oisd.nl/) | Low maintenance, fewer broken sites |
| Balanced (recommended) | Pi-hole default + [HaGeZi Multi Pro](https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.txt) | Stronger privacy/threat blocking, manageable false positives |
| Classic lightweight | Pi-hole default + [StevenBlack hosts](https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts) | Smaller, long-running curated list |

Let the balanced profile run for several days before adding stricter lists.

## Step 10: Add security-focused lists (after the base profile is stable)

| List | URL | Notes |
|---|---|---|
| HaGeZi TIF Mini | `https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/tif.mini.txt` | Threat intel, lower resource cost than full TIF |
| HaGeZi DoH/VPN/TOR/Proxy Bypass | `https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/doh-vpn-proxy-bypass.txt` | Must be paired with firewall rules |
| URLhaus hostfile | `https://urlhaus.abuse.ch/downloads/hostfile/` | Malware-distribution hostnames |

Avoid the full HaGeZi TIF list unless the Docker VM has memory to spare and you're prepared to troubleshoot false positives.

## Step 11: Optional family/adult filtering

| Option | Use when | Notes |
|---|---|---|
| Cloudflare Families upstream | Want provider-level malware+adult filtering | Use `1.1.1.3;1.0.0.3` instead of `1.1.1.2;1.0.0.2` |
| OISD NSFW | Want a Pi-hole-managed NSFW list | Add `https://nsfw.oisd.nl/` to a strict group |
| Separate Pi-hole group | Only some devices need it | Create a `Strict` group, assign kid/guest/IoT clients |

Do not apply adult filtering globally unless everyone on the network expects it.

## Step 12: Create Pi-hole groups

**Groups → Groups**:

| Group | Devices | Lists |
|---|---|---|
| `Default` | Normal trusted clients | Default + balanced |
| `Strict` | Guest, kid, IoT, smart TV | Default + balanced + TIF Mini + DoH bypass + optional NSFW |
| `Bypass` | Temporary troubleshooting only | No adlists, or minimal |

Then **Groups → Clients**, and assign devices by static IP/MAC/hostname (prefer DHCP reservations so membership stays stable).

## Step 13: Enforce DNS at the router/firewall

| Rule | Action |
|---|---|
| Allow LAN → `192.168.1.20` TCP/UDP `53` | Permit DNS to Pi-hole |
| Block LAN → internet TCP/UDP `53` | Stop direct DNS bypass |
| Block LAN → internet TCP/UDP `853` | Stop DoT/DoQ bypass |
| Allow `192.168.1.20` → internet TCP/UDP `53` | Let Pi-hole reach upstream |

If supported, add a NAT redirect for LAN `53` → `192.168.1.20` to catch hardcoded IoT DNS — exclude the Pi-hole host itself from the redirect to avoid a DNS loop.

## Step 14: Protect Pi-hole itself

| Service | Port | Allow from | Block from |
|---|---:|---|---|
| DNS | `53/tcp`, `53/udp` | LAN, selected Tailscale clients | Internet |
| Web UI | `8081/tcp` | Admin LAN/Tailscale clients | Guest, IoT, internet |
| SSH to Docker VM | `22/tcp` | Admin LAN/Tailscale only | Guest, IoT, internet |

This Docker bridge deployment intentionally uses `FTLCONF_dns_listeningMode: ALL` (vs. the non-Docker "local requests only" default) because the container sits behind Docker port publishing — that is not permission to expose DNS publicly.

## Step 15: Update and backup

Weekly:

```bash
cd /opt/stacks/pihole
docker compose pull
docker compose up -d
docker exec pihole pihole -g
docker compose logs --tail=100 pihole
```

Before major upgrades: export config via Settings → Teleporter, back up `/opt/stacks/pihole/etc-pihole`, copy the export to `/mnt/main/backups/pihole`, snapshot the Docker VM if available, read the release notes, and only pull/restart once you have a rollback path.

## Step 16: Validation checklist

| Check | Expected result |
|---|---|
| `nslookup pi-hole.net 192.168.1.20` | Resolves |
| `nslookup doubleclick.net 192.168.1.20` | Blocked |
| Client DNS settings | Only `192.168.1.20` |
| Pi-hole query log | Shows client queries |
| Router firewall | Blocks client DNS to internet |
| `https://1.1.1.1/help` | Normal browsing still works |
| Pi-hole web UI | Reachable from admin LAN, not guest/IoT |
| Local DNS | `proxmox.local`, `truenas.local`, `pihole.local` resolve |

## Troubleshooting

### Pi-hole container will not start

```bash
sudo ss -tulpn | grep -E ':53 |:8081 '
docker compose logs pihole
```

If port `53` is busy, fix `systemd-resolved` (or another local DNS service) before retrying.

### Clients still show ads

Check: client DNS is only `192.168.1.20`; browser secure DNS/DoH is disabled or controlled; the router isn't also advertising itself as DNS; IPv6 RA/DHCP isn't handing out ISP DNS; Query Log shows the client actually asking Pi-hole.

### Some websites break

Use Query Log, filter blocked queries for that client, and allowlist the smallest exact domain required rather than disabling all blocking. Common breakage: bank login redirects, shopping referral links, smart TV telemetry, mobile app analytics that double as app function, captive portals when VPN'd home.

### DNS works on LAN but not over Tailscale

If Tailscale clients should use home Pi-hole: allow Tailscale source ranges to reach `192.168.1.20:53`, configure Tailscale DNS to use Pi-hole or advertise the LAN subnet route, and confirm no Tailscale DNS override forces another resolver. Otherwise leave Tailscale DNS alone and use Pi-hole LAN-only.

## Rollback

If Pi-hole breaks DNS for the house:

1. In router DHCP settings, change DNS back to router/a known resolver.
2. Renew client DHCP leases.
3. `cd /opt/stacks/pihole && docker compose down`
4. Fix Pi-hole offline.
5. Re-enable router DHCP DNS to `192.168.1.20` only after validation passes.
