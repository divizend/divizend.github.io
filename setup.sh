#!/bin/bash
set -e

# ==============================================================================
# Automated Message Stream Processor Setup
# Stack: Resend (Email) + S2 (Stream Store) + Bento (Processor)
# ==============================================================================

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Source common functions
# Handle both local execution and remote execution (when copied to /tmp)
if [[ -f "${BASH_SOURCE[0]%/*}/common.sh" ]]; then
    # Local execution: use script directory
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/common.sh"
elif [[ -f "/tmp/common.sh" ]]; then
    # Remote execution: use /tmp/common.sh
    SCRIPT_DIR="/tmp"
    source "/tmp/common.sh"
else
    log_error "common.sh not found"
    exit 1
fi

# Determine template directory
if [[ -d "${SCRIPT_DIR}/templates" ]]; then
    TEMPLATE_DIR="${SCRIPT_DIR}/templates"
elif [[ -d "/tmp/templates" ]]; then
    TEMPLATE_DIR="/tmp/templates"
else
    log_error "templates directory not found"
    exit 1
fi


log_info "Starting Stream Processor Setup..."

# 1. Pre-flight Checks
if [ "$EUID" -ne 0 ]; then
  log_error "Please run as root"
  exit 1
fi

# 2. Setup SOPS and Age Keypair (if on server)
log_info "Setting up encrypted secrets..."

# Check for or create server age keypair
SERVER_AGE_KEY_FILE="/root/.age-key-server"
if ! command -v age-keygen &> /dev/null; then
    log_info "Installing age..."
    # Install age (simple binary download)
    if [[ "$(uname -m)" == "x86_64" ]]; then
        # Try to get the actual download URL from GitHub API
        AGE_URL=$(curl -sf --max-time 10 https://api.github.com/repos/FiloSottile/age/releases/latest 2>/dev/null | grep -o 'https://[^"]*age[^"]*linux[^"]*amd64[^"]*\.tar\.gz' | head -n1)
        if [ -z "$AGE_URL" ]; then
            # Fallback to direct URL pattern
            AGE_URL="https://github.com/FiloSottile/age/releases/latest/download/age-v1.1.1-linux-amd64.tar.gz"
        fi
        
        AGE_TMP=$(mktemp)
        if curl -Lf --max-time 30 "$AGE_URL" -o "$AGE_TMP" 2>/dev/null && [ -s "$AGE_TMP" ]; then
            if tar -xzf "$AGE_TMP" 2>/dev/null; then
                mv age/age /usr/local/bin/age 2>/dev/null || true
                mv age/age-keygen /usr/local/bin/age-keygen 2>/dev/null || true
                rm -rf age "$AGE_TMP"
                log_info "✓ Age installed successfully"
            else
                log_error "Failed to extract age archive"
                rm -f "$AGE_TMP"
                exit 1
            fi
        else
            log_error "Failed to download age"
            rm -f "$AGE_TMP"
            exit 1
        fi
    else
        log_warn "⚠ Unsupported architecture, please install age manually"
        exit 1
    fi
fi

ensure_age_keypair "$SERVER_AGE_KEY_FILE" "server age keypair" || exit 1

# Extract server public key
SERVER_PUBLIC_KEY=$(extract_age_public_key "$SERVER_AGE_KEY_FILE")
if [[ -z "$SERVER_PUBLIC_KEY" ]]; then
    log_error "Could not extract public key from server keypair"
    exit 1
fi

# Set SOPS_AGE_KEY for server operations
ensure_sops_age_key "$SERVER_AGE_KEY_FILE" || exit 1

# Update .sops.yaml with server public key if copied from deploy.sh
if [[ -f "/tmp/.sops.yaml" ]]; then
    cp /tmp/.sops.yaml "${SCRIPT_DIR}/.sops.yaml" 2>/dev/null || true
    # Add server public key to .sops.yaml if not present
    if ! grep -q "$SERVER_PUBLIC_KEY" "${SCRIPT_DIR}/.sops.yaml" 2>/dev/null; then
        log_info "📝 Adding server public key to .sops.yaml..."
        add_sops_recipient "$SERVER_PUBLIC_KEY"
    fi
    # Copy secrets.encrypted.yaml (already re-encrypted on local machine with server key)
    if [[ -f "/tmp/secrets.encrypted.yaml" ]]; then
        # Determine target directory
        if [[ -d "/etc/bento" ]]; then
            TARGET_DIR="/etc/bento"
        else
            TARGET_DIR="${SCRIPT_DIR}"
        fi
        cp /tmp/secrets.encrypted.yaml "${TARGET_DIR}/secrets.encrypted.yaml" 2>/dev/null || {
            log_error "Could not copy secrets.encrypted.yaml to ${TARGET_DIR}"
            exit 1
        }
        log_info "✓ Secrets file copied to ${TARGET_DIR}/secrets.encrypted.yaml (already encrypted with server key)"
    fi
fi

# Load secrets from encrypted file (if available)
load_secrets_from_sops

# 3. Interactive Configuration
log_info "--- Configuration ---"

# Domain
get_config_value BASE_DOMAIN "Enter your Base Domain (e.g., mydomain.com)" "Domain is required."
STREAM_DOMAIN="streams.${BASE_DOMAIN}"
SERVER_IP=$(hostname -I | awk '{print $1}' || curl -s ifconfig.me || echo "")
log_info "Service will be deployed at: https://${STREAM_DOMAIN}"
log_info "DNS: Create an A record: ${STREAM_DOMAIN} -> ${SERVER_IP}"

# Wait for DNS record to be configured
wait_for_dns "${STREAM_DOMAIN}" "$SERVER_IP" || true

# S2 Configuration
get_config_value S2_ACCESS_TOKEN "Enter S2 Access Token" "S2 Token is required."

# Resend API Key
get_config_value RESEND_API_KEY "Enter Resend API Key (starts with re_)" "Resend API Key is required."

# Tools Root GitHub Configuration (with default)
get_config_value TOOLS_ROOT_GITHUB "Enter Tools Root GitHub URL (e.g., https://github.com/owner/repo/main/bentotools)" "Tools Root GitHub is required." "https://github.com/divizend/divizend.github.io/main/bentotools"

# GitHub Actions Secrets Setup Instructions
log_info ""
log_info "--- GitHub Actions Secrets Setup ---"
log_info "To enable GitHub Actions to sync Bento streams automatically:"
log_info "1. Add GitHub secret SOPS_AGE_KEY with the contents of .age-key-github (the private key)"
log_info "2. The public key has already been added to .sops.yaml"
log_info "3. Commit secrets.encrypted.yaml and .sops.yaml to the repo"
log_warn "4. Never commit .age-key-* files (they contain private keys)"
log_info ""
log_info "Note: All secrets are stored in secrets.encrypted.yaml (no .env file needed)."
log_info "Use npm run secrets edit to edit secrets, npm run secrets dump to view them, or npm run secrets set <key> <value> to set individual secrets."
log_info "Press Enter to continue..."
read -r < /dev/tty || true

# Webhook Setup Step
WEBHOOK_URL="https://${STREAM_DOMAIN}/webhooks/resend"

if [[ -z "$RESEND_WEBHOOK_SECRET" ]]; then
log_info ""
log_info "--- Action Required ---"
log_info "1. Go to your Resend Dashboard > Webhooks."
log_info "2. Create a new Webhook."
log_info "3. Set the Endpoint URL to: ${WEBHOOK_URL}"
    log_info "4. Select All Events"
log_info "5. Create the webhook and copy the Signing Secret (starts with whsec_)."
log_info "-----------------------"
    get_config_value RESEND_WEBHOOK_SECRET "Paste the Resend Webhook Secret here" "Webhook Secret is required."
fi

# 3. System Dependencies
log_info ""
log_info "Installing system dependencies..."
apt-get update -qq
apt-get dist-upgrade -qq
apt-get install -y -qq curl jq unzip git debian-keyring debian-archive-keyring apt-transport-https

# 4. Install Caddy (Web Server / HTTPS)
if ! command -v caddy &> /dev/null; then
    log_info "Installing Caddy..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    apt-get install -y -qq caddy
else
    log_debug "Caddy is already installed."
fi

# 5. Configure Caddy
log_info "Configuring Caddy for ${STREAM_DOMAIN}..."
EXPECTED_CADDYFILE="/tmp/caddyfile.expected"
# Use template file with variable substitution using sed
sed -e "s|\${STREAM_DOMAIN}|${STREAM_DOMAIN}|g" \
    "${TEMPLATE_DIR}/caddy/Caddyfile.template" > "$EXPECTED_CADDYFILE"

# Check if Caddyfile needs updating (idempotent)
CADDYFILE_CHANGED=false
if [ ! -f /etc/caddy/Caddyfile ] || ! diff -q /etc/caddy/Caddyfile "$EXPECTED_CADDYFILE" > /dev/null 2>&1; then
    cp "$EXPECTED_CADDYFILE" /etc/caddy/Caddyfile
    CADDYFILE_CHANGED=true
    log_info "Caddyfile updated."
else
    log_debug "Caddyfile is already configured correctly."
fi
rm -f "$EXPECTED_CADDYFILE"

# Enable Caddy service
systemctl daemon-reload
systemctl enable caddy > /dev/null 2>&1 || true

# Ensure Caddy is running
if [ "$CADDYFILE_CHANGED" = true ]; then
    if is_service_active caddy; then
        log_info "Reloading Caddy configuration..."
        systemctl reload caddy || {
            log_warn "Caddy reload failed, attempting restart..."
            systemctl restart caddy || log_warn "Note: Caddy restart had issues, but continuing..."
        }
    else
        # Check for port conflicts
        if is_port_listening 443 && ! is_service_active caddy; then
            log_warn "Port 443 is in use, checking for conflicting services..."
            for service in apache2 nginx httpd; do
                if is_service_active "$service"; then
                    log_warn "Stopping ${service} to free port 443..."
                    systemctl stop "$service"
                    systemctl disable "$service" > /dev/null 2>&1 || true
                fi
            done
            sleep 1
        fi
        ensure_service_running caddy 443 "Caddy" || {
            log_warn "Warning: Caddy failed to start. This may be due to port conflicts or configuration issues."
            log_warn "You can check the status with: systemctl status caddy"
        }
    fi
else
    if is_service_active caddy; then
        log_debug "Caddy is already running."
    else
        ensure_service_running caddy 443 "Caddy" || {
            log_warn "Warning: Caddy failed to start."
            log_warn "You can check the status with: systemctl status caddy"
        }
    fi
fi

# 6. Install Bento (Stream Processor)
if ! command -v bento &> /dev/null; then
    log_info "Installing Bento..."
    set +e  # Temporarily disable exit on error for installation attempts
    BENTO_TMP=$(mktemp)
    MAX_RETRIES=3
    RETRY_COUNT=0
    INSTALL_SUCCESS=false
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$INSTALL_SUCCESS" = false ]; do
        # Try to get the actual download URL from GitHub API
        BENTO_URL=$(curl -sf --max-time 10 https://api.github.com/repos/warpstreamlabs/bento/releases/latest 2>/dev/null | grep -o 'https://[^"]*bento[^"]*linux[^"]*amd64[^"]*\.tar\.gz' | head -n1)
        if [ -z "$BENTO_URL" ]; then
            # Fallback to direct URL
            BENTO_URL="https://github.com/warpstreamlabs/bento/releases/latest/download/bento-linux-amd64.tar.gz"
        fi
        CURL_OUTPUT=$(curl -Lf --max-time 30 -w "\n%{http_code}" "$BENTO_URL" -o "$BENTO_TMP" 2>&1)
        CURL_EXIT=$?
        HTTP_CODE=$(echo "$CURL_OUTPUT" | tail -n1)
        
        if [ $CURL_EXIT -eq 0 ] && [ "$HTTP_CODE" = "200" ] && [ -s "$BENTO_TMP" ]; then
            # Try to extract - tar.gz files can be extracted directly with tar
            if tar -xz -C /usr/bin -f "$BENTO_TMP" bento 2>/dev/null; then
                if [ -f /usr/bin/bento ]; then
                    chmod +x /usr/bin/bento
                    rm -f "$BENTO_TMP"
                    log_info "Bento installed successfully."
                    INSTALL_SUCCESS=true
                    break
                fi
            fi
            # If tar extraction failed, try gzip decompression first
            if gzip -t "$BENTO_TMP" 2>/dev/null; then
                gunzip -c "$BENTO_TMP" 2>/dev/null | tar -x -C /usr/bin bento 2>/dev/null
                if [ -f /usr/bin/bento ]; then
                    chmod +x /usr/bin/bento
                    rm -f "$BENTO_TMP"
                    log_info "Bento installed successfully."
                    INSTALL_SUCCESS=true
                    break
                fi
            fi
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            log_debug "Download failed (curl exit: $CURL_EXIT, HTTP: $HTTP_CODE), retrying ($RETRY_COUNT/$MAX_RETRIES)..."
            sleep 2
        fi
        rm -f "$BENTO_TMP"
    done
    
    rm -f "$BENTO_TMP"
    
    if [ "$INSTALL_SUCCESS" = false ] && ! command -v bento &> /dev/null; then
        log_info "Trying alternative installation method..."
        # Alternative: try downloading the binary directly if available
        if curl -Lf --max-time 30 https://github.com/warpstreamlabs/bento/releases/latest/download/bento-linux-amd64 -o /usr/bin/bento 2>/dev/null; then
    chmod +x /usr/bin/bento
            if command -v bento &> /dev/null; then
                log_info "Bento installed successfully via alternative method."
                INSTALL_SUCCESS=true
            fi
        fi
    fi
    
    set -e  # Re-enable exit on error
    
    if [ "$INSTALL_SUCCESS" = false ] && ! command -v bento &> /dev/null; then
        log_error "Failed to install Bento after all attempts"
        log_warn "Continuing anyway - Bento may need to be installed manually"
    fi
else
    log_debug "Bento is already installed."
fi

# 6.5. Install S2 CLI
log_info "Installing S2 CLI..."
if ! command -v s2 &> /dev/null; then
    # Use official install script (installs to ~/.s2/bin)
    log_info "Installing S2 CLI via official install script..."
    if curl -fsSL https://s2.dev/install.sh | bash >/dev/null 2>&1; then
        # Add ~/.s2/bin to PATH for current session
        export PATH="$HOME/.s2/bin:$PATH"
        # Also add to system PATH for future sessions
        if ! grep -q "~/.s2/bin" /etc/profile 2>/dev/null; then
            echo 'export PATH="$HOME/.s2/bin:$PATH"' >> /etc/profile
        fi
        if command -v s2 &> /dev/null || [ -f "$HOME/.s2/bin/s2" ]; then
            log_info "S2 CLI installed successfully."
            S2_CMD=$(command -v s2 2>/dev/null || echo "$HOME/.s2/bin/s2")
            # Configure S2 CLI with access token
            "$S2_CMD" config set --access-token "${S2_ACCESS_TOKEN}" 2>/dev/null || true
        else
            log_error "S2 CLI not found after installation"
            exit 1
        fi
    else
        log_error "S2 CLI installation failed"
        log_warn "Please install manually from: https://s2.dev/docs/quickstart"
        exit 1
    fi
else
    log_debug "S2 CLI is already installed."
    # Ensure access token is configured
    export PATH="$HOME/.s2/bin:$PATH"
    S2_CMD=$(command -v s2 2>/dev/null || echo "$HOME/.s2/bin/s2")
    "$S2_CMD" config set --access-token "${S2_ACCESS_TOKEN}" 2>/dev/null || true
fi

# 7. Configure Bento (Streams Mode)
log_info "Generating Bento Pipeline Configuration..."
mkdir -p /etc/bento/streams

# S2 Basin Configuration
# If S2_BASIN is not set, derive it from BASE_DOMAIN (replace dots with hyphens, lowercase)
# S2 basin names must be lowercase letters, numbers, and hyphens only
# For "divizend.ai", basin would be "divizend-ai"
if [[ -z "$S2_BASIN" ]]; then
    S2_BASIN=$(echo "${BASE_DOMAIN}" | tr '.' '-' | tr '[:upper:]' '[:lower:]')
    log_debug "Derived S2_BASIN from BASE_DOMAIN: ${S2_BASIN}"
else
    log_debug "Using S2_BASIN from environment: ${S2_BASIN}"
fi

# Copy and process template files with variable substitution
mkdir -p /etc/bento/streams

# Process Bento config files using sed to replace only specific variables
# This avoids issues with envsubst replacing bloblang $ variables
sed -e "s|\${S2_BASIN}|${S2_BASIN}|g" \
    -e "s|\${BASE_DOMAIN}|${BASE_DOMAIN}|g" \
    -e "s|\${S2_ACCESS_TOKEN}|${S2_ACCESS_TOKEN}|g" \
    -e "s|\${RESEND_API_KEY}|${RESEND_API_KEY}|g" \
    "${TEMPLATE_DIR}/bento/config.yaml" > /etc/bento/config.yaml

sed -e "s|\${S2_BASIN}|${S2_BASIN}|g" \
    -e "s|\${BASE_DOMAIN}|${BASE_DOMAIN}|g" \
    -e "s|\${S2_ACCESS_TOKEN}|${S2_ACCESS_TOKEN}|g" \
    -e "s|\${RESEND_API_KEY}|${RESEND_API_KEY}|g" \
    "${TEMPLATE_DIR}/bento/resources.yaml" > /etc/bento/resources.yaml

# Streams are now managed via Bento HTTP API from TOOLS_ROOT_GITHUB
# They will be synced automatically by the sync daemon

# 8. Systemd Service Setup
log_info "Configuring Systemd service..."
cp "${TEMPLATE_DIR}/systemd/bento.service" /etc/systemd/system/bento.service
sed -e "s|\${TOOLS_ROOT_GITHUB}|${TOOLS_ROOT_GITHUB}|g" \
    "${TEMPLATE_DIR}/systemd/bento-sync.service" > /etc/systemd/system/bento-sync.service
cp "${TEMPLATE_DIR}/systemd/bento-sync.timer" /etc/systemd/system/bento-sync.timer

# 9. Setup Bento Tools Sync Daemon
log_info "Setting up Bento Tools Sync Daemon..."

# Install bun if not present (required for TypeScript compilation)
if ! command -v bun &> /dev/null; then
    log_info "Installing bun..."
    curl -fsSL https://bun.sh/install | bash
    export PATH="$HOME/.bun/bin:$PATH"
    # Ensure bun is in system PATH for systemd
    if [ -f "$HOME/.bun/bin/bun" ] && [ ! -f /usr/local/bin/bun ]; then
        ln -sf "$HOME/.bun/bin/bun" /usr/local/bin/bun 2>/dev/null || cp "$HOME/.bun/bin/bun" /usr/local/bin/bun 2>/dev/null || true
    fi
    log_info "Bun installed."
else
    log_debug "Bun is already installed."
    # Ensure bun is accessible system-wide
    BUN_PATH=$(command -v bun)
    if [ -n "$BUN_PATH" ] && [ ! -f /usr/local/bin/bun ]; then
        ln -sf "$BUN_PATH" /usr/local/bin/bun 2>/dev/null || cp "$BUN_PATH" /usr/local/bin/bun 2>/dev/null || true
    fi
fi

# Clone or update bentotools directory from TOOLS_ROOT_GITHUB
# Parse TOOLS_ROOT_GITHUB to construct git clone URL
if [[ "$TOOLS_ROOT_GITHUB" =~ ^https://github\.com/([^/]+)/([^/]+)(/([^/]+))?(/(.*))?$ ]]; then
    OWNER="${BASH_REMATCH[1]}"
    REPO="${BASH_REMATCH[2]}"
    BRANCH="${BASH_REMATCH[4]}"
    PATH_PART="${BASH_REMATCH[6]}"
    
    # If branch not specified, get default branch from GitHub API
    if [ -z "$BRANCH" ]; then
        DEFAULT_BRANCH=$(curl -s "https://api.github.com/repos/${OWNER}/${REPO}" | grep -o '"default_branch":"[^"]*' | cut -d'"' -f4 || echo "main")
        BRANCH="$DEFAULT_BRANCH"
    fi
    
    # Construct git clone URL
    GIT_URL="https://github.com/${OWNER}/${REPO}.git"
    
    # Clone or update the repository
    if [ -d "/opt/bento-sync/.git" ]; then
        log_info "Updating bentotools directory..."
        cd /opt/bento-sync
        git fetch origin
        git checkout "${BRANCH}" 2>/dev/null || git checkout -b "${BRANCH}" "origin/${BRANCH}" 2>/dev/null || true
        git pull origin "${BRANCH}" || {
            log_warn "⚠ Could not pull latest changes, continuing with existing version"
        }
    else
        log_info "Cloning bentotools directory from ${GIT_URL} (branch: ${BRANCH})..."
        rm -rf /opt/bento-sync
        git clone -b "${BRANCH}" "${GIT_URL}" /opt/bento-sync || {
            log_error "Could not clone repository"
            exit 1
        }
        
        # If PATH_PART is specified, we need to work in a subdirectory
        # For now, we assume the entire repo is cloned and we work from the root
        # If PATH_PART is set, we'll need to adjust the working directory
        if [ -n "$PATH_PART" ]; then
            PATH_PART="${PATH_PART%/}"
            if [ -d "/opt/bento-sync/${PATH_PART}" ]; then
                # Move the subdirectory to be the root
                mv "/opt/bento-sync/${PATH_PART}" /opt/bento-sync-tmp
                rm -rf /opt/bento-sync
                mv /opt/bento-sync-tmp /opt/bento-sync
            fi
        fi
    fi
    
    cd /opt/bento-sync
    
    # Install bun dependencies
    log_info "Installing bun dependencies..."
    if [ -f "package.json" ]; then
        bun install || {
            log_warn "⚠ Could not install dependencies, continuing anyway"
        }
    else
        log_warn "⚠ No package.json found in bentotools directory"
    fi
else
    log_error "Invalid TOOLS_ROOT_GITHUB format"
    exit 1
fi

# Enable and start the sync timer
systemctl daemon-reload
systemctl enable bento-sync.timer > /dev/null 2>&1
systemctl start bento-sync.timer > /dev/null 2>&1

# Run initial sync
log_info "Running initial Bento tools sync..."
cd /opt/bento-sync
if ! BENTO_API_URL="http://localhost:4195" \
TOOLS_ROOT_GITHUB="${TOOLS_ROOT_GITHUB}" \
S2_BASIN="${S2_BASIN}" \
BASE_DOMAIN="${BASE_DOMAIN}" \
S2_ACCESS_TOKEN="${S2_ACCESS_TOKEN}" \
RESEND_API_KEY="${RESEND_API_KEY}" \
bun sync.ts; then
    log_error "Initial Bento tools sync failed"
    log_error "This is required for the system to function properly."
    log_warn "Check the error messages above and ensure:"
    log_warn "  - TOOLS_ROOT_GITHUB is correct and accessible"
    log_warn "  - Network connectivity is available"
    log_warn "  - All required environment variables are set"
    exit 1
fi

log_info "Bento Tools Sync Daemon configured."

# 10. Start Services
log_info "Starting Bento..."
# Stop the service if it's running to ensure clean start (don't kill, just stop gracefully)
systemctl stop bento 2>/dev/null || true
sleep 2
# Only kill processes if service stop didn't work and port is still in use
if lsof -ti:4195 > /dev/null 2>&1 && ! systemctl is-active --quiet bento 2>/dev/null; then
    log_warn "Killing stale process on port 4195..."
    lsof -ti:4195 | xargs kill -9 2>/dev/null || true
    sleep 2
fi
# Streams are now managed via Bento HTTP API from TOOLS_ROOT_GITHUB
# They will be synced automatically by the sync daemon
# No need to verify local stream files as they're managed via API

# Validate config if Bento supports it (with timeout to prevent hanging)
if command -v bento > /dev/null 2>&1; then
    set +e  # Temporarily disable exit on error for lint check
    if command -v timeout > /dev/null 2>&1; then
        LINT_OUTPUT=$(timeout 5 bento lint /etc/bento/config.yaml /etc/bento/resources.yaml 2>&1)
        LINT_EXIT=$?
    else
        LINT_OUTPUT=$(bento lint /etc/bento/config.yaml /etc/bento/resources.yaml 2>&1)
        LINT_EXIT=$?
    fi
    set -e  # Re-enable exit on error
    if [ $LINT_EXIT -ne 0 ] && [ -n "$LINT_OUTPUT" ]; then
        log_error "Bento config validation failed:"
        echo "$LINT_OUTPUT" | sed 's/^/  /'
        log_error "Please fix the configuration errors above before continuing."
        exit 1
    fi
fi
systemctl daemon-reload
systemctl enable bento
if systemctl is-active --quiet bento; then
systemctl restart bento
else
    systemctl start bento
fi

# Wait for Bento to start and verify it's running
log_info "Waiting for Bento to start..."
MAX_WAIT=10
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if systemctl is-active --quiet bento; then
        # Check if it's actually listening on the port
        if ss -tuln | grep -q ':4195 '; then
            log_info "Bento is running and listening on port 4195"
            
            # Trigger GitHub Actions sync by pushing to bentotools (if GITHUB_PAT is set)
            if [[ -n "$GITHUB_PAT" ]] && [[ -n "$TOOLS_ROOT_GITHUB" ]]; then
                # Parse TOOLS_ROOT_GITHUB to extract repo info
                if [[ "$TOOLS_ROOT_GITHUB" =~ ^https://github\.com/([^/]+)/([^/]+)(/([^/]+))?(/(.*))?$ ]]; then
                    OWNER="${BASH_REMATCH[1]}"
                    REPO="${BASH_REMATCH[2]}"
                    BRANCH="${BASH_REMATCH[4]}"
                    PATH_PART="${BASH_REMATCH[6]}"
                    
                    # Get default branch if not specified
                    if [ -z "$BRANCH" ]; then
                        DEFAULT_BRANCH=$(curl -s "https://api.github.com/repos/${OWNER}/${REPO}" | grep -o '"default_branch":"[^"]*' | cut -d'"' -f4 || echo "main")
                        BRANCH="$DEFAULT_BRANCH"
                    fi
                    
                    log_info "Triggering GitHub Actions sync by pushing to bentotools..."
                    
                    # Create a temporary file in bentotools to trigger the workflow
                    TEMP_FILE="/tmp/bento-sync-trigger-$(date +%s).txt"
                    echo "# Sync trigger $(date -Iseconds)" > "$TEMP_FILE"
                    
                    # Clone the repo, add the file, commit, and push
                    TEMP_REPO_DIR=$(mktemp -d)
                    if git clone "https://${GITHUB_PAT}@github.com/${OWNER}/${REPO}.git" -b "${BRANCH}" "$TEMP_REPO_DIR" 2>/dev/null; then
                        cd "$TEMP_REPO_DIR"
                        
                        # Determine the path to bentotools
                        if [ -n "$PATH_PART" ]; then
                            BENTOTOOLS_DIR="${PATH_PART%/}"
                        else
                            BENTOTOOLS_DIR="bentotools"
                        fi
                        
                        mkdir -p "$BENTOTOOLS_DIR"
                        cp "$TEMP_FILE" "${BENTOTOOLS_DIR}/.sync-trigger"
                        git add "${BENTOTOOLS_DIR}/.sync-trigger"
                        git -c user.name="Bento Sync" -c user.email="bento@divizend.com" commit -m "Trigger Bento sync [skip ci]" 2>/dev/null || true
                        git push "https://${GITHUB_PAT}@github.com/${OWNER}/${REPO}.git" "${BRANCH}" 2>/dev/null || {
                            log_warn "⚠ Could not push to trigger sync (this is non-fatal)"
                        }
                        
                        cd /
                        rm -rf "$TEMP_REPO_DIR"
                        rm -f "$TEMP_FILE"
                        log_info "✓ GitHub Actions sync triggered"
                    else
                        log_warn "⚠ Could not clone repo to trigger sync (this is non-fatal)"
                        rm -f "$TEMP_FILE"
                    fi
                fi
            fi
            
            break
        fi
    fi
    WAIT_COUNT=$((WAIT_COUNT + 1))
    sleep 1
done

# If Bento is not running, try to diagnose and fix
if ! systemctl is-active --quiet bento; then
    log_warn "Bento service is not active, checking status..."
    BENTO_STATUS=$(systemctl status bento --no-pager -l 2>&1 | head -n 20)
    echo "$BENTO_STATUS" | sed 's/^/  /'
    
    # Try to restart it
    log_info "Attempting to restart Bento..."
    systemctl reset-failed bento 2>/dev/null || true
    systemctl start bento
    sleep 3
    
    # Check again
    if ! systemctl is-active --quiet bento; then
        log_info "Checking Bento logs for errors..."
        BENTO_LOGS=$(journalctl -u bento -n 20 --no-pager 2>&1)
        echo "$BENTO_LOGS" | sed 's/^/  /'
        
        # Try running Bento manually to see the error
        log_info "Testing Bento configuration manually..."
        if command -v bento > /dev/null 2>&1; then
            set +e
            BENTO_TEST=$(timeout 5 /usr/bin/bento streams /etc/bento/config.yaml --dry-run 2>&1 || /usr/bin/bento streams /etc/bento/config.yaml 2>&1 | head -n 10)
            set -e
            if [ -n "$BENTO_TEST" ]; then
                echo "$BENTO_TEST" | sed 's/^/  /'
            fi
        fi
    fi
fi

# 10. Health Checks
log_info ""
log_info "Running health checks..."
HEALTH_FAILED=false
CADDY_FAILED=false
BENTO_FAILED=false

# Health checks
HEALTH_FAILED=false
CADDY_FAILED=false
BENTO_FAILED=false

if ! check_service_health caddy 443 "Caddy"; then
    HEALTH_FAILED=true
    CADDY_FAILED=true
fi

if ! check_service_health bento 4195 "Bento"; then
    HEALTH_FAILED=true
    BENTO_FAILED=true
fi

check_https_endpoint "https://${STREAM_DOMAIN}" "200,201,404" || true

# If Caddy failed, try to fix it
if [ "$CADDY_FAILED" = true ]; then
    log_info ""
    log_warn "Attempting to fix Caddy service..."
    systemctl reset-failed caddy 2>/dev/null || true
    systemctl stop caddy 2>/dev/null || true
    sleep 2
    
    # Check for port conflicts
    if is_port_listening 443 && ! is_service_active caddy; then
        log_warn "Port 443 is in use, checking for conflicting services..."
        for service in apache2 nginx httpd; do
            if is_service_active "$service"; then
                log_warn "Stopping ${service} to free port 443..."
                systemctl stop "$service"
                systemctl disable "$service" > /dev/null 2>&1 || true
            fi
        done
        sleep 1
    fi
    
    if ensure_service_running caddy 443 "Caddy"; then
        CADDY_FAILED=false
        HEALTH_FAILED=false
    else
        log_info "Showing Caddy service status:"
        systemctl status caddy --no-pager -l | head -n 30 | sed 's/^/  /'
        log_info "Showing recent Caddy logs:"
        journalctl -u caddy -n 30 --no-pager | sed 's/^/  /'
    fi
fi

# If Bento failed, try to fix it
if [ "$BENTO_FAILED" = true ]; then
    log_info ""
    log_warn "Attempting to fix Bento service..."
    systemctl reset-failed bento 2>/dev/null || true
    systemctl stop bento 2>/dev/null || true
    sleep 2
    
    if ensure_service_running bento 4195 "Bento"; then
        BENTO_FAILED=false
        HEALTH_FAILED=false
    else
        log_info "Showing Bento service status:"
        systemctl status bento --no-pager -l | head -n 30 | sed 's/^/  /'
        log_info "Showing recent Bento logs:"
        journalctl -u bento -n 30 --no-pager | sed 's/^/  /'
    fi
fi

if [ "$HEALTH_FAILED" = true ]; then
    log_info ""
    log_error "Some health checks failed. Debugging commands:"
    if [ "$CADDY_FAILED" = true ]; then
        log_info "  systemctl status caddy"
        log_info "  journalctl -u caddy -n 20"
    fi
    if [ "$BENTO_FAILED" = true ]; then
        log_info "  systemctl status bento"
        log_info "  journalctl -u bento -n 20"
    fi
    exit 1
fi

# Show success message only at the very end if everything passed
if [ "$SETUP_SUCCESS" = true ] && [ "$HEALTH_FAILED" != true ]; then
log_info ""
log_info "=============================================="
log_info "       Setup Complete Successfully!           "
log_info "=============================================="
log_info "1. HTTPS is active at: https://${STREAM_DOMAIN}"
log_info "2. Webhook endpoint:   https://${STREAM_DOMAIN}/webhooks/resend"
log_info "3. Logic:              Email -> Webhook -> S2 -> Reverse -> Resend"
fi
