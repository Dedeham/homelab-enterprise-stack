#!/bin/bash
# =============================================================================
# Database Backup Script — Dump Databases Before ZFS Snapshot
# =============================================================================
#
# Why do we need this when ZFS already takes snapshots?
# ──────────────────────────────────────────────────────
# ZFS snapshots freeze the filesystem at an exact moment in time.
# The problem: databases like MariaDB write data in pieces, and a snapshot
# might catch the database MID-WRITE — with half-written transactions.
# Restoring such a snapshot can result in a corrupt database.
#
# The correct approach is:
#   Step 1: Run this script → dumps all databases to SQL files (consistent state)
#   Step 2: TrueNAS automatic snapshot runs → snapshots the dump files too
#   Step 3: If you ever need to restore → restore the dump, not the live DB files
#
# This script handles the database dumps. ZFS snapshots handle the rest.
#
# What it backs up:
#   - Nextcloud's MariaDB database (all tables, users, settings)
#   - Vaultwarden's SQLite database (all passwords, TOTP keys, etc.)
#
# How it works:
#   - MariaDB: uses `docker exec` to run mysqldump INSIDE the container
#     (we don't expose port 3306 to the host — that would be a security risk)
#   - Vaultwarden: uses `docker exec` to run sqlite3 .backup for a consistent
#     copy, then copies the backup file out of the container's volume
#
# Where dumps go:
#   /mnt/main/backups/db/ — this path is on the ZFS "main" pool, so it's:
#   ✅ Protected by the ZFS mirror (real-time copy on 2nd drive)
#   ✅ Included in ZFS snapshots
#   ✅ Included in off-site backups via TrueNAS Cloud Sync
#
# Schedule: Run daily on the Docker VM, 30 minutes BEFORE the TrueNAS snapshot schedule.
#   E.g., if snapshots run at 02:00, run this at 01:30.
#   Set up as root's cron job on the Docker VM.
#
# HOW TO USE:
#   Manual run: bash /mnt/main/scripts/db-backup.sh
#   Docker VM cron: Add as root's cron job at 01:30 daily
#
# PREREQUISITES:
#   1. Create the secrets file:
#      echo 'DB_USER=nextcloud' > /root/.db-backup-secrets
#      echo 'DB_PASS=your_mariadb_password' >> /root/.db-backup-secrets
#      chmod 600 /root/.db-backup-secrets
#   2. The containers "nextcloud-db" and "vaultwarden" must be running
#
# =============================================================================

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
BACKUP_DIR="/mnt/main/backups/db"
RETENTION_DAYS=14           # Keep last 14 days of dumps (ZFS snapshots cover longer)
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="/var/log/db-backup.log"

# ── Load database credentials ─────────────────────────────────────────────────
# We still need credentials for the docker exec mysqldump command — the dump
# command runs inside the container but needs to authenticate to MariaDB.
# Store these in a secrets file with restricted permissions (chmod 600).
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

# Validate required variables are set
: "${DB_USER:?DB_USER not set in $SECRETS_FILE}"
: "${DB_PASS:?DB_PASS not set in $SECRETS_FILE}"

# ── Logging helper ─────────────────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

log "══════════════════════════════════════════"
log "Database backup started"
log "══════════════════════════════════════════"

# ── Create backup directory ────────────────────────────────────────────────────
mkdir -p "$BACKUP_DIR"

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 1: Nextcloud MariaDB Backup
# ══════════════════════════════════════════════════════════════════════════════
#
# Why `docker exec` instead of direct mysqldump?
# ──────────────────────────────────────────────
# The MariaDB container does NOT expose port 3306 to the host (by design —
# databases should never be accessible from outside Docker). So we can't run
# mysqldump directly from the host.
#
# Instead, we use `docker exec` to run mysqldump INSIDE the container where
# MariaDB IS accessible on localhost:3306. The dump output is piped back to
# the host via stdout, compressed with gzip, and saved to the backup directory.
#
# mysqldump options explained:
#   --single-transaction: Dumps InnoDB tables in a consistent state WITHOUT
#     locking (other services keep running during the dump — no downtime)
#   --quick: Dumps row by row instead of loading the whole table into RAM
#     (important for large databases like Nextcloud)
#   --lock-tables=false: Don't lock tables (single-transaction handles this)
#   --routines: Include stored procedures/functions
#   --events: Include scheduled events
#   | gzip: Compress output (SQL files can be very large uncompressed)
# ══════════════════════════════════════════════════════════════════════════════

NC_DB_NAME="nextcloud"
NC_OUTPUT_FILE="${BACKUP_DIR}/nextcloud_${TIMESTAMP}.sql.gz"

log "Dumping Nextcloud MariaDB → $(basename "$NC_OUTPUT_FILE")"

# Check that the nextcloud-db container is running
if ! docker ps --format '{{.Names}}' | grep -q '^nextcloud-db$'; then
    log "❌ ERROR: Container 'nextcloud-db' is not running. Skipping MariaDB backup."
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
        log "✅ Nextcloud MariaDB dump complete — size: $NC_SIZE"
        NC_BACKUP_OK=true
    else
        log "❌ ERROR: Failed to dump Nextcloud MariaDB"
        rm -f "$NC_OUTPUT_FILE"   # Remove incomplete dump
        NC_BACKUP_OK=false
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 2: Vaultwarden SQLite Backup
# ══════════════════════════════════════════════════════════════════════════════
#
# Why a special backup for SQLite?
# ────────────────────────────────
# Vaultwarden stores ALL your passwords in a SQLite database file (db.sqlite3).
# Simply copying this file while Vaultwarden is running risks getting a corrupt
# copy (if a write happens mid-copy).
#
# The safe way is to use SQLite's built-in `.backup` command, which creates a
# consistent snapshot of the database even while it's being written to.
#
# How it works:
#   1. `docker exec` runs sqlite3 INSIDE the Vaultwarden container
#   2. The `.backup` command creates a consistent copy at /data/db-backup.sqlite3
#   3. We copy that backup file out of the container's volume to our backup dir
#   4. The in-container backup file is left in place (overwritten next run)
#
# The Vaultwarden data volume is mounted at /mnt/main/appdata/vaultwarden/
# so we can access the backup file directly from the host after creating it.
# ══════════════════════════════════════════════════════════════════════════════

VW_OUTPUT_FILE="${BACKUP_DIR}/vaultwarden_${TIMESTAMP}.sqlite3"

log "Backing up Vaultwarden SQLite → $(basename "$VW_OUTPUT_FILE")"

# Check that the vaultwarden container is running
if ! docker ps --format '{{.Names}}' | grep -q '^vaultwarden$'; then
    log "❌ ERROR: Container 'vaultwarden' is not running. Skipping Vaultwarden backup."
    log "   Start it with: cd /opt/docker/vaultwarden && docker compose up -d"
    VW_BACKUP_OK=false
else
    # Step 1: Create a consistent backup inside the container
    if docker exec vaultwarden sqlite3 /data/db.sqlite3 ".backup '/data/db-backup.sqlite3'"; then
        # Step 2: Copy the backup from the mounted volume to the backup directory
        if cp /mnt/main/appdata/vaultwarden/db-backup.sqlite3 "$VW_OUTPUT_FILE"; then
            VW_SIZE=$(du -sh "$VW_OUTPUT_FILE" | cut -f1)
            log "✅ Vaultwarden SQLite backup complete — size: $VW_SIZE"
            VW_BACKUP_OK=true
        else
            log "❌ ERROR: Failed to copy Vaultwarden backup from appdata volume"
            log "   Check that /mnt/main/appdata/vaultwarden/ is the correct volume mount path"
            VW_BACKUP_OK=false
        fi
    else
        log "❌ ERROR: Failed to create Vaultwarden SQLite backup"
        log "   Check that sqlite3 is available in the Vaultwarden container"
        VW_BACKUP_OK=false
    fi
fi

# Add more databases here if you add more services with databases:
# Example for a PostgreSQL service:
# docker exec my-postgres-container pg_dump -U myuser mydb | gzip > "${BACKUP_DIR}/mydb_${TIMESTAMP}.sql.gz"

# ── Clean up old dumps ─────────────────────────────────────────────────────────
# We keep 14 days of dumps locally. Older ones are deleted.
# (ZFS snapshots and off-site backups provide longer history)
log "Cleaning up dumps older than ${RETENTION_DAYS} days..."
find "$BACKUP_DIR" -name "*.sql.gz" -mtime "+${RETENTION_DAYS}" -delete
find "$BACKUP_DIR" -name "*.sqlite3" -mtime "+${RETENTION_DAYS}" -delete
log "Cleanup complete"

# ── Verify the latest dumps are readable ──────────────────────────────────────
# A zero-byte or corrupt dump is worse than no dump at all — we'd think we're
# protected but actually have nothing. This quick check catches obvious failures.

# Verify Nextcloud dump
if [[ "${NC_BACKUP_OK:-false}" == "true" ]]; then
    DUMP_SIZE=$(stat -c%s "$NC_OUTPUT_FILE")
    if [[ $DUMP_SIZE -lt 1024 ]]; then   # Less than 1 KB is almost certainly wrong
        log "⚠️  WARNING: Nextcloud dump seems too small (${DUMP_SIZE} bytes). Check for errors."
    else
        log "✅ Nextcloud dump verified: $(basename "$NC_OUTPUT_FILE") (${DUMP_SIZE} bytes)"
    fi
fi

# Verify Vaultwarden dump
if [[ "${VW_BACKUP_OK:-false}" == "true" ]]; then
    VW_DUMP_SIZE=$(stat -c%s "$VW_OUTPUT_FILE")
    if [[ $VW_DUMP_SIZE -lt 1024 ]]; then
        log "⚠️  WARNING: Vaultwarden dump seems too small (${VW_DUMP_SIZE} bytes). Check for errors."
    else
        log "✅ Vaultwarden dump verified: $(basename "$VW_OUTPUT_FILE") (${VW_DUMP_SIZE} bytes)"
    fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
log ""
log "Backup summary:"
log "  Nextcloud MariaDB: ${NC_BACKUP_OK:-false}"
log "  Vaultwarden SQLite: ${VW_BACKUP_OK:-false}"
log ""
log "Database backup finished"
log "══════════════════════════════════════════"

# Exit with error if any backup failed (so cron reports the failure)
if [[ "${NC_BACKUP_OK:-false}" != "true" ]] || [[ "${VW_BACKUP_OK:-false}" != "true" ]]; then
    exit 1
fi
