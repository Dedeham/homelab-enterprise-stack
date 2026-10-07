# Monitoring, Updates, And Backup Execution

Last updated: 2026-06-24

This guide does not require syncing this repo to the server. You will SSH into the Ubuntu Docker VM and create the monitoring files directly under `/opt/stacks`. It covers the full path from first deployment through ongoing maintenance, plus the hands-on backup execution steps that implement `docs/backup-strategy/storage-and-backup-plan.md`.

## Short Answer

Monitoring and update notifications are a good next step once the base stack is running.

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

## Part 1: Initial Deployment

### Phase 0: SSH Into The Docker VM

Run from your own machine:

```powershell
ssh alice@192.168.1.20
```

Expected: you land on the Ubuntu Docker VM, with a prompt similar to `alice@docker-vm:~$`.

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

### Phase 1: Confirm Docker Works

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

Then SSH back in and, if Docker is not running:

```bash
sudo systemctl enable --now docker
sudo systemctl status docker --no-pager
```

### Phase 2: Create Monitoring Folders

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

### Phase 3: Create The Environment File

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

Save the printed Grafana password. Fallback if `openssl` is missing:

```bash
sudo apt update
sudo apt install -y openssl
```

If the password is lost later:

```bash
grep '^GRAFANA_PASSWORD=' /opt/stacks/monitoring/.env
```

### Phase 4: Create Docker Compose

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

### Phase 5: Create Prometheus Config

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

If Proxmox node-exporter isn't installed yet, comment out the `proxmox` job block until Phase 14 is complete.

### Phase 6: Create Alert Rules

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

Validate later once Prometheus is running:

```bash
docker exec prometheus promtool check rules /etc/prometheus/rules/alerts.yml
```

### Phase 7: Create Alertmanager Config

Start without real notifications, which lets the stack boot cleanly. Do not put a placeholder URL in the active file — Alertmanager validates receiver URLs during startup, and an invalid placeholder causes a permanent restart loop.

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

#### Repairing An Alertmanager Restart Loop

```bash
cd /opt/stacks/monitoring
docker compose ps alertmanager
docker compose logs --tail 200 alertmanager
```

If the log says `alertmanager.yml` cannot be parsed, loaded, or contains an invalid URL, replace it with the local-only configuration above, then validate without relying on the restarting container:

```bash
docker compose run --rm --no-deps --entrypoint amtool alertmanager \
  check-config /etc/alertmanager/alertmanager.yml
docker compose up -d --force-recreate alertmanager
docker compose ps alertmanager
docker compose logs --tail 50 alertmanager
curl -fsS http://192.168.1.20:9093/-/ready
```

Expected: `SUCCESS`, container state `Up`, and an HTTP response from `/-/ready`.

If the log says `permission denied`, check both the bind-mounted config and the named volume:

```bash
ls -l alertmanager/alertmanager.yml
docker volume inspect monitoring_alertmanager_data
docker compose config
```

Do not delete the volume as a first fix — it contains silences and notification state, and a bad YAML file is not repaired by deleting data.

### Phase 8: Create Grafana Provisioning

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

### Phase 9: Start Monitoring

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

Change the left side of the port mapping, e.g. `"192.168.1.20:13000:3000"`, which makes Grafana open at `http://192.168.1.20:13000`.

### Phase 10: Verify Monitoring

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

### Phase 11: Open The Web UIs

```text
http://192.168.1.20:3000   Grafana
http://192.168.1.20:9090   Prometheus
http://192.168.1.20:9093   Alertmanager
http://192.168.1.20:3001   Uptime Kuma
```

Grafana login is `admin` with the password from `/opt/stacks/monitoring/.env`:

```bash
grep '^GRAFANA_PASSWORD=' /opt/stacks/monitoring/.env
```

### Phase 12: Import Grafana Dashboards

In Grafana, go to Dashboards → New → Import, and use dashboard ID `1860` (Node Exporter Full). If Traefik metrics are enabled later, also import `17346` (Traefik).

Dashboard `893` (Docker & cAdvisor) is often skipped if Grafana warns it depends on Angular or shows many panels as `N/A` — it's old and often doesn't match current Grafana/cAdvisor label behavior. cAdvisor is still working if Prometheus has data for:

```promql
up{job="cadvisor"}
container_memory_working_set_bytes
rate(container_cpu_usage_seconds_total[5m])
container_fs_usage_bytes
```

If dashboard import fails or shows mostly `N/A`: import only `1860` first, select Prometheus as the data source, save, and use Prometheus queries to verify cAdvisor until a newer Docker dashboard is chosen.

### Phase 13: Add Uptime Kuma Monitors

Open `http://192.168.1.20:3001` and create the admin user on first run.

Monitors can be added manually in the UI, or automated with a Python wrapper once the admin account exists:

```bash
sudo mkdir -p /opt/stacks/uptime-kuma-automation
sudo chown -R "$USER":"$USER" /opt/stacks/uptime-kuma-automation
cd /opt/stacks/uptime-kuma-automation

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

Reruns skip monitors that already exist by name.

Manual fallback in Uptime Kuma if the script can't be used:

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

Recommended settings: 60-second heartbeat interval, 2-3 retries, 4-hour resend notification. Enable "Ignore TLS/SSL error" for self-signed Proxmox/TrueNAS monitors.

### Phase 14: Install Proxmox Node Exporter

```powershell
ssh root@192.168.1.2
```

```bash
apt update
apt install -y prometheus-node-exporter
systemctl enable --now prometheus-node-exporter
systemctl status prometheus-node-exporter --no-pager
exit
```

Test from the Docker VM:

```bash
curl -fsS http://192.168.1.2:9100/metrics | head
```

If node-exporter works locally on Proxmox but times out from the Docker VM, the problem is firewall or routing between `192.168.1.20` and `192.168.1.2:9100`. Test:

```bash
ping -c 3 192.168.1.2
nc -vz -w 5 192.168.1.2 9100
```

If `nc` is missing:

```bash
sudo apt update
sudo apt install -y netcat-openbsd
nc -vz -w 5 192.168.1.2 9100
```

Check the Proxmox firewall:

```bash
ssh root@192.168.1.2
pve-firewall status
```

If the Proxmox firewall is used, add a rule allowing source `192.168.1.20`, destination port `9100`, protocol TCP, under Node → Firewall → Add (or Datacenter → Firewall if the node-level firewall is disabled but the datacenter firewall is enabled). Then retest:

```bash
curl -4 -fsS --max-time 5 http://192.168.1.2:9100/metrics | head
```

### Phase 15: TrueNAS Monitoring

Start with TrueNAS's built-in SMART and alerts, via System Settings → Alert Services and Storage → Disks → S.M.A.R.T. Tests: short SMART test daily, long SMART test weekly, email or app alert service enabled.

The Docker VM usually cannot read TrueNAS disk SMART data directly — since TrueNAS owns the disks, SMART collection belongs on TrueNAS.

### Phase 16: Deploy Watchtower Monitor-Only

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

docker compose config
docker compose up -d
docker compose logs --tail 100 watchtower
```

Confirm monitor-only mode:

```bash
docker inspect watchtower --format '{{range .Config.Env}}{{println .}}{{end}}' | grep WATCHTOWER_MONITOR_ONLY
```

Expected: `WATCHTOWER_MONITOR_ONLY=true`. This setting is mandatory — Watchtower reports image changes but does not apply updates. The Docker socket mount is still a high-privilege interface even read-only, so this stack stays private and uses only the official image.

## Part 2: Ongoing Maintenance

Use this part only after Part 1 is complete and the stack is healthy. It does not recreate containers, volumes, dashboards, or configuration files.

### Rules

1. Run shell commands on the Ubuntu Docker VM unless stated otherwise.
2. Keep Watchtower in monitor-only mode.
3. Change and verify one stack at a time.
4. Never use `docker compose down -v` during maintenance or rollback.
5. Confirm backups before updating stateful services.
6. Keep Grafana, Prometheus, Alertmanager, and Uptime Kuma LAN/Tailscale-only.

### Record The Current Healthy State

```bash
cd /opt/stacks/monitoring
docker compose config --quiet
docker compose ps
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
```

Expected containers: `prometheus`, `grafana`, `node-exporter`, `cadvisor`, `alertmanager`, `uptime-kuma` — all `Up`, with health checks taking a minute or two to become `healthy`.

Save a pre-maintenance inventory:

```bash
mkdir -p "$HOME/maintenance-records"
STAMP="$(date +%F-%H%M)"

docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}' \
  > "$HOME/maintenance-records/containers-$STAMP.txt"
docker inspect $(docker ps -q) \
  --format '{{.Name}}|{{.Config.Image}}|{{.Image}}' \
  > "$HOME/maintenance-records/images-$STAMP.txt"
```

### Verify Every Monitoring Layer

HTTP health:

```bash
curl -fsS http://192.168.1.20:3000/api/health
curl -fsS http://192.168.1.20:9090/-/ready
curl -fsS http://192.168.1.20:9093/-/ready
curl -fsS http://192.168.1.20:3001/ >/dev/null
echo "Monitoring HTTP checks passed"
```

Prometheus targets — open `http://192.168.1.20:9090/targets` and confirm Prometheus, node-exporter, and cAdvisor jobs are `UP`. With `jq` installed:

```bash
curl -fsS http://192.168.1.20:9090/api/v1/targets | \
  jq -r '.data.activeTargets[] |
    [.labels.job, .scrapeUrl, .health, (.lastError // "")] | @tsv'
```

Prometheus config and rules:

```bash
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
docker exec prometheus promtool check rules /etc/prometheus/rules/alerts.yml
```

### Test The Prometheus To Alertmanager Path

A temporary always-firing alert confirms the pipeline without stopping a real service:

```bash
cd /opt/stacks/monitoring

cat > prometheus/rules/follow-up-test.yml <<'EOF'
groups:
  - name: follow_up_test
    rules:
      - alert: FollowUpPipelineTest
        expr: vector(1)
        for: 30s
        labels:
          severity: warning
        annotations:
          summary: "Temporary monitoring pipeline test"
          description: "Remove follow-up-test.yml after this alert reaches Alertmanager."
EOF

docker exec prometheus promtool check rules \
  /etc/prometheus/rules/follow-up-test.yml
docker compose kill -s HUP prometheus
docker compose logs --tail 50 prometheus
```

Wait a minute, then open `http://192.168.1.20:9090/alerts` and `http://192.168.1.20:9093/#/alerts` — `FollowUpPipelineTest` should be firing in both. Remove it immediately after confirming:

```bash
rm prometheus/rules/follow-up-test.yml
docker compose kill -s HUP prometheus
```

Wait another minute; the alert should disappear or show resolved. If it's in Prometheus but not Alertmanager:

```bash
docker compose logs --tail 100 prometheus
docker compose logs --tail 100 alertmanager
docker exec prometheus wget -qO- http://alertmanager:9093/-/ready
```

### Configure Uptime Kuma For Actionable Notifications

| Monitor | Type | Target |
|---|---|---|
| Grafana | HTTP | `http://192.168.1.20:3000/api/health` |
| Prometheus | HTTP | `http://192.168.1.20:9090/-/ready` |
| Alertmanager | HTTP | `http://192.168.1.20:9093/-/ready` |
| Docker VM | Ping | `192.168.1.20` |
| Proxmox | Ping | Actual Proxmox IP |
| TrueNAS | Ping | `192.168.1.10` |
| ARR/media apps | HTTP | Each application's current LAN URL and port |

Recommended: 60-second heartbeat, 3 retries, 30-second retry interval, certificate expiry notification enabled for HTTPS monitors.

In Settings → Notifications, add one provider (Discord or Telegram is simplest), test it, then run a controlled failure to confirm it works end to end:

```bash
cd /opt/stacks/monitoring
docker compose stop grafana
```

Confirm Uptime Kuma reports Grafana down and sends a notification, then restore:

```bash
docker compose start grafana
docker compose ps grafana
curl -fsS http://192.168.1.20:3000/api/health
```

Confirm the recovery notification arrives. Do not stop Alertmanager for this test.

### Verify Grafana

Open `http://192.168.1.20:3000`, go to Connections → Data sources → Prometheus → Save & test (should use `http://prometheus:9090`).

In Explore: select the Prometheus data source, set the time range to Last 15 minutes, use Code mode, run one query at a time, and use Table view for labels or Time series for CPU/memory/disk graphs. Add additional queries as separate rows (A, B, …) rather than pasting multiple queries into one box.

Useful diagnostic queries:

```promql
up
up{job="docker-vm"}
node_uname_info
node_uname_info{job="docker-vm"}
100 - (avg by (instance) (rate(node_cpu_seconds_total{job="docker-vm", mode="idle"}[5m])) * 100)
100 * (1 - node_memory_MemAvailable_bytes{job="docker-vm"} / node_memory_MemTotal_bytes{job="docker-vm"})
100 * (1 - node_filesystem_avail_bytes{job="docker-vm", fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{job="docker-vm", fstype!~"tmpfs|overlay"})
```

`node_memory_MemAvailable_bytes` is used rather than `MemFree` because Linux intentionally uses free RAM for cache, which would otherwise make healthy systems look unnecessarily full.

Diagnosing `No Data`, in order: confirm the Prometheus data source passes Save & test; run `up` (no data means a Grafana/Prometheus problem, not node-exporter); run `up{job="docker-vm"}` (no series means the job has another name or is absent, `0` means it's configured but failing); run `node_uname_info` to inspect real labels; check `http://192.168.1.20:9090/targets` for the node-exporter target's `Last scrape` and `Error`; then check containers and logs:

```bash
cd /opt/stacks/monitoring
docker compose ps prometheus node-exporter
docker compose logs --tail 100 prometheus node-exporter
docker inspect node-exporter --format '{{json .NetworkSettings.Networks}}'
docker inspect prometheus --format '{{json .NetworkSettings.Networks}}'
```

Both containers must share the monitoring Docker network, and Prometheus must target `node-exporter:9100` (not the Docker VM's LAN address) unless port `9100` is intentionally published. After editing `prometheus/prometheus.yml`:

```bash
cd /opt/stacks/monitoring
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
docker compose kill -s HUP prometheus
docker compose logs --tail 50 prometheus
```

Imported dashboards often expect a different `job` label than the one deployed here — adjust the dashboard's data-source variable or job filter to match the labels shown by `up`, rather than renaming the actual job.

### Review Watchtower Without Enabling Updates

```bash
cd /opt/stacks/watchtower
docker compose config --quiet
docker compose ps
docker compose logs --tail 200 watchtower

docker inspect watchtower \
  --format '{{range .Config.Env}}{{println .}}{{end}}' | \
  grep '^WATCHTOWER_MONITOR_ONLY=true$'
```

Trigger an immediate check without changing containers:

```bash
docker compose run --rm watchtower --run-once --monitor-only
```

`Found new ... image` means review is required, not an instruction to update everything. Authentication or registry `HEAD` errors mean that image wasn't checked successfully. Never enable `WATCHTOWER_MONITOR_ONLY=false`.

#### Adding Watchtower Update Notifications

Watchtower notifications answer "are newer images available?" — not whether an update is safe, and they never apply it automatically.

**Discord:** create a webhook, then:

```bash
cd /opt/stacks/watchtower
nano .env
```

```env
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/WEBHOOK_ID/WEBHOOK_TOKEN
```

Ensure `docker-compose.yml` has:

```yaml
      - WATCHTOWER_MONITOR_ONLY=true
      - WATCHTOWER_NOTIFICATIONS=slack
      - WATCHTOWER_NOTIFICATION_SLACK_HOOK_URL=${DISCORD_WEBHOOK_URL}/slack
```

```bash
docker compose config --quiet
docker compose up -d
docker compose logs --tail 100 watchtower
docker compose run --rm watchtower --run-once --monitor-only
```

Use `--quiet` rather than full `docker compose config` after adding the webhook, since it would print the secret URL.

**Telegram:** message `@BotFather`, create a bot with `/newbot`, save the token, and start a chat with the bot (or add it to the target group/channel). Find the chat target:

```bash
docker run --rm -it containrrr/shoutrrr generate telegram
```

```bash
cd /opt/stacks/watchtower
nano .env
```

```env
WATCHTOWER_NOTIFICATION_URL=telegram://BOT_TOKEN@telegram?chats=CHAT_ID
```

Edit `docker-compose.yml` to remove the Discord-only lines and use:

```yaml
      - WATCHTOWER_NOTIFICATION_URL=${WATCHTOWER_NOTIFICATION_URL}
```

```bash
docker compose config --quiet
docker compose up -d
docker compose logs --tail 100 watchtower
docker compose run --rm watchtower --run-once --monitor-only
```

**Both together:** use shoutrrr URLs for both providers separated by a space, e.g. `telegram://BOT_TOKEN@telegram?chats=CHAT_ID discord://DISCORD_WEBHOOK_TOKEN@DISCORD_WEBHOOK_ID`, with only `WATCHTOWER_NOTIFICATION_URL=${WATCHTOWER_NOTIFICATION_URL}` in compose — not the legacy `WATCHTOWER_NOTIFICATIONS=slack` lines.

For email, Uptime Kuma SMTP notifications are preferred for service outages, since Watchtower email requires maintaining SMTP credentials on the Docker VM.

### Controlled Stack Update Workflow

Watchtower is only the signal that an image changed — never run one command that updates every stack. Update one stack at a time.

**Inventory and triage:**

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
docker system df
cd /opt/stacks/STACK_NAME
docker compose config --images
docker compose ps
```

Read upstream release notes. Treat database major versions, Nextcloud major versions, reverse proxies, auth, VPN gateways, and storage components as planned maintenance — a notification is not proof of compatibility.

**Confirm recovery before changing anything:**

```bash
cd /opt/stacks/STACK_NAME
cp docker-compose.yml "docker-compose.yml.before-$(date +%F-%H%M)"
docker compose images
docker inspect $(docker compose ps -q) \
  --format '{{.Name}} {{.Config.Image}} {{.Image}}'
```

Before stateful updates, confirm the latest application/database backup exists and that TrueNAS snapshots and Proxmox backups succeeded — a running backup job is not a tested restore.

**Find the real stack and image** (example: Jellyfin):

```bash
docker inspect jellyfin --format 'Image={{.Config.Image}}'
docker inspect jellyfin --format 'Compose dir={{ index .Config.Labels "com.docker.compose.project.working_dir" }}'
docker inspect jellyfin --format 'Compose files={{ index .Config.Labels "com.docker.compose.project.config_files" }}'

cd "$(docker inspect jellyfin --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}')"
docker compose config --images
docker compose ps jellyfin
```

| Image prefix | Provider | Update rule |
|---|---|---|
| `jellyfin/jellyfin` | Official Jellyfin image | Match the tag to Jellyfin release notes |
| `lscr.io/linuxserver/jellyfin` | LinuxServer image | Match the tag to LinuxServer's tag list and read both sets of release notes |

Don't switch providers during a routine update — treat that as a migration.

**Check whether the compose file needs editing:**

```bash
docker compose config --images | grep -i jellyfin
```

A `:latest` tag needs no compose edit for a normal pull:

```bash
docker compose pull jellyfin
docker compose up -d jellyfin
```

A pinned version tag (e.g. `jellyfin/jellyfin:10.9.7`) must be edited to the reviewed new version first, and verified to exist before editing the stack:

```bash
docker manifest inspect jellyfin/jellyfin:<reviewed-new-version> >/dev/null && echo "tag exists"
```

(or `docker manifest inspect lscr.io/linuxserver/jellyfin:<reviewed-new-tag>` for LinuxServer).

Choosing the tag: check the currently running version in the app's admin dashboard, read the release notes for the same provider/image, prefer the newest stable patch release without unresolved manual migration steps, avoid major jumps until a fresh config backup exists and there's time to test, and verify the exact tag exists before committing to it.

For a stateful stack, don't proceed until: the latest database/application backup succeeded, the latest TrueNAS snapshot succeeded, the latest Proxmox VM backup succeeded, the restore procedure is known, and the release notes contain no unresolved migration requirement.

**Apply one update:**

```bash
nano docker-compose.yml
docker compose config --quiet
docker compose pull jellyfin
docker compose up -d jellyfin
docker compose ps jellyfin
docker compose logs --tail 100 jellyfin
```

Test the real application, not just the container state. For Jellyfin: web UI loads, admin login works, library metadata is present, an existing movie/episode plays, hardware transcoding still sees `/dev/dri` if Quick Sync is used, the Uptime Kuma monitor returns to UP, and logs show no repeated database/migration/permission/FFmpeg errors. Watch it for at least ten minutes before touching another stack.

**Roll back if verification fails:**

```bash
docker compose ps
docker compose logs --tail 200
```

Restore the previous image tag in `docker-compose.yml` or `.env`, then:

```bash
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps
```

If the update migrated a database or appdata format, don't force an old image onto migrated data — follow the application's own rollback procedure and restore the matching backup instead.

Prune old images only after successful verification and the rollback window:

```bash
docker image prune -f
```

### Patch The Ubuntu Docker VM

```bash
docker ps
findmnt /mnt/main
findmnt /mnt/media
sudo apt update
apt list --upgradable
sudo apt upgrade
```

Check for a required reboot:

```bash
if [ -f /var/run/reboot-required ]; then
  cat /var/run/reboot-required
else
  echo "No reboot required"
fi
```

Reboot only during a maintenance window:

```bash
sudo reboot
```

After reconnecting:

```bash
findmnt /mnt/main
findmnt /mnt/media
docker ps --format 'table {{.Names}}\t{{.Status}}'
cd /opt/stacks/monitoring
docker compose ps
curl -fsS http://192.168.1.20:9090/-/ready
curl -fsS http://192.168.1.20:9093/-/ready
```

Also rerun the ARR/Gluetun leak and kill-switch checks before considering maintenance complete.

### Weekly Maintenance Checklist

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
docker system df
df -h

cd /opt/stacks/monitoring
docker compose ps
docker compose logs --since 168h prometheus alertmanager uptime-kuma | \
  grep -Ei 'error|failed|panic' || true

cd /opt/stacks/watchtower
docker compose logs --since 168h watchtower

sudo apt update
apt list --upgradable
```

Also confirm: Prometheus targets are UP; no unexpected alerts remain firing; Uptime Kuma monitors and notifications work; Watchtower remains monitor-only with completed registry checks; TrueNAS SMART tests, scrubs, snapshots, and alerts are healthy; Proxmox backup jobs succeeded; application/database backups succeeded; disk usage has enough headroom.

### Monthly And Quarterly Work

Monthly: review supported versions and upstream release notes; update approved containers one stack at a time; apply Ubuntu updates and schedule any required reboot; test one notification path; restore one sample file or non-production database backup.

Quarterly: review every pinned image for support status; review Prometheus thresholds and remove noisy alerts; review Uptime Kuma monitors for deleted or missing services; review accounts, tokens, webhook URLs, and expired credentials; walk through the disaster-recovery runbook; confirm monitoring remains private with no router port forward.

## Part 3: Backup Execution

This section carries out the backup strategy described in `docs/backup-strategy/storage-and-backup-plan.md`. That document defines what is protected and on what schedule; this section runs the commands that implement it.

### Install The Database Backup Script

The repo contains `scripts/backup/db-backup.sh`, which dumps Nextcloud MariaDB and Vaultwarden SQLite. It is installed on the Docker VM, not TrueNAS, because it uses `docker exec`:

```bash
sudo mkdir -p /mnt/main/scripts
sudo cp scripts/backup/db-backup.sh /mnt/main/scripts/db-backup.sh
sudo chmod 750 /mnt/main/scripts/db-backup.sh
```

Create the secrets file on the Docker VM:

```bash
sudo nano /root/.db-backup-secrets
sudo chmod 600 /root/.db-backup-secrets
```

Example contents:

```bash
DB_USER=nextcloud
DB_PASS=replace_with_the_nextcloud_database_password
```

Test manually:

```bash
sudo bash /mnt/main/scripts/db-backup.sh
ls -lah /mnt/main/backups/db
```

Schedule it with cron:

```bash
sudo crontab -e
```

Add:

```cron
30 1 * * * /bin/bash /mnt/main/scripts/db-backup.sh
```

This dump runs at `01:30`, ahead of the `02:00` TrueNAS snapshot of `main/backups` and `main/appdata`, so the snapshot captures a fresh dump.

For the dedicated Nextcloud VM deployment, use `scripts/backup/nextcloud-vm-backup.sh` instead, which runs on the Nextcloud VM and writes MariaDB dumps plus the local Nextcloud app/config archive to `/mnt/nc-backups` (mapped to `/mnt/main/backups/nextcloud-db` on TrueNAS).

### Create TrueNAS Snapshot Tasks

In TrueNAS: Data Protection → Periodic Snapshot Tasks → Add, using the schedule from the backup strategy document (`main/appdata` every 6 hours/14 days, `main/backups` daily/30 days, `main/nextcloud` daily/30 days, `main/userdata` daily/30-90 days, `main/media/data` daily or weekly/7-14 days).

### Configure Off-Server Backup

**Replication** (Data Protection → Replication Tasks → Add): replicate `main/appdata`, `main/backups`, `main/nextcloud`, and `main/userdata`. Skip `main/media/data` by default.

**Cloud Sync** (Data Protection → Cloud Sync Tasks → Add): direction Push, transfer mode Sync or Copy, encryption enabled if supported, schedule daily after snapshots, including `appdata`, `backups`, `nextcloud`, `userdata`, excluding large replaceable media and downloads.

### Export The TrueNAS Config

After creating pools, shares, users, snapshot tasks, replication tasks, or cloud sync tasks:

```text
System Settings -> General -> Manage Configuration -> Download File
```

Store the resulting file in a password manager/encrypted archive and in an off-server backup location.

### Export The Proxmox Config

```bash
tar czf /root/proxmox-config-$(date +%F).tar.gz /etc/pve
```

Copy that archive off the Proxmox host — do not leave the only copy on the same boot disk.

### Minimum Setup To Do Now

If only the essentials get done, do these in order:

```text
1. Create TrueNAS snapshot tasks for main/appdata and main/backups.
2. Run database dumps into /mnt/main/backups/db for database-backed containers.
3. Export the TrueNAS config file.
4. Configure Proxmox backups for the TrueNAS VM boot disk and Ubuntu Docker VM.
5. Add one off-server backup target for appdata, backups, and user data.
6. Restore one test file from snapshot and one file from the off-server backup.
```

That gives the practical baseline: Proxmox can restore machines, TrueNAS can restore data, and `appdata` is protected beyond the mirror.

### Restore Tests

Run these quarterly:

```text
[ ] Restore one file from snapshot (TrueNAS) — file opens and has expected contents.
[ ] Restore one database dump to a test database (Docker VM) — app can read the restored database.
[ ] Restore one file from off-server backup — downloaded/restored file matches original.
[ ] Restore Docker VM backup (Proxmox test VM or maintenance window) — VM boots and mounts TrueNAS.
[ ] Import TrueNAS config (maintenance test or documented dry run) — confirms where the config file is.
```

Quick snapshot restore pattern from the Docker VM:

```bash
ls /mnt/main/.zfs/snapshot
```

If the `.zfs` directory is not visible, enable snapshot directory visibility in TrueNAS for the dataset, or restore through the TrueNAS UI.

## Part 4: Before Public Exposure

Do not move monitoring behind Traefik until Authelia and CrowdSec work — follow `docs/security/authelia-crowdsec-before-public-exposure.md` first. Only move to Traefik once Authelia works, CrowdSec works, the Cloudflare DNS challenge works, TLS certs issue correctly, and a local or Tailscale recovery path exists if auth breaks. At that point, remove direct `ports:` from Grafana and Uptime Kuma, attach them to the Traefik network, and add Traefik labels.

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

Delete monitoring data only for an intentional clean reset:

```bash
cd /opt/stacks/monitoring
docker compose down -v
```

Do not run `down -v` unless losing Grafana dashboards, Prometheus history, Alertmanager state, and Uptime Kuma monitors is acceptable.

## Completion Checklist

```text
[ ] SSH from your machine to the Docker VM works.
[ ] Docker works on the Docker VM.
[ ] /opt/stacks/monitoring/docker-compose.yml and .env exist.
[ ] Grafana, Prometheus, Alertmanager, and Uptime Kuma all open on their ports.
[ ] Alertmanager config passes amtool check-config and is not restarting.
[ ] Watchtower is running in monitor-only mode.
[ ] Prometheus has prometheus, docker-vm, and cadvisor targets up; Proxmox is added or intentionally deferred.
[ ] Uptime Kuma monitors the Docker VM and current media services, and sent both a down and recovery notification.
[ ] TrueNAS SMART alerts are configured in TrueNAS.
[ ] The temporary test alert reached Alertmanager and was removed.
[ ] Grafana queries return current host metrics.
[ ] One low-risk stack completed the update and rollback-readiness workflow.
[ ] Ubuntu updates and reboot handling are understood.
[ ] Database dumps, TrueNAS snapshots, off-server backup, and TrueNAS/Proxmox config exports are all in place.
[ ] One restore test has been run successfully.
[ ] Weekly, monthly, and quarterly maintenance are scheduled.
[ ] Nothing in this stack is publicly exposed.
```

After this checklist passes, continue with the security guides before following the Traefik/Cloudflare public-access guide — monitoring itself does not need public exposure.
