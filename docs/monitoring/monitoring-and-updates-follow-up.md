# Monitoring And Updates Follow-Up

Last updated: 2026-06-20

Use this guide only after completing
[Monitoring And Updates Start Here](monitoring-and-updates-start-here.md).
It continues from the already-deployed stack and does not recreate containers,
volumes, dashboards, or configuration files.

## Confirmed Starting Point

Your Alertmanager repair succeeded when this guide was written:

```text
amtool check-config: SUCCESS
Alertmanager container: Up
Configuration loaded: Completed loading of configuration file
Listener: port 9093
External receiver: local-only
```

`TLS is disabled` in the Alertmanager log is expected because it is currently
accessed only through the LAN-bound Docker port. Do not expose port `9093` to the
internet.

The `local-only` receiver means alerts reach Alertmanager but do not yet produce
Discord, email, or phone notifications.

## Rules For This Follow-Up

1. Run shell commands on the Ubuntu Docker VM unless stated otherwise.
2. Keep Watchtower in monitor-only mode.
3. Change and verify one stack at a time.
4. Never use `docker compose down -v` during maintenance or rollback.
5. Confirm backups before updating stateful services.
6. Keep Grafana, Prometheus, Alertmanager, and Uptime Kuma LAN/Tailscale-only.

## Step 1: Record The Current Healthy State

Run:

```bash
cd /opt/stacks/monitoring

docker compose config --quiet
docker compose ps
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
```

Expected monitoring containers:

```text
prometheus
grafana
node-exporter
cadvisor
alertmanager
uptime-kuma
```

The exact list can include additional exporters. Every required container should
show `Up`; allow health checks one or two minutes to change to `healthy`.

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

These files record the previous image tags and IDs. They are useful during
rollback but are not backups of databases or application data.

## Step 2: Verify Every Monitoring Layer

### 2.1 Check HTTP Health

```bash
curl -fsS http://192.168.1.20:3000/api/health
curl -fsS http://192.168.1.20:9090/-/ready
curl -fsS http://192.168.1.20:9093/-/ready
curl -fsS http://192.168.1.20:3001/ >/dev/null
echo "Monitoring HTTP checks passed"
```

If a check fails:

```bash
cd /opt/stacks/monitoring
docker compose ps
docker compose logs --tail 100 SERVICE_NAME
sudo ss -lntp | grep -E ':3000|:3001|:9090|:9093' || true
```

### 2.2 Check Prometheus Targets

Open:

```text
http://192.168.1.20:9090/targets
```

At minimum, confirm the Prometheus, Docker VM node-exporter, and cAdvisor jobs are
`UP`. A deliberately deferred Proxmox or TrueNAS exporter may be `DOWN`, but it
must be documented rather than ignored.

CLI view when `jq` is installed:

```bash
curl -fsS http://192.168.1.20:9090/api/v1/targets | \
  jq -r '.data.activeTargets[] |
    [.labels.job, .scrapeUrl, .health, (.lastError // "")] | @tsv'
```

### 2.3 Check Prometheus Configuration And Rules

```bash
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
docker exec prometheus promtool check rules /etc/prometheus/rules/alerts.yml
```

Both commands must report `SUCCESS` before continuing.

## Step 3: Test The Prometheus To Alertmanager Path

This creates a temporary alert that is always active. It tests Prometheus rule
loading and Alertmanager delivery without stopping a real service.

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

Wait one minute, then open both pages:

```text
http://192.168.1.20:9090/alerts
http://192.168.1.20:9093/#/alerts
```

`FollowUpPipelineTest` should be firing in both places. Remove it immediately
after confirming:

```bash
rm prometheus/rules/follow-up-test.yml
docker compose kill -s HUP prometheus
```

Wait another minute. The alert should disappear or show as resolved. If it is in
Prometheus but not Alertmanager, check:

```bash
docker compose logs --tail 100 prometheus
docker compose logs --tail 100 alertmanager
docker exec prometheus wget -qO- http://alertmanager:9093/-/ready
```

## Step 4: Configure Uptime Kuma For Actionable Notifications

Open:

```text
http://192.168.1.20:3001
```

Create monitors for the services that currently exist. Use an HTTP monitor for
web applications and a ping or TCP monitor only when no useful HTTP endpoint is
available.

| Monitor | Type | Target |
|---|---|---|
| Grafana | HTTP | `http://192.168.1.20:3000/api/health` |
| Prometheus | HTTP | `http://192.168.1.20:9090/-/ready` |
| Alertmanager | HTTP | `http://192.168.1.20:9093/-/ready` |
| Docker VM | Ping | `192.168.1.20` |
| Proxmox | Ping | Use the actual Proxmox IP from your network reference. |
| TrueNAS | Ping | `192.168.1.10` if that remains its actual address. |
| ARR/media apps | HTTP | Use each application's current LAN URL and port. |

Recommended settings:

```text
Heartbeat interval: 60 seconds
Retries: 3
Retry interval: 30 seconds
Certificate expiry notification: enabled for HTTPS monitors
```

In Uptime Kuma, go to `Settings -> Notifications` and add one notification
provider. Discord or Telegram is the simplest first path. Use `Test` and confirm
the message arrives before assigning it to every monitor.

Then create a short controlled failure:

```bash
cd /opt/stacks/monitoring
docker compose stop grafana
```

Confirm Uptime Kuma reports Grafana down and sends a notification. Restore it:

```bash
docker compose start grafana
docker compose ps grafana
curl -fsS http://192.168.1.20:3000/api/health
```

Confirm the recovery notification arrives. Do not stop Alertmanager for this test;
it has only just been repaired.

## Step 5: Verify Grafana Is Useful

Open:

```text
http://192.168.1.20:3000
```

Go to `Connections -> Data sources -> Prometheus -> Save & test`. It should use:

```text
http://prometheus:9090
```

### 5.1 Open Explore Correctly

1. Select `Explore` from Grafana's left menu.
2. Select the `Prometheus` data source at the top of the page.
3. Set the time range to `Last 15 minutes`.
4. In query row `A`, select `Code` instead of `Builder` if Grafana offers both.
5. Paste only one PromQL query at a time.
6. Select `Run query` in the upper-right corner.
7. Use `Table` view when inspecting labels and `Time series` for CPU, memory, and
   disk graphs.

Do not paste all four queries into one query box. To compare queries on one graph,
use `Add query` and place each expression in its own row (`A`, `B`, and so on).

### 5.2 Check Which Targets Exist

Start with:

```promql
up
```

This metric exists for every Prometheus scrape target. Switch to `Table` view and
expand a result to see its labels.

Important labels:

| Label | Meaning | Values expected from the guide |
|---|---|---|
| `job` | Scrape configuration that produced the metric | `prometheus`, `docker-vm`, `cadvisor`, optionally `proxmox` |
| `instance` | Friendly target name configured in Prometheus | `prometheus`, `docker-vm`, `docker-containers`, optionally `proxmox` |

The sample value means:

```text
1 = Prometheus can currently scrape that target.
0 = The target exists in the configuration but the scrape is failing.
```

Focus on the Docker VM node-exporter:

```promql
up{job="docker-vm"}
```

Expected result:

```text
{instance="docker-vm", job="docker-vm"} 1
```

If you deployed the files from `configs/docker/monitoring/` instead of manually
following the original guide, the job may be named `node-exporter`. Discover it
with `up` and use the actual value rather than renaming it merely to satisfy a
dashboard.

### 5.3 Confirm Node-Exporter Metrics Exist

Run:

```promql
node_uname_info
```

This should return one series for each working node-exporter target, including
labels such as `job`, `instance`, `nodename`, `release`, and `sysname`.

Limit it to the Docker VM:

```promql
node_uname_info{job="docker-vm"}
```

If `up{job="docker-vm"}` is `1` but `node_uname_info` is empty, check that the
target on the Prometheus Targets page really points to node-exporter port `9100`
and is not another exporter with the wrong job name.

### 5.4 Docker VM CPU Usage

Run:

```promql
100 - (
  avg by (instance) (
    rate(node_cpu_seconds_total{job="docker-vm", mode="idle"}[5m])
  ) * 100
)
```

What it does:

1. `node_cpu_seconds_total{mode="idle"}` selects idle CPU time.
2. `rate(...[5m])` calculates the per-second idle fraction over five minutes.
3. `avg by (instance)` averages all CPU cores for each host.
4. Subtracting from `100` converts idle percentage into used percentage.

The result should be one value from approximately `0` to `100` for
`instance="docker-vm"`. A short spike is normal; investigate sustained high usage
together with load, container CPU, and the workload running at that time.

The query needs at least several minutes of collected samples. Immediately after
starting Prometheus or node-exporter, wait five minutes and run it again.

To include all node-exporter hosts, remove `job="docker-vm"`:

```promql
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

### 5.5 Docker VM Memory Usage

Run:

```promql
100 * (
  1 -
  node_memory_MemAvailable_bytes{job="docker-vm"} /
  node_memory_MemTotal_bytes{job="docker-vm"}
)
```

This uses `MemAvailable`, not just unused memory. Linux intentionally uses free
RAM for cache, so `MemFree` would make healthy systems look unnecessarily full.

Expected result: one percentage for `instance="docker-vm"`. Use the Table view to
confirm the instance label, then switch to Time series to see whether usage is
sustained or only temporary.

Inspect the underlying byte values if the percentage looks wrong:

```promql
node_memory_MemTotal_bytes{job="docker-vm"}
```

```promql
node_memory_MemAvailable_bytes{job="docker-vm"}
```

### 5.6 Filesystem Usage Per Mount Point

Run:

```promql
100 * (
  1 -
  node_filesystem_avail_bytes{job="docker-vm", fstype!~"tmpfs|overlay"} /
  node_filesystem_size_bytes{job="docker-vm", fstype!~"tmpfs|overlay"}
)
```

This returns multiple series because filesystems are separate. In Table view,
inspect these labels:

| Label | Meaning |
|---|---|
| `mountpoint` | Where the filesystem is mounted, such as `/`, `/mnt/main`, or `/mnt/media` |
| `device` | Backing block device or NFS export |
| `fstype` | Filesystem type, such as `ext4` or `nfs4` |
| `instance` | Host reporting the filesystem |

To see only the Docker VM root filesystem:

```promql
100 * (
  1 -
  node_filesystem_avail_bytes{job="docker-vm", mountpoint="/"} /
  node_filesystem_size_bytes{job="docker-vm", mountpoint="/"}
)
```

To confirm which mount-point labels are actually available, run this in Table
view:

```promql
node_filesystem_size_bytes{job="docker-vm", fstype!~"tmpfs|overlay"}
```

Do not assume NFS data is present merely because `/mnt/main` appears. Compare the
Grafana result with `findmnt /mnt/main`, `findmnt /mnt/media`, and `df -h` on the
Docker VM.

### 5.7 Diagnose `No Data`

Work through these checks in order.

1. Confirm the Prometheus data source still passes `Save & test` and uses
   `http://prometheus:9090`.
2. Run `up`. If this also returns no data, the problem is the Grafana data source,
   selected time range, or Prometheus itself rather than node-exporter.
3. Run `up{job="docker-vm"}`. No series means the installed job has another name
   or is absent. A value of `0` means it is configured but failing.
4. Run `node_uname_info` and inspect the real `job` and `instance` labels.
5. Open `http://192.168.1.20:9090/targets`, locate the node-exporter target, and
   read its `Last scrape` and `Error` fields.
6. Check the containers and logs on the Docker VM:

```bash
cd /opt/stacks/monitoring
docker compose ps prometheus node-exporter
docker compose logs --tail 100 prometheus node-exporter
docker inspect node-exporter --format '{{json .NetworkSettings.Networks}}'
docker inspect prometheus --format '{{json .NetworkSettings.Networks}}'
```

Both containers must share the monitoring Docker network. Prometheus must target
`node-exporter:9100`, not the Docker VM's LAN address, unless you intentionally
published port `9100`.

After editing `prometheus/prometheus.yml`, validate and reload it:

```bash
cd /opt/stacks/monitoring
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
docker compose kill -s HUP prometheus
docker compose logs --tail 50 prometheus
```

Do not import a dashboard until these direct queries work. Imported dashboards
often expect a different `job` label; when that happens, adjust the dashboard's
data-source variable or job filter to the labels shown by your own `up` query.

## Step 6: Review Watchtower Without Enabling Updates

```bash
cd /opt/stacks/watchtower
docker compose config --quiet
docker compose ps
docker compose logs --tail 200 watchtower
```

Verify the effective setting inside the container:

```bash
docker inspect watchtower \
  --format '{{range .Config.Env}}{{println .}}{{end}}' | \
  grep '^WATCHTOWER_MONITOR_ONLY=true$'
```

The command must print exactly:

```text
WATCHTOWER_MONITOR_ONLY=true
```

Trigger one immediate check without changing containers:

```bash
docker compose run --rm watchtower --run-once --monitor-only
```

Read the result. `Found new ... image` means review is required; it is not an
instruction to update everything. Authentication or registry `HEAD` errors mean
the affected image was not checked successfully and must not be treated as
current.

If Watchtower has no notification provider, review its logs weekly. Uptime Kuma
should remain the primary service-down notification path. Do not enable
`WATCHTOWER_MONITOR_ONLY=false`.

### 6.1 Add Watchtower Update Notifications

Watchtower notifications answer this question:

```text
Are newer container images available?
```

They do not answer whether the update is safe, and they must not apply the
update automatically.

The existing Watchtower compose template already supports Discord. Telegram is
also supported, but it uses Watchtower's newer shoutrrr notification URL instead
of the legacy Slack-compatible Discord settings.

Use one notification path first. After it works, you can add a second one.

#### Option A: Discord

Create a Discord webhook in the channel where you want update notices, then
configure Watchtower:

```bash
cd /opt/stacks/watchtower
nano .env
```

Use this format, without a `/slack` suffix:

```env
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/WEBHOOK_ID/WEBHOOK_TOKEN
```

Make sure `docker-compose.yml` contains these environment lines:

```yaml
      - WATCHTOWER_MONITOR_ONLY=true
      - WATCHTOWER_NOTIFICATIONS=slack
      - WATCHTOWER_NOTIFICATION_SLACK_HOOK_URL=${DISCORD_WEBHOOK_URL}/slack
```

Restart and test one manual check:

```bash
docker compose config --quiet
docker compose up -d
docker compose logs --tail 100 watchtower
docker compose run --rm watchtower --run-once --monitor-only
```

Do not paste normal `docker compose config` output into chat or tickets after
adding the webhook; it can print the secret URL. Use `--quiet` for validation.

For email, prefer Uptime Kuma SMTP notifications for service outages. Watchtower
can also notify through other providers, but email requires maintaining SMTP
credentials on the Docker VM. Use that only if you are comfortable storing an app
password on the server.

#### Option B: Telegram

Telegram is a good choice if you want update notices on your phone.

In Telegram:

1. Message `@BotFather`.
2. Create a bot with `/newbot`.
3. Save the bot token.
4. Start a chat with your new bot, or add it to the group/channel where you want
   Watchtower notices.

Find the chat target:

```bash
docker run --rm -it containrrr/shoutrrr generate telegram
```

That command walks you through creating the Telegram notification URL. For a
private chat or group, the target is usually a numeric chat ID. For a public
channel, the target can be the channel name with `@` in front, but the bot must
be allowed to post there.

Then edit Watchtower:

```bash
cd /opt/stacks/watchtower
nano .env
```

Use this format:

```env
WATCHTOWER_NOTIFICATION_URL=telegram://BOT_TOKEN@telegram?chats=CHAT_ID
```

Public channel example:

```env
WATCHTOWER_NOTIFICATION_URL=telegram://BOT_TOKEN@telegram?chats=@your_channel_name
```

Then edit `docker-compose.yml` and replace the Discord notification lines:

```yaml
      # Remove or comment these Discord-only lines:
      # - WATCHTOWER_NOTIFICATIONS=slack
      # - WATCHTOWER_NOTIFICATION_SLACK_HOOK_URL=${DISCORD_WEBHOOK_URL}/slack

      # Use this for Telegram:
      - WATCHTOWER_NOTIFICATION_URL=${WATCHTOWER_NOTIFICATION_URL}
```

Restart and test:

```bash
docker compose config --quiet
docker compose up -d
docker compose logs --tail 100 watchtower
docker compose run --rm watchtower --run-once --monitor-only
```

Do not paste normal `docker compose config` output after adding the Telegram URL;
it can print the bot token.

#### Option C: Discord And Telegram Together

If you want both Discord and Telegram at the same time, use shoutrrr URLs for
both providers and separate them with a space:

```env
WATCHTOWER_NOTIFICATION_URL=telegram://BOT_TOKEN@telegram?chats=CHAT_ID discord://DISCORD_WEBHOOK_TOKEN@DISCORD_WEBHOOK_ID
```

For Discord, convert this webhook:

```text
https://discord.com/api/webhooks/DISCORD_WEBHOOK_ID/DISCORD_WEBHOOK_TOKEN
```

into this shoutrrr URL:

```text
discord://DISCORD_WEBHOOK_TOKEN@DISCORD_WEBHOOK_ID
```

Then use only this compose environment line:

```yaml
      - WATCHTOWER_NOTIFICATION_URL=${WATCHTOWER_NOTIFICATION_URL}
```

Do not also keep the legacy `WATCHTOWER_NOTIFICATIONS=slack` Discord lines when
using the combined shoutrrr URL.

For a weekly or monthly maintenance reminder, use a recurring calendar/task
reminder on your phone or email account. That reminder should say: review
Watchtower notices, read release notes, confirm backups, then update one stack at
a time. A self-hosted reminder is less reliable because the reminder can fail
when the server itself is down.

## Step 7: Perform The First Controlled Container Update

Choose a low-risk, stateless stack first. Do not start with a database,
Nextcloud, Traefik, Authelia, Gluetun, or storage-related service.

### 7.1 Pre-Update Checks

```bash
cd /opt/stacks/STACK_NAME
docker compose config --quiet
docker compose ps
docker compose images
docker compose logs --tail 50
```

Read the upstream release notes for the exact old and new versions. If the image
is pinned, edit the tag to the reviewed version. `docker compose pull` alone does
not advance an explicit immutable version tag.

### 7.1.1 Find The Real Stack And Image

Before editing anything, identify which compose file owns the running container.
This avoids updating the wrong Jellyfin definition when multiple guides or
example compose files exist.

For Jellyfin:

```bash
docker inspect jellyfin \
  --format 'Image={{.Config.Image}}'

docker inspect jellyfin \
  --format 'Compose dir={{ index .Config.Labels "com.docker.compose.project.working_dir" }}'

docker inspect jellyfin \
  --format 'Compose files={{ index .Config.Labels "com.docker.compose.project.config_files" }}'
```

Then go to that directory:

```bash
cd "$(docker inspect jellyfin --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}')"
docker compose config --images
docker compose ps jellyfin
```

The image name tells you the provider:

| Image prefix | Provider | Update rule |
|---|---|---|
| `jellyfin/jellyfin` | Official Jellyfin image | Choose a tag from the official Jellyfin image tags and match it to Jellyfin release notes. |
| `lscr.io/linuxserver/jellyfin` | LinuxServer image | Choose a tag from the LinuxServer Jellyfin image tags and read both Jellyfin and LinuxServer notes. |

Do not switch providers during a routine update. `jellyfin/jellyfin` and
`lscr.io/linuxserver/jellyfin` have different image conventions and can have
different paths, users, permissions, and startup behavior. Treat a provider
change as a migration.

### 7.1.2 Decide Whether The Compose File Needs Editing

Look at the image tag:

```bash
docker compose config --images | grep -i jellyfin
```

If it ends in `:latest`, the compose file does not need to change for a normal
pull. The update happens when you run:

```bash
docker compose pull jellyfin
docker compose up -d jellyfin
```

That is convenient, but it is less controlled because the tag name stays the
same while the image behind it changes.

If it ends in a version, such as this example:

```yaml
image: jellyfin/jellyfin:10.9.7
```

then you must edit the compose file or `.env` tag first:

```yaml
image: jellyfin/jellyfin:<reviewed-new-version>
```

Use the exact tag published by the same image provider. Do not guess. Verify the
tag exists before editing the stack:

```bash
docker manifest inspect jellyfin/jellyfin:<reviewed-new-version> >/dev/null && echo "tag exists"
```

For a LinuxServer image, verify the LinuxServer tag instead:

```bash
docker manifest inspect lscr.io/linuxserver/jellyfin:<reviewed-new-tag> >/dev/null && echo "tag exists"
```

How to choose the tag:

```text
1. Check the currently running version in the Jellyfin admin dashboard.
2. Open the release notes for the same provider/image you already use.
3. Prefer the newest stable patch release that does not require unresolved manual migration work.
4. Avoid major jumps until you have a fresh config backup and time to test playback.
5. Verify the exact container tag exists with docker manifest inspect.
```

For Jellyfin specifically, test playback after updating. A container can be
`healthy` while transcoding, hardware acceleration, subtitles, plugins, or client
login behavior is broken.

For a stateful stack, stop here until all are true:

```text
[ ] Latest database/application backup succeeded.
[ ] Latest TrueNAS snapshot succeeded where applicable.
[ ] Latest Proxmox VM backup succeeded.
[ ] The restore procedure is known.
[ ] The release notes contain no unresolved migration requirement.
```

### 7.2 Apply One Update

If the image is pinned, change the tag first. If it uses `latest`, do not edit the
file just to update, but consider converting to a pinned tag during a planned
maintenance window.

Jellyfin example with a pinned official image:

```yaml
# Before
image: jellyfin/jellyfin:10.9.7

# After reviewing release notes and verifying the tag exists
image: jellyfin/jellyfin:<reviewed-new-version>
```

Jellyfin example with a LinuxServer image:

```yaml
# Before
image: lscr.io/linuxserver/jellyfin:latest

# Routine update: no compose edit required; pull refreshes latest.
# Controlled pinning: replace latest with an exact LinuxServer tag from their tag list.
```

Then apply the update:

```bash
nano docker-compose.yml
docker compose config --quiet
docker compose pull jellyfin
docker compose up -d jellyfin
docker compose ps jellyfin
docker compose logs --tail 100 jellyfin
```

For a different service, replace `jellyfin` with that compose service name. If
the stack has dependencies, update only the intended service unless the release
notes say a dependency must also move.

Test the actual application, not only the container state. For Jellyfin, confirm:

```text
[ ] Web UI loads.
[ ] Admin login works.
[ ] Library metadata is still present.
[ ] One existing movie or episode plays.
[ ] Hardware transcoding still sees /dev/dri if you use Quick Sync.
[ ] Uptime Kuma monitor returns to UP.
[ ] Logs have no repeated database, migration, permission, or FFmpeg errors.
```

Watch it for at least ten minutes before touching another stack.

### 7.3 Roll Back If Verification Fails

Collect evidence before changing it again:

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

If the update migrated a database or appdata format, do not force an old image
onto the migrated data. Follow the application's rollback procedure and restore
the matching database/appdata backup.

Only prune old images after successful verification and the rollback window:

```bash
docker image prune -f
```

## Step 8: Patch The Ubuntu Docker VM

First confirm containers, storage, and backups are healthy:

```bash
docker ps
findmnt /mnt/main
findmnt /mnt/media
```

Review and apply Ubuntu updates:

```bash
sudo apt update
apt list --upgradable
sudo apt upgrade
```

Check whether a reboot is required:

```bash
if [ -f /var/run/reboot-required ]; then
  cat /var/run/reboot-required
else
  echo "No reboot required"
fi
```

If required, reboot only during a maintenance window:

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

Also rerun the ARR/Gluetun leak and kill-switch checks before considering the
maintenance complete.

## Step 9: Weekly Maintenance Checklist

Run every week:

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

Also check:

```text
[ ] Prometheus targets are UP.
[ ] No unexpected alerts remain firing.
[ ] Uptime Kuma monitors and notifications work.
[ ] Watchtower remains monitor-only.
[ ] Watchtower registry checks completed without hidden errors.
[ ] TrueNAS SMART tests, scrubs, snapshots, and alerts are healthy.
[ ] Proxmox backup jobs succeeded.
[ ] Application/database backups succeeded.
[ ] Disk usage has enough headroom.
```

## Step 10: Monthly And Quarterly Work

Monthly:

```text
1. Review supported versions and upstream release notes.
2. Update approved containers one stack at a time.
3. Apply Ubuntu updates and schedule any required reboot.
4. Test one notification path.
5. Restore one sample file or non-production database backup.
```

Quarterly:

```text
1. Review every pinned image for support status.
2. Review Prometheus thresholds and remove noisy alerts.
3. Review Uptime Kuma monitors for deleted or missing services.
4. Review accounts, tokens, webhook URLs, and expired credentials.
5. Walk through the disaster-recovery runbook.
6. Confirm monitoring remains private and has no router port forward.
```

## Completion Checklist

```text
[ ] Alertmanager remains Up after at least one hour.
[ ] Alertmanager configuration passes amtool check-config.
[ ] Prometheus, node-exporter, and cAdvisor targets are UP.
[ ] The temporary test alert reached Alertmanager and was removed.
[ ] Uptime Kuma sent both a down and recovery notification.
[ ] Grafana queries return current host metrics.
[ ] Watchtower reports updates but never applies them.
[ ] One low-risk stack completed the update and rollback-readiness workflow.
[ ] Ubuntu updates and reboot handling are understood.
[ ] Weekly, monthly, and quarterly maintenance are scheduled.
[ ] Monitoring ports are LAN/Tailscale-only.
```

After this checklist passes, continue with the security guides before following
the Traefik/Cloudflare public-access guide. Monitoring itself does not need public
exposure.
