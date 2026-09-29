# 🤖 Hermes Agents — Deployment Guide (VM + Docker)

> **Prerequisite:** Proxmox with the isolated `vmbr1` bridge configured by the [manual Proxmox guide](../os-and-virtualization/proxmox-manual-initial-setup.md), and Hermes VM 120 created in the Proxmox web UI.
>
> **Architecture:** One isolated Debian VM on `vmbr1` runs [Hermes Agent](https://github.com/NousResearch/hermes-agent). Hermes never runs on the Docker VM (Nextcloud/Jellyfin/ARR) or TrueNAS.
>
> **Last updated:** June 2026

---

## Should You Run Hermes in Docker?

Hermes has **two completely different Docker modes**. Most guides mix them up. This matters for your setup.

| Mode | What it means | Best for |
|---|---|---|
| **Mode 1: Hermes IN Docker** | The entire agent (gateway, CLI, memory, skills) runs inside the official `nousresearch/hermes-agent` container | Always-on gateway on a VPS/VM — **recommended for your homelab** |
| **Mode 2: Docker terminal backend** | Hermes runs natively on the host; only shell commands execute inside a separate sandbox container | Local dev on your laptop where you want command isolation but easy CLI access |

These are **not** either/or at the infrastructure level. Your homelab uses:

```
Layer 1: Proxmox VM on vmbr1     → isolates Hermes from TrueNAS, Docker VM, LAN
Layer 2: Hermes IN Docker       → isolates agent from VM host (Mode 1)
Layer 3: (optional) terminal.backend: docker → extra command sandbox inside container
```

### What Nous Research recommends

Per the [official Docker docs](https://hermes-agent.nousresearch.com/docs/user-guide/docker):

- **Production / always-on gateway:** Run Hermes **in** the official Docker image with `~/.hermes` mounted to `/opt/data`. Updates are `docker pull` + recreate. The image includes s6 supervision (auto-restart on crash).
- **First-time setup / debugging:** Native install via `curl | bash`, then containerize once chat works.
- **Docker terminal backend:** For when Hermes runs on a trusted host (your laptop) but you want commands sandboxed. Less critical when Hermes already runs inside a container — commands already execute inside the container filesystem.

### Optimal choice for this homelab

| Approach | Verdict | Why |
|---|---|---|
| **Hermes IN Docker on isolated VM** | ✅ **Recommended** | Official production path, supervised gateway, clean upgrades, container is already sandboxed from VM host |
| **Native install + Docker terminal backend** | ✅ Good alternative | Simpler debugging (`hermes` CLI directly), systemd gateway, still uses Docker for command sandboxing |
| **Hermes on Docker VM (vmbr0)** | ❌ **Do not** | Breaks isolation — agent would have LAN access to TrueNAS, Nextcloud, Vaultwarden |
| **Multiple Hermes profiles in one container** | ⚠️ Avoid for now | Profiles share one OS process tree. Keep this homelab simple with one isolated Hermes VM. |
| **Native install, no Docker at all** | ⚠️ Avoid | Commands run directly on VM host. Acceptable only for testing |

### Resource requirements (from official docs)

| Resource | Minimum | Recommended | Your VM |
|---|---|---|---|
| Memory | 1 GB | 2–4 GB | 2–3 GB (API-only, no browser tools) |
| CPU | 1 core | 2 cores | 1–2 cores |
| Disk (data) | 500 MB | 2+ GB | 30 GB VM disk (plenty) |

Browser automation (Playwright) is the most RAM-hungry feature. With API-based providers only, 1.5 GB container limit on a 2 GB VM works fine.

---

## Shared Infrastructure (Both Approaches)

These steps are identical whether you deploy natively or via Docker.

### Step 1: Create the Hermes VM (Proxmox UI)

| Setting | Hermes (ID 120) |
|---|---|
| Name | `Hermes` |
| OS | Debian 12 netinst ISO |
| CPU | 1–2 cores |
| RAM | 2048–3072 MB |
| Disk | 30 GiB on `ssd-fast` |
| Network | **`vmbr1`** |
| Start at boot | Yes (order 3) |

> [!WARNING]
> `vmbr0` puts the VM on your LAN with access to all homelab services. Always use `vmbr1`.

### Step 2: Install Debian 12

1. Install Debian 12 minimal via Proxmox console (SSH server only, no desktop).
2. Create user `hermesadmin` with sudo.
3. Set hostname: `sudo hostnamectl set-hostname hermes`.

### Step 3: Static IPs

**Hermes (`10.10.100.2`):**

```ini
auto ens18
iface ens18 inet static
    address 10.10.100.2/24
    gateway 10.10.100.1
    dns-nameservers 1.1.1.1 9.9.9.9
```

Verify: `ping 8.8.8.8` works, `ping 192.168.1.10` fails.

### Step 4: Harden the VM

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw enable
```

Use the **Proxmox console** for setup — SSH from LAN is blocked by design.

### Step 5: Install Docker Engine

Both deployment paths need Docker installed on the VM:

- **Docker deployment:** runs the Hermes container
- **Native deployment:** provides the terminal sandbox backend

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker hermesadmin
# Log out and back in
docker run --rm hello-world
```

---

## Option A: Hermes IN Docker (Recommended)

Run the official `nousresearch/hermes-agent` image on the isolated VM. This is Nous Research's first-class deployment for always-on gateways.

### Architecture

```
Hermes VM (vmbr1)
├── Docker Engine
└── Container: nousresearch/hermes-agent
    ├── gateway (Telegram, Discord, etc.)
    ├── /opt/data ← bind mount ~/.hermes (persistent)
    └── s6 supervision (auto-restart)
```

### Step A1: First-time setup (interactive wizard)

Run once per VM to create config and API keys:

```bash
mkdir -p ~/.hermes
docker run -it --rm \
  -v ~/.hermes:/opt/data \
  nousresearch/hermes-agent setup
```

The wizard writes secrets to `~/.hermes/.env` and config to `~/.hermes/config.yaml`. You only do this once.

> Use SSH to the VM console, not a browser-based VPS console — special characters in `docker run` args can get corrupted in browser terminals ([official warning](https://hermes-agent.nousresearch.com/docs/user-guide/docker)).

**Quick provider setup:**

```bash
# Nous Portal — one subscription for models + tools
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent setup --portal

# Or OpenRouter — pay-per-use
# Enter API key when the wizard prompts
```

### Step A2: Configure messaging gateway

During `setup`, configure Telegram/Discord/Slack. Or run separately:

```bash
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent gateway setup
```

### Step A3: Deploy with Docker Compose

Copy the config from this repo:

```bash
mkdir -p /opt/hermes
# Copy configs/hermes/docker-compose.yml and .env.example from this repo
cd /opt/hermes
cp .env.example .env
nano .env    # Add TELEGRAM_BOT_TOKEN etc. if not already in ~/.hermes/.env
docker compose up -d
```

Or use `docker run` directly:

```bash
docker run -d \
  --name hermes \
  --restart unless-stopped \
  --memory=1536m --cpus=1.5 \
  -v ~/.hermes:/opt/data \
  nousresearch/hermes-agent gateway run
```

> [!IMPORTANT]
> Do **not** expose port 8642 to the internet. On isolated VMs, bind to localhost only (as in the compose file). The gateway reaches Telegram/Discord via outbound connections — no inbound ports needed.

### Step A4: Verify the gateway

```bash
docker logs -f hermes
docker exec hermes hermes gateway status
```

Send a test message to your Telegram bot from your phone.

### Step A5: Approvals and security config

Edit `~/.hermes/config.yaml` on the host (persists via volume mount):

```yaml
approvals:
  mode: manual
  timeout: 60
  cron_mode: deny
```

When Hermes runs inside Docker, terminal commands execute inside the container — the container is the security boundary. You do **not** need `terminal.backend: docker` unless you want nested sandboxing (usually unnecessary).

### Step A6: Updates

```bash
docker pull nousresearch/hermes-agent:latest
docker compose down && docker compose up -d
# Or: docker rm -f hermes && docker run -d ... (same flags as Step A3)
```

Your `~/.hermes` data survives — config migrations run automatically on container start.

### Step A7: Optional dashboard

Only enable behind auth, and only if you need a web UI. On isolated VMs, keep it localhost-only:

```yaml
# docker-compose.yml additions:
ports:
  - "127.0.0.1:9119:9119"
environment:
  - HERMES_DASHBOARD=1
  - HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin
  - HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=your-strong-password
  - HERMES_DASHBOARD_BASIC_AUTH_SECRET=another-random-string
```

> [!WARNING]
> Never set `HERMES_DASHBOARD_INSECURE=1` on any network-accessible host. It exposes API keys and session data without authentication.

### Step A8: Interactive CLI (debugging)

```bash
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent
# Or attach to running container:
docker exec -it hermes /opt/hermes/.venv/bin/hermes
```

### Docker troubleshooting

| Problem | Fix |
|---|---|
| Container exits immediately | `docker logs hermes` — usually missing/invalid `.env` |
| Permission denied on volume | `chmod -R 755 ~/.hermes` or set `PUID`/`PGID` env vars |
| Browser tools OOM | Add `shm_size: 1g` to compose, increase VM RAM to 3–4 GB |
| Gateway stuck after network blip | `docker restart hermes` |
| Two gateways corrupt data | Never mount the same `~/.hermes` in two containers simultaneously |

---

## Option B: Native Install on VM

Install Hermes directly on the Debian VM with the curl installer. Use Docker only as the **terminal backend** (Mode 2) for command sandboxing.

### Architecture

```
Hermes VM (vmbr1)
├── Hermes Agent (native, ~/.hermes/)
├── systemd hermes-gateway service
└── Docker Engine
    └── Persistent sandbox container (terminal.backend: docker)
        └── Shell commands execute here, not on VM host
```

### Step B1: Install Hermes

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
source ~/.bashrc
hermes doctor
```

### Step B2: Configure provider and gateway

```bash
hermes setup
# Or: hermes setup --portal

hermes gateway setup
```

### Step B3: Enable Docker terminal backend

This sandboxes every shell command in a persistent Docker container:

```bash
hermes config set terminal.backend docker
```

Recommended `~/.hermes/config.yaml`:

```yaml
terminal:
  backend: docker
  docker_image: "nikolaik/python-nodejs:python3.11-nodejs20"
  container_memory: 5120
  container_cpu: 1

approvals:
  mode: manual
  timeout: 60
  cron_mode: deny
```

With the Docker backend, dangerous-command approval prompts are skipped inside the sandbox ([security docs](https://hermes-agent.nousresearch.com/docs/user-guide/security)) — the container is the boundary. Keep `approvals.mode: manual` anyway for commands that run outside the sandbox.

### Step B4: Install gateway as systemd service

```bash
hermes gateway install
sudo systemctl enable hermes-gateway
sudo systemctl start hermes-gateway
sudo systemctl status hermes-gateway
```

### Step B5: Verify and test CLI

```bash
hermes                    # Interactive chat
hermes --tui              # Modern TUI
journalctl -u hermes-gateway -f
```

### Step B6: Updates

```bash
hermes update
hermes doctor
sudo systemctl restart hermes-gateway
```

### Native troubleshooting

| Problem | Fix |
|---|---|
| `hermes: command not found` | `source ~/.bashrc` |
| Docker backend fails | `sudo systemctl start docker` → `docker ps` |
| Gateway won't start | `hermes doctor` → check `~/.hermes/.env` |
| Approval prompts block cron | Keep `cron_mode: deny` (cron must find safe paths) |

---

## Shared Final Steps (Both Options)

### Verify network isolation

Run from inside the Hermes VM:

```bash
# MUST fail:
ping -c 3 192.168.1.10    # TrueNAS
ping -c 3 192.168.1.20    # Docker VM
ping -c 3 192.168.1.2      # Proxmox

# MUST succeed:
ping -c 3 8.8.8.8
curl -s --connect-timeout 5 https://example.com
```

### Boot order (Proxmox)

| VM | Order | Delay |
|---|---|---|
| TrueNAS (110) | 1 | 0s |
| Docker-Host (111) | 2 | 60s |
| Hermes (120) | 3 | 90s |

### Backup

All state lives in `~/.hermes/`:

```
~/.hermes/
├── .env              # API keys
├── config.yaml       # Provider, tools, approvals
├── sessions/         # Conversation history
├── memories/         # Persistent memory
├── skills/           # Installed skills
└── logs/             # Gateway logs (Docker path)
```

```bash
# Weekly backup inside the VM
tar czf /tmp/hermes-backup-$(date +%Y%m%d).tar.gz -C ~ .hermes
```

Or snapshot the entire VM in Proxmox. Do **not** mount TrueNAS NFS on Hermes.

### Migrate from OpenClaw

```bash
# Native install:
hermes claw migrate --dry-run
hermes claw migrate

# Docker install:
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent claw migrate --dry-run
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent claw migrate
```

---

## Side-by-Side Comparison

| | Docker (Option A) | Native (Option B) |
|---|---|---|
| **Setup complexity** | Medium (compose + volume) | Low (`curl \| bash`) |
| **Always-on gateway** | s6-supervised, auto-restart | systemd service |
| **Updates** | `docker pull` + recreate | `hermes update` |
| **CLI access** | `docker exec` | Direct `hermes` |
| **Command sandbox** | Container filesystem (built-in) | Docker terminal backend |
| **RAM overhead** | ~200 MB for container runtime | Lower (no container overhead) |
| **Debugging** | `docker logs` | `journalctl`, direct CLI |
| **Official recommendation** | ✅ Production / VPS | ✅ First-time setup, then containerize |

---

## Quick Reference

| Task | Docker (Option A) | Native (Option B) |
|---|---|---|
| Start gateway | `docker compose up -d` | `sudo systemctl start hermes-gateway` |
| Chat | `docker exec -it hermes /opt/hermes/.venv/bin/hermes` | `hermes` |
| Logs | `docker logs -f hermes` | `journalctl -u hermes-gateway -f` |
| Status | `docker exec hermes hermes gateway status` | `hermes gateway status` |
| Update | `docker pull` + recreate | `hermes update` |
| Diagnose | `docker exec hermes hermes doctor` | `hermes doctor` |

---

## What's Next?

- [System architecture](../architecture/system-architecture.md) — full stack overview
- [Security hardening](../security/security-hardening.md) — isolation verification
- [Networking plan](../networking/networking-plan.md) — vmbr1 firewall rules
- [Hermes official Docker docs](https://hermes-agent.nousresearch.com/docs/user-guide/docker)
- [Hermes security docs](https://hermes-agent.nousresearch.com/docs/user-guide/security)
