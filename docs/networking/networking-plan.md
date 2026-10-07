# Networking — Secure Remote Access & Network Topology

> [!IMPORTANT]
> **Current deployment correction (2026-06-09):** For this homelab, TrueNAS is
> storage only. Docker services, Traefik, Pi-hole, Jellyfin, ARR apps, and
> other containers belong on the Ubuntu Docker VM, not on TrueNAS. Tailscale is
> already set up for remote management. Hermes is isolated on `10.10.100.2`.

For the canonical IP table, use [network-reference.md](network-reference.md).
For step-by-step setup and testing procedures referenced below, see
[docs/setup-and-testing/networking/](../setup-and-testing/networking/).

> **Philosophy: Zero trust from the outside, defense in depth on the inside.**
> No ports open to the internet except through encrypted tunnels. All management
> access via VPN. Public-facing services behind Cloudflare Tunnel. Internal
> services firewalled per-VLAN.

## Network Topology Overview

```
                          +--------------+
                          |   INTERNET   |
                          +------+-------+
                                 |
                    +------------+------------+
                    |     HOME ROUTER         |
                    |  (ISP-provided or own)  |
                    |                         |
                    |  WAN: Public IP (DHCP)  |
                    |  LAN: 192.168.1.1/24    |
                    |                         |
                    |  Port forwarding:       |
                    |  ❌ NONE (see below)    |
                    +------------+------------+
                                 | LAN
                                 |
        +------------------------+------------------------+
        |                        |                         |
        |                  +-----+------+                  |
        |                  |  PROXMOX   |                  |
        |                  | 192.168.1.2 |                  |
        |                  +-----+------+                  |
        |                        |                         |
   +----+------------------------+---------------------+   |
   |              vmbr0 (Main Bridge)                  |   |
   |                             |                     |   |
   |  +------------------+  +------------------+      |   |
   |  | TrueNAS          |  | Docker VM        |      |   |
   |  | 192.168.1.10     |  | 192.168.1.20     |      |   |
   |  | Storage only:    |  | Services:        |      |   |
   |  | • ZFS datasets   |  | • Traefik        |      |   |
   |  | • NFS/SMB        |  | • ARR stack      |      |   |
   |  | • Snapshots      |  | • Jellyfin       |      |   |
   |  |                  |  | • Pi-hole        |      |   |
   |  +------------------+  +------------------+      |   |
   +--------------------------------------------------+   |
                                                          |
   +--------------------------------------------------+   |
   |              vmbr1 (Isolated Bridge)              |   |
   |              10.10.100.0/24                       |   |
   |                                                   |   |
   |  +--------------+                                 |   |
   |  | Hermes       |                                 |   |
   |  | .100.2       |                                 |   |
   |  +--------------+                                 |   |
   |                                                   |   |
   |  Rules: Internet OUT ✅ | LAN access ❌           |   |
   +--------------------------------------------------+   |
                                                          |
   +--------------------------------------------------+   |
   |         Tailscale Mesh (Overlay Network)          |   |
   |         100.x.x.x/32 (WireGuard tunnel)           |   |
   |                                                   |   |
   |   Laptop ◄---- encrypted ----► TrueNAS            |   |
   |   Phone  ◄---- encrypted ----► Proxmox            |   |
   |                                                   |   |
   |   Access: Management UIs, SSH, file shares        |   |
   +--------------------------------------------------+   |
        +-------------------------------------------------+
```

## IP Address Plan

### VLAN / Subnet Layout

| Subnet | Bridge | Purpose | DHCP |
|---|---|---|---|
| `192.168.1.0/24` | `vmbr0` | Main LAN — servers + clients | Router DHCP |
| `10.10.100.0/24` | `vmbr1` | Isolated — Hermes VM | Static only |
| `100.x.x.x/32` | Tailscale | Remote access overlay (WireGuard) | Tailscale managed |

### Static IP Assignments

| Device | IP | MAC Reservation | Notes |
|---|---|---|---|
| **Router** | `192.168.1.1` | — | Default gateway |
| **Proxmox** | `192.168.1.2` | Yes | Hypervisor management |
| **TrueNAS** | `192.168.1.10` | Yes | Storage only |
| **Docker VM** | `192.168.1.20` | Yes | Docker services and ARR stack |
| **Hermes** | `10.10.100.2` | — | Isolated bridge |

Servers use static IPs or DHCP reservations. If TrueNAS were to get a new IP
after a router reboot, every NFS mount and DNS record would break.

## Remote Access Strategy

### The Golden Rule

Zero open ports on the router. No port forwarding, no exposed services.
Everything goes through encrypted tunnels. This eliminates entire categories
of attacks: port scanning, brute force, DDoS, and exploit attempts against
exposed services.

### Layer 1: Tailscale VPN (Management Access)

**Tailscale** is a zero-config mesh VPN built on WireGuard. It creates encrypted
point-to-point tunnels between devices without any port forwarding, and acts
as the access path for management interfaces (Proxmox, TrueNAS, SSH) and any
other LAN service reached without going through Cloudflare.

#### Why Tailscale Over Raw WireGuard

| Factor | Tailscale | Self-hosted WireGuard |
|---|---|---|
| **Port forwarding** | ❌ None needed | ✅ Need UDP 51820 open |
| **Setup complexity** | Install + login | Generate keys, configure endpoints, manage peers |
| **NAT traversal** | ✅ Automatic (DERP relays) | ⚠️ Manual, breaks behind CGNAT |
| **Key rotation** | ✅ Automatic | Manual |
| **Multi-device** | ✅ Easy (phone, laptop, tablet) | ⚠️ Manual config per device |
| **MagicDNS** | ✅ `truenas.tail1234.ts.net` | ❌ Remember IPs |
| **SSO/2FA** | ✅ Built-in (Google, GitHub, etc.) | ❌ Add manually |
| **ACLs** | ✅ Fine-grained in web UI | ❌ iptables on each peer |
| **Cost** | Free for 100 devices, 3 users | Free forever |
| **Trust** | ⚠️ Tailscale sees your metadata | ✅ Fully self-controlled |

If Tailscale's visibility into connection metadata is a concern, **Headscale**
(a self-hosted Tailscale control server) is an option to run on the Docker VM
instead of TrueNAS — it keeps the Tailscale protocol with zero third-party
trust.

TrueNAS is configured as a Tailscale **subnet router**, advertising
`192.168.1.0/24` so that remote devices can reach the whole LAN through it,
not just TrueNAS itself. Proxmox runs its own Tailscale node for direct
management access.

#### What Is Reachable Via Tailscale

| Service | URL/Address | From Where |
|---|---|---|
| Proxmox management | `https://proxmox:8006` or `https://100.x.x.x:8006` | Anywhere |
| TrueNAS management | `https://truenas:443` or `https://100.x.x.x:443` | Anywhere |
| SSH to TrueNAS | `ssh admin@truenas` | Anywhere |
| SSH to Proxmox | `ssh root@proxmox` | Anywhere |
| All web services | Via Traefik on Docker VM | Anywhere |
| SMB file shares | `\\truenas\share` | Anywhere (but slow over WAN) |

#### Tailscale ACLs

Access control in the Tailscale admin console grants the account owner
(`autogroup:owner`) access to everything, and tags servers (`tag:server`) so
that pre-authenticated server nodes do not expire and disconnect after the
default 180-day key lifetime.

### Layer 2: Cloudflare Tunnel (Public Web Services)

Services that need to be reachable **without VPN** (e.g. Nextcloud on a
phone, Jellyfin for streaming) go through **Cloudflare Tunnel** instead of
port forwarding.

#### How It Works

```
Phone (anywhere)
       |
       ▼ HTTPS
Cloudflare Edge (DDoS protection, WAF, caching)
       |
       ▼ Encrypted tunnel (outbound from the server)
Docker VM → cloudflared container → Traefik → Service
```

- **No port forwarding** — `cloudflared` makes an outbound connection to Cloudflare.
- **Free DDoS protection** — Cloudflare absorbs attacks before they reach the origin.
- **Free SSL certificates** — Cloudflare handles cert issuance and renewal.
- **WAF rules** — block by country, rate limit, challenge suspicious IPs.

This requires a domain name with DNS hosted in Cloudflare (free tier).

#### Public Hostname Mapping

| Public Hostname | Internal Service | Protocol |
|---|---|---|
| `cloud.example.com` | `http://traefik:80` or `http://localhost:8080` | HTTPS → HTTP |
| `media.example.com` | `http://traefik:80` | HTTPS → HTTP |
| `vault.example.com` | `http://traefik:80` | HTTPS → HTTP |

Cloudflare Access policies can additionally restrict who can reach each
service (e.g. OTP challenge limited to specific email addresses).

> [!CAUTION]
> **Management interfaces are never exposed through Cloudflare Tunnel:**
> - ❌ Proxmox UI (`https://proxmox:8006`)
> - ❌ TrueNAS UI (`https://truenas:443`)
> - ❌ SSH
> - ❌ Portainer
>
> These are reachable only via **Tailscale VPN**. If the Cloudflare account
> were ever compromised, the management plane would still be unreachable.

### Layer 3: SSH Hardening

SSH is the last-resort management tool and is locked down accordingly on
Proxmox, TrueNAS, and the Docker VM:

```text
# /etc/ssh/sshd_config

PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes

PermitRootLogin prohibit-password
AllowUsers root

KexAlgorithms sshd_default
Ciphers sshd_default
MACs sshd_default

MaxAuthTries 3
MaxSessions 3

X11Forwarding no
AllowAgentForwarding no

ClientAliveInterval 300
ClientAliveCountMax 2
```

SSH private keys are backed up to Vaultwarden (or an encrypted offline copy);
without a key backup and with password auth disabled, recovery would require
physical console access.

## Firewall Rules

### Proxmox Host Firewall

The Proxmox firewall is enabled at **Datacenter → Firewall → Options**.

#### Host-Level Rules

| Direction | Source | Dest | Port | Protocol | Action | Reason |
|---|---|---|---|---|---|---|
| IN | `192.168.1.0/24` | Proxmox | 8006 | TCP | ✅ Accept | Web UI from LAN |
| IN | `192.168.1.0/24` | Proxmox | 22 | TCP | ✅ Accept | SSH from LAN |
| IN | `100.64.0.0/10` | Proxmox | 8006 | TCP | ✅ Accept | Web UI via Tailscale |
| IN | `100.64.0.0/10` | Proxmox | 22 | TCP | ✅ Accept | SSH via Tailscale |
| IN | ANY | Proxmox | ANY | ANY | ❌ Drop | Block everything else |

#### VM-Level Rules: Hermes VM

| Direction | Source | Dest | Port | Protocol | Action | Reason |
|---|---|---|---|---|---|---|
| OUT | Hermes | `0.0.0.0/0` | 80,443 | TCP | ✅ Accept | Internet access |
| OUT | Hermes | `0.0.0.0/0` | 53 | UDP | ✅ Accept | DNS resolution |
| OUT | Hermes | `192.168.1.0/24` | ANY | ANY | ❌ Drop | Block LAN access |
| OUT | Hermes | `10.10.100.0/24` | ANY | ANY | ❌ Drop | Block isolated subnet lateral access |
| IN | ANY | Hermes | ANY | ANY | ❌ Drop | No inbound allowed |

### TrueNAS Firewall (iptables/nftables)

TrueNAS exposes services on `vmbr0`. Access is locked down per service:

| Service | Port | Accessible From | Blocked From |
|---|---|---|---|
| TrueNAS Web UI | 443 | LAN + Tailscale only | Internet |
| SSH | 22 | LAN + Tailscale only | Internet |
| Traefik HTTP | 80 | LAN (redirect to 443) | Internet |
| Traefik HTTPS | 443 | LAN + Cloudflare Tunnel | Direct internet |
| Pi-hole DNS | 53 | LAN only | Internet |
| Samba/SMB | 445 | LAN + Tailscale only | Internet |
| NFS | 2049 | LAN only | Internet, Tailscale |
| Jellyfin | 8096 | Via Traefik only | Direct access |
| Nextcloud | 8080 | Via Traefik only | Direct access |

## DNS Configuration

### Pi-hole as LAN DNS Server

Pi-hole runs as a Docker VM container and serves as the DHCP DNS server for
the LAN (`192.168.1.20`). TrueNAS remains storage only.

#### Local DNS Records

| Domain | IP | Purpose |
|---|---|---|
| `truenas.local` | `192.168.1.10` | TrueNAS management |
| `proxmox.local` | `192.168.1.2` | Proxmox management |
| `cloud.example.com` | `192.168.1.20` | Nextcloud on Docker VM |
| `media.example.com` | `192.168.1.20` | Jellyfin on Docker VM |
| `vault.example.com` | `192.168.1.20` | Vaultwarden on Docker VM |
| `dash.example.com` | `192.168.1.20` | Homepage/Homarr on Docker VM |

Local DNS records for the public domains (pointing to `192.168.1.20`) give
split DNS / split-horizon behavior: LAN traffic goes directly to the Docker
VM instead of routing out to Cloudflare and back, which is faster and keeps
working even if internet access is down.

### Upstream DNS

Pi-hole uses privacy-respecting upstream resolvers:

| Priority | Resolver | IP | Protocol |
|---|---|---|---|
| Primary | Cloudflare | `1.1.1.1` | DNS-over-HTTPS |
| Secondary | Quad9 | `9.9.9.9` | DNS-over-HTTPS |

## Reverse Proxy: Traefik

Traefik runs as a Docker VM container and handles HTTP/HTTPS routing to
internal services.

### Why Traefik

| Feature | Benefit |
|---|---|
| Auto-discovery | Detects new Docker containers and creates routes automatically |
| Let's Encrypt | Auto-provisions and renews SSL certificates |
| Middleware | Rate limiting, IP whitelisting, auth headers, redirects |
| Dashboard | Visual overview of all routes and services |

### Traefik Architecture

```
Cloudflare Tunnel (external)         LAN clients (internal)
        |                                    |
        ▼                                    ▼
+--------------------------------------------------+
|                 Traefik (:443)                    |
|                                                  |
|  Router rules:                                   |
|  +- cloud.example.com  → nextcloud:8080       |
|  +- media.example.com  → jellyfin:8096        |
|  +- vault.example.com  → vaultwarden:80       |
|  +- dash.example.com   → homepage:3000        |
|  +- monitor.example.com → grafana:3000        |
|                                                  |
|  Middleware:                                     |
|  +- HTTPS redirect (80 → 443)                   |
|  +- Security headers (HSTS, XSS, etc.)          |
|  +- Rate limiting (prevent brute force)          |
|  +- IP whitelist for internal-only services      |
+--------------------------------------------------+
```

### Security Headers Middleware

The current Traefik dynamic configuration applies this security headers
middleware to routed services:

```yaml
http:
  middlewares:
    security-headers:
      headers:
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        stsPreload: false
        forceSTSHeader: true
        contentTypeNosniff: true
        browserXssFilter: true
        referrerPolicy: "strict-origin-when-cross-origin"
        frameDeny: true
        customResponseHeaders:
          X-Powered-By: ""
          Server: ""
```

HSTS preload is intentionally left off until the whole domain and every
subdomain are stable on HTTPS, since preload is difficult to undo.

## Access Matrix Summary

| Service | LAN | Tailscale VPN | Cloudflare Tunnel | Direct Internet |
|---|---|---|---|---|
| **Proxmox UI** | ✅ | ✅ | ❌ Never | ❌ Never |
| **TrueNAS UI** | ✅ | ✅ | ❌ Never | ❌ Never |
| **SSH** | ✅ | ✅ | ❌ Never | ❌ Never |
| **Nextcloud** | ✅ | ✅ | ✅ (with Access policy) | ❌ |
| **Jellyfin** | ✅ | ✅ | ✅ (optional) | ❌ |
| **Vaultwarden** | ✅ | ✅ | ✅ (with Access policy) | ❌ |
| **Homepage** | ✅ | ✅ | ✅ (optional) | ❌ |
| **Grafana** | ✅ | ✅ | ❌ | ❌ |
| **Pi-hole** | ✅ DNS | ✅ DNS + UI | ❌ | ❌ |
| **Samba/SMB** | ✅ | ✅ (slow) | ❌ | ❌ |
| **Hermes VM** | ❌ | ❌ | ❌ | Outbound only |
