#!/bin/bash
# Get a secret value using SOPS extract

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY="$1"

if [[ -z "$KEY" ]]; then
    echo "Usage: $0 <key>" >&2
    exit 1
fi

# Use the sops-wrapper which handles age key loading
bash "${SCRIPT_DIR}/sops-wrapper.sh" -d --extract "[\"${KEY}\"]" "${SCRIPT_DIR}/../secrets.encrypted.yaml"

