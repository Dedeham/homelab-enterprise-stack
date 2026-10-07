# Jellyfin Setup And Testing

Covers: Intel iGPU (Quick Sync) passthrough, moving Jellyfin appdata off NFS onto local storage, and adding legal Live TV through Dispatcharr.

See [docs/services/jellyfin.md](../../services/jellyfin.md) for the current architecture and configuration this setup produces.

Do this after:

1. Proxmox manual initial setup.
2. Ubuntu Docker VM setup.
3. The ARR stack / local-first media setup (and, if applicable, media automation with debrid).

## Part 1: Intel iGPU Passthrough And Local Appdata

### Source-of-truth values for this setup

| Item | Value |
|---|---|
| Proxmox host | `192.168.1.2` |
| TrueNAS VM | VM `110`, `192.168.1.10` |
| Ubuntu Docker VM | VM `111`, `192.168.1.20` |
| CPU | Intel Xeon E3-1245 v6 |
| iGPU | Intel HD Graphics P630, PCI ID `8086:591d` |
| Proxmox iGPU address | `0000:00:02.0` |
| Jellyfin stack | `/opt/stacks/jellyfin-stack` |
| Container UID/GID | `3000:3000` |
| Existing NFS config | `/mnt/main/appdata/arr-stack/jellyfin` |
| New local config | `/srv/appdata/jellyfin` |

### Step 1: Record the working baseline

On the Proxmox host:

```bash
dmesg | grep -e DMAR -e IOMMU
lspci -nnk -s 00:02.0
find /sys/kernel/iommu_groups/ -type l | sort
qm config 111
```

Confirm IOMMU is enabled, `00:02.0` is the P630 (`8086:591d`), the iGPU is in its own IOMMU group, VM `111` uses legacy BIOS, and VT-d/integrated graphics are enabled in firmware. A firmware "bad RMRR" warning does not by itself block passthrough.

In VM `111`:

```bash
cd /opt/stacks/jellyfin-stack
docker compose ps
docker inspect jellyfin --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
findmnt -T /mnt/main/appdata/arr-stack/jellyfin
findmnt -T /mnt/media/data
sudo du -sh /mnt/main/appdata/arr-stack/jellyfin
df -h /
```

The media source must be `192.168.1.10:/mnt/main/media/data -> /mnt/media/data`. Do not continue otherwise.

### Step 2: Configure Proxmox iGPU passthrough

Keep VM `111` on SeaBIOS/default BIOS, default machine type, and the virtual Bochs display. Add the iGPU as a secondary PCI device; do not enable `Primary GPU` or `PCI-Express`; do not add a persistent `vfio-pci.ids` or blacklist `i915`.

```bash
qm shutdown 111
qm status 111       # wait for "status: stopped"
qm set 111 --hostpci0 0000:00:02.0
qm start 111
```

Equivalent GUI path: `VM 111 -> Hardware -> Add -> PCI Device -> Raw Device -> 0000:00:02.0` (leave Primary GPU/All Functions/PCI-Express off).

Rollback if the VM does not boot:

```bash
qm stop 111
qm set 111 -delete hostpci0
qm start 111
```

If the host still shows `Kernel driver in use: vfio-pci`, cleanly shut down the VMs and reboot Proxmox; it should return to `i915`.

### Step 3: Verify the P630 inside VM 111

```bash
lspci -nnk | grep -A4 -Ei 'HD Graphics|Kaby|8086:591d'
ls -l /dev/dri
getent group video
getent group render
```

Expect `card1`/`renderD128` for the iGPU (`card0` is the virtual Bochs display) and groups `video:44`, `render:991` (verify per installation).

Install validation tools:

```bash
sudo apt update
sudo apt install -y vainfo intel-media-va-driver-non-free intel-gpu-tools
# or, if unavailable:
sudo apt install -y vainfo intel-media-va-driver intel-gpu-tools

sudo usermod -aG video,render "$USER"
# log out and back in
id
vainfo --display drm --device /dev/dri/renderD128
```

Expect H.264/HEVC/MPEG-2 (and others) hardware profiles; AV1 is not expected. `intel_gpu_top` reporting `Failed to detect engines` is expected in this passed-through guest and is not a failure signal — use `vainfo` and a real Jellyfin transcode as the authoritative tests.

### Step 4: Give Jellyfin access to the iGPU

Re-check group IDs (do not assume another installation's values):

```bash
getent group video
getent group render
```

In `/opt/stacks/jellyfin-stack/docker-compose.yml`, the Jellyfin service must contain:

```yaml
    devices:
      - /dev/dri:/dev/dri
    group_add:
      - "44"
      - "991"
    volumes:
      - ${JELLYFIN_CONFIG}:/config
      - ${DATA_PATH}/media/movies:/media/movies:ro
      - ${DATA_PATH}/media/tv:/media/tv:ro
      - ${DATA_PATH}/media/music:/media/music:ro
```

Apply and verify:

```bash
cd /opt/stacks/jellyfin-stack
docker compose config
docker compose up -d
docker exec jellyfin id
docker exec jellyfin ls -l /dev/dri
```

### Step 5: Configure Quick Sync in Jellyfin

Open **Dashboard → Playback → Transcoding** and set:

| Option | Value |
|---|---|
| Hardware acceleration | Intel Quick Sync (QSV) |
| QSV device | `/dev/dri/renderD128` |
| H.264 / HEVC / MPEG-2 / VC-1 / VP8 / VP9 decode | Enabled |
| HEVC 10-bit / VP9 10-bit decode | Enabled |
| AV1 decode | Disabled |
| HEVC RExt profiles | Disabled |
| Prefer native VA-API decoders | Enabled |
| Hardware encoding | Enabled |
| Low-power H.264/HEVC encoding | Disabled initially |
| HEVC output encoding | Disabled initially |
| AV1 output encoding | Disabled |
| VPP/OpenCL tone mapping | Disabled initially |
| Audio downmix gain | `1` |
| Maximum muxing queue | `2048` |
| Transcoding throttling | Enabled |
| Delete old segments | Enabled |

Confirm normal SDR/HEVC Main10 transcoding before testing tone mapping.

### Step 6: Prove QSV is actually used

Start a 4K HEVC video, force a transcode (lower playback quality), and in a second shell:

```bash
docker logs -f jellyfin
```

Look for `-init_hw_device vaapi=va:/dev/dri/renderD128,driver=iHD`, `-init_hw_device qsv=qs@va`, and `-codec:v:0 h264_qsv`. Seeing `qsv` only in the encoder list is not sufficient. In a Jellyfin client, check **Dashboard → Active devices → open the active stream** for `Direct Play` / `Remux` / `Transcoding`.

### Step 7: Add a local appdata disk in Proxmox

The Docker VM root filesystem has limited free space; do not grow Jellyfin metadata there.

`VM 111 -> Hardware -> Add -> Hard Disk`:

| Setting | Value |
|---|---|
| Bus/device | SCSI |
| Storage | `ssd-fast` (verify actual name in the UI) |
| Size | 32 GB minimum, 64 GB with heavy trickplay/chapter images |
| Discard / IO thread / SSD emulation / Backup | Enabled |

### Step 8: Format and mount the new disk

```bash
sudo apt update
sudo apt install -y parted rsync
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,MODEL
```

Replace `/dev/sdb` below with the actual new blank disk — never `mkfs` the root disk:

```bash
sudo parted /dev/sdb --script mklabel gpt
sudo parted /dev/sdb --script mkpart primary ext4 0% 100%
sudo mkfs.ext4 -L appdata /dev/sdb1
sudo mkdir -p /srv/appdata
sudo mount /dev/sdb1 /srv/appdata
sudo blkid /dev/sdb1
```

Add to `/etc/fstab` (use the real UUID):

```fstab
UUID=REPLACE_WITH_REAL_UUID /srv/appdata ext4 defaults,noatime 0 2
```

Validate:

```bash
sudo umount /srv/appdata
sudo mount -a
findmnt -T /srv/appdata
df -h /srv/appdata
```

Expect filesystem type `ext4`, not `nfs4`/`autofs`.

### Step 9: Migrate Jellyfin config from NFS to local SSD

```bash
cd /opt/stacks/jellyfin-stack
docker compose stop jellyfin

sudo mkdir -p /srv/appdata/jellyfin
sudo rsync -aH --numeric-ids \
  /mnt/main/appdata/arr-stack/jellyfin/ \
  /srv/appdata/jellyfin/
sudo chown -R 3000:3000 /srv/appdata/jellyfin

sudo du -sh /mnt/main/appdata/arr-stack/jellyfin
sudo du -sh /srv/appdata/jellyfin
sudo find /srv/appdata/jellyfin -maxdepth 3 -name jellyfin.db -ls
```

Do not delete the NFS source — it is the rollback copy until tests and a full reboot pass.

Edit `/opt/stacks/jellyfin-stack/.env`:

```text
PUID=3000
PGID=3000
TZ=Europe/Berlin
DOCKER_IP=192.168.1.20
JELLYFIN_CONFIG=/srv/appdata/jellyfin
DATA_PATH=/mnt/media/data
```

Do not change `DATA_PATH`. Validate and start:

```bash
cd /opt/stacks/jellyfin-stack
docker compose config
docker compose up -d
docker compose ps
docker inspect jellyfin --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
docker logs --tail=150 jellyfin
docker logs --since 30m jellyfin 2>&1 | grep -Ei 'database is locked|SqliteException'
```

Expect no `database is locked`/`SqliteException` output, and mounts `/srv/appdata/jellyfin -> /config` plus the three TrueNAS media paths. In the UI, confirm users, libraries, and watch history are intact, media opens normally, `/dev/dri/renderD128` is still visible, and a forced transcode still uses `h264_qsv`/`hevc_qsv`.

### Step 10: Reboot tests

```bash
sudo reboot
# after reconnecting:
findmnt -T /srv/appdata/jellyfin
findmnt -T /mnt/media/data/media/movies
lspci -nnk | grep -A4 -Ei 'HD Graphics|Kaby|8086:591d'
ls -l /dev/dri
docker compose -f /opt/stacks/jellyfin-stack/docker-compose.yml ps
docker exec jellyfin ls -l /dev/dri
```

After the VM reboot passes, schedule a full Proxmox reboot (TrueNAS starts first at order `1`, Docker VM at order `2` with a 60s delay), then repeat the checks and force one QSV transcode.

### Step 11: Back up the new local appdata

```bash
sudo -u mediauser mkdir -p /mnt/main/backups/docker-volumes/jellyfin

cd /opt/stacks/jellyfin-stack
docker compose stop jellyfin
sudo -u mediauser tar --xattrs --acls --exclude='jellyfin/cache' \
  -czf "/mnt/main/backups/docker-volumes/jellyfin/jellyfin-config-$(date +%F-%H%M).tar.gz" \
  -C /srv/appdata jellyfin
docker compose start jellyfin

ls -lh /mnt/main/backups/docker-volumes/jellyfin
sudo tar -tzf /mnt/main/backups/docker-volumes/jellyfin/jellyfin-config-YYYY-MM-DD-HHMM.tar.gz | head
```

Add retention/scheduling only after one archive has been restored in a test directory.

### Rollback to NFS config

```bash
cd /opt/stacks/jellyfin-stack
docker compose stop jellyfin
```

Restore `JELLYFIN_CONFIG=/mnt/main/appdata/arr-stack/jellyfin` in `.env`, then:

```bash
docker compose up -d
docker inspect jellyfin --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
docker logs --tail=100 jellyfin
```

Do not copy the new local database back over the NFS rollback copy until the migration failure is understood.

### Final checklist

- [ ] Proxmox IOMMU is enabled.
- [ ] VM `111` has only `hostpci0: 0000:00:02.0`.
- [ ] `/dev/dri/renderD128` exists in the VM and the container.
- [ ] `vainfo` succeeds against `/dev/dri/renderD128`.
- [ ] A real transcode uses `h264_qsv`/`hevc_qsv`.
- [ ] `/config` maps from `/srv/appdata/jellyfin` on ext4.
- [ ] Media paths still map from TrueNAS NFS.
- [ ] `database is locked` does not recur.
- [ ] VM and full Proxmox reboot tests pass.
- [ ] The new disk is in Proxmox backups and a config archive exists under `/mnt/main/backups`.

## Part 2: Live TV (German, English, Sports) Via Dispatcharr

Legal-sources-only scope: legal IPTV/public M3U streams, legal XMLTV/EPG sources, official public-broadcaster streams/downloads where permitted. Do not use pirate IPTV, scraped pay-TV lists, DRM bypasses, CI+ workarounds, or token/cookie scraping.

Assumes the TrueNAS media pool migration (`/mnt/media/data`, not the old `/mnt/main/media/data`) is complete. Verify first:

```bash
findmnt -T /mnt/media/data -o TARGET,SOURCE,FSTYPE,OPTIONS
df -h /mnt/main /mnt/media/data
```

Expect source `192.168.1.10:/mnt/media/data`.

### Step 1: Create folders

On the Docker VM:

```bash
findmnt -T /mnt/media/data -o TARGET,SOURCE,FSTYPE,OPTIONS
findmnt -T /srv/appdata -o TARGET,SOURCE,FSTYPE,OPTIONS
df -h /mnt/main /mnt/media/data

sudo mkdir -p /srv/appdata/dispatcharr
sudo chown root:root /srv/appdata/dispatcharr

sudo -u mediauser mkdir -p /mnt/main/appdata/live-tv/mediathek/urls
sudo -u mediauser mkdir -p /mnt/main/appdata/live-tv/mediathek/logs
sudo -u mediauser mkdir -p /mnt/main/appdata/live-tv/mediathek/pip-cache
sudo -u mediauser mkdir -p /mnt/main/appdata/live-tv/sources
sudo -u mediauser mkdir -p /mnt/main/backups/docker-volumes/dispatcharr
sudo -u mediauser mkdir -p /mnt/media/data/live-tv/dispatcharr-recordings
sudo -u mediauser mkdir -p "/mnt/media/data/media/tv/Bares fuer Rares"
sudo -u mediauser mkdir -p /mnt/media/data/media/movies/public-broadcaster
```

Write-test each path (`touch`/`rm` a `.write-test` file as the appropriate owner) before continuing. If `/srv/appdata` is NFS/autofs, fix that first (same local-appdata pattern as Jellyfin).

### Step 2: Deploy Dispatcharr

```bash
sudo mkdir -p /opt/stacks/live-tv
sudo chown -R "$USER":"$USER" /opt/stacks/live-tv
cd /opt/stacks/live-tv
```

`.env`:

```bash
cat > .env <<'EOF'
TZ=Europe/Berlin
SERVER_IP=192.168.1.20
DISPATCHARR_VERSION=latest
EOF
chmod 600 .env
```

Use `latest` or `dev`/a commit SHA — Dispatcharr's GitHub release tags (e.g. `v0.27.1`) do not exist on GHCR and will fail to pull.

`docker-compose.yml`:

```yaml
services:
  dispatcharr:
    image: ghcr.io/dispatcharr/dispatcharr:${DISPATCHARR_VERSION}
    container_name: dispatcharr
    restart: unless-stopped
    ports:
      - "${SERVER_IP}:9191:9191"
    environment:
      - DISPATCHARR_ENV=aio
      - REDIS_HOST=localhost
      - CELERY_BROKER_URL=redis://localhost:6379/0
      - DISPATCHARR_LOG_LEVEL=info
      - TZ=${TZ}
    volumes:
      - /srv/appdata/dispatcharr:/data
      - /mnt/main/appdata/live-tv/sources:/sources:ro
      - /mnt/main/appdata/live-tv/sources:/data/m3us:ro
      - /mnt/media/data/live-tv/dispatcharr-recordings:/recordings
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

```bash
docker compose config
docker compose up -d dispatcharr
docker compose ps dispatcharr
```

Open `http://192.168.1.20:9191` and create the admin account. Keep LAN/Tailscale-only.

### Step 3: Configure Dispatcharr

Add one legal M3U source at a time. For iptv-org (or similar public index):

| Field | Value |
|---|---|
| `Name` | descriptive, e.g. `Ger - iptv-org Germany Review` |
| `Account Type` | `Standard` or `Standard M3U` (never `Xtream Codes` for a plain playlist) |
| `URL` | e.g. `https://iptv-org.github.io/iptv/countries/de.m3u` |
| `Upload files` | empty unless uploading a local curated `.m3u` |
| `Max Streams` | `0` unless the source gives a limit |
| `Enable VOD Scanning` | Off |
| `Is Active` | On |

Do not put a filesystem path (`/sources/...`, `/data/m3us/...`) into the `URL` field — upload the file or use mapped-file auto-import from `/data/m3us` instead (enable under `Settings -> Stream Settings`).

Repeat for additional sources (German-language, English, sports, news, public), changing only name/URL, importing one at a time and cleaning it up before adding the next.

Under the source's group/auto-sync settings:

- `Automatically enable new groups discovered on future scans`: Off.
- `Auto-sync orphan cleanup`: On.
- `Auto Channel Sync`: On only for groups you've reviewed and want; Off for noisy/unknown groups.
- Assign a starting channel number per enabled group (suggested ranges: German/public general `1`, German regional `100`, English `200`, sports `300`, news `400`, kids `500`, test `900`).

Apply source filters to exclude dead/geo-blocked/premium-named/adult/shopping streams before creating channels (regex examples: `dead|offline|test`, `DAZN|Sky|WOW|MagentaSport|RTL\+`, `adult|xxx|18\+`).

Create channels manually from `Channels` for a clean first pass (3-5 German, 1-2 news, 0-2 English, 0-1 sports), picking the most reliable quality stream per channel and giving it a clean display name.

Add EPG/XMLTV only after at least one channel plays: `M3U & EPG Manager -> Add EPG`, name it, paste the XMLTV URL from the same provider, save, then confirm programme data in `TV Guide`.

Test playback inside Dispatcharr for each channel (≥30s) before adding to Jellyfin; disable channels that don't start, buffer constantly, redirect to unrelated content, or require DRM/login/cookies.

Confirm the exports from the Docker VM:

```bash
curl -fsS "PASTE_DISPATCHARR_M3U_EXPORT_URL_HERE" | sed -n '1,40p'
curl -fsS "PASTE_DISPATCHARR_XMLTV_EXPORT_URL_HERE" | sed -n '1,40p'
```

Expect `#EXTM3U`/channel entries and `<?xml`/`<tv...>` respectively.

### Step 4: Connect Dispatcharr to Jellyfin

In Jellyfin: **Dashboard → Live TV → Add tuner device → M3U Tuner**, paste the Dispatcharr M3U export URL. Then **Add TV guide data provider → XMLTV**, paste the Dispatcharr XMLTV export URL. Save, wait for guide refresh, and map channels if not mapped automatically.

If Jellyfin cannot reach Dispatcharr, test from the Docker VM first:

```bash
curl -fsS "http://192.168.1.20:9191" >/dev/null
```

### Step 5: Optional local Mediathek archive

On the Docker VM:

```bash
sudo apt-get update
sudo apt-get install -y ffmpeg python3-venv

sudo -u mediauser python3 -m venv /mnt/main/appdata/live-tv/mediathek/venv
sudo -u mediauser env PIP_CACHE_DIR=/mnt/main/appdata/live-tv/mediathek/pip-cache \
  /mnt/main/appdata/live-tv/mediathek/venv/bin/python -m pip install -U pip yt-dlp
sudo -u mediauser /mnt/main/appdata/live-tv/mediathek/venv/bin/yt-dlp --version
```

Helper script (`/opt/stacks/live-tv/download-medithek-url.sh`):

```bash
#!/usr/bin/env bash
set -euo pipefail

URL="${1:?Usage: download-medithek-url.sh <exact-episode-url>}"
APPDATA="/mnt/main/appdata/live-tv/mediathek"
OUTPUT_ROOT="/mnt/media/data/media/tv/Bares fuer Rares"
YTDLP="$APPDATA/venv/bin/yt-dlp"

sudo -u mediauser "$YTDLP" \
  --no-playlist \
  --download-archive "$APPDATA/bares-fuer-rares.downloaded.txt" \
  --write-info-json --write-thumbnail --embed-metadata --embed-thumbnail \
  --merge-output-format mkv --restrict-filenames \
  -o "$OUTPUT_ROOT/%(title).180B [%(id)s].%(ext)s" \
  "$URL"
```

Simulate before downloading:

```bash
sudo -u mediauser /mnt/main/appdata/live-tv/mediathek/venv/bin/yt-dlp --simulate --no-playlist "PASTE_EXACT_EPISODE_URL_HERE"
./download-medithek-url.sh "PASTE_EXACT_EPISODE_URL_HERE"
```

Add a Jellyfin library pointing at `/mnt/media/data/media/tv/Bares fuer Rares` (content type Shows, or Mixed if metadata matching is poor), or `/mnt/media/data/media/movies/public-broadcaster` for standalone films.

### Step 6: Firewall

```bash
sudo ufw allow from 192.168.1.0/24 to any port 9191 proto tcp comment 'Dispatcharr web'
```

Do not expose Dispatcharr through Cloudflare Tunnel or router port forwards.

### Step 7: Optional VPN egress with Gluetun

Only add this if Dispatcharr itself proxies streams to Jellyfin (not direct upstream URLs), non-VPN playback already works, and the VPN is not being used to bypass DRM/geo-blocking. Create `/mnt/main/appdata/live-tv/gluetun` and add PIA credentials to `/opt/stacks/live-tv/.env`:

```env
GLUETUN_VERSION=latest
PIA_USER=p1234567
PIA_PASS=replace_with_your_pia_password
PIA_REGION=Netherlands
DNS_UPSTREAM_RESOLVER_TYPE=doh
DNS_UPSTREAM_RESOLVERS=cloudflare
```

Replace the direct Dispatcharr compose with a `live-tv-gluetun` + `dispatcharr` (via `network_mode: "service:gluetun"`) pair — see the Jellyfin descriptive doc for the architecture. Run a separate Gluetun instance from the existing debrid-stack Gluetun; do not reuse `debrid-gluetun`.

Verify:

```bash
cd /opt/stacks/live-tv
docker compose config
docker compose up -d
docker exec live-tv-gluetun wget -qO- --timeout=15 https://ifconfig.me
```

Full routing check:

```bash
HOME_WAN_IP="$(curl -4 -fsS --max-time 15 https://ifconfig.me)"
docker exec live-tv-gluetun sh -lc 'wget -qO- --timeout=15 https://ifconfig.me'
docker exec dispatcharr sh -lc 'wget -qO- --timeout=15 https://ifconfig.me'
docker compose config | grep -A5 -E '^[[:space:]]+dispatcharr:'
```

Pass: `network_mode: service:gluetun` set, both containers return a VPN IP, neither returns `$HOME_WAN_IP`.

Kill-switch check:

```bash
docker stop live-tv-gluetun
docker exec dispatcharr sh -lc 'curl -4 -fsS --max-time 10 https://ifconfig.me' \
  && echo "LEAK: investigate" || echo "blocked as expected"
docker compose up -d gluetun dispatcharr
```

### Monitoring

Add Uptime Kuma monitors for Dispatcharr UI (`http://192.168.1.20:9191`) plus manual monthly checks: open Live TV guide, play one channel per configured category, test one scheduled DVR recording if enabled, and confirm any new Mediathek download appears in Jellyfin.

### Backups

```bash
BACKUP_DIR="/mnt/main/backups/docker-volumes/dispatcharr"
STAMP="$(date +%F-%H%M)"
BACKUP_FILE="dispatcharr-data-${STAMP}.tar.gz"
TMP_BACKUP="/tmp/${BACKUP_FILE}"

sudo -u mediauser mkdir -p "$BACKUP_DIR"
sudo rm -f "$TMP_BACKUP"
cd /opt/stacks/live-tv
docker compose stop dispatcharr
sudo tar --xattrs --acls -czf "$TMP_BACKUP" -C /srv/appdata dispatcharr
docker compose start dispatcharr
sudo chown mediauser:mediauser "$TMP_BACKUP"
sudo -u mediauser mv "$TMP_BACKUP" "$BACKUP_DIR/$BACKUP_FILE"
```

Also back up `/mnt/main/appdata/live-tv/mediathek` and `/mnt/main/appdata/live-tv/sources`. For the `media` pool: monthly scrub, SMART tests (daily/weekly short, monthly long), optional daily/weekly snapshots with 7-14 day retention.

### Validation checklist

- [ ] `/mnt/media/data` is mounted from `192.168.1.10:/mnt/media/data`; `/srv/appdata` is local block storage.
- [ ] Dispatcharr `/data` maps from `/srv/appdata/dispatcharr`, not NFS.
- [ ] Live TV sources are legal and documented; questionable channels are disabled.
- [ ] M3U and XMLTV exports open from the Docker VM.
- [ ] Jellyfin Live TV guide populates; one channel per configured category plays.
- [ ] Dispatcharr is LAN/Tailscale-only.
- [ ] If VPN mode is used, both Gluetun and Dispatcharr return a VPN IP and exports point at Dispatcharr, not upstream.
- [ ] Dispatcharr appdata is covered by Proxmox VM backup and an archive backup.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `mkdir: Read-only file system` during backup | `/mnt/main` is read-only or unmounted; check `findmnt`, NFS export rw, `mediauser` ACL. Run checks from the Docker VM host, not inside a container. |
| `chown: changing ownership of '/data/db': Operation not permitted` | Dispatcharr `/data` is on NFS; move it to `/srv/appdata/dispatcharr` (local storage) and restart. |
| `Missing username or password for Xtream Codes account` | M3U source was created as `Xtream Codes` instead of `Standard`/`Standard M3U`; edit (or delete and recreate) with empty username/password and the plain M3U URL. |
| `Failed to refresh M3U groups - download failed or other error` | URL field has a filesystem path instead of an `http(s)://` URL, or the URL is unreachable/DNS-broken, or Gluetun is unhealthy. Test with `curl` from the Docker VM, then from inside the `dispatcharr` container. |
| Jellyfin guide is empty | XMLTV export is empty — fix EPG in Dispatcharr first. |
| Channels appear but do not play | Test the same channel directly in Dispatcharr first; if it fails there, it's a source/backend issue, not Jellyfin. |
| Sports recording cuts off early | Increase DVR post-padding (5 min pre / 30-60 min post for live sports). |
| IPTV works in VLC but not Jellyfin | Test direct source in VLC, then Dispatcharr output in VLC, then in Jellyfin — isolates which layer fails. Do not work around browser DRM/cookies/tokens. |
| Mediathek download not in Jellyfin | Confirm the file exists under the TV/movies path, then rescan the library; magazine-style shows often need `Mixed Movies and Shows` or folder view. |

## References

- Jellyfin Live Broadcast: <https://jellyfin.org/docs/general/server/live-tv/>
- Dispatcharr: <https://github.com/Dispatcharr/Dispatcharr>
- iptv-org: <https://github.com/iptv-org/iptv>
- MediathekView: <https://mediathekview.de/>
- yt-dlp: <https://github.com/yt-dlp/yt-dlp>
