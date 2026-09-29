# Jellyfin Public Access With Cloudflare Tunnel And Traefik

Last updated: 2026-06-19

This guide exposes Jellyfin at `https://media.example.com` through
Cloudflare Tunnel while keeping the home router closed to inbound internet
traffic.

Use this after:

1. The Ubuntu Docker VM is running at `192.168.1.20`.
2. Traefik is running on the Docker VM.
3. Jellyfin works locally through Traefik.
4. Your domain uses Cloudflare nameservers.
5. Traefik already has a valid Let's Encrypt certificate through the
   Cloudflare DNS challenge.

Do not expose raw Jellyfin ports directly to the internet. Public traffic
should go:

```text
Internet client
  -> Cloudflare
  -> Cloudflare Tunnel
  -> cloudflared container on Docker VM
  -> Traefik
  -> Jellyfin
```

## Current Homestack Values

Replace these if your live values differ.

| Item | Value |
|---|---|
| Docker VM SSH user | `alice` |
| Docker VM IP | `192.168.1.20` |
| Traefik stack path | `/opt/docker/traefik` |
| Jellyfin stack path | `/opt/stacks/jellyfin-stack` |
| New cloudflared stack path | `/opt/stacks/cloudflared` |
| Public Jellyfin hostname | `media.example.com` |
| Traefik container name | `traefik` |
| Shared Docker proxy network | `proxy` |

## Security Position

Baseline decision:

- Use Cloudflare Tunnel, not router port forwarding.
- Keep Jellyfin behind Traefik.
- Do not put Authelia or Cloudflare Access in front of Jellyfin by default.
- Use Jellyfin accounts, strong passwords, and per-user remote access controls.
- Keep Proxmox, TrueNAS, SSH, Pi-hole admin, Traefik dashboard, Dockge,
  Portainer-style tools, and Grafana private over LAN or Tailscale only.

Why no Authelia by default:

- Jellyfin has its own account system.
- TV, mobile, and media clients often expect the Jellyfin API directly.
- A second browser login layer can break or annoy non-browser clients.

Use Authelia or Cloudflare Access for Seerr, dashboards, and admin tools. For
Jellyfin, use an outer auth layer only if every client you care about supports
it.

## Step 1: SSH To The Docker VM

Run this from your workstation:

```bash
ssh alice@192.168.1.20
```

Set helper variables on the Docker VM:

```bash
export DOMAIN="example.com"
export MEDIA_HOST="media.${DOMAIN}"
export TRAEFIK_DIR="/opt/docker/traefik"
export JELLYFIN_DIR="/opt/stacks/jellyfin-stack"
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
- This does not mean the internet can reach those ports. Router forwarding is
  checked later.

## Step 3: Confirm Jellyfin Is Routed Only Through Traefik

```bash
cd "$JELLYFIN_DIR"
docker compose ps
docker compose logs --tail=100 jellyfin
```

Confirm Jellyfin has Traefik labels:

```bash
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

Expected:

```text
null
```

or:

```text
{}
```

If you see `8096` or `8920` published here, remove the direct port mapping
before public exposure.

Confirm Jellyfin media mounts are read-only:

```bash
docker inspect jellyfin \
  --format '{{range .Mounts}}{{println .Source "->" .Destination "RW=" .RW}}{{end}}'
```

Expected for media libraries:

```text
/mnt/media/movies -> /media/movies RW= false
/mnt/media/tv-shows -> /media/tv RW= false
/mnt/media/music -> /media/music RW= false
```

The config mount can be writable. The media mounts should be read-only.

## Step 4: Test Local HTTPS Before Cloudflare Tunnel

From the Docker VM:

```bash
curl -kI --resolve "${MEDIA_HOST}:443:192.168.1.20" "https://${MEDIA_HOST}/"
curl -kfsS --resolve "${MEDIA_HOST}:443:192.168.1.20" "https://${MEDIA_HOST}/health"
```

Expected:

- The first command returns HTTP headers from Jellyfin through Traefik.
- The second command returns a healthy response.

If this fails, fix Traefik or Jellyfin before creating the Cloudflare Tunnel.

## Step 5: Create The Cloudflare Tunnel In The Dashboard

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
token value. Do not paste the token into chat, screenshots, git, or public docs.

## Step 6: Create The cloudflared Stack On The Docker VM

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

Security note: the token appears in the Docker container command because this
is how the dashboard-managed Docker connector is normally run. Treat the Docker
VM as a trusted host. If the token is exposed, delete or rotate the tunnel
token in Cloudflare.

## Step 7: Add The Public Hostname

In the same Cloudflare Tunnel:

```text
Public Hostnames -> Add a public hostname
```

Set:

| Field | Value |
|---|---|
| Subdomain | `media` |
| Domain | `example.com` |
| Path | blank |
| Type | `HTTPS` |
| URL | `traefik:443` |

Open the additional settings for that public hostname.

Set HTTP settings:

| Field | Value |
|---|---|
| HTTP Host Header | `media.example.com` |

Set TLS settings:

| Field | Value |
|---|---|
| Origin Server Name | `media.example.com` |
| No TLS Verify | off |

Do not enable `No TLS Verify` for the final setup. If you temporarily enable
it during troubleshooting, turn it off again after Traefik certificate/SNI is
fixed.

Cloudflare should automatically create a DNS record similar to:

```text
media.example.com CNAME <tunnel-id>.cfargotunnel.com
```

## Step 8: Disable Cache For Jellyfin

Jellyfin is dynamic streaming traffic. Do not rely on Cloudflare caching for it.

In Cloudflare:

```text
Rules -> Cache Rules -> Create rule
```

Set:

```text
Rule name: Bypass cache for Jellyfin
If: Hostname equals media.example.com
Then: Bypass cache
```

This keeps Cloudflare as an access path and edge protection layer, not a video
cache.

## Step 9: Confirm Jellyfin Remote Access Controls

In Jellyfin:

```text
Dashboard -> Networking
```

Recommended settings:

| Setting | Recommendation |
|---|---|
| Allow remote connections to this server | enabled only if you want public access |
| Known proxies | Traefik/proxy network if you are enforcing forwarded client IP behavior |
| Local networks | your LAN CIDR, for example `192.168.1.0/24` |

For each Jellyfin user:

```text
Dashboard -> Users -> select user
```

Recommended:

- Use a strong unique password.
- Disable remote connections for users who only need LAN access.
- Do not share the admin account.
- Create normal non-admin accounts for watching.
- Keep the admin account for administration only.

## Step 10: Test Through Cloudflare

From the Docker VM:

```bash
nslookup "${MEDIA_HOST}"
curl -I "https://${MEDIA_HOST}/"
curl -fsS "https://${MEDIA_HOST}/health"
```

Expected:

- DNS resolves to Cloudflare, not directly to `192.168.1.20`, unless you are
  intentionally using split DNS on that client.
- HTTPS works without certificate warnings.
- `/health` returns a healthy response.

From a phone on cellular data, open:

```text
https://media.example.com
```

Expected:

- Jellyfin login page loads.
- Login works with a non-admin Jellyfin user.
- Playback works acceptably.

If playback buffers badly, Cloudflare Tunnel may not be the right path for your
media workload. Use Tailscale, direct Traefik forwarding with strict firewalling,
or keep remote playback private.

## Step 11: Router And Firewall Safety Checks

The secure tunnel model does not require inbound router port forwarding.

On the Docker VM:

```bash
sudo ufw status verbose
sudo ss -tulpn | grep -E ':(22|80|443|8096|8920)\b'
```

Expected:

- SSH is reachable only from LAN/Tailscale according to your firewall design.
- Traefik may listen on `80` and `443` locally.
- Jellyfin should not listen on host ports `8096` or `8920`.

In your router/firewall UI, verify there are no WAN forwards for:

```text
22
80
443
8096
8920
7878
8989
9696
8080
3000
3001
9000
9443
```

From a network outside your home, optionally scan your WAN IP:

```bash
nmap -Pn -p 22,80,443,8096,8920 YOUR_PUBLIC_WAN_IP
```

Expected:

```text
closed
```

or:

```text
filtered
```

If `80`, `443`, or `8096` are open on the WAN IP, you are not using the
closed-router tunnel model.

## Step 12: Docker Safety Checks

Run these on the Docker VM.

Check direct port publishing:

```bash
docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

Expected:

- Traefik may publish `80` and `443`.
- Jellyfin should not publish `8096` or `8920`.
- Cloudflared should publish no ports.

Check Jellyfin privilege posture:

```bash
docker inspect jellyfin \
  --format 'User={{.Config.User}} SecurityOpt={{json .HostConfig.SecurityOpt}} Privileged={{.HostConfig.Privileged}}'
```

Expected:

```text
Privileged=false
```

and:

```text
no-new-privileges:true
```

Check Jellyfin Docker socket exposure:

```bash
docker inspect jellyfin \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' \
  | grep -E 'docker.sock|/var/run' || echo "OK: no Docker socket mount"
```

Expected:

```text
OK: no Docker socket mount
```

Check cloudflared privilege posture:

```bash
docker inspect cloudflared \
  --format 'ReadonlyRootfs={{.HostConfig.ReadonlyRootfs}} Privileged={{.HostConfig.Privileged}} CapDrop={{json .HostConfig.CapDrop}}'
```

Expected:

```text
ReadonlyRootfs=true
Privileged=false
CapDrop=["ALL"]
```

Check who shares the `proxy` network:

```bash
docker network inspect proxy \
  --format '{{range $id,$c := .Containers}}{{println $c.Name}}{{end}}' \
  | sort
```

This shows which containers can share the reverse-proxy network. A future
hardening improvement is per-service proxy networks, so a compromised web app
has less ability to talk sideways to unrelated containers.

## Step 13: Cloudflare Safety Checks

In Cloudflare, confirm:

| Area | Standard |
|---|---|
| Domain | Active in Cloudflare |
| Tunnel | Healthy connector for Docker VM |
| Public hostname | Only `media.example.com` for Jellyfin |
| Service URL | `https://traefik:443` |
| HTTP Host Header | `media.example.com` |
| Origin Server Name | `media.example.com` |
| No TLS Verify | off |
| Cache rule | Bypass cache for `media.example.com` |
| Access policy | Not required for Jellyfin unless all clients support it |

Do not publish management hostnames through the tunnel:

```text
proxmox.example.com
truenas.example.com
ssh.example.com
dns.example.com
traefik.example.com
dockge.example.com
portainer.example.com
grafana.example.com
```

## Step 14: Incident Response If Jellyfin Is Compromised

If a Jellyfin account is stolen:

1. Disable or change that Jellyfin user password.
2. Revoke active sessions in Jellyfin if available.
3. Review Jellyfin logs.
4. Confirm the account was not an admin.

If the Jellyfin admin account is stolen:

```bash
cd "$CLOUDFLARED_DIR"
docker compose stop

cd "$JELLYFIN_DIR"
docker compose stop jellyfin
```

Then:

1. Disable the Cloudflare public hostname or tunnel route.
2. Change all Jellyfin passwords.
3. Remove unknown Jellyfin users, API keys, and plugins.
4. Review Jellyfin logs under `/mnt/main/appdata/jellyfin`.
5. Restore Jellyfin config from a known-good snapshot if settings changed.
6. Restart only after you understand what changed.

If you suspect container escape or host compromise:

1. Stop the tunnel.
2. Stop Jellyfin.
3. Do not delete logs.
4. Rotate Cloudflare tunnel token and DNS API token.
5. Rotate Jellyfin passwords.
6. Rebuild the container from a known-good compose file.
7. Consider restoring the Docker VM from a known-good backup.

## Pass/Fail Checklist

Do not consider public exposure complete until all pass.

| Check | Pass condition |
|---|---|
| Traefik local HTTPS | `https://media.example.com` works through Traefik locally |
| Jellyfin raw ports | No host port mapping for `8096` or `8920` |
| Router WAN forwards | No WAN forwards to Jellyfin, SSH, or admin tools |
| Cloudflare Tunnel | Connector healthy |
| Cloudflare hostname | `media.example.com` routes to `https://traefik:443` |
| Origin TLS | `Origin Server Name` is `media.example.com`; `No TLS Verify` is off |
| Cloudflare cache | Cache bypass rule exists for Jellyfin hostname |
| Jellyfin accounts | Strong unique passwords; admin account not used for watching |
| Jellyfin user permissions | Remote access enabled only for users who need it |
| Docker socket | Jellyfin does not mount Docker socket |
| Media mounts | Jellyfin media mounts are read-only |
| Management UIs | Proxmox, TrueNAS, SSH, Pi-hole, Traefik dashboard, Dockge, Grafana stay private |

## References

- Cloudflare Tunnel overview: <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/>
- Cloudflare dashboard tunnel creation: <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/>
- Cloudflare self-hosted applications: <https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/>
- Jellyfin networking: <https://jellyfin.org/docs/general/post-install/networking/>
