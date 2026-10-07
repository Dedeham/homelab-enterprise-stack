# Monitoring Stack

Sources: Grafana Labs official docs, Prometheus docs, linuxserver.io community guides, and home server best practices (2025).

## What Monitoring Covers

Monitoring exists to know about problems before they become disasters: a failing hard drive raises an alert before data is lost, a filling disk raises an alert before Nextcloud crashes, CrowdSec blocks a brute-force login attempt and surfaces it in Grafana, and an offline server produces a notification within minutes.

## The Monitoring Stack

This setup uses several specialized tools, each doing one job:

```
+-----------------------------------------------------------------+
|                    MONITORING OVERVIEW                          |
|                                                                 |
|  +-------------+  +--------------+  +----------------------+   |
|  | Node        |  | cAdvisor     |  | Scrutiny             |   |
|  | Exporter    |  |              |  |                      |   |
|  |             |  | Per-container|  | Disk S.M.A.R.T.      |   |
|  | Host metrics|  | resource use |  | health + history     |   |
|  +------+------+  +------+-------+  +----------+-----------+   |
|         |                |                      |               |
|         +----------------+----------------------+               |
|                          | all metrics flow here                 |
|                          ▼                                       |
|                  +---------------+                              |
|                  |  Prometheus   |                              |
|                  |  Metric       |                              |
|                  |  database     |                              |
|                  +-------+-------+                              |
|                          |                                       |
|              +-----------+-----------+                          |
|              |           |           |                          |
|              ▼           ▼           ▼                          |
|         +---------+ +---------+ +--------------+               |
|         | Grafana | | Uptime  | | Alertmanager |               |
|         | Charts  | | Kuma    | | Notification |               |
|         | and     | | Service | | routing      |               |
|         | graphs  | | up/down | |              |               |
|         +---------+ +---------+ +--------------+               |
+-----------------------------------------------------------------+
```

## Tool Roles

### Prometheus — The Metric Database

Prometheus is a time-series database: it records numbers over time (CPU, memory, disk, container stats) by periodically scraping them from exporters. On its own it has no UI — it just collects and stores.

### Grafana — The Dashboard

Grafana reads the numbers stored in Prometheus and turns them into charts, graphs, and dashboards, making trends (climbing RAM over days, a disk I/O spike at 2 AM) visible at a glance.

### Node Exporter — The Server Health Reporter

A small program running on each server (TrueNAS and the Docker VM) that measures CPU, RAM, disk space, network traffic, and system temperature, exposing those numbers for Prometheus to scrape.

### cAdvisor — The Container Inspector

cAdvisor reports per-container CPU, RAM, and network usage, so resource consumption can be attributed to a specific container rather than just "the server."

### Scrutiny — The Disk Health Monitor

Scrutiny reads S.M.A.R.T. data from the hard drives — bad sector counts, temperature, and other wear indicators — and stores it over time so failing drives are visible before they actually fail.

### Uptime Kuma — The "Is It Up?" Monitor

Uptime Kuma checks whether services are actually reachable and responding, independent of host-level metrics. It can catch a crashed Traefik even when Prometheus still shows the host as healthy.

### Alertmanager — The Notification Router

Alertmanager receives threshold breaches from Prometheus and routes them to configured notification channels (email, Discord, Telegram, webhook).

## What Is Monitored

### System Health (Node Exporter)

| Metric | Warning Threshold | Critical Threshold | Why It Matters |
|---|---|---|---|
| CPU usage | > 80% for 10 min | > 95% for 5 min | Sustained high CPU signals something's wrong or overloaded |
| RAM usage | > 85% | > 95% | Low RAM causes slowdowns and OOM kills |
| Disk space | > 80% full | > 90% full | Full disk crashes services, especially databases |
| Disk I/O | Unusual spikes | — | Could indicate a failing drive or runaway process |
| Load average | > 4.0 (1min) | > 8.0 (1min) | Shows whether the server is overwhelmed with tasks |
| Network traffic | Unusual spike | — | Could indicate data exfiltration or DDoS |
| System uptime | — | Unexpected reboot | Reboots without intent indicate a problem |

### Hard Drive Health (Scrutiny + SMART)

| Attribute | ID | Healthy | Action if Not |
|---|---|---|---|
| Overall SMART status | — | PASSED | Replace drive immediately |
| Reallocated sectors | 5 | 0 | Drive is remapping bad sectors — plan replacement |
| Pending sectors | 197 | 0 | Sectors about to fail |
| Uncorrectable errors | 187 | 0 | Replace immediately |
| Drive temperature | 194 | < 45°C | Improve airflow if consistently high |
| Power-on hours | 9 | < 50,000h | Track age — most drives rated for 5 years |

ZFS protects data from bit-rot but cannot protect against a drive that physically fails completely. SMART monitoring via Scrutiny is the early warning system for that failure mode.

### Container Health (cAdvisor)

| Metric | What to Watch For |
|---|---|
| Container RAM usage | Gradual memory leaks (usage growing over days) |
| Container restarts | Any container restarting frequently — it's crashing |
| Container CPU usage | One container hogging all CPU |
| Container status | Container stopped unexpectedly |

### Service Availability (Uptime Kuma)

| Monitor | Type | URL/Target | Alert if Down > |
|---|---|---|---|
| Nextcloud | HTTP keyword | `https://cloud.example.com` | 2 minutes |
| Jellyfin | HTTP | `https://media.example.com` | 5 minutes |
| Vaultwarden | HTTP | `https://vault.example.com` | 2 minutes |
| TrueNAS UI | HTTP | `https://truenas:443` | 2 minutes |
| Proxmox UI | HTTP | `https://proxmox:8006` | 5 minutes |
| Pi-hole DNS | DNS | Query `pi.hole` on `192.168.1.20` | 1 minute |
| Traefik | TCP | `192.168.1.20:443` | 1 minute |
| Scrutiny (disk health) | HTTP keyword | `http://scrutiny:8080/api/summary` | Immediate |

## Current Deployment

### Directory Structure

```
configs/docker/monitoring/
+-- docker-compose.yml
+-- prometheus/
|   +-- prometheus.yml
+-- alertmanager/
|   +-- alertmanager.yml
+-- grafana/
    +-- provisioning/
        +-- datasources/
        |   +-- prometheus.yml
        +-- dashboards/
            +-- dashboards.yml
```

### Docker Compose

```yaml
# configs/docker/monitoring/docker-compose.yml

services:

  prometheus:
    image: prom/prometheus:v2.51.0
    restart: unless-stopped
    user: "1000:1000"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.retention.time=30d"
      - "--storage.tsdb.path=/prometheus"
      - "--web.enable-lifecycle"
    networks:
      - monitoring
    labels:
      - "traefik.enable=false"

  grafana:
    image: grafana/grafana:10.4.0
    restart: unless-stopped
    user: "1000:1000"
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_PASSWORD}
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_SERVER_DOMAIN: monitor.example.com
      GF_SERVER_ROOT_URL: https://monitor.example.com
      GF_SMTP_ENABLED: "true"
      GF_SMTP_HOST: ${SMTP_HOST}
      GF_SMTP_USER: ${SMTP_USER}
      GF_SMTP_PASSWORD: ${SMTP_PASSWORD}
      GF_SMTP_FROM_ADDRESS: grafana@example.com
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    networks:
      - monitoring
      - frontend
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.grafana.rule=Host(`monitor.example.com`)"
      - "traefik.http.routers.grafana.middlewares=authelia@docker"

  node-exporter:
    image: prom/node-exporter:v1.8.0
    restart: unless-stopped
    pid: host
    network_mode: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - "--path.procfs=/host/proc"
      - "--path.sysfs=/host/sys"
      - "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)"

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    restart: unless-stopped
    privileged: true
    devices:
      - /dev/kmsg
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    networks:
      - monitoring

  alertmanager:
    image: prom/alertmanager:v0.27.0
    restart: unless-stopped
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - alertmanager_data:/alertmanager
    command:
      - "--config.file=/etc/alertmanager/alertmanager.yml"
      - "--storage.path=/alertmanager"
    networks:
      - monitoring

  scrutiny:
    image: ghcr.io/analogj/scrutiny:master-web
    restart: unless-stopped
    volumes:
      - scrutiny_data:/opt/scrutiny/config
      - scrutiny_influx:/opt/scrutiny/influxdb
    networks:
      - monitoring

  scrutiny-collector:
    image: ghcr.io/analogj/scrutiny:master-collector
    restart: unless-stopped
    privileged: true
    volumes:
      - /run/udev:/run/udev:ro
    environment:
      COLLECTOR_API_ENDPOINT: http://scrutiny:8080
    network_mode: host

  uptime-kuma:
    image: louislam/uptime-kuma:1
    restart: unless-stopped
    volumes:
      - uptime_kuma_data:/app/data
    networks:
      - monitoring
      - frontend
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.uptime.rule=Host(`status.example.com`)"
      - "traefik.http.routers.uptime.middlewares=authelia@docker"

networks:
  monitoring:
    internal: true
  frontend:
    external: true

volumes:
  prometheus_data:
  grafana_data:
  alertmanager_data:
  scrutiny_data:
  scrutiny_influx:
  uptime_kuma_data:
```

### Prometheus Configuration

```yaml
# configs/docker/monitoring/prometheus/prometheus.yml

global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]

rule_files:
  - "/etc/prometheus/rules/*.yml"

scrape_configs:

  - job_name: "truenas"
    static_configs:
      - targets: ["192.168.1.10:9100"]
        labels:
          instance: "truenas"

  - job_name: "proxmox"
    static_configs:
      - targets: ["192.168.1.2:9100"]
        labels:
          instance: "proxmox"

  - job_name: "cadvisor"
    static_configs:
      - targets: ["cadvisor:8080"]

  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "traefik"
    static_configs:
      - targets: ["traefik:8082"]
```

### Alert Rules

```yaml
# configs/docker/monitoring/prometheus/rules/alerts.yml

groups:
  - name: system_alerts
    rules:

      - alert: DiskSpaceWarning
        expr: (node_filesystem_avail_bytes / node_filesystem_size_bytes) * 100 < 20
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Disk space low on {{ $labels.instance }}"
          description: >
            {{ $labels.mountpoint }} has less than 20% free space.
            Available: {{ $value | humanize }}%.

      - alert: DiskSpaceCritical
        expr: (node_filesystem_avail_bytes / node_filesystem_size_bytes) * 100 < 10
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "CRITICAL: Disk almost full on {{ $labels.instance }}"
          description: "Less than 10% free on {{ $labels.mountpoint }}. Services may crash."

      - alert: HighMemoryUsage
        expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100 > 90
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage on {{ $labels.instance }}"
          description: "RAM usage above 90% for 10 minutes."

      - alert: HighCPUUsage
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "High CPU on {{ $labels.instance }}"
          description: "CPU above 85% for 15 minutes. May indicate runaway process."

      - alert: InstanceDown
        expr: up == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }} is DOWN"
          description: "No metrics received for 2 minutes. Server may be offline."

      - alert: ContainerRestarting
        expr: rate(container_last_seen{name!=""}[5m]) > 0 and delta(container_start_time_seconds{name!=""}[1h]) > 2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Container {{ $labels.name }} keeps restarting"
          description: "Container has restarted more than twice in the last hour."
```

### Alertmanager — Notification Routing

The deployed baseline deliberately uses a receiver with no external integration, keeping alerts visible in Alertmanager while avoiding placeholder credentials that would stop the container at startup:

```yaml
# configs/docker/monitoring/alertmanager/alertmanager.yml
route:
  receiver: local-only
  group_by: ["alertname", "instance"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: local-only
```

Compose interpolation (`${VAR}`) applies to `docker-compose.yml` only, not to arbitrary bind-mounted configuration files like this one — a placeholder such as `${DISCORD_WEBHOOK_URL}` written directly into `alertmanager.yml` will not be substituted. The repo also contains `alertmanager-discord.example.yml`, which uses Alertmanager's native Discord receiver. Notification setup and validation steps are in `docs/setup-and-testing/monitoring-and-updates.md`.

### Grafana Provisioning

Grafana is provisioned on startup rather than configured by hand, so it reconnects to Prometheus and reloads dashboards automatically on every redeploy:

```yaml
# configs/docker/monitoring/grafana/provisioning/datasources/prometheus.yml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    url: http://prometheus:9090
    access: proxy
    isDefault: true
    editable: false
```

```yaml
# configs/docker/monitoring/grafana/provisioning/dashboards/dashboards.yml
apiVersion: 1
providers:
  - name: "default"
    folder: "Home Server"
    type: file
    options:
      path: /etc/grafana/provisioning/dashboards/json
      foldersFromFilesStructure: true
```

Dashboards exported as JSON (`Dashboard → Share → Export → Save to file`) are stored under `configs/docker/monitoring/grafana/provisioning/dashboards/json/`, so they come back automatically on redeploy.

## Pre-Built Grafana Dashboards

The Grafana community dashboards used in this stack (imported via Grafana → Dashboards → Import → Enter ID):

| Dashboard | ID | What It Shows |
|---|---|---|
| Node Exporter Full | `1860` | Complete server stats — CPU, RAM, disk, network, temps |
| Docker & cAdvisor | `893` | Per-container resource usage |
| Traefik 2.x | `17346` | HTTP requests, response times, error rates per service |
| Proxmox via Node Exporter | `10347` | Proxmox-specific metrics overlay |

After importing dashboard 1860, the Instance dropdown at the top switches between TrueNAS, Proxmox, and any other server added later.

## Alert Fatigue

"Alert fatigue" is when too many notifications cause even the important ones to get ignored. The stack is tuned to alert only on things that actually need attention.

### Alerted

- Service is completely down
- Disk over 85% full
- Drive SMART failure or pending sectors
- Container restarting repeatedly
- RAM over 90% for sustained time
- Unexpected server reboot

### Not Alerted

- CPU briefly spiked to 80% (happens during backups, transcoding — normal)
- Network traffic spike (might just be a large file download)
- Container used 10% more RAM than usual
- Disk I/O spike at 3 AM (scheduled backup running)

The baseline favors fewer, higher-confidence alerts, with more added as the normal baseline becomes known.
