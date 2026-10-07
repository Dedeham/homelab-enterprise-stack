#!/bin/bash
# Wrapper for Nextcloud's occ CLI, which has to run inside the Docker
# container rather than directly on the host.
#
# Usage:
#   bash nextcloud-occ.sh <occ-command>
#   bash nextcloud-occ.sh status
#   bash nextcloud-occ.sh files:scan --all
#   bash nextcloud-occ.sh maintenance:mode --on

set -euo pipefail

CONTAINER_NAME="nextcloud"

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "ERROR: Container '${CONTAINER_NAME}' is not running."
    echo "   Start it with: docker compose up -d"
    exit 1
fi

if [[ $# -eq 0 ]]; then
    echo ""
    echo "Nextcloud occ - Quick Reference"
    echo ""
    echo "Usage: bash nextcloud-occ.sh <command>"
    echo ""
    echo "COMMON COMMANDS"
    echo ""
    echo "  STATUS & INFO"
    echo "    status                     Show Nextcloud version and status"
    echo "    app:list                   List all installed apps"
    echo "    config:list                Show all config values"
    echo ""
    echo "  MAINTENANCE (run before/after updates)"
    echo "    maintenance:mode --on      Enable maintenance mode (locks users out)"
    echo "                               Run BEFORE updating Nextcloud"
    echo "    maintenance:mode --off     Disable maintenance mode (lets users back in)"
    echo "                               Run AFTER update is complete"
    echo "    maintenance:repair         Fix common issues after an update"
    echo "    upgrade                    Run database migrations after image update"
    echo ""
    echo "  FILES (use when files are out of sync)"
    echo "    files:scan --all           Re-scan all user files"
    echo "                               Use after adding files directly to /mnt/main/nextcloud"
    echo "    files:cleanup              Remove orphaned file cache entries"
    echo ""
    echo "  USERS"
    echo "    user:list                  List all users"
    echo "    user:add <username>        Create a new user"
    echo "    user:resetpassword <user>  Reset a user's password"
    echo "    user:disable <user>        Disable a user account"
    echo ""
    echo "  DATABASE"
    echo "    db:add-missing-indices     Add missing DB indices (speeds things up)"
    echo "    db:convert-filecache-bigint  Fix large file count performance issues"
    echo ""
    echo "  BACKGROUND JOBS"
    echo "    background:cron            Switch cron mode (should be 'cron')"
    echo ""
    echo "EXAMPLE UPDATE WORKFLOW"
    echo ""
    echo "  1. bash nextcloud-occ.sh maintenance:mode --on"
    echo "  2. docker compose pull nextcloud        (download new image)"
    echo "  3. docker compose up -d nextcloud       (restart with new image)"
    echo "  4. bash nextcloud-occ.sh upgrade        (run DB migrations)"
    echo "  5. bash nextcloud-occ.sh maintenance:repair"
    echo "  6. bash nextcloud-occ.sh maintenance:mode --off"
    echo ""
    exit 0
fi

# Run the occ command inside the container as the www-data user
# www-data is the web server user that Nextcloud runs as — occ must run as this user
echo "Running: occ $*"
docker exec --user www-data "$CONTAINER_NAME" php occ "$@"
