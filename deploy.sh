#!/bin/bash
set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Ensure SOPS and age are available
if ! command -v sops &> /dev/null; then
    log_error "SOPS is not installed"
    log_warn "Install with: brew install sops (macOS) or download from https://github.com/getsops/sops"
    exit 1
fi

if ! command -v age-keygen &> /dev/null; then
    log_error "age-keygen is not installed"
    log_warn "Install with: brew install age (macOS) or download from https://github.com/FiloSottile/age"
    exit 1
fi

# Check for or create local age keypair
LOCAL_AGE_KEY_FILE="${SCRIPT_DIR}/.age-key-local"
ensure_age_keypair "$LOCAL_AGE_KEY_FILE" "local age keypair" || exit 1

# Extract public key from local key file
LOCAL_PUBLIC_KEY=$(extract_age_public_key "$LOCAL_AGE_KEY_FILE")
if [[ -z "$LOCAL_PUBLIC_KEY" ]]; then
    log_error "Could not extract public key from ${LOCAL_AGE_KEY_FILE}"
    exit 1
fi

# Set SOPS_AGE_KEY for local operations
ensure_sops_age_key "$LOCAL_AGE_KEY_FILE" || exit 1

# Ensure .sops.yaml exists and add local public key if not present
ensure_sops_config "$LOCAL_PUBLIC_KEY"
if ! grep -q "$LOCAL_PUBLIC_KEY" "${SCRIPT_DIR}/.sops.yaml" 2>/dev/null; then
    log_info "📝 Updating .sops.yaml with local public key..."
    add_sops_recipient "$LOCAL_PUBLIC_KEY"
fi

# Load secrets from encrypted file
load_secrets_from_sops

# Get GitHub Personal Access Token for triggering sync
get_config_value GITHUB_PAT "Enter GitHub Personal Access Token (with repo scope)" "GITHUB_PAT is required"

if ! git diff --quiet setup.sh; then
    log_info "Committing and pushing setup.sh..."
git add setup.sh
git commit -m "Update setup.sh"
git push
else
    log_debug "setup.sh is unchanged, skipping git operations."
fi

log_info "Running setup on server..."
# Get SERVER_IP using common function (will load from encrypted secrets if available)
get_config_value SERVER_IP "Enter Server IP address" "SERVER_IP is required"

# Remove server IP from known_hosts to ensure clean state (silently skip if not present)
KNOWN_HOSTS_FILE="$HOME/.ssh/known_hosts"
if [[ -f "$KNOWN_HOSTS_FILE" ]] && grep -q "${SERVER_IP}" "$KNOWN_HOSTS_FILE" 2>/dev/null; then
    log_debug "Removing ${SERVER_IP} from known_hosts for clean connection..."
    # Create backup before modifying
    BACKUP_FILE=$(backup_file "$KNOWN_HOSTS_FILE" 2>/dev/null || echo "")
    # Remove lines containing the IP address (works on both macOS and Linux)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "/${SERVER_IP}/d" "$KNOWN_HOSTS_FILE" 2>/dev/null || true
    else
        sed -i "/${SERVER_IP}/d" "$KNOWN_HOSTS_FILE" 2>/dev/null || true
    fi
    # Remove backup if validation passed (no lines containing SERVER_IP remain)
    if ! grep -q "${SERVER_IP}" "$KNOWN_HOSTS_FILE" 2>/dev/null; then
        [[ -n "$BACKUP_FILE" ]] && [[ -f "$BACKUP_FILE" ]] && rm -f "$BACKUP_FILE" 2>/dev/null || true
    fi
fi

# Get or generate server's age public key and add it to .sops.yaml before re-encrypting
log_info "Getting server's age public key..."
# Add server to known_hosts to avoid interactive prompt (will be added automatically by ssh-keyscan)
ssh-keyscan -H ${SERVER_IP} >> ~/.ssh/known_hosts 2>/dev/null || true
SERVER_AGE_KEY_FILE="/root/.age-key-server"

# Try to get or generate the server's age keypair
# First check if age is installed, if not install it
# Then check if key exists, if not generate it
SERVER_PUBLIC_KEY=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 root@${SERVER_IP} "
    # Install age if not available
    if ! command -v age-keygen &> /dev/null; then
        # Try to install age (Ubuntu/Debian)
        if command -v apt-get &> /dev/null; then
            apt-get update -qq > /dev/null 2>&1
            apt-get install -y age > /dev/null 2>&1
        # Try to install age (other systems - download binary)
        elif command -v curl &> /dev/null; then
            AGE_VERSION=\$(curl -s https://api.github.com/repos/FiloSottile/age/releases/latest | grep -o '\"tag_name\": \"[^\"]*' | cut -d'\"' -f4)
            if [ -n \"\$AGE_VERSION\" ]; then
                curl -L \"https://github.com/FiloSottile/age/releases/download/\${AGE_VERSION}/age-\${AGE_VERSION}-linux-amd64.tar.gz\" -o /tmp/age.tar.gz 2>/dev/null
                tar -xzf /tmp/age.tar.gz -C /tmp 2>/dev/null
                mv /tmp/age/age* /usr/local/bin/ 2>/dev/null || true
                rm -rf /tmp/age* 2>/dev/null
            fi
        fi
    fi
    
    # Generate keypair if it doesn't exist
    if [ ! -f $SERVER_AGE_KEY_FILE ]; then
        age-keygen -o $SERVER_AGE_KEY_FILE 2>&1
    fi
    
    # Extract public key
    if [ -f $SERVER_AGE_KEY_FILE ]; then
        grep '^# public key:' $SERVER_AGE_KEY_FILE | cut -d' ' -f4
    fi
" 2>&1)

# Check if we got a valid public key (starts with age1)
if [[ -z "$SERVER_PUBLIC_KEY" ]] || [[ ! "$SERVER_PUBLIC_KEY" =~ ^age1 ]]; then
    log_error "Could not get server's public key"
    log_error "SSH output: $SERVER_PUBLIC_KEY"
    exit 1
fi

# Add server public key to .sops.yaml if not present
if ! grep -q "$SERVER_PUBLIC_KEY" "${SCRIPT_DIR}/.sops.yaml" 2>/dev/null; then
    log_info "Adding server public key to .sops.yaml..."
    add_sops_recipient "$SERVER_PUBLIC_KEY"
    
    # Re-encrypt secrets with server key included
    if [[ -f "${SCRIPT_DIR}/secrets.encrypted.yaml" ]]; then
        log_info "Re-encrypting secrets with server key..."
        TEMP_SECRETS=$(mktemp)
        ensure_sops_age_key || exit 1
        if sops_cmd -d "${SCRIPT_DIR}/secrets.encrypted.yaml" > "$TEMP_SECRETS" 2>/dev/null; then
            sops_cmd -e "$TEMP_SECRETS" > "${SCRIPT_DIR}/secrets.encrypted.yaml"
            rm -f "$TEMP_SECRETS"
            log_info "✓ Secrets re-encrypted with server key"
        else
            log_error "Could not decrypt secrets for re-encryption"
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
    log_info "Deployment complete."
    
    # Test sync script functionality
    log_info "Testing sync.ts script..."
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
        log_error "Sync script test failed with warnings:"
        echo "$SYNC_OUTPUT"
        exit 1
    fi
    
    if [ $SYNC_EXIT -ne 0 ]; then
        log_error "Sync script test failed with exit code $SYNC_EXIT:"
        echo "$SYNC_OUTPUT"
        exit 1
    fi
    
    log_info "✓ Sync script test passed."
else
    log_error "Deployment failed. The setup script on the server terminated with an error."
    exit 1
fi
