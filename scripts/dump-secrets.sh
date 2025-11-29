#!/bin/bash
# Dump all encrypted secrets to stdout

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Check prerequisites
if ! command -v sops &> /dev/null; then
    echo -e "${RED}Error: SOPS is not installed${NC}" >&2
    exit 1
fi

# Check for local age key
LOCAL_AGE_KEY="${SCRIPT_DIR}/.age-key-local"
if [[ ! -f "$LOCAL_AGE_KEY" ]]; then
    echo -e "${RED}Error: Local age key not found at ${LOCAL_AGE_KEY}${NC}" >&2
    exit 1
fi

# Set SOPS_AGE_KEY from local key
export SOPS_AGE_KEY=$(cat "$LOCAL_AGE_KEY")
export SOPS_AGE_KEY_FILE=""

# Decrypt and display secrets
if [[ -f "secrets.encrypted.yaml" ]]; then
    echo -e "${BLUE}📋 Decrypted secrets:${NC}\n"
    sops -d "secrets.encrypted.yaml" 2>/dev/null || {
        echo -e "${RED}Error: Failed to decrypt secrets.encrypted.yaml${NC}" >&2
        exit 1
    }
else
    echo -e "${YELLOW}⚠ secrets.encrypted.yaml not found${NC}" >&2
    exit 1
fi

