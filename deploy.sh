#!/bin/bash
set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Ensure SOPS and age are available
if ! command -v sops &> /dev/null; then
    echo -e "${RED}Error: SOPS is not installed${NC}" >&2
    echo -e "${YELLOW}Install with: brew install sops (macOS) or download from https://github.com/getsops/sops${NC}" >&2
    exit 1
fi

if ! command -v age-keygen &> /dev/null; then
    echo -e "${RED}Error: age-keygen is not installed${NC}" >&2
    echo -e "${YELLOW}Install with: brew install age (macOS) or download from https://github.com/FiloSottile/age${NC}" >&2
    exit 1
fi

# Check for or create local age keypair
LOCAL_AGE_KEY_FILE="${SCRIPT_DIR}/.age-key-local"
if [[ ! -f "$LOCAL_AGE_KEY_FILE" ]]; then
    echo -e "${BLUE}🔑 Generating local age keypair...${NC}"
    age-keygen -o "$LOCAL_AGE_KEY_FILE"
    echo -e "${GREEN}✓ Local age keypair created at ${LOCAL_AGE_KEY_FILE}${NC}"
    echo -e "${YELLOW}⚠ Keep this file secure and never commit it to git${NC}"
else
    echo -e "${GREEN}✓ Using existing local age keypair${NC}"
fi

# Extract public key from local key file
# The public key is in a comment line like: # public key: age1...
LOCAL_PUBLIC_KEY=$(grep "^# public key:" "$LOCAL_AGE_KEY_FILE" | cut -d' ' -f4)
if [[ -z "$LOCAL_PUBLIC_KEY" ]]; then
    echo -e "${RED}Error: Could not extract public key from ${LOCAL_AGE_KEY_FILE}${NC}" >&2
    exit 1
fi

# Set SOPS_AGE_KEY for local operations
export SOPS_AGE_KEY=$(cat "$LOCAL_AGE_KEY_FILE")

# Update .sops.yaml with local public key (add if not present)
if [[ -f "${SCRIPT_DIR}/.sops.yaml" ]]; then
    # Check if local public key is already in .sops.yaml
    if ! grep -q "$LOCAL_PUBLIC_KEY" "${SCRIPT_DIR}/.sops.yaml" 2>/dev/null; then
        echo -e "${BLUE}📝 Updating .sops.yaml with local public key...${NC}"
        bash "${SCRIPT_DIR}/scripts/secrets.sh" add-recipient "$LOCAL_PUBLIC_KEY"
    fi
else
    echo -e "${YELLOW}⚠ .sops.yaml not found, creating it...${NC}"
    cat > "${SCRIPT_DIR}/.sops.yaml" <<EOF
# SOPS configuration for encrypting secrets
# This file supports multiple recipients (local, server, GitHub Actions)
# Each recipient can decrypt the secrets using their private key

creation_rules:
  - path_regex: secrets\.encrypted\.yaml$
    age: >-
      ${LOCAL_PUBLIC_KEY}
    # Multiple age public keys (comma-separated):
    # 1. Local machine public key (for editing secrets locally)
    # 2. Server public key (for decrypting during setup.sh)
    # 3. GitHub Actions public key (for CI/CD)
    # Keys will be automatically added/updated by deploy.sh and setup.sh
EOF
fi

# Load secrets from encrypted file
load_secrets_from_sops

# Get GitHub Personal Access Token for triggering sync
get_config_value GITHUB_PAT "Enter GitHub Personal Access Token (with repo scope)" "GITHUB_PAT is required"

if ! git diff --quiet setup.sh; then
    echo "[INFO] Committing and pushing setup.sh..."
git add setup.sh
git commit -m "Update setup.sh"
git push
else
    echo "[INFO] setup.sh is unchanged, skipping git operations."
fi

echo "[DEPLOY] Running setup on server..."
# Get SERVER_IP using common function (will load from encrypted secrets if available)
get_config_value SERVER_IP "Enter Server IP address" "SERVER_IP is required"

# Get or generate server's public key and add it to .sops.yaml before re-encrypting
echo "[DEPLOY] Getting server's age public key..."
SERVER_AGE_KEY_FILE="/root/.age-key-server"
SERVER_PUBLIC_KEY=$(ssh root@${SERVER_IP} "if [ -f $SERVER_AGE_KEY_FILE ]; then grep '^# public key:' $SERVER_AGE_KEY_FILE | cut -d' ' -f4; else age-keygen -o $SERVER_AGE_KEY_FILE 2>&1 | grep '^Public key:' | cut -d' ' -f3; fi" 2>/dev/null || true)

if [[ -z "$SERVER_PUBLIC_KEY" ]]; then
    echo "[ERROR] Could not get server's public key" >&2
    exit 1
fi

# Add server public key to .sops.yaml if not present
if ! grep -q "$SERVER_PUBLIC_KEY" "${SCRIPT_DIR}/.sops.yaml" 2>/dev/null; then
    echo "[DEPLOY] Adding server public key to .sops.yaml..."
    bash "${SCRIPT_DIR}/scripts/secrets.sh" add-recipient "$SERVER_PUBLIC_KEY"
    
    # Re-encrypt secrets with server key included
    if [[ -f "${SCRIPT_DIR}/secrets.encrypted.yaml" ]]; then
        echo "[DEPLOY] Re-encrypting secrets with server key..."
        TEMP_SECRETS=$(mktemp)
        if sops -d "${SCRIPT_DIR}/secrets.encrypted.yaml" > "$TEMP_SECRETS" 2>/dev/null; then
            sops -e "$TEMP_SECRETS" > "${SCRIPT_DIR}/secrets.encrypted.yaml"
            rm -f "$TEMP_SECRETS"
            echo "[DEPLOY] ✓ Secrets re-encrypted with server key"
        else
            echo "[ERROR] Could not decrypt secrets for re-encryption" >&2
            rm -f "$TEMP_SECRETS"
            exit 1
        fi
    fi
fi

# Copy files to server
scp setup.sh root@${SERVER_IP}:/tmp/setup.sh.local > /dev/null
scp common.sh root@${SERVER_IP}:/tmp/common.sh > /dev/null
# Copy templates directory
scp -r templates root@${SERVER_IP}:/tmp/ > /dev/null
# Copy scripts directory (for secrets.ts)
scp -r scripts root@${SERVER_IP}:/tmp/ > /dev/null
# Copy encrypted secrets and SOPS config to server
scp secrets.encrypted.yaml root@${SERVER_IP}:/tmp/secrets.encrypted.yaml > /dev/null
scp .sops.yaml root@${SERVER_IP}:/tmp/.sops.yaml > /dev/null

# Load secrets again to pass to server (they're already loaded, but ensure they're available)
# The server will decrypt using its own key
SSH_CMD=""
[[ -n "$BASE_DOMAIN" ]] && SSH_CMD="${SSH_CMD}BASE_DOMAIN=$(printf %q "$BASE_DOMAIN") "
[[ -n "$S2_ACCESS_TOKEN" ]] && SSH_CMD="${SSH_CMD}S2_ACCESS_TOKEN=$(printf %q "$S2_ACCESS_TOKEN") "
[[ -n "$RESEND_API_KEY" ]] && SSH_CMD="${SSH_CMD}RESEND_API_KEY=$(printf %q "$RESEND_API_KEY") "
[[ -n "$RESEND_WEBHOOK_SECRET" ]] && SSH_CMD="${SSH_CMD}RESEND_WEBHOOK_SECRET=$(printf %q "$RESEND_WEBHOOK_SECRET") "
[[ -n "$TEST_SENDER" ]] && SSH_CMD="${SSH_CMD}TEST_SENDER=$(printf %q "$TEST_SENDER") "
[[ -n "$TOOLS_ROOT_GITHUB" ]] && SSH_CMD="${SSH_CMD}TOOLS_ROOT_GITHUB=$(printf %q "$TOOLS_ROOT_GITHUB") "
[[ -n "$S2_BASIN" ]] && SSH_CMD="${SSH_CMD}S2_BASIN=$(printf %q "$S2_BASIN") "
[[ -n "$GITHUB_PAT" ]] && SSH_CMD="${SSH_CMD}GITHUB_PAT=$(printf %q "$GITHUB_PAT") "

if ssh -t root@${SERVER_IP} "${SSH_CMD}bash /tmp/setup.sh.local; EXIT_CODE=\$?; rm -rf /tmp/setup.sh.local /tmp/common.sh /tmp/templates /tmp/scripts /tmp/secrets.encrypted.yaml /tmp/.sops.yaml; exit \$EXIT_CODE"; then
    echo "[INFO] Deployment complete."
    
    # Test sync script functionality
    echo "[TEST] Testing sync.ts script..."
    # Prepare environment variables for test
    TEST_ENV="BENTO_API_URL='http://localhost:4195'"
    TEST_ENV="${TEST_ENV} TOOLS_ROOT_GITHUB='${TOOLS_ROOT_GITHUB:-https://github.com/divizend/divizend.github.io/main/bentotools}'"
    [[ -n "$S2_BASIN" ]] && TEST_ENV="${TEST_ENV} S2_BASIN='${S2_BASIN}'"
    [[ -n "$BASE_DOMAIN" ]] && TEST_ENV="${TEST_ENV} BASE_DOMAIN='${BASE_DOMAIN}'"
    [[ -n "$S2_ACCESS_TOKEN" ]] && TEST_ENV="${TEST_ENV} S2_ACCESS_TOKEN='${S2_ACCESS_TOKEN}'"
    [[ -n "$RESEND_API_KEY" ]] && TEST_ENV="${TEST_ENV} RESEND_API_KEY='${RESEND_API_KEY}'"
    
    SYNC_OUTPUT=$(ssh root@${SERVER_IP} "cd /opt/bento-sync && ${TEST_ENV} bun sync.ts 2>&1")
    SYNC_EXIT=$?
    
    # Check for warnings in sync output
    if echo "$SYNC_OUTPUT" | grep -q "⚠\|warning\|Warning\|WARNING"; then
        echo "[ERROR] Sync script test failed with warnings:"
        echo "$SYNC_OUTPUT"
        exit 1
    fi
    
    if [ $SYNC_EXIT -ne 0 ]; then
        echo "[ERROR] Sync script test failed with exit code $SYNC_EXIT:"
        echo "$SYNC_OUTPUT"
        exit 1
    fi
    
    echo "[INFO] ✓ Sync script test passed."
else
    echo "[ERROR] Deployment failed. The setup script on the server terminated with an error."
    exit 1
fi
