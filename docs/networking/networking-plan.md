# 🌐 Networking — Secure Remote Access & Network Topology

> [!IMPORTANT]
> **Current deployment correction (2026-06-09):** For this homelab, TrueNAS is
> storage only. Docker services, Traefik, Pi-hole, Jellyfin, ARR apps, and
> other containers belong on the Ubuntu Docker VM, not on TrueNAS. Tailscale is
> already set up for remote management. Hermes is isolated on `10.10.100.2`.
> Treat any older section in this file that says services run on TrueNAS as
> stale until the file is fully rewritten.

For the canonical IP table, use [network-reference.md](network-reference.md).

> **Philosophy: Zero trust from the outside, defense in depth on the inside.**
> No ports open to the internet except through encrypted tunnels. All management
> access via VPN. Public-facing services behind Cloudflare Tunnel. Internal
> services firewalled per-VLAN.

---

## Network Topology Overview

```
                          ┌──────────────┐
                          │   INTERNET   │
                          └──────┬───────┘
                                 │
                    ┌────────────┴────────────┐
                    │     HOME ROUTER         │
                    │  (ISP-provided or own)  │
                    │                         │
                    │  WAN: Public IP (DHCP)  │
                    │  LAN: 192.168.1.1/24    │
                    │                         │
                    │  Port forwarding:       │
                    │  ❌ NONE (see below)    │
                    └────────────┬────────────┘
                                 │ LAN
                                 │
        ┌────────────────────────┼────────────────────────┐
        │                        │                         │
        │                  ┌─────┴──────┐                  │
        │                  │  PROXMOX   │                  │
        │                  │ 192.168.1.2 │                  │
        │                  └─────┬──────┘                  │
        │                        │                         │
   ┌────┴────────────────────────┼─────────────────────┐   │
   │              vmbr0 (Main Bridge)                  │   │
   │                             │                     │   │
   │  ┌──────────────────┐  ┌──────────────────┐      │   │
   │  │ TrueNAS          │  │ Docker VM        │      │   │
   │  │ 192.168.1.10     │  │ 192.168.1.20     │      │   │
   │  │ Storage only:    │  │ Services:        │      │   │
   │  │ • ZFS datasets   │  │ • Traefik later  │      │   │
   │  │ • NFS/SMB        │  │ • ARR stack      │      │   │
   │  │ • Snapshots      │  │ • Jellyfin       │      │   │
   │  │                  │  │ • Pi-hole later  │      │   │
   │  └──────────────────┘  └──────────────────┘      │   │
   └──────────────────────────────────────────────────┘   │
                                                          │
   ┌──────────────────────────────────────────────────┐   │
   │              vmbr1 (Isolated Bridge)              │   │
   │              10.10.100.0/24                       │   │
   │                                                   │   │
   │  ┌──────────────┐    ┌──────────────┐            │   │
   │  │ Hermes       │                                 │   │
   │  │ .100.2       │                                 │   │
   │  └──────────────┘                                 │   │
   │                                                   │   │
   │  Rules: Internet OUT ✅ | LAN access ❌           │   │
   └──────────────────────────────────────────────────┘   │
                                                          │
   ┌──────────────────────────────────────────────────┐   │
   │         Tailscale Mesh (Overlay Network)          │   │
   │         100.x.x.x/32 (WireGuard tunnel)           │   │
   │                                                   │   │
   │   Your laptop ◄──── encrypted ────► TrueNAS      │   │
   │   Your phone  ◄──── encrypted ────► Proxmox      │   │
   │                                                   │   │
   │   Access: Management UIs, SSH, file shares        │   │
   └──────────────────────────────────────────────────┘   │
        └─────────────────────────────────────────────────┘
```

---

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

> [!IMPORTANT]
> Always use static IPs or DHCP reservations for servers. If TrueNAS gets a new IP
> after a router reboot, every NFS mount and DNS record breaks.

---

## Remote Access Strategy

### The Golden Rule

> **Zero open ports on your router.** No port forwarding. No exposed services.
> Everything goes through encrypted tunnels.

This eliminates entire categories of attacks: port scanning, brute force, DDoS,
exploit attempts against exposed services.

### Layer 1: Tailscale VPN (Management Access)

**Tailscale** is a zero-config mesh VPN built on WireGuard. It creates encrypted
point-to-point tunnels between your devices without any port forwarding.

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

> [!NOTE]
> If you're uncomfortable with Tailscale seeing connection metadata, consider
> **Headscale** — a self-hosted Tailscale control server. You get Tailscale's
> protocol with zero third-party trust. If you deploy it later, run it on the
> Docker VM, not on TrueNAS.

#### Tailscale Setup

**Install on TrueNAS:**

```bash
# TrueNAS SCALE is Debian-based
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --advertise-routes=192.168.1.0/24 --accept-dns=false
```

The `--advertise-routes` flag makes TrueNAS a **subnet router** — your remote
devices can access the entire `192.168.1.0/24` network through TrueNAS, not
just TrueNAS itself.

**Install on Proxmox host:**

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --accept-dns=false
```

**Install on your devices:**
- **Laptop/Desktop:** Download from [tailscale.com](https://tailscale.com/download)
- **Phone:** App Store / Google Play
- **All devices:** Login with the same account (Google, GitHub, etc.)

#### What You Can Access Via Tailscale

| Service | URL/Address | From Where |
|---|---|---|
| Proxmox management | `https://proxmox:8006` or `https://100.x.x.x:8006` | Anywhere |
| TrueNAS management | `https://truenas:443` or `https://100.x.x.x:443` | Anywhere |
| SSH to TrueNAS | `ssh admin@truenas` | Anywhere |
| SSH to Proxmox | `ssh root@proxmox` | Anywhere |
| All web services | Via Traefik on Docker VM | Anywhere |
| SMB file shares | `\\truenas\share` | Anywhere (but slow over WAN) |

#### Tailscale ACLs (Access Control)

Configure in Tailscale admin console → **Access Controls**:

```jsonc
{
  "acls": [
    // You can access everything
    {
      "action": "accept",
      "src": ["autogroup:owner"],
      "dst": ["*:*"]
    }
  ],
  "tagOwners": {
    "tag:server": ["autogroup:owner"]
  },
  // Disable key expiry for servers (so they don't disconnect)
  "nodeAttrs": [
    {
      "target": ["tag:server"],
      "attr": ["funnel", "mullvad"]
    }
  ]
}
```

> [!TIP]
> Run `tailscale up --auth-key=<key>` with a pre-auth key tagged `tag:server`
> to disable key expiry on your servers. Otherwise they disconnect every 180 days
> and you need physical access to re-authenticate.

### Layer 2: Cloudflare Tunnel (Public Web Services)

For services you want accessible **without VPN** (e.g., Nextcloud on your phone,
Jellyfin for streaming), use **Cloudflare Tunnel** instead of port forwarding.

#### How It Works

```
Your phone (anywhere)
       │
       ▼ HTTPS
Cloudflare Edge (DDoS protection, WAF, caching)
       │
       ▼ Encrypted tunnel (outbound from your server)
TrueNAS → cloudflared container → Traefik → Service
```

- **No port forwarding** — `cloudflared` makes an outbound connection to Cloudflare
- **Free DDoS protection** — Cloudflare absorbs attacks before they reach you
- **Free SSL certificates** — Cloudflare handles cert issuance and renewal
- **WAF rules** — Block by country, rate limit, challenge suspicious IPs

#### Requirements

- A domain name (e.g., `example.com` — ~€10/year)
- Cloudflare account (free tier is enough)
- Domain's DNS managed by Cloudflare (free)

#### Setup

**1. Install `cloudflared` as a Docker VM container:**

```yaml
# docker-compose.yml
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: tunnel run
    environment:
      - TUNNEL_TOKEN=<your-tunnel-token>
```

**2. Create tunnel in Cloudflare Zero Trust dashboard:**

Cloudflare Zero Trust → Networks → Tunnels → Create a tunnel

**3. Map public hostnames to internal services:**

| Public Hostname | Internal Service | Protocol |
|---|---|---|
| `cloud.example.com` | `http://traefik:80` or `http://localhost:8080` | HTTPS → HTTP |
| `media.example.com` | `http://traefik:80` | HTTPS → HTTP |
| `vault.example.com` | `http://traefik:80` | HTTPS → HTTP |

**4. Add Cloudflare Access policies (optional but recommended):**

Restrict who can access each service. Example:
- `cloud.example.com` → Allow: your email only (OTP challenge)
- `media.example.com` → Allow: your email + friend's email
- `vault.example.com` → Allow: your email only

> [!CAUTION]
> **Never expose management interfaces through Cloudflare Tunnel:**
> - ❌ Proxmox UI (`https://proxmox:8006`)
> - ❌ TrueNAS UI (`https://truenas:443`)
> - ❌ SSH
> - ❌ Portainer
>
> These should ONLY be accessible via **Tailscale VPN**. If someone compromises
> your Cloudflare account, they still can't reach your management plane.

### Layer 3: SSH Hardening

SSH is your last-resort management tool. Lock it down.

#### On Proxmox Host

```bash
# /etc/ssh/sshd_config

# Disable password authentication — keys only
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes

# Disable root login via password (key-only)
PermitRootLogin prohibit-password

# Only allow specific users
AllowUsers root

# Use strong key exchange and ciphers
KexAlgorithms sshd_default
Ciphers sshd_default
MACs sshd_default

# Limit auth attempts
MaxAuthTries 3
MaxSessions 3

# Disable X11 and agent forwarding unless needed
X11Forwarding no
AllowAgentForwarding no

# Idle timeout (disconnect after 10 min of inactivity)
ClientAliveInterval 300
ClientAliveCountMax 2
```

```bash
systemctl restart sshd
```

#### SSH Key Setup

```bash
# On YOUR laptop — generate a key pair (if you don't have one)
ssh-keygen -t ed25519 -C "your-email@example.com"

# Copy public key to Proxmox
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.1.2

# Copy public key to TrueNAS
ssh-copy-id -i ~/.ssh/id_ed25519.pub admin@192.168.1.10

# Test login (should NOT ask for password)
ssh root@192.168.1.2
ssh admin@192.168.1.10
```

> [!WARNING]
> **Back up your SSH private key!** If you lose it and password auth is disabled,
> you'll need physical console access to recover. Store a copy in Vaultwarden
> or on an encrypted USB drive.

---

## Firewall Rules

### Proxmox Host Firewall

Enable in Proxmox: **Datacenter → Firewall → Options → Firewall: Yes**

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

### TrueNAS Firewall (via iptables/nftables)

TrueNAS exposes services on `vmbr0`. Lock down what's accessible from where:

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

---

## DNS Configuration

### Pi-hole as LAN DNS Server

Pi-hole should run as a Docker VM container if you deploy it. TrueNAS remains storage only.

**Router configuration:** Set DHCP DNS server to the Docker VM IP (`192.168.1.20`) if Pi-hole is deployed there.

#### Local DNS Records

Configure in Pi-hole: **Local DNS → DNS Records**

| Domain | IP | Purpose |
|---|---|---|
| `truenas.local` | `192.168.1.10` | TrueNAS management |
| `proxmox.local` | `192.168.1.2` | Proxmox management |
| `cloud.example.com` | `192.168.1.20` | Nextcloud on Docker VM |
| `media.example.com` | `192.168.1.20` | Jellyfin on Docker VM |
| `vault.example.com` | `192.168.1.20` | Vaultwarden on Docker VM |
| `dash.example.com` | `192.168.1.20` | Homepage/Homarr on Docker VM |

> [!TIP]
> **Split DNS / DNS rebinding:** By adding local DNS records for your public domains
> (pointing to `192.168.1.20`), LAN traffic goes directly to the Docker VM instead of
> routing out to Cloudflare and back. Faster and works even if your internet is down.

### Upstream DNS

Configure Pi-hole to use privacy-respecting upstream resolvers:

| Priority | Resolver | IP | Protocol |
|---|---|---|---|
| Primary | Cloudflare | `1.1.1.1` | DNS-over-HTTPS |
| Secondary | Quad9 | `9.9.9.9` | DNS-over-HTTPS |

---

## Reverse Proxy: Traefik

Traefik should run as a Docker VM container and handle HTTP/HTTPS routing to internal services when you reach the internet-exposure phase.

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
        │                                    │
        ▼                                    ▼
┌──────────────────────────────────────────────────┐
│                 Traefik (:443)                    │
│                                                  │
│  Router rules:                                   │
│  ├─ cloud.example.com  → nextcloud:8080       │
│  ├─ media.example.com  → jellyfin:8096        │
│  ├─ vault.example.com  → vaultwarden:80       │
│  ├─ dash.example.com   → homepage:3000        │
│  └─ monitor.example.com → grafana:3000        │
│                                                  │
│  Middleware:                                     │
│  ├─ HTTPS redirect (80 → 443)                   │
│  ├─ Security headers (HSTS, XSS, etc.)          │
│  ├─ Rate limiting (prevent brute force)          │
│  └─ IP whitelist for internal-only services      │
└──────────────────────────────────────────────────┘
```

### Security Headers Middleware

```yaml
# traefik dynamic config
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

---

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

---

## Implementation Checklist

| # | Task | Status |
|---|---|---|
| 1 | Assign static IPs / DHCP reservations for Proxmox + TrueNAS | ⬜ TODO |
| 2 | Create isolated bridge `vmbr1` on Proxmox | ⬜ TODO |
| 3 | Configure `vmbr1` iptables (NAT + LAN block) | ⬜ TODO |
| 4 | Enable Proxmox firewall + add host rules | ⬜ TODO |
| 5 | Add VM-level firewall rules for Hermes VM | ⬜ TODO |
| 6 | Install Tailscale on TrueNAS + Proxmox + your devices | ⬜ TODO |
| 7 | Configure Tailscale subnet router on TrueNAS | ⬜ TODO |
| 8 | Set up Tailscale ACLs in admin console | ⬜ TODO |
| 9 | Register a domain name | ⬜ TODO |
| 10 | Move domain DNS to Cloudflare | ⬜ TODO |
| 11 | Install `cloudflared` on Docker VM | ⬜ TODO |
| 12 | Create Cloudflare Tunnel + map hostnames | ⬜ TODO |
| 13 | Add Cloudflare Access policies for sensitive services | ⬜ TODO |
| 14 | Install + configure Pi-hole on Docker VM | ⬜ TODO |
| 15 | Set router DHCP DNS to Pi-hole IP | ⬜ TODO |
| 16 | Add local DNS records in Pi-hole (split DNS) | ⬜ TODO |
| 17 | Install + configure Traefik on Docker VM | ⬜ TODO |
| 18 | Configure security headers middleware | ⬜ TODO |
| 19 | Harden SSH on Proxmox + TrueNAS (key-only, disable password) | ⬜ TODO |
| 20 | Generate + deploy SSH keys to all servers | ⬜ TODO |
| 21 | Back up SSH private key to Vaultwarden | ⬜ TODO |
| 22 | Test: access Proxmox/TrueNAS via Tailscale from phone | ⬜ TODO |
| 23 | Test: access Nextcloud via Cloudflare Tunnel from phone | ⬜ TODO |
| 24 | Test: verify Hermes VM cannot reach LAN | ⬜ TODO |
