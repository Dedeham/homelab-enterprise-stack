# Seerr Public Access With Cloudflare Tunnel And Traefik

Last updated: 2026-06-28

This guide exposes your Seerr request app at
`https://requests.example.com` through Cloudflare Tunnel while keeping the
home router closed to inbound internet traffic.

Use this after:

1. The Ubuntu Docker VM is running at `192.168.1.20`.
2. Traefik is running on the Docker VM.
3. Seerr works locally at `http://192.168.1.20:5055`.
4. Jellyfin, Radarr, and Sonarr already work from Seerr.
5. Your domain uses Cloudflare nameservers.
6. Traefik already has a valid Let's Encrypt certificate through the
   Cloudflare DNS challenge.

Do not expose raw Seerr, Radarr, Sonarr, Prowlarr, or qBittorrent ports to the
internet. Public traffic should go:

```text
Internet client
  -> Cloudflare Access
  -> Cloudflare Tunnel
  -> cloudflared container on Docker VM
  -> Traefik
  -> Seerr
```

## Current Homestack Values

Replace these if your live values differ.

| Item | Value |
|---|---|
| Docker VM SSH user | `alice` |
| Docker VM IP | `192.168.1.20` |
| Traefik stack path | `/opt/stacks/traefik` |
| ARR stack path | `/opt/stacks/arr-stack` |
| cloudflared stack path | `/opt/stacks/cloudflared` |
| Public Seerr hostname | `requests.example.com` |
| Seerr container name | `seerr` |
| Seerr internal port | `5055` |
| Traefik container name | `traefik` |
| Shared Docker proxy network | `proxy` |

Use `seerr.example.com` instead if you prefer that hostname. The examples
use `requests.example.com` because it is clearer for non-admin users.

## Security Position

Baseline decision:

- Use Cloudflare Tunnel, not router port forwarding.
- Keep Seerr behind Traefik.
- Put Cloudflare Access in front of Seerr by default.
- Keep Seerr's own login enabled too.
- Keep Radarr, Sonarr, Prowlarr, qBittorrent, FlareSolverr, Proxmox, TrueNAS,
  SSH, Pi-hole admin, Traefik dashboard, Dockge, Portainer-style tools, and
  Grafana private over LAN or Tailscale only.

Why Cloudflare Access for Seerr:

- Seerr is a browser request app, so an outer browser auth layer is practical.
- Seerr can trigger requests in Radarr and Sonarr.
- A compromised Seerr admin account can cause downloads, queue changes, and
  library churn even if it cannot directly manage the Docker host.

Do not put `admin-whitelist@file` on the public Seerr router. It is meant for
LAN/Tailscale-only admin services and will block normal public users.

## Step 1: SSH To The Docker VM

Run this from your workstation:

```bash
ssh alice@192.168.1.20
```

Set helper variables on the Docker VM:

```bash
export DOMAIN="example.com"
export SEERR_HOST="requests.${DOMAIN}"
export TRAEFIK_DIR="/opt/stacks/traefik"
export ARR_DIR="/opt/stacks/arr-stack"
export CLOUDFLARED_DIR="/opt/stacks/cloudflared"
```

Confirm the VM identity:

```bash
hostname
ip addr show
docker --version
docker compose version
```

## Step 2: Confirm Traefik Is Healthy

```bash
cd "$TRAEFIK_DIR"
docker compose ps
docker compose logs --tail=100 traefik
```

Expected:

- `traefik` is running.
- `socket-proxy` is running.
- Traefik logs do not show Cloudflare DNS challenge authentication failures.

Check that the `proxy` Docker network exists:

```bash
docker network inspect proxy >/dev/null && echo "OK: proxy network exists"
```

Confirm Traefik is listening on the Docker VM:

```bash
sudo ss -tulpn | grep -E ':(80|443)\b'
```

Expected:

- Traefik listens on `80` and `443` on the Docker VM.
- The router still has no WAN port forwards.

## Step 3: Confirm Seerr Works Locally First

```bash
cd "$ARR_DIR"
docker compose ps seerr
docker compose logs --tail=100 seerr
```

From a LAN browser, open:

```text
http://192.168.1.20:5055
```

Expected:

- Seerr loads.
- You can sign in as an admin.
- Seerr can reach Jellyfin.
- Seerr can create test requests in Radarr and Sonarr.

If local Seerr does not work, fix the ARR stack before adding public access.

## Step 4: Confirm Seerr's Internal App Connections

In Seerr, keep backend app URLs private. Use the values from the ARR guide:

| Backend | URL from Seerr |
|---|---|
| Jellyfin | `http://jellyfin:8096` if it works, otherwise `http://192.168.1.20:8096` |
| Radarr | `http://192.168.1.20:7878` |
| Sonarr | `http://192.168.1.20:8989` |

Do not change Seerr to point Radarr or Sonarr at public hostnames. Seerr should
talk to the local Docker VM, not out to Cloudflare and back.

Do not expose these through Cloudflare Tunnel:

```text
radarr.example.com
sonarr.example.com
prowlarr.example.com
qbittorrent.example.com
flaresolverr.example.com
```

## Step 5: Add Seerr To Traefik

Edit the live ARR compose file:

```bash
cd "$ARR_DIR"
cp docker-compose.yml docker-compose.yml.before-seerr-public
nano docker-compose.yml
```

In the `seerr` service, keep the existing settings and add Traefik labels plus
the `proxy` network.

If the service currently has no `networks:` block, use this pattern:

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

If the service already has a `networks:` block, add `proxy` to that existing
list. Do not remove the network Seerr already uses to reach Jellyfin or the ARR
stack.

If the compose file already has a top-level `networks:` section, add only this
entry under it:

```yaml
  proxy:
    external: true
```

If Authelia and CrowdSec are already deployed and you want them instead of
Cloudflare Access, use this middleware line:

```yaml
      - "traefik.http.routers.seerr.middlewares=crowdsec@docker,authelia@docker,security-headers@file,rate-limit@file"
```

Do not use both Cloudflare Access and Authelia unless you intentionally want two
separate login gates.

Validate and apply:

```bash
cd "$ARR_DIR"
docker compose config
docker compose up -d seerr
docker compose ps seerr
```

Confirm Traefik can see the route:

```bash
docker inspect seerr \
  --format '{{range $k,$v := .Config.Labels}}{{println $k "=" $v}}{{end}}' \
  | sort
```

Expected important labels:

```text
traefik.enable = true
traefik.docker.network = proxy
traefik.http.routers.seerr.rule = Host(`requests.example.com`)
traefik.http.routers.seerr.entrypoints = websecure
traefik.http.routers.seerr.tls.certresolver = cloudflare
traefik.http.services.seerr.loadbalancer.server.port = 5055
```

## Step 6: Test Local HTTPS Before Cloudflare Tunnel

From the Docker VM:

```bash
curl -kI --resolve "${SEERR_HOST}:443:192.168.1.20" "https://${SEERR_HOST}/"
```

Expected:

- Traefik responds for `requests.example.com`.
- HTTP status is usually `200`, `302`, or `307`.
- The response is not a Traefik `404`.
- The response is not a Traefik `502` or `504`.

If Traefik returns `404`, the router did not match the hostname. Check the
Host rule, `DOMAIN` value, and labels.

If Traefik returns `502` or `504`, the router matched but Traefik cannot reach
Seerr. Check that Seerr is attached to the `proxy` network and that the
load-balancer port is `5055`.

## Step 7: Set Seerr's Public URL

In Seerr:

```text
Settings -> General
```

Set the application URL or external URL to:

```text
https://requests.example.com
```

Exact wording can vary by Seerr version. The goal is that generated links,
notifications, and redirects use the public HTTPS hostname.

Review Seerr user settings before public exposure:

- Keep Seerr login enabled.
- Prefer Jellyfin-backed users if that matches your media setup.
- Give normal users request permissions only.
- Keep admin permissions limited to your own account.
- Disable open registration or automatic broad permissions unless you
  intentionally want that behavior.
- Keep 4K requests disabled unless you have separate profiles and storage for
  them.

## Step 8: Create Or Reuse The Cloudflare Tunnel

If you already created `homestack-docker-vm` for Jellyfin, reuse that tunnel and
skip to Step 9.

If no tunnel exists yet, create it in Cloudflare:

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

On the Docker VM:

```bash
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
is how the dashboard-managed Docker connector is normally run. Treat the Docker
VM as a trusted host. If the token is exposed, delete or rotate the tunnel
token in Cloudflare.

## Step 9: Add The Public Hostname

In the same Cloudflare Tunnel:

```text
Public Hostnames -> Add a public hostname
```

Set:

| Field | Value |
|---|---|
| Subdomain | `requests` |
| Domain | `example.com` |
| Path | blank |
| Type | `HTTPS` |
| URL | `traefik:443` |

Open the additional settings for that public hostname.

Set HTTP settings:

| Field | Value |
|---|---|
| HTTP Host Header | `requests.example.com` |

Set TLS settings:

| Field | Value |
|---|---|
| Origin Server Name | `requests.example.com` |
| No TLS Verify | off |

Do not enable `No TLS Verify` for the final setup. If you temporarily enable
it during troubleshooting, turn it off again after Traefik certificate/SNI is
fixed.

Cloudflare should automatically create a DNS record similar to:

```text
requests.example.com CNAME <tunnel-id>.cfargotunnel.com
```

## Step 10: Add A Cloudflare Access Policy

In Cloudflare Zero Trust:

```text
Access -> Applications -> Add an application -> Self-hosted
```

Create an application for:

```text
https://requests.example.com
```

Recommended policy:

| Setting | Value |
|---|---|
| Action | `Allow` |
| Include | Your email, your family's emails, or a small email domain/group |
| Session duration | `24h` or `1 week` |
| Login method | One-time PIN or your configured identity provider |

Do not create a public bypass policy for Seerr. If you need to test without
Access, disable the public hostname briefly instead of leaving a bypass rule in
place.

Every remote user should pass:

```text
Cloudflare Access login
-> Seerr login
```

This is intentional. Cloudflare Access decides who may reach the app at all;
Seerr decides what that person can request.

## Step 11: Disable Cache For Seerr

Seerr is a dynamic web application. Do not cache it at Cloudflare.

In Cloudflare:

```text
Rules -> Cache Rules -> Create rule
```

Set:

```text
Rule name: Bypass cache for Seerr
If: Hostname equals requests.example.com
Then: Bypass cache
```

## Step 12: Test Through Cloudflare

From the Docker VM:

```bash
nslookup "${SEERR_HOST}"
curl -I "https://${SEERR_HOST}/"
```

Expected:

- DNS resolves to Cloudflare, not directly to `192.168.1.20`, unless you are
  intentionally using split DNS on that client.
- The first browser visit shows Cloudflare Access.
- After Access login, Seerr shows its own login page.
- HTTPS works without certificate warnings.

From a phone on cellular data, open:

```text
https://requests.example.com
```

Test with a non-admin user:

1. Pass Cloudflare Access.
2. Sign in to Seerr.
3. Search for a title.
4. Submit one controlled request.
5. Confirm the request appears in Radarr or Sonarr with the expected root
   folder and quality profile.

Do not use a real broad download test until the ARR VPN leak and kill-switch
checks have already passed.

## Step 13: Router And Firewall Safety Checks

The secure tunnel model does not require inbound router port forwarding.

On the Docker VM:

```bash
sudo ufw status verbose
sudo ss -tulpn | grep -E ':(22|80|443|5055|7878|8989|9696|8080)\b'
```

Expected:

- SSH is reachable only from LAN/Tailscale according to your firewall design.
- Traefik may listen on `80` and `443` locally.
- Seerr may still listen on host port `5055` during migration, but should not
  be reachable from the WAN.
- Radarr, Sonarr, Prowlarr, and qBittorrent stay private.

In your router/firewall UI, verify there are no WAN forwards for:

```text
22
80
443
5055
7878
8989
9696
8080
8191
3000
3001
9000
9443
```

From a network outside your home, optionally scan your WAN IP:

```bash
nmap -Pn -p 22,80,443,5055,7878,8989,9696,8080 YOUR_PUBLIC_WAN_IP
```

Expected:

```text
closed
```

or:

```text
filtered
```

If `5055`, `7878`, `8989`, `9696`, or `8080` are open on the WAN IP, stop and
remove the router port forward before using public Seerr.

## Step 14: Remove The Direct Seerr Port After Validation

After `https://requests.example.com` works through Traefik and Cloudflare,
remove the raw LAN-published Seerr port unless you still need it for a specific
local fallback.

In the `seerr` service, remove or comment this kind of mapping if present:

```yaml
    ports:
      - "5055:5055"
```

Then apply:

```bash
cd "$ARR_DIR"
docker compose up -d seerr
docker compose ps seerr
docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep -E 'seerr|traefik|cloudflared'
```

Expected:

- Traefik publishes `80` and `443`.
- cloudflared publishes no host ports.
- Seerr publishes no host ports.
- Seerr remains reachable through `https://requests.example.com`.

If you remove the direct port, LAN access should use the same HTTPS hostname
through Traefik. Add a Pi-hole local DNS record if needed:

```text
requests.example.com -> 192.168.1.20
```

Cloudflare Access applies only when traffic goes through Cloudflare. LAN split
DNS traffic goes directly to Traefik, so Seerr's own login remains important.

## Step 15: Docker Safety Checks

Run these on the Docker VM.

Check direct port publishing:

```bash
docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

Expected:

- Traefik may publish `80` and `443`.
- cloudflared publishes no ports.
- Seerr should publish no ports after the migration.
- Radarr, Sonarr, Prowlarr, and qBittorrent are not exposed through Cloudflare.

Check Seerr privilege posture:

```bash
docker inspect seerr \
  --format 'User={{.Config.User}} SecurityOpt={{json .HostConfig.SecurityOpt}} Privileged={{.HostConfig.Privileged}}'
```

Expected:

```text
Privileged=false
```

and preferably:

```text
no-new-privileges:true
```

Check Seerr Docker socket exposure:

```bash
docker inspect seerr \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' \
  | grep -E 'docker.sock|/var/run' || echo "OK: no Docker socket mount"
```

Expected:

```text
OK: no Docker socket mount
```

Check who shares the `proxy` network:

```bash
docker network inspect proxy \
  --format '{{range $id,$c := .Containers}}{{println $c.Name}}{{end}}' \
  | sort
```

Expected:

- `traefik`
- `cloudflared`
- `seerr`
- Other intentionally reverse-proxied web services

## Step 16: Cloudflare Safety Checks

In Cloudflare, confirm:

| Area | Standard |
|---|---|
| Domain | Active in Cloudflare |
| Tunnel | Healthy connector for Docker VM |
| Public hostname | Only `requests.example.com` for Seerr |
| Service URL | `https://traefik:443` |
| HTTP Host Header | `requests.example.com` |
| Origin Server Name | `requests.example.com` |
| No TLS Verify | off |
| Access application | Exists for `requests.example.com` |
| Access policy | Allows only intended users |
| Cache rule | Bypass cache for `requests.example.com` |

Do not publish management or ARR admin hostnames through the tunnel:

```text
proxmox.example.com
truenas.example.com
ssh.example.com
dns.example.com
traefik.example.com
dockge.example.com
portainer.example.com
grafana.example.com
radarr.example.com
sonarr.example.com
prowlarr.example.com
qbittorrent.example.com
```

## Step 17: Incident Response If Seerr Is Compromised

If a normal Seerr user account is stolen:

1. Disable or remove that Seerr user.
2. Revoke the user's sessions if Seerr exposes that option.
3. Review pending requests.
4. Review Radarr and Sonarr queues for unwanted items.
5. Tighten Cloudflare Access allowed users if needed.

If the Seerr admin account is stolen:

```bash
cd "$CLOUDFLARED_DIR"
docker compose stop

cd "$ARR_DIR"
docker compose stop seerr
```

Then:

1. Disable the Cloudflare public hostname or Access application.
2. Change Seerr admin credentials.
3. Remove unknown Seerr users and permissions.
4. Rotate Radarr and Sonarr API keys.
5. Rotate the Jellyfin API key used by Seerr.
6. Review Radarr, Sonarr, and qBittorrent queues.
7. Review Seerr logs and recent request history.
8. Restart only after you understand what changed.

If you suspect host or container compromise:

1. Stop the tunnel.
2. Stop Seerr.
3. Do not delete logs.
4. Rotate the Cloudflare tunnel token and Cloudflare DNS API token.
5. Rotate Seerr, Radarr, Sonarr, and Jellyfin credentials/API keys.
6. Rebuild the container from a known-good compose file.
7. Consider restoring the Docker VM from a known-good backup.

## Pass/Fail Checklist

Do not consider public exposure complete until all pass.

| Check | Pass condition |
|---|---|
| Seerr local app | `http://192.168.1.20:5055` works before migration |
| Seerr backend links | Jellyfin, Radarr, and Sonarr test successfully from Seerr |
| Traefik local HTTPS | `https://requests.example.com` works through Traefik locally |
| Seerr raw port | No host port mapping for `5055` after validation |
| Router WAN forwards | No WAN forwards to Seerr, ARR apps, SSH, or admin tools |
| Cloudflare Tunnel | Connector healthy |
| Cloudflare hostname | `requests.example.com` routes to `https://traefik:443` |
| Origin TLS | `Origin Server Name` is `requests.example.com`; `No TLS Verify` is off |
| Cloudflare Access | Only intended users can reach Seerr |
| Cloudflare cache | Cache bypass rule exists for Seerr hostname |
| Seerr users | Normal users have request permissions only |
| ARR admin UIs | Radarr, Sonarr, Prowlarr, qBittorrent stay private |
| Docker socket | Seerr does not mount Docker socket |
| Management UIs | Proxmox, TrueNAS, SSH, Pi-hole, Traefik dashboard, Dockge, Grafana stay private |

## References

- Existing ARR app setup: [../services/arr-stack-app-configuration-guide.md](../services/arr-stack-app-configuration-guide.md)
- Existing Traefik and Cloudflare TLS guide: [ssl-traefik-cloudflare-guide.md](ssl-traefik-cloudflare-guide.md)
- Existing Jellyfin Cloudflare Tunnel pattern: [jellyfin-cloudflare-tunnel-public-access-guide.md](jellyfin-cloudflare-tunnel-public-access-guide.md)
- Cloudflare Tunnel overview: <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/>
- Cloudflare dashboard tunnel creation: <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/>
- Cloudflare self-hosted applications: <https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/>
