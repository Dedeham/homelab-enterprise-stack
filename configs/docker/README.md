# Docker Configs

> **What is this folder?**
> These are the actual deployment files for every service running on your Docker VM.
> Each subfolder contains a `docker-compose.yml` that you copy to the Docker VM and run.
> They use plain Docker Compose — no TrueNAS app system, no Kubernetes, no wrappers.
> All persistent data lives on TrueNAS, accessed via NFS mounts.

---

## Services

| Folder | Service | What It Does | Exposes |
|---|---|---|---|
| `traefik/` | **Traefik** | Reverse proxy — routes all traffic, handles SSL certs automatically | 80, 443 |
| `authelia/` | **Authelia** | 2FA gateway — protects services that don't have their own login | `auth.example.com` |
| `crowdsec/` | **CrowdSec** | Intrusion detection — watches logs and blocks malicious IPs | Internal only |
| `pihole/` | **Pi-hole** | Network-wide ad blocker + local DNS server | `dns.example.com`, port 53 |
| `vaultwarden/` | **Vaultwarden** | Self-hosted Bitwarden password manager | `vault.example.com` |
| `nextcloud/` | **Nextcloud** | Simpler Docker-VM deployment | `cloud.example.com` |
| `nextcloud-dedicated-vm/` | **Nextcloud dedicated VM** | Isolated Nextcloud compose and Traefik file-provider template | `cloud.example.com` |
| `jellyfin/` | **Jellyfin** | Self-hosted Netflix (media streaming) | `media.example.com` |
| `debrid-stack/` | **Independent debrid stack** | RDTClient behind its own Gluetun VPN gateway | `192.168.1.20:6500` |
| `homepage/` | **Homepage** | Server dashboard — links to all services at a glance | `dash.example.com` |
| `monitoring/` | **Full monitoring stack** | Prometheus + Grafana + Node Exporter + cAdvisor + Alertmanager + Scrutiny + Uptime Kuma | `monitor.example.com`, `status.example.com` |
| `ai-stack/` | **AI stack** | Whisper speech-to-text + llama.cpp vision model + n8n workflow automation | `n8n.example.com` (LAN only) |
| `watchtower/` | **Watchtower** | Monitors containers for image updates (notifications only — does NOT auto-update) | Internal only |

> **About Watchtower:** Watchtower runs in **monitor-only mode**. It checks if newer versions
> of your images exist and sends you a notification, but it does NOT auto-update containers.
> This is intentional — we pin images to specific versions for stability, and you should update
> deliberately after reading the changelogs. See the image pinning rules below.

---

## Deployment Order

Deploy in this order — later services depend on earlier ones:

| Step | Service | Why This Order |
|------|---------|----------------|
| 1 | `traefik/` | Must be up first — everything else needs the `proxy` network and reverse proxy |
| 2 | `authelia/` | Must be up before any service that uses `authelia@docker` middleware |
| 3 | `crowdsec/` | Start before public-facing services so it can protect them from the start |
| 4 | `pihole/` | Set your router's DNS to Docker VM IP (192.168.1.20) after this starts |
| 5 | `vaultwarden/` | Set up your admin account before disabling signups in the `.env` |
| 6 | `nextcloud/` or `nextcloud-dedicated-vm/` | Database initialisation takes a minute on first run — watch the logs |
| 7 | `jellyfin/` | Point at your media library paths after starting |
| 8 | `homepage/` | Configure after all services are running (so it can detect them) |
| 9 | `monitoring/` | Last — needs all services running to monitor them |
| 10 | `ai-stack/` | Optional — needs Traefik; uses 6–10 GB RAM with default models |
| 11 | `watchtower/` | Very last — monitors all other containers for updates |

---

## How to Deploy on the Docker VM

> **Prerequisites:**
> 1. An Ubuntu Docker VM running on Proxmox (see `docs/os-and-virtualization/ubuntu-docker-security-setup.md`)
> 2. NFS mounts configured (TrueNAS exports `/mnt/main` and `/mnt/media` to the Docker VM)
> 3. The setup script has already run (creates directories, Docker networks, etc.)
>
> If you haven't set up the Docker VM yet, start with the setup script first.

### Step 1: SSH into the Docker VM

```bash
ssh dockeradmin@192.168.1.20
```

### Step 2: Copy service folders from this repo

From your workstation, copy all service configs to the Docker VM:

```bash
# From your workstation (not the Docker VM)
scp -r configs/docker/traefik   dockeradmin@192.168.1.20:/opt/docker/
scp -r configs/docker/authelia  dockeradmin@192.168.1.20:/opt/docker/
scp -r configs/docker/crowdsec  dockeradmin@192.168.1.20:/opt/docker/
scp -r configs/docker/pihole    dockeradmin@192.168.1.20:/opt/docker/
scp -r configs/docker/vaultwarden dockeradmin@192.168.1.20:/opt/docker/
scp -r configs/docker/nextcloud dockeradmin@192.168.1.20:/opt/docker/
scp -r configs/docker/jellyfin  dockeradmin@192.168.1.20:/opt/docker/
# Debrid stack is managed with the ARR/media stacks under /opt/stacks
scp -r configs/docker/debrid-stack dockeradmin@192.168.1.20:/opt/stacks/
scp -r configs/docker/homepage  dockeradmin@192.168.1.20:/opt/docker/
scp -r configs/docker/monitoring dockeradmin@192.168.1.20:/opt/docker/
scp -r configs/docker/watchtower dockeradmin@192.168.1.20:/opt/docker/
scp -r configs/docker/ai-stack   dockeradmin@192.168.1.20:/opt/docker/   # optional
```

### Step 3: Create `.env` files from examples

For each service, create a `.env` file from the example and fill in your actual values.
**Never skip this step** — services will fail or be insecure with placeholder values.

```bash
# Example for Traefik (repeat for each service)
cd /opt/docker/traefik
cp .env.example .env
nano .env   # Fill in your actual domain, email, API keys, etc.
```

> **Important:** Read every line in the `.env` file. Lines marked `# ← CHANGE THIS` must
> be updated with your actual values. Lines with sensible defaults can be left as-is.

### Step 4: Edit traefik.yml

Traefik's static config doesn't support `${DOMAIN}` variables — you must hardcode your
actual domain and email. Open it and search for `← CHANGE THIS`:

```bash
nano /opt/docker/traefik/traefik.yml
# Replace: example.com → your actual domain
# Replace: your@email.com → your actual email
```

### Step 5: Start services in deployment order

```bash
cd /opt/docker/traefik    && docker compose up -d
cd /opt/docker/authelia   && docker compose up -d
cd /opt/docker/crowdsec   && docker compose up -d
cd /opt/docker/pihole     && docker compose up -d
cd /opt/docker/vaultwarden && docker compose up -d
cd /opt/docker/nextcloud  && docker compose up -d
cd /opt/docker/jellyfin   && docker compose up -d
cd /opt/docker/homepage   && docker compose up -d
cd /opt/docker/monitoring && docker compose up -d
cd /opt/docker/watchtower && docker compose up -d
```

### Step 6: Verify each service is running

```bash
# Check all containers at once
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Watch logs for a specific service
cd /opt/docker/traefik && docker compose logs -f

# Check a specific service
cd /opt/docker/nextcloud && docker compose ps
```

> **Common problems:**
> - `Exited (1)` → Check logs with `docker compose logs`. Usually a typo in `.env`.
> - `Restarting` → The service crashes on startup. Check if required directories exist.
> - `unhealthy` → The container is running but the service inside isn't responding.
>   Check if a dependency (database, Redis) is up.
> - `NFS mount not available` → Check that TrueNAS is running and NFS exports are configured.
>   Verify with: `df -h | grep nfs`

---

## Important Rules

### 🔑 Never commit `.env` files to git

`.env` files contain passwords and API keys. They are in `.gitignore`.
Only `.env.example` files (with placeholder values) are committed.

```bash
# If you accidentally committed a .env file:
git rm --cached configs/docker/*/.env
# Then rotate ALL passwords in that file — they're now in git history forever
```

### 📌 Always pin image versions

Images should be pinned to specific supported versions, not `latest`. This prevents surprise breaking changes during updates, but pinned versions still need maintenance. Review support status before internet exposure.

```yaml
# Good — pinned to an explicit supported version
image: nextcloud:<supported-version>-apache

# Acceptable for some services — pinned to a major/minor line
image: traefik:3.1

# Bad — could change at any time
image: nextcloud:latest
```

Watchtower runs in **monitor-only mode** and will notify you when new versions are
available. You then decide when to update by changing the image tag in the compose file
and running `docker compose up -d`.

Use the complete backup, validation, update, verification, and rollback procedure in
[`docs/monitoring/monitoring-and-updates-start-here.md`](../../docs/monitoring/monitoring-and-updates-start-here.md).

### 🔒 Secrets Management

All secrets (passwords, API keys, tokens) are stored in `.env` files with `chmod 600`
permissions. This is the pragmatic approach for a home server:

- ✅ `.env` files are gitignored — never committed to version control
- ✅ Each service has its own `.env` (no single point of failure)
- ✅ Backed up via your password manager (store all `.env` contents as a secure note)
- ✅ `chmod 600` means only root/owner can read them

**Password rotation schedule** (set a calendar reminder):
- Every 6 months: Rotate database passwords, Redis password, Grafana admin password
- Immediately: After any suspected breach or if a `.env` file was accidentally exposed
- Generate strong passwords: `openssl rand -base64 32`

### 🔍 Image Vulnerability Scanning

Periodically scan your Docker images for known vulnerabilities:

```bash
# Option 1: Docker Scout (built into Docker Desktop, also works on CLI)
docker scout cves nextcloud:<supported-version>-apache

# Option 2: Trivy (install: apt install trivy)
trivy image nextcloud:<supported-version>-apache

# Scan all running images at once:
docker images --format '{{.Repository}}:{{.Tag}}' | xargs -I {} trivy image {}
```

Run this monthly or after any major update. Focus on CRITICAL and HIGH severity CVEs.

### 🔄 The Escape Hatch

These compose files aren't tied to any specific platform. If you want to move:

1. Copy the service folders to the new host
2. Install Docker + Docker Compose
3. Mount or copy your data (adjust volume paths if needed)
4. Create the `proxy` network
5. Start services with `docker compose up -d`

---

## Where Data Lives

```
Docker VM (192.168.1.20):
├── /opt/docker/           ← Compose files, .env files (local SSD — fast)
│   ├── traefik/
│   ├── authelia/
│   ├── nextcloud/
│   └── ...
└── /mnt/                  ← NFS mounts from TrueNAS (ZFS protected)
    ├── main/              ← ZFS mirror pool (redundant, snapshotted)
    │   ├── appdata/       ← Service persistent data
    │   │   ├── authelia/
    │   │   ├── vaultwarden/
    │   │   ├── jellyfin/
    │   │   ├── pihole/
    │   │   ├── homepage/
    │   │   ├── nextcloud-db/
    │   │   └── crowdsec/
    │   ├── nextcloud/     ← Nextcloud user files (photos, docs)
    │   └── backups/db/    ← Database dumps (MariaDB + Vaultwarden)
    └── media/             ← Jellyfin media library (expendable)
        ├── movies/
        ├── tv-shows/
        └── music/

TrueNAS (192.168.1.10):
├── /mnt/main/     ← ZFS mirror pool — exports via NFS to Docker VM
├── /mnt/media/    ← ZFS single pool — exports via NFS to Docker VM
└── /mnt/scratch/  ← ZFS single pool (optional)
```

> **Key insight:** Compose files are on the Docker VM's local SSD (fast access, easily
> replaceable). All *data* is on TrueNAS via NFS (ZFS protected, mirrored, snapshotted).
> If the Docker VM dies, you lose nothing — recreate it and start services again.

---

## Network Architecture

```
proxy network (Traefik can route to these):
  traefik, nextcloud, vaultwarden, jellyfin, pihole,
  homepage, authelia, grafana, uptime-kuma, crowdsec-bouncer

nextcloud_internal (isolated — DB and cache only):
  nextcloud ↔ nextcloud-db (MariaDB)
  nextcloud ↔ nextcloud-redis (Redis cache)
  nextcloud ↔ nextcloud-cron (background jobs)

monitoring (isolated — metrics collection only):
  prometheus ↔ cadvisor, node-exporter, alertmanager, scrutiny

crowdsec (isolated — log analysis):
  crowdsec ↔ bouncer-traefik

socket_proxy (isolated — Docker API access):
  traefik ↔ socket-proxy → Docker socket (filtered, read-only)
  homepage ↔ socket-proxy → Docker socket (filtered, read-only)
```

> **Why so many networks?** Each internal network is a security boundary. If an attacker
> compromises Jellyfin, they can't reach the Nextcloud database because Jellyfin isn't on
> the `nextcloud_internal` network. Network isolation is one of Docker's best security features.
