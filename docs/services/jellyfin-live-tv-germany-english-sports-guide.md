# Jellyfin Live TV Stack For German, English, And Sports Channels

Last updated: 2026-06-30

This guide adds Live TV and public-broadcaster archive downloads to the current
homelab without changing the existing storage/app split:

1. TrueNAS remains storage only.
2. The Ubuntu Docker VM runs the TV/archive services.
3. Jellyfin remains the user-facing playback app.
4. Management stays LAN/Tailscale-only.
5. Public exposure is not required.
6. The setup uses only the Docker VM's existing network connection.
7. No extra cables, adapters, or physical TV hardware are part of this setup.

This is the no-extra-hardware path:

```text
Legal IPTV/public M3U/XMLTV source
-> Dispatcharr
-> Jellyfin Live TV through Dispatcharr M3U/XMLTV
-> Jellyfin clients
```

Optional local archive for public-broadcaster on-demand content:

```text
Official broadcaster episode page or other permitted source
-> MediathekView or yt-dlp
-> /mnt/media/data/media/tv/... or /mnt/media/data/media/movies/...
-> Jellyfin library
```

## Scope

Live TV in this guide means legal network IPTV/M3U/XMLTV through Dispatcharr.
Public-broadcaster downloads are saved as normal Jellyfin library media.

## Current Storage Assumption

This guide assumes the 3 TB media migration is complete or is the next storage
step to finish:

[TrueNAS 3 TB Media Pool Migration Guide](../os-and-virtualization/truenas-3tb-media-pool-migration-guide.md)

The new media disk is its own `media` pool for media files and downloads. It is
not an added vdev inside the protected `main` pool.

The current layout is:

| Purpose | TrueNAS path | Docker VM path |
|---|---|---|
| Appdata, service config, small source files | `/mnt/main` | `/mnt/main` |
| Media library, downloads, DVR output, Mediathek files | `/mnt/media/data` | `/mnt/media/data` |

The important rule from the migration guide is that Docker paths stay stable.
Containers and scripts should use:

```text
/mnt/media/data
```

They should not use the old one-pool source path:

```text
/mnt/main/media/data
```

On the Docker VM, verify the media mount before creating folders or deploying
Dispatcharr:

```bash
findmnt -T /mnt/media/data -o TARGET,SOURCE,FSTYPE,OPTIONS
df -h /mnt/main /mnt/media/data
```

Expected media source after the migration:

```text
192.168.1.10:/mnt/media/data
```

If `findmnt` still shows `192.168.1.10:/mnt/main/media/data`, finish the media
pool migration first. Do not deploy this stack against the old media location.

## Legal And Practical Boundary

This guide is for legal sources only:

- Legal IPTV/public M3U streams.
- Legal XMLTV/EPG sources.
- Official public broadcaster streams where the broadcaster permits that use.
- Public-broadcaster episode downloads only when local storage is allowed by
  the broadcaster's terms, the content license, or an explicit download option.

Do not use pirate IPTV playlists, scraped pay-TV channel lists, DRM bypasses,
CI+ workarounds, provider-app token scraping, or login/cookie workarounds. They
are not part of this homelab design and they make the server a legal and
security risk.

Important: open-source tools do not make the content open source. Bares fuer
Rares, ZDF content, sports broadcasts, and provider streams still have their own
rights and terms. The homelab can store files you are permitted to store; it
should not be used to bypass DRM, login controls, geo-blocking, expiring links,
or paid apps.

## Reality For German, English, And Sports Channels

| Goal | Realistic no-hardware path |
|---|---|
| German public channels | Good if legal public IPTV/M3U streams are available |
| German private channels | Only if the provider offers legal raw M3U/XMLTV access |
| English channels | Only through legal IPTV/public streams |
| Sports highlights and some live events | Possible through public/free legal streams |
| Premium sports such as DAZN, Sky/WOW, MagentaSport, RTL+ | Usually DRM/app based; keep these outside Jellyfin unless the provider gives legal M3U/XMLTV access |

Dispatcharr can organize legal raw streams, but it cannot make DRM/app-only
premium sports into Jellyfin-compatible Live TV.

## Source Strategy

Choose one primary source first. Do not try to combine everything on day one.

| Source | Best for | Notes |
|---|---|---|
| Legal IPTV/public M3U/XMLTV | German, English, news, niche, international, and some sports channels without hardware | Put Dispatcharr in front first. Only use sources that are explicitly legal for personal use. |
| Official broadcaster on-demand pages | Saving permitted public-broadcaster shows/movies into Jellyfin | Use MediathekView for discovery/manual downloads or yt-dlp for exact episode URLs. This is library media, not Live TV. |

Best practical recommendation:

```text
If you want Live TV:
  legal IPTV/public M3U/XMLTV
  -> Dispatcharr
  -> Jellyfin

If you want local public-broadcaster episodes:
  permitted episode URL/source
  -> MediathekView or yt-dlp
  -> /mnt/media/data/media/tv or /mnt/media/data/media/movies
  -> Jellyfin
```

## Legal M3U Starter Sources

Start with public playlists that you can review in Dispatcharr. The best current
starter index is iptv-org because it publishes M3U playlists by country,
language, and category. iptv-org describes itself as a collection of publicly
available IPTV channels and says the repository stores links, not video files.

Use this as a review queue, not as proof that every channel is usable forever.
Disable dead, questionable, geo-blocked, duplicate, or irrelevant channels in
Dispatcharr before exporting to Jellyfin.

Important: public playlist indexes can still contain premium-sounding channel
names, dead links, mirrors, or streams that are not appropriate for your use.
For a strict legal posture, copy only verified public/free channels into your
own curated M3U or disable everything questionable inside Dispatcharr.

| Priority | Source | Dispatcharr M3U URL | Use |
|---:|---|---|---|
| 1 | iptv-org Germany | `https://iptv-org.github.io/iptv/countries/de.m3u` | First German test source |
| 2 | iptv-org German language | `https://iptv-org.github.io/iptv/languages/deu.m3u` | German-language channels beyond Germany |
| 3 | iptv-org English language | `https://iptv-org.github.io/iptv/languages/eng.m3u` | English channels |
| 4 | iptv-org Sports | `https://iptv-org.github.io/iptv/categories/sports.m3u` | Free/public sports and sports-adjacent channels |
| 5 | iptv-org News | `https://iptv-org.github.io/iptv/categories/news.m3u` | News channels |
| 6 | iptv-org Public | `https://iptv-org.github.io/iptv/categories/public.m3u` | Public/community channels |

Avoid importing the all-channels playlist on day one:

```text
https://iptv-org.github.io/iptv/index.m3u
```

It is useful for testing, but too noisy for a clean Dispatcharr/Jellyfin setup.

Create a local note with the starter URLs:

```bash
sudo -u mediauser tee /mnt/main/appdata/live-tv/sources/legal-m3u-starter-sources.md >/dev/null <<'EOF'
# Legal M3U Starter Sources

Reviewed on: 2026-06-28

- Germany: https://iptv-org.github.io/iptv/countries/de.m3u
- German language: https://iptv-org.github.io/iptv/languages/deu.m3u
- English language: https://iptv-org.github.io/iptv/languages/eng.m3u
- Sports: https://iptv-org.github.io/iptv/categories/sports.m3u
- News: https://iptv-org.github.io/iptv/categories/news.m3u
- Public: https://iptv-org.github.io/iptv/categories/public.m3u

Legal rule:
- Use only public/free streams and provider-authorized M3U/XMLTV sources.
- Disable channels that are dead, questionable, geo-blocked, DRM/app-only, or
  not useful for this household.
EOF
```

Quickly test the playlist headers from the Docker VM:

```bash
for url in \
  https://iptv-org.github.io/iptv/countries/de.m3u \
  https://iptv-org.github.io/iptv/languages/deu.m3u \
  https://iptv-org.github.io/iptv/languages/eng.m3u \
  https://iptv-org.github.io/iptv/categories/sports.m3u \
  https://iptv-org.github.io/iptv/categories/news.m3u \
  https://iptv-org.github.io/iptv/categories/public.m3u
do
  printf '\n== %s ==\n' "$url"
  curl -fsSL "$url" | sed -n '1,12p'
done
```

If a playlist fails to download from the Docker VM, do not add it to
Dispatcharr yet. Fix DNS/networking first.

If the command prints an M3U header and channel entries like this:

```text
#EXTM3U
#EXTINF:-1 tvg-id="3sat.de@SD" ... group-title="General",3sat (720p) [Geo-blocked]
https://...
```

that proves only that the Docker VM can download the public playlist. It does
not prove Dispatcharr is using Gluetun. Gluetun routing is checked later from
inside `live-tv-gluetun` and `dispatcharr`.

Treat premium-sounding entries in public playlists as review items, not as
approved channels. A public playlist may contain names such as Sky, DAZN, WOW,
13th Street, or other pay-TV brands. Keep them disabled unless you can verify
that the source is an official free/public stream or a provider-authorized raw
M3U/XMLTV feed for your account.

Strict curated-file option:

```bash
sudo -u mediauser tee /mnt/main/appdata/live-tv/sources/curated-public.m3u >/dev/null <<'EOF'
#EXTM3U
# Add only channels you have verified are public/free and appropriate to use.
# Example shape:
#EXTINF:-1 group-title="Public",Example Public Channel
#https://example.invalid/live/stream.m3u8
EOF
```

Then import it through Dispatcharr's `Upload files` control, or enable
mapped-file auto-import for `/data/m3us`, instead of importing a large public
index directly.

### M3U Source Naming Plan

Use clear names so you can tell where each channel came from when something
breaks later.

| Dispatcharr source name | M3U URL | Add when |
|---|---|---|
| `Ger - iptv-org Germany Review` | `https://iptv-org.github.io/iptv/countries/de.m3u` | First test source |
| `GerLang - iptv-org German Review` | `https://iptv-org.github.io/iptv/languages/deu.m3u` | After Germany is clean |
| `Eng - iptv-org English Review` | `https://iptv-org.github.io/iptv/languages/eng.m3u` | When you want English channels |
| `Sports - iptv-org Review` | `https://iptv-org.github.io/iptv/categories/sports.m3u` | After basic playback works |
| `News - iptv-org Review` | `https://iptv-org.github.io/iptv/categories/news.m3u` | Optional |
| `Public - iptv-org Review` | `https://iptv-org.github.io/iptv/categories/public.m3u` | Optional |
| `Manual - Curated Public` | uploaded `/mnt/main/appdata/live-tv/sources/curated-public.m3u` | Strictest option |

Add sources one at a time. The clean workflow is:

1. Add `Ger - iptv-org Germany Review`.
2. Enable only a few reviewed groups.
3. Create or auto-sync a small channel set.
4. Test playback in Dispatcharr.
5. Confirm the Dispatcharr M3U export opens from the Docker VM.
6. Add it to Jellyfin.
7. Only then add `Eng`, `Sports`, or another source.

Do not import every playlist at once. It makes duplicates, guide matching, and
bad-channel cleanup much harder.

### EPG/XMLTV

Prefer XMLTV/EPG from the same provider as the M3U source when available.
iptv-org publishes EPG tooling, but it is a separate workflow from the M3U
playlist URLs. Do not block the first Live TV test on perfect EPG data. First
make one legal channel play, then add guide data.

## Why Not Just Add M3U Directly To Jellyfin?

Jellyfin supports M3U sources directly, so the simplest legal M3U setup can
skip a middle layer. For this homelab, Dispatcharr is still the better default
because it gives you one managed place for source cleanup, grouping, EPG
control, channel numbering, and a stable export for Jellyfin.

| Need | Jellyfin direct | Dispatcharr first |
|---|---:|---:|
| Simple M3U import | Good | Good |
| Legal IPTV source cleanup | Basic | Strong |
| EPG source control | Limited | Strong |
| Channel groups | Basic | Strong |
| Stable channel numbering | Basic | Strong |
| Recording/DVR management, if enabled | Basic | Better |
| Export one clean feed to Jellyfin | No | Yes |

## Storage Layout

Keep Dispatcharr's active database/appdata on local Docker VM block storage.
Dispatcharr AIO runs PostgreSQL under `/data/db` and needs normal Linux
ownership changes there. Do not put Dispatcharr `/data` on a TrueNAS NFS mount.

Keep small source files and Mediathek metadata on the protected `main` pool, and
put all large media/archive output on the dedicated `media` pool:

```text
/srv/appdata/
  dispatcharr/

/mnt/main/appdata/live-tv/
  mediathek/
    urls/
    logs/
    pip-cache/
  sources/

/mnt/main/backups/docker-volumes/
  dispatcharr/

/mnt/media/data/live-tv/
  dispatcharr-recordings/

/mnt/media/data/media/tv/
  Bares fuer Rares/

/mnt/media/data/media/movies/
  public-broadcaster/
```

Use `/mnt/main/appdata/live-tv/sources` for legal M3U/XMLTV files that you are
allowed to store locally.

Use `/srv/appdata/dispatcharr` for Dispatcharr's active `/data` volume. This is
local VM storage, not TrueNAS NFS. It should be protected by Proxmox VM backups
and periodic archive backups to `/mnt/main/backups/docker-volumes/dispatcharr`.

Use `/mnt/main/appdata/live-tv/mediathek` for small text files, URL lists,
download archives, logs, and the yt-dlp virtual environment.

Use `/mnt/media/data/live-tv/dispatcharr-recordings` for Dispatcharr DVR output
if you enable DVR features.

Use `/mnt/media/data/media/tv/Bares fuer Rares` for saved Bares fuer Rares
episodes or similar TV shows that Jellyfin should scan as library media. The
ASCII folder name is intentional so shell commands stay simple.

Use `/mnt/media/data/media/movies/public-broadcaster` for permitted standalone
films or documentaries from public-broadcaster sources.

Do not put Dispatcharr recordings, Bares fuer Rares downloads, or other large
video files under `/mnt/main`. The `main` mirror is for appdata and important
data; the dedicated `media` pool is for media files.

## Deployment Order

Do this after the current ARR/local media stack is stable:

1. Finish Docker VM firewall and monitoring.
2. Confirm Jellyfin works locally.
3. Confirm you have a legal no-hardware source: M3U/XMLTV, public IPTV, or
   exact public-broadcaster episode URLs where local storage is permitted.
4. Deploy Dispatcharr.
5. Add and clean the legal live source in Dispatcharr.
6. Export Dispatcharr M3U/XMLTV to Jellyfin.
7. Add MediathekView or yt-dlp only if you want local on-demand files.
8. Add Uptime Kuma checks.
9. Add backups for local Dispatcharr appdata and Mediathek appdata.

Do not expose Dispatcharr or Jellyfin Live TV publicly just to make TV work.
Use LAN or Tailscale.

## Phase 1: Create Folders

Run on the Ubuntu Docker VM:

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

sudo touch /srv/appdata/dispatcharr/.write-test
sudo rm /srv/appdata/dispatcharr/.write-test

sudo -u mediauser touch /mnt/main/appdata/live-tv/.write-test
sudo -u mediauser rm /mnt/main/appdata/live-tv/.write-test

sudo -u mediauser touch /mnt/media/data/live-tv/dispatcharr-recordings/.write-test
sudo -u mediauser rm /mnt/media/data/live-tv/dispatcharr-recordings/.write-test

sudo -u mediauser touch "/mnt/media/data/media/tv/Bares fuer Rares/.write-test"
sudo -u mediauser rm "/mnt/media/data/media/tv/Bares fuer Rares/.write-test"
```

If `/srv/appdata` is missing or mounted as `nfs`, `nfs4`, or `autofs`, stop and
create/use a local Docker VM appdata disk first. Follow the same local appdata
pattern used for Jellyfin.

If the `/mnt/main` or `/mnt/media/data` commands fail, fix TrueNAS permissions
or NFS mapping before deploying containers. If `/mnt/media/data` is not mounted from
`192.168.1.10:/mnt/media/data`, finish the media pool migration first.

## Phase 2: Deploy Dispatcharr

Create the stack directory:

```bash
sudo mkdir -p /opt/stacks/live-tv
sudo chown -R "$USER":"$USER" /opt/stacks/live-tv
cd /opt/stacks/live-tv
```

Create `.env`:

```bash
cat > .env <<'EOF'
TZ=Europe/Berlin
SERVER_IP=192.168.1.20

# Dispatcharr publishes Docker tags as latest, dev, and commit SHA.
# GitHub release tags such as v0.27.1 are not GHCR image tags.
DISPATCHARR_VERSION=latest
EOF

chmod 600 .env
```

Create `docker-compose.yml`:

```bash
cat > docker-compose.yml <<'EOF'
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
EOF
```

Before starting, note that Dispatcharr's GitHub releases and GHCR image tags
are not the same thing. The official Docker image uses:

| Tag | Use |
|---|---|
| `latest` | Normal deployment from the main branch |
| `dev` | Development branch; avoid for this homelab unless testing |
| Commit SHA | Advanced pinning if you intentionally track a specific image build |

Do not set `DISPATCHARR_VERSION` to a GitHub release such as `v0.27.1`; that
tag does not currently exist on GHCR and Docker will fail to pull it.

Validate and start Dispatcharr:

```bash
docker compose config
docker compose up -d dispatcharr
docker compose ps dispatcharr
```

Open Dispatcharr locally:

```text
http://192.168.1.20:9191
```

Create an admin username and password during first setup. Keep Dispatcharr
LAN/Tailscale-only.

The official Dispatcharr compose does not use the repo's normal `PUID`/`PGID`
pattern. For this homelab, Dispatcharr writes its active appdata to local
storage at `/srv/appdata/dispatcharr`. TrueNAS NFS is still used for read-only
source files and media output, but not for Dispatcharr's PostgreSQL database.

## Phase 3: Configure Dispatcharr

The exact UI can change between Dispatcharr releases, so treat this as the
target workflow rather than a pixel-by-pixel walkthrough. The goal is to import
one legal source, curate it down to a small working channel list, then export
one clean M3U/XMLTV pair to Jellyfin.

### 3.1 First Login

Open:

```text
http://192.168.1.20:9191
```

Create the first admin user. Use a real password manager entry even though this
stays LAN/Tailscale-only.

After login, find these areas in the left navigation or getting-started screen:

| Dispatcharr area | Purpose |
|---|---|
| `M3U & EPG Manager` | Add M3U playlist sources and XMLTV/EPG sources |
| `Channels` | Create/enable final channels and copy Jellyfin export URLs |
| `TV Guide` | Check whether EPG data is mapped correctly |
| `DVR` | Optional recording settings if you later enable recordings |

### 3.2 Add One M3U Source

Start with one source only. Do not add Germany, English, sports, news, and
public playlists all at once.

Use one of these:

| Option | Value |
|---|---|
| Public Germany test | URL field: `https://iptv-org.github.io/iptv/countries/de.m3u` |
| Strict curated file | Upload the file in the `Upload files` field, or use mapped-file auto-import from `/data/m3us` |

Do not type `/sources/curated-public.m3u`, `/data/m3us/curated-public.m3u`,
or any other filesystem path into the `URL` field. The `URL` field is for a web
URL such as `https://...`. A local M3U file must be uploaded through the file
upload control, or placed in `/data/m3us` with Dispatcharr's mapped-file
auto-import enabled under `Settings -> Stream Settings`.

In Dispatcharr:

1. Go to `M3U & EPG Manager`.
2. Click `Add M3U`.
3. Set `Name` to something clear, such as `iptv-org Germany Review`.
4. Set `Account Type` to `Standard` or `Standard M3U`. Do not select
   `Xtream Codes`.
5. If using iptv-org, paste
   `https://iptv-org.github.io/iptv/countries/de.m3u` into `URL`.
6. If using a curated local file, leave `URL` empty and use `Upload files` to
   select the `.m3u` file from your browser.
7. Leave `Max Streams` at `0` unless the source explicitly gives you a limit.
8. Leave VOD scanning off. VOD scanning is only for Xtream Codes accounts, and
   this guide uses Dispatcharr for Live TV, not VOD.
9. Set a conservative refresh interval, such as 24 hours, after the first import
   works.
10. Make sure `Is Active` is enabled.
11. Save the M3U account.

Correct field values for the first iptv-org test:

| Field | Value |
|---|---|
| `Name` | `Ger - iptv-org Germany Review` |
| `Account Type` | `Standard` or `Standard M3U` |
| `URL` | `https://iptv-org.github.io/iptv/countries/de.m3u` |
| `Upload files` | Empty |
| `Max Streams` | `0` |
| `Enable VOD Scanning` | Off/not used |
| `Is Active` | On |

Use the same field pattern for additional public playlists. Change only the
source name and URL:

| Source goal | `Name` | `Account Type` | `URL` | First channel range |
|---|---|---|---|---:|
| More German-language channels | `GerLang - iptv-org German Review` | `Standard` or `Standard M3U` | `https://iptv-org.github.io/iptv/languages/deu.m3u` | 100 |
| English channels | `Eng - iptv-org English Review` | `Standard` or `Standard M3U` | `https://iptv-org.github.io/iptv/languages/eng.m3u` | 200 |
| Sports review | `Sports - iptv-org Review` | `Standard` or `Standard M3U` | `https://iptv-org.github.io/iptv/categories/sports.m3u` | 300 |
| News review | `News - iptv-org Review` | `Standard` or `Standard M3U` | `https://iptv-org.github.io/iptv/categories/news.m3u` | 400 |
| Public/community review | `Public - iptv-org Review` | `Standard` or `Standard M3U` | `https://iptv-org.github.io/iptv/categories/public.m3u` | 600 |

For every one of these:

1. Leave username and password empty.
2. Leave Xtream Codes fields empty.
3. Leave VOD scanning off.
4. Set refresh to 24 hours only after the first import works.
5. Disable new groups by default.
6. Review groups and channels before they reach Jellyfin.

Wrong values that cause the errors you saw:

| Wrong setting | Result |
|---|---|
| `Account Type = Xtream Codes` | Dispatcharr expects a provider panel login and logs `Missing username or password for Xtream Codes account`. |
| `URL = /sources/curated-public.m3u` | Dispatcharr tries to download a filesystem path like a URL and logs `download failed or other error`. |
| `URL = /data/m3us/curated-public.m3u` | Same problem: it is a local path, not an HTTP(S) URL. |

If you already created a broken source named `Ger`, edit it rather than adding
more copies:

1. Go to `M3U & EPG Manager`.
2. Find `Ger`.
3. Click the edit icon in the `Actions` column.
4. Change `Account Type` to `Standard` or `Standard M3U`.
5. Clear any username/password/profile fields left from Xtream Codes mode.
6. Put `https://iptv-org.github.io/iptv/countries/de.m3u` in `URL`.
7. Clear `Upload files` unless you are uploading a local file instead.
8. Save.
9. Click the refresh icon for that M3U account.

If the UI does not let you cleanly switch from `Xtream Codes` to `Standard` or
`Standard M3U`, delete the broken `Ger` account and recreate it as a standard
M3U account.

### 3.3 Configure `M3U Group Filter & Auto Channel Sync`

After the M3U account imports, open the source's `Groups`, `Group Filter`,
`M3U Group Filter & Auto Channel Sync`, or similarly named screen before
creating channels.

This screen controls two separate things:

| Setting area | What it does |
|---|---|
| Group enable/disable | Decides which source groups are allowed into your clean channel list. |
| Auto Channel Sync | Automatically creates/removes Dispatcharr channels for streams in enabled groups. |
| Starting channel number | Assigns the first channel number used when auto-sync creates channels for that group. |
| New group behavior | Decides whether new groups discovered on later scans are enabled automatically. |
| Orphan cleanup | Removes auto-synced channels when the source stream disappears from that provider. |

Recommended default for public playlist sources:

| UI setting | Recommended value | Why |
|---|---|---|
| `Automatically enable new groups discovered on future scans` | Off | New public playlist groups should appear disabled until you review them. |
| `Auto-sync orphan cleanup` | On | Removes channels that were auto-created from streams that no longer exist. |
| `Auto Channel Sync` per reviewed group | On only for groups you intentionally want | Avoids filling Jellyfin with hundreds of unwanted channels. |
| `Auto Channel Sync` for unknown/noisy groups | Off | Keeps junk, duplicates, and questionable streams out of Jellyfin. |

For the first Germany source, start conservatively:

1. Leave `Automatically enable new groups discovered on future scans` disabled.
2. Enable `Auto-sync orphan cleanup`.
3. Review the group list.
4. Enable only one or two groups that clearly contain public/free channels you
   want to test.
5. Leave shopping, adult, unknown, test, radio, religious, and irrelevant groups
   disabled unless you intentionally want them.
6. Set a starting channel number for each enabled group.
7. Save the group settings.
8. Refresh/sync the M3U account.

Recommended starting numbers:

| Source group type | Auto Channel Sync | Start number |
|---|---|---:|
| German/public general | On after review | 1 |
| German regional/public | On after review | 100 |
| English | Off until later | 200 |
| Sports | Off until later | 300 |
| News | On only if wanted | 400 |
| Kids | Off until later | 500 |
| Test/temporary | Usually off | 900 |

If a public playlist uses broad group names such as `General`, `Entertainment`,
`News`, `Shop`, or `Undefined`, do not enable all of them at once. Enable one
group, sync, inspect the created channels, then continue.

For a strict manual setup, leave `Auto Channel Sync` disabled for every group.
Then create channels manually from the streams you reviewed. This is slower but
produces the cleanest Jellyfin Live TV guide.

Good first-pass settings for your `Ger` source:

| Field | Value |
|---|---|
| Source name | `Ger - iptv-org Germany Review` |
| Automatically enable new groups discovered on future scans | Off |
| Auto-sync orphan cleanup | On |
| Auto Channel Sync for reviewed public/general group | On |
| Start number for public/general group | `1` |
| Auto Channel Sync for `Shop`/shopping group | Off |
| Auto Channel Sync for `Undefined`/unknown group | Off |
| Auto Channel Sync for sports | Off until you review individual streams |

What to expect after saving:

1. Dispatcharr should create channels only for enabled auto-sync groups.
2. Disabled groups should remain visible in the M3U group screen but should not
   create Jellyfin channels.
3. Future newly discovered groups should appear disabled by default.
4. If a stream disappears from the source, orphan cleanup should remove the
   auto-synced channel on a later sync.

If the channel list explodes with hundreds of entries, stop and clean it before
connecting Jellyfin:

1. Disable `Auto Channel Sync` for noisy groups.
2. Save.
3. Run M3U refresh/sync again.
4. Confirm orphan cleanup removed the auto-created junk channels.
5. If cleanup does not remove them, delete unwanted channels manually from
   `Channels` before adding the M3U export to Jellyfin.

### 3.4 Filter The Source Before Creating Channels

If Dispatcharr offers source filters, use them to reduce noise before channels
are created. Filters are especially useful with public playlist indexes.

Use filters carefully. Start with broad review filters, then tighten them after
you see what the playlist contains.

Examples of streams to exclude:

| Reason | Example filter idea |
|---|---|
| Clearly unusable | `dead|offline|test` |
| Geo-blocked until reviewed | `geo-blocked|geo blocked` |
| Premium/app-only names | `DAZN|Sky|WOW|MagentaSport|RTL\+` |
| Adult content | `adult|xxx|18\+` |
| Shopping channels, if unwanted | `shop|shopping|teleshopping` |

Then refresh or rescan the M3U account. The expected result is a shorter stream
list that only contains channels worth reviewing.

Do not rely on filters as the legal decision. If a channel name or source looks
questionable, disable it or leave it out.

### 3.5 Create The First Clean Channels

Go to `Channels`.

You should see imported streams from the M3U source. For the first pass, create
only a small test set:

| Channel type | How many to create first |
|---|---:|
| German public/general | 3-5 |
| News | 1-2 |
| English | 0-2 |
| Sports | 0-1 |

For each channel:

1. Search for the stream by name.
2. Use `Create New Channel` or the equivalent action.
3. Set a stable channel number.
4. Put it in the correct group.
5. Prefer a clean display name, for example `3sat HD` instead of a long
   provider-specific stream name.
6. Save the channel.

If the same channel exists in multiple qualities, start with the most reliable
720p or 1080p stream. Do not keep five duplicates in Jellyfin.

If Dispatcharr supports backup streams, add a backup only when both streams are
clearly valid public/free sources. Do not mix questionable mirrors into a clean
channel just because they play.

### 3.6 Add EPG/XMLTV

EPG is optional for the first playback test. It is better to get one channel
playing first than to spend hours fixing guide data before playback works.

When you do add guide data:

1. Go to `M3U & EPG Manager`.
2. Click `Add EPG`.
3. Give it a clear name, such as `iptv-org EPG` or the provider name.
4. Enter the XMLTV URL from the same source/provider when available.
5. Save and let Dispatcharr import the guide.
6. Go to `TV Guide` and confirm that at least one test channel has programme
   data.

If auto-matching fails, map only the channels you are actually keeping. Do not
try to clean guide data for channels that will be disabled.

For a first test, these states are acceptable:

| State | Acceptable? | Action |
|---|---|---|
| Channel plays, no guide yet | Yes | Add Jellyfin after playback works |
| Guide exists for some channels only | Yes | Map important channels manually |
| Guide is empty for every channel | Maybe | Continue playback test, fix EPG later |
| Guide maps to wrong channels | No | Fix mapping before family use |

### 3.7 Playback Test Inside Dispatcharr

Before touching Jellyfin, test playback in Dispatcharr if the UI offers a player
or preview action.

For each test channel:

1. Start playback.
2. Wait at least 30 seconds.
3. Stop playback.
4. Try one channel from each group you plan to keep.

Remove or disable channels that:

- never start;
- buffer constantly;
- redirect to unrelated content;
- require cookies, tokens, DRM, or a provider app;
- show content that does not match the channel name;
- only work through a suspicious mirror.

### 3.8 Confirm Export URLs From The Docker VM

In Dispatcharr, go to `Channels` and copy the exported `M3U` URL. If EPG is
configured, also copy the exported `EPG` or `XMLTV` URL.

Test the M3U export from the Docker VM:

```bash
curl -fsS "PASTE_DISPATCHARR_M3U_EXPORT_URL_HERE" | sed -n '1,40p'
```

Expected:

```text
#EXTM3U
#EXTINF...
```

If EPG is configured, test XMLTV:

```bash
curl -fsS "PASTE_DISPATCHARR_XMLTV_EXPORT_URL_HERE" | sed -n '1,40p'
```

Expected:

```text
<?xml
<tv...
```

If the M3U export is empty, you have not created/enabled final channels yet. Go
back to the `Channels` page and confirm the channels are active.

### 3.9 Dispatcharr Proxy/VPN Check

If you use the optional Gluetun VPN mode later, inspect the exported M3U before
adding it to Jellyfin:

```bash
curl -fsS "PASTE_DISPATCHARR_M3U_EXPORT_URL_HERE" | grep -E 'https?://' | head -20
```

If the stream URLs point back to Dispatcharr, Jellyfin playback should flow
through Dispatcharr. If the stream URLs point directly to upstream domains,
Jellyfin may bypass Dispatcharr for playback and the upstream source may see
Jellyfin's normal home IP.

For the first non-VPN setup this is less important, but it matters if your goal
is VPN-routed stream egress.

### 3.10 Add More Sources Later

Only after the first German source is cleaned and playing should you add more
sources:

| Next source | Add when |
|---|---|
| `languages/deu.m3u` | You want more German-language public channels |
| `languages/eng.m3u` | You want English channels |
| `categories/news.m3u` | You want more news channels |
| `categories/sports.m3u` | You accept that most premium sports will not be usable |
| `categories/public.m3u` | You want public/community channels |

After each new source:

1. Import one source.
2. Disable unwanted groups.
3. Apply filters.
4. Create only the channels you want.
5. Test playback.
6. Confirm the export still opens from the Docker VM.

Do not add another source until the previous one is clean.

## Phase 4: Connect Dispatcharr To Jellyfin

Jellyfin can consume Dispatcharr through M3U/XMLTV. Prefer the URLs shown in
the Dispatcharr UI over hard-coded examples.

Note: Jellyfin uses TV-source terminology for M3U. In this guide, only the
software M3U source is used.

In Jellyfin:

1. Go to `Dashboard -> Live TV`.
2. Click `Add tuner device`.
3. Select Jellyfin's `M3U Tuner` option.
4. Paste the M3U URL from Dispatcharr.
5. Add TV guide data provider.
6. Select `XMLTV`.
7. Paste the XMLTV URL from Dispatcharr.
8. Save.
9. Wait for guide refresh.
10. Map channels if Jellyfin does not map them automatically.

If Jellyfin cannot reach Dispatcharr, test from the Docker VM first:

```bash
curl -fsS "http://192.168.1.20:9191" >/dev/null
```

Then copy the exact export URL from the Dispatcharr UI and test that URL with
`curl` before changing Jellyfin again.

## Phase 5: Optional Local Mediathek Archive

This is for saving permitted public-broadcaster on-demand videos, such as Bares
fuer Rares episodes, into Jellyfin. It is separate from Live TV and does not
need Dispatcharr or the Live TV stack.

Use the lightest workflow first:

| Workflow | Best for | Notes |
|---|---|---|
| MediathekView on a desktop | Manual discovery and occasional downloads | Open source and easy to search. Save directly to the SMB share that points at `/mnt/media/data/media/...`. |
| yt-dlp on the Docker VM | Repeatable downloads from exact episode URLs | Better for server-side saving. Test one episode URL first. |

Do not point automation at a whole series page until you know how many videos it
will resolve. Start with one exact episode URL and use simulation first.

### Install yt-dlp On The Docker VM

Run on the Ubuntu Docker VM:

```bash
sudo apt-get update
sudo apt-get install -y ffmpeg python3-venv

sudo -u mediauser python3 -m venv /mnt/main/appdata/live-tv/mediathek/venv
sudo -u mediauser env PIP_CACHE_DIR=/mnt/main/appdata/live-tv/mediathek/pip-cache \
  /mnt/main/appdata/live-tv/mediathek/venv/bin/python -m pip install -U pip yt-dlp

sudo -u mediauser /mnt/main/appdata/live-tv/mediathek/venv/bin/yt-dlp --version
```

Create a small helper script:

```bash
cd /opt/stacks/live-tv

cat > download-medithek-url.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

URL="${1:?Usage: download-medithek-url.sh <exact-episode-url>}"
APPDATA="/mnt/main/appdata/live-tv/mediathek"
OUTPUT_ROOT="/mnt/media/data/media/tv/Bares fuer Rares"
YTDLP="$APPDATA/venv/bin/yt-dlp"

sudo -u mediauser "$YTDLP" \
  --no-playlist \
  --download-archive "$APPDATA/bares-fuer-rares.downloaded.txt" \
  --write-info-json \
  --write-thumbnail \
  --embed-metadata \
  --embed-thumbnail \
  --merge-output-format mkv \
  --restrict-filenames \
  -o "$OUTPUT_ROOT/%(title).180B [%(id)s].%(ext)s" \
  "$URL"
EOF

chmod +x download-medithek-url.sh
```

Before downloading, simulate the exact episode URL:

```bash
sudo -u mediauser /mnt/main/appdata/live-tv/mediathek/venv/bin/yt-dlp \
  --simulate \
  --no-playlist \
  "PASTE_EXACT_EPISODE_URL_HERE"
```

If the simulation resolves one expected video, download it:

```bash
./download-medithek-url.sh "PASTE_EXACT_EPISODE_URL_HERE"
```

Then add a Jellyfin library:

| Jellyfin setting | Value |
|---|---|
| Library name | `Public Mediathek` or `Bares fuer Rares` |
| Content type | Shows, or Mixed Movies and Shows if metadata matching is poor |
| Folder | `/mnt/media/data/media/tv/Bares fuer Rares` |

For standalone films or documentaries, save them under
`/mnt/media/data/media/movies/public-broadcaster` and add that path to a Movies
or Mixed library.

### MediathekView Desktop Option

If you prefer manual control, install MediathekView on a desktop/laptop, search
for the episode, and save only permitted downloads directly to the SMB share for
the Jellyfin media folder. This keeps the server simple and still uses no new
hardware cables.

Use the same legal boundary: do not download or archive content when the
broadcaster terms or the page itself does not allow local storage.

## Channel Plan

Use stable channel ranges so family members can find channels consistently.

| Range | Group |
|---:|---|
| 1-99 | Main German channels |
| 100-199 | German regional/public channels |
| 200-299 | English channels |
| 300-399 | Sports |
| 400-499 | News |
| 500-599 | Kids |
| 900-999 | Test, radio, temporary, or disabled review |

Do not spend time perfecting channel numbers before source playback and EPG
work. First make playback stable.

## Sports Setup Notes

Sports is the hardest part because premium rights are usually in DRM apps, not
raw M3U streams.

Good Jellyfin-compatible sports sources:

- Free sports or sports-heavy channels available through your legal IPTV source.
- Live sports on public broadcasters when a legal raw stream is available.
- Legal provider M3U streams if your provider explicitly offers them.

Poor Jellyfin targets:

- DAZN app streams.
- Sky/WOW app streams.
- MagentaSport app streams.
- RTL+ app streams.
- Any paid provider where the only access path is an app, browser, receiver,
  account cookie, rotating token, or DRM.

Keep those services on their official apps. Do not design the homelab around
bypassing DRM.

For your specific goal of Sky TV, DAZN, and mostly sports:

| Goal | Practical Jellyfin path |
|---|---|
| DAZN live channels/events | Use the official DAZN app unless DAZN or your TV provider gives you an authorized raw M3U/XMLTV feed. Do not use account cookies, browser tokens, or DRM workarounds. |
| Sky/WOW live sports | Use Sky/WOW apps or official receiver/app access unless your provider explicitly supplies legal M3U/XMLTV. Public playlist entries with Sky-like names should stay disabled unless verified. |
| Free sports channels | Add `Sports - iptv-org Review`, then keep only channels that are public/free, play reliably, and are relevant. |
| Public broadcaster sports events | Use public broadcaster streams when available and permitted. These may appear under general German channels rather than the sports category. |
| Sports recordings | Enable DVR only after playback is stable. Use 5 minutes pre-padding and 30-60 minutes post-padding. |

Recommended sports workflow:

1. Make `Ger - iptv-org Germany Review` work first.
2. Keep German public channels that sometimes carry sports, such as ARD/ZDF or
   regional public channels when their streams are legal and working.
3. Add `Sports - iptv-org Review`.
4. Filter out `DAZN|Sky|WOW|MagentaSport|RTL+` unless you have verified a legal
   source.
5. Create only a few sports channels in the `300-399` range.
6. Test each channel for at least 30 seconds in Dispatcharr, then Jellyfin.
7. Remove channels that are dead, geo-blocked, app-only, or mismatched.

## Firewall Rules

Keep Dispatcharr private.

If UFW is enabled on the Docker VM:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 9191 proto tcp comment 'Dispatcharr web'
```

If Docker VM Tailscale is later installed, add Tailscale source rules only for
trusted tailnet clients. Do not expose this port through Cloudflare Tunnel or
router port forwards.

## Optional VPN Egress With Gluetun

Default recommendation: run Dispatcharr without VPN first. Legal public IPTV and
public-broadcaster streams normally work like ordinary web traffic. A VPN is
only useful if you intentionally want Dispatcharr's upstream M3U/XMLTV/stream
requests to egress through your VPN provider.

Do not attach Dispatcharr to the existing `debrid-gluetun` container. The debrid
stack is intentionally independent and may be restarted, tested, or rebuilt for
RDTClient. Reuse the same known-good Gluetun settings, but run a separate Live
TV Gluetun gateway in `/opt/stacks/live-tv`.

Only use this variant if all of these are true:

- Dispatcharr is the component fetching or proxying the upstream streams.
- Jellyfin uses Dispatcharr-generated playback URLs, not the original upstream
  stream URLs.
- You have already tested normal non-VPN Dispatcharr playback.
- You are not using the VPN to bypass DRM, paid apps, account controls, or
  geo-blocking rules.

Create the optional Gluetun config directory:

```bash
sudo -u mediauser mkdir -p /mnt/main/appdata/live-tv/gluetun
```

Add these values to `/opt/stacks/live-tv/.env`, reusing the same PIA account
style from the debrid stack:

```env
GLUETUN_VERSION=latest
PIA_USER=p1234567
PIA_PASS=replace_with_your_pia_password
PIA_REGION=Netherlands
DNS_UPSTREAM_RESOLVER_TYPE=doh
DNS_UPSTREAM_RESOLVERS=cloudflare
```

Then replace the direct Dispatcharr compose with this VPN-routed variant:

```yaml
services:
  gluetun:
    image: qmcgaw/gluetun:${GLUETUN_VERSION}
    container_name: live-tv-gluetun
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - TZ=${TZ}
      - VPN_SERVICE_PROVIDER=private internet access
      - VPN_TYPE=openvpn
      - OPENVPN_USER=${PIA_USER}
      - OPENVPN_PASSWORD=${PIA_PASS}
      - SERVER_REGIONS=${PIA_REGION}
      - VPN_PORT_FORWARDING=off
      - DNS_UPSTREAM_RESOLVER_TYPE=${DNS_UPSTREAM_RESOLVER_TYPE:-doh}
      - DNS_UPSTREAM_RESOLVERS=${DNS_UPSTREAM_RESOLVERS:-cloudflare}
      - DNS_UPSTREAM_IPV6=off
      - BLOCK_MALICIOUS=on
      - BLOCK_SURVEILLANCE=off
      - BLOCK_ADS=off
    volumes:
      - /mnt/main/appdata/live-tv/gluetun:/gluetun
    ports:
      - "${SERVER_IP}:9191:9191"
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- --timeout=10 https://ifconfig.me >/dev/null 2>&1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 90s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  dispatcharr:
    image: ghcr.io/dispatcharr/dispatcharr:${DISPATCHARR_VERSION}
    container_name: dispatcharr
    restart: unless-stopped
    network_mode: "service:gluetun"
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
    depends_on:
      gluetun:
        condition: service_healthy
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

In this VPN variant, the `9191` port is published on `live-tv-gluetun`, not on
the Dispatcharr service. That is expected when a container uses
`network_mode: "service:gluetun"`.

Start and verify:

```bash
cd /opt/stacks/live-tv
docker compose config
docker compose up -d
docker exec live-tv-gluetun wget -qO- --timeout=15 https://ifconfig.me
```

The returned IPv4 should be a VPN IP, not your home WAN IP.

Use this explicit routing check before assuming the public playlist traffic is
VPN-routed:

```bash
cd /opt/stacks/live-tv

HOME_WAN_IP="$(curl -4 -fsS --max-time 15 https://ifconfig.me)"
printf 'Home WAN IPv4: %s\n' "$HOME_WAN_IP"

printf 'Gluetun IPv4: '
docker exec live-tv-gluetun sh -lc 'wget -qO- --timeout=15 https://ifconfig.me || curl -4 -fsS --max-time 15 https://ifconfig.me'

printf 'Dispatcharr IPv4: '
docker exec dispatcharr sh -lc 'wget -qO- --timeout=15 https://ifconfig.me || curl -4 -fsS --max-time 15 https://ifconfig.me'

docker compose config | grep -A5 -E '^[[:space:]]+dispatcharr:'
```

Pass criteria:

- `docker compose config` shows `network_mode: service:gluetun` for
  `dispatcharr`.
- `live-tv-gluetun` returns a VPN-provider IPv4.
- `dispatcharr` returns a VPN-provider IPv4.
- Neither `live-tv-gluetun` nor `dispatcharr` returns `$HOME_WAN_IP`.

Your command:

```bash
curl -fsS "https://iptv-org.github.io/iptv/countries/de.m3u" | sed -n '1,60p'
```

was run from the Docker VM host, so it used the VM's normal network path. That
is useful for proving the playlist exists, but it is not a Gluetun test. To test
the same playlist through Gluetun, run it inside Dispatcharr's shared namespace:

```bash
docker exec dispatcharr sh -lc \
  'curl -fsSL --max-time 30 https://iptv-org.github.io/iptv/countries/de.m3u || wget -qO- --timeout=30 https://iptv-org.github.io/iptv/countries/de.m3u' \
  | sed -n '1,20p'
```

If that prints `#EXTM3U` and the Dispatcharr public IPv4 check returns a VPN IP,
then Dispatcharr's M3U download path is going through Gluetun.

Check whether Jellyfin will still fetch through Dispatcharr or bypass it:

```bash
curl -fsS "PASTE_DISPATCHARR_M3U_EXPORT_URL_HERE" | sed -n '1,60p'
```

If the exported stream URLs point back to Dispatcharr, Jellyfin playback should
flow through the Dispatcharr/Gluetun path. Good signs are URLs containing your
Dispatcharr host, such as `192.168.1.20:9191`, `dispatcharr`, or a Dispatcharr
proxy/stream endpoint.

If the exported stream URLs are the original upstream domains, Jellyfin will
fetch those streams directly and its normal home IP may still be visible to the
upstream source. In that case, Gluetun protects Dispatcharr's playlist refresh
and preview traffic, but not Jellyfin playback.

Kill-switch check:

```bash
cd /opt/stacks/live-tv
docker stop live-tv-gluetun
docker exec dispatcharr sh -lc 'curl -4 -fsS --max-time 10 https://ifconfig.me || wget -qO- --timeout=10 https://ifconfig.me' \
  && echo "LEAK: investigate before using VPN mode" \
  || echo "blocked or namespace unavailable as expected"

docker compose up -d gluetun dispatcharr
```

This intentionally interrupts only the Live TV stack. It should not affect
RDTClient, Radarr, Sonarr, Prowlarr, Jellyfin, or the existing debrid Gluetun.

## Monitoring

Add Uptime Kuma monitors:

| Monitor | Type | Target |
|---|---|---|
| Dispatcharr UI | HTTP | `http://192.168.1.20:9191` |
| Jellyfin Live TV | Manual check | Open Live TV guide and start one channel |
| Mediathek archive, if used | Manual check | Download one permitted test episode and confirm Jellyfin scans it |

Add a monthly manual check:

1. Open Jellyfin Live TV guide.
2. Play one German channel.
3. Play one English channel if configured.
4. Play one sports channel if configured.
5. Schedule a short recording if Dispatcharr DVR is enabled.
6. Confirm the recording file appears under `/mnt/media/data/live-tv/dispatcharr-recordings`.
7. If Mediathek archive is enabled, download one permitted test episode and
   confirm Jellyfin can see it in the configured library.

## Backups

Back up:

| Path | Why |
|---|---|
| `/srv/appdata/dispatcharr` | Active Dispatcharr database/config on local Docker VM storage |
| `/mnt/main/backups/docker-volumes/dispatcharr` | Archive backups of local Dispatcharr appdata |
| `/mnt/main/appdata/live-tv/mediathek` | yt-dlp venv, download archive, URL lists, logs |
| `/mnt/main/appdata/live-tv/sources` | Local legal source files |

Do not treat ordinary recordings as critical unless you intentionally archive
them. If recordings matter, move them to protected user data and include them in
off-server backup.

Add `main/appdata/live-tv` and `main/backups/docker-volumes` to the same
snapshot policy as other protected appdata.

Dispatcharr's active `/data` folder is local to the Docker VM, so protect it
with Proxmox VM backups and an app-consistent archive:

```bash
set -euo pipefail

cd /opt/stacks/live-tv

# Run this on the Ubuntu Docker VM, not inside the Dispatcharr container.
findmnt -T /mnt/main -o TARGET,SOURCE,FSTYPE,OPTIONS
df -h /mnt/main

BACKUP_DIR="/mnt/main/backups/docker-volumes/dispatcharr"
STAMP="$(date +%F-%H%M)"
BACKUP_FILE="dispatcharr-data-${STAMP}.tar.gz"
TMP_BACKUP="/tmp/${BACKUP_FILE}"

sudo -u mediauser mkdir -p "$BACKUP_DIR"
if ! sudo -u mediauser test -w "$BACKUP_DIR"; then
  echo "Backup destination is not writable: $BACKUP_DIR" >&2
  echo "Fix /mnt/main before stopping Dispatcharr or creating a backup." >&2
  exit 1
fi

sudo rm -f "$TMP_BACKUP"
docker compose stop dispatcharr

if sudo tar --xattrs --acls -czf "$TMP_BACKUP" -C /srv/appdata dispatcharr; then
  docker compose start dispatcharr
else
  docker compose start dispatcharr
  echo "Dispatcharr backup tar failed; stack was restarted." >&2
  exit 1
fi

sudo chown mediauser:mediauser "$TMP_BACKUP"
sudo -u mediauser mv "$TMP_BACKUP" "$BACKUP_DIR/$BACKUP_FILE"
sudo -u mediauser ls -lh "$BACKUP_DIR/$BACKUP_FILE"
```

If `sudo -u mediauser mkdir -p "$BACKUP_DIR"` prints
`mkdir: Read-only file system`, stop and fix the `/mnt/main` mount. The later
`tar: Cannot open: No such file or directory` is only a consequence of the
backup directory not existing.

For the dedicated `media` pool, follow the migration guide's maintenance model:

| Task | Target | Notes |
|---|---|---|
| Scrub | `media` pool | Monthly |
| SMART tests | 3 TB media HDD | Short daily/weekly, long monthly |
| Snapshot | `media/data` | Optional daily/weekly, short retention such as 7-14 days |

The media pool is for replaceable media and downloads. Back it up only if you
care about restoring those files without re-downloading or recreating them.

## Validation Checklist

Before calling Live TV done:

- [ ] No extra physical hardware or cabling is required for the active setup.
- [ ] Docker VM `/mnt/media/data` is mounted from `192.168.1.10:/mnt/media/data`.
- [ ] Docker VM `/srv/appdata` is local block storage, not NFS/autofs.
- [ ] No compose file or script for this stack uses `/mnt/main/media/data`.
- [ ] Dispatcharr `/data` maps from `/srv/appdata/dispatcharr`.
- [ ] `/mnt/main/appdata/live-tv/dispatcharr` is not used for Dispatcharr `/data`.
- [ ] Live TV source is legal and documented.
- [ ] Public playlist imports have been reviewed, and questionable channels are disabled.
- [ ] Dispatcharr is reachable at `http://192.168.1.20:9191`.
- [ ] Dispatcharr source import succeeds.
- [ ] Encrypted/unusable channels are disabled.
- [ ] EPG populates in Dispatcharr, or the source limitation is documented.
- [ ] M3U export opens from the Docker VM.
- [ ] XMLTV export opens from the Docker VM.
- [ ] Jellyfin Live TV guide populates.
- [ ] One German channel plays.
- [ ] One English channel plays, if configured.
- [ ] One sports channel plays, if configured.
- [ ] One test recording succeeds if DVR is enabled.
- [ ] Optional Mediathek download is from a permitted exact episode URL.
- [ ] Saved Mediathek file appears in Jellyfin.
- [ ] Dispatcharr is LAN/Tailscale-only.
- [ ] Optional VPN mode is either not used, or `live-tv-gluetun` returns a VPN IP.
- [ ] If VPN mode is used, `dispatcharr` also returns a VPN IP from inside the container.
- [ ] If VPN mode is used, the same iptv-org M3U URL prints `#EXTM3U` from inside `dispatcharr`.
- [ ] If VPN mode is used, Dispatcharr M3U exports point Jellyfin at Dispatcharr/proxy URLs, not direct upstream stream URLs.
- [ ] `/mnt/main/backups/docker-volumes/dispatcharr` is writable by `mediauser`.
- [ ] Dispatcharr local appdata is covered by Proxmox VM backup and archive backup.
- [ ] TrueNAS appdata and backup archive folders are covered by snapshots.
- [ ] The `media` pool has scrub, SMART, and optional snapshot tasks configured.

## Troubleshooting

### Backup Fails With `mkdir: Read-only file system`

This error means the backup destination is not writable from the shell where you
ran the command:

```text
mkdir: Read-only file system
tar: ... Cannot open: No such file or directory
```

The `tar` errors happen because the directory creation failed first.

Run these checks on the Ubuntu Docker VM, not inside a container:

```bash
hostname
pwd
findmnt -T /mnt/main -o TARGET,SOURCE,FSTYPE,OPTIONS
findmnt -T /mnt/main/backups -o TARGET,SOURCE,FSTYPE,OPTIONS
df -h /mnt/main
mount | grep ' /mnt/main '
sudo -u mediauser test -d /mnt/main && echo "/mnt/main exists"
sudo -u mediauser mkdir -p /mnt/main/backups/docker-volumes/dispatcharr
sudo -u mediauser touch /mnt/main/backups/docker-volumes/dispatcharr/.write-test
sudo -u mediauser rm /mnt/main/backups/docker-volumes/dispatcharr/.write-test
```

Expected:

```text
192.168.1.10:/mnt/main
```

or the exact TrueNAS export used for the protected `main` pool. The mount
options should include `rw`, not `ro`.

Common causes and fixes:

| Cause | Fix |
|---|---|
| You ran the command inside the Dispatcharr container | Exit the container and run it on the Docker VM host. Containers do not have the same `/mnt/main` view. |
| `/mnt/main` is mounted read-only | Check `/etc/fstab`, remount with `sudo mount -o remount,rw /mnt/main`, or run `sudo mount -a` after fixing fstab. |
| The TrueNAS NFS export is read-only | Fix the NFS share/export on TrueNAS so the Docker VM and `mediauser` can write to the protected appdata/backup paths. |
| `/mnt/main` is not mounted and you are seeing a read-only fallback path | Restore the NFS mount before writing backups. Do not create backup files on the wrong filesystem. |
| `mediauser` cannot write even though the mount is `rw` | Fix TrueNAS dataset ACL/NFS mapping for `mediauser` or the configured UID/GID. |

After the write test passes, rerun the backup command from the `Backups`
section.

### Dispatcharr Logs `chown: changing ownership of '/data/db': Operation not permitted`

This means Dispatcharr's `/data` volume is on a filesystem where the container
cannot change ownership. In this homelab, the usual cause is mapping `/data` to
TrueNAS NFS, such as `/mnt/main/appdata/live-tv/dispatcharr`.

The fix is to keep Dispatcharr `/data` on local Docker VM storage:

```bash
cd /opt/stacks/live-tv
docker compose down

sudo mkdir -p /srv/appdata/dispatcharr
sudo chown root:root /srv/appdata/dispatcharr

# docker-compose.yml must contain:
#   - /srv/appdata/dispatcharr:/data

docker compose pull dispatcharr
docker compose up -d dispatcharr
docker compose logs -f dispatcharr
```

Leave the old `/mnt/main/appdata/live-tv/dispatcharr` folder alone until the new
local instance is working. It can be removed later if it is empty and no longer
needed.

The warnings about `PYTHONUNBUFFERED`, `PYTHONDONTWRITEBYTECODE`,
`DISPATCHARR_DEBUG`, and `DISPATCHARR_ENABLE_IP_LOOKUP` are not the startup
blocker. The `/dev/dri/renderD128 not found` warning only matters if you expect
GPU acceleration; this no-cable IPTV setup can run without it.

### Dispatcharr Logs `Missing username or password for Xtream Codes account`

This means the M3U account was created as `Xtream Codes`, not as a plain
standard M3U source.

For iptv-org and normal `.m3u` playlists, use:

| Field | Correct value |
|---|---|
| `Account Type` | `Standard` or `Standard M3U` |
| `URL` | `https://iptv-org.github.io/iptv/countries/de.m3u` |
| `Username` | Empty |
| `Password` | Empty |
| `Server URL` / `Base URL` | Empty unless the UI uses this as the plain M3U URL field |
| `Enable VOD Scanning` | Off/not used |

Fix:

1. Go to `M3U & EPG Manager`.
2. Edit the broken source, such as `Ger`.
3. Change `Account Type` from `Xtream Codes` to `Standard` or `Standard M3U`.
4. Remove any username/password/provider-panel fields.
5. Put the M3U URL in the URL field:
   `https://iptv-org.github.io/iptv/countries/de.m3u`.
6. Save.
7. Refresh the source.

If Dispatcharr does not cleanly switch account type, delete the broken source
and recreate it as a standard M3U account.

### Dispatcharr Logs `Failed to refresh M3U groups - download failed or other error`

Common causes:

| Cause | Fix |
|---|---|
| The URL field contains `/sources/curated-public.m3u` | Do not use filesystem paths in the URL field. Upload the file or use mapped-file auto-import. |
| The URL field contains `/data/m3us/curated-public.m3u` | Same problem: it is a local file path, not a web URL. |
| The M3U URL is wrong or unreachable | Test it from the Docker VM with `curl`. |
| DNS/networking from the container is broken | Test from inside the Dispatcharr container. |
| VPN mode is enabled and Gluetun is unhealthy | Fix `live-tv-gluetun` before refreshing the M3U. |

Test the public Germany playlist from the Docker VM:

```bash
curl -fsSL "https://iptv-org.github.io/iptv/countries/de.m3u" | sed -n '1,12p'
```

Test from inside the Dispatcharr container:

```bash
docker exec dispatcharr sh -lc 'curl -fsSL --max-time 20 https://iptv-org.github.io/iptv/countries/de.m3u || wget -qO- --timeout=20 https://iptv-org.github.io/iptv/countries/de.m3u' | sed -n '1,12p'
```

If the Docker VM can download the playlist but the container cannot, the problem
is container networking, DNS, or optional VPN routing.

For local curated files, use one of these two methods:

| Method | How |
|---|---|
| Upload | In `Add M3U`, leave `URL` empty and use `Upload files` to upload the `.m3u` from your browser. |
| Mapped-file auto-import | Keep `/mnt/main/appdata/live-tv/sources:/data/m3us:ro` in compose, put `.m3u` files there, and enable mapped-file auto-import in `Settings -> Stream Settings`. |

### Jellyfin Guide Is Empty

Copy the XMLTV URL shown in the Dispatcharr UI and check it from the Docker VM:

```bash
curl -fsS "PASTE_DISPATCHARR_XMLTV_URL_HERE" | head
```

If the export is empty, fix EPG in Dispatcharr first. Jellyfin cannot map guide
data that Dispatcharr does not export.

### Jellyfin Channels Appear But Do Not Play

Copy the M3U URL shown in the Dispatcharr UI and check it from the Docker VM:

```bash
curl -fsS "PASTE_DISPATCHARR_M3U_URL_HERE" | head
```

Then try playing the same channel directly in Dispatcharr. If it fails there,
the problem is source/backend setup, not Jellyfin.

### Some Channels Show No Video

Likely causes:

- The source URL is dead.
- The source requires DRM or a provider app.
- The source requires a login, browser session, cookie, or rotating token.
- The stream is geo-blocked or not permitted for your use.

Disable unusable channels instead of trying to force Jellyfin to play them.

### Sports Recording Cuts Off Early

Increase DVR post-padding in Dispatcharr. For live sports, start with:

```text
Pre-padding: 5 minutes
Post-padding: 30-60 minutes
```

### IPTV Works In VLC But Not Jellyfin

Put Dispatcharr in front and test:

1. Direct source in VLC.
2. Dispatcharr output in VLC.
3. Dispatcharr output in Jellyfin.

If the source requires browser DRM, cookies, rotating tokens, or unofficial
headers, do not put it in the homelab stack.

### Mediathek Download Does Not Appear In Jellyfin

Check:

```bash
find "/mnt/media/data/media/tv/Bares fuer Rares" -maxdepth 3 -type f | sort | tail
```

Then rescan the Jellyfin library. If the file exists but matching is poor, keep
the library as `Mixed Movies and Shows` or use folder view. Public-broadcaster
magazine shows often do not map cleanly to TV metadata providers.

If `yt-dlp` fails with an unsupported URL, search/download the episode manually
with MediathekView or use the official broadcaster app instead. Do not work
around DRM, login-only, geo-blocked, or expiring protected streams.

## References

- Jellyfin Live Broadcast: <https://jellyfin.org/docs/general/server/live-tv/>
- Jellyfin Live TV Setup Guide: <https://jellyfin.org/docs/general/server/live-tv/setup-guide/>
- Dispatcharr project: <https://github.com/Dispatcharr/Dispatcharr>
- Dispatcharr docs: <https://dispatcharr.github.io/Dispatcharr-Docs/>
- iptv-org project: <https://github.com/iptv-org/iptv>
- iptv-org playlists: <https://github.com/iptv-org/iptv/blob/master/PLAYLISTS.md>
- iptv-org EPG utilities: <https://github.com/iptv-org/epg>
- MediathekView: <https://mediathekview.de/>
- yt-dlp project: <https://github.com/yt-dlp/yt-dlp>
- yt-dlp supported sites: <https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md>
- ZDF Bares fuer Rares page: <https://www.zdf.de/show/bares-fuer-rares>
