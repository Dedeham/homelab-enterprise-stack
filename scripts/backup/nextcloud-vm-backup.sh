#!/bin/bash
# Run on the dedicated Nextcloud VM after /mnt/nc-backups is mounted from
# TrueNAS. Creates a logical MariaDB dump and a tar archive of the local
# Nextcloud app/config directory (excluding user data).
#
# User files are protected separately by TrueNAS snapshots and off-site
# backup of the main/nextcloud dataset.

set -euo pipefail
umask 077

COMPOSE_DIR="/opt/docker/nextcloud"
APP_DIR="${COMPOSE_DIR}/html"
BACKUP_DIR="/mnt/nc-backups"
LOG_FILE="/var/log/nextcloud-vm-backup.log"
TIMESTAMP="$(date +%F_%H-%M-%S)"
ENV_FILE="${COMPOSE_DIR}/.env"
LOCK_FILE="/run/nextcloud-vm-backup.lock"

log() {
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "ERROR: Another Nextcloud backup is already running."
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    log "ERROR: ${ENV_FILE} does not exist."
    exit 1
fi

ENV_MODE="$(stat -c '%a' "$ENV_FILE")"
if (( (8#$ENV_MODE & 077) != 0 )); then
    log "ERROR: ${ENV_FILE} is readable by group or others. Run: chmod 600 ${ENV_FILE}"
    exit 1
fi

NEXTCLOUD_DB_PASSWORD="$(
    awk -F= '
        /^[[:space:]]*NEXTCLOUD_DB_PASSWORD[[:space:]]*=/ {
            sub(/^[^=]*=/, "", $0)
            gsub(/\r/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            gsub(/^"|"$/, "", $0)
            print
            exit
        }
    ' "$ENV_FILE"
)"

if [[ -z "${NEXTCLOUD_DB_PASSWORD:-}" ]]; then
    log "ERROR: NEXTCLOUD_DB_PASSWORD is missing from ${ENV_FILE}."
    exit 1
fi

mkdir -p "$BACKUP_DIR"

if ! findmnt --mountpoint "$BACKUP_DIR" >/dev/null 2>&1; then
    log "ERROR: ${BACKUP_DIR} is not a mounted filesystem. Refusing to write backups to the VM boot disk."
    exit 1
fi

chmod 700 "$BACKUP_DIR"

log "Dedicated Nextcloud backup started"

if ! docker ps --format '{{.Names}}' | grep -q '^nextcloud-db$'; then
    log "ERROR: Container 'nextcloud-db' is not running."
    exit 1
fi

DB_OUTPUT="${BACKUP_DIR}/nextcloud_${TIMESTAMP}.sql.gz"
APP_OUTPUT="${BACKUP_DIR}/nextcloud_app_${TIMESTAMP}.tar.gz"
DB_TMP="${DB_OUTPUT}.tmp"
APP_TMP="${APP_OUTPUT}.tmp"

cleanup() {
    rm -f "$DB_TMP" "$APP_TMP"
}
trap cleanup EXIT

log "Dumping MariaDB to $(basename "$DB_OUTPUT")"
docker exec -e MYSQL_PWD="$NEXTCLOUD_DB_PASSWORD" nextcloud-db mariadb-dump \
    -u nextcloud \
    --single-transaction \
    --quick \
    --lock-tables=false \
    nextcloud | gzip > "$DB_TMP"

gzip -t "$DB_TMP"
mv -f "$DB_TMP" "$DB_OUTPUT"
log "MariaDB dump verified"

if [[ ! -d "$APP_DIR" ]]; then
    log "ERROR: ${APP_DIR} does not exist."
    exit 1
fi

log "Archiving Nextcloud app/config directory to $(basename "$APP_OUTPUT")"
tar -C "$APP_DIR" --exclude="./data" -czf "$APP_TMP" .
gzip -t "$APP_TMP"
mv -f "$APP_TMP" "$APP_OUTPUT"
log "App/config archive verified"

find "$BACKUP_DIR" -maxdepth 1 -type f -name 'nextcloud_*.sql.gz' -mtime +14 -delete
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'nextcloud_app_*.tar.gz' -mtime +14 -delete

log "Dedicated Nextcloud backup finished"
