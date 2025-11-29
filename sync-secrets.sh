#!/bin/bash
# Sync .env file to SOPS encrypted secrets
# This script ensures secrets.encrypted.yaml matches .env

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
SECRETS_ENCRYPTED="${SCRIPT_DIR}/secrets.encrypted.yaml"
SOPS_CONFIG="${SCRIPT_DIR}/.sops.yaml"
SECRETS_TEMP=$(mktemp)

echo -e "${BLUE}🔄 Syncing .env to SOPS encrypted secrets...${NC}"

# Check prerequisites
if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "${RED}❌ Error: .env file not found at ${ENV_FILE}${NC}" >&2
    exit 1
fi

if ! command -v sops &> /dev/null; then
    echo -e "${RED}❌ Error: SOPS is not installed${NC}" >&2
    echo -e "${YELLOW}Install with: brew install sops (macOS) or download from https://github.com/getsops/sops${NC}" >&2
    exit 1
fi

if [[ ! -f "$SOPS_CONFIG" ]]; then
    echo -e "${RED}❌ Error: .sops.yaml not found at ${SOPS_CONFIG}${NC}" >&2
    echo -e "${YELLOW}Run setup.sh first to configure SOPS${NC}" >&2
    exit 1
fi

# Check if SOPS_AGE_KEY_FILE or SOPS_AGE_KEY is set
if [[ -z "$SOPS_AGE_KEY_FILE" ]] && [[ -z "$SOPS_AGE_KEY" ]]; then
    echo -e "${RED}❌ Error: SOPS_AGE_KEY or SOPS_AGE_KEY_FILE must be set${NC}" >&2
    echo -e "${YELLOW}Set SOPS_AGE_KEY environment variable with your age private key${NC}" >&2
    exit 1
fi

# Set up age key file if SOPS_AGE_KEY is provided
TEMP_KEY_FILE=""
if [[ -n "$SOPS_AGE_KEY" ]] && [[ -z "$SOPS_AGE_KEY_FILE" ]]; then
    TEMP_KEY_FILE=$(mktemp)
    echo "$SOPS_AGE_KEY" > "$TEMP_KEY_FILE"
    export SOPS_AGE_KEY_FILE="$TEMP_KEY_FILE"
    echo -e "${BLUE}📝 Using SOPS_AGE_KEY from environment${NC}"
fi

# If secrets.encrypted.yaml doesn't exist, create it from .env
if [[ ! -f "$SECRETS_ENCRYPTED" ]]; then
    echo -e "${BLUE}📝 Creating secrets.encrypted.yaml from .env...${NC}"
    
    # Create a temporary YAML file from .env
    cat > "$SECRETS_TEMP" << 'EOF'
# Encrypted secrets - synced from .env
BENTO_API_URL: "http://localhost:4195"
S2_BASIN: ""
BASE_DOMAIN: ""
S2_ACCESS_TOKEN: ""
RESEND_API_KEY: ""
EOF
    
    # Read .env and update the YAML
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        
        # Handle quoted values (single or double quotes)
        # Remove quotes from value if present
        value=$(echo "$value" | sed "s/^['\"]//;s/['\"]\$//")
        
        # Update the YAML file based on key
        case "$key" in
            BENTO_API_URL|S2_BASIN|BASE_DOMAIN|S2_ACCESS_TOKEN|RESEND_API_KEY)
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    sed -i '' "s|^${key}:.*|${key}: \"${value}\"|" "$SECRETS_TEMP"
                else
                    sed -i "s|^${key}:.*|${key}: \"${value}\"|" "$SECRETS_TEMP"
                fi
                ;;
        esac
    done < "$ENV_FILE"
    
    # Encrypt the YAML file
    if sops -e "$SECRETS_TEMP" > "$SECRETS_ENCRYPTED"; then
        echo -e "${GREEN}✓ Created secrets.encrypted.yaml${NC}"
    else
        echo -e "${RED}❌ Failed to encrypt secrets${NC}" >&2
        rm -f "$SECRETS_TEMP" "$TEMP_KEY_FILE"
        exit 1
    fi
    rm -f "$SECRETS_TEMP"
else
    # Update existing encrypted file
    echo -e "${BLUE}📝 Updating secrets.encrypted.yaml from .env...${NC}"
    
    # Read .env and update each secret
    UPDATED_COUNT=0
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        
        # Handle quoted values (single or double quotes)
        # Remove quotes from value if present
        value=$(echo "$value" | sed "s/^['\"]//;s/['\"]\$//")
        
        # Only update known secret keys
        case "$key" in
            BENTO_API_URL|S2_BASIN|BASE_DOMAIN|S2_ACCESS_TOKEN|RESEND_API_KEY)
                if sops --set "[\"${key}\"] \"${value}\"" "$SECRETS_ENCRYPTED" > /dev/null 2>&1; then
                    echo -e "${GREEN}  ✓ Updated ${key}${NC}"
                    UPDATED_COUNT=$((UPDATED_COUNT + 1))
                else
                    echo -e "${YELLOW}  ⚠ Failed to update ${key}${NC}" >&2
                fi
                ;;
        esac
    done < "$ENV_FILE"
    
    if [[ $UPDATED_COUNT -gt 0 ]]; then
        echo -e "${GREEN}✓ Updated ${UPDATED_COUNT} secret(s) in secrets.encrypted.yaml${NC}"
    else
        echo -e "${YELLOW}⚠ No secrets were updated${NC}"
    fi
fi

# Clean up temp key file
if [[ -n "$TEMP_KEY_FILE" ]] && [[ -f "$TEMP_KEY_FILE" ]]; then
    rm -f "$TEMP_KEY_FILE"
fi

echo -e "${GREEN}✅ Secrets sync completed${NC}"

