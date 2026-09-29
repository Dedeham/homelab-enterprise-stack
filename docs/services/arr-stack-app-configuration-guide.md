# ARR Stack App Configuration Guide

Last updated: 2026-06-10

This guide expands the application setup phases after the Docker Compose stack is running.

Use this after the ARR stack containers are healthy and reachable from the LAN. It covers qBittorrent, Radarr, Sonarr, Prowlarr, Jellyfin, Seerr, and local end-to-end testing.

Assumptions:

- The stack runs on the Ubuntu Docker VM.
- Docker VM LAN IP is `192.168.1.20`.
- The ARR stack lives at `/opt/stacks/arr-stack`.
- qBittorrent, Prowlarr, Radarr, Sonarr, and FlareSolverr share qBittorrent's VPN network namespace.
- Jellyfin and Seerr are on the normal Docker network.
- Containers share the media root as `/data` where hardlinks and atomic moves can work.
- Jellyfin sees final media under `/media`.
- Remote access is local-first: LAN, Proxmox over Tailscale, SSH tunnel, or subnet route. Do not expose ARR admin UIs publicly.

## Phase 8: Configure qBittorrent

Goal: make qBittorrent save downloads into the same `/data` tree that Radarr and Sonarr can import from.

### 8.1 Open qBittorrent

From a browser on the LAN:

```text
http://192.168.1.20:8080
```

If the UI does not load, check the container first:

```bash
cd /opt/stacks/arr-stack
docker compose ps
docker compose logs --tail=100 qbittorrent
```

Do not add torrents yet. Finish the VPN check in Phase 11 before using qBittorrent for real downloads.

### 8.2 Confirm the Web UI login

Sign in with the credentials configured for the qBittorrent container.

After login:

1. Open `Tools`.
2. Open `Options`.
3. Open `Web UI`.
4. Change the default password if it is still using a generated or temporary value.
5. Save.

Use a password manager. The qBittorrent UI controls torrent downloads and should not be weak even on LAN.

### 8.3 Configure download folders

In qBittorrent:

1. Open `Tools`.
2. Open `Options`.
3. Open `Downloads`.
4. Enable `Keep incomplete torrents in`.
5. Set incomplete downloads to:

```text
/data/torrents/incomplete
```

6. Set the default save path to:

```text
/data/torrents
```

7. Save.

Expected folder layout:

```text
/data
├── media
│   ├── movies
│   ├── music
│   └── tv
└── torrents
    ├── incomplete
    ├── movies
    └── tv
```

### 8.4 Create categories

In the qBittorrent Web UI:

1. Go to the left sidebar.
2. Find `Categories`.
3. Right-click in the category area, or use the category add option if shown.
4. Create this category:

| Field | Value |
|---|---|
| Category | `movies` |
| Save path | `/data/torrents/movies` |

5. Create this category:

| Field | Value |
|---|---|
| Category | `tv` |
| Save path | `/data/torrents/tv` |

These category names must exactly match the Radarr and Sonarr download-client settings later.

### 8.5 Configure queueing and seeding

Use limits that match your storage, connection, and VPN provider rules.

Recommended starting point:

| Setting | Starting value |
|---|---:|
| Maximum active downloads | `3` |
| Maximum active uploads | `3` |
| Maximum active torrents | `8` |
| Global upload limit | Your available upload minus headroom |
| Global download limit | Optional; leave unlimited unless it hurts LAN use |

For private trackers, follow their ratio and seeding-time requirements. For public/legal test torrents, keep the initial setup conservative and confirm the workflow before tuning.

### 8.6 Confirm qBittorrent can see the paths

Run:

```bash
docker exec qbittorrent ls -la /data
docker exec qbittorrent ls -la /data/torrents
docker exec qbittorrent ls -la /data/torrents/incomplete
docker exec qbittorrent ls -la /data/torrents/movies
docker exec qbittorrent ls -la /data/torrents/tv
```

If a path is missing, create it on the Docker VM host under the mounted storage path, then fix ownership for the UID/GID used by the containers.

## Phase 9: Configure Radarr, Sonarr, And Prowlarr

Goal: make Radarr and Sonarr import from qBittorrent without remote path mappings, then let Prowlarr sync indexers to both apps.

Because Radarr, Sonarr, Prowlarr, qBittorrent, and FlareSolverr share the qBittorrent VPN namespace, they reach each other through `127.0.0.1` and their internal ports.

### 9.1 Configure Radarr

Open Radarr:

```text
http://192.168.1.20:7878
```

#### Set authentication

1. Open `Settings`.
2. Open `General`.
3. Set authentication if it is not already configured.
4. Save.

Keep ARR authentication enabled even when the service is LAN-only.

#### Add the movie root folder

1. Open `Settings`.
2. Open `Media Management`.
3. Show `Advanced Settings`.
4. Enable `Use Hardlinks instead of Copy` if available.
5. Save.
6. Open `Movies`.
7. Choose `Add New` or `Library Import`.
8. Add root folder:

```text
/data/media/movies
```

Use `/data/media/movies`, not the host path and not Jellyfin's `/media/movies` path.

#### Add qBittorrent as Radarr download client

1. Open `Settings`.
2. Open `Download Clients`.
3. Click `Add`.
4. Choose `qBittorrent`.
5. Use these settings:

| Setting | Value |
|---|---|
| Name | `qBittorrent` |
| Enable | On |
| Host | `127.0.0.1` |
| Port | `8080` |
| Username | qBittorrent username |
| Password | qBittorrent password |
| Category | `movies` |

6. Click `Test`.
7. Click `Save` only after the test succeeds.

No remote path mapping should be needed. Radarr and qBittorrent both see the same `/data` mount.

#### Confirm Radarr paths

Run:

```bash
docker exec radarr ls -la /data/media/movies
docker exec radarr ls -la /data/torrents/movies
```

If Radarr cannot list both paths, fix container mounts before continuing.

### 9.2 Configure Sonarr

Open Sonarr:

```text
http://192.168.1.20:8989
```

#### Set authentication

1. Open `Settings`.
2. Open `General`.
3. Set authentication if it is not already configured.
4. Save.

#### Add the TV root folder

1. Open `Settings`.
2. Open `Media Management`.
3. Show `Advanced Settings`.
4. Enable `Use Hardlinks instead of Copy` if available.
5. Save.
6. Open `Series`.
7. Choose `Add New` or `Library Import`.
8. Add root folder:

```text
/data/media/tv
```

Use `/data/media/tv`, not the host path and not Jellyfin's `/media/tv` path.

#### Add qBittorrent as Sonarr download client

1. Open `Settings`.
2. Open `Download Clients`.
3. Click `Add`.
4. Choose `qBittorrent`.
5. Use these settings:

| Setting | Value |
|---|---|
| Name | `qBittorrent` |
| Enable | On |
| Host | `127.0.0.1` |
| Port | `8080` |
| Username | qBittorrent username |
| Password | qBittorrent password |
| Category | `tv` |

6. Click `Test`.
7. Click `Save` only after the test succeeds.

#### Confirm Sonarr paths

Run:

```bash
docker exec sonarr ls -la /data/media/tv
docker exec sonarr ls -la /data/torrents/tv
```

If Sonarr cannot list both paths, fix container mounts before continuing.

### 9.3 Configure Prowlarr

Open Prowlarr:

```text
http://192.168.1.20:9696
```

#### Set authentication

1. Open `Settings`.
2. Open `General`.
3. Set authentication if it is not already configured.
4. Save.

#### Get Radarr and Sonarr API keys

In Radarr:

1. Open `Settings`.
2. Open `General`.
3. Copy the `API Key`.

In Sonarr:

1. Open `Settings`.
2. Open `General`.
3. Copy the `API Key`.

#### Add Radarr to Prowlarr

In Prowlarr:

1. Open `Settings`.
2. Open `Apps`.
3. Click `Add Application`.
4. Choose `Radarr`.
5. Use these settings:

| Setting | Value |
|---|---|
| Name | `Radarr` |
| Sync Level | `Full Sync` |
| Prowlarr Server | `http://127.0.0.1:9696` |
| Radarr Server | `http://127.0.0.1:7878` |
| API Key | Radarr API key |

6. Click `Test`.
7. Click `Save`.

#### Add Sonarr to Prowlarr

In Prowlarr:

1. Open `Settings`.
2. Open `Apps`.
3. Click `Add Application`.
4. Choose `Sonarr`.
5. Use these settings:

| Setting | Value |
|---|---|
| Name | `Sonarr` |
| Sync Level | `Full Sync` |
| Prowlarr Server | `http://127.0.0.1:9696` |
| Sonarr Server | `http://127.0.0.1:8989` |
| API Key | Sonarr API key |

6. Click `Test`.
7. Click `Save`.

#### Add indexers

1. Open `Indexers`.
2. Click `Add Indexer`.
3. Add only indexers you are allowed to use.
4. Test each indexer.
5. Save only working indexers.

Use legal sources and follow each indexer's terms. Do not troubleshoot by disabling security controls or exposing ARR services publicly.

#### Add FlareSolverr only when needed

Only add FlareSolverr for indexers that explicitly require it.

In Prowlarr:

1. Open `Settings`.
2. Open `Indexers`.
3. Find the proxy or FlareSolverr setting.
4. Add:

```text
http://127.0.0.1:8191
```

5. Test against the specific indexer that needs it.

Do not use FlareSolverr globally unless an indexer requires it.

## Phase 10: Configure Jellyfin And Seerr

Goal: make Jellyfin read final media directly and make Seerr request media through Radarr and Sonarr.

Jellyfin and Seerr are not in the VPN namespace. They use normal Docker networking and LAN-published ports.

### 10.1 Configure Jellyfin

Open Jellyfin:

```text
http://192.168.1.20:8096
```

#### Complete first-run setup

1. Create the admin user.
2. Set language and metadata preferences.
3. Skip remote access setup for now.
4. Finish the wizard.

Remote access should be designed separately after local playback works.

#### Add libraries

In Jellyfin:

1. Open the dashboard.
2. Open `Libraries`.
3. Add a library for movies:

| Setting | Value |
|---|---|
| Content type | `Movies` |
| Display name | `Movies` |
| Folder | `/media/movies` |

4. Add a library for TV:

| Setting | Value |
|---|---|
| Content type | `Shows` |
| Display name | `TV Shows` |
| Folder | `/media/tv` |

5. Add a library for music if needed:

| Setting | Value |
|---|---|
| Content type | `Music` |
| Display name | `Music` |
| Folder | `/media/music` |

6. Save.
7. Run `Scan All Libraries`.

Jellyfin uses `/media/...` because its container mount is intentionally read-focused and separate from the ARR `/data/...` path.

#### Check Jellyfin storage access

Run:

```bash
docker exec jellyfin ls -la /media
docker exec jellyfin ls -la /media/movies
docker exec jellyfin ls -la /media/tv
docker exec jellyfin ls -la /media/music
```

If Jellyfin cannot read the folders, fix the Jellyfin volume mount or storage permissions before adding more services.

#### Check hardware transcoding support

On the Docker VM:

```bash
ls -l /dev/dri
docker exec jellyfin ls -l /dev/dri
```

If both commands show render devices, hardware transcoding may be available.

If `/dev/dri` is missing on the host or inside the container:

1. Leave Jellyfin hardware transcoding disabled.
2. Use direct play for local testing.
3. Revisit Proxmox iGPU passthrough to VM `111` later.

Do not enable hardware transcoding until `/dev/dri` is visible inside the Jellyfin container.

For the tested Intel P630 passthrough, Quick Sync settings, local appdata
migration, reboot validation, and rollback procedure, follow
[Jellyfin Intel iGPU Passthrough And Local Appdata Guide](jellyfin-intel-igpu-passthrough-and-local-appdata-guide.md).

### 10.2 Configure Seerr

Open Seerr:

```text
http://192.168.1.20:5055
```

#### Complete first-run setup

1. Create or sign in with the admin account.
2. Choose Jellyfin as the media server type if prompted.
3. Keep the service LAN-only during initial setup.

#### Connect Jellyfin

Use:

| Setting | Value |
|---|---|
| Server name | `Jellyfin` |
| Server URL | `http://jellyfin:8096` |
| API key | Jellyfin API key |

If `http://jellyfin:8096` does not test successfully, try the LAN URL:

```text
http://192.168.1.20:8096
```

Prefer the Docker service name when it works because Seerr and Jellyfin are on the normal Docker network.

#### Connect Radarr

Use:

| Setting | Value |
|---|---|
| Server name | `Radarr` |
| Server URL | `http://192.168.1.20:7878` |
| API key | Radarr API key |
| Default root folder | `/data/media/movies` |
| Default quality profile | Choose intentionally |

Seerr is not in the VPN namespace, so it reaches Radarr through the Docker VM's LAN-published port.

#### Connect Sonarr

Use:

| Setting | Value |
|---|---|
| Server name | `Sonarr` |
| Server URL | `http://192.168.1.20:8989` |
| API key | Sonarr API key |
| Default root folder | `/data/media/tv` |
| Default quality profile | Choose intentionally |
| Language profile | Choose intentionally if shown |

Seerr is not in the VPN namespace, so it reaches Sonarr through the Docker VM's LAN-published port.

#### Set request behavior

Recommended starting point:

| Setting | Recommendation |
|---|---|
| Auto-approve admin requests | On if you are the only user |
| Auto-approve normal users | Off until the stack is proven |
| 4K requests | Off unless you have separate 4K profiles and storage plans |
| Notifications | Configure later |

Keep Seerr simple until the import workflow is proven.

## Phase 11: Test Locally End To End

Goal: prove that containers are healthy, VPN routing works, paths are shared correctly, imports work, and Jellyfin can play the result.

### 11.1 Check containers

Run:

```bash
cd /opt/stacks/arr-stack
docker compose ps
```

Expected:

- qBittorrent is running and healthy enough to serve the Web UI.
- Prowlarr is running.
- Radarr is running.
- Sonarr is running.
- Jellyfin is running.
- Seerr is running if already enabled.
- FlareSolverr can be running, but it should only be used for indexers that need it.

Check recent logs if anything is restarting:

```bash
docker compose logs --tail=100 qbittorrent
docker compose logs --tail=100 prowlarr
docker compose logs --tail=100 radarr
docker compose logs --tail=100 sonarr
docker compose logs --tail=100 jellyfin
docker compose logs --tail=100 seerr
```

### 11.2 Check storage mounts

Run:

```bash
df -h /mnt/main /mnt/media/data
```

Then check container views:

```bash
docker exec radarr ls -la /data/media/movies
docker exec sonarr ls -la /data/media/tv
docker exec qbittorrent ls -la /data/torrents
docker exec jellyfin ls -la /media/movies
docker exec jellyfin ls -la /media/tv
```

Stop here if any container cannot see its expected paths.

### 11.3 Check VPN egress

Run:

```bash
docker exec qbittorrent curl -4 -s https://ifconfig.me
docker exec prowlarr curl -4 -s https://ifconfig.me
docker exec radarr curl -4 -s https://ifconfig.me
docker exec sonarr curl -4 -s https://ifconfig.me
```

Expected:

- All four commands return public IPv4 addresses that belong to PIA or the configured VPN provider.
- None of the addresses are your home WAN IP.
- The addresses may differ because a VPN provider can use different exit IPs for separate HTTPS requests.

If any command returns your home WAN IP, do not download anything. Fix the container network namespace or VPN configuration first.

Optional comparison from the Docker VM host:

```bash
curl -4 -s https://ifconfig.me
```

The host IP can be different. The important part is that qBittorrent, Prowlarr, Radarr, and Sonarr share the VPN IP.

### 11.4 Test Radarr with one legal item

Use a legal/public-domain movie or your own media. Do not use copyrighted material you do not have rights to download.

In Radarr:

1. Open `Movies`.
2. Click `Add New`.
3. Search for the test item.
4. Choose root folder:

```text
/data/media/movies
```

5. Choose a quality profile.
6. Enable search only when you are ready.
7. Add the item.

In qBittorrent:

1. Confirm the torrent appears with category `movies`.
2. Confirm the save path is under:

```text
/data/torrents/movies
```

After completion, in Radarr:

1. Confirm the item imports.
2. Confirm the final file appears under:

```text
/data/media/movies
```

On the Docker VM:

```bash
docker exec radarr ls -la /data/media/movies
docker exec jellyfin ls -la /media/movies
```

### 11.5 Test Sonarr with one legal item

Use legal/public-domain TV content or your own media.

In Sonarr:

1. Open `Series`.
2. Click `Add New`.
3. Search for the test series.
4. Choose root folder:

```text
/data/media/tv
```

5. Choose a quality profile.
6. Enable search only when you are ready.
7. Add the item.

In qBittorrent:

1. Confirm the torrent appears with category `tv`.
2. Confirm the save path is under:

```text
/data/torrents/tv
```

After completion, in Sonarr:

1. Confirm the episode imports.
2. Confirm the final file appears under:

```text
/data/media/tv
```

On the Docker VM:

```bash
docker exec sonarr ls -la /data/media/tv
docker exec jellyfin ls -la /media/tv
```

### 11.6 Scan and play in Jellyfin

In Jellyfin:

1. Open the dashboard.
2. Open `Libraries`.
3. Run `Scan All Libraries`.
4. Open the Movies or TV library.
5. Confirm the test item appears.
6. Start playback from a LAN client.

For the first test, prefer a file that can direct play. Leave hardware transcoding disabled unless `/dev/dri` is confirmed inside the container.

### 11.7 Test Seerr requests

In Seerr:

1. Search for a legal test movie or show.
2. Request it.
3. Confirm the request appears in Radarr or Sonarr.
4. Confirm the root folder and quality profile are correct.
5. Confirm qBittorrent receives the correct category.

If Seerr cannot contact Radarr or Sonarr, verify it is using the LAN URLs:

```text
http://192.168.1.20:7878
http://192.168.1.20:8989
```

Do not change Seerr to `127.0.0.1` for Radarr or Sonarr. From Seerr's container, `127.0.0.1` means Seerr itself, not the VPN-shared ARR namespace.

### 11.8 Test remote management path

Use one of these approved paths:

| Remote method | Use for |
|---|---|
| Proxmox over Tailscale | Shell access and emergency management |
| SSH tunnel to Docker VM | Browser access to local service ports |
| Tailscale subnet route | Browser access to LAN services over Tailnet |
| Direct Docker VM Tailscale | Optional later improvement |

Keep these services private:

- qBittorrent
- Prowlarr
- Radarr
- Sonarr
- FlareSolverr

Only consider public exposure for Jellyfin or Seerr after local testing, authentication, updates, and reverse-proxy rules are reviewed.

## Troubleshooting

### qBittorrent test fails in Radarr or Sonarr

Check:

- qBittorrent Web UI is reachable at `http://192.168.1.20:8080`.
- Radarr/Sonarr download client host is `127.0.0.1`.
- Port is `8080`.
- Username and password are correct.
- Category is exactly `movies` for Radarr and `tv` for Sonarr.

Run:

```bash
docker exec radarr curl -s http://127.0.0.1:8080
docker exec sonarr curl -s http://127.0.0.1:8080
```

### Imports fail or copy instead of hardlink

Check:

- qBittorrent saves to `/data/torrents/...`.
- Radarr root is `/data/media/movies`.
- Sonarr root is `/data/media/tv`.
- All ARR containers see the same `/data` mount.
- The download and media folders are on the same filesystem.
- Hardlinks are enabled in Radarr/Sonarr media management.

Do not add remote path mappings for this layout unless the container paths actually differ.

### Prowlarr cannot reach Radarr or Sonarr

Use these URLs inside Prowlarr:

```text
http://127.0.0.1:7878
http://127.0.0.1:8989
```

Prowlarr shares the VPN namespace with Radarr and Sonarr, so `127.0.0.1` is correct there.

### Seerr cannot reach Radarr or Sonarr

Use these URLs inside Seerr:

```text
http://192.168.1.20:7878
http://192.168.1.20:8989
```

Seerr does not share the VPN namespace, so `127.0.0.1` is wrong for Radarr and Sonarr from Seerr.

### Jellyfin shows no media

Check:

- Jellyfin library paths are `/media/movies`, `/media/tv`, and `/media/music`.
- Files imported by ARR appear under `/data/media/...`.
- The Jellyfin container maps the same final media folders to `/media/...`.
- Jellyfin can read the files.

Run:

```bash
docker exec jellyfin ls -la /media/movies
docker exec jellyfin ls -la /media/tv
```

### VPN IP check fails

Do not download anything until this is fixed.

Check:

- qBittorrent VPN container logs.
- PIA credentials and region.
- Required VPN environment variables.
- Container network mode for Prowlarr, Radarr, and Sonarr.
- Whether the VPN provider is blocking the selected endpoint.

The required result is simple: qBittorrent, Prowlarr, Radarr, and Sonarr must all show VPN-provider public IPs and must not show your home WAN IP.

## Completion Checklist

- qBittorrent incomplete path is `/data/torrents/incomplete`.
- qBittorrent default save path is `/data/torrents`.
- qBittorrent category `movies` saves to `/data/torrents/movies`.
- qBittorrent category `tv` saves to `/data/torrents/tv`.
- Radarr root folder is `/data/media/movies`.
- Radarr qBittorrent category is `movies`.
- Sonarr root folder is `/data/media/tv`.
- Sonarr qBittorrent category is `tv`.
- Prowlarr app URL for Radarr is `http://127.0.0.1:7878`.
- Prowlarr app URL for Sonarr is `http://127.0.0.1:8989`.
- FlareSolverr is only used for indexers that require it.
- Jellyfin libraries point to `/media/movies`, `/media/tv`, and `/media/music`.
- Seerr uses `http://jellyfin:8096` or `http://192.168.1.20:8096` for Jellyfin.
- Seerr uses `http://192.168.1.20:7878` for Radarr.
- Seerr uses `http://192.168.1.20:8989` for Sonarr.
- qBittorrent, Prowlarr, Radarr, and Sonarr all show VPN-provider public IPs, not the home WAN IP.
- One legal test item downloads, imports, scans, and plays locally.
