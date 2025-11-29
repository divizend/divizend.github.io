#!/bin/bash
# Edit encrypted secrets as if they were a .env file

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
    echo -e "${YELLOW}Install with: brew install sops (macOS) or download from https://github.com/getsops/sops${NC}" >&2
    exit 1
fi

# Check for local age key
LOCAL_AGE_KEY="${SCRIPT_DIR}/.age-key-local"
if [[ ! -f "$LOCAL_AGE_KEY" ]]; then
    echo -e "${RED}Error: Local age key not found at ${LOCAL_AGE_KEY}${NC}" >&2
    echo -e "${YELLOW}Run ./deploy.sh first to generate the local keypair${NC}" >&2
    exit 1
fi

# Set SOPS_AGE_KEY from local key
export SOPS_AGE_KEY=$(cat "$LOCAL_AGE_KEY")
export SOPS_AGE_KEY_FILE=""

# Create temp file for editing
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

# Decrypt existing secrets or use example template
if [[ -f "secrets.encrypted.yaml" ]]; then
    echo -e "${BLUE}📝 Decrypting secrets.encrypted.yaml...${NC}"
    if ! sops -d "secrets.encrypted.yaml" > "$TEMP_FILE" 2>/dev/null; then
        echo -e "${RED}Error: Failed to decrypt secrets.encrypted.yaml${NC}" >&2
        exit 1
    fi
else
    echo -e "${BLUE}📝 Creating new secrets file from template...${NC}"
    cp "secrets.example.yaml" "$TEMP_FILE"
fi

# Convert YAML to .env-like format for easier editing
ENV_TEMP=$(mktemp)
trap "rm -f $TEMP_FILE $ENV_TEMP" EXIT

# Parse YAML and convert to KEY=value format
while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue
    
    # Match YAML key: "value" format
    if [[ "$line" =~ ^([^:]+):[[:space:]]*(.+)$ ]]; then
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        
        # Remove leading/trailing whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Remove quotes if present
        value=$(echo "$value" | sed 's/^"//;s/"$//' | sed "s/^'//;s/'$//")
        
        # Write as KEY=value
        echo "${key}=${value}" >> "$ENV_TEMP"
    fi
done < "$TEMP_FILE"

# Edit the .env-like file
echo -e "${BLUE}📝 Opening secrets in ${EDITOR:-nano}...${NC}"
echo -e "${YELLOW}Edit the values below, then save and exit:${NC}"
"${EDITOR:-nano}" "$ENV_TEMP"

# Convert back to YAML format
YAML_TEMP=$(mktemp)
trap "rm -f $TEMP_FILE $ENV_TEMP $YAML_TEMP" EXIT

echo "# Encrypted secrets - synced from .env" > "$YAML_TEMP"
echo "BENTO_API_URL: \"http://localhost:4195\"" >> "$YAML_TEMP"
echo "S2_BASIN: \"\"" >> "$YAML_TEMP"
echo "BASE_DOMAIN: \"\"" >> "$YAML_TEMP"
echo "S2_ACCESS_TOKEN: \"\"" >> "$YAML_TEMP"
echo "RESEND_API_KEY: \"\"" >> "$YAML_TEMP"

# Parse edited .env-like file and update YAML
while IFS='=' read -r key value || [[ -n "$key" ]]; do
    # Skip comments and empty lines
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue
    
    # Remove quotes from value if present
    value=$(echo "$value" | sed 's/^"//;s/"$//' | sed "s/^'//;s/'$//")
    
    # Update YAML based on key
    case "$key" in
        BENTO_API_URL|S2_BASIN|BASE_DOMAIN|S2_ACCESS_TOKEN|RESEND_API_KEY)
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s|^${key}:.*|${key}: \"${value}\"|" "$YAML_TEMP"
            else
                sed -i "s|^${key}:.*|${key}: \"${value}\"|" "$YAML_TEMP"
            fi
            ;;
    esac
done < "$ENV_TEMP"

# Encrypt the YAML file
echo -e "${BLUE}🔐 Encrypting secrets...${NC}"
if sops -e "$YAML_TEMP" > "secrets.encrypted.yaml"; then
    echo -e "${GREEN}✓ Secrets updated and encrypted successfully${NC}"
else
    echo -e "${RED}Error: Failed to encrypt secrets${NC}" >&2
    exit 1
fi

