# Pi-hole

Pi-hole is the LAN DNS resolver and filter for the homelab. It runs as a container on the Ubuntu Docker VM and is the only DNS server LAN clients should use.

## Placement

| Component | Location |
|---|---|
| Pi-hole container | Ubuntu Docker VM, `192.168.1.20` |
| DNS service | Docker VM ports `53/tcp` and `53/udp` |
| Pi-hole web UI | `http://192.168.1.20:8081/admin` |
| Pi-hole config | Local Docker VM disk, `/opt/stacks/pihole/etc-pihole` |
| Pi-hole backups | Exported/synced to TrueNAS-backed `/mnt/main/backups/pihole` |
| DHCP | Stays on the router |
| Local DNS records | Managed in Pi-hole |
| Public exposure | Never |

Pi-hole's live configuration is deliberately kept on local Docker VM disk rather than TrueNAS NFS: DNS is infrastructure, so the LAN must still be able to resolve names (router, Proxmox, TrueNAS UI, recovery docs) even if TrueNAS/NFS is down. TrueNAS is only used for the backup copy. Pi-hole does not run on TrueNAS — TrueNAS remains storage-only.

## DNS Configuration

Pi-hole's upstreams are a mix of Quad9 and Cloudflare filtered resolvers (`9.9.9.9;149.112.112.112;1.1.1.2;1.0.0.2` — the `.2` Cloudflare addresses are malware-blocking resolvers), with DNSSEC enabled. `FTLCONF_dns_listeningMode` is set to `ALL` because Pi-hole runs behind Docker bridge networking; safety comes from LAN-only routing and firewall rules, not from restricting the DNS listener.

The router remains the DHCP server and default gateway; DHCP hands out Pi-hole (`192.168.1.20`) as the sole DNS server (no secondary DNS, since many clients treat a secondary as "use either," not "failover only").

### Local DNS records

Pi-hole provides split-DNS so LAN clients resolve internal services directly instead of hairpinning through the public internet, including entries such as `proxmox.local`, `truenas.local`, `docker.local`, `pihole.local`, and the Traefik-routed service hostnames (`media.example.com`, `cloud.example.com`, `vault.example.com`, `dash.example.com`, etc.), all pointed at the relevant internal IP.

### Blocklists And Groups

The current blocklist profile is the "balanced" tier: the Pi-hole default list plus HaGeZi Multi Pro. Additional security-focused lists (HaGeZi TIF Mini, HaGeZi DoH/VPN/TOR/Proxy Bypass, URLhaus hostfile) can be layered on after the base profile is stable; the full HaGeZi TIF list is avoided due to its size and false-positive rate relative to available memory.

Pi-hole groups are used for per-client policy:

| Group | Devices | Lists |
|---|---|---|
| `Default` | Normal trusted clients | Default + balanced recommended list |
| `Strict` | Guest, kid, IoT, smart TV | Default + balanced + TIF Mini + DoH bypass + optional NSFW |
| `Bypass` | Temporary troubleshooting only | No adlists, or minimal list |

Optional adult-content filtering is applied per-group (not globally) via either Cloudflare Families upstream (`1.1.1.3;1.0.0.3`) or an OISD NSFW list assigned to the `Strict` group.

## Enforcement

Router/firewall rules permit LAN clients to reach only `192.168.1.20` on DNS ports (`53/tcp`, `53/udp`), block LAN clients from reaching the internet directly on `53` and `853` (classic DNS and DoT/DoQ bypass), and allow Pi-hole itself to reach upstream resolvers. Where supported, the router NAT-redirects LAN `53` traffic to Pi-hole to catch hardcoded DNS on IoT devices (excluding the Pi-hole host itself, to avoid a redirect loop). The Pi-hole web UI (`8081`) and Docker VM SSH (`22`) are restricted to admin LAN/Tailscale clients only.

Tailscale clients can optionally be pointed at the same Pi-hole instance if the tailnet is configured to allow reaching `192.168.1.20:53` and advertise/override DNS accordingly; otherwise Tailscale clients use their own DNS and Pi-hole filtering only applies on LAN.
