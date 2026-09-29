#!/bin/bash
# =============================================================================
# Nextcloud Maintenance — occ Command Wrapper
# =============================================================================
#
# What is "occ"?
# ──────────────
# "occ" (ownCloud Console) is Nextcloud's built-in command-line tool.
# It lets you do things that aren't possible through the web UI, like:
# - Triggering a file system scan (after you add files directly to the server)
# - Enabling/disabling maintenance mode (required before updates)
# - Managing users from the terminal
# - Fixing common issues
#
# Why do you need this wrapper?
# Because Nextcloud runs INSIDE a Docker container, you can't just type "occ"
# in your terminal — you have to tell Docker to run it inside the container.
# This script does that for you so you don't have to remember the full command.
#
# The full raw command (what this script saves you from typing):
#   docker exec --user www-data nextcloud php occ <command>
#
# HOW TO USE:
#   bash nextcloud-occ.sh <occ-command>
#   bash nextcloud-occ.sh status
#   bash nextcloud-occ.sh files:scan --all
#   bash nextcloud-occ.sh maintenance:mode --on
#
# =============================================================================

set -euo pipefail

CONTAINER_NAME="nextcloud"

# Check that the container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "❌ ERROR: Container '${CONTAINER_NAME}' is not running."
    echo "   Start it with: docker compose up -d"
    exit 1
fi

# If no arguments given, show a help menu
if [[ $# -eq 0 ]]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║            Nextcloud occ — Quick Reference                  ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Usage: bash nextcloud-occ.sh <command>"
    echo ""
    echo "── COMMON COMMANDS ──────────────────────────────────────────────"
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
    echo "── EXAMPLE UPDATE WORKFLOW ──────────────────────────────────────"
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
