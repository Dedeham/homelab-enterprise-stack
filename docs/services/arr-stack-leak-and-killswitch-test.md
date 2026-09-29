# ARR Stack Leak And Kill-Switch Test

Last updated: 2026-06-11

Use this runbook before adding indexers, real downloads, or debrid automation.
It validates the current ARR design where qBittorrent owns the PIA WireGuard
namespace and the privacy-sensitive apps share that namespace.

This test covers:

- public IPv4 path;
- IPv6 behavior;
- container resolver configuration;
- live plaintext DNS leak watch;
- torrent-client leak test;
- kill-switch behavior when the tunnel is dropped;
- cold-start behavior when PIA configuration is intentionally broken.

The pass target is strict: qBittorrent, Prowlarr, Radarr, Sonarr, FlareSolverr,
and optional VPN-routed helpers must not expose the home WAN IP or plaintext DNS
outside the PIA tunnel.

## Scope

Protected by this runbook:

| Service | Expected network path |
|---|---|
| qBittorrent | PIA WireGuard through hotio qBittorrent VPN |
| Prowlarr | `network_mode: "service:qbittorrent"` |
| Radarr | `network_mode: "service:qbittorrent"` |
| Sonarr | `network_mode: "service:qbittorrent"` |
| FlareSolverr | `network_mode: "service:qbittorrent"` |
| Bazarr, optional | `network_mode: "service:qbittorrent"` |
| Recyclarr, optional | `network_mode: "service:qbittorrent"` |
| Unpackerr, optional | `network_mode: "service:qbittorrent"` |
| RDTClient, optional debrid | `network_mode: "service:qbittorrent"` |

Not protected by this runbook unless you later redesign them:

| Service | Current network path |
|---|---|
| Jellyfin | Normal Docker networking |
| Seerr | Normal Docker networking |
| Dockge | Normal Docker networking |

Jellyfin and Seerr may still perform metadata DNS/API calls through the normal
Docker VM path. That is separate from the ARR search/download privacy target.

## Safety Rules

- Do not use real downloads during this runbook.
- Use only a torrent leak-test magnet for qBittorrent.
- Run these commands on the Ubuntu Docker VM, not on TrueNAS.
- Stop if any protected service returns the home WAN IP.
- Stop if the DNS watch shows protected ARR DNS going to the router, ISP DNS, or
  public DNS outside the tunnel.
- Keep the `.env` backup created during the cold-start kill-switch test until
  the stack is restored.

## Variables

Set the service list for the containers that should share qBittorrent's network
namespace. Include optional services only if they are actually enabled.

```bash
cd /opt/stacks/arr-stack

ARR_VPN_SERVICES="qbittorrent prowlarr radarr sonarr flaresolverr"

# Optional examples:
# ARR_VPN_SERVICES="$ARR_VPN_SERVICES bazarr"
# ARR_VPN_SERVICES="$ARR_VPN_SERVICES recyclarr unpackerr"
# ARR_VPN_SERVICES="$ARR_VPN_SERVICES rdt-client"
```

Record the home WAN IP from the Docker VM outside the VPN namespace:

```bash
HOME_WAN_IP="$(curl -4 -fsS --max-time 15 https://ifconfig.me)"
printf 'Home WAN IPv4: %s\n' "$HOME_WAN_IP"
```

This value must never appear from a protected ARR container.

## Clean Rerun Start

Use this if you are rerunning the leak test after a failed region, broken
password test, or manual restart. It starts qBittorrent first, waits for
WireGuard, verifies the VPN IP, and only then starts the dependent apps.

```bash
cd /opt/stacks/arr-stack

docker compose stop qbittorrent prowlarr radarr sonarr flaresolverr
docker compose up -d qbittorrent

for i in $(seq 1 60); do
  if docker exec qbittorrent sh -lc 'ip link show wg0 >/dev/null 2>&1'; then
    echo "wg0 is present"
    break
  fi

  echo "waiting for wg0..."
  sleep 2
done

docker exec qbittorrent wg show
docker exec qbittorrent curl -4 -fsS --max-time 15 https://ifconfig.me
docker compose up -d
```

Pass criteria:

- `wg0 is present` is printed.
- `wg show` shows a recent handshake.
- The qBittorrent `curl` returns a PIA/VPN IP, not the home WAN IP.
- `docker compose up -d` starts the dependent VPN-routed apps without a
  qBittorrent healthcheck failure.

If the qBittorrent `curl` returns the home WAN IP, stop and do not continue the
test. qBittorrent either started before the VPN was ready or the VPN/firewall is
not enforcing correctly.

## Phase 1: Compose And Namespace Check

Confirm the stack is using the expected Compose model:

```bash
docker compose config | sed -n '/qbittorrent:/,/^[[:space:]]*[a-zA-Z0-9_-]*:/p'
docker compose config | grep -A4 -E '^[[:space:]]+(prowlarr|radarr|sonarr|flaresolverr|bazarr|recyclarr|unpackerr|rdt-client):'
docker compose ps
```

Pass criteria:

- qBittorrent has `VPN_ENABLED=true`.
- qBittorrent has `VPN_PROVIDER=pia`.
- qBittorrent has `VPN_NAMESERVERS=wg`.
- qBittorrent has `VPN_LAN_LEAK_ENABLED=false`.
- qBittorrent has `NET_ADMIN`.
- Prowlarr, Radarr, Sonarr, and FlareSolverr use
  `network_mode: service:qbittorrent`.
- Optional Bazarr, Recyclarr, Unpackerr, and RDTClient also use
  `network_mode: service:qbittorrent` if enabled.

Confirm qBittorrent has an address on the Docker bridge. All shared-namespace
containers use this same network namespace.

```bash
QB_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' qbittorrent)"
printf 'qBittorrent namespace Docker IP: %s\n' "$QB_IP"
```

## Phase 2: Baseline VPN Health

Check qBittorrent startup, WireGuard, and routes:

```bash
docker logs --tail 150 qbittorrent
docker exec qbittorrent wg show
docker exec qbittorrent ip route
docker exec qbittorrent ip addr show wg0
```

Pass criteria:

- qBittorrent is running.
- `wg show` shows interface `wg0`.
- `wg show` shows a recent handshake.
- The default route for internet traffic uses the VPN path.
- There is no normal default route that would let qBittorrent bypass the VPN for
  internet traffic.

## Phase 3: Public IPv4 Leak Test

Run the IPv4 check from every protected service:

```bash
for service in $ARR_VPN_SERVICES; do
  if docker inspect "$service" >/dev/null 2>&1; then
    printf '\n[%s] public IPv4: ' "$service"
    docker exec "$service" sh -lc 'curl -4 -fsS --max-time 15 https://ifconfig.me || curl -4 -fsS --max-time 15 https://api.ipify.org' || echo "FAILED"
  fi
done
```

Pass criteria:

- Every result is a PIA/VPN public IPv4.
- No result equals `$HOME_WAN_IP`.
- The protected services do not have to show exactly the same IP. PIA may use
  different exit IPs for separate requests.
- A failed request is safer than a home WAN result, but it still needs
  troubleshooting before the stack is considered ready.

Fail criteria:

- Any protected service returns the home WAN IP.
- Any protected service returns an ISP/router address.
- Any protected service works outside the VPN when qBittorrent reports no
  active tunnel.

## Phase 4: IPv6 Leak Test

Run the IPv6 check from every protected service:

```bash
for service in $ARR_VPN_SERVICES; do
  if docker inspect "$service" >/dev/null 2>&1; then
    printf '\n[%s] IPv6: ' "$service"
    docker exec "$service" sh -lc 'curl -6 -fsS --max-time 10 https://ifconfig.me && echo "IPv6 LEAK: investigate" || echo "IPv6 blocked as expected"'
  fi
done
```

Pass criteria:

- Every protected service prints `IPv6 blocked as expected`.
- DNS may still return IPv6 records. That is not a leak by itself. The leak is
  whether an IPv6 connection can leave the namespace.

Fail criteria:

- Any protected service successfully reaches `https://ifconfig.me` over IPv6.

## Phase 5: Resolver Configuration Check

Check resolver files and name lookups from the protected namespace:

```bash
docker exec qbittorrent cat /etc/resolv.conf

for service in $ARR_VPN_SERVICES; do
  if docker inspect "$service" >/dev/null 2>&1; then
    printf '\n[%s] resolver lookup:\n' "$service"
    docker exec "$service" sh -lc 'getent hosts example.com; getent hosts privateinternetaccess.com' || echo "FAILED"
  fi
done
```

Pass criteria:

- qBittorrent's `/etc/resolv.conf` uses the VPN namespace resolver. In this
  design, `nameserver 127.0.0.1` is expected because hotio uses the internal
  resolver path when `VPN_NAMESERVERS=wg`.
- `/etc/resolv.conf` does not point at the router, such as `192.168.1.1`.
- `/etc/resolv.conf` does not point at ISP DNS.
- Lookups succeed while the VPN is healthy.

Fail criteria:

- A protected service uses the LAN router, ISP DNS, or a public resolver directly
  outside the tunnel.

## Phase 6: Live Plaintext DNS Leak Watch

Open a first terminal on the Docker VM and start a DNS capture limited to the
qBittorrent network namespace IP:

```bash
QB_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' qbittorrent)"
sudo tcpdump -l -nn -vv -ni any "host $QB_IP and (udp port 53 or tcp port 53 or tcp port 853)"
```

Leave this running.

The warning below is normal when capturing on Linux's `any` device:

```text
any: That device doesn't support promiscuous mode
```

Quiet output can be normal and is usually good here. If the protected namespace
uses the internal VPN DNS path, `tcpdump` may print no plaintext DNS packets at
all. A quiet capture is a pass only when the public IPv4 checks also show PIA/VPN
IPs and no protected service returns the home WAN IP.

Open a second terminal and trigger DNS activity from the protected services:

```bash
for service in $ARR_VPN_SERVICES; do
  if docker inspect "$service" >/dev/null 2>&1; then
    printf '\n[%s] DNS trigger:\n' "$service"
    docker exec "$service" sh -lc 'getent hosts example.com; getent hosts debian.org; curl -4 -fsS --max-time 15 https://example.com >/dev/null && echo ok' || echo "FAILED"
  fi
done
```

Also open Prowlarr in the browser and test one indexer. If Radarr and Sonarr are
already configured, run their built-in download-client and indexer tests.

Stop `tcpdump` with `Ctrl+C`.

Pass criteria:

- No plaintext DNS packets leave from `$QB_IP` to the router, ISP DNS, or public
  DNS.
- No TCP/UDP 853 packets leave from `$QB_IP` outside the VPN path.
- Seeing WireGuard traffic to the PIA endpoint is normal, but it should not
  appear in this DNS-only capture.
- `0 packets captured` is acceptable if the trigger commands completed and no
  protected service used the home WAN IP.

Important limitation: this capture detects classic DNS and DoT outside the
tunnel. It does not decode encrypted HTTPS traffic. The IPv4 public-IP test and
kill-switch tests are what catch general non-DNS bypass behavior.

If you see unrelated host DNS in a broader `tcpdump -ni any 'udp port 53 or tcp
port 53'` capture, identify the source before treating it as an ARR leak.

## Phase 7: Torrent Leak Test

Use a reputable torrent leak-test site such as `ipleak.net` and copy its magnet
link. Do not use a real torrent.

In qBittorrent:

1. Add the leak-test magnet.
2. Wait until the leak-test page reports the torrent client IP.
3. Delete the test torrent and data from qBittorrent after the result is shown.

Pass criteria:

- The torrent leak-test page reports a PIA/VPN IP.
- The reported torrent IP does not equal `$HOME_WAN_IP`.
- The reported torrent IP may differ from the HTTPS `ifconfig.me` IP because VPN
  providers can use different exits for web and torrent flows.

Fail criteria:

- The leak-test page reports the home WAN IP.
- The leak-test page reports an ISP/router address.

## Phase 8: Live Tunnel-Drop Kill-Switch Test

This is the strongest local kill-switch test because it drops `wg0` while the
container namespace still exists.

Start a DNS capture in a first terminal:

```bash
QB_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' qbittorrent)"
sudo tcpdump -l -nn -vv -ni any "host $QB_IP and (udp port 53 or tcp port 53 or tcp port 853)"
```

The warning below is normal when using the Linux `any` capture device:

```text
any: That device doesn't support promiscuous mode
```

For this test, quiet output is expected. A summary such as `0 packets captured`
after pressing `Ctrl+C` is a pass for the DNS-capture part, provided the
protected-service commands also fail closed. The capture is only a failure if it
prints DNS traffic from `$QB_IP` to the router, ISP DNS, or public DNS after
`wg0` is down.

In a second terminal, drop the WireGuard interface:

```bash
docker exec qbittorrent sh -lc 'ip link set wg0 down'
```

Immediately test every protected service:

```bash
KILLSWITCH_DNS_NAME="arr-killswitch-$(date +%s).example.com"

for service in $ARR_VPN_SERVICES; do
  if docker inspect "$service" >/dev/null 2>&1; then
    printf '\n[%s] kill-switch IPv4: ' "$service"
    docker exec "$service" sh -lc 'curl -4 -fsS --max-time 10 https://ifconfig.me && echo "LEAK: investigate" || echo "blocked as expected"'

    printf '[%s] kill-switch DNS trigger: ' "$service"
    docker exec "$service" sh -lc "getent hosts $KILLSWITCH_DNS_NAME >/dev/null 2>&1 && echo \"unexpected DNS answer\" || echo \"lookup failed as expected; verify tcpdump stayed quiet\""
  fi
done
```

Stop `tcpdump` with `Ctrl+C`.

Pass criteria:

- Every protected service either fails to execute because the namespace is
  unhealthy or prints `blocked as expected`.
- No protected service returns `$HOME_WAN_IP`.
- The random DNS lookup fails or the container is unavailable.
- The DNS capture shows no DNS from `$QB_IP` to the router, ISP DNS, or public
  DNS after `wg0` is down.

Restore the stack:

```bash
docker compose stop qbittorrent prowlarr radarr sonarr flaresolverr
docker compose up -d qbittorrent

for i in $(seq 1 60); do
  if docker exec qbittorrent sh -lc 'ip link show wg0 >/dev/null 2>&1'; then
    echo "wg0 is present"
    break
  fi

  echo "waiting for wg0..."
  sleep 2
done

docker exec qbittorrent wg show
docker exec qbittorrent curl -4 -fsS --max-time 15 https://ifconfig.me
docker compose up -d
```

Pass criteria after restore:

- `wg show` shows a current handshake.
- qBittorrent returns a PIA/VPN public IPv4.
- Prowlarr, Radarr, Sonarr, and FlareSolverr become reachable again.

Do not run the post-restore `curl` before `wg0` exists. Docker can report the
container as started before hotio has finished the WireGuard initialization and
firewall setup. Start qBittorrent first, verify the VPN, then start the
dependent VPN-routed services.

## Phase 9: Cold-Start Kill-Switch Test

This test verifies that a broken PIA config does not fall back to the home WAN on
container startup.

Back up `.env`:

```bash
cd /opt/stacks/arr-stack
cp -a .env .env.before-killswitch-test
chmod 600 .env.before-killswitch-test
```

Edit `.env` and deliberately break one PIA value:

```bash
nano .env
```

Use one of these temporary changes:

```text
PIA_PASS=definitely_wrong_for_killswitch_test
```

or:

```text
PIA_REGION=definitely-invalid-region
```

Recreate qBittorrent and restart dependents:

```bash
docker compose up -d --force-recreate qbittorrent
docker compose up -d
docker compose ps
docker logs --tail 150 qbittorrent
```

If qBittorrent still starts cleanly and shows a valid `wg0` handshake, it may be
using an already generated `/config/wireguard/wg0.conf` instead of regenerating
from the intentionally broken PIA values. In that case, do not count this as a
cold-start failure test. Restore `.env`, confirm the stack is healthy, and rely
on the live tunnel-drop kill-switch result unless you intentionally perform a
separate first-boot simulation with the WireGuard config backed up and moved
aside.

Run the connectivity checks:

```bash
for service in $ARR_VPN_SERVICES; do
  if docker inspect "$service" >/dev/null 2>&1; then
    printf '\n[%s] cold-start IPv4: ' "$service"
    docker exec "$service" sh -lc 'curl -4 -fsS --max-time 10 https://ifconfig.me && echo "LEAK: investigate" || echo "blocked as expected"' || echo "blocked as expected"
  fi
done
```

Pass criteria:

- qBittorrent may restart, fail healthchecks, or fail to start.
- Dependent services may be unavailable because they share qBittorrent's
  namespace.
- No protected service returns `$HOME_WAN_IP`.
- No protected service reaches the internet through the normal Docker/LAN path.

Restore `.env` and recreate the stack:

```bash
cp -a .env.before-killswitch-test .env
chmod 600 .env

docker compose up -d --force-recreate qbittorrent

for i in $(seq 1 60); do
  if docker exec qbittorrent sh -lc 'ip link show wg0 >/dev/null 2>&1'; then
    echo "wg0 is present"
    break
  fi

  echo "waiting for wg0..."
  sleep 2
done

docker exec qbittorrent wg show
docker exec qbittorrent curl -4 -fsS --max-time 15 https://ifconfig.me
docker compose up -d
docker compose ps
```

The qBittorrent `curl` must return a PIA/VPN public IP before you start the rest
of the stack. Do not rely on Docker's `Started` state alone; it can appear before
the hotio WireGuard initialization and firewall setup are complete.

Keep `.env.before-killswitch-test` until the stack is confirmed healthy. Delete
it only after restoration is complete:

```bash
rm .env.before-killswitch-test
```

## Phase 10: Final Pass Record

Record the final state:

```bash
printf 'Home WAN IPv4: %s\n' "$HOME_WAN_IP"

for service in $ARR_VPN_SERVICES; do
  if docker inspect "$service" >/dev/null 2>&1; then
    printf '\n[%s] final IPv4: ' "$service"
    docker exec "$service" sh -lc 'curl -4 -fsS --max-time 15 https://ifconfig.me || curl -4 -fsS --max-time 15 https://api.ipify.org' || echo "FAILED"
  fi
done

docker exec qbittorrent wg show
docker compose ps
```

The ARR stack is cleared for indexer setup and legal end-to-end download testing
only when all of these are true:

- [ ] qBittorrent has active `wg0`.
- [ ] qBittorrent, Prowlarr, Radarr, Sonarr, and FlareSolverr return PIA/VPN
      public IPv4 addresses.
- [ ] Optional VPN-routed helpers return PIA/VPN public IPv4 addresses.
- [ ] No protected service returns the home WAN IP.
- [ ] IPv6 connections are blocked from every protected service.
- [ ] Protected service resolvers do not point at the router or ISP DNS.
- [ ] Live DNS watch shows no plaintext DNS from the protected namespace to the
      router, ISP DNS, or public DNS.
- [ ] qBittorrent torrent leak-test magnet reports a PIA/VPN IP.
- [ ] Live `wg0` tunnel-drop test blocks internet and DNS.
- [ ] Cold-start broken-PIA test does not fall back to the home WAN.
- [ ] Stack restores cleanly after both kill-switch tests.

## Failure Response

If any protected service leaks the home WAN IP:

1. Stop qBittorrent and the shared namespace services.
2. Do not add indexers or real downloads.
3. Re-check `network_mode: "service:qbittorrent"` for every protected service.
4. Re-check qBittorrent VPN variables: `VPN_ENABLED`, `VPN_PROVIDER`,
   `VPN_NAMESERVERS`, `VPN_LAN_LEAK_ENABLED`, PIA username, PIA password, and
   PIA region.
5. Re-run the runbook from Phase 1.

```bash
docker compose stop qbittorrent prowlarr radarr sonarr flaresolverr
```

If the design falls back to the home WAN when `wg0` is down, do not use this
stack for torrenting. Replace the VPN gateway design, for example with a
dedicated Gluetun gateway, then repeat the full leak and kill-switch runbook.
