# Pi-hole Local DNS and Filtering Guide

Last updated: 2026-06-10

This guide deploys Pi-hole as the LAN DNS filter for the homelab.

Use this after the Ubuntu Docker VM is stable. Do not run Pi-hole on TrueNAS; TrueNAS remains storage only.

## Current Placement

| Component | Location |
|---|---|
| Pi-hole container | Ubuntu Docker VM `192.168.1.20` |
| DNS service | Docker VM ports `53/tcp` and `53/udp` |
| Pi-hole web UI | `http://192.168.1.20:8081/admin` |
| Pi-hole config | Local Docker VM disk at `/opt/stacks/pihole/etc-pihole` |
| Pi-hole backups | Export/sync to TrueNAS-backed `/mnt/main/backups/pihole` |
| DHCP | Keep on router unless router DHCP cannot advertise Pi-hole DNS |
| Local DNS records | Pi-hole |
| Public exposure | Never |

Pi-hole should be reachable from LAN and Tailscale management only. Do not expose DNS port `53` or the Pi-hole web UI through Cloudflare Tunnel, router forwarding, or direct internet NAT.

This guide intentionally keeps Pi-hole's live config local on the Docker VM. Most service appdata can live on TrueNAS, but DNS is infrastructure. If TrueNAS or NFS is down, the LAN should still be able to resolve DNS and reach the recovery docs, router, Proxmox, and TrueNAS UI.

## Sources Checked

- [Pi-hole Docker documentation](https://docs.pi-hole.net/docker/)
- [Pi-hole Docker configuration](https://docs.pi-hole.net/docker/configuration/)
- [Pi-hole Docker DHCP and network modes](https://docs.pi-hole.net/docker/dhcp/)
- [Pi-hole interface binding behavior](https://docs.pi-hole.net/ftldns/interfaces/)
- [Pi-hole upstream DNS providers](https://docs.pi-hole.net/guides/dns/upstream-dns-providers/)
- [Pi-hole per-client group examples](https://docs.pi-hole.net/group_management/example/)
- [HaGeZi DNS blocklists](https://github.com/hagezi/dns-blocklists)
- [OISD domain blocklist](https://oisd.nl/)
- [StevenBlack hosts](https://github.com/StevenBlack/hosts)
- [URLhaus host file notes](https://urlhaus.abuse.ch/api/)

## Design Rules

1. Router stays the default gateway.
2. Router DHCP hands out Pi-hole as DNS.
3. Pi-hole forwards upstream to reputable resolvers.
4. Pi-hole blocks ads, trackers, malware, phishing, and known bypass methods.
5. Firewall rules prevent clients from quietly bypassing Pi-hole.
6. Filtering starts moderate, then tightens after false positives are understood.

Avoid the common mistake of adding every blocklist you can find. Large overlapping lists increase update time, memory usage, and false positives without giving proportional protection.

## Step 1: Reserve The Docker VM IP

In the router, confirm the Docker VM has a DHCP reservation:

```text
Docker VM -> 192.168.1.20
```

If this IP changes, every client DNS setting and local DNS record breaks.

## Step 2: Check Port 53 On The Docker VM

On the Docker VM:

```bash
sudo ss -tulpn | grep ':53 '
```

If `systemd-resolved` is binding DNS locally and Docker cannot publish port `53`, disable only the local stub listener.

If you already followed the ARR/Docker VM guide and configured DNS-over-TLS on the Docker VM, preserve that resolver configuration. Do not replace it with router or ISP DNS.

```bash
sudo nano /etc/systemd/resolved.conf
```

Good baseline if the Docker VM does not already have hardened DNS:

```ini
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net
FallbackDNS=
DNSOverTLS=yes
DNSStubListener=no
```

Then:

```bash
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
sudo systemctl restart systemd-resolved
```

Re-check port `53` before starting Pi-hole.

Do not point the Docker VM host resolver at `192.168.1.20` while Pi-hole is hosted on the same VM. Keep the host resolver independent so Docker can pull images and recover Pi-hole if the container is stopped.

## Step 3: Create The Compose Folder

On the Docker VM:

```bash
sudo mkdir -p /opt/stacks/pihole/etc-pihole
sudo chown -R "$USER":"$USER" /opt/stacks/pihole
cd /opt/stacks/pihole
```

This path is deliberately not under `/mnt/main/appdata`. Keeping live Pi-hole state off NFS avoids a DNS outage when TrueNAS storage is unavailable.

`$USER` should resolve to your Docker VM login user, for example `alice`. Do not use `dockeradmin` unless you actually created that user on the Docker VM.

Create `.env`:

```bash
nano .env
```

Use a strong unique password:

```env
PIHOLE_WEB_PASSWORD=replace-with-a-long-random-password
TZ=Europe/Berlin
```

Do not reuse router, Proxmox, TrueNAS, SSH, or Vaultwarden passwords.

## Step 4: Create `docker-compose.yml`

Create:

```bash
nano docker-compose.yml
```

Use:

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

Notes:

- `FTLCONF_dns_listeningMode: "ALL"` is intentional for Docker bridge networking.
- Safety comes from LAN-only routing and firewall rules, not from exposing Pi-hole to the internet.
- `1.1.1.2` and `1.0.0.2` are Cloudflare malware-blocking resolvers.
- `9.9.9.9` and `149.112.112.112` are Quad9 filtered resolvers.
- Do not map port `443` for Pi-hole. Keep `443` available for Traefik later.
- Do not enable Pi-hole DHCP in Docker for the first deployment.

## Step 5: Start Pi-hole

On the Docker VM:

```bash
cd /opt/stacks/pihole
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=100 pihole
```

Open:

```text
http://192.168.1.20:8081/admin
```

Log in with `PIHOLE_WEB_PASSWORD`.

## Step 6: First DNS Test

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

In the Pi-hole UI, check:

1. Dashboard shows incoming queries.
2. Query Log shows the client IPs you expect.
3. Tools -> Update Gravity completes successfully.
4. Settings -> DNS shows the upstreams from the compose file.

## Step 7: Point The LAN To Pi-hole

In the router DHCP settings, set DNS server:

```text
Primary DNS: 192.168.1.20
Secondary DNS: blank
```

Do not set the router, ISP DNS, Google DNS, or Cloudflare DNS as secondary DNS for clients. Many clients treat secondary DNS as "use either one", not "use only if primary fails".

After changing DHCP, renew one client lease:

```bash
ipconfig /release
ipconfig /renew
ipconfig /all
```

On Linux:

```bash
sudo resolvectl flush-caches
nmcli networking off
nmcli networking on
resolvectl dns
```

Confirm the client uses only:

```text
192.168.1.20
```

## Step 8: Add Local DNS Records

In Pi-hole:

```text
Local DNS -> DNS Records
```

Add:

| Domain | IP | Purpose |
|---|---:|---|
| `proxmox.local` | `192.168.1.2` | Proxmox UI and SSH |
| `truenas.local` | `192.168.1.10` | TrueNAS UI and storage |
| `docker.local` | `192.168.1.20` | Docker VM |
| `pihole.local` | `192.168.1.20` | Pi-hole UI |
| `media.example.com` | `192.168.1.20` | Jellyfin through Traefik later |
| `cloud.example.com` | `192.168.1.20` | Nextcloud through Traefik later |
| `vault.example.com` | `192.168.1.20` | Vaultwarden through Traefik later |
| `dash.example.com` | `192.168.1.20` | Dashboard through Traefik later |

This gives split DNS: LAN clients reach internal services directly instead of hairpinning through Cloudflare or the public internet.

## Step 9: Choose A Blocklist Profile

Start with one of these profiles. Do not install all of them together.

| Profile | Lists | Use When |
|---|---|---|
| Conservative | Pi-hole default list + [OISD Big](https://big.oisd.nl/) | You want low maintenance and fewer broken sites. |
| Balanced recommended | Pi-hole default list + [HaGeZi Multi Pro](https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.txt) | You want stronger privacy and threat blocking with manageable false positives. |
| Classic lightweight | Pi-hole default list + [StevenBlack hosts](https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts) | You want a smaller, long-running community-curated hosts list. |

Recommended starting point for this homelab:

```text
Pi-hole default list
HaGeZi Multi Pro
```

Let that run for several days before adding stricter lists.

## Step 10: Add Security-Focused Lists

Add these only after the balanced profile is stable.

| List | URL | Notes |
|---|---|---|
| HaGeZi TIF Mini | `https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/tif.mini.txt` | Threat intelligence for malware, phishing, scam, spam, and command-and-control domains. Lower resource impact than full TIF. |
| HaGeZi DoH/VPN/TOR/Proxy Bypass | `https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/doh-vpn-proxy-bypass.txt` | Helps stop clients from bypassing Pi-hole with encrypted DNS, VPN, Tor, and proxy endpoints. Must be paired with firewall rules. |
| URLhaus hostfile | `https://urlhaus.abuse.ch/downloads/hostfile/` | Malware-distribution hostnames from abuse.ch. Use if the direct feed remains available and updates cleanly in Gravity. |

Do not add HaGeZi full TIF first. The full list is very large and should only be used if the Docker VM has enough memory and you are willing to troubleshoot false positives.

## Step 11: Optional Family / Adult Filtering

For adult-content filtering, use one of these approaches:

| Option | Use When | Notes |
|---|---|---|
| Cloudflare Families upstream | You want DNS-provider-level malware and adult filtering. | Use `1.1.1.3;1.0.0.3` as upstreams instead of `1.1.1.2;1.0.0.2`. |
| OISD NSFW | You want a Pi-hole-managed NSFW list. | Add `https://nsfw.oisd.nl/` to a strict group. |
| Separate Pi-hole group | You only want filtering for some devices. | Create a `Strict` group and assign kid/guest/IoT clients to it. |

Do not apply adult filtering globally unless everyone using the network expects it. Use groups for per-client policy.

## Step 12: Create Pi-hole Groups

In Pi-hole:

```text
Groups -> Groups
```

Create:

| Group | Devices | Lists |
|---|---|---|
| `Default` | Normal trusted clients | Default + balanced recommended list |
| `Strict` | Guest, kid, IoT, smart TV | Default + balanced + TIF Mini + DoH bypass + optional NSFW |
| `Bypass` | Temporary troubleshooting only | No adlists, or minimal list |

Then:

```text
Groups -> Clients
```

Assign devices by static IP, MAC-derived client entry, or hostname. Prefer DHCP reservations so group membership stays stable.

## Step 13: Enforce DNS At The Router / Firewall

Pi-hole filtering is only reliable if clients cannot silently use other DNS resolvers.

Minimum router rules:

| Rule | Action |
|---|---|
| Allow LAN -> `192.168.1.20` TCP/UDP `53` | Permit DNS to Pi-hole |
| Block LAN -> internet TCP/UDP `53` | Stop direct classic DNS bypass |
| Block LAN -> internet TCP/UDP `853` | Stop DNS-over-TLS and DNS-over-QUIC |
| Allow `192.168.1.20` -> internet TCP/UDP `53` | Let Pi-hole reach upstream DNS |

If your router supports NAT redirect:

```text
Redirect LAN TCP/UDP 53 to 192.168.1.20
```

This catches hardcoded DNS on many IoT devices.

Do not redirect DNS from the Pi-hole host itself back to Pi-hole. Exclude `192.168.1.20` from redirect rules or you can create a DNS loop.

## Step 14: Protect Pi-hole Itself

Firewall access rules:

| Service | Port | Allow From | Block From |
|---|---:|---|---|
| DNS | `53/tcp`, `53/udp` | LAN, selected Tailscale clients if needed | Internet |
| Web UI | `8081/tcp` | Admin LAN clients, Tailscale admin clients | Guest, IoT, internet |
| SSH to Docker VM | `22/tcp` | Admin LAN and Tailscale only | Guest, IoT, internet |

Pi-hole interface setting should remain safe for local use. The official Pi-hole docs recommend "allow only local requests" for non-Docker installs; this Docker bridge deployment uses `ALL` because the container is behind Docker port publishing. Do not confuse that with permission to expose DNS publicly.

## Step 15: Update And Backup

Weekly:

```bash
cd /opt/stacks/pihole
docker compose pull
docker compose up -d
docker exec pihole pihole -g
docker compose logs --tail=100 pihole
```

Before major Pi-hole upgrades:

1. In the UI, use Settings -> Teleporter to export configuration.
2. Back up `/opt/stacks/pihole/etc-pihole`.
3. Copy the export to TrueNAS-backed storage, for example `/mnt/main/backups/pihole`.
4. Snapshot the Docker VM if available.
5. Read the Pi-hole Docker release notes.
6. Pull and restart only after you have a rollback path.

## Step 16: Validation Checklist

| Check | Expected Result |
|---|---|
| `nslookup pi-hole.net 192.168.1.20` | Resolves |
| `nslookup doubleclick.net 192.168.1.20` | Blocked or returns Pi-hole blocking response |
| Client DNS settings | Only `192.168.1.20` |
| Pi-hole query log | Shows client queries |
| Router firewall | Blocks client DNS to internet |
| `https://1.1.1.1/help` | Shows normal browsing still works |
| Pi-hole web UI | Reachable from admin LAN, not from guest/IoT |
| Local DNS | `proxmox.local`, `truenas.local`, and `pihole.local` resolve |

## Troubleshooting

### Pi-hole Container Will Not Start

Check port conflicts:

```bash
sudo ss -tulpn | grep -E ':53 |:8081 '
docker compose logs pihole
```

If port `53` is busy, fix `systemd-resolved` or any other local DNS service before retrying.

### Clients Still Show Ads

Check:

1. Client DNS is only `192.168.1.20`.
2. Browser secure DNS / DNS-over-HTTPS is disabled or controlled.
3. Router is not advertising itself as DNS.
4. IPv6 DHCP/router advertisements are not handing out ISP DNS.
5. Query Log shows the client actually asking Pi-hole.

### Some Websites Break

Use:

```text
Query Log -> filter blocked queries for that client
```

Temporarily allowlist the smallest exact domain required. Do not disable all blocking unless you are isolating the cause.

Common breakage areas:

- Bank login redirects.
- Shopping referral links.
- Smart TV app telemetry dependencies.
- Mobile app analytics domains that are also used for app function.
- Captive portals on public Wi-Fi when using VPN back to home.

### DNS Works On LAN But Not Over Tailscale

Decide whether Tailscale clients should use home Pi-hole.

If yes:

1. Allow Tailscale source ranges to reach `192.168.1.20:53`.
2. Configure Tailscale DNS to use Pi-hole or advertise the LAN subnet route.
3. Confirm no Tailscale DNS override is forcing another resolver.

If no, leave Tailscale DNS alone and use Pi-hole only on LAN.

## Rollback

If Pi-hole breaks DNS for the house:

1. In the router DHCP settings, change DNS back to router or a known resolver.
2. Renew client DHCP leases.
3. Stop Pi-hole:

```bash
cd /opt/stacks/pihole
docker compose down
```

4. Fix Pi-hole offline.
5. Re-enable router DHCP DNS to `192.168.1.20` only after validation passes.
