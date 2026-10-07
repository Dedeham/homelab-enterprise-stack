# Public Access Via Cloudflare Tunnel: Jellyfin And Seerr

Last updated: 2026-06-28

This guide exposes Jellyfin and Seerr through Cloudflare Tunnel while keeping
the home router closed to inbound internet traffic. Both services share the
same tunnel and the same `cloudflared` container on the Docker VM; only the
per-service Traefik labels, Cloudflare public hostname, and access policy
differ. The common tunnel setup is covered once below, followed by a section
for each service's differences.

Public traffic for both services follows this path:

```text
Internet client
  -> Cloudflare (+ Cloudflare Access for Seerr)
  -> Cloudflare Tunnel
  -> cloudflared container on Docker VM
  -> Traefik
  -> Jellyfin or Seerr
```

Use this after:

1. The Ubuntu Docker VM is running at `192.168.1.20`.
2. Traefik is running on the Docker VM, with a valid Let's Encrypt certificate
   through the Cloudflare DNS challenge (see
   [ssl-traefik-cloudflare.md](ssl-traefik-cloudflare.md)).
3. Jellyfin works locally through Traefik, and/or Seerr works locally at
   `http://192.168.1.20:5055` with working connections to Jellyfin, Radarr,
   and Sonarr.
4. Your domain uses Cloudflare nameservers.

Do not expose raw Jellyfin, Seerr, Radarr, Sonarr, Prowlarr, or qBittorrent
ports to the internet. Public traffic for Radarr, Sonarr, Prowlarr, and
qBittorrent should never go through the tunnel at all — Seerr talks to them
locally on the Docker VM.

## Current Homestack Values

Replace these if your live values differ.

| Item | Value |
|---|---|
| Docker VM SSH user | `alice` |
| Docker VM IP | `192.168.1.20` |
| Traefik stack path | `/opt/stacks/traefik` |
| Traefik container name | `traefik` |
| Jellyfin stack path | `/opt/stacks/jellyfin-stack` |
| ARR stack path (includes Seerr) | `/opt/stacks/arr-stack` |
| cloudflared stack path | `/opt/stacks/cloudflared` |
| Shared Docker proxy network | `proxy` |
| Public Jellyfin hostname | `media.example.com` |
| Public Seerr hostname | `requests.example.com` |
| Seerr container name / internal port | `seerr` / `5055` |

`requests.example.com` is used for Seerr instead of `seerr.example.com`
because it is clearer for non-admin users; use whichever hostname you prefer.

## Security Position

Baseline decisions, common to both services:

- Use Cloudflare Tunnel, not router port forwarding.
- Keep both services behind Traefik.
- Keep Radarr, Sonarr, Prowlarr, qBittorrent, FlareSolverr, Proxmox, TrueNAS,
  SSH, Pi-hole admin, Traefik dashboard, Dockge, Portainer-style tools, and
  Grafana private over LAN or Tailscale only.

Where the two services differ:

| | Jellyfin | Seerr |
|---|---|---|
| Outer auth gate (Authelia / Cloudflare Access) | No, by default | Yes, Cloudflare Access by default |
| Why | Jellyfin has its own account system; TV, mobile, and media clients expect the Jellyfin API directly, and a second browser login layer can break or annoy non-browser clients | Seerr is a browser request app, so an outer auth layer is practical; a compromised Seerr admin account can trigger downloads and queue/library changes |
| `admin-whitelist@file` middleware | Not applicable | Must not be used on the public Seerr router — it is for LAN/Tailscale-only admin services and would block normal public users |

If Authelia and CrowdSec are already deployed (see
[authelia-crowdsec-setup.md](../security/authelia-crowdsec-setup.md) and
[crowdsec-all-services.md](../security/crowdsec-all-services.md)) and you want
them instead of, or alongside, Cloudflare Access for Seerr, use:

```yaml
      - "traefik.http.routers.seerr.middlewares=crowdsec@docker,authelia@docker,security-headers@file,rate-limit@file"
```

Do not use both Cloudflare Access and Authelia on the same router unless you
intentionally want two separate login gates.

## Part 1: Common Tunnel Setup

### Step 1: SSH To The Docker VM And Confirm Identity

```bash
ssh alice@192.168.1.20
hostname
ip addr show
docker --version
docker compose version
```

### Step 2: Confirm Traefik Is Healthy

```bash
export TRAEFIK_DIR="/opt/stacks/traefik"
cd "$TRAEFIK_DIR"
docker compose ps
docker compose logs --tail=100 traefik
docker network inspect proxy >/dev/null && echo "OK: proxy network exists"
sudo ss -tulpn | grep -E ':(80|443)\b'
```

Expected:

- `traefik` and `socket-proxy` are running.
- No Cloudflare DNS challenge authentication failures in the logs.
- Traefik listens on `80` and `443` locally (this does not mean the internet
  can reach those ports — router forwarding is checked later).

### Step 3: Create The Cloudflare Tunnel In The Dashboard

If a tunnel already exists for this Docker VM (e.g. you're adding the second
of the two services), reuse it and skip to Step 5.

In Cloudflare:

```text
Cloudflare One -> Networks -> Tunnels -> Create a tunnel
```

Choose:

```text
Connector type: cloudflared
Tunnel name: homestack-docker-vm
Environment: Docker
```

Cloudflare will show a Docker command with a long tunnel token. Copy only the
token value. Do not paste the token into chat, screenshots, git, or public
docs.

### Step 4: Create The cloudflared Stack On The Docker VM

```bash
export CLOUDFLARED_DIR="/opt/stacks/cloudflared"
sudo mkdir -p "$CLOUDFLARED_DIR"
sudo chown -R "$USER":"$USER" "$CLOUDFLARED_DIR"
cd "$CLOUDFLARED_DIR"
nano .env
```

Put this in `.env`:

```text
TUNNEL_TOKEN=paste_cloudflare_tunnel_token_here
```

Lock down the env file:

```bash
chmod 600 .env
```

Create the compose file:

```bash
cat > docker-compose.yml <<'EOF'
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate run --token ${TUNNEL_TOKEN}
    security_opt:
      - no-new-privileges:true
    read_only: true
    cap_drop:
      - ALL
    networks:
      - proxy
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  proxy:
    external: true
EOF
```

Start it:

```bash
docker compose up -d
docker compose ps
docker compose logs -f --tail=100
```

Expected:

- The connector appears healthy in the Cloudflare dashboard.
- Logs show the tunnel connected.
- The `cloudflared` container publishes no host ports.

Security note: the token appears in the Docker container command because this
is how the dashboard-managed Docker connector is normally run. Treat the
Docker VM as a trusted host. If the token is exposed, delete or rotate the
tunnel token in Cloudflare.

Continue with whichever service-specific section below applies, then come
back to [Part 3](#part-3-shared-safety-checks) for the shared safety checks.

## Part 2a: Jellyfin-Specific Steps

### Confirm Jellyfin Is Routed Only Through Traefik

```bash
export JELLYFIN_DIR="/opt/stacks/jellyfin-stack"
cd "$JELLYFIN_DIR"
docker compose ps
docker compose logs --tail=100 jellyfin

docker inspect jellyfin \
  --format '{{range $k,$v := .Config.Labels}}{{println $k "=" $v}}{{end}}' \
  | sort
```

Expected important labels:

```text
traefik.enable = true
traefik.http.routers.jellyfin.rule = Host(`media.example.com`)
traefik.http.routers.jellyfin.entrypoints = websecure
traefik.http.routers.jellyfin.tls.certresolver = cloudflare
traefik.http.services.jellyfin.loadbalancer.server.port = 8096
```

Confirm Jellyfin does not publish raw ports to the host:

```bash
docker inspect jellyfin --format '{{json .HostConfig.PortBindings}}'
```

Expected: `null` or `{}`. If you see `8096` or `8920` published, remove the
direct port mapping before public exposure.

Confirm Jellyfin media mounts are read-only:

```bash
docker inspect jellyfin \
  --format '{{range .Mounts}}{{println .Source "->" .Destination "RW=" .RW}}{{end}}'
```

Expected for media libraries (`/mnt/media/movies`, `/mnt/media/tv-shows`,
`/mnt/media/music`): `RW=false`. The config mount can remain writable.

### Test Local HTTPS Before The Tunnel

```bash
export DOMAIN="example.com"
export MEDIA_HOST="media.${DOMAIN}"
curl -kI --resolve "${MEDIA_HOST}:443:192.168.1.20" "https://${MEDIA_HOST}/"
curl -kfsS --resolve "${MEDIA_HOST}:443:192.168.1.20" "https://${MEDIA_HOST}/health"
```

Fix Traefik or Jellyfin before creating the public hostname if this fails.

### Add The Public Hostname

In the Cloudflare Tunnel, under **Public Hostnames -> Add a public hostname**:

| Field | Value |
|---|---|
| Subdomain | `media` |
| Domain | `example.com` |
| Path | blank |
| Type | `HTTPS` |
| URL | `traefik:443` |
| HTTP Host Header | `media.example.com` |
| Origin Server Name | `media.example.com` |
| No TLS Verify | off |

Do not enable `No TLS Verify` for the final setup. If you temporarily enable
it during troubleshooting, turn it off again once Traefik's certificate/SNI
is confirmed working.

Cloudflare should automatically create a DNS record similar to:

```text
media.example.com CNAME <tunnel-id>.cfargotunnel.com
```

### Disable Cache For Jellyfin

Jellyfin is dynamic streaming traffic — do not rely on Cloudflare caching it.

In Cloudflare, under **Rules -> Cache Rules -> Create rule**:

```text
Rule name: Bypass cache for Jellyfin
If: Hostname equals media.example.com
Then: Bypass cache
```

### Confirm Jellyfin Remote Access Controls

In Jellyfin, under **Dashboard -> Networking**:

| Setting | Recommendation |
|---|---|
| Allow remote connections to this server | enabled only if you want public access |
| Known proxies | Traefik/proxy network if enforcing forwarded client IP behavior |
| Local networks | your LAN CIDR, e.g. `192.168.1.0/24` |

For each Jellyfin user, under **Dashboard -> Users -> select user**:

- Use a strong unique password.
- Disable remote connections for users who only need LAN access.
- Do not share the admin account.
- Create normal non-admin accounts for watching; keep the admin account for
  administration only.

### Test Through Cloudflare

```bash
nslookup "${MEDIA_HOST}"
curl -I "https://${MEDIA_HOST}/"
curl -fsS "https://${MEDIA_HOST}/health"
```

Then, from a phone on cellular data, open `https://media.example.com`,
confirm the login page loads, login works with a non-admin user, and playback
is acceptable. If playback buffers badly, Cloudflare Tunnel may not be the
right path for this media workload — consider Tailscale or direct Traefik
forwarding with strict firewalling instead.

### Jellyfin Incident Response

If a Jellyfin account is stolen: disable or change that user's password,
revoke active sessions if available, review Jellyfin logs, and confirm the
account was not an admin.

If the Jellyfin admin account is stolen:

```bash
cd "$CLOUDFLARED_DIR" && docker compose stop
cd "$JELLYFIN_DIR" && docker compose stop jellyfin
```

Then: disable the Cloudflare public hostname or tunnel route; change all
Jellyfin passwords; remove unknown users, API keys, and plugins; review logs
under `/mnt/main/appdata/jellyfin`; restore config from a known-good snapshot
if settings changed; restart only once you understand what changed.

If container escape or host compromise is suspected: stop the tunnel, stop
Jellyfin, do not delete logs, rotate the Cloudflare tunnel token and DNS API
token, rotate Jellyfin passwords, rebuild the container from a known-good
compose file, and consider restoring the Docker VM from a known-good backup.

## Part 2b: Seerr-Specific Steps

### Confirm Seerr Works Locally First

```bash
export ARR_DIR="/opt/stacks/arr-stack"
cd "$ARR_DIR"
docker compose ps seerr
docker compose logs --tail=100 seerr
```

From a LAN browser, open `http://192.168.1.20:5055`, sign in as admin, and
confirm Seerr can reach Jellyfin and create test requests in Radarr and
Sonarr. Fix the ARR stack before adding public access if this does not work.

Keep Seerr's backend app URLs pointed at the local Docker VM, not public
hostnames:

| Backend | URL from Seerr |
|---|---|
| Jellyfin | `http://jellyfin:8096` if it works, otherwise `http://192.168.1.20:8096` |
| Radarr | `http://192.168.1.20:7878` |
| Sonarr | `http://192.168.1.20:8989` |

Do not expose `radarr.example.com`, `sonarr.example.com`,
`prowlarr.example.com`, `qbittorrent.example.com`, or
`flaresolverr.example.com` through Cloudflare Tunnel.

### Add Seerr To Traefik

```bash
cd "$ARR_DIR"
cp docker-compose.yml docker-compose.yml.before-seerr-public
nano docker-compose.yml
```

In the `seerr` service, keep the existing settings and add Traefik labels
plus the `proxy` network. If the service currently has no `networks:` block,
use this pattern:

```yaml
services:
  seerr:
    # keep the existing image, container_name, environment, volumes, and depends_on
    networks:
      - default
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      - "traefik.http.routers.seerr.rule=Host(`requests.${DOMAIN}`)"
      - "traefik.http.routers.seerr.entrypoints=websecure"
      - "traefik.http.routers.seerr.tls.certresolver=cloudflare"
      - "traefik.http.routers.seerr.middlewares=security-headers@file,rate-limit@file"
      - "traefik.http.services.seerr.loadbalancer.server.port=5055"

networks:
  proxy:
    external: true
```

If the service already has a `networks:` block, add `proxy` to that list
instead of replacing it — do not remove the network Seerr uses to reach
Jellyfin or the ARR stack. If a top-level `networks:` section already exists,
add only the `proxy: {external: true}` entry under it.

Validate and apply:

```bash
docker compose config
docker compose up -d seerr
docker compose ps seerr
docker inspect seerr \
  --format '{{range $k,$v := .Config.Labels}}{{println $k "=" $v}}{{end}}' \
  | sort
```

### Test Local HTTPS Before The Tunnel

```bash
export DOMAIN="example.com"
export SEERR_HOST="requests.${DOMAIN}"
curl -kI --resolve "${SEERR_HOST}:443:192.168.1.20" "https://${SEERR_HOST}/"
```

Expected: Traefik responds with `200`, `302`, or `307` — not `404` (hostname
didn't match; check the Host rule and labels) and not `502`/`504` (Traefik
can't reach Seerr; check the `proxy` network attachment and port `5055`).

### Set Seerr's Public URL

In Seerr, under **Settings -> General**, set the application/external URL to
`https://requests.example.com` (exact wording varies by version) so that
generated links, notifications, and redirects use the public hostname.

Also review Seerr user settings before public exposure: keep Seerr login
enabled, prefer Jellyfin-backed users if that matches your setup, give normal
users request permissions only, keep admin permissions limited to your own
account, disable open registration/broad default permissions, and keep 4K
requests disabled unless you have separate profiles and storage.

### Add The Public Hostname

In the Cloudflare Tunnel, under **Public Hostnames -> Add a public hostname**:

| Field | Value |
|---|---|
| Subdomain | `requests` |
| Domain | `example.com` |
| Path | blank |
| Type | `HTTPS` |
| URL | `traefik:443` |
| HTTP Host Header | `requests.example.com` |
| Origin Server Name | `requests.example.com` |
| No TLS Verify | off |

Cloudflare should automatically create a DNS record similar to:

```text
requests.example.com CNAME <tunnel-id>.cfargotunnel.com
```

### Add A Cloudflare Access Policy

In Cloudflare Zero Trust, under **Access -> Applications -> Add an
application -> Self-hosted**, create an application for
`https://requests.example.com` with:

| Setting | Value |
|---|---|
| Action | `Allow` |
| Include | Your email, your family's emails, or a small email domain/group |
| Session duration | `24h` or `1 week` |
| Login method | One-time PIN or your configured identity provider |

Do not create a public bypass policy. To test without Access, disable the
public hostname briefly instead of leaving a bypass rule in place. Every
remote user passes Cloudflare Access login, then Seerr's own login — this is
intentional layering: Access decides who may reach the app, Seerr decides
what they can request.

### Disable Cache For Seerr

In Cloudflare, under **Rules -> Cache Rules -> Create rule**:

```text
Rule name: Bypass cache for Seerr
If: Hostname equals requests.example.com
Then: Bypass cache
```

### Test Through Cloudflare

```bash
nslookup "${SEERR_HOST}"
curl -I "https://${SEERR_HOST}/"
```

From a phone on cellular data, open `https://requests.example.com`, pass
Cloudflare Access, sign in to Seerr, search for a title, submit one controlled
request, and confirm it appears in Radarr or Sonarr with the expected root
folder and quality profile. Do not run a real broad download test until the
ARR VPN leak and kill-switch checks have passed (see
[../services/arr-stack.md](../services/arr-stack.md)).

### Remove The Direct Seerr Port After Validation

Once `https://requests.example.com` works through Traefik and Cloudflare,
remove the raw LAN-published Seerr port unless a local fallback is still
needed:

```yaml
    ports:
      - "5055:5055"   # remove or comment out
```

```bash
cd "$ARR_DIR"
docker compose up -d seerr
docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep -E 'seerr|traefik|cloudflared'
```

Expected: Traefik publishes `80`/`443`, `cloudflared` and `seerr` publish no
host ports, and Seerr remains reachable through the HTTPS hostname. If you
still need LAN access without the direct port, add a Pi-hole local DNS record
for `requests.example.com -> 192.168.1.20` — Cloudflare Access only applies to
traffic that goes through Cloudflare, so Seerr's own login remains important
for LAN split-DNS traffic.

### Seerr Incident Response

If a normal Seerr user account is stolen: disable or remove that user, revoke
sessions if available, review pending requests and the Radarr/Sonarr queues,
and tighten the Cloudflare Access allowed users if needed.

If the Seerr admin account is stolen:

```bash
cd "$CLOUDFLARED_DIR" && docker compose stop
cd "$ARR_DIR" && docker compose stop seerr
```

Then: disable the Cloudflare public hostname or Access application; change
Seerr admin credentials; remove unknown Seerr users/permissions; rotate
Radarr, Sonarr, and Jellyfin API keys used by Seerr; review the Radarr,
Sonarr, and qBittorrent queues and Seerr's recent request history; restart
only once you understand what changed.

If host or container compromise is suspected: stop the tunnel, stop Seerr, do
not delete logs, rotate the Cloudflare tunnel token and DNS API token, rotate
Seerr/Radarr/Sonarr/Jellyfin credentials and API keys, rebuild the container
from a known-good compose file, and consider restoring the Docker VM from a
known-good backup.

## Part 3: Shared Safety Checks

Run these after either or both services are live.

### Router And Firewall Safety Checks

```bash
sudo ufw status verbose
sudo ss -tulpn | grep -E ':(22|80|443|5055|7878|8989|9696|8080|8096|8920)\b'
```

Expected: SSH reachable only from LAN/Tailscale; Traefik may listen on `80`
and `443` locally; Jellyfin should not listen on host ports `8096`/`8920`;
Seerr may still listen on `5055` during migration but should not be reachable
from the WAN; Radarr, Sonarr, Prowlarr, and qBittorrent stay private.

In the router/firewall UI, verify there are no WAN forwards for any of:
`22, 80, 443, 5055, 7878, 8989, 9696, 8080, 8191, 8096, 8920, 3000, 3001,
9000, 9443`.

From a network outside your home, optionally scan the WAN IP:

```bash
nmap -Pn -p 22,80,443,5055,7878,8989,9696,8080,8096,8920 YOUR_PUBLIC_WAN_IP
```

Expected: `closed` or `filtered` for all of them. Any `open` result means you
are not using the closed-router tunnel model and should stop and remove the
offending router port forward before continuing.

### Docker Safety Checks

```bash
docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

Expected: Traefik may publish `80`/`443`; `cloudflared` publishes no ports;
Jellyfin and Seerr publish no host ports (after migration for Seerr).

```bash
docker inspect jellyfin \
  --format 'User={{.Config.User}} SecurityOpt={{json .HostConfig.SecurityOpt}} Privileged={{.HostConfig.Privileged}}'
docker inspect seerr \
  --format 'User={{.Config.User}} SecurityOpt={{json .HostConfig.SecurityOpt}} Privileged={{.HostConfig.Privileged}}'
```

Expected: `Privileged=false` and preferably `no-new-privileges:true` for both.

```bash
docker inspect jellyfin \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' \
  | grep -E 'docker.sock|/var/run' || echo "OK: no Docker socket mount"
docker inspect seerr \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' \
  | grep -E 'docker.sock|/var/run' || echo "OK: no Docker socket mount"
```

Expected: neither container mounts the Docker socket.

```bash
docker inspect cloudflared \
  --format 'ReadonlyRootfs={{.HostConfig.ReadonlyRootfs}} Privileged={{.HostConfig.Privileged}} CapDrop={{json .HostConfig.CapDrop}}'
```

Expected: `ReadonlyRootfs=true`, `Privileged=false`, `CapDrop=["ALL"]`.

```bash
docker network inspect proxy \
  --format '{{range $id,$c := .Containers}}{{println $c.Name}}{{end}}' \
  | sort
```

This shows which containers share the reverse-proxy network — `traefik`,
`cloudflared`, `jellyfin`/`seerr`, and other intentionally reverse-proxied web
services. A future hardening improvement is per-service proxy networks, so a
compromised web app has less ability to talk sideways to unrelated
containers.

### Cloudflare Safety Checks

| Area | Standard |
|---|---|
| Domain | Active in Cloudflare |
| Tunnel | Healthy connector for the Docker VM |
| Public hostnames | Only `media.example.com` and `requests.example.com` |
| Service URL | `https://traefik:443` for both |
| HTTP Host Header / Origin Server Name | Matches the public hostname |
| No TLS Verify | off |
| Cache rules | Bypass cache for both hostnames |
| Access policy | Exists and restricts allowed users for Seerr; not required for Jellyfin unless all clients support it |

Do not publish management, ARR admin, or Dockge/Portainer/Grafana hostnames
through the tunnel (e.g. `proxmox.example.com`, `truenas.example.com`,
`ssh.example.com`, `dns.example.com`, `traefik.example.com`,
`dockge.example.com`, `portainer.example.com`, `grafana.example.com`,
`radarr.example.com`, `sonarr.example.com`, `prowlarr.example.com`,
`qbittorrent.example.com`).

## Pass/Fail Checklist

| Check | Pass condition |
|---|---|
| Traefik local HTTPS | Both hostnames work through Traefik locally |
| Jellyfin raw ports | No host port mapping for `8096`/`8920` |
| Seerr raw port | No host port mapping for `5055` after validation |
| Router WAN forwards | No WAN forwards to either service, ARR apps, SSH, or admin tools |
| Cloudflare Tunnel | Connector healthy |
| Cloudflare hostnames | Both route to `https://traefik:443` with correct Origin Server Name and `No TLS Verify` off |
| Cloudflare Access | Only intended users can reach Seerr |
| Cloudflare cache | Bypass rule exists for both hostnames |
| Jellyfin accounts | Strong unique passwords; admin account not used for watching |
| Seerr users | Normal users have request permissions only |
| Docker socket | Neither service mounts the Docker socket |
| Media mounts | Jellyfin media mounts are read-only |
| ARR admin UIs | Radarr, Sonarr, Prowlarr, qBittorrent stay private |
| Management UIs | Proxmox, TrueNAS, SSH, Pi-hole, Traefik dashboard, Dockge, Grafana stay private |

## References

- [ssl-traefik-cloudflare.md](ssl-traefik-cloudflare.md)
- [../security/authelia-crowdsec-setup.md](../security/authelia-crowdsec-setup.md)
- [../services/arr-stack.md](../services/arr-stack.md)
- Cloudflare Tunnel overview: <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/>
- Cloudflare dashboard tunnel creation: <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/>
- Cloudflare self-hosted applications: <https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/>
- Jellyfin networking: <https://jellyfin.org/docs/general/post-install/networking/>
