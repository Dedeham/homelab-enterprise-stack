# Bitmagnet Gluetun IP Leak Test

Last updated: 2026-06-21

Use this short runbook after deploying Bitmagnet with
[the local Bitmagnet guide](bitmagnet-local-prowlarr-integration-guide.md).

Gluetun supplies the VPN routing and firewall, but a configuration mistake can
still place Bitmagnet on the wrong Docker network. Test the setup after initial
deployment and after changing Compose networking, Gluetun, VPN credentials, or
container images.

## Expected Topology

| Service | Expected path |
|---|---|
| Bitmagnet | `network_mode: "service:gluetun"` through `debrid-gluetun` |
| RDTClient | Direct Docker networking; intentionally not protected by this test |
| PostgreSQL | Internal `debrid` network; no published port |

Run all commands on the Ubuntu Docker VM.

## 1. Check Container State

```bash
cd /opt/stacks/debrid-stack
docker compose ps
```

Pass criteria:

- `debrid-gluetun` is healthy.
- `debrid-bitmagnet` is running.
- `debrid-bitmagnet-postgres` is healthy.
- RDTClient remains available on `192.168.1.20:6500`.

## 2. Prove The Shared Network Namespace

```bash
GLUETUN_ID="$(docker inspect -f '{{.Id}}' debrid-gluetun)"
BITMAGNET_MODE="$(docker inspect -f '{{.HostConfig.NetworkMode}}' debrid-bitmagnet)"
RDT_MODE="$(docker inspect -f '{{.HostConfig.NetworkMode}}' debrid-rdt-client)"

printf 'Expected Bitmagnet mode: container:%s\n' "$GLUETUN_ID"
printf 'Actual Bitmagnet mode:   %s\n' "$BITMAGNET_MODE"
printf 'RDTClient mode:          %s\n' "$RDT_MODE"

test "$BITMAGNET_MODE" = "container:$GLUETUN_ID" \
  && echo "PASS: Bitmagnet shares Gluetun" \
  || echo "FAIL: Bitmagnet is not using Gluetun"

test "$RDT_MODE" != "container:$GLUETUN_ID" \
  && echo "PASS: RDTClient remains direct" \
  || echo "FAIL: RDTClient was unexpectedly routed through Gluetun"
```

Stop if either result prints `FAIL`.

## 3. Compare Public IPv4 Addresses

```bash
HOME_WAN_IP="$(curl -4 -fsS --max-time 15 https://ifconfig.me/ip)"
GLUETUN_IP="$(docker exec debrid-gluetun wget -qO- --timeout=15 https://ifconfig.me/ip)"
BITMAGNET_IP="$(docker exec debrid-bitmagnet curl -4 -fsS --max-time 15 https://ifconfig.me/ip)"

printf 'Home WAN IPv4: %s\n' "$HOME_WAN_IP"
printf 'Gluetun IPv4:  %s\n' "$GLUETUN_IP"
printf 'Bitmagnet IPv4:%s\n' "$BITMAGNET_IP"
```

Pass criteria:

- `$GLUETUN_IP` differs from `$HOME_WAN_IP`.
- `$BITMAGNET_IP` equals `$GLUETUN_IP`.
- Bitmagnet never returns `$HOME_WAN_IP`.

Enforce those criteria:

```bash
test "$GLUETUN_IP" != "$HOME_WAN_IP" \
  && test "$BITMAGNET_IP" = "$GLUETUN_IP" \
  && echo "PASS: Bitmagnet public IPv4 uses Gluetun" \
  || echo "FAIL: stop Bitmagnet and inspect its networking"
```

An IP lookup alone is not enough to prove the kill switch. Complete section 6.

## 4. Check IPv6

```bash
if docker exec debrid-bitmagnet curl -6 -fsS --max-time 10 https://ifconfig.me/ip; then
  echo "FAIL: Bitmagnet has working public IPv6"
else
  echo "PASS: Bitmagnet public IPv6 is blocked"
fi
```

Any returned public IPv6 address is a failure unless the VPN is deliberately
configured and independently verified to tunnel IPv6.

## 5. Check DNS Sanity

```bash
docker exec debrid-gluetun cat /etc/resolv.conf
docker exec debrid-bitmagnet cat /etc/resolv.conf
docker logs --tail 150 debrid-gluetun \
  | grep -Ei 'dns|doh|listening|ready' \
  | tail -30
```

Pass criteria:

- Bitmagnet can resolve names while Gluetun is healthy.
- Gluetun reports its DNS service ready.
- The logs do not show repeated resolver failures.
- Bitmagnet is not configured with the router or ISP DNS server directly.

Trigger one lookup through Bitmagnet if needed:

```bash
docker exec debrid-bitmagnet sh -lc \
  'getent hosts example.com || nslookup example.com'
```

This is a resolver sanity check, not a full packet-level DNS audit. Gluetun's
configured DoH resolver encrypts upstream DNS, but repeated DNS errors must be
fixed before relying on Bitmagnet.

## 6. Prove The Kill Switch

This test stops Gluetun. Bitmagnet should lose internet access, while the direct
RDTClient should remain available.

```bash
docker stop debrid-gluetun
sleep 3

if docker exec debrid-bitmagnet curl -4 -fsS --max-time 10 https://ifconfig.me/ip; then
  echo "FAIL: Bitmagnet still has internet access"
else
  echo "PASS: Bitmagnet failed closed"
fi

curl -fsS --max-time 15 http://192.168.1.20:6500 >/dev/null \
  && echo "PASS: direct RDTClient stayed available" \
  || echo "CHECK: RDTClient was unavailable"
```

A failed `docker exec` is acceptable after Gluetun stops. Bitmagnet shares
Gluetun's namespace, so the namespace may be unavailable or have no working
route. The only unacceptable result is a public IP response.

Restore Gluetun and Bitmagnet:

```bash
cd /opt/stacks/debrid-stack
docker compose up -d gluetun

for i in $(seq 1 60); do
  if docker inspect -f '{{.State.Health.Status}}' debrid-gluetun 2>/dev/null \
    | grep -q healthy; then
    echo "Gluetun is healthy"
    break
  fi
  sleep 2
done

docker compose up -d --force-recreate --no-deps bitmagnet

BITMAGNET_IP=""
for i in $(seq 1 30); do
  if BITMAGNET_IP="$(docker exec debrid-bitmagnet \
    curl -4 -fsS --max-time 15 https://ifconfig.me/ip 2>/dev/null)"; then
    printf 'Bitmagnet public IPv4: %s\n' "$BITMAGNET_IP"
    break
  fi
  sleep 2
done

if [ -z "$BITMAGNET_IP" ]; then
  echo "FAIL: Bitmagnet did not recover after Gluetun restoration"
  docker compose logs --tail=150 gluetun bitmagnet
fi
```

The final result must again be the VPN IPv4, not the home WAN IPv4.

## Failure Response

If Bitmagnet returns the home WAN IP or survives the kill-switch test:

```bash
cd /opt/stacks/debrid-stack
docker compose stop bitmagnet
docker inspect -f '{{.HostConfig.NetworkMode}}' debrid-bitmagnet
docker compose config | grep -A12 '^  bitmagnet:'
docker logs --tail 250 debrid-gluetun
```

Do not restart Bitmagnet until its rendered Compose configuration contains:

```yaml
network_mode: "service:gluetun"
```

and the complete test passes.

Once the rendered configuration is correct and Gluetun is healthy, recreate
Bitmagnet against the current Gluetun container namespace:

```bash
docker compose up -d --force-recreate --no-deps bitmagnet

for i in $(seq 1 30); do
  if docker exec debrid-bitmagnet \
    curl -4 -fsS --max-time 15 https://ifconfig.me/ip; then
    break
  fi
  sleep 2
done
```

Then repeat the namespace, VPN IPv4, IPv6, DNS, and kill-switch checks before
marking the test complete.

## Pass Checklist

- [ ] Bitmagnet shares the exact `debrid-gluetun` container namespace.
- [ ] RDTClient remains direct.
- [ ] Gluetun IPv4 differs from the home WAN IPv4.
- [ ] Bitmagnet IPv4 equals the Gluetun IPv4.
- [ ] Bitmagnet has no working public IPv6 path.
- [ ] Gluetun DNS is healthy and Bitmagnet resolves through it.
- [ ] Stopping Gluetun blocks Bitmagnet internet access.
- [ ] RDTClient remains available during the Gluetun stop test.
- [ ] Bitmagnet returns to the VPN IPv4 after restoration.
