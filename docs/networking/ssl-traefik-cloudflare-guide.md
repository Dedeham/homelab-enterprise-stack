# SSL/TLS For The Homestack With Traefik And Cloudflare

Last updated: 2026-06-13

This guide adds trusted HTTPS certificates to the homestack using the Traefik
configuration already present in this repo.

Use this after:

1. The Ubuntu Docker VM is running at `192.168.1.20`.
2. Docker and Docker Compose work on the Docker VM.
3. The `proxy` Docker network can be created on the Docker VM.
4. You own a real domain name.
5. Your domain's DNS is hosted in Cloudflare.

## Current Homestack Values

Use these values for the current setup:

| Item | Value |
|---|---|
| Docker VM SSH user | `alice` |
| Docker VM IP | `192.168.1.20` |
| TrueNAS IP | `192.168.1.10` |
| LAN subnet | `192.168.1.0/24` |
| Tailscale subnet | `100.64.0.0/10` |
| Active Docker stack path | `/opt/stacks` |
| Traefik stack path | `/opt/stacks/traefik` |
| Persistent app data | `/mnt/main/appdata` |
| Stack config backup copy | `/mnt/main/appdata/docker-stack-configs` |

This guide uses `/opt/stacks`, not `/opt/docker`, because the current live
monitoring and Watchtower stacks were created under `/opt/stacks`.

The recommended setup is:

```text
LAN / Tailscale clients
        |
        | https://cloud.example.com
        v
Pi-hole local DNS -> 192.168.1.20
        |
        v
Traefik on Docker VM
        |
        v
Docker services on the proxy network
```

Traefik gets a Let's Encrypt wildcard certificate by using Cloudflare DNS
validation. This means you can get valid certificates for LAN-only services
without opening router ports `80` or `443`.

## Important Naming Note

Most people say "SSL", but the modern protocol is TLS. In this guide:

- "SSL" means the common homelab goal: browser-trusted `https://` URLs.
- "TLS" means the actual encryption protocol used by Traefik and browsers.

## Current Repo Support

The repo already contains the main pieces:

| File | Purpose |
|---|---|
| `configs/docker/traefik/docker-compose.yml` | Runs Traefik and the Docker socket proxy |
| `configs/docker/traefik/traefik.yml` | Defines entrypoints, certificate resolver, TLS settings |
| `configs/docker/traefik/dynamic/middlewares.yml` | Defines security headers, rate limits, admin IP allowlist |
| `configs/docker/traefik/.env.example` | Shows the Cloudflare token variable |
| `configs/docker/*/docker-compose.yml` | Service labels for `cloud`, `media`, `vault`, `dns`, `dash`, etc. |

Some older comments in compose files still mention Docker VM `192.168.1.20`
or `/opt/docker`. Use the current values instead:

```text
Docker VM: 192.168.1.20
Stack path: /opt/stacks
```

## The Recommended Certificate Strategy

Use `DNS-01` validation through Cloudflare.

Why:

- It supports wildcard certificates like `*.example.com`.
- It works for private LAN services.
- It does not require router port forwarding.
- It avoids exposing internal services just to prove domain ownership.

Do not use self-signed certificates for normal browser access. They cause
warnings, break mobile apps, and train you to ignore certificate errors.

Do not start by forwarding router ports `80` and `443`. Public exposure is a
separate decision after local HTTPS, backups, auth, and monitoring work.

## Target Hostnames

Use one domain and service subdomains:

| Hostname | Service | Exposure recommendation |
|---|---|---|
| `traefik.example.com` | Traefik dashboard | LAN/Tailscale only |
| `cloud.example.com` | Nextcloud | LAN/Tailscale first, public later if needed |
| `media.example.com` | Jellyfin | LAN/Tailscale first, public optional |
| `vault.example.com` | Vaultwarden | LAN/Tailscale first, public only after hardening |
| `dns.example.com` | Pi-hole admin | LAN/Tailscale only |
| `dash.example.com` | Homepage | LAN/Tailscale only unless intentionally shared |
| `monitor.example.com` | Grafana | LAN/Tailscale only |
| `status.example.com` | Uptime Kuma | LAN/Tailscale or public depending on checks |

Never expose these publicly:

- Proxmox UI.
- TrueNAS UI.
- SSH.
- Docker socket or Portainer-style admin tools.
- Pi-hole DNS port `53`.
- Grafana unless you have a specific reason and strong auth.

## Step 1: Put The Domain In Cloudflare

In Cloudflare:

1. Add your domain.
2. Change the registrar nameservers to Cloudflare's assigned nameservers.
3. Wait until Cloudflare shows the domain as active.

You do not need public `A` records for local-only HTTPS. The certificate is
issued through DNS validation, not by reaching your server over the internet.

Optional public records can come later when you decide between Cloudflare Tunnel
and direct port forwarding.

## Step 2: Create A Cloudflare API Token

Create a narrow API token for Traefik.

Cloudflare dashboard path:

```text
My Profile -> API Tokens -> Create Token
```

Use either the "Edit zone DNS" template or a custom token.

Minimum permissions:

```text
Zone / Zone / Read
Zone / DNS / Edit
```

Resource scope:

```text
Include -> Specific zone -> example.com
```

Store the token in your password manager. Do not use the global API key.

## Step 3: Copy Traefik To The Docker VM

From your workstation, run:

```bash
scp -r configs/docker/traefik alice@192.168.1.20:/opt/stacks/
```

On the Docker VM:

```bash
ssh alice@192.168.1.20
sudo mkdir -p /opt/stacks
sudo chown -R "$USER":"$USER" /opt/stacks
cd /opt/stacks/traefik
cp .env.example .env
chmod 600 .env
nano .env
```

Set:

```text
CF_DNS_API_TOKEN=your_real_cloudflare_token
```

## Step 4: Edit Traefik Static Config

Open:

```bash
nano /opt/stacks/traefik/traefik.yml
```

Replace the placeholder email:

```yaml
certificatesResolvers:
  cloudflare:
    acme:
      email: your@email.com
```

Replace the placeholder domain:

```yaml
entryPoints:
  websecure:
    address: ":443"
    http:
      tls:
        certResolver: cloudflare
        domains:
          - main: "example.com"
            sans:
              - "*.example.com"
```

Example:

```yaml
          - main: "example.net"
            sans:
              - "*.example.net"
```

Do not put `${DOMAIN}` in `traefik.yml`. Traefik's static YAML file does not
expand Docker Compose environment variables.

## Step 5: Create The Certificate Store

On the Docker VM:

```bash
cd /opt/stacks/traefik
mkdir -p certs
touch certs/acme.json
chmod 600 certs/acme.json
```

Why this matters:

- `acme.json` stores the Let's Encrypt account and certificates.
- Traefik expects it to be writable.
- The file contains private key material and must not be world-readable.

Do not commit `acme.json` to git.

## Step 6: Create The Proxy Network

On the Docker VM:

```bash
docker network create proxy
```

If it already exists, Docker will report that. That is fine. To make the command
idempotent, you can use:

```bash
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy
```

Traefik uses this network to reach service containers. Each web service compose
file should include:

```yaml
networks:
  proxy:
    external: true
```

## Step 7: Start Traefik

On the Docker VM:

```bash
cd /opt/stacks/traefik
docker compose up -d
docker compose ps
docker compose logs -f traefik
```

Expected result:

- `traefik` is running.
- `socket-proxy` is running.
- Traefik does not log Cloudflare authentication errors.
- Traefik eventually writes certificate data to `certs/acme.json`.

Check the certificate file:

```bash
sudo ls -lh /opt/stacks/traefik/certs/acme.json
sudo grep -o "example.com" /opt/stacks/traefik/certs/acme.json | head
```

If `acme.json` stays nearly empty, Traefik has not issued a certificate yet.
Usually that means no router requested TLS, the Cloudflare token is wrong, or
the domain placeholders were not replaced.

## Step 8: Add Local DNS Records

For LAN access, each service hostname should resolve to the Docker VM:

```text
cloud.example.com   -> 192.168.1.20
media.example.com   -> 192.168.1.20
vault.example.com   -> 192.168.1.20
dns.example.com     -> 192.168.1.20
dash.example.com    -> 192.168.1.20
traefik.example.com -> 192.168.1.20
monitor.example.com -> 192.168.1.20
status.example.com  -> 192.168.1.20
```

Preferred place:

```text
Pi-hole -> Local DNS -> DNS Records
```

Temporary alternative on one workstation:

```text
192.168.1.20 cloud.example.com
192.168.1.20 media.example.com
192.168.1.20 vault.example.com
```

On Windows, the hosts file is:

```text
C:\Windows\System32\drivers\etc\hosts
```

Split DNS keeps local traffic local. Your browser uses the real public domain
name, gets a real trusted certificate, but connects directly to the Docker VM.

## Step 9: Configure Each Service For Traefik

Each HTTPS service needs four things:

1. It joins the `proxy` Docker network.
2. It has `traefik.enable=true`.
3. Its router uses `websecure`.
4. Its router uses the `cloudflare` cert resolver.

Example labels:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.example.rule=Host(`example.${DOMAIN}`)"
  - "traefik.http.routers.example.entrypoints=websecure"
  - "traefik.http.routers.example.tls.certresolver=cloudflare"
  - "traefik.http.routers.example.middlewares=security-headers@file,rate-limit@file"
  - "traefik.http.services.example.loadbalancer.server.port=8080"
```

The repo already follows this pattern in the service compose files.

The `DOMAIN` variable belongs in each service's `.env` file:

```text
DOMAIN=example.com
```

Do not include `https://` in `DOMAIN`.

## Step 10: Start One Service And Test

Start with one low-risk service such as Homepage or Jellyfin before doing
Nextcloud or Vaultwarden.

Example:

```bash
cd /opt/stacks/jellyfin
cp .env.example .env
nano .env
docker compose up -d
docker compose ps
```

Then test from a LAN client:

```text
https://media.example.com
```

The browser should show a normal trusted lock icon with no certificate warning.

Command-line checks from a LAN machine:

```bash
nslookup media.example.com
curl -I https://media.example.com
```

Expected:

- DNS returns `192.168.1.20`.
- HTTP returns a normal response or a service login redirect.
- No certificate error.

Certificate check:

```bash
openssl s_client -connect media.example.com:443 -servername media.example.com </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject -dates
```

Expected issuer is Let's Encrypt or the current Let's Encrypt intermediate.

## Step 11: Add HTTP To HTTPS Redirect

This is already present in `configs/docker/traefik/traefik.yml`:

```yaml
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
```

Test:

```bash
curl -I http://media.example.com
```

Expected:

```text
HTTP/1.1 301 Moved Permanently
Location: https://media.example.com/
```

## Step 12: Confirm Security Headers

The repo's Traefik middleware already defines `security-headers@file`.

Test:

```bash
curl -I https://media.example.com
```

Look for:

```text
Strict-Transport-Security
X-Content-Type-Options
Referrer-Policy
Permissions-Policy
```

Do not enable HSTS preload until the whole domain and every subdomain are
stable on HTTPS. Preload is difficult to undo.

## Step 13: Protect Internal Dashboards

For internal admin UIs, combine:

- `security-headers@file`
- `admin-whitelist@file`
- `authelia@docker` where appropriate

Example:

```yaml
- "traefik.http.routers.pihole.middlewares=admin-whitelist@file,security-headers@file"
```

The current `admin-whitelist@file` allows:

```text
192.168.1.0/24
100.64.0.0/10
127.0.0.1/32
```

That matches the current LAN plus Tailscale model.

Add `authelia@docker` only after Authelia is deployed and tested. Before that,
routes that reference `authelia@docker` will not be protected by Authelia and
may show middleware errors in Traefik.

Do not put Authelia in front of Nextcloud or Jellyfin by default. Both have
their own auth flows, and Nextcloud mobile or desktop clients can break behind
a generic forward-auth login.

## Step 14: Decide Public Access Later

After local HTTPS works, choose one public access model if you need access
without Tailscale.

### Option A: Cloudflare Tunnel

Recommended default for public web apps.

Pros:

- No router port forwarding.
- Works behind CGNAT.
- Cloudflare handles inbound edge protection.
- Your origin can remain private.

Recommended for:

- Nextcloud if you need browser/mobile access without VPN.
- Jellyfin only if performance is acceptable for your use.
- Vaultwarden only with strong account security and careful Access policies.

Keep Traefik as the internal router. The tunnel should point public hostnames
to Traefik on the Docker VM, not directly to random containers.

### Option B: Direct Port Forwarding

Use only if you intentionally want the homestack reachable directly.

Router forwards:

```text
WAN TCP 80  -> 192.168.1.20 TCP 80
WAN TCP 443 -> 192.168.1.20 TCP 443
```

Do this only after:

- Traefik TLS works locally.
- Services have strong auth.
- Admin dashboards are allowlisted.
- Backups and restore tests are done.
- You are comfortable with internet scanning and attack traffic hitting Traefik.

Do not forward service ports like `8096`, `8080`, `8989`, `7878`, `6500`, or
database ports. Public traffic should enter only through Traefik.

### Option C: Tailscale Only

This is safest and usually enough for management.

Use Tailscale for:

- Proxmox.
- TrueNAS.
- SSH.
- Pi-hole admin.
- Grafana.
- Internal dashboards.

You can still use trusted HTTPS names over Tailscale if DNS resolves those
names to `192.168.1.20` or to a reachable Tailscale subnet route.

## Step 15: Renewal Checks

Traefik renews ACME certificates automatically. You should still monitor it.

Monthly check:

```bash
cd /opt/stacks/traefik
docker compose logs --since 720h traefik | grep -i -E "acme|certificate|renew|error"
```

Check certificate expiry from a client:

```bash
openssl s_client -connect cloud.example.com:443 -servername cloud.example.com </dev/null 2>/dev/null | openssl x509 -noout -dates
```

Back up:

```text
/opt/stacks/traefik/.env
/opt/stacks/traefik/traefik.yml
/opt/stacks/traefik/dynamic/
/opt/stacks/traefik/certs/acme.json
```

Your daily stack-config backup should copy `/opt/stacks` to:

```text
/mnt/main/appdata/docker-stack-configs
```

Store the Cloudflare token in your password manager too. If the Docker VM is
lost, you can recreate the certs, but keeping `acme.json` avoids unnecessary
rate limit risk during restores.

## Troubleshooting

### Browser shows a certificate warning

Check:

```bash
nslookup cloud.example.com
docker compose logs traefik | grep -i acme
```

Likely causes:

- Local DNS does not point to `192.168.1.20`.
- Traefik is serving its default certificate because ACME failed.
- The service router has no `tls.certresolver=cloudflare` label.
- `traefik.yml` still contains `example.com`.

### Traefik logs Cloudflare authentication errors

Check:

```bash
cd /opt/stacks/traefik
grep CF_DNS_API_TOKEN .env
```

Likely causes:

- Token pasted incorrectly.
- Token lacks `Zone / DNS / Edit`.
- Token lacks `Zone / Zone / Read`.
- Token is scoped to the wrong Cloudflare zone.

Rotate the token if you accidentally paste it into chat, logs, screenshots, or
git.

### ACME validation times out

DNS-01 does not require inbound access to your Docker VM. If it times out:

- Confirm the domain uses Cloudflare nameservers.
- Confirm the token can edit DNS records in the correct zone.
- Wait a few minutes for DNS propagation.
- Check whether Cloudflare audit logs show TXT record creation.

### The service works by IP but not by hostname

Check local DNS:

```bash
nslookup media.example.com
```

Expected:

```text
192.168.1.20
```

If it returns a public Cloudflare IP, your LAN client is not using Pi-hole or
your split DNS record is missing.

### Traefik is healthy but returns 404

Traefik is reachable, but no router matched the hostname.

Check:

```bash
docker inspect jellyfin --format '{{json .Config.Labels}}'
docker network inspect proxy
```

Likely causes:

- Service does not have `traefik.enable=true`.
- Host rule uses the wrong domain.
- Service is not attached to the `proxy` network.
- The service compose `.env` has missing or wrong `DOMAIN`.

### Traefik returns 502 or 504

The router matched, but Traefik cannot reach the backend container.

Check:

```bash
docker compose ps
docker compose logs
docker network inspect proxy
```

Likely causes:

- Wrong `loadbalancer.server.port`.
- Service is unhealthy or still starting.
- Service is not on the `proxy` network.

### Gluetun DNS-over-TLS warnings are unrelated

Warnings like this in `debrid-gluetun`:

```text
running TLS handshake with 9.9.9.9:853 ... connection reset by peer
```

are DNS-over-TLS warnings inside the VPN container. They are not Traefik HTTPS
certificate failures.

Keep Traefik outside the Gluetun network path. Traefik should run as the normal
reverse proxy on the Docker VM, while Gluetun protects only the debrid or
torrent-related containers that intentionally use it.

## Final Validation Checklist

| Check | Command or location | Expected result |
|---|---|---|
| Traefik running | `docker compose ps` in `/opt/stacks/traefik` | `traefik` and `socket-proxy` are up |
| Certificate store exists | `ls -lh certs/acme.json` | File exists, mode `600`, non-empty after issuance |
| Local DNS works | `nslookup cloud.example.com` | Returns `192.168.1.20` |
| HTTPS works | `curl -I https://cloud.example.com` | No certificate error |
| HTTP redirects | `curl -I http://cloud.example.com` | `301` to HTTPS |
| Headers exist | `curl -I https://cloud.example.com` | HSTS and security headers present |
| Admin routes limited | Traefik labels and middleware | Admin UIs use allowlist and/or Authelia |
| No direct service exposure | Router and compose ports | Only Traefik uses public HTTP/HTTPS paths |

## References

- Traefik ACME certificate resolver: <https://doc.traefik.io/traefik/reference/install-configuration/tls/certificate-resolvers/acme/>
- Let's Encrypt challenge types: <https://letsencrypt.org/docs/challenge-types/>
- Lego Cloudflare DNS provider variables: <https://go-acme.github.io/lego/dns/cloudflare/>
- Cloudflare API token creation: <https://developers.cloudflare.com/fundamentals/api/get-started/create-token/>
