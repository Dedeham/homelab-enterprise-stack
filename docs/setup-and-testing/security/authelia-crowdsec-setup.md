# Authelia And CrowdSec Setup, Before Public Exposure

Last updated: 2026-06-14

Use this guide after basic monitoring works and before moving Grafana, Uptime
Kuma, Nextcloud, Vaultwarden, or other services behind public Traefik routes.

This guide is SSH-first. It does not require syncing this repo to the Docker
VM.

## Goal

Add two security layers before using Traefik for protected services:

```text
Authelia = login + 2FA gate in front of web apps
CrowdSec = watches logs and blocks suspicious IPs
```

Target order:

```text
Monitoring baseline
-> Traefik with local HTTPS
-> Authelia
-> CrowdSec
-> Move Grafana/Uptime Kuma behind Traefik
-> Later public exposure only if still needed
```

## Current Homelab IPs

```text
Docker VM: 192.168.1.20
Proxmox:   192.168.1.2
TrueNAS:   192.168.1.10
```

## Important Readiness Check

Authelia and CrowdSec are useful only when services are reached through
Traefik. If you are still using direct ports like these:

```text
http://192.168.1.20:3000
http://192.168.1.20:3001
```

then keep them as-is until Traefik local HTTPS works.

Before this guide, finish
[ssl-traefik-cloudflare.md](../networking/ssl-traefik-cloudflare.md).

Minimum required:

```text
[ ] You own a real domain.
[ ] DNS is in Cloudflare.
[ ] Traefik runs on the Docker VM.
[ ] Docker network `proxy` exists.
[ ] Traefik has valid wildcard TLS certs.
[ ] Local DNS points service subdomains to 192.168.1.20.
```

Do not expose router ports just to make this work. LAN/Tailscale first.

## Naming Used In This Guide

Replace `example.com` with your real domain.

```text
auth.example.com      Authelia login portal
monitor.example.com   Grafana
status.example.com    Uptime Kuma
traefik.example.com   Traefik dashboard
```

## Phase 1: Verify Traefik Is Ready

SSH into the Docker VM:

```bash
ssh alice@192.168.1.20
```

Check Traefik:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'traefik|socket-proxy' || true
docker network inspect proxy >/dev/null && echo "proxy network exists"
```

Check ports:

```bash
sudo ss -lntp | grep -E ':80|:443' || true
```

Expected:

```text
Traefik is running.
The proxy Docker network exists.
Ports 80 and 443 are bound by Traefik.
```

Fallback if Traefik is not ready: stop here and finish the Traefik/Cloudflare
TLS guide first.

## Phase 2: Create Authelia Folders

Run on the Docker VM:

```bash
sudo mkdir -p /opt/stacks/authelia/config
sudo chown -R "$USER":"$USER" /opt/stacks/authelia
cd /opt/stacks/authelia
```

Create `.env`:

```bash
cat > .env <<'EOF'
DOMAIN=example.com
TZ=Europe/Berlin
EOF

chmod 600 .env
nano .env
```

Change `DOMAIN=example.com` to your real domain.

## Phase 3: Generate Authelia Secrets

Run:

```bash
cd /opt/stacks/authelia

SESSION_SECRET="$(openssl rand -base64 64)"
STORAGE_KEY="$(openssl rand -base64 64)"
JWT_SECRET="$(openssl rand -base64 64)"

cat > config/secrets.env <<EOF
SESSION_SECRET=${SESSION_SECRET}
STORAGE_KEY=${STORAGE_KEY}
JWT_SECRET=${JWT_SECRET}
EOF

chmod 600 config/secrets.env
```

Fallback if `openssl` is missing:

```bash
sudo apt update
sudo apt install -y openssl
```

## Phase 4: Create Authelia User Database

Choose an Authelia password for your admin user. Generate a password hash:

```bash
docker run --rm authelia/authelia:4.38.18 authelia crypto hash generate argon2 --password 'REPLACE_WITH_YOUR_PASSWORD'
```

Copy the generated `$argon2id$...` hash.

Create the user database:

```bash
nano /opt/stacks/authelia/config/users_database.yml
```

Paste and edit:

```yaml
users:
  alice:
    displayname: "Alice"
    password: "$argon2id$v=19$m=65536,t=3,p=4$REPLACE_WITH_HASH"
    email: you@example.com
    groups:
      - admins
```

Important: do not paste the plain password. Paste only the generated argon2
hash.

## Phase 5: Create Authelia Configuration

Run:

```bash
cd /opt/stacks/authelia
. ./.env
. ./config/secrets.env

cat > config/configuration.yml <<EOF
theme: dark

server:
  address: 'tcp://0.0.0.0:9091/'

log:
  level: info

totp:
  issuer: '${DOMAIN}'

authentication_backend:
  file:
    path: /config/users_database.yml

access_control:
  default_policy: deny
  rules:
    - domain: 'auth.${DOMAIN}'
      policy: bypass

    - domain:
        - 'monitor.${DOMAIN}'
        - 'status.${DOMAIN}'
        - 'traefik.${DOMAIN}'
      policy: two_factor

session:
  secret: '${SESSION_SECRET}'
  cookies:
    - domain: '${DOMAIN}'
      authelia_url: 'https://auth.${DOMAIN}'
      default_redirection_url: 'https://monitor.${DOMAIN}'

regulation:
  max_retries: 3
  find_time: 2m
  ban_time: 5m

storage:
  encryption_key: '${STORAGE_KEY}'
  local:
    path: /config/db.sqlite3

identity_validation:
  reset_password:
    jwt_secret: '${JWT_SECRET}'

notifier:
  filesystem:
    filename: /config/notification.txt
EOF

chmod 600 config/configuration.yml
```

This uses file notifications first. SMTP can come later.

## Phase 6: Create Authelia Compose

Run:

```bash
cd /opt/stacks/authelia

cat > docker-compose.yml <<'EOF'
services:
  authelia:
    image: authelia/authelia:4.38.18
    container_name: authelia
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    environment:
      TZ: ${TZ}
    volumes:
      - ./config:/config
    networks:
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.authelia.rule=Host(`auth.${DOMAIN}`)"
      - "traefik.http.routers.authelia.entrypoints=websecure"
      - "traefik.http.routers.authelia.tls.certresolver=cloudflare"
      - "traefik.http.services.authelia.loadbalancer.server.port=9091"
      - "traefik.http.middlewares.authelia.forwardAuth.address=http://authelia:9091/api/authz/forward-auth"
      - "traefik.http.middlewares.authelia.forwardAuth.trustForwardHeader=true"
      - "traefik.http.middlewares.authelia.forwardAuth.authResponseHeaders=Remote-User,Remote-Groups,Remote-Name,Remote-Email"
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://127.0.0.1:9091/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
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

Validate and start:

```bash
docker compose config
docker compose up -d
docker compose ps
docker logs --tail 100 authelia
```

Open `https://auth.example.com`.

Expected:

```text
Authelia login page loads.
You can log in with the user from users_database.yml.
You can enroll TOTP/2FA.
```

Do not put Authelia in front of itself. The `auth.example.com` route must not
use the Authelia middleware.

## Phase 7: Prepare Traefik Logs For CrowdSec

CrowdSec needs access logs. Make sure Traefik writes them to a host-mounted
folder.

On the Docker VM:

```bash
sudo mkdir -p /opt/docker/traefik/logs
sudo chown -R "$USER":"$USER" /opt/docker/traefik/logs
```

In `/opt/docker/traefik/docker-compose.yml`, Traefik should have this volume:

```yaml
      - ./logs:/var/log/traefik
```

Edit if needed:

```bash
nano /opt/docker/traefik/docker-compose.yml
```

Restart Traefik:

```bash
cd /opt/docker/traefik
docker compose up -d
```

Generate one request, then check logs:

```bash
ls -la /opt/docker/traefik/logs
tail -n 5 /opt/docker/traefik/logs/access.log
```

Fallback if `access.log` does not exist — check that `traefik.yml` contains:

```yaml
accessLog:
  filePath: "/var/log/traefik/access.log"
```

## Phase 8: Create CrowdSec Folders

Run:

```bash
sudo mkdir -p /opt/stacks/crowdsec
sudo chown -R "$USER":"$USER" /opt/stacks/crowdsec
cd /opt/stacks/crowdsec
```

Create acquisition config:

```bash
cat > acquis.yaml <<'EOF'
filenames:
  - /var/log/traefik/access.log
labels:
  type: traefik
EOF
```

Create `.env` with a placeholder bouncer key:

```bash
cat > .env <<'EOF'
CROWDSEC_BOUNCER_KEY=replace_after_generating_key
EOF

chmod 600 .env
```

## Phase 9: Create CrowdSec Compose

Run:

```bash
cd /opt/stacks/crowdsec

cat > docker-compose.yml <<'EOF'
services:
  crowdsec:
    image: crowdsecurity/crowdsec:v1.7.8
    container_name: crowdsec
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    environment:
      COLLECTIONS: "crowdsecurity/traefik crowdsecurity/http-cve"
    volumes:
      - crowdsec_config:/etc/crowdsec
      - crowdsec_data:/var/lib/crowdsec/data
      - ./acquis.yaml:/etc/crowdsec/acquis.yaml:ro
      - /opt/docker/traefik/logs:/var/log/traefik:ro
    networks:
      - crowdsec
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:8080/health"]
      interval: 30s
      timeout: 5s
      retries: 3
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  bouncer-traefik:
    image: fbonalair/traefik-crowdsec-bouncer:0.5.0
    container_name: bouncer-traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    environment:
      CROWDSEC_BOUNCER_API_KEY: ${CROWDSEC_BOUNCER_KEY}
      CROWDSEC_AGENT_HOST: crowdsec:8080
    networks:
      - crowdsec
      - proxy
    depends_on:
      - crowdsec
    labels:
      - "traefik.enable=true"
      - "traefik.http.middlewares.crowdsec.forwardauth.address=http://bouncer-traefik:8080/api/v1/forwardAuth"
      - "traefik.http.middlewares.crowdsec.forwardauth.trustForwardHeader=true"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  crowdsec:
    name: crowdsec
  proxy:
    external: true

volumes:
  crowdsec_config:
  crowdsec_data:
EOF
```

Start the engine only:

```bash
docker compose up -d crowdsec
docker compose logs --tail 100 crowdsec
```

Generate the bouncer key:

```bash
docker exec -it crowdsec cscli bouncers add bouncer-traefik
```

Copy the key, then edit `.env`:

```bash
nano /opt/stacks/crowdsec/.env
```

Set:

```env
CROWDSEC_BOUNCER_KEY=paste_generated_key_here
```

Start everything:

```bash
cd /opt/stacks/crowdsec
docker compose up -d
docker compose ps
docker compose logs --tail 100 bouncer-traefik
```

Note: the per-service `bouncer-traefik` ForwardAuth setup above is the
initial deployment path. [crowdsec-all-services.md](crowdsec-all-services.md)
describes a later simplification that replaces this per-service bouncer
with a global Traefik plugin middleware covering every router automatically.

## Phase 10: Verify CrowdSec

Check installed collections:

```bash
docker exec crowdsec cscli collections list
```

Check metrics:

```bash
docker exec crowdsec cscli metrics
```

Check bouncer registration:

```bash
docker exec crowdsec cscli bouncers list
```

Expected:

```text
bouncer-traefik appears in bouncers list.
Traefik parser/scenario collections are installed.
CrowdSec sees the Traefik access log.
```

Fallback if CrowdSec shows no parsed lines:

```bash
tail -n 20 /opt/docker/traefik/logs/access.log
docker exec crowdsec cscli metrics
docker logs --tail 100 crowdsec
```

If the access log is empty, browse one Traefik-hosted service and retry.

## Phase 11: Add Middleware To Protected Services

Use this middleware order on protected routers:

```text
crowdsec@docker,authelia@docker,security-headers@file
```

Example labels for Grafana after you move it behind Traefik:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.grafana.rule=Host(`monitor.example.com`)"
  - "traefik.http.routers.grafana.entrypoints=websecure"
  - "traefik.http.routers.grafana.tls.certresolver=cloudflare"
  - "traefik.http.routers.grafana.middlewares=crowdsec@docker,authelia@docker,security-headers@file"
  - "traefik.http.services.grafana.loadbalancer.server.port=3000"
```

Example labels for Uptime Kuma:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.uptime-kuma.rule=Host(`status.example.com`)"
  - "traefik.http.routers.uptime-kuma.entrypoints=websecure"
  - "traefik.http.routers.uptime-kuma.tls.certresolver=cloudflare"
  - "traefik.http.routers.uptime-kuma.middlewares=crowdsec@docker,authelia@docker,security-headers@file"
  - "traefik.http.services.uptime-kuma.loadbalancer.server.port=3001"
```

Do not remove direct LAN ports from monitoring until the Traefik routes work.

## Phase 12: Recovery Path

Before protecting monitoring with Authelia, keep one way back in:

```text
SSH to Docker VM: ssh alice@192.168.1.20
Direct Grafana:   http://192.168.1.20:3000
Direct Kuma:      http://192.168.1.20:3001
```

After `monitor.example.com` and `status.example.com` work reliably, you can
remove the direct `ports:` from Grafana and Uptime Kuma.

Rollback Authelia:

```bash
cd /opt/stacks/authelia
docker compose down
```

Rollback CrowdSec:

```bash
cd /opt/stacks/crowdsec
docker compose down
```

If a service is locked behind broken middleware, remove the middleware label
and recreate that service:

```bash
docker compose up -d
```

## Minimum Success Checklist

```text
[ ] Traefik local HTTPS works.
[ ] auth.example.com loads Authelia.
[ ] Authelia login works.
[ ] Authelia TOTP/2FA enrollment works.
[ ] Traefik access.log exists on the host.
[ ] CrowdSec engine is running.
[ ] CrowdSec bouncer key is generated.
[ ] bouncer-traefik is running.
[ ] cscli bouncers list shows bouncer-traefik.
[ ] At least one test route uses crowdsec@docker and authelia@docker.
[ ] Direct LAN fallback still works until protected routes are proven.
```
