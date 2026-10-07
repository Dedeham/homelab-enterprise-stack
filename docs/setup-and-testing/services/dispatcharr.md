# Dispatcharr Setup And Testing

Setup for Dispatcharr Live TV curation, optional Gluetun VPN egress, and the associated routing/kill-switch tests. For architecture and current source list, see [Dispatcharr](../../services/dispatcharr.md).

## Preflight Checks

```bash
cd /opt/stacks/live-tv
docker compose ps
docker compose config | grep -A8 -E '^[[:space:]]+(gluetun|dispatcharr):'
findmnt -T /srv/appdata -o TARGET,SOURCE,FSTYPE,OPTIONS
findmnt -T /mnt/main -o TARGET,SOURCE,FSTYPE,OPTIONS
findmnt -T /mnt/media/data -o TARGET,SOURCE,FSTYPE,OPTIONS
```

Expected: `/srv/appdata` is local VM storage (not NFS); Dispatcharr's `/data` maps to `/srv/appdata/dispatcharr`; `/mnt/main` is writable; `/mnt/media/data` is the media pool path; if Gluetun is enabled, Dispatcharr uses `network_mode: service:gluetun`.

### Verify M3U URLs Before Adding Sources

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

Every source should print `#EXTM3U`. Do not add a source until it downloads successfully. Note that a source-level M3U being reachable does not guarantee every channel URL inside it works — individual dead/stalling channel URLs should still be disabled.

## Add A Legal M3U Source

Open `http://192.168.1.20:9191` -> `M3U & EPG Manager` -> `Add M3U`.

Add sources one at a time (do not add the next until the current one is imported, filtered, and tested):

| `Name` | `Account Type` | `URL` | VOD scanning | Max Streams |
|---|---|---|---|---:|
| `Sports - iptv-org Review` | `Standard`/`Standard M3U` | `https://iptv-org.github.io/iptv/categories/sports.m3u` | Off | 0 |
| `Sports - Free-TV IPTV Review` | `Standard`/`Standard M3U` | `https://raw.githubusercontent.com/Free-TV/IPTV/master/playlist.m3u8` | Off | 0 |
| `Sports - TDTChannels Spain Review` | `Standard`/`Standard M3U` | `https://www.tdtchannels.com/lists/tv.m3u8` | Off | 0 |
| `Sports - iptv-org English Review` | `Standard`/`Standard M3U` | `https://iptv-org.github.io/iptv/languages/eng.m3u` | Off | 0 |
| `Sports - iptv-org Germany Review` | `Standard`/`Standard M3U` | `https://iptv-org.github.io/iptv/countries/de.m3u` | Off | 0 |

For all five: leave Username/Password/Xtream fields empty, set `Is Active` on, and refresh every 24 hours after the first successful import.

Do not set `Account Type = Xtream Codes` (expects a provider panel login) or use a local filesystem path as the `URL`. Do not add all public playlists at once — it creates duplicates and bad guide mapping.

Initial per-source cleanup guidance:

| Source | Keep first | Disable first |
|---|---|---|
| `Sports - iptv-org Review` | 720p/1080p channels that start quickly and match their name | Dead, geo-blocked, premium-looking, low-res duplicates |
| `Sports - Free-TV IPTV Review` | Sports/outdoor/motorsport/racing/fight/sports-news channels | General entertainment, music, shopping, adult |
| `Sports - TDTChannels Spain Review` | Public Spanish and sports/event channels actually watched | Regional/general duplicates, non-sports |
| `Sports - iptv-org English Review` | English sports/outdoor/motorsport/racing/fight/sports-news | Movies, kids, religious, shopping, unrelated news |
| `Sports - iptv-org Germany Review` | German public/general channels carrying events | Shop, undefined, premium-looking names, dead mirrors |

## Group Filter And Auto Channel Sync

After a source imports, open its `M3U Group Filter & Auto Channel Sync` modal, stay on the `Live` tab, and configure:

1. Uncheck `Automatically enable new groups discovered on future scans` (new groups should not auto-enter Jellyfin without review).
2. Set `Auto-sync orphan cleanup` to `Always remove` during first setup (switch to `Preserve customized` once channels are hand-tuned; never leave it at `Never remove`).
3. Click `Deselect Visible` if the source imported with many groups already enabled.
4. Use `Filter groups...` to find one group you actually want — avoid `Select Visible` on public playlists, it's too easy to enable hundreds of unwanted groups.
5. Enable `Auto Channel Sync` only on that reviewed group.
6. Set `Channel Numbering Mode` to `Fixed` and `Start #` from the numbering table in the service description.
7. Ignore groups showing `Streams: 0`.
8. Click `Save and Refresh`.

Do not enable every country/group card in a noisy playlist — most will be irrelevant, dead, geo-blocked, or duplicated.

On both `VOD - Movies` and `VOD - Series` tabs: uncheck the automatic-enable option, do not enable any VOD categories, do not use `Select Visible`, and `Save and Refresh`. This deployment uses Dispatcharr for Live TV only.

If hundreds of channels appear under `Channels`, stop and clean up: disable auto-sync for noisy groups, save, refresh the source, let orphan cleanup remove channels, then manually delete anything still unwanted.

## Quality Filtering

Suggested reject-filter patterns (tighten after seeing the import result, never use filters alone as the legal decision):

| Reason | Pattern |
|---|---|
| Dead/test streams | `dead\|offline\|test` |
| Geo-blocked review queue | `geo-blocked\|geo blocked` |
| Premium/app-only names | `DAZN\|Sky\|WOW\|MagentaSport\|RTL\+` |
| Adult content | `adult\|xxx\|18\+` |
| Shopping | `shop\|shopping\|teleshopping` |
| Low quality duplicates | `240p\|270p\|360p\|480p` |

When the same channel exists more than once: prefer official/public broadcaster domains, prefer 1080p if stable, fall back to 720p if 1080p buffers, disable 360p/480p duplicates unless they're the only stable version, disable mismatched/suspicious mirrors, and keep only one visible Jellyfin channel per name.

## EPG/XMLTV

`M3U & EPG Manager -> Add EPG`, paste the XMLTV URL from the same legal provider when possible, save and import, then open `TV Guide` and map guide entries only for channels being kept.

## Playback Test (Before Jellyfin)

Open the channel in Dispatcharr, play 30-60 seconds, confirm channel identity, and repeat for one German, one English, one sports, and one news channel if configured. Treat a channel that starts then stops after about a second as failed until proven otherwise.

For a stronger test, copy the raw stream URL and test it inside the Dispatcharr namespace:

```bash
docker exec dispatcharr sh -lc \
  'ffprobe -v error -rw_timeout 15000000 -show_streams -show_format "PASTE_STREAM_URL_HERE" | head -80'
```

If `ffprobe` isn't available, fall back to an HTTP test:

```bash
docker exec dispatcharr sh -lc \
  'curl -L -I --max-time 20 "PASTE_STREAM_URL_HERE" || wget --spider --timeout=20 "PASTE_STREAM_URL_HERE"'
```

Pass: the URL resolves from inside `dispatcharr`, returns a video playlist/response (not HTML), requires no cookies/headers/tokens/DRM, and keeps responding for more than a few seconds.

## Export To Jellyfin

Copy the M3U and XMLTV export URLs from Dispatcharr, then test from the Docker VM:

```bash
curl -fsS "PASTE_DISPATCHARR_M3U_EXPORT_URL_HERE" | sed -n '1,40p'
curl -fsS "PASTE_DISPATCHARR_XMLTV_EXPORT_URL_HERE" | sed -n '1,20p'
```

Expected M3U starts with `#EXTM3U`; expected XMLTV starts with `<?xml` / `<tv`.

In Jellyfin: `Dashboard -> Live TV -> Add M3U Tuner` (paste the Dispatcharr M3U URL), `Add XMLTV` guide provider (paste the Dispatcharr XMLTV URL), Save, refresh guide data, test one channel.

## Gluetun Compose Pattern (Optional VPN Egress)

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

## Gluetun Routing Proof

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

Pass: `dispatcharr` shows `network_mode: service:gluetun`; both Gluetun and Dispatcharr return VPN-provider IPs; neither equals the home WAN IP.

A host-level `curl` of the playlist URL only proves the Docker VM host can reach it — test the playlist from inside the Dispatcharr namespace instead:

```bash
docker exec dispatcharr sh -lc \
  'curl -fsSL --max-time 30 https://iptv-org.github.io/iptv/countries/de.m3u || wget -qO- --timeout=30 https://iptv-org.github.io/iptv/countries/de.m3u' \
  | sed -n '1,20p'
```

## Jellyfin Playback Routing Check

```bash
curl -fsS "PASTE_DISPATCHARR_M3U_EXPORT_URL_HERE" | grep -E 'https?://' | head -20
```

If the URLs point to `192.168.1.20:9191`, `dispatcharr`, or a Dispatcharr proxy/stream endpoint, Jellyfin playback flows through Dispatcharr and therefore through Gluetun. If they point to original upstream domains, Jellyfin fetches those streams directly — Gluetun protects Dispatcharr's own source refresh/preview traffic, but not Jellyfin playback traffic, in that case.

## Kill-Switch Test

Interrupts only the Live TV Gluetun stack.

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
  docker inspect -f '{{.State.Health.Status}}' live-tv-gluetun 2>/dev/null | grep -q healthy && { echo "live-tv-gluetun healthy"; break; }
  echo "waiting for live-tv-gluetun health..."; sleep 2
done

docker exec dispatcharr sh -lc 'wget -qO- --timeout=15 https://ifconfig.me || curl -4 -fsS --max-time 15 https://ifconfig.me'
```

Pass: Dispatcharr reaches the internet before the test with a VPN IP; after stopping `live-tv-gluetun`, it cannot reach the internet and never prints the home WAN IP; after restore, both become healthy and return a VPN IP again.

If Dispatcharr returns the home WAN IP at any point:

```bash
cd /opt/stacks/live-tv
docker compose stop dispatcharr gluetun
```

Fix Compose (most likely `dispatcharr` is missing `network_mode: "service:gluetun"`, or the wrong compose file is running) before using the source again.

## DNS And IPv6 Checks

```bash
cd /opt/stacks/live-tv
docker exec dispatcharr cat /etc/resolv.conf
docker exec dispatcharr sh -lc 'curl -6 -fsS --max-time 10 https://ifconfig.me && echo "IPv6 LEAK: investigate" || echo "IPv6 blocked as expected"'
docker exec dispatcharr sh -lc 'getent hosts example.com || nslookup example.com || true'
```

Pass: IPv6 does not connect (unless intentionally designed otherwise); DNS lookups succeed while Gluetun is healthy; resolver does not point directly at the LAN router or ISP DNS.

## Sports Setup Checklist

1. Make Germany/public channels work first.
2. Add `Sports - iptv-org Review`.
3. Keep only legal public/free streams; disable premium/app-only names unless provider-authorized.
4. Use channel numbers `300-399`.
5. Test every sports channel before adding to Jellyfin.
6. If recording, use DVR padding: 5 minutes pre, 30-60 minutes post.

## Maintenance

Monthly: refresh each M3U source, check disabled/new groups, play one German/English/sports/news channel, confirm EPG mapping, re-run the Gluetun routing proof, and re-run the kill-switch test after any Gluetun or Compose change.

After adding a new source: keep new groups disabled by default, review quality/legality, add only wanted channels, test Dispatcharr playback, test Jellyfin playback, and confirm whether Jellyfin is using Dispatcharr proxy URLs or direct upstream URLs.

## Troubleshooting

### Dispatcharr Play Starts Then Stops Immediately

| Cause | What it looks like | Fix |
|---|---|---|
| Dead stream URL | Starts then stops, or loops | Disable and try another source/quality |
| Geo-blocked | Works in some regions, fails via current VPN region | Use a legal source for your region, or change VPN region if allowed |
| Non-HLS/unsupported URL | Points to Twitch/web page/unsupported player | Disable; Dispatcharr/Jellyfin need `.m3u8`-style playable URLs |
| DRM/app-only stream | Premium name, starts briefly or never | Disable; use the official app |
| VPN timeout/DNS issue | Many channels fail at once | Check `live-tv-gluetun` health and test from inside `dispatcharr` |
| Cached failed-attempt state | First click stops, second click loops | Refresh the Dispatcharr page after disabling the bad stream |

Gluetun log lines confirming VPN routing is working:

```text
[openvpn] Initialization Sequence Completed
[dns] ready and using DNS server with doh upstream resolvers
[ip getter] Public IP address is ... Germany ... Frankfurt am Main
```

Dispatcharr log lines indicating a dead URL (disable the stream, don't keep retrying):

```text
HTTP error 404 Not Found
Error opening input files: Server returned 404 Not Found
Maximum retry attempts (3) reached
```

Dispatcharr log lines indicating a reached-but-unusable stream (disable or try another quality/source):

```text
connected but waiting for buffer to fill: 0/4 chunks
Stream unhealthy ... no data for 5.0s
stalled in connecting state with no buffer data after 5s
```

Isolate a one-channel problem from a stack-wide problem:

```bash
cd /opt/stacks/live-tv
docker compose ps
docker logs --tail 120 live-tv-gluetun
docker logs --tail 120 dispatcharr

HOME_WAN_IP="$(curl -4 -fsS --max-time 15 https://ifconfig.me)"
docker exec dispatcharr sh -lc 'wget -qO- --timeout=15 https://ifconfig.me || curl -4 -fsS --max-time 15 https://ifconfig.me'
```

Try one channel each from three different sources:

| Result | Meaning |
|---|---|
| Only one channel fails | That channel/URL is bad or blocked — disable it |
| Every channel from one source fails | That M3U source has bad URLs or needs a different VPN region — disable the source for now |
| Every source fails | Check Gluetun, DNS, Dispatcharr logs, and Compose routing |

If a raw stream URL is available, test it directly:

```bash
docker exec dispatcharr sh -lc \
  'curl -L -I --max-time 20 "PASTE_STREAM_URL_HERE" || wget --spider --timeout=20 "PASTE_STREAM_URL_HERE"'
```

Good signs: HTTP `200`/`206`/normal redirect to `.m3u8`; HLS/MPEG-TS/video/plain-text content-type. Bad signs: `403`/`404`/`451`/`5xx`/timeout; `content-type: text/html`; login/session/cookie/token-only behavior; a premium app/player page instead of an HLS stream.

If many channels fail only while Gluetun is enabled, try a different nearby VPN region and only keep it if the routing proof and kill-switch test still pass:

```bash
cd /opt/stacks/live-tv
docker compose up -d --force-recreate gluetun dispatcharr
docker exec dispatcharr sh -lc 'wget -qO- --timeout=15 https://ifconfig.me || curl -4 -fsS --max-time 15 https://ifconfig.me'
```

### Playlist Works From Host But Not Dispatcharr

The host command uses the Docker VM's own network; Dispatcharr may be behind Gluetun. Test inside the container:

```bash
docker exec dispatcharr sh -lc \
  'curl -fsSL --max-time 30 https://iptv-org.github.io/iptv/countries/de.m3u || wget -qO- --timeout=30 https://iptv-org.github.io/iptv/countries/de.m3u' \
  | sed -n '1,20p'
```

If this fails but the host `curl` works, check Gluetun health, DNS, and PIA credentials.

### Too Many Bad Channels / Premium Entries In Public Playlists

Disable auto-sync for noisy groups, enable orphan cleanup, refresh the source, delete unwanted channels manually. Leave premium-looking entries disabled unless verified as official free streams or provider-authorized raw M3U/XMLTV.

## Done Criteria

- [ ] Dispatcharr source uses `Standard`/`Standard M3U`, not Xtream Codes.
- [ ] Only reviewed groups auto-sync; new groups are disabled by default.
- [ ] Low-quality duplicates and premium/app-only channels are disabled unless needed/authorized.
- [ ] One German channel plays; one English and one sports channel play if configured.
- [ ] EPG maps for kept channels, or missing EPG is documented.
- [ ] Jellyfin M3U and XMLTV exports open from the Docker VM.
- [ ] `dispatcharr` returns a VPN IP when Gluetun mode is enabled, and the same M3U source downloads from inside `dispatcharr`.
- [ ] Kill-switch test blocks Dispatcharr when `live-tv-gluetun` is stopped.
- [ ] Jellyfin playback routing (proxy vs. direct upstream) is understood and documented.

## References

- [iptv-org playlists](https://github.com/iptv-org/iptv/blob/master/PLAYLISTS.md)
- [Free-TV/IPTV playlist](https://github.com/Free-TV/IPTV)
- [TDTChannels repository](https://github.com/LaQuay/TDTChannels)
