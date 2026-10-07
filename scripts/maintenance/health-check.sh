#!/bin/bash
# Quick terminal snapshot of server health: resources, ZFS, Docker containers,
# service reachability, and recent container log errors. For 24/7 automated
# alerting, use the monitoring stack (Grafana + Alertmanager + Uptime Kuma)
# instead — this is for a quick manual check or troubleshooting.
#
# Usage:
#   bash health-check.sh              Full check
#   bash health-check.sh --quick      Skip slow checks (URL reachability)

set -uo pipefail

QUICK=false
[[ "${1:-}" == "--quick" ]] && QUICK=true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}OK${NC} $1"; }
warn() { echo -e "  ${YELLOW}!!${NC} $1"; }
fail() { echo -e "  ${RED}XX${NC} $1"; }
section() { echo ""; echo -e "${BOLD}${BLUE}-- $1 --${NC}"; }

IS_PROXMOX=false
IS_TRUENAS=false
[[ -f /etc/pve/local/pve-ssl.pem ]] && IS_PROXMOX=true
[[ -f /etc/version ]] && grep -q "TrueNAS" /etc/version 2>/dev/null && IS_TRUENAS=true

echo ""
echo -e "${BOLD}Home Server Health Check - $(date '+%Y-%m-%d %H:%M:%S')${NC}"

section "System Resources"

# Load average below 70% of core count is healthy; above core count is high.
LOAD=$(awk '{print $1}' /proc/loadavg)
CPU_COUNT=$(nproc)
LOAD_PCT=$(awk "BEGIN {printf \"%.0f\", ($LOAD/$CPU_COUNT)*100}")
if (( $(awk "BEGIN {print ($LOAD < $CPU_COUNT * 0.7)}") )); then
    ok "CPU load: ${LOAD} (${LOAD_PCT}% of ${CPU_COUNT} cores)"
elif (( $(awk "BEGIN {print ($LOAD < $CPU_COUNT)}") )); then
    warn "CPU load: ${LOAD} (${LOAD_PCT}% of ${CPU_COUNT} cores) - elevated"
else
    fail "CPU load: ${LOAD} (${LOAD_PCT}% of ${CPU_COUNT} cores) - HIGH"
fi

MEM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_AVAILABLE=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
MEM_USED=$(( MEM_TOTAL - MEM_AVAILABLE ))
MEM_PCT=$(awk "BEGIN {printf \"%.0f\", ($MEM_USED/$MEM_TOTAL)*100}")
MEM_USED_GB=$(awk "BEGIN {printf \"%.1f\", $MEM_USED/1024/1024}")
MEM_TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $MEM_TOTAL/1024/1024}")

if [[ $MEM_PCT -lt 80 ]]; then
    ok "RAM: ${MEM_USED_GB} GB / ${MEM_TOTAL_GB} GB used (${MEM_PCT}%)"
elif [[ $MEM_PCT -lt 90 ]]; then
    warn "RAM: ${MEM_USED_GB} GB / ${MEM_TOTAL_GB} GB used (${MEM_PCT}%) - elevated"
else
    fail "RAM: ${MEM_USED_GB} GB / ${MEM_TOTAL_GB} GB used (${MEM_PCT}%) - HIGH"
fi

echo "  Disk space:"
df -h --output=target,used,avail,pcent | tail -n +2 | while IFS= read -r line; do
    MOUNT=$(echo "$line" | awk '{print $1}')
    PCT=$(echo "$line" | awk '{print $4}' | tr -d '%')
    DISPLAY=$(echo "$line" | awk '{printf "%-30s %s used, %s free (%s)", $1, $2, $3, $4}')
    echo "$MOUNT" | grep -qE "^/(proc|sys|dev|run|snap)" && continue
    if [[ $PCT -lt 80 ]]; then
        ok "$DISPLAY"
    elif [[ $PCT -lt 90 ]]; then
        warn "$DISPLAY"
    else
        fail "$DISPLAY <- ACTION NEEDED"
    fi
done

section "ZFS Pool Status"

if command -v zpool &>/dev/null; then
    while IFS= read -r line; do
        POOL=$(echo "$line" | awk '{print $1}')
        STATE=$(echo "$line" | awk '{print $2}')
        if [[ "$STATE" == "ONLINE" ]]; then
            ok "Pool '${POOL}': ${STATE}"
        elif [[ "$STATE" == "DEGRADED" ]]; then
            warn "Pool '${POOL}': ${STATE} - a drive may have failed, check zpool status"
        else
            fail "Pool '${POOL}': ${STATE} - REQUIRES ATTENTION"
        fi
    done < <(zpool list -H -o name,health 2>/dev/null)

    SCRUB_ERRORS=$(zpool status 2>/dev/null | grep "errors:" | grep -v "No known data errors" | head -5)
    if [[ -n "$SCRUB_ERRORS" ]]; then
        fail "ZFS errors detected: $SCRUB_ERRORS"
    else
        ok "No ZFS data errors"
    fi
else
    warn "zpool not available on this host (run on TrueNAS for ZFS checks)"
fi

section "Docker Containers"

if command -v docker &>/dev/null; then
    docker ps -a --format "{{.Names}}\t{{.Status}}" | while IFS=$'\t' read -r name status; do
        if echo "$status" | grep -q "^Up"; then
            RESTARTS=$(docker inspect --format='{{.RestartCount}}' "$name" 2>/dev/null || echo "0")
            if [[ $RESTARTS -gt 5 ]]; then
                warn "Container '${name}': ${status} (restarted ${RESTARTS} times)"
            else
                ok "Container '${name}': running"
            fi
        elif echo "$status" | grep -q "Restarting"; then
            fail "Container '${name}': RESTARTING - check logs: docker logs ${name}"
        elif echo "$status" | grep -q "Exited (0)"; then
            warn "Container '${name}': stopped (exited cleanly)"
        else
            fail "Container '${name}': ${status}"
        fi
    done
else
    warn "Docker not available on this host"
fi

if [[ "$QUICK" == "false" ]]; then
    section "Service Reachability"
    echo "  (Checking if services respond - use --quick to skip this)"

    # "Name|URL|Expected HTTP code" - tests that the service responds to
    # HTTP, not just that the container is running (checked above).
    SERVICES=(
        "Traefik dashboard|http://localhost:8080/ping|200"
        "Authelia|http://localhost:9091/api/health|200"
        "Nextcloud|http://localhost:8080|200"
        "Vaultwarden|http://localhost:8082|200"
        "Jellyfin|http://localhost:8096|200"
        "Pi-hole|http://localhost:8083/admin|200"
        "Homepage|http://localhost:3000|200"
        "Grafana|http://localhost:3001|200"
        "Uptime Kuma|http://localhost:3002|200"
    )

    for SERVICE in "${SERVICES[@]}"; do
        NAME=$(echo "$SERVICE" | cut -d'|' -f1)
        URL=$(echo "$SERVICE" | cut -d'|' -f2)
        EXPECTED=$(echo "$SERVICE" | cut -d'|' -f3)

        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$URL" 2>/dev/null || echo "000")

        if [[ "$HTTP_CODE" == "$EXPECTED" ]] || [[ "$HTTP_CODE" =~ ^(200|301|302|401|403)$ ]]; then
            ok "${NAME}: responding (HTTP ${HTTP_CODE})"
        elif [[ "$HTTP_CODE" == "000" ]]; then
            fail "${NAME}: NOT REACHABLE (timeout/connection refused)"
        else
            warn "${NAME}: HTTP ${HTTP_CODE} (expected ${EXPECTED})"
        fi
    done
fi

section "Recent Container Errors (last 50 lines each)"

if command -v docker &>/dev/null; then
    CONTAINERS_TO_CHECK=(
        "nextcloud"
        "nextcloud-db"
        "nextcloud-redis"
        "vaultwarden"
        "traefik"
        "authelia"
        "pihole"
        "homepage"
        "jellyfin"
    )
    for CONTAINER in "${CONTAINERS_TO_CHECK[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
            ERROR_COUNT=$(docker logs --tail=50 "$CONTAINER" 2>&1 | grep -ciE "error|fatal|critical|exception" || true)
            if [[ $ERROR_COUNT -gt 0 ]]; then
                warn "${CONTAINER}: ${ERROR_COUNT} error-level log entries in last 50 lines"
                echo "    -> Run: docker logs --tail=50 ${CONTAINER} | grep -i error"
            else
                ok "${CONTAINER}: No recent errors in logs"
            fi
        fi
    done
fi

echo ""
echo -e "${BOLD}Check complete.${NC}"
echo "For 24/7 monitoring: Grafana (monitor.example.com) + Uptime Kuma (status.example.com)"
echo ""
