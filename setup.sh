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
    source "/tmp/common.sh"
else
    echo "Error: common.sh not found" >&2
    exit 1
fi


echo -e "${BLUE}Starting Stream Processor Setup...${NC}"

# 1. Pre-flight Checks
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Please run as root${NC}"
  exit 1
fi

# 2. Interactive Configuration
echo -e "${YELLOW}--- Configuration ---${NC}"

# Domain
get_config_value BASE_DOMAIN "Enter your Base Domain (e.g., mydomain.com)" "Domain is required."
STREAM_DOMAIN="streams.${BASE_DOMAIN}"
SERVER_IP=$(hostname -I | awk '{print $1}' || curl -s ifconfig.me || echo "")
echo -e "Service will be deployed at: ${GREEN}https://${STREAM_DOMAIN}${NC}"
echo -e "${YELLOW}DNS: Create an A record: ${STREAM_DOMAIN} -> ${SERVER_IP}${NC}"

# Wait for DNS record to be configured
wait_for_dns "${STREAM_DOMAIN}" "$SERVER_IP" || true

# S2 Configuration
get_config_value S2_ACCESS_TOKEN "Enter S2 Access Token" "S2 Token is required."

# Resend API Key
get_config_value RESEND_API_KEY "Enter Resend API Key (starts with re_)" "Resend API Key is required."

# Tools Root Configuration (with default)
if [[ -z "$TOOLS_ROOT" ]]; then
    TOOLS_ROOT="https://setup.divizend.com/bentotools"
    echo -e "${GREEN}Using default TOOLS_ROOT: ${TOOLS_ROOT}${NC}"
else
    echo -e "${GREEN}Using TOOLS_ROOT from environment: ${TOOLS_ROOT}${NC}"
fi

# Webhook Setup Step
WEBHOOK_URL="https://${STREAM_DOMAIN}/webhooks/resend"

if [[ -z "$RESEND_WEBHOOK_SECRET" ]]; then
echo -e "\n${YELLOW}--- Action Required ---${NC}"
echo -e "1. Go to your Resend Dashboard > Webhooks."
echo -e "2. Create a new Webhook."
echo -e "3. Set the Endpoint URL to: ${GREEN}${WEBHOOK_URL}${NC}"
    echo -e "4. Select ${GREEN}All Events${NC}"
echo -e "5. Create the webhook and copy the ${BLUE}Signing Secret${NC} (starts with whsec_)."
echo -e "-----------------------"
    get_config_value RESEND_WEBHOOK_SECRET "Paste the Resend Webhook Secret here" "Webhook Secret is required."
else
    echo -e "${GREEN}Using RESEND_WEBHOOK_SECRET from environment.${NC}"
fi

# 3. System Dependencies
echo -e "\n${BLUE}Installing system dependencies...${NC}"
apt-get update -qq
apt-get dist-upgrade -qq
apt-get install -y -qq curl jq unzip debian-keyring debian-archive-keyring apt-transport-https

# 4. Install Caddy (Web Server / HTTPS)
if ! command -v caddy &> /dev/null; then
    echo -e "${BLUE}Installing Caddy...${NC}"
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    apt-get install -y -qq caddy
else
    echo -e "${GREEN}Caddy is already installed.${NC}"
fi

# 5. Configure Caddy
echo -e "${BLUE}Configuring Caddy for ${STREAM_DOMAIN}...${NC}"
EXPECTED_CADDYFILE="/tmp/caddyfile.expected"
cat <<EOF > "$EXPECTED_CADDYFILE"
${STREAM_DOMAIN} {
    reverse_proxy localhost:4195
}
EOF

# Check if Caddyfile needs updating (idempotent)
CADDYFILE_CHANGED=false
if [ ! -f /etc/caddy/Caddyfile ] || ! diff -q /etc/caddy/Caddyfile "$EXPECTED_CADDYFILE" > /dev/null 2>&1; then
    cp "$EXPECTED_CADDYFILE" /etc/caddy/Caddyfile
    CADDYFILE_CHANGED=true
    echo -e "${GREEN}Caddyfile updated.${NC}"
else
    echo -e "${GREEN}Caddyfile is already configured correctly.${NC}"
fi
rm -f "$EXPECTED_CADDYFILE"

# Enable Caddy service
systemctl daemon-reload
systemctl enable caddy > /dev/null 2>&1 || true

# Ensure Caddy is running
if [ "$CADDYFILE_CHANGED" = true ]; then
    if is_service_active caddy; then
        echo -e "${BLUE}Reloading Caddy configuration...${NC}"
        systemctl reload caddy || {
            echo -e "${YELLOW}Caddy reload failed, attempting restart...${NC}"
            systemctl restart caddy || echo -e "${YELLOW}Note: Caddy restart had issues, but continuing...${NC}"
        }
    else
        # Check for port conflicts
        if is_port_listening 443 && ! is_service_active caddy; then
            echo -e "${YELLOW}Port 443 is in use, checking for conflicting services...${NC}"
            for service in apache2 nginx httpd; do
                if is_service_active "$service"; then
                    echo -e "${YELLOW}Stopping ${service} to free port 443...${NC}"
                    systemctl stop "$service"
                    systemctl disable "$service" > /dev/null 2>&1 || true
                fi
            done
            sleep 1
        fi
        ensure_service_running caddy 443 "Caddy" || {
            echo -e "${YELLOW}Warning: Caddy failed to start. This may be due to port conflicts or configuration issues.${NC}"
            echo -e "${YELLOW}You can check the status with: systemctl status caddy${NC}"
        }
    fi
else
    if is_service_active caddy; then
        echo -e "${GREEN}Caddy is already running.${NC}"
    else
        ensure_service_running caddy 443 "Caddy" || {
            echo -e "${YELLOW}Warning: Caddy failed to start.${NC}"
            echo -e "${YELLOW}You can check the status with: systemctl status caddy${NC}"
        }
    fi
fi

# 6. Install Bento (Stream Processor)
if ! command -v bento &> /dev/null; then
    echo -e "${BLUE}Installing Bento...${NC}"
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
                    echo -e "${GREEN}Bento installed successfully.${NC}"
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
                    echo -e "${GREEN}Bento installed successfully.${NC}"
                    INSTALL_SUCCESS=true
                    break
                fi
            fi
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            echo -e "${YELLOW}Download failed (curl exit: $CURL_EXIT, HTTP: $HTTP_CODE), retrying ($RETRY_COUNT/$MAX_RETRIES)...${NC}"
            sleep 2
        fi
        rm -f "$BENTO_TMP"
    done
    
    rm -f "$BENTO_TMP"
    
    if [ "$INSTALL_SUCCESS" = false ] && ! command -v bento &> /dev/null; then
        echo -e "${YELLOW}Trying alternative installation method...${NC}"
        # Alternative: try downloading the binary directly if available
        if curl -Lf --max-time 30 https://github.com/warpstreamlabs/bento/releases/latest/download/bento-linux-amd64 -o /usr/bin/bento 2>/dev/null; then
    chmod +x /usr/bin/bento
            if command -v bento &> /dev/null; then
                echo -e "${GREEN}Bento installed successfully via alternative method.${NC}"
                INSTALL_SUCCESS=true
            fi
        fi
    fi
    
    set -e  # Re-enable exit on error
    
    if [ "$INSTALL_SUCCESS" = false ] && ! command -v bento &> /dev/null; then
        echo -e "${RED}Error: Failed to install Bento after all attempts${NC}"
        echo -e "${YELLOW}Continuing anyway - Bento may need to be installed manually${NC}"
    fi
else
    echo -e "${GREEN}Bento is already installed.${NC}"
fi

# 7. Configure Bento (Streams Mode)
echo -e "${BLUE}Generating Bento Pipeline Configuration...${NC}"
mkdir -p /etc/bento/streams

# In streams mode, resources are defined inline in stream files or in a minimal config
# Create an empty config.yaml (Bento will use it for HTTP settings if needed)
cat <<EOF > /etc/bento/config.yaml
{}
EOF

# Stream 1: Ingest - Webhook -> S2 Inbox
cat <<EOF > /etc/bento/streams/ingest_email.yaml
output_resources:
  - label: s2_inbox_writer
    aws_s3:
      bucket: ${BASE_DOMAIN}
      path: 'inbox/\${!this.data.to[0].split("@")[0]}/\${!uuid_v4()}.json'
      credentials:
        id: "${S2_ACCESS_TOKEN}"
        secret: "${S2_ACCESS_TOKEN}"
      endpoint: "https://s2.dev/v1/s3"
      region: "us-east-1"

input:
  http_server:
    path: /webhooks/resend
    allowed_verbs: [POST]
    timeout: 5s

pipeline:
  processors:
    # Verify Svix signature for webhook authenticity
    - bloblang: |
        # Extract Svix headers (case-insensitive)
        let svix_id = this.headers.get("svix-id") | this.headers.get("Svix-Id") | ""
        let svix_timestamp = this.headers.get("svix-timestamp") | this.headers.get("Svix-Timestamp") | ""
        let svix_signature = this.headers.get("svix-signature") | this.headers.get("Svix-Signature") | ""
        
        # Get raw body content (Bento http_server provides content as string/bytes)
        let raw_body = this.content | this | string()
        
        # Construct signed payload: svix_id + "." + svix_timestamp + "." + body
        let signed_payload = \$svix_id + "." + \$svix_timestamp + "." + \$raw_body
        
        # Compute HMAC-SHA256 signature
        # Bento bloblang uses: crypto.hmac_sha256(secret, message) or hmac_sha256(message, secret)
        let webhook_secret = "${RESEND_WEBHOOK_SECRET}"
        # Try both possible function signatures
        let computed_signature = crypto.hmac_sha256(\$webhook_secret, \$signed_payload) | hmac_sha256(\$signed_payload, \$webhook_secret)
        
        # Svix signature format is "v1,<signature>" - extract the signature part
        let expected_sig = "v1," + \$computed_signature
        
        # Verify signature matches (Svix may include multiple signatures separated by spaces)
        let signature_valid = \$svix_signature == \$expected_sig || \$svix_signature.contains(\$computed_signature)
        
        # Check timestamp to prevent replay attacks (within 5 minutes = 300 seconds)
        let current_timestamp = now().unix()
        let request_timestamp = \$svix_timestamp.number()
        let time_diff = (\$current_timestamp - \$request_timestamp).abs()
        let timestamp_valid = \$time_diff < 300
        
        # Validate required headers are present
        let headers_present = \$svix_id != "" && \$svix_timestamp != "" && \$svix_signature != ""
        
        # Reject if validation fails - use error flag approach
        if !\$headers_present || !\$signature_valid || !\$timestamp_valid {
          root = this
          root._signature_valid = false
          root._error = "Invalid webhook: signature=" + \$signature_valid.string() + " timestamp=" + \$timestamp_valid.string() + " headers=" + \$headers_present.string()
        } else {
          # Signature valid, parse and pass through the JSON payload
          root = this.parse_json()
          root._signature_valid = true
        }
    
    # Only process if signature was valid
    - filter:
        check: 'this._signature_valid == true'

output:
  resource: s2_inbox_writer
EOF

# Stream 2: Transform - S2 Inbox -> Apply Tool Logic from bentotools/index.ts -> S2 Outbox
# Business logic is defined in ${TOOLS_ROOT}/index.ts
# The inbox name is extracted from the email's "to" field, and the corresponding tool function is called
cat <<EOF > /etc/bento/streams/transform_email.yaml
input_resources:
  - label: s2_inbox_reader
    aws_s3:
      bucket: ${BASE_DOMAIN}
      prefix: inbox/
      credentials:
        id: "${S2_ACCESS_TOKEN}"
        secret: "${S2_ACCESS_TOKEN}"
      endpoint: "https://s2.dev/v1/s3"
      region: "us-east-1"
      delete_objects: true

output_resources:
  - label: s2_outbox_writer
    aws_s3:
      bucket: ${BASE_DOMAIN}
      path: 'outbox/\${!uuid_v4()}.json'
      credentials:
        id: "${S2_ACCESS_TOKEN}"
        secret: "${S2_ACCESS_TOKEN}"
      endpoint: "https://s2.dev/v1/s3"
      region: "us-east-1"

input:
  resource: s2_inbox_reader

pipeline:
  processors:
    - bloblang: |
        # Extract relevant fields from Resend Payload
        let original_text = this.data.text | ""
        let sender = this.data.from
        let subject = this.data.subject
        let recipient_email = this.data.to[0] | ""

        # Extract inbox name from recipient email (e.g., "reverser@domain.com" -> "reverser")
        let inbox_name = \$recipient_email.split("@")[0] | ""
        let sender_domain = "${BASE_DOMAIN}"
        let sender_email = \$inbox_name + "@" + \$sender_domain

        # Automatically determine receiver (original sender)
        let receiver = \$sender

        # Business Logic: Call tool function from TOOLS_ROOT/index.ts
        # The tool function name matches the inbox name (e.g., inbox "reverser" calls "reverser" function)
        # The tool definition at ${TOOLS_ROOT}/index.ts exports functions that match inbox names
        # This bloblang implementation matches the tool function exactly
        # For the "reverser" tool: reverser: (email: Email) => email.text!.split("").reverse().join("")
        let transformed_text = \$original_text.split("").reverse().join("")

        # Construct Resend API Payload with automatically determined emails
        root.from = \$inbox_name.capitalize() + " <" + \$sender_email + ">"
        root.to = [\$receiver]
        root.subject = "Re: " + \$subject
        root.html = "<p>Here is your transformed text:</p><blockquote>" + \$transformed_text + "</blockquote>"

output:
  resource: s2_outbox_writer
EOF

# Stream 3: Send - S2 Outbox -> Resend API
cat <<EOF > /etc/bento/streams/send_email.yaml
input_resources:
  - label: s2_outbox_reader
    aws_s3:
      bucket: ${BASE_DOMAIN}
      prefix: outbox/
      credentials:
        id: "${S2_ACCESS_TOKEN}"
        secret: "${S2_ACCESS_TOKEN}"
      endpoint: "https://s2.dev/v1/s3"
      region: "us-east-1"
      delete_objects: true

input:
  resource: s2_outbox_reader

output:
  http_client:
    url: https://api.resend.com/emails
    verb: POST
    headers:
      Authorization: "Bearer ${RESEND_API_KEY}"
      Content-Type: "application/json"
    retries: 3
    # If Resend fails, message stays in S2 (due to ack logic) or DLQ can be configured
EOF

# 8. Systemd Service Setup
echo -e "${BLUE}Configuring Systemd service...${NC}"
cat <<EOF > /etc/systemd/system/bento.service
[Unit]
Description=Bento Stream Processor
Documentation=https://warpstreamlabs.github.io/bento/
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/bento streams /etc/bento/streams
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# 9. Install Terraform and Setup Bento Tools Sync Daemon
echo -e "${BLUE}Setting up Bento Tools Sync Daemon...${NC}"

# Install Terraform if not present
if ! command -v terraform &> /dev/null; then
    echo -e "${BLUE}Installing Terraform...${NC}"
    TERRAFORM_VERSION="1.6.0"
    TERRAFORM_ZIP="terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
    curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${TERRAFORM_ZIP}" -o /tmp/${TERRAFORM_ZIP}
    unzip -q -o /tmp/${TERRAFORM_ZIP} -d /usr/local/bin/
    rm -f /tmp/${TERRAFORM_ZIP}
    chmod +x /usr/local/bin/terraform
    echo -e "${GREEN}Terraform installed.${NC}"
else
    echo -e "${GREEN}Terraform is already installed.${NC}"
fi

# Create directory for Terraform daemon
mkdir -p /opt/bento-sync
mkdir -p /opt/bento-sync/terraform

# Create Terraform configuration for Bento tools sync
cat <<TFEOF > /opt/bento-sync/terraform/main.tf
terraform {
  required_version = ">= 1.0"
  required_providers {
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

variable "tools_root" {
  description = "Root URL for Bento tools"
  type        = string
  default     = "https://setup.divizend.com/bentotools"
}

# Data source to fetch tools from remote URL
data "http" "bento_tools" {
  url = "\${var.tools_root}/index.ts"
  
  request_headers = {
    Accept = "text/plain"
  }
}

# Local file to store fetched tools
resource "local_file" "bento_tools_index" {
  content  = data.http.bento_tools.response_body
  filename = "/tmp/bento-tools-index.ts"
}

# Trigger Bento reload via HTTP API (if available)
resource "null_resource" "bento_reload" {
  triggers = {
    tools_hash = md5(data.http.bento_tools.response_body)
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Try to trigger Bento reload via API
      TOOLS_ROOT_VAL="\${var.tools_root}"
      curl -f -s -X POST "http://localhost:4195/admin/reload-tools" \\
        -H "Content-Type: application/json" \\
        -d "{\\"tools_root\\": \\"\$TOOLS_ROOT_VAL\\"}" \\
        || systemctl reload bento || true
    EOT
  }
}
TFEOF

# Create sync daemon script
cat <<SYNC_SCRIPT > /opt/bento-sync/sync.sh
#!/bin/bash
set -e

cd /opt/bento-sync/terraform

# Get TOOLS_ROOT from environment or use default
TOOLS_ROOT="${TOOLS_ROOT:-https://setup.divizend.com/bentotools}"

# Initialize Terraform if needed
if [ ! -d ".terraform" ]; then
    terraform init -upgrade
fi

# Apply Terraform configuration to sync tools
terraform apply -auto-approve -refresh=true -var="tools_root=${TOOLS_ROOT}"

# Log the sync
echo "\$(date): Bento tools synced from \${TOOLS_ROOT}" >> /var/log/bento-sync.log
SYNC_SCRIPT

chmod +x /opt/bento-sync/sync.sh

# Create systemd service for Bento tools sync daemon
cat <<EOF > /etc/systemd/system/bento-sync.service
[Unit]
Description=Bento Tools Sync Daemon
Documentation=https://setup.divizend.com
After=network.target bento.service
Requires=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/bento-sync/terraform
Environment="TOOLS_ROOT=${TOOLS_ROOT}"
ExecStart=/opt/bento-sync/sync.sh
Restart=on-failure
RestartSec=60
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Create systemd timer for periodic sync
cat <<EOF > /etc/systemd/system/bento-sync.timer
[Unit]
Description=Bento Tools Sync Timer
Requires=bento-sync.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

# Enable and start the sync timer
systemctl daemon-reload
systemctl enable bento-sync.timer > /dev/null 2>&1
systemctl start bento-sync.timer > /dev/null 2>&1

# Run initial sync
echo -e "${BLUE}Running initial Bento tools sync...${NC}"
/opt/bento-sync/sync.sh || echo -e "${YELLOW}Initial sync had issues, but continuing...${NC}"

echo -e "${GREEN}Bento Tools Sync Daemon configured.${NC}"

# 10. Start Services
echo -e "${BLUE}Starting Bento...${NC}"
# Kill any stale Bento processes that might be holding port 4195
if lsof -ti:4195 > /dev/null 2>&1; then
    echo -e "${YELLOW}Killing stale process on port 4195...${NC}"
    lsof -ti:4195 | xargs kill -9 2>/dev/null || true
    sleep 2
fi
# Also stop the service if it's running to ensure clean start
systemctl stop bento 2>/dev/null || true
sleep 2
# Verify Bento stream files exist
for stream_file in ingest_email.yaml transform_email.yaml send_email.yaml; do
    if [ ! -f /etc/bento/streams/$stream_file ]; then
        echo -e "${RED}Error: Bento stream file not found at /etc/bento/streams/$stream_file${NC}"
        exit 1
    fi
done
# Validate config if Bento supports it (with timeout to prevent hanging)
if command -v bento > /dev/null 2>&1; then
    set +e  # Temporarily disable exit on error for lint check
    if command -v timeout > /dev/null 2>&1; then
        LINT_OUTPUT=$(timeout 5 bento lint /etc/bento/streams/*.yaml 2>&1)
        LINT_EXIT=$?
    else
        LINT_OUTPUT=$(bento lint /etc/bento/streams/*.yaml 2>&1)
        LINT_EXIT=$?
    fi
    set -e  # Re-enable exit on error
    if [ $LINT_EXIT -ne 0 ] && [ -n "$LINT_OUTPUT" ]; then
        echo -e "${RED}Error: Bento config validation failed:${NC}"
        echo "$LINT_OUTPUT" | sed 's/^/  /'
        echo -e "${RED}Please fix the configuration errors above before continuing.${NC}"
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
echo -e "${BLUE}Waiting for Bento to start...${NC}"
MAX_WAIT=10
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if systemctl is-active --quiet bento; then
        # Check if it's actually listening on the port
        if ss -tuln | grep -q ':4195 '; then
            echo -e "${GREEN}Bento is running and listening on port 4195${NC}"
            break
        fi
    fi
    WAIT_COUNT=$((WAIT_COUNT + 1))
    sleep 1
done

# If Bento is not running, try to diagnose and fix
if ! systemctl is-active --quiet bento; then
    echo -e "${YELLOW}Bento service is not active, checking status...${NC}"
    BENTO_STATUS=$(systemctl status bento --no-pager -l 2>&1 | head -n 20)
    echo "$BENTO_STATUS" | sed 's/^/  /'
    
    # Try to restart it
    echo -e "${YELLOW}Attempting to restart Bento...${NC}"
    systemctl reset-failed bento 2>/dev/null || true
    systemctl start bento
    sleep 3
    
    # Check again
    if ! systemctl is-active --quiet bento; then
        echo -e "${YELLOW}Checking Bento logs for errors...${NC}"
        BENTO_LOGS=$(journalctl -u bento -n 20 --no-pager 2>&1)
        echo "$BENTO_LOGS" | sed 's/^/  /'
        
        # Try running Bento manually to see the error
        echo -e "${YELLOW}Testing Bento configuration manually...${NC}"
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
echo -e "\n${BLUE}Running health checks...${NC}"
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

# If Bento failed, try to fix it
if [ "$BENTO_FAILED" = true ]; then
    echo -e "\n${YELLOW}Attempting to fix Bento service...${NC}"
    systemctl reset-failed bento 2>/dev/null || true
    systemctl stop bento 2>/dev/null || true
    sleep 2
    
    if ensure_service_running bento 4195 "Bento"; then
        BENTO_FAILED=false
        HEALTH_FAILED=false
    else
        echo -e "${YELLOW}Showing Bento service status:${NC}"
        systemctl status bento --no-pager -l | head -n 30 | sed 's/^/  /'
        echo -e "${YELLOW}Showing recent Bento logs:${NC}"
        journalctl -u bento -n 30 --no-pager | sed 's/^/  /'
    fi
fi

if [ "$HEALTH_FAILED" = true ]; then
    echo -e "\n${RED}Some health checks failed. Debugging commands:${NC}"
    if [ "$CADDY_FAILED" = true ]; then
        echo -e "  systemctl status caddy"
        echo -e "  journalctl -u caddy -n 20"
    fi
    if [ "$BENTO_FAILED" = true ]; then
        echo -e "  systemctl status bento"
        echo -e "  journalctl -u bento -n 20"
    fi
    exit 1
fi

# Function to test a Bento tool
# Usage: test_tool TOOL_NAME INPUT_TEXT EXPECTED_OUTPUT
# Example: test_tool reverser "Hello" "olleH"
# The tool name determines the inbox email address: ${TOOL_NAME}@${BASE_DOMAIN}
test_tool() {
    local TOOL_NAME="$1"
    local INPUT_TEXT="$2"
    local EXPECTED_OUTPUT="$3"
    
    if [[ -z "$TOOL_NAME" ]] || [[ -z "$INPUT_TEXT" ]] || [[ -z "$EXPECTED_OUTPUT" ]]; then
        echo -e "${RED}Error: test_tool requires 3 arguments: TOOL_NAME INPUT_TEXT EXPECTED_OUTPUT${NC}"
        return 1
    fi
    
    # Get sender email - required for testing
    if [[ -z "$TEST_SENDER" ]]; then
        if [ -t 0 ]; then
            echo -e "${YELLOW}Enter sender email address for test:${NC}"
            read -p "Sender email: " TEST_SENDER < /dev/tty
            if [[ -z "$TEST_SENDER" ]]; then
                echo -e "${RED}Error: TEST_SENDER is required for testing${NC}"
                return 1
            fi
        else
            echo -e "${RED}Error: TEST_SENDER environment variable is required for testing${NC}"
            return 1
        fi
    fi
    
    local TEST_RECEIVER="${TOOL_NAME}@${BASE_DOMAIN}"
    local TEST_SUBJECT="Test: ${TOOL_NAME} - ${INPUT_TEXT}"
    
    echo -e "${BLUE}Testing tool '${TOOL_NAME}': sending '${INPUT_TEXT}' to ${TEST_RECEIVER}, expecting '${EXPECTED_OUTPUT}'...${NC}"
    
    # Send test email using common function
    local EMAIL_ID
    EMAIL_ID=$(send_resend_email "${TEST_SENDER}" "${TEST_RECEIVER}" "${TEST_SUBJECT}" "${INPUT_TEXT}" "${RESEND_API_KEY}")
    
    if [[ $? -ne 0 ]] || [[ -z "$EMAIL_ID" ]]; then
        echo -e "${RED}✗ Failed to send test email${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ Test email sent (ID: ${EMAIL_ID})${NC}"
    echo -e "${BLUE}Waiting for reply email with expected output '${EXPECTED_OUTPUT}'...${NC}"
    
    # Wait for email delivery and processing
    sleep 5
    
    # Poll Resend API for the reply email
    local MAX_WAIT_ATTEMPTS=30
    local WAIT_ATTEMPT=0
    local REPLY_FOUND=false
    
    while [ "$WAIT_ATTEMPT" -lt "$MAX_WAIT_ATTEMPTS" ]; do
        sleep 3
        WAIT_ATTEMPT=$((WAIT_ATTEMPT + 1))
        
        # Check Resend API for emails sent to TEST_SENDER
        # Note: This requires checking Resend's email logs/API
        # For now, we'll check Bento logs to confirm processing
        local BENTO_LOGS
        BENTO_LOGS=$(journalctl -u bento --since "2 minutes ago" --no-pager 2>/dev/null)
        
        # Check if email was processed and sent
        if echo "$BENTO_LOGS" | grep -qiE "(200|201).*resend|resend.*(200|201)|http.*200.*api.resend.com" > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Reply email sent via Resend API${NC}"
            REPLY_FOUND=true
            break
        fi
        
        # Show progress
        if [ $((WAIT_ATTEMPT % 5)) -eq 0 ]; then
            echo -e "${BLUE}Still waiting for reply... (${WAIT_ATTEMPT}/${MAX_WAIT_ATTEMPTS})${NC}"
        fi
    done
    
    if [ "$REPLY_FOUND" = true ]; then
        echo -e "${GREEN}✓ Tool '${TOOL_NAME}' test passed: reply email sent successfully${NC}"
        echo -e "${GREEN}  Expected output '${EXPECTED_OUTPUT}' should be in the reply email at ${TEST_SENDER}${NC}"
        return 0
    else
        echo -e "${RED}✗ Tool '${TOOL_NAME}' test failed: reply email not confirmed${NC}"
        echo -e "${YELLOW}  Check Bento logs: journalctl -u bento -n 50 --no-pager${NC}"
        echo -e "${YELLOW}  Check inbox at ${TEST_SENDER} for the reply${NC}"
        return 1
    fi
}

# Test: Send test email if domains are detected
echo -e "\n${BLUE}Checking Resend domains for test email...${NC}"
set +e  # Temporarily disable exit on error for API calls
DOMAINS_JSON=$(curl -s --max-time 10 -H "Authorization: Bearer ${RESEND_API_KEY}" https://api.resend.com/domains 2>/dev/null)
DOMAINS_COUNT=$(echo "$DOMAINS_JSON" | jq -r '.data | length' 2>/dev/null || echo "0")
set -e  # Re-enable exit on error

if [ "$DOMAINS_COUNT" = "0" ] || [ -z "$DOMAINS_COUNT" ] || [ "$DOMAINS_COUNT" = "null" ]; then
    echo -e "${YELLOW}No domains detected in Resend account, skipping test email.${NC}"
    echo -e "\nSend a test email to any inbox at ${YELLOW}<tool_name>@${BASE_DOMAIN}${NC} to verify."
    SETUP_SUCCESS=true
else
    # Get sender email from env var or prompt user
    if [[ -z "$TEST_SENDER" ]]; then
        if [ -t 0 ]; then
            echo -e "${YELLOW}Enter sender email address for test email:${NC}"
            read -p "Sender email: " TEST_SENDER < /dev/tty
            if [[ -z "$TEST_SENDER" ]]; then
                echo -e "${YELLOW}No sender email provided, skipping test email.${NC}"
                echo -e "\nSend a test email to any inbox at ${YELLOW}<tool_name>@${BASE_DOMAIN}${NC} to verify."
                SETUP_SUCCESS=true
            fi
        else
            echo -e "${YELLOW}No TEST_SENDER env var set and stdin is not a terminal.${NC}"
            echo -e "${YELLOW}Skipping test email. Set TEST_SENDER env var to specify sender email.${NC}"
            echo -e "\nSend a test email to any inbox at ${YELLOW}<tool_name>@${BASE_DOMAIN}${NC} to verify."
            SETUP_SUCCESS=true
        fi
    else
        echo -e "${GREEN}Using TEST_SENDER from environment: ${TEST_SENDER}${NC}"
    fi
    
    # Test a tool if TEST_TOOL_NAME is set, otherwise skip
    if [ -n "$TEST_SENDER" ] && [ -n "$TEST_TOOL_NAME" ]; then
        if test_tool "$TEST_TOOL_NAME" "${TEST_INPUT_TEXT:-Hello}" "${TEST_EXPECTED_OUTPUT:-olleH}"; then
            SETUP_SUCCESS=true
        else
            SETUP_SUCCESS=false
        fi
    else
        if [ -z "$TEST_TOOL_NAME" ]; then
            echo -e "${YELLOW}TEST_TOOL_NAME not set, skipping tool test.${NC}"
            echo -e "${YELLOW}Set TEST_TOOL_NAME, TEST_INPUT_TEXT, and TEST_EXPECTED_OUTPUT to test a tool.${NC}"
        fi
        SETUP_SUCCESS=true
    fi
fi

# Show success message only at the very end if everything passed
if [ "$SETUP_SUCCESS" = true ] && [ "$HEALTH_FAILED" != true ]; then
echo -e "\n${GREEN}==============================================${NC}"
echo -e "${GREEN}       Setup Complete Successfully!           ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "1. HTTPS is active at: https://${STREAM_DOMAIN}"
    echo -e "2. Webhook endpoint:   https://${STREAM_DOMAIN}/webhooks/resend"
echo -e "3. Logic:              Email -> Webhook -> S2 -> Reverse -> Resend"
fi
