#!/bin/bash
# Dumps application databases to consistent SQL/SQLite files before the ZFS
# snapshot runs, since a snapshot can catch a database mid-write and corrupt it.
#
# Backs up: Nextcloud's MariaDB database, Vaultwarden's SQLite database.
# Run daily via cron, 30 minutes before the TrueNAS snapshot schedule.
#
# Requires /root/.db-backup-secrets (chmod 600) with DB_USER and DB_PASS set.

set -euo pipefail

BACKUP_DIR="/mnt/main/backups/db"
RETENTION_DAYS=14
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="/var/log/db-backup.log"

SECRETS_FILE="/root/.db-backup-secrets"
if [[ -f "$SECRETS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$SECRETS_FILE"
else
    echo "[ERROR] Secrets file not found: $SECRETS_FILE"
    echo "Create it with:"
    echo "  echo 'DB_USER=nextcloud' > /root/.db-backup-secrets"
    echo "  echo 'DB_PASS=your_mariadb_password' >> /root/.db-backup-secrets"
    echo "  chmod 600 /root/.db-backup-secrets"
    exit 1
fi

: "${DB_USER:?DB_USER not set in $SECRETS_FILE}"
: "${DB_PASS:?DB_PASS not set in $SECRETS_FILE}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

log "Database backup started"

mkdir -p "$BACKUP_DIR"

# Nextcloud MariaDB. The container doesn't expose 3306 to the host, so the
# dump has to run via `docker exec` instead of a direct mysqldump.
NC_DB_NAME="nextcloud"
NC_OUTPUT_FILE="${BACKUP_DIR}/nextcloud_${TIMESTAMP}.sql.gz"

log "Dumping Nextcloud MariaDB -> $(basename "$NC_OUTPUT_FILE")"

if ! docker ps --format '{{.Names}}' | grep -q '^nextcloud-db$'; then
    log "ERROR: Container 'nextcloud-db' is not running. Skipping MariaDB backup."
    log "   Start it with: cd /opt/docker/nextcloud && docker compose up -d"
    NC_BACKUP_OK=false
else
    if docker exec nextcloud-db mysqldump \
        --user="$DB_USER" \
        --password="$DB_PASS" \
        --single-transaction \
        --quick \
        --lock-tables=false \
        --routines \
        --events \
        "$NC_DB_NAME" | gzip > "$NC_OUTPUT_FILE"; then

        NC_SIZE=$(du -sh "$NC_OUTPUT_FILE" | cut -f1)
        log "Nextcloud MariaDB dump complete - size: $NC_SIZE"
        NC_BACKUP_OK=true
    else
        log "ERROR: Failed to dump Nextcloud MariaDB"
        rm -f "$NC_OUTPUT_FILE"
        NC_BACKUP_OK=false
    fi
fi

# Vaultwarden SQLite. Use the built-in `.backup` command for a consistent
# copy instead of copying db.sqlite3 directly while it may be mid-write.
VW_OUTPUT_FILE="${BACKUP_DIR}/vaultwarden_${TIMESTAMP}.sqlite3"

log "Backing up Vaultwarden SQLite -> $(basename "$VW_OUTPUT_FILE")"

if ! docker ps --format '{{.Names}}' | grep -q '^vaultwarden$'; then
    log "ERROR: Container 'vaultwarden' is not running. Skipping Vaultwarden backup."
    log "   Start it with: cd /opt/docker/vaultwarden && docker compose up -d"
    VW_BACKUP_OK=false
else
    if docker exec vaultwarden sqlite3 /data/db.sqlite3 ".backup '/data/db-backup.sqlite3'"; then
        if cp /mnt/main/appdata/vaultwarden/db-backup.sqlite3 "$VW_OUTPUT_FILE"; then
            VW_SIZE=$(du -sh "$VW_OUTPUT_FILE" | cut -f1)
            log "Vaultwarden SQLite backup complete - size: $VW_SIZE"
            VW_BACKUP_OK=true
        else
            log "ERROR: Failed to copy Vaultwarden backup from appdata volume"
            VW_BACKUP_OK=false
        fi
    else
        log "ERROR: Failed to create Vaultwarden SQLite backup"
        VW_BACKUP_OK=false
    fi
fi

# Add more databases here if you add more services with databases:
# docker exec my-postgres-container pg_dump -U myuser mydb | gzip > "${BACKUP_DIR}/mydb_${TIMESTAMP}.sql.gz"

log "Cleaning up dumps older than ${RETENTION_DAYS} days..."
find "$BACKUP_DIR" -name "*.sql.gz" -mtime "+${RETENTION_DAYS}" -delete
find "$BACKUP_DIR" -name "*.sqlite3" -mtime "+${RETENTION_DAYS}" -delete

# A zero-byte or corrupt dump is worse than no dump — catch obvious failures.
if [[ "${NC_BACKUP_OK:-false}" == "true" ]]; then
    DUMP_SIZE=$(stat -c%s "$NC_OUTPUT_FILE")
    if [[ $DUMP_SIZE -lt 1024 ]]; then
        log "WARNING: Nextcloud dump seems too small (${DUMP_SIZE} bytes). Check for errors."
    else
        log "Nextcloud dump verified: $(basename "$NC_OUTPUT_FILE") (${DUMP_SIZE} bytes)"
    fi
fi

if [[ "${VW_BACKUP_OK:-false}" == "true" ]]; then
    VW_DUMP_SIZE=$(stat -c%s "$VW_OUTPUT_FILE")
    if [[ $VW_DUMP_SIZE -lt 1024 ]]; then
        log "WARNING: Vaultwarden dump seems too small (${VW_DUMP_SIZE} bytes). Check for errors."
    else
        log "Vaultwarden dump verified: $(basename "$VW_OUTPUT_FILE") (${VW_DUMP_SIZE} bytes)"
    fi
fi

log "Nextcloud MariaDB: ${NC_BACKUP_OK:-false}"
log "Vaultwarden SQLite: ${VW_BACKUP_OK:-false}"
log "Database backup finished"

if [[ "${NC_BACKUP_OK:-false}" != "true" ]] || [[ "${VW_BACKUP_OK:-false}" != "true" ]]; then
    exit 1
fi
