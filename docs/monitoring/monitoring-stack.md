# 📊 Monitoring Stack

> **Sources:** Grafana Labs official docs, Prometheus docs, linuxserver.io community guides,
> and home server best practices (2025).

---

## What Is Monitoring and Why Does It Matter?

> **For beginners:** Monitoring is like having a dashboard on your car — it tells you
> how fast you're going, how much fuel you have, and if anything is about to break.
> Without it, you're driving blind. Your server could be running out of disk space,
> have a failing hard drive, or be getting hammered by an attacker — and you'd have
> no idea until something actually breaks.

The goal of monitoring is to **know about problems before they become disasters**:
- A hard drive starts failing → you get an alert → you replace it before you lose data
- Disk fills up → you get an alert → you clean it before Nextcloud crashes
- Someone is brute-forcing your login → CrowdSec blocks them + you see it in Grafana
- Server went offline → you get a notification on your phone within minutes

---

## The Monitoring Stack

This setup uses **4 specialized tools**, each doing one job well:

```
┌─────────────────────────────────────────────────────────────────┐
│                    MONITORING OVERVIEW                          │
│                                                                 │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │ Node        │  │ cAdvisor     │  │ Scrutiny             │   │
│  │ Exporter    │  │              │  │                      │   │
│  │             │  │ "What are    │  │ "How healthy are     │   │
│  │ "How is the │  │  my Docker   │  │  my hard drives?"    │   │
│  │  server     │  │  containers  │  │                      │   │
│  │  itself     │  │  doing?"     │  │  SMART monitoring    │   │
│  │  doing?"    │  │              │  │  + history           │   │
│  └──────┬──────┘  └──────┬───────┘  └──────────┬───────────┘   │
│         │                │                      │               │
│         └────────────────┼──────────────────────┘               │
│                          │ all metrics flow here                 │
│                          ▼                                       │
│                  ┌───────────────┐                              │
│                  │  Prometheus   │                              │
│                  │               │                              │
│                  │ "The database │                              │
│                  │  that stores  │                              │
│                  │  all metrics" │                              │
│                  └───────┬───────┘                              │
│                          │                                       │
│              ┌───────────┼───────────┐                          │
│              │           │           │                          │
│              ▼           ▼           ▼                          │
│         ┌─────────┐ ┌─────────┐ ┌──────────────┐               │
│         │ Grafana │ │ Uptime  │ │ Alertmanager │               │
│         │         │ │ Kuma    │ │              │               │
│         │ "Pretty │ │         │ │ "Sends you   │               │
│         │  charts │ │ "Are my │ │  alerts when │               │
│         │  and    │ │  services│ │  things go   │               │
│         │  graphs"│ │  UP?"   │ │  wrong"      │               │
│         └─────────┘ └─────────┘ └──────────────┘               │
└─────────────────────────────────────────────────────────────────┘
```

---

## Tool Explanations

### 🔵 Prometheus — The Metric Database

> **What it is:** Prometheus is a time-series database. That means it records numbers
> over time — like "CPU was at 12% at 3:00PM, 45% at 3:01PM, 8% at 3:02PM."
>
> **Why you need it:** Grafana needs somewhere to get its data from. Prometheus is that
> source. It regularly goes and "scrapes" (fetches) numbers from all your other tools
> and stores them. On its own, it's invisible — it just sits in the background collecting.
>
> **Analogy:** Prometheus is the flight recorder (black box) of your server. It silently
> records everything, and you use other tools to actually read and display the data.

### 🟠 Grafana — The Dashboard

> **What it is:** Grafana takes the numbers stored in Prometheus and turns them into
> visual charts, graphs, and dashboards — the kind you see on IT operations rooms
> in movies with big screens full of live stats.
>
> **Why you need it:** Raw numbers in a database are useless to a human. Grafana makes
> them meaningful. You can see at a glance that your RAM has been climbing for 3 days,
> or that your disk I/O spiked at 2AM (maybe a backup ran).
>
> **Analogy:** If Prometheus is the flight recorder, Grafana is the cockpit instrument
> panel — it makes all those recorded numbers readable and visual.

### 🟡 Node Exporter — The Server Health Reporter

> **What it is:** A small program that runs on your server (TrueNAS or Proxmox) and
> constantly measures things like CPU usage, RAM usage, disk space, network traffic,
> and system temperature. It then makes these numbers available for Prometheus to collect.
>
> **Why you need it:** Without Node Exporter, Prometheus has nothing to collect.
> It's the "sensor" that measures your server's vital signs.
>
> **Analogy:** It's like a fitness tracker on your wrist — it measures your heart rate,
> steps, and temperature so that your phone (Grafana) can display it nicely.

### 🐋 cAdvisor — The Container Inspector

> **What it is:** cAdvisor (Container Advisor) is like Node Exporter but specifically
> for Docker containers. It tells you how much CPU, RAM, and network each individual
> container is using.
>
> **Why you need it:** Without cAdvisor, you can see "the server is using 60% RAM" but
> not *which* container is eating it. With cAdvisor, you can see "Jellyfin is using 2GB,
> Nextcloud is using 512MB, MariaDB is using 300MB."
>
> **Analogy:** If Node Exporter monitors the whole house's electricity usage, cAdvisor
> monitors each individual room/appliance.

### 🔴 Scrutiny — The Disk Health Monitor

> **What it is:** Scrutiny monitors the S.M.A.R.T. data from your hard drives.
> S.M.A.R.T. (Self-Monitoring, Analysis and Reporting Technology) is a system built into
> every hard drive that tracks signs of wear and failure — things like "how many bad
> sectors does this drive have?" or "how hot is it running?"
>
> **Why you need it:** Hard drives fail. They always give warning signs before they die,
> but those signs are buried in technical data that's hard to read. Scrutiny reads that
> data, stores it over time, and warns you when something looks bad — ideally before
> you lose data.
>
> **Analogy:** It's like a car mechanic who regularly inspects your tyres and tells you
> "this one is getting worn — replace it soon" before you get a blowout on the motorway.

### 🟢 Uptime Kuma — The "Is It Up?" Monitor

> **What it is:** Uptime Kuma checks whether your services are actually reachable and
> responding. It pings your URLs every minute and if something stops responding, it sends
> you a notification immediately — on your phone, via email, Discord, Telegram, etc.
>
> **Why you need it:** Prometheus and Grafana tell you about performance. Uptime Kuma
> tells you about availability. "Is Nextcloud actually loading right now?" If Traefik
> crashes, Prometheus might still show the server is fine (it is!) but Uptime Kuma
> will catch that the web service is down.
>
> **Analogy:** It's the equivalent of a friend who regularly checks your front door
> is still open and texts you if it isn't.

### 🔔 Alertmanager — The Notification Router

> **What it is:** Alertmanager works alongside Prometheus. When Prometheus detects that
> a metric crosses a threshold (e.g., "disk is over 90% full"), it tells Alertmanager,
> which then sends the notification to wherever you've configured — email, Discord,
> Telegram, or a webhook.
>
> **Why you need it:** Without Alertmanager, you'd have to sit and watch your Grafana
> dashboards all day. With it, you're notified automatically when something needs attention.
>
> **Analogy:** It's the alarm system. Grafana shows you the cameras — Alertmanager calls
> the police when something triggers.

---

## What to Monitor

### System Health (Node Exporter)

| Metric | Warning Threshold | Critical Threshold | Why It Matters |
|---|---|---|---|
| **CPU usage** | > 80% for 10 min | > 95% for 5 min | Sustained high CPU = something's wrong or overloaded |
| **RAM usage** | > 85% | > 95% | Low RAM causes slowdowns and OOM kills |
| **Disk space** | > 80% full | > 90% full | Full disk = services crash (databases especially) |
| **Disk I/O** | Unusual spikes | — | Could indicate failing drive or runaway process |
| **Load average** | > 4.0 (1min) | > 8.0 (1min) | Shows if the server is overwhelmed with tasks |
| **Network traffic** | Unusual spike | — | Could indicate data exfiltration or DDoS |
| **System uptime** | — | Unexpected reboot | Reboots without you doing them = problem |

### Hard Drive Health (Scrutiny + SMART)

| Attribute | ID | Healthy | Action if Not |
|---|---|---|---|
| **Overall SMART status** | — | PASSED | 🔴 Replace drive immediately |
| **Reallocated sectors** | 5 | 0 | ⚠️ Drive is remapping bad sectors — plan replacement |
| **Pending sectors** | 197 | 0 | ⚠️ Sectors about to fail |
| **Uncorrectable errors** | 187 | 0 | 🔴 Replace immediately |
| **Drive temperature** | 194 | < 45°C | Improve airflow if consistently high |
| **Power-on hours** | 9 | < 50,000h | Track age — most drives rated for 5 years |

> [!IMPORTANT]
> ZFS protects your data from bit-rot, but it cannot protect you from a drive that
> physically fails completely. SMART monitoring + Scrutiny is your early warning system.
> A drive showing increasing reallocated sectors needs to be replaced before ZFS has
> to deal with actual data loss on that drive.

### Container Health (cAdvisor)

| Metric | What to Watch For |
|---|---|
| Container RAM usage | Gradual memory leaks (usage growing over days) |
| Container restarts | Any container restarting frequently = it's crashing |
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

---

## Deployment

### Directory Structure

```
configs/docker/monitoring/
├── docker-compose.yml
├── prometheus/
│   └── prometheus.yml
├── alertmanager/
│   └── alertmanager.yml
└── grafana/
    └── provisioning/
        ├── datasources/
        │   └── prometheus.yml
        └── dashboards/
            └── dashboards.yml
```

### Docker Compose

```yaml
# configs/docker/monitoring/docker-compose.yml

services:

  # ── Prometheus ─────────────────────────────────────────────────
  # The metric database. Scrapes numbers from all exporters.
  prometheus:
    image: prom/prometheus:v2.51.0
    restart: unless-stopped
    user: "1000:1000"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.retention.time=30d"   # Keep 30 days of history
      - "--storage.tsdb.path=/prometheus"
      - "--web.enable-lifecycle"
    networks:
      - monitoring
    labels:
      - "traefik.enable=false"   # Internal only — not exposed externally

  # ── Grafana ─────────────────────────────────────────────────────
  # The visual dashboard. Reads from Prometheus and draws charts.
  grafana:
    image: grafana/grafana:10.4.0
    restart: unless-stopped
    user: "1000:1000"
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_PASSWORD}   # Set in .env
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
      - frontend   # Needs to be reachable via Traefik
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.grafana.rule=Host(`monitor.example.com`)"
      - "traefik.http.routers.grafana.middlewares=authelia@docker"

  # ── Node Exporter ────────────────────────────────────────────────
  # Measures server health: CPU, RAM, disk, network. One per server.
  node-exporter:
    image: prom/node-exporter:v1.8.0
    restart: unless-stopped
    pid: host          # Needs host PID namespace to see all processes
    network_mode: host # Needs host network to see all interfaces
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - "--path.procfs=/host/proc"
      - "--path.sysfs=/host/sys"
      - "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)"

  # ── cAdvisor ────────────────────────────────────────────────────
  # Measures per-container resource usage. Tells you which container
  # is eating your RAM or CPU.
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

  # ── Alertmanager ────────────────────────────────────────────────
  # Routes alerts from Prometheus to your phone/email when
  # something crosses a threshold.
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

  # ── Scrutiny ────────────────────────────────────────────────────
  # Monitors hard drive SMART health. Warns you before drives fail.
  # Hub: collects data. Collector: runs on each machine with drives.
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
    privileged: true   # Needs access to disk devices
    volumes:
      - /run/udev:/run/udev:ro
    environment:
      COLLECTOR_API_ENDPOINT: http://scrutiny:8080
    network_mode: host

  # ── Uptime Kuma ─────────────────────────────────────────────────
  # Checks if your services are actually reachable.
  # Sends alerts to your phone/Discord if a service goes down.
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
    internal: true    # Monitoring stack — no direct internet access
  frontend:
    external: true    # Shared with Traefik

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
  scrape_interval: 15s        # Collect metrics every 15 seconds
  evaluation_interval: 15s    # Evaluate alert rules every 15 seconds

# Tell Alertmanager about new alerts
alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]

# Load alert rule files
rule_files:
  - "/etc/prometheus/rules/*.yml"

# Where to collect metrics from
scrape_configs:

  # TrueNAS server health (CPU, RAM, disk, network)
  - job_name: "truenas"
    static_configs:
      - targets: ["192.168.1.10:9100"]  # Node Exporter on TrueNAS
        labels:
          instance: "truenas"

  # Proxmox host health
  - job_name: "proxmox"
    static_configs:
      - targets: ["192.168.1.2:9100"]    # Node Exporter on Proxmox
        labels:
          instance: "proxmox"

  # Docker container stats
  - job_name: "cadvisor"
    static_configs:
      - targets: ["cadvisor:8080"]

  # Prometheus itself (meta-monitoring)
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  # Traefik metrics
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

      # Disk space — warns before things start crashing
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
            ACTION: Check what's taking space (logs, media, backups).

      - alert: DiskSpaceCritical
        expr: (node_filesystem_avail_bytes / node_filesystem_size_bytes) * 100 < 10
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "🔴 CRITICAL: Disk almost full on {{ $labels.instance }}"
          description: "Less than 10% free on {{ $labels.mountpoint }}. Services may crash."

      # RAM — high usage for sustained period
      - alert: HighMemoryUsage
        expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100 > 90
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage on {{ $labels.instance }}"
          description: "RAM usage above 90% for 10 minutes. Check cAdvisor for which container."

      # CPU — not a problem unless sustained
      - alert: HighCPUUsage
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "High CPU on {{ $labels.instance }}"
          description: "CPU above 85% for 15 minutes. May indicate runaway process."

      # Server went offline
      - alert: InstanceDown
        expr: up == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "🔴 {{ $labels.instance }} is DOWN"
          description: "No metrics received for 2 minutes. Server may be offline."

      # Container restarting unexpectedly
      - alert: ContainerRestarting
        expr: rate(container_last_seen{name!=""}[5m]) > 0 and delta(container_start_time_seconds{name!=""}[1h]) > 2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Container {{ $labels.name }} keeps restarting"
          description: "Container has restarted more than twice in the last hour. Check logs."
```

### Alertmanager — Notification Routing

The deployable baseline deliberately uses a receiver with no external
integration. This keeps alerts visible in Alertmanager and prevents placeholder
credentials from stopping the container at startup:

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

Do not use `${DISCORD_WEBHOOK_URL}` directly in this bind-mounted YAML file;
Compose interpolation applies to `docker-compose.yml`, not arbitrary mounted
configuration files. For notification setup and validation, follow
[Monitoring And Updates Start Here](monitoring-and-updates-start-here.md). The
repo also contains `alertmanager-discord.example.yml`, which uses Alertmanager's
native Discord receiver.

---

## Pre-Built Grafana Dashboards

> **Don't build dashboards from scratch.** The Grafana community has already made
> excellent ones. Import these by going to:
> **Grafana → Dashboards → Import → Enter ID**

| Dashboard | ID | What It Shows |
|---|---|---|
| **Node Exporter Full** | `1860` | Complete server stats — CPU, RAM, disk, network, temps |
| **Docker & cAdvisor** | `893` | Per-container resource usage — which app is eating your RAM |
| **Traefik 2.x** | `17346` | HTTP requests, response times, error rates per service |
| **Proxmox via Node Exporter** | `10347` | Proxmox-specific metrics overlay |

> [!TIP]
> After importing dashboard 1860, use the **Instance** dropdown at the top of the
> dashboard to switch between TrueNAS, Proxmox, and any other server you add.

---

## Uptime Kuma Setup Guide

Uptime Kuma has no config files — everything is done through its web UI.

```
Access at: https://status.example.com (or http://192.168.1.20:3001 internally)
First login: Create your admin account on first run
```

### Monitors to Create

For each service, click **Add New Monitor**:

| Service | Type | URL | Heartbeat Interval | Alert After |
|---|---|---|---|---|
| Nextcloud | HTTPS | `https://cloud.example.com` | 60s | 2 failures |
| Jellyfin | HTTPS | `https://media.example.com` | 60s | 3 failures |
| Vaultwarden | HTTPS | `https://vault.example.com` | 60s | 2 failures |
| Homepage | HTTPS | `https://dash.example.com` | 120s | 3 failures |
| Grafana | HTTPS | `https://monitor.example.com` | 120s | 3 failures |
| Pi-hole | HTTP | `http://192.168.1.20:80/admin` | 60s | 2 failures |
| Disk health | HTTP Keyword | `http://scrutiny:8080/api/summary` | 300s | 1 failure |

**Disk health monitor keyword setup:**
- Keyword: `"device_status":2`
- Invert keyword: ✅ Yes
- (This means: alert if the word IS found, which means a drive has a problem)

### Notification Channels

```
Uptime Kuma → Settings → Notifications → Add Notification

Discord:
  Type: Discord
  Webhook URL: [your Discord webhook URL]

Telegram (optional — great for phone alerts):
  Type: Telegram
  Bot Token: [create bot via @BotFather]
  Chat ID: [your chat ID]
```

---

## Grafana Provisioning (Auto-Configure on Startup)

Instead of clicking through the UI every time you redeploy, use provisioning files
so Grafana automatically connects to Prometheus and loads dashboards on startup.

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

> [!TIP]
> Once you've set up your dashboards the way you like them, export them as JSON
> (`Dashboard → Share → Export → Save to file`) and store them in
> `configs/docker/monitoring/grafana/provisioning/dashboards/json/`. Next time
> you deploy, your dashboards come back automatically.

---

## Alert Fatigue Warning

> **For beginners:** "Alert fatigue" is when you receive so many notifications that
> you start ignoring them all — including the important ones. The trick is to only
> alert on things that actually need your attention, not every little fluctuation.

### Good Alerts (Alert on these)
- ✅ Service is completely down
- ✅ Disk over 85% full
- ✅ Drive SMART failure or pending sectors
- ✅ Container restarting repeatedly
- ✅ RAM over 90% for sustained time
- ✅ Unexpected server reboot

### Bad Alerts (Don't alert on these)
- ❌ CPU briefly spiked to 80% (happens during backups, transcoding — normal)
- ❌ Network traffic spike (might just be a large file download)
- ❌ Container used 10% more RAM than usual
- ❌ Disk I/O spike at 3AM (that's your scheduled backup running)

**Start with fewer, higher-confidence alerts. Add more as you learn your baseline.**

---

## Implementation Checklist

| # | Task | Status |
|---|---|---|
| 1 | Deploy monitoring stack (Prometheus + Grafana + exporters) | ⬜ TODO |
| 2 | Install Node Exporter on TrueNAS | ⬜ TODO |
| 3 | Install Node Exporter on Proxmox host | ⬜ TODO |
| 4 | Configure Prometheus scrape targets | ⬜ TODO |
| 5 | Import Grafana dashboards (1860, 893, 17346) | ⬜ TODO |
| 6 | Set Grafana admin password (change from default) | ⬜ TODO |
| 7 | Configure provisioning files (auto datasource + dashboards) | ⬜ TODO |
| 8 | Deploy Scrutiny for SMART disk monitoring | ⬜ TODO |
| 9 | Deploy Uptime Kuma and add all service monitors | ⬜ TODO |
| 10 | Set up Discord / Telegram notification channel in Uptime Kuma | ⬜ TODO |
| 11 | Configure Alertmanager with Discord webhook | ⬜ TODO |
| 12 | Configure email alerts for critical severity | ⬜ TODO |
| 13 | Create alert rules (disk, RAM, CPU, instance down) | ⬜ TODO |
| 14 | Test alerts by intentionally triggering one | ⬜ TODO |
| 15 | Export and save dashboard JSON files to configs/ | ⬜ TODO |
| 16 | Put monitoring behind Authelia (Grafana + Uptime Kuma) | ⬜ TODO |
