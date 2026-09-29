# CrowdSec: alle Traefik-Dienste schnell schützen

Stand: 2026-08-20

Dieser Guide passt zu deiner Umgebung:

- CrowdSec `v1.7.8` läuft bereits healthy.
- Traefik verwendet `/opt/stacks/traefik/compose.yml`.
- Das Docker-Netz `proxy` ist `172.29.0.0/16`.
- LAN ist `192.168.1.0/24`, Tailscale `100.64.0.0/10`.
- Alle HTTPS-Router verwenden `websecure`.

Das Ergebnis:

- Jeder HTTP-Router auf `websecure` bekommt CrowdSec automatisch.
- Du musst keine Labels bei einzelnen Diensten ergänzen.
- Stream-Modus verwendet einen lokalen Speicher-Cache und ist schnell.
- AppSec bleibt aus; Jellyfin/Emby-Streaming wird nicht auf Request-Bodies geprüft.
- LAN und Tailscale werden nicht blockiert.
- Bei CrowdSec-Ausfall bleibt Traefik erreichbar (Fail-open).

> CrowdSec schützt nur Verbindungen, die tatsächlich durch Traefik laufen. Direkt veröffentlichte Ports wie `7878`, `8096` oder `8989` umgehen Traefik und damit CrowdSec. Solche Ports dürfen nur im LAN/Tailscale erreichbar sein, niemals direkt aus dem Internet.

## 1. Backup und Voraussetzungen

Den gesamten Block kopieren:

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

Wenn der Block ohne Fehler endet, weiter mit Schritt 2.

## 2. Secret erzeugen und Bouncer registrieren

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

Der Schlüssel wird nicht ausgegeben und nicht in Compose oder `.env` gespeichert.

## 3. CrowdSec-Compose vereinfachen

Der alte `fbonalair`-ForwardAuth-Bouncer wird entfernt. CrowdSec, seine Named Volumes und `acquis.yaml` bleiben unverändert.

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

`--remove-orphans` entfernt nur den jetzt nicht mehr definierten alten Bouncer-Container. Die CrowdSec-Volumes werden nicht gelöscht.

## 4. Traefik-Compose automatisch ergänzen

Dieser Block ergänzt nur das Secret und das CrowdSec-Netz. Vorhandene Volumes und Netzwerke bleiben erhalten.

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

## 5. Traefik global konfigurieren

Der folgende Block:

- installiert das Plugin `v1.7.1`;
- vertraut Forwarded Headers nur aus deinem kontrollierten Proxy-Netz;
- setzt `crowdsec@file` automatisch vor alle Router auf `websecure`.

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

Alle vorhandenen Router-Middlewares wie Security-Headers, Rate-Limit oder Authelia bleiben bestehen und laufen nach CrowdSec.

## 6. Schnelle globale Middleware anlegen

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

## 7. Traefik neu starten und prüfen

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

Diese Fehler dürfen nicht erscheinen:

```text
port is missing
unknown plugin type
crowdsecLapiKey fail
connection refused
```

## 8. Automatischer Block-Test

Der reservierte Testwert `198.51.100.123` wird zwei Minuten gesperrt. Ein kurzlebiger Container im vertrauenswürdigen Proxy-Netz simuliert anschließend einen Request mit dieser Client-IP.

```bash
set -o pipefail

docker exec crowdsec cscli decisions delete --ip 198.51.100.123 >/dev/null 2>&1 || true
docker exec crowdsec cscli decisions add \
  --ip 198.51.100.123 \
  --duration 2m \
  --reason "global middleware test"

echo "Warte 65 Sekunden auf den Stream-Abgleich ..."
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

In der Ausgabe muss `HTTP/1.1 403 Forbidden` oder `HTTP/2 403` stehen. Nach spätestens 60 weiteren Sekunden ist die Testentscheidung aus dem Stream-Cache verschwunden.

Zusätzlich kurz im Browser prüfen:

- eine Domain im LAN;
- eine Domain über Tailscale;
- Seerr/Jellyfin/Emby über den normalen öffentlichen Weg.

## Kontrolle

```bash
docker exec crowdsec cscli metrics show acquisition parsers scenarios \
  --url http://127.0.0.1:6060/metrics
docker exec crowdsec cscli alerts list --since 24h
docker exec crowdsec cscli decisions list
docker exec crowdsec cscli bouncers list
```

## Ein-Block-Rollback

Dieser Block nimmt nur die CrowdSec-Integration zurück und stellt die zuletzt durch diesen Guide angelegte Sicherung wieder her:

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

Keine Named Volumes werden gelöscht.

## Wichtig

- Der globale Schutz gilt für alle HTTP-Router auf `websecure`.
- TCP-/UDP-Router und direkt veröffentlichte Container-Ports sind nicht abgedeckt.
- AppSec ist absichtlich deaktiviert; der schnelle IP-/Szenario-Schutz bleibt aktiv.
- Niemals `docker compose down -v` verwenden.

## Quellen

- [Traefik: EntryPoint-Middlewares gelten automatisch für jeden zugeordneten Router](https://doc.traefik.io/traefik/reference/install-configuration/entrypoints/#httpmiddlewares)
- [CrowdSec Traefik Plugin](https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin)
- [CrowdSec Docker](https://docs.crowdsec.net/u/getting_started/installation/docker/)
