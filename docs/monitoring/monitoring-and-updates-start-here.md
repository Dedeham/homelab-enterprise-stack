# Monitoring And Updates Start Here

Last updated: 2026-06-20

This guide does not require syncing this repo to the server.

You will SSH into the Ubuntu Docker VM and create the monitoring files directly
under `/opt/stacks`.

If you already completed this deployment, continue with
[Monitoring And Updates Follow-Up](monitoring-and-updates-follow-up.md). Do not
repeat the installation phases on an existing healthy stack.

## Short Answer

Yes, monitoring and update notifications are a good next step now.

Do this now:

```text
1. Deploy Prometheus, Grafana, Alertmanager, node-exporter, cAdvisor, and Uptime Kuma.
2. Deploy Watchtower in monitor-only mode.
3. Keep monitoring LAN-only or Tailscale-only.
4. Use TrueNAS built-in SMART tests and alerts first.
5. Add CrowdSec and Authelia after monitoring works.
```

Do not do this yet:

```text
1. Do not expose Grafana, Prometheus, Alertmanager, or Uptime Kuma publicly.
2. Do not use Watchtower auto-update mode.
3. Do not deploy Nextcloud before backups, alerts, auth, and storage permissions are ready.
4. Do not depend on Authelia middleware until Authelia is deployed.
```

Recommended order:

```text
ARR base stack and VPN checks
-> basic monitoring and update notifications
-> backup verification
-> CrowdSec
-> Authelia
-> public reverse proxy exposure only if actually needed
-> Nextcloud
```

## Assumptions

Replace these if yours are different:

```text
Docker VM SSH user: alice
Docker VM IP:       192.168.1.20
Proxmox IP:         192.168.1.2
TrueNAS IP:         192.168.1.10
Monitoring path:    /opt/stacks/monitoring
Watchtower path:    /opt/stacks/watchtower
```

## Phase 0: SSH Into The Docker VM

Run from your own machine:

```powershell
ssh alice@192.168.1.20
```

Expected:

```text
You land on the Ubuntu Docker VM.
The prompt looks similar to: alice@docker-vm:~$
```

Fallback if SSH fails:

```powershell
ping 192.168.1.20
```

Then check SSH from the VM console:

```bash
sudo systemctl status ssh --no-pager
sudo systemctl enable --now ssh
ip -4 addr show
```

## Phase 1: Confirm Docker Works

Run on the Docker VM:

```bash
docker version
docker compose version
docker ps
```

Fallback if Docker permission is denied:

```bash
sudo usermod -aG docker "$USER"
exit
```

Then SSH back in:

```powershell
ssh alice@192.168.1.20
```

Fallback if Docker is not running:

```bash
sudo systemctl enable --now docker
sudo systemctl status docker --no-pager
```

## Phase 2: Create Monitoring Folders

Run on the Docker VM:

```bash
sudo mkdir -p /opt/stacks/monitoring
sudo chown -R "$USER":"$USER" /opt/stacks/monitoring

cd /opt/stacks/monitoring
mkdir -p prometheus/rules
mkdir -p alertmanager
mkdir -p grafana/provisioning/datasources
mkdir -p grafana/provisioning/dashboards
```

Verify:

```bash
find /opt/stacks/monitoring -maxdepth 4 -type d | sort
```

Fallback if permission is denied:

```bash
sudo chown -R "$USER":"$USER" /opt/stacks/monitoring
cd /opt/stacks/monitoring
```

## Phase 3: Create The Environment File

Your previous error happened because `.env.example` did not exist. That is fine.
Create `.env` directly instead.

Run on the Docker VM:

```bash
cd /opt/stacks/monitoring
GRAFANA_PASS="$(openssl rand -base64 32)"

cat > .env <<EOF
DOMAIN=lan.invalid
GRAFANA_PASSWORD=${GRAFANA_PASS}
EOF

chmod 600 .env
printf 'Grafana password: %s\n' "$GRAFANA_PASS"
```

Save the printed Grafana password.

Fallback if `openssl` is missing:

```bash
sudo apt update
sudo apt install -y openssl
```

Fallback if you lost the password later:

```bash
grep '^GRAFANA_PASSWORD=' /opt/stacks/monitoring/.env
```

## Phase 4: Create Docker Compose

Run on the Docker VM:

```bash
cd /opt/stacks/monitoring

cat > docker-compose.yml <<'EOF'
services:
  prometheus:
    image: prom/prometheus:v2.54.1
    container_name: prometheus
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "192.168.1.20:9090:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/rules:/etc/prometheus/rules:ro
      - prometheus_data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=30d"
      - "--web.enable-lifecycle"
    networks:
      - monitoring
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  grafana:
    image: grafana/grafana-oss:11.3.1
    container_name: grafana
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "192.168.1.20:3000:3000"
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_PASSWORD}
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_SERVER_DOMAIN: ${DOMAIN}
      GF_SERVER_ROOT_URL: http://192.168.1.20:3000
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    networks:
      - monitoring
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  node-exporter:
    image: prom/node-exporter:v1.8.2
    container_name: node-exporter
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    pid: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - "--path.procfs=/host/proc"
      - "--path.sysfs=/host/sys"
      - "--path.rootfs=/rootfs"
      - "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)"
    networks:
      - monitoring
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.2
    container_name: cadvisor
    restart: unless-stopped
    privileged: true
    devices:
      - /dev/kmsg
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker:/var/lib/docker:ro
      - /dev/disk:/dev/disk:ro
    networks:
      - monitoring
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  alertmanager:
    image: prom/alertmanager:v0.27.0
    container_name: alertmanager
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "192.168.1.20:9093:9093"
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - alertmanager_data:/alertmanager
    command:
      - "--config.file=/etc/alertmanager/alertmanager.yml"
      - "--storage.path=/alertmanager"
    networks:
      - monitoring
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  uptime-kuma:
    image: louislam/uptime-kuma:1.23.15
    container_name: uptime-kuma
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "192.168.1.20:3001:3001"
    volumes:
      - uptime_kuma_data:/app/data
    networks:
      - monitoring
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  monitoring:
    name: monitoring

volumes:
  prometheus_data:
  grafana_data:
  alertmanager_data:
  uptime_kuma_data:
EOF
```

Verify that no placeholder IP is left in the compose file:

```bash
grep -n "YOUR_DOCKER_VM_IP" docker-compose.yml || echo "No Docker VM IP placeholder found"
```

If it prints any lines, fix them:

```bash
sed -i "s/YOUR_DOCKER_VM_IP/192.168.1.20/g" docker-compose.yml
docker compose config
```

Fallback if you do not want to use `sed`:

```bash
nano /opt/stacks/monitoring/docker-compose.yml
```

Replace every:

```text
YOUR_DOCKER_VM_IP
```

with:

```text
192.168.1.20
```

## Phase 5: Create Prometheus Config

Run on the Docker VM:

```bash
cd /opt/stacks/monitoring

cat > prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "/etc/prometheus/rules/*.yml"

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - "alertmanager:9093"

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]
        labels:
          instance: "prometheus"

  - job_name: "docker-vm"
    static_configs:
      - targets: ["node-exporter:9100"]
        labels:
          instance: "docker-vm"

  - job_name: "cadvisor"
    static_configs:
      - targets: ["cadvisor:8080"]
        labels:
          instance: "docker-containers"

  # Enable after installing node-exporter on Proxmox.
  - job_name: "proxmox"
    static_configs:
      - targets: ["192.168.1.2:9100"]
        labels:
          instance: "proxmox"
EOF
```

Verify the Proxmox target:

```bash
grep -n "192.168.1.2:9100" prometheus/prometheus.yml
```

Fallback if you have not installed Proxmox node-exporter yet:

```bash
nano /opt/stacks/monitoring/prometheus/prometheus.yml
```

Comment out this block until later:

```yaml
  - job_name: "proxmox"
    static_configs:
      - targets: ["192.168.1.2:9100"]
        labels:
          instance: "proxmox"
```

## Phase 6: Create Alert Rules

Run on the Docker VM:

```bash
cd /opt/stacks/monitoring

cat > prometheus/rules/alerts.yml <<'EOF'
groups:
  - name: homelab_alerts
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }} is down"
          description: "Prometheus cannot scrape {{ $labels.job }} on {{ $labels.instance }}."

      - alert: DiskSpaceLow
        expr: |
          (
            node_filesystem_avail_bytes{fstype!~"tmpfs|overlay",mountpoint!~"/boot.*"}
            /
            node_filesystem_size_bytes{fstype!~"tmpfs|overlay",mountpoint!~"/boot.*"}
          ) * 100 < 20
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Disk space low on {{ $labels.instance }}"
          description: "{{ $labels.mountpoint }} has less than 20 percent free space."

      - alert: DiskSpaceCritical
        expr: |
          (
            node_filesystem_avail_bytes{fstype!~"tmpfs|overlay",mountpoint!~"/boot.*"}
            /
            node_filesystem_size_bytes{fstype!~"tmpfs|overlay",mountpoint!~"/boot.*"}
          ) * 100 < 10
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Disk space critical on {{ $labels.instance }}"
          description: "{{ $labels.mountpoint }} has less than 10 percent free space."

      - alert: HighMemoryUsage
        expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 90
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage on {{ $labels.instance }}"
          description: "Memory usage has been above 90 percent for 10 minutes."

      - alert: HighCPUUsage
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage on {{ $labels.instance }}"
          description: "CPU usage has been above 85 percent for 15 minutes."
EOF
```

Validate later after Prometheus starts:

```bash
docker exec prometheus promtool check rules /etc/prometheus/rules/alerts.yml
```

## Phase 7: Create Alertmanager Config

Start without real notifications. This lets the stack boot cleanly.

Do not put a placeholder URL in the active file. Alertmanager validates receiver
URLs during startup; an invalid placeholder causes a permanent restart loop.

Run on the Docker VM:

```bash
cd /opt/stacks/monitoring

cat > alertmanager/alertmanager.yml <<'EOF'
route:
  receiver: "local-only"
  group_by: ["alertname", "instance"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: "local-only"
EOF
```

Later you can add Discord, Telegram, or email.

### Repair An Existing Alertmanager Restart Loop

Run on the Docker VM:

```bash
cd /opt/stacks/monitoring
docker compose ps alertmanager
docker compose logs --tail 200 alertmanager
```

If the log says that `alertmanager.yml` cannot be parsed, loaded, or contains an
invalid URL, replace it with the local-only configuration above. Then validate
the file without relying on the restarting container:

```bash
docker compose run --rm --no-deps --entrypoint amtool alertmanager \
  check-config /etc/alertmanager/alertmanager.yml
docker compose up -d --force-recreate alertmanager
docker compose ps alertmanager
docker compose logs --tail 50 alertmanager
curl -fsS http://192.168.1.20:9093/-/ready
```

Expected: `SUCCESS`, container state `Up`, and an HTTP response from `/-/ready`.

If the log says `permission denied`, check both the bind-mounted config and the
named volume:

```bash
ls -l alertmanager/alertmanager.yml
docker volume inspect monitoring_alertmanager_data
docker compose config
```

Do not delete the volume as a first fix. It contains silences and notification
state, and a bad YAML file is not repaired by deleting data.

## Phase 8: Create Grafana Provisioning

Run on the Docker VM:

```bash
cd /opt/stacks/monitoring

cat > grafana/provisioning/datasources/prometheus.yml <<'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
EOF

cat > grafana/provisioning/dashboards/dashboards.yml <<'EOF'
apiVersion: 1

providers:
  - name: "Home Server"
    folder: "Home Server"
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards/json
EOF

mkdir -p grafana/provisioning/dashboards/json
```

## Phase 9: Start Monitoring

Run on the Docker VM:

```bash
cd /opt/stacks/monitoring
docker compose config
docker compose up -d
docker compose ps
```

Fallback if images fail to pull:

```bash
docker compose pull
docker compose up -d
```

Fallback if a port is already used:

```bash
sudo ss -lntp | grep -E ':3000|:3001|:9090|:9093' || true
nano docker-compose.yml
```

Change the left side of the port mapping. Example:

```yaml
ports:
  - "192.168.1.20:13000:3000"
```

That would make Grafana open at:

```text
http://192.168.1.20:13000
```

## Phase 10: Verify Monitoring

Run on the Docker VM:

```bash
curl -fsS http://192.168.1.20:3000/api/health
curl -fsS http://192.168.1.20:9090/-/healthy
curl -fsS http://192.168.1.20:9093/-/healthy
curl -fsS http://192.168.1.20:3001 | head
```

Check logs if something is unhealthy:

```bash
cd /opt/stacks/monitoring
docker compose logs --tail 100 grafana
docker compose logs --tail 100 prometheus
docker compose logs --tail 100 alertmanager
docker compose logs --tail 100 uptime-kuma
```

Validate Prometheus config:

```bash
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
docker exec prometheus promtool check rules /etc/prometheus/rules/alerts.yml
```

## Phase 11: Open The Web UIs

Open these from your browser:

```text
http://192.168.1.20:3000   Grafana
http://192.168.1.20:9090   Prometheus
http://192.168.1.20:9093   Alertmanager
http://192.168.1.20:3001   Uptime Kuma
```

Grafana login:

```text
Username: admin
Password: value from /opt/stacks/monitoring/.env
```

Retrieve the password:

```bash
grep '^GRAFANA_PASSWORD=' /opt/stacks/monitoring/.env
```

## Phase 12: Import Grafana Dashboards

In Grafana:

```text
Dashboards -> New -> Import
```

Use:

```text
1860   Node Exporter Full
```

If you later enable Traefik metrics:

```text
17346  Traefik
```

Do not spend time on dashboard `893` if Grafana warns that it depends on
Angular or if many panels show `N/A`. That dashboard is old and often does not
match current Grafana/cAdvisor label behavior. cAdvisor is still working if
Prometheus has data for these queries:

```promql
up{job="cadvisor"}
container_memory_working_set_bytes
rate(container_cpu_usage_seconds_total[5m])
container_fs_usage_bytes
```

Fallback if dashboard import fails or shows mostly `N/A`:

```text
Import only 1860 first.
Select Prometheus as the data source.
Save.
Use Prometheus queries to verify cAdvisor until you choose a newer Docker dashboard.
```

## Phase 13: Add Uptime Kuma Monitors

You can add monitors manually in the UI, but automation is easier once the
first Uptime Kuma admin account exists.

First, open Uptime Kuma once and create the admin user:

```text
http://192.168.1.20:3001
```

Then run this on the Docker VM.

Create an automation folder:

```bash
sudo mkdir -p /opt/stacks/uptime-kuma-automation
sudo chown -R "$USER":"$USER" /opt/stacks/uptime-kuma-automation
cd /opt/stacks/uptime-kuma-automation
```

Install the Python wrapper:

```bash
sudo apt update
sudo apt install -y python3-venv python3-pip
python3 -m venv .venv
. .venv/bin/activate
pip install uptime-kuma-api
```

Create the monitor script:

```bash
cat > add-monitors.py <<'EOF'
from getpass import getpass

from uptime_kuma_api import MonitorType, UptimeKumaApi

KUMA_URL = "http://192.168.1.20:3001"

MONITORS = [
    {
        "type": MonitorType.PORT,
        "name": "Docker VM SSH",
        "hostname": "192.168.1.20",
        "port": 22,
        "interval": 60,
        "maxretries": 2,
        "retryInterval": 60,
        "resendInterval": 240,
    },
    {
        "type": MonitorType.HTTP,
        "name": "Grafana",
        "url": "http://192.168.1.20:3000",
        "interval": 60,
        "maxretries": 2,
        "retryInterval": 60,
        "resendInterval": 240,
        "accepted_statuscodes": ["200-299", "300-399"],
    },
    {
        "type": MonitorType.HTTP,
        "name": "Prometheus",
        "url": "http://192.168.1.20:9090/-/healthy",
        "interval": 60,
        "maxretries": 2,
        "retryInterval": 60,
        "resendInterval": 240,
        "accepted_statuscodes": ["200-299", "300-399"],
    },
    {
        "type": MonitorType.HTTP,
        "name": "Alertmanager",
        "url": "http://192.168.1.20:9093/-/healthy",
        "interval": 60,
        "maxretries": 2,
        "retryInterval": 60,
        "resendInterval": 240,
        "accepted_statuscodes": ["200-299", "300-399"],
    },
    {
        "type": MonitorType.HTTP,
        "name": "Proxmox UI",
        "url": "https://192.168.1.2:8006",
        "ignoreTls": True,
        "interval": 60,
        "maxretries": 2,
        "retryInterval": 60,
        "resendInterval": 240,
        "accepted_statuscodes": ["200-299", "300-399"],
    },
    {
        "type": MonitorType.HTTP,
        "name": "TrueNAS UI",
        "url": "https://192.168.1.10",
        "ignoreTls": True,
        "interval": 60,
        "maxretries": 2,
        "retryInterval": 60,
        "resendInterval": 240,
        "accepted_statuscodes": ["200-299", "300-399"],
    },
]


def existing_monitor_names(api):
    return {monitor["name"] for monitor in api.get_monitors()}


username = input("Uptime Kuma username: ")
password = getpass("Uptime Kuma password: ")

with UptimeKumaApi(KUMA_URL) as api:
    api.login(username, password)
    existing = existing_monitor_names(api)

    for monitor in MONITORS:
        if monitor["name"] in existing:
            print(f"SKIP existing monitor: {monitor['name']}")
            continue

        result = api.add_monitor(**monitor)
        print(f"ADD {monitor['name']}: {result}")
EOF
```

Run it:

```bash
. /opt/stacks/uptime-kuma-automation/.venv/bin/activate
python /opt/stacks/uptime-kuma-automation/add-monitors.py
```

Expected:

```text
ADD Docker VM SSH: ...
ADD Grafana: ...
ADD Prometheus: ...
ADD Alertmanager: ...
ADD Proxmox UI: ...
ADD TrueNAS UI: ...
```

If you rerun the script, it skips monitors that already exist by name.

Fallback if the Python package install fails because the VM cannot reach PyPI:

```bash
sudo apt update
sudo apt install -y python3-venv python3-pip
pip --version
```

Then retry:

```bash
cd /opt/stacks/uptime-kuma-automation
. .venv/bin/activate
pip install uptime-kuma-api
```

Manual fallback in Uptime Kuma:

```text
Docker VM SSH: TCP, 192.168.1.20, port 22
Grafana: HTTP, http://192.168.1.20:3000
Prometheus: HTTP, http://192.168.1.20:9090/-/healthy
Jellyfin: HTTP, http://192.168.1.20:8096
qBittorrent UI: HTTP, your current qBittorrent URL
Radarr: HTTP, your current Radarr URL
Sonarr: HTTP, your current Sonarr URL
Prowlarr: HTTP, your current Prowlarr URL
TrueNAS UI: HTTPS, https://192.168.1.10
Proxmox UI: HTTPS, https://192.168.1.2:8006
```

Recommended settings:

```text
Heartbeat interval: 60 seconds
Retries: 2 or 3
Resend notification: 4 hours
```

Fallback for self-signed HTTPS on Proxmox or TrueNAS:

```text
Enable "Ignore TLS/SSL error" for that monitor.
```

## Phase 14: Install Proxmox Node Exporter

SSH to Proxmox from your own machine:

```powershell
ssh root@192.168.1.2
```

Run on Proxmox:

```bash
apt update
apt install -y prometheus-node-exporter
systemctl enable --now prometheus-node-exporter
systemctl status prometheus-node-exporter --no-pager
```

Exit Proxmox:

```bash
exit
```

Test from the Docker VM:

```bash
curl -fsS http://192.168.1.2:9100/metrics | head
```

Fallback if the port is blocked:

```bash
ssh root@192.168.1.2 "ss -lntp | grep 9100 || true && systemctl restart prometheus-node-exporter"
```

If node-exporter works on Proxmox itself but times out from the Docker VM:

```text
Proxmox local test works:
curl http://192.168.1.2:9100/metrics

Docker VM test fails:
curl http://192.168.1.2:9100/metrics
```

Then node-exporter is fine. The problem is firewall or routing between:

```text
Docker VM 192.168.1.20 -> Proxmox 192.168.1.2:9100
```

Test from the Docker VM:

```bash
ping -c 3 192.168.1.2
nc -vz -w 5 192.168.1.2 9100
```

Fallback if `nc` is missing:

```bash
sudo apt update
sudo apt install -y netcat-openbsd
nc -vz -w 5 192.168.1.2 9100
```

Check Proxmox firewall status:

```bash
ssh root@192.168.1.2
pve-firewall status
```

If you use the Proxmox firewall, allow:

```text
Source: 192.168.1.20
Destination port: 9100
Protocol: TCP
Action: ACCEPT
```

Add the rule in the Proxmox UI:

```text
Node: proxmox -> Firewall -> Add
Direction: in
Action: ACCEPT
Source: 192.168.1.20
Dest. port: 9100
Protocol: tcp
Comment: Allow Prometheus on Docker VM to scrape Proxmox node_exporter
Enable: checked
```

If the node-level firewall is disabled but datacenter firewall is enabled, add
the same rule under:

```text
Datacenter -> Firewall
```

Then test again from the Docker VM:

```bash
curl -4 -fsS --max-time 5 http://192.168.1.2:9100/metrics | head
```

## Phase 15: TrueNAS Monitoring

Start with TrueNAS built-in SMART and alerts.

Use the TrueNAS UI:

```text
System Settings -> Alert Services
Storage -> Disks -> S.M.A.R.T. Tests
```

Create:

```text
Short SMART test: daily
Long SMART test: weekly
Email or app alert service: enabled
```

Important:

```text
The Docker VM usually cannot read TrueNAS disk SMART data.
If TrueNAS owns the disks, SMART collection belongs on TrueNAS.
```

## Phase 16: Deploy Watchtower Monitor-Only

Create the Watchtower stack directly.

Run on the Docker VM:

```bash
sudo mkdir -p /opt/stacks/watchtower
sudo chown -R "$USER":"$USER" /opt/stacks/watchtower
cd /opt/stacks/watchtower

cat > docker-compose.yml <<'EOF'
services:
  watchtower:
    image: containrrr/watchtower:1.7.1
    container_name: watchtower
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    environment:
      - WATCHTOWER_MONITOR_ONLY=true
      - WATCHTOWER_SCHEDULE=0 0 4 * * 1
      - WATCHTOWER_CLEANUP=false
      - TZ=Europe/Berlin
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    healthcheck:
      test: ["CMD", "/watchtower", "--health-check"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
```

Start it:

```bash
docker compose config
docker compose up -d
docker compose logs --tail 100 watchtower
```

Confirm monitor-only mode:

```bash
docker inspect watchtower --format '{{range .Config.Env}}{{println .}}{{end}}' | grep WATCHTOWER_MONITOR_ONLY
```

Expected:

```text
WATCHTOWER_MONITOR_ONLY=true
```

This setting is mandatory. Watchtower reports image changes; it does not approve,
schedule, or perform your production updates. The Docker socket mount is still a
high-privilege interface even with `:ro`, so keep this stack private and use only
the official image.

Fallback if Watchtower cannot read Docker:

```bash
ls -l /var/run/docker.sock
docker logs --tail 100 watchtower
```

## Phase 17: Controlled Stack Update Workflow

Watchtower is only the signal that an image changed. Never run one command that
updates every stack. Use this process for one stack at a time.

### 17.1 Inventory And Triage

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
docker system df
cd /opt/stacks/STACK_NAME
docker compose config --images
docker compose ps
```

Read the upstream release notes. Treat database major versions, Nextcloud major
versions, reverse proxies, authentication, VPN gateways, and storage components
as planned maintenance. A notification is not proof that the new version is
compatible with this compose file.

### 17.2 Confirm Recovery Before Change

```bash
cd /opt/stacks/STACK_NAME
cp docker-compose.yml "docker-compose.yml.before-$(date +%F-%H%M)"
docker compose images
docker inspect $(docker compose ps -q) \
  --format '{{.Name}} {{.Config.Image}} {{.Image}}'
```

Before stateful updates, confirm the latest application/database backup exists
and that TrueNAS snapshots and Proxmox backups succeeded. Do not count a running
backup job as a tested restore.

### 17.3 Update The Pin And Validate

For an explicitly pinned image, edit the compose file or its `.env` tag to the
reviewed version first. Merely running `pull` does not move an immutable version
pin to a newer release.

```bash
nano docker-compose.yml
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail 100
```

Then test the real user path: login, one read/write action for stateful apps,
one media request for media services, and the health endpoint where available.
Watch Grafana and Uptime Kuma for at least 10 minutes before moving to another
stack.

### 17.4 Roll Back

If verification fails, collect logs first, restore the previous compose file or
tag, and recreate the stack:

```bash
cd /opt/stacks/STACK_NAME
docker compose logs --tail 200
nano docker-compose.yml
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps
```

An application or database migration may make an image-only rollback unsafe.
In that case follow that application's rollback documentation and restore its
database/appdata backup together. Never use `docker compose down -v` to roll back.

Clean old images only after the maintenance window and verification are complete:

```bash
docker image prune -f
```

### 17.5 Maintenance Cadence

| Frequency | Work |
|---|---|
| Continuous | Uptime Kuma checks service paths; Prometheus evaluates host/container alerts. |
| Weekly | Review Watchtower notices, failed alerts, backup results, disk space, and SMART alerts. |
| Monthly | Apply reviewed container updates one stack at a time; run OS security updates; verify one restore sample. |
| Quarterly | Review pinned versions, unsupported releases, alert thresholds, users/tokens, and disaster-recovery steps. |

For Ubuntu host maintenance:

```bash
sudo apt update
apt list --upgradable
sudo apt upgrade
test -f /var/run/reboot-required && cat /var/run/reboot-required || true
```

Reboot only in a maintenance window after confirming storage mounts and backups.
After reboot, verify `docker ps`, NFS mounts, the VPN kill switch, Prometheus
targets, Uptime Kuma, and application logins.

## Phase 18: Add Real Notifications

Start without notifications. After local monitoring works, add one notification
path at a time.

Good first options:

```text
Uptime Kuma Discord notification
Uptime Kuma Telegram notification
Alertmanager native Discord receiver
Alertmanager email for critical alerts
```

Do Uptime Kuma first because it is easier to configure from the UI.

For Alertmanager Discord, use the native `discord_configs` receiver, not a generic
`webhook_configs` receiver. A normal Discord webhook does not accept Alertmanager's
generic webhook payload.

The repo includes a starting template at:

```text
configs/docker/monitoring/alertmanager/alertmanager-discord.example.yml
```

Copy it to the server as `alertmanager/alertmanager.yml`, replace both URL
placeholders, protect the file, validate it, and reload:

```bash
chmod 600 alertmanager/alertmanager.yml
docker compose run --rm --no-deps --entrypoint amtool alertmanager \
  check-config /etc/alertmanager/alertmanager.yml
docker compose kill -s HUP alertmanager
docker compose logs --tail 50 alertmanager
```

Because that file contains a secret URL, do not commit the filled-in version.
Send a test alert or temporarily use an always-firing test rule, confirm both the
firing and resolved messages, and then remove the test rule.

## Phase 19: Move Behind Traefik Later

Do not do this until Authelia and CrowdSec work.

Follow this guide first:

```text
docs/security/authelia-crowdsec-before-public-exposure.md
```

Later, remove direct `ports:` from Grafana and Uptime Kuma, attach them to the
Traefik network, and add Traefik labels.

Only move to Traefik when:

```text
Authelia works.
CrowdSec works.
Cloudflare DNS challenge works.
TLS certs issue correctly.
You have a local or Tailscale recovery path if auth breaks.
```

## Fast Rollback

Stop monitoring but keep data:

```bash
cd /opt/stacks/monitoring
docker compose down
```

Stop Watchtower:

```bash
cd /opt/stacks/watchtower
docker compose down
```

Delete monitoring data only if you intentionally want a clean reset:

```bash
cd /opt/stacks/monitoring
docker compose down -v
```

Do not run `down -v` unless you are okay losing Grafana dashboards, Prometheus
history, Alertmanager state, and Uptime Kuma monitors.

## Minimum Success Checklist

```text
[ ] SSH from your machine to the Docker VM works.
[ ] Docker works on the Docker VM.
[ ] /opt/stacks/monitoring/docker-compose.yml exists.
[ ] /opt/stacks/monitoring/.env exists.
[ ] Grafana opens at http://192.168.1.20:3000.
[ ] Prometheus opens at http://192.168.1.20:9090.
[ ] Alertmanager opens at http://192.168.1.20:9093.
[ ] Alertmanager config passes `amtool check-config` and is not restarting.
[ ] Uptime Kuma opens at http://192.168.1.20:3001.
[ ] Watchtower is running in monitor-only mode.
[ ] Prometheus has prometheus, docker-vm, and cadvisor targets up.
[ ] Uptime Kuma monitors the Docker VM and current media services.
[ ] Proxmox exporter is added or intentionally deferred.
[ ] TrueNAS SMART alerts are configured in TrueNAS.
[ ] Nothing is publicly exposed just to make monitoring work.
[ ] A documented backup and rollback path exists before each stateful update.
```
