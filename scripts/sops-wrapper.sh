#!/bin/bash
# Wrapper script for SOPS commands that automatically loads age key

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGE_KEY_FILE="${SCRIPT_DIR}/../.age-key-local"
SECRETS_FILE="${SCRIPT_DIR}/../secrets.encrypted.yaml"

# Load age key from file or environment
if [[ -z "$SOPS_AGE_KEY" ]] && [[ -f "$AGE_KEY_FILE" ]]; then
    export SOPS_AGE_KEY=$(cat "$AGE_KEY_FILE")
fi

# Execute SOPS command with remaining arguments
# Don't use exec to ensure proper output flushing
sops "$@" || exit $?

