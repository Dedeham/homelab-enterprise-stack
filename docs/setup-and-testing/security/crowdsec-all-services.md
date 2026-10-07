# CrowdSec: Quickly Protecting All Traefik Services

As of: 2026-08-20

This guide matches this environment:

- CrowdSec `v1.7.8` is already running healthy.
- Traefik uses `/opt/stacks/traefik/compose.yml`.
- The Docker network `proxy` is `172.29.0.0/16`.
- LAN is `192.168.1.0/24`, Tailscale is `100.64.0.0/10`.
- All HTTPS routers use `websecure`.

The result:

- Every HTTP router on `websecure` automatically gets CrowdSec protection.
- No need to add labels to individual services.
- Stream mode uses a local in-memory cache and is fast.
- AppSec stays off; Jellyfin/Emby streaming request bodies are not inspected.
- LAN and Tailscale traffic is never blocked.
- If CrowdSec goes down, Traefik stays reachable (fail-open).

> CrowdSec only protects connections that actually pass through Traefik.
> Directly published ports such as `7878`, `8096`, or `8989` bypass Traefik
> and therefore bypass CrowdSec too. Such ports must only ever be reachable
> from LAN/Tailscale, never directly from the internet.

## 1. Backup And Prerequisites

Copy the whole block:

```bash
set -o pipefail

CROWDSEC_COMPOSE_FILE="$(docker inspect crowdsec --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')"
TRAEFIK_COMPOSE_FILE="$(docker inspect traefik --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')"

test -f "$CROWDSEC_COMPOSE_FILE"
test -f "$TRAEFIK_COMPOSE_FILE"
test -f /opt/stacks/traefik/traefik.yml
test -d /opt/stacks/traefik/dynamic
docker network inspect crowdsec >/dev/null
docker network inspect proxy >/dev/null

GUIDE_BACKUP_DIR="/opt/stack-backups/crowdsec-global-$(date +%F-%H%M%S)"
sudo install -d -m 700 "$GUIDE_BACKUP_DIR"
sudo cp -a /opt/stacks/crowdsec "$GUIDE_BACKUP_DIR/"
sudo cp -a /opt/stacks/traefik "$GUIDE_BACKUP_DIR/"

echo "CrowdSec compose: $CROWDSEC_COMPOSE_FILE"
echo "Traefik compose:  $TRAEFIK_COMPOSE_FILE"
echo "Backup:           $GUIDE_BACKUP_DIR"
```

If the block completes without errors, continue to step 2.

## 2. Generate The Secret And Register The Bouncer

```bash
set -o pipefail

CROWDSEC_COMPOSE_FILE="$(docker inspect crowdsec --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')"

docker compose -f "$CROWDSEC_COMPOSE_FILE" config --quiet
docker compose -f "$CROWDSEC_COMPOSE_FILE" up -d crowdsec

for CROWDSEC_WAIT_ATTEMPT in $(seq 1 30); do
  CROWDSEC_HEALTH="$(docker inspect crowdsec --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')"
  [ "$CROWDSEC_HEALTH" = "healthy" ] && break
  sleep 2
done

test "$(docker inspect crowdsec --format '{{.State.Running}}')" = "true"
test "$(docker inspect crowdsec --format '{{.State.Health.Status}}')" = "healthy"

sudo install -d -m 700 /opt/stacks/traefik/secrets

if ! sudo test -s /opt/stacks/traefik/secrets/crowdsec_lapi_key; then
  sudo sh -c 'umask 077; openssl rand -hex 32 | tr -d "\n" > /opt/stacks/traefik/secrets/crowdsec_lapi_key'
fi

docker exec crowdsec cscli bouncers delete traefik-global >/dev/null 2>&1 || true

docker exec crowdsec cscli bouncers add traefik-global \
  --key "$(sudo cat /opt/stacks/traefik/secrets/crowdsec_lapi_key)"

sudo test -s /opt/stacks/traefik/secrets/crowdsec_lapi_key
docker exec crowdsec cscli bouncers list

unset CROWDSEC_WAIT_ATTEMPT CROWDSEC_HEALTH
```

The key is never printed and never stored in Compose or `.env`.

## 3. Simplify The CrowdSec Compose File

The old `fbonalair` ForwardAuth bouncer is removed. CrowdSec, its named
volumes, and `acquis.yaml` are left unchanged.

```bash
set -o pipefail

CROWDSEC_COMPOSE_FILE="$(docker inspect crowdsec --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')"
CROWDSEC_YQ_FILE="/stacks${CROWDSEC_COMPOSE_FILE#/opt/stacks}"

docker run --rm \
  --user 0:0 \
  -v /opt/stacks:/stacks \
  mikefarah/yq:4.53.3 -i '
    del(.services."bouncer-traefik") |
    del(.networks.proxy)
  ' "$CROWDSEC_YQ_FILE"

sudo tee /opt/stacks/crowdsec/acquis.yaml >/dev/null <<'YAML'
filenames:
  - /var/log/traefik/access.log
labels:
  type: traefik
YAML

cd /opt/stacks/crowdsec
docker compose -f "$CROWDSEC_COMPOSE_FILE" config --quiet
docker compose -f "$CROWDSEC_COMPOSE_FILE" up -d --remove-orphans
docker compose -f "$CROWDSEC_COMPOSE_FILE" ps
```

`--remove-orphans` only removes the now-undefined old bouncer container. The
CrowdSec volumes are not deleted.

## 4. Update The Traefik Compose File Automatically

This block only adds the secret and the CrowdSec network. Existing volumes
and networks are preserved.

```bash
set -o pipefail

TRAEFIK_COMPOSE_FILE="$(docker inspect traefik --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')"
TRAEFIK_YQ_FILE="/stacks${TRAEFIK_COMPOSE_FILE#/opt/stacks}"

docker run --rm \
  --user 0:0 \
  -v /opt/stacks:/stacks \
  mikefarah/yq:4.53.3 -i '
    .services.traefik.volumes = (((.services.traefik.volumes // []) +
      ["./secrets/crowdsec_lapi_key:/run/secrets/crowdsec_lapi_key:ro"]) | unique) |
    .services.traefik.networks = (((.services.traefik.networks // []) +
      ["crowdsec"]) | unique) |
    .networks.crowdsec = {"name": "crowdsec", "external": true}
  ' "$TRAEFIK_YQ_FILE"

cd /opt/stacks/traefik
docker compose -f "$TRAEFIK_COMPOSE_FILE" config --quiet
```

## 5. Configure Traefik Globally

The following block:

- installs the `v1.7.1` plugin;
- trusts forwarded headers only from your controlled proxy network;
- sets `crowdsec@file` automatically in front of every router on
  `websecure`.

```bash
set -o pipefail

docker run --rm \
  --user 0:0 \
  -v /opt/stacks:/stacks \
  mikefarah/yq:4.53.3 -i '
    .experimental.plugins.bouncer.moduleName =
      "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin" |
    .experimental.plugins.bouncer.version = "v1.7.1" |
    .entryPoints.websecure.forwardedHeaders.trustedIPs = ["172.29.0.0/16"] |
    .entryPoints.websecure.http.middlewares =
      (((.entryPoints.websecure.http.middlewares // []) + ["crowdsec@file"]) | unique)
  ' /stacks/traefik/traefik.yml
```

All existing router middlewares, such as security headers, rate limiting, or
Authelia, remain in place and run after CrowdSec.

## 6. Create The Quick Global Middleware

```bash
sudo tee /opt/stacks/traefik/dynamic/crowdsec.yml >/dev/null <<'YAML'
http:
  middlewares:
    crowdsec:
      plugin:
        bouncer:
          enabled: true
          logLevel: INFO

          crowdsecMode: stream
          crowdsecLapiScheme: http
          crowdsecLapiHost: crowdsec:8080
          crowdsecLapiPath: "/"
          crowdsecLapiKeyFile: /run/secrets/crowdsec_lapi_key

          crowdsecAppsecEnabled: false

          forwardedHeadersCustomName: X-Forwarded-For
          forwardedHeadersTrustedIPs:
            - "172.29.0.0/16"

          clientTrustedIPs:
            - "192.168.1.0/24"
            - "100.64.0.0/10"

          updateIntervalSeconds: 60
          updateMaxFailure: -1
          streamStartupBlock: false
          metricsUpdateIntervalSeconds: 600
YAML
```

## 7. Restart And Verify Traefik

```bash
set -o pipefail

TRAEFIK_COMPOSE_FILE="$(docker inspect traefik --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')"

cd /opt/stacks/traefik
docker compose -f "$TRAEFIK_COMPOSE_FILE" config --quiet
docker compose -f "$TRAEFIK_COMPOSE_FILE" up -d --force-recreate traefik

sleep 10

docker compose -f "$TRAEFIK_COMPOSE_FILE" ps
docker inspect traefik --format '{{range $name,$net := .NetworkSettings.Networks}}{{println $name $net.IPAddress}}{{end}}'
docker exec traefik sh -c 'test -s /run/secrets/crowdsec_lapi_key && echo secret-ok'
docker exec crowdsec cscli bouncers list
docker logs --since=2m traefik 2>&1 | grep -Ei 'crowdsec|plugin|error' || true
```

None of these errors should appear:

```text
port is missing
unknown plugin type
crowdsecLapiKey fail
connection refused
```

## 8. Automatic Block Test

The reserved test value `198.51.100.123` is blocked for two minutes. A
short-lived container on the trusted proxy network then simulates a request
using that client IP.

```bash
set -o pipefail

docker exec crowdsec cscli decisions delete --ip 198.51.100.123 >/dev/null 2>&1 || true
docker exec crowdsec cscli decisions add \
  --ip 198.51.100.123 \
  --duration 2m \
  --reason "global middleware test"

echo "Waiting 65 seconds for the stream sync..."
sleep 65

TRAEFIK_PROXY_IP="$(docker inspect traefik --format '{{(index .NetworkSettings.Networks "proxy").IPAddress}}')"
test -n "$TRAEFIK_PROXY_IP"

docker run --rm --network proxy \
  --add-host "requests.example.com:$TRAEFIK_PROXY_IP" \
  busybox:1.37.0 \
  wget -S -O /dev/null --no-check-certificate \
  --header='X-Forwarded-For: 198.51.100.123' \
  https://requests.example.com 2>&1 || true

docker exec crowdsec cscli decisions delete --ip 198.51.100.123
unset TRAEFIK_PROXY_IP
```

The output must show `HTTP/1.1 403 Forbidden` or `HTTP/2 403`. Within at most
60 more seconds, the test decision disappears from the stream cache.

Also briefly check in a browser:

- a domain on the LAN;
- a domain over Tailscale;
- Seerr/Jellyfin/Emby through the normal public path.

## Checks

```bash
docker exec crowdsec cscli metrics show acquisition parsers scenarios \
  --url http://127.0.0.1:6060/metrics
docker exec crowdsec cscli alerts list --since 24h
docker exec crowdsec cscli decisions list
docker exec crowdsec cscli bouncers list
```

## Single-Block Rollback

This block only reverts the CrowdSec integration and restores the most
recent backup created by this guide:

```bash
set -o pipefail

GUIDE_BACKUP_DIR="$(find /opt/stack-backups -maxdepth 1 -type d -name 'crowdsec-global-*' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)"
test -n "$GUIDE_BACKUP_DIR"

CROWDSEC_COMPOSE_FILE="$(docker inspect crowdsec --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')"
TRAEFIK_COMPOSE_FILE="$(docker inspect traefik --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')"

sudo cp -a "$GUIDE_BACKUP_DIR/crowdsec/$(basename "$CROWDSEC_COMPOSE_FILE")" "$CROWDSEC_COMPOSE_FILE"
sudo cp -a "$GUIDE_BACKUP_DIR/traefik/$(basename "$TRAEFIK_COMPOSE_FILE")" "$TRAEFIK_COMPOSE_FILE"
sudo cp -a "$GUIDE_BACKUP_DIR/traefik/traefik.yml" /opt/stacks/traefik/traefik.yml

if [ -f /opt/stacks/traefik/dynamic/crowdsec.yml ]; then
  sudo mv /opt/stacks/traefik/dynamic/crowdsec.yml \
    /opt/stacks/traefik/dynamic/crowdsec.yml.disabled
fi

cd /opt/stacks/crowdsec
docker compose -f "$CROWDSEC_COMPOSE_FILE" config --quiet
docker compose -f "$CROWDSEC_COMPOSE_FILE" up -d --remove-orphans

cd /opt/stacks/traefik
docker compose -f "$TRAEFIK_COMPOSE_FILE" config --quiet
docker compose -f "$TRAEFIK_COMPOSE_FILE" up -d --force-recreate traefik

docker logs --tail=100 traefik
```

No named volumes are deleted.

## Important

- The global protection applies to all HTTP routers on `websecure`.
- TCP/UDP routers and directly published container ports are not covered.
- AppSec is intentionally disabled; the fast IP/scenario protection stays
  active.
- Never use `docker compose down -v`.

## Sources

- [Traefik: EntryPoint middlewares apply automatically to every associated router](https://doc.traefik.io/traefik/reference/install-configuration/entrypoints/#httpmiddlewares)
- [CrowdSec Traefik Plugin](https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin)
- [CrowdSec Docker](https://docs.crowdsec.net/u/getting_started/installation/docker/)
