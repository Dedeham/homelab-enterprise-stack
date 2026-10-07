# Dispatcharr

Dispatcharr curates and re-exports Live TV M3U/XMLTV sources for Jellyfin Live TV, filtering legal/public playlists down to a clean, high-quality channel set. It is a separate stack from the ARR/debrid stacks, dedicated to Live TV only.

## Target Design

```text
Legal M3U/XMLTV source
-> Dispatcharr
-> clean Dispatcharr M3U/XMLTV export
-> Jellyfin Live TV
-> Jellyfin clients
```

Dispatcharr handles: adding legal M3U sources, selecting higher-quality/stable streams, filtering bad/duplicate/low-quality/questionable channels, adding EPG/XMLTV, and exporting one clean M3U/XMLTV pair for Jellyfin to consume. It does not cover bypassing paid apps, DRM, cookies, provider tokens, or geo-blocking — premium services (Sky/WOW, DAZN, MagentaSport, RTL+, etc.) belong in their official apps unless the provider explicitly grants legal raw M3U/XMLTV access.

## Optional VPN Egress

Dispatcharr can route through its own dedicated Live TV Gluetun gateway, separate from the ARR/torrent Gluetun and the debrid Gluetun, so it can be restarted and tested independently:

```text
live-tv-gluetun
+-- owns VPN tunnel, DNS, and firewall
+-- publishes Dispatcharr port 9191
+-- shares network namespace with dispatcharr
```

Compose pattern: `dispatcharr` uses `network_mode: "service:gluetun"`; port `9191` is published on `live-tv-gluetun`, not on `dispatcharr`, because Dispatcharr shares Gluetun's namespace. This Live TV Gluetun container is never attached to `debrid-gluetun` or the ARR/torrent Gluetun.

Even with Gluetun protecting Dispatcharr's own traffic (source refreshes, previews), Jellyfin playback can still bypass the VPN if the exported M3U contains direct upstream URLs rather than URLs pointing back through Dispatcharr's own proxy/stream endpoint. Whether playback is VPN-routed depends on whether the Dispatcharr export uses its own proxy path or passes through original upstream domains.

## Quality Rules

High quality does not mean highest resolution at any cost — a stable 720p/1080p stream beats a 4K stream that stalls or redirects. A stream is kept only if it is from a legal/authorized source, starts quickly, plays 30-60 seconds without constant buffering, matches its channel name, is 720p/1080p (reject low-quality duplicates unless needed), survives a source refresh, and has no cookies/rotating tokens/browser sessions/DRM/suspicious mirrors.

## Current Live Sources (Sports Focus)

| Order | Source name | Channel range | Notes |
|---:|---|---:|---|
| 1 | `Sports - iptv-org Review` | 300-349 | Sports-only public playlist, noisy but focused |
| 2 | `Sports - Free-TV IPTV Review` | 350-379 | Quality-over-quantity free TV playlist |
| 3 | `Sports - TDTChannels Spain Review` | 380-399 | Spanish free/open TV list with integrated EPG |
| 4 | `Sports - iptv-org English Review` | 200-249 | English-language public/FAST list, filtered to sports |
| 5 | `Sports - iptv-org Germany Review` | 1-99 | German public/general channels that may carry sports events |

The all-channels playlist (`https://iptv-org.github.io/iptv/index.m3u`) is intentionally avoided for normal use — too noisy for quality control.

## Numbering Convention

| Group | Start number |
|---|---:|
| German public/general | 1 |
| German regional/public | 100 |
| English | 200 |
| Sports | 300 |
| News | 400 |
| Public/community | 600 |
| Temporary/test | 900 |

Fixed channel numbering is used throughout so Jellyfin channel numbers stay predictable.

## Storage

| Path | Role |
|---|---|
| `/srv/appdata/dispatcharr` (mounted as `/data`) | Dispatcharr config/database (local VM storage, not NFS) |
| `/mnt/main/appdata/live-tv/sources` | Source files and backups |
| `/mnt/media/data/live-tv/dispatcharr-recordings` | DVR recordings |

## References

- [iptv-org playlists](https://github.com/iptv-org/iptv/blob/master/PLAYLISTS.md)
- [Free-TV/IPTV playlist](https://github.com/Free-TV/IPTV)
- [TDTChannels lists](https://www.tdtchannels.com/listas/)
