# Hermes Setup And Testing

Deploys [Hermes Agent](https://github.com/NousResearch/hermes-agent) on an isolated Proxmox VM, then sets up access to its web dashboard. See [docs/services/hermes.md](../../services/hermes.md) for the resulting architecture and current addresses.

Prerequisite: Proxmox with the isolated `vmbr1` bridge already configured (manual Proxmox setup guide).

## Part 1: Deploy Hermes On An Isolated VM

### Step 1: Create the Hermes VM (Proxmox UI)

| Setting | Value |
|---|---|
| Name | `Hermes` |
| ID | `120` |
| OS | Debian 12 netinst ISO |
| CPU | 1-2 cores |
| RAM | 2048-3072 MB |
| Disk | 30 GiB on `ssd-fast` |
| Network | `vmbr1` (never `vmbr0`) |
| Start at boot | Yes, order `3` |

### Step 2: Install Debian 12

1. Install Debian 12 minimal via the Proxmox console (SSH server only, no desktop).
2. Create a sudo-capable admin user for the VM.
3. Set the hostname: `sudo hostnamectl set-hostname hermes`.

### Step 3: Static IP

Example for `/etc/network/interfaces`:

```ini
auto ens18
iface ens18 inet static
    address 10.10.100.2/24
    gateway 10.10.100.1
    dns-nameservers 1.1.1.1 9.9.9.9
```

Verify isolation: `ping 8.8.8.8` succeeds, `ping 192.168.1.10` fails.

### Step 4: Harden the VM

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw enable
```

Use the Proxmox console for ongoing setup — SSH from the LAN is blocked by design.

### Step 5: Install Docker Engine

Needed either way: to run the Hermes container (Docker deployment) or to provide the terminal sandbox backend (native deployment).

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker <hermes-vm-user>
# log out and back in
docker run --rm hello-world
```

### Option A: Hermes IN Docker (recommended production path)

First-time setup wizard (run once per VM):

```bash
mkdir -p ~/.hermes
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent setup
```

Use SSH to the VM console rather than a browser-based VPS console — special characters in `docker run` args can get corrupted in browser terminals.

Quick provider setup:

```bash
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent setup --portal
```

Configure the messaging gateway (Telegram/Discord/Slack), either during `setup` or separately:

```bash
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent gateway setup
```

Deploy with Docker Compose:

```bash
mkdir -p /opt/hermes
# copy configs/hermes/docker-compose.yml and .env.example from this repo
cd /opt/hermes
cp .env.example .env
nano .env    # add TELEGRAM_BOT_TOKEN etc. if not already in ~/.hermes/.env
docker compose up -d
```

Or run directly:

```bash
docker run -d \
  --name hermes \
  --restart unless-stopped \
  --memory=1536m --cpus=1.5 \
  -v ~/.hermes:/opt/data \
  nousresearch/hermes-agent gateway run
```

Do not expose port `8642` to the internet — bind to localhost only; the gateway only needs outbound connections.

Verify:

```bash
docker logs -f hermes
docker exec hermes hermes gateway status
```

Send a test message to the bot from your phone.

Edit `~/.hermes/config.yaml` (persists via the volume mount) for approvals:

```yaml
approvals:
  mode: manual
  timeout: 60
  cron_mode: deny
```

With Hermes in Docker, the container itself is the sandbox boundary — `terminal.backend: docker` is unnecessary unless you want nested sandboxing.

Updates:

```bash
docker pull nousresearch/hermes-agent:latest
docker compose down && docker compose up -d
```

Optional web dashboard (only enable behind auth, keep localhost-only):

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

Never set `HERMES_DASHBOARD_INSECURE=1` on any network-accessible host.

Interactive CLI for debugging:

```bash
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent
# or:
docker exec -it hermes /opt/hermes/.venv/bin/hermes
```

Docker troubleshooting:

| Problem | Fix |
|---|---|
| Container exits immediately | `docker logs hermes` — usually a missing/invalid `.env` |
| Permission denied on volume | `chmod -R 755 ~/.hermes` or set `PUID`/`PGID` |
| Browser tools OOM | Add `shm_size: 1g` to compose, increase VM RAM to 3-4 GB |
| Gateway stuck after a network blip | `docker restart hermes` |
| Two gateways corrupt data | Never mount the same `~/.hermes` into two containers at once |

### Option B: Native install + Docker terminal backend

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
source ~/.bashrc
hermes doctor

hermes setup        # or: hermes setup --portal
hermes gateway setup
```

Enable the Docker-sandboxed terminal backend:

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

With the Docker backend, dangerous-command approval prompts are skipped inside the sandbox — keep `approvals.mode: manual` anyway for anything running outside it.

Install the gateway as a systemd service:

```bash
hermes gateway install
sudo systemctl enable hermes-gateway
sudo systemctl start hermes-gateway
sudo systemctl status hermes-gateway
```

Verify and test:

```bash
hermes
hermes --tui
journalctl -u hermes-gateway -f
```

Updates:

```bash
hermes update
hermes doctor
sudo systemctl restart hermes-gateway
```

Native troubleshooting:

| Problem | Fix |
|---|---|
| `hermes: command not found` | `source ~/.bashrc` |
| Docker backend fails | `sudo systemctl start docker` then `docker ps` |
| Gateway won't start | `hermes doctor`, check `~/.hermes/.env` |
| Approval prompts block cron | Keep `cron_mode: deny` |

### Shared final steps

Verify network isolation from inside the Hermes VM:

```bash
# MUST fail:
ping -c 3 192.168.1.10    # TrueNAS
ping -c 3 192.168.1.20    # Docker VM
ping -c 3 192.168.1.2     # Proxmox

# MUST succeed:
ping -c 3 8.8.8.8
curl -s --connect-timeout 5 https://example.com
```

Boot order:

| VM | Order | Delay |
|---|---|---|
| TrueNAS (110) | 1 | 0s |
| Docker-Host (111) | 2 | 60s |
| Hermes (120) | 3 | 90s |

Backup:

```bash
tar czf /tmp/hermes-backup-$(date +%Y%m%d).tar.gz -C ~ .hermes
```

Or snapshot the whole VM in Proxmox. Do not mount TrueNAS NFS on Hermes.

Migrate from OpenClaw, if applicable:

```bash
# native:
hermes claw migrate --dry-run
hermes claw migrate
# docker:
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent claw migrate --dry-run
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent claw migrate
```

## Part 2: Dashboard Access

The dashboard stays bound to `127.0.0.1:9119` on the Hermes VM. The addresses below reflect the VM's documented current operational configuration — reconcile against your actual live VM/user before running these commands if they differ from Part 1's provisioning values.

| Component | Address |
|---|---|
| Proxmox | `192.168.1.2` |
| Hermes VM | `10.10.100.3` |
| Hermes user | `<hermes-user>` |
| Dashboard port | `9119` |

### Step 1: Start the dashboard

On the Hermes VM:

```bash
set -a
. ~/.config/hermes/dashboard.env
set +a

hermes dashboard --host 127.0.0.1 --port 9119 --no-open
```

Leave this running in the foreground unless `hermes-dashboard.service` (Step 4) already exists. Verify on the Hermes VM:

```bash
ss -ltnp | grep 9119
curl http://127.0.0.1:9119/
```

`curl -I` may return `405 Method Not Allowed` — expected, since the dashboard expects `GET`, not `HEAD`.

### Step 2: Open the SSH tunnel

From a management workstation (PowerShell example):

```powershell
ssh -N -J root@192.168.1.2 -L 9119:127.0.0.1:9119 <hermes-user>@10.10.100.3
```

After entering the passwords, the command appears to hang — that's normal; keep the window open while using the dashboard. Then open `http://127.0.0.1:9119/` in a browser.

### Step 3: Test the tunnel

In a second PowerShell window:

```powershell
Test-NetConnection 127.0.0.1 -Port 9119
curl.exe -v http://127.0.0.1:9119/
```

Expect `TcpTestSucceeded : True`.

### If it does not load

On the Hermes VM:

```bash
ss -ltnp | grep 9119
systemctl --user status hermes-gateway --no-pager
journalctl --user -u hermes-gateway -n 80 --no-pager
```

On Windows, close stale tunnel windows (`Ctrl+C`), check for leftover SSH processes:

```powershell
Get-CimInstance Win32_Process -Filter "name = 'ssh.exe'" | Select-Object ProcessId,CommandLine
Stop-Process -Id <PID>
```

Then reopen the tunnel with the Step 2 command.

### Step 4: Optional persistent dashboard service

Once the foreground dashboard test works, create a systemd user service so it starts automatically:

```bash
mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/hermes-dashboard.service <<'EOF'
[Unit]
Description=Hermes Web Dashboard
After=hermes-gateway.service
Wants=hermes-gateway.service

[Service]
Type=simple
WorkingDirectory=/home/<hermes-user>/.hermes
EnvironmentFile=/home/<hermes-user>/.config/hermes/dashboard.env
ExecStart=/home/<hermes-user>/.local/bin/hermes dashboard --host 127.0.0.1 --port 9119 --no-open
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now hermes-dashboard
systemctl --user status hermes-dashboard --no-pager
ss -ltnp | grep 9119
```

With the service enabled, future access only needs the SSH tunnel command from Step 2.
