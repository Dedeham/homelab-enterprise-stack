# Dispatcharr High Quality Streams With Gluetun

Last updated: 2026-06-30

This guide is only about Dispatcharr setup for clean, high-quality Live TV
streams and optional VPN egress through the dedicated Live TV Gluetun gateway.

Use it after the broader Live TV guide exists:

[Jellyfin Live TV For German, English, And Sports Channels](jellyfin-live-tv-germany-english-sports-guide.md)

## Scope

This guide covers:

- adding legal M3U sources to Dispatcharr;
- selecting higher-quality, stable streams;
- filtering bad, duplicate, low-quality, and questionable channels;
- adding EPG/XMLTV;
- exporting one clean M3U/XMLTV pair to Jellyfin;
- proving Dispatcharr traffic is routed through `live-tv-gluetun`;
- kill-switch testing for the Live TV Gluetun namespace.

This guide does not cover bypassing paid apps, DRM, cookies, provider tokens, or
geo-blocking. Sky/WOW, DAZN, MagentaSport, RTL+, and similar services belong in
their official apps unless your provider explicitly gives you legal raw
M3U/XMLTV access.

## Target Design

```text
Legal M3U/XMLTV source
-> Dispatcharr
-> clean Dispatcharr M3U/XMLTV export
-> Jellyfin Live TV
-> Jellyfin clients
```

Optional VPN egress:

```text
live-tv-gluetun
+-- owns VPN tunnel, DNS, and firewall
+-- publishes Dispatcharr port 9191
+-- shares network namespace with dispatcharr
```

Expected compose pattern:

```text
dispatcharr network_mode: "service:gluetun"
9191 published on live-tv-gluetun
```

Do not attach this stack to `debrid-gluetun` or the ARR/torrent Gluetun. Live TV
gets its own Gluetun container so it can be restarted and tested independently.

## Quality Rules

High quality does not mean highest resolution at any cost. For Live TV, stable
720p or 1080p is better than a 4K stream that stalls, redirects, or changes
URLs constantly.

Keep a stream only if it passes all of these:

| Check | Required result |
|---|---|
| Legal source | Public/free or provider-authorized raw M3U/XMLTV |
| Playback | Starts quickly in Dispatcharr |
| Stability | Plays for at least 30-60 seconds without constant buffering |
| Identity | Content matches the channel name |
| Resolution | Prefer 720p/1080p; reject very low-quality duplicates unless needed |
| Reliability | Works again after a source refresh |
| Security/legal posture | No cookies, rotating tokens, browser sessions, DRM, or suspicious mirrors |

Disable streams that are dead, app-only, DRM-protected, mismatched, adult,
shopping-only, or irrelevant for the household.

## Recommended Sports M3U Sources

These are the best practical legal/public sports sources for this setup as of
2026-06-30. They are exact M3U URLs, not examples.

Important: only the first source is sports-only. The others are useful because
legal sports often appears on public/general or FAST channels, not only in a
clean sports category. Import one source, curate it, then add the next.

| Order | Dispatcharr source name | M3U URL | Why use it | Channel range |
|---:|---|---|---|---:|
| 1 | `Sports - iptv-org Review` | `https://iptv-org.github.io/iptv/categories/sports.m3u` | Best first sports-only public playlist. Noisy, but focused. | 300-349 |
| 2 | `Sports - Free-TV IPTV Review` | `https://raw.githubusercontent.com/Free-TV/IPTV/master/playlist.m3u8` | Quality-over-quantity free TV playlist; good place to find stable HD public/FAST sports-adjacent channels. | 350-379 |
| 3 | `Sports - TDTChannels Spain Review` | `https://www.tdtchannels.com/lists/tv.m3u8` | Spanish free/open TV list with integrated EPG and public sports/event channels such as RTVE/TDP-style sources when available. | 380-399 |
| 4 | `Sports - iptv-org English Review` | `https://iptv-org.github.io/iptv/languages/eng.m3u` | English-language public/FAST list; use filters to keep only sports, outdoor, motorsport, fight, racing, and sports-news channels. | 200-249 |
| 5 | `Sports - iptv-org Germany Review` | `https://iptv-org.github.io/iptv/countries/de.m3u` | German public/general channels that may carry sports events. Keep legal public channels, not premium-looking mirrors. | 1-99 |

Avoid the all-channels playlist for normal use:

```text
https://iptv-org.github.io/iptv/index.m3u
```

It is too noisy and makes quality control harder.

### Verify The M3U URLs

Run this before adding sources:

```bash
for url in \
  https://iptv-org.github.io/iptv/categories/sports.m3u \
  https://raw.githubusercontent.com/Free-TV/IPTV/master/playlist.m3u8 \
  https://www.tdtchannels.com/lists/tv.m3u8 \
  https://iptv-org.github.io/iptv/languages/eng.m3u \
  https://iptv-org.github.io/iptv/countries/de.m3u
do
  printf '\n== %s ==\n' "$url"
  curl -fsSL "$url" | sed -n '1,8p'
done
```

Every source should print `#EXTM3U`. If one fails, do not add it until the
Docker VM or Dispatcharr container can download it.

Important: a source-level M3U can be reachable while individual channel streams
inside it are dead. For example, a channel URL returning `404 Not Found` or
stalling at `0/4 chunks` should be disabled even if the parent M3U imports
successfully.

## Preflight Checks

Run on the Ubuntu Docker VM:

```bash
cd /opt/stacks/live-tv
docker compose ps
docker compose config | grep -A8 -E '^[[:space:]]+(gluetun|dispatcharr):'
findmnt -T /srv/appdata -o TARGET,SOURCE,FSTYPE,OPTIONS
findmnt -T /mnt/main -o TARGET,SOURCE,FSTYPE,OPTIONS
findmnt -T /mnt/media/data -o TARGET,SOURCE,FSTYPE,OPTIONS
```

Expected:

- `/srv/appdata` is local VM storage, not NFS.
- Dispatcharr `/data` maps to `/srv/appdata/dispatcharr`.
- `/mnt/main` is writable for source files and backups.
- `/mnt/media/data` is the media pool path.
- If Gluetun is enabled, Dispatcharr uses `network_mode: service:gluetun`.

## Add A Legal M3U Source

In Dispatcharr:

1. Open `http://192.168.1.20:9191`.
2. Go to `M3U & EPG Manager`.
3. Click `Add M3U`.
4. Set `Account Type` to `Standard` or `Standard M3U`.
5. Do not select `Xtream Codes`.
6. Set `Name` from the source plan.
7. Paste the M3U URL into `URL`.
8. Leave username and password empty.
9. Leave VOD scanning off.
10. Leave `Max Streams` as `0` unless your legal provider gives a limit.
11. Enable the source.
12. Save.

Add sources using these exact values:

| Add order | `Name` | `Account Type` | `URL` | `VOD scanning` | `Max Streams` |
|---:|---|---|---|---|---:|
| 1 | `Sports - iptv-org Review` | `Standard` or `Standard M3U` | `https://iptv-org.github.io/iptv/categories/sports.m3u` | Off | 0 |
| 2 | `Sports - Free-TV IPTV Review` | `Standard` or `Standard M3U` | `https://raw.githubusercontent.com/Free-TV/IPTV/master/playlist.m3u8` | Off | 0 |
| 3 | `Sports - TDTChannels Spain Review` | `Standard` or `Standard M3U` | `https://www.tdtchannels.com/lists/tv.m3u8` | Off | 0 |
| 4 | `Sports - iptv-org English Review` | `Standard` or `Standard M3U` | `https://iptv-org.github.io/iptv/languages/eng.m3u` | Off | 0 |
| 5 | `Sports - iptv-org Germany Review` | `Standard` or `Standard M3U` | `https://iptv-org.github.io/iptv/countries/de.m3u` | Off | 0 |

For all five sources:

| Field | Value |
|---|---|
| `Username` | Empty |
| `Password` | Empty |
| `Server URL` / Xtream fields | Empty |
| `Is Active` | On |
| Refresh interval | 24 hours after the first successful import |

Do not add the next source until the current source is imported, filtered, and
tested.

Initial per-source cleanup:

| Source | Keep first | Disable first |
|---|---|---|
| `Sports - iptv-org Review` | 720p/1080p channels that start quickly and match their name | Dead, geo-blocked, premium-looking, low-resolution duplicates, suspicious mirrors |
| `Sports - Free-TV IPTV Review` | Sports, outdoor, motorsport, racing, fight, sports-news, and event channels | General entertainment, music, shopping, adult, non-sports channels |
| `Sports - TDTChannels Spain Review` | Public Spanish channels and sports/event channels you actually watch | Regional/general channels you do not need, duplicates, non-sports channels |
| `Sports - iptv-org English Review` | English sports, outdoor, motorsport, racing, fight, sports-news, and sports-adjacent channels | Movies, entertainment, kids, religious, shopping, unrelated news |
| `Sports - iptv-org Germany Review` | German public/general channels that carry events and reliable public HD streams | Shop, undefined, premium-looking names, dead mirrors, unrelated entertainment |

Wrong settings:

| Wrong setting | Why it breaks |
|---|---|
| `Account Type = Xtream Codes` | Dispatcharr expects a provider panel login. |
| `URL = /data/m3us/file.m3u` | Local filesystem paths are not web URLs. |
| Adding all public playlists at once | Creates duplicates, junk groups, and bad guide mapping. |

## Group Filter And Auto Channel Sync

After the source imports, open its group/filter/sync settings.

In the Dispatcharr modal you showed, configure the tabs like this.

### Live Tab

Use these global settings at the top of the `Live` tab:

| UI option | Recommended value | Why |
|---|---|---|
| `Automatically enable new groups discovered on future scans` | Unchecked/off | New groups from public playlists should not auto-enter Jellyfin without review. |
| `Auto-sync orphan cleanup` | `Always remove` during first setup | Removes auto-created channels when a source stream disappears. |
| `Auto-sync orphan cleanup` after you customize channels | `Preserve customized` | Safer after you have renamed channels, changed logos, or manually tuned channel entries. |
| `Auto-sync orphan cleanup = Never remove` | Avoid | Leaves dead channels behind and makes Jellyfin messy. |
| `All / Enabled / Disabled` | Use for review only | It changes what cards are visible, not the legal/quality decision. |
| `Select Visible` | Avoid for public playlists | Too easy to enable hundreds of unwanted groups. |
| `Deselect Visible` | Useful after filtering noisy groups | Good for disabling a filtered set such as shopping/adult/test groups. |

For each group card:

| Per-group option | Recommended value |
|---|---|
| Green group header | Means the group exists/enabled in the group filter, but does not by itself create channels. |
| `Auto Channel Sync` checkbox | Enable only for groups you reviewed and want in Jellyfin. |
| `Channel Numbering Mode` | `Fixed` for this homelab. |
| `Provider` numbering | Use only if the provider has clean channel numbers you trust. |
| `Next Avail` numbering | Use only for later temporary/import testing. |
| `Start #` | Use the range table below. |
| `End # (optional)` | Set it if you want to cap that source range. |
| `Streams: 0` | Do not enable auto-sync; that group has nothing to create. |

For the first pass, do this:

1. Open the source's `M3U Group Filter & Auto Channel Sync`.
2. Stay on the `Live` tab.
3. Uncheck `Automatically enable new groups discovered on future scans`.
4. Set `Auto-sync orphan cleanup` to `Always remove`.
5. Click `Deselect Visible` if the source imported with many enabled groups.
6. Use `Filter groups...` to find one group you actually want.
7. Enable `Auto Channel Sync` only on that group.
8. Set `Channel Numbering Mode` to `Fixed`.
9. Set `Start #` from the source range below.
10. Leave `End #` blank at first, or set it to the end of the range if you want a hard cap.
11. Ignore groups showing `Streams: 0`.
12. Click `Save and Refresh`.

Do not enable every country card in the sports playlist. Most will be irrelevant,
dead, geo-blocked, or duplicated.

### VOD - Movies And VOD - Series Tabs

This guide uses Dispatcharr for Live TV only.

On both `VOD - Movies` and `VOD - Series`:

1. Uncheck `Automatically enable new movie categories discovered on future scans`
   or the equivalent VOD-series option.
2. Do not enable VOD categories.
3. Do not use `Select Visible`.
4. Click `Save and Refresh` after disabling automatic VOD category enablement.

If you see VOD categories later, leave them disabled. VOD scanning should also
remain off on the M3U account itself.

### Source-Specific Group Choices

Start with one or two groups only.

| Source | First groups to try | Leave disabled first |
|---|---|---|
| `Sports - iptv-org Review` | Countries you actually watch, then only groups with `Streams` greater than `0` | Random countries, `Streams: 0`, premium-looking or suspicious groups |
| `Sports - Free-TV IPTV Review` | Sports/outdoor/motorsport/racing/fight/sports-news groups if present | General entertainment, music, shopping, adult, unrelated countries |
| `Sports - TDTChannels Spain Review` | Spanish public/general and sports/event groups you want | Regional/general duplicates and non-sports groups |
| `Sports - iptv-org English Review` | Sports, outdoor, motorsport, racing, fight, sports-news | Movies, religious, kids, shopping, unrelated entertainment |
| `Sports - iptv-org Germany Review` | Public/general German channels that may carry sports | `Shop`, `Undefined`, premium-looking names, dead mirrors |

For a screen like your screenshot:

- `Albania` has `Auto Channel Sync` enabled but shows `Streams: 0`; disable it
  because it will not create useful channels.
- `Andorra`, `Argentina`, `Armenia`, and similar country cards should stay
  without `Auto Channel Sync` unless you specifically want those channels.
- Use the group filter box to search for relevant groups instead of scrolling
  through every country.
- Enable a group only when the stream count is greater than `0` and the group is
  relevant.
- Use `Fixed` numbering so Jellyfin channel numbers stay predictable.
- Save with `Save and Refresh`, then check the `Channels` page before adding
  another group.

Recommended starting numbers:

| Group | Start number |
|---|---:|
| German public/general | 1 |
| German regional/public | 100 |
| English | 200 |
| Sports | 300 |
| News | 400 |
| Public/community | 600 |
| Temporary/test | 900 |

If hundreds of channels appear in `Channels`, stop and clean up before adding
Jellyfin:

1. Disable auto-sync for noisy groups.
2. Save.
3. Refresh the M3U source.
4. Let orphan cleanup remove channels.
5. Manually delete anything still unwanted.

## Quality Filtering

Use Dispatcharr filters where available. Start broad, then tighten after you see
the import result.

Suggested reject filters:

| Reason | Pattern idea |
|---|---|
| Dead or test streams | `dead|offline|test` |
| Geo-blocked review queue | `geo-blocked|geo blocked` |
| Premium/app-only names | `DAZN|Sky|WOW|MagentaSport|RTL\+` |
| Adult content | `adult|xxx|18\+` |
| Shopping, if unwanted | `shop|shopping|teleshopping` |
| Low quality, if duplicates exist | `240p|270p|360p|480p` |

Do not use filters as the legal decision. If a high-quality stream looks
questionable, leave it disabled.

## Pick The Best Stream

When the same channel exists more than once:

1. Prefer official/public broadcaster domains where recognizable.
2. Prefer 1080p if stable.
3. Use 720p if 1080p buffers or fails.
4. Disable 360p/480p duplicates unless they are the only stable version.
5. Disable mirrors with mismatched content or suspicious domains.
6. Keep only one visible Jellyfin channel per channel name.

If Dispatcharr supports backup streams, add a backup stream only when both the
primary and backup are legal and stable.

## EPG/XMLTV

EPG should come from the same legal provider when possible.

In Dispatcharr:

1. Go to `M3U & EPG Manager`.
2. Click `Add EPG`.
3. Add the XMLTV URL from your source/provider.
4. Save and import.
5. Open `TV Guide`.
6. Map guide entries only for channels you are keeping.

Do not spend time mapping EPG for channels you will disable.

## Playback Test

Before Jellyfin:

1. Open the channel in Dispatcharr.
2. Play for 30-60 seconds.
3. Check that the channel identity is correct.
4. Repeat for one German, one English, one sports, and one news channel if
   configured.

Disable streams that fail, buffer constantly, redirect, or require protected
provider behavior.

If Dispatcharr shows `Start streaming`, stops after about one second, and the
video never loads, treat that channel as failed until proven otherwise. Do not
add it to Jellyfin yet.

For a stronger test, copy the stream URL from the channel/source details if
Dispatcharr exposes it, then test it from inside the Dispatcharr namespace:

```bash
docker exec dispatcharr sh -lc \
  'ffprobe -v error -rw_timeout 15000000 -show_streams -show_format "PASTE_STREAM_URL_HERE" | head -80'
```

If `ffprobe` is not installed in the container, use a short HTTP test first:

```bash
docker exec dispatcharr sh -lc \
  'curl -L -I --max-time 20 "PASTE_STREAM_URL_HERE" || wget --spider --timeout=20 "PASTE_STREAM_URL_HERE"'
```

Pass criteria:

- the URL resolves from inside `dispatcharr`;
- it returns a video playlist or video response, not an HTML page;
- it does not require cookies, browser headers, account tokens, or DRM;
- it keeps responding for more than a few seconds.

## Export To Jellyfin

In Dispatcharr, copy:

- M3U export URL;
- XMLTV/EPG export URL, if configured.

Test from the Docker VM:

```bash
curl -fsS "PASTE_DISPATCHARR_M3U_EXPORT_URL_HERE" | sed -n '1,40p'
curl -fsS "PASTE_DISPATCHARR_XMLTV_EXPORT_URL_HERE" | sed -n '1,20p'
```

Expected M3U starts with:

```text
#EXTM3U
```

Expected XMLTV starts with:

```text
<?xml
<tv
```

In Jellyfin:

1. Go to `Dashboard -> Live TV`.
2. Add an `M3U Tuner`.
3. Paste the Dispatcharr M3U URL.
4. Add an `XMLTV` guide data provider.
5. Paste the Dispatcharr XMLTV URL.
6. Save.
7. Refresh guide data.
8. Test one channel.

## Gluetun Compose Pattern

Use a separate Live TV Gluetun container. The important parts are:

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
```

In this design, port `9191` is published on `live-tv-gluetun`, not on
`dispatcharr`. That is correct because Dispatcharr shares Gluetun's network
namespace.

## Gluetun Routing Proof

Run this from the Docker VM:

```bash
cd /opt/stacks/live-tv

HOME_WAN_IP="$(curl -4 -fsS --max-time 15 https://ifconfig.me)"
printf 'Home WAN IPv4: %s\n' "$HOME_WAN_IP"

printf 'Gluetun IPv4: '
docker exec live-tv-gluetun sh -lc 'wget -qO- --timeout=15 https://ifconfig.me || curl -4 -fsS --max-time 15 https://ifconfig.me'

printf 'Dispatcharr IPv4: '
docker exec dispatcharr sh -lc 'wget -qO- --timeout=15 https://ifconfig.me || curl -4 -fsS --max-time 15 https://ifconfig.me'

docker compose config | grep -A8 -E '^[[:space:]]+dispatcharr:'
```

Pass criteria:

- `dispatcharr` shows `network_mode: service:gluetun`.
- `live-tv-gluetun` returns a VPN-provider IP.
- `dispatcharr` returns a VPN-provider IP.
- Neither result equals the home WAN IP.

Your host-level command:

```bash
curl -fsS "https://iptv-org.github.io/iptv/countries/de.m3u" | sed -n '1,60p'
```

does not prove Gluetun routing. It proves only that the Docker VM host can reach
the playlist. Test playlist download through Gluetun like this:

```bash
docker exec dispatcharr sh -lc \
  'curl -fsSL --max-time 30 https://iptv-org.github.io/iptv/countries/de.m3u || wget -qO- --timeout=30 https://iptv-org.github.io/iptv/countries/de.m3u' \
  | sed -n '1,20p'
```

Pass criteria:

- output starts with `#EXTM3U`;
- `dispatcharr` public IPv4 check returns a VPN IP;
- no check returns the home WAN IP.

## Jellyfin Playback Routing Check

Even when Dispatcharr is behind Gluetun, Jellyfin may still bypass it if the
exported M3U contains direct upstream URLs.

Check the export:

```bash
curl -fsS "PASTE_DISPATCHARR_M3U_EXPORT_URL_HERE" | grep -E 'https?://' | head -20
```

If the URLs point to `192.168.1.20:9191`, `dispatcharr`, or a Dispatcharr
proxy/stream endpoint, Jellyfin playback should flow through Dispatcharr and
therefore through Gluetun.

If the URLs point to original upstream domains, Jellyfin fetches those streams
directly. In that case, Gluetun protects Dispatcharr source refresh and preview
traffic, but not Jellyfin playback traffic.

## Kill-Switch Test

This intentionally interrupts only the Live TV Gluetun stack.

Run from the Docker VM:

```bash
cd /opt/stacks/live-tv

docker compose ps
docker exec dispatcharr sh -lc 'wget -qO- --timeout=15 https://ifconfig.me || curl -4 -fsS --max-time 15 https://ifconfig.me'

docker stop live-tv-gluetun

docker exec dispatcharr sh -lc 'wget -qO- --timeout=10 https://ifconfig.me || curl -4 -fsS --max-time 10 https://ifconfig.me' \
  && echo "LEAK: Dispatcharr reached the internet after Gluetun stopped" \
  || echo "blocked or namespace unavailable as expected"

docker compose up -d gluetun dispatcharr

for i in $(seq 1 60); do
  if docker inspect -f '{{.State.Health.Status}}' live-tv-gluetun 2>/dev/null | grep -q healthy; then
    echo "live-tv-gluetun healthy"
    break
  fi

  echo "waiting for live-tv-gluetun health..."
  sleep 2
done

docker exec dispatcharr sh -lc 'wget -qO- --timeout=15 https://ifconfig.me || curl -4 -fsS --max-time 15 https://ifconfig.me'
```

Pass criteria:

- Dispatcharr can reach the internet before the test and shows a VPN IP.
- After `live-tv-gluetun` is stopped, Dispatcharr cannot reach the internet.
- It does not print the home WAN IP.
- After restore, `live-tv-gluetun` becomes healthy.
- Dispatcharr again returns a VPN IP.

If Dispatcharr returns the home WAN IP at any point, stop the Live TV stack:

```bash
cd /opt/stacks/live-tv
docker compose stop dispatcharr gluetun
```

Then fix compose before using the source.

## DNS And IPv6 Checks

Run:

```bash
cd /opt/stacks/live-tv

docker exec dispatcharr cat /etc/resolv.conf

docker exec dispatcharr sh -lc 'curl -6 -fsS --max-time 10 https://ifconfig.me && echo "IPv6 LEAK: investigate" || echo "IPv6 blocked as expected"'

docker exec dispatcharr sh -lc 'getent hosts example.com || nslookup example.com || true'
```

Pass criteria:

- IPv6 does not connect unless you intentionally designed VPN IPv6.
- DNS lookups work while Gluetun is healthy.
- Resolver configuration does not point directly at the LAN router or ISP DNS.

## Sports Setup

For sports:

1. Make Germany/public channels work first.
2. Add `Sports - iptv-org Review`.
3. Keep only legal public/free streams.
4. Disable premium/app-only names unless verified through an authorized M3U
   provider.
5. Use channel numbers `300-399`.
6. Test every sports channel before Jellyfin.
7. Use DVR padding if recording:

```text
Pre-padding: 5 minutes
Post-padding: 30-60 minutes
```

Premium sports expectation:

| Service | Dispatcharr/Jellyfin path |
|---|---|
| DAZN | Official app unless authorized raw M3U/XMLTV exists |
| Sky/WOW | Official app/receiver unless authorized raw M3U/XMLTV exists |
| MagentaSport | Official app unless authorized raw M3U/XMLTV exists |
| Public broadcaster sports | Good candidate when legal stream is available |
| Free sports channels | Good candidate after review |

## Maintenance

Monthly:

1. Refresh each M3U source.
2. Check disabled/new groups.
3. Play one German, one English, one sports, and one news channel.
4. Confirm EPG still maps for kept channels.
5. Re-run the Gluetun routing proof.
6. Re-run the kill-switch test after Gluetun or compose changes.

After adding a new source:

1. Keep new groups disabled by default.
2. Review quality and legality.
3. Add only wanted channels.
4. Test Dispatcharr playback.
5. Test Jellyfin playback.
6. Confirm whether Jellyfin uses Dispatcharr proxy URLs or direct upstream URLs.

## Troubleshooting

### Dispatcharr Play Starts Then Stops Immediately

Symptom:

```text
Click Play
-> Dispatcharr shows Start streaming
-> after about one second it stops
-> stream never loads
-> clicking Play again stays in a loading loop
```

This usually means Dispatcharr created the channel, but playback cannot actually
open the underlying stream. The most common causes are:

| Cause | What it looks like | Fix |
|---|---|---|
| Dead stream URL | Starts then stops, or loops forever | Disable the stream and try another source/quality. |
| Geo-blocked stream | Works for some regions, fails through your current VPN region | Try a legal source available in your region, or change VPN region only if that is allowed for the source. |
| Non-HLS or unsupported URL | Playlist entry points to Twitch, web page, or unsupported player URL | Disable it; Dispatcharr/Jellyfin need playable stream URLs, usually `.m3u8`. |
| DRM/app-only stream | Premium channel name, starts briefly or never starts | Disable it. Use the official app. |
| VPN timeout/DNS issue | Many channels fail, not just one | Check `live-tv-gluetun` health and test from inside `dispatcharr`. |
| Browser/player cache after failed attempt | First click stops, second click loops | Refresh the Dispatcharr page after disabling the bad stream or restarting the channel test. |

If your Gluetun logs show lines like these, routing is working:

```text
[openvpn] Initialization Sequence Completed
[dns] ready and using DNS server with doh upstream resolvers
[ip getter] Public IP address is ... Germany ... Frankfurt am Main
```

Those lines mean Gluetun established the VPN tunnel, enabled DNS, and got a VPN
public IP. Do not keep troubleshooting VPN routing just because one stream does
not play.

If Dispatcharr logs show lines like these, the stream itself is bad or unusable:

```text
HTTP error 404 Not Found
Error opening input files: Server returned 404 Not Found
Maximum retry attempts (3) reached
```

Action: disable that stream. It is a dead URL.

If Dispatcharr logs show lines like these, Dispatcharr reached the URL but got
no playable media data:

```text
connected but waiting for buffer to fill: 0/4 chunks
Stream unhealthy ... no data for 5.0s
stalled in connecting state with no buffer data after 5s
```

Action: disable that stream or try another quality/source. This is not a routing
success; it is a playback-source failure.

First, confirm the Live TV stack is healthy:

```bash
cd /opt/stacks/live-tv
docker compose ps
docker logs --tail 120 live-tv-gluetun
docker logs --tail 120 dispatcharr
```

Then confirm Dispatcharr still egresses through Gluetun:

```bash
HOME_WAN_IP="$(curl -4 -fsS --max-time 15 https://ifconfig.me)"
printf 'Home WAN IPv4: %s\n' "$HOME_WAN_IP"

printf 'Dispatcharr IPv4: '
docker exec dispatcharr sh -lc 'wget -qO- --timeout=15 https://ifconfig.me || curl -4 -fsS --max-time 15 https://ifconfig.me'
```

The Dispatcharr IP must be a VPN IP, not `$HOME_WAN_IP`.

Next, test whether this is one bad stream or a stack-wide problem:

1. Try a known public German channel from `Sports - iptv-org Germany Review`.
2. Try one channel from `Sports - iptv-org Review`.
3. Try one channel from `Sports - Free-TV IPTV Review`.

Result:

| Result | Meaning |
|---|---|
| Only one channel fails | That channel/URL is bad or blocked. Disable it. |
| Every channel from one source fails | That M3U source has bad URLs, needs a different VPN region, or is not usable. Disable that source for now. |
| Every source fails | Check Gluetun, DNS, Dispatcharr logs, and compose routing. |

If you can copy the raw stream URL from Dispatcharr, test it inside the
Dispatcharr namespace:

```bash
docker exec dispatcharr sh -lc \
  'curl -L -I --max-time 20 "PASTE_STREAM_URL_HERE" || wget --spider --timeout=20 "PASTE_STREAM_URL_HERE"'
```

Good signs:

- HTTP status is `200`, `206`, or a normal redirect to an `.m3u8` playlist.
- `content-type` looks like HLS, MPEG-TS, video, or plain text playlist.
- The URL is an actual media/playlist URL, not a normal website page.

Bad signs:

- `403`, `404`, `451`, `5xx`, or timeout.
- `content-type: text/html`.
- URL contains login/session/cookie/token-only behavior.
- URL points to a premium app/player page rather than an HLS stream.

If the stream fails this test, disable it in Dispatcharr. Do not keep retrying a
bad channel in Jellyfin.

If many channels fail only while Gluetun is enabled, try a different nearby VPN
region in `.env`, then restart and re-test:

```bash
cd /opt/stacks/live-tv
docker compose up -d --force-recreate gluetun dispatcharr
docker exec dispatcharr sh -lc 'wget -qO- --timeout=15 https://ifconfig.me || curl -4 -fsS --max-time 15 https://ifconfig.me'
```

Only keep the new region if the routing proof and kill-switch test still pass.

### Playlist Works From Host But Not Dispatcharr

The host command uses the Docker VM network. Dispatcharr may be behind Gluetun.

Test inside Dispatcharr:

```bash
docker exec dispatcharr sh -lc \
  'curl -fsSL --max-time 30 https://iptv-org.github.io/iptv/countries/de.m3u || wget -qO- --timeout=30 https://iptv-org.github.io/iptv/countries/de.m3u' \
  | sed -n '1,20p'
```

If this fails but host `curl` works, check Gluetun health, DNS, and PIA
credentials.

### Dispatcharr Shows Home WAN IP

Stop:

```bash
cd /opt/stacks/live-tv
docker compose stop dispatcharr gluetun
```

Then check:

```bash
docker compose config | grep -A12 -E '^[[:space:]]+(gluetun|dispatcharr):'
docker logs --tail 200 live-tv-gluetun
```

The most likely cause is that `dispatcharr` is not using
`network_mode: "service:gluetun"`, or the wrong compose file is running.

### Jellyfin Playback Is Not VPN-Routed

Check the Dispatcharr M3U export. If it contains direct upstream stream URLs,
Jellyfin will fetch them directly.

Fix by enabling Dispatcharr proxy/stream URLs if the UI supports it, then
re-export and re-test the M3U. If Dispatcharr cannot proxy that source, accept
that Jellyfin playback is direct or choose another legal source.

### Too Many Bad Channels

Disable auto-sync for noisy groups, enable orphan cleanup, refresh the source,
and delete unwanted channels manually.

### Premium Sports Entries Appear In Public Playlists

Leave them disabled unless they are verified official free streams or
provider-authorized raw M3U/XMLTV. Public playlist names are not proof of legal
or stable access.

## Done Criteria

- [ ] Dispatcharr source uses `Standard` or `Standard M3U`, not Xtream Codes.
- [ ] Only reviewed groups auto-sync.
- [ ] New groups are disabled by default.
- [ ] Low-quality duplicates are disabled unless needed.
- [ ] Premium/app-only channels are disabled unless provider-authorized.
- [ ] One German channel plays.
- [ ] One English channel plays, if configured.
- [ ] One sports channel plays, if configured.
- [ ] EPG maps for kept channels, or missing EPG is documented.
- [ ] Jellyfin M3U export opens from the Docker VM.
- [ ] Jellyfin XMLTV export opens if configured.
- [ ] `dispatcharr` returns a VPN IP when Gluetun mode is enabled.
- [ ] The same M3U source downloads from inside `dispatcharr`.
- [ ] Kill-switch test blocks Dispatcharr when `live-tv-gluetun` is stopped.
- [ ] Jellyfin playback routing is understood: Dispatcharr proxy path or direct upstream path.

## References

- iptv-org playlists: <https://github.com/iptv-org/iptv/blob/master/PLAYLISTS.md>
- Free-TV/IPTV playlist: <https://github.com/Free-TV/IPTV>
- TDTChannels lists: <https://www.tdtchannels.com/listas/>
- TDTChannels repository: <https://github.com/LaQuay/TDTChannels>
