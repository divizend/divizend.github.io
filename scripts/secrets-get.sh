#!/bin/bash
# Get a secret value using SOPS extract

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGE_KEY_FILE="${SCRIPT_DIR}/../.age-key-local"
SECRETS_FILE="${SCRIPT_DIR}/../secrets.encrypted.yaml"
KEY="$1"

if [[ -z "$KEY" ]]; then
    echo "Usage: $0 <key>" >&2
    exit 1
fi

# Load age key from file or environment
if [[ -z "$SOPS_AGE_KEY" ]] && [[ -f "$AGE_KEY_FILE" ]]; then
    export SOPS_AGE_KEY=$(cat "$AGE_KEY_FILE")
fi

# Use extract with JSON path format
bash "${SCRIPT_DIR}/sops-wrapper.sh" -d --extract "[\"${KEY}\"]" "$SECRETS_FILE"

