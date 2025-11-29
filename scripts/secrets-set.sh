#!/bin/bash
# Set a secret value using SOPS set

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGE_KEY_FILE="${SCRIPT_DIR}/../.age-key-local"
SECRETS_FILE="${SCRIPT_DIR}/../secrets.encrypted.yaml"
KEY="$1"
VALUE="$2"

if [[ -z "$KEY" ]] || [[ -z "$VALUE" ]]; then
    echo "Usage: $0 <key> <value>" >&2
    exit 1
fi

# Load age key from file or environment
if [[ -z "$SOPS_AGE_KEY" ]] && [[ -f "$AGE_KEY_FILE" ]]; then
    export SOPS_AGE_KEY=$(cat "$AGE_KEY_FILE")
fi

# Use set with JSON path format and JSON-encoded value
bash "${SCRIPT_DIR}/sops-wrapper.sh" set "$SECRETS_FILE" "[\"${KEY}\"]" "\"${VALUE}\""
echo "✓ Set ${KEY}"

