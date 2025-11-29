#!/bin/bash
# Remove all lines containing SERVER_IP from ~/.ssh/known_hosts

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Source .env if it exists (silently handle if it doesn't)
[ -f .env ] && source .env

# Get SERVER_IP using common function
get_config_value SERVER_IP "Enter Server IP address" "SERVER_IP is required"

KNOWN_HOSTS_FILE="$HOME/.ssh/known_hosts"

if [[ ! -f "$KNOWN_HOSTS_FILE" ]]; then
    echo "Note: $KNOWN_HOSTS_FILE does not exist, nothing to remove"
    exit 0
fi

# Create backup
BACKUP_FILE=$(backup_file "$KNOWN_HOSTS_FILE")
if [[ -z "$BACKUP_FILE" ]]; then
    echo "Error: Failed to create backup" >&2
    exit 1
fi

# Count lines to remove before deletion
REMOVED=$(grep -c "${SERVER_IP}" "$KNOWN_HOSTS_FILE" 2>/dev/null | head -n1 | tr -d '\n' || echo "0")
REMOVED=${REMOVED:-0}

if [[ "$REMOVED" = "0" ]] || [[ "$REMOVED" -eq 0 ]] 2>/dev/null; then
    echo "No lines containing $SERVER_IP found in $KNOWN_HOSTS_FILE"
    # Remove backup since no changes were made
    rm -f "${KNOWN_HOSTS_FILE}.bak."*
    exit 0
fi

# Remove lines containing the IP address
sed -i.tmp "/${SERVER_IP}/d" "$KNOWN_HOSTS_FILE" 2>/dev/null || sed -i '' "/${SERVER_IP}/d" "$KNOWN_HOSTS_FILE" 2>/dev/null

# Remove temporary file if created
rm -f "${KNOWN_HOSTS_FILE}.tmp"

# Validate: check that no lines containing SERVER_IP remain
if grep -q "${SERVER_IP}" "$KNOWN_HOSTS_FILE" 2>/dev/null; then
    REMAINING=$(grep -c "${SERVER_IP}" "$KNOWN_HOSTS_FILE" 2>/dev/null | head -n1)
    echo "Warning: Validation failed - $REMAINING line(s) containing $SERVER_IP still remain"
    echo "Backup kept at: ${KNOWN_HOSTS_FILE}.bak.*"
    exit 1
else
    echo "Removed $REMOVED line(s) containing $SERVER_IP from $KNOWN_HOSTS_FILE"
    echo "Validation passed: no lines containing $SERVER_IP remain"
    # Remove backup since validation passed
    rm -f "${KNOWN_HOSTS_FILE}.bak."*
fi

