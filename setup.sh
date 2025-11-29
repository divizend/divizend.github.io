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

echo -e "${BLUE}Starting Stream Processor Setup...${NC}"

# 1. Pre-flight Checks
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Please run as root${NC}"
  exit 1
fi

# 2. Interactive Configuration
echo -e "${YELLOW}--- Configuration ---${NC}"

# Domain
if [[ -z "$BASE_DOMAIN" ]]; then
    read -p "Enter your Base Domain (e.g., mydomain.com): " BASE_DOMAIN < /dev/tty
    if [[ -z "$BASE_DOMAIN" ]]; then echo -e "${RED}Domain is required.${NC}"; exit 1; fi
else
    echo -e "${GREEN}Using BASE_DOMAIN from environment: ${BASE_DOMAIN}${NC}"
fi
STREAM_DOMAIN="streams.${BASE_DOMAIN}"
SERVER_IP=$(hostname -I | awk '{print $1}' || curl -s ifconfig.me || echo "")
echo -e "Service will be deployed at: ${GREEN}https://${STREAM_DOMAIN}${NC}"
echo -e "${YELLOW}DNS: Create an A record: ${STREAM_DOMAIN} -> ${SERVER_IP}${NC}"

# Wait for DNS record to be configured
if [[ -n "$SERVER_IP" ]]; then
    echo -e "${BLUE}Waiting for DNS record to propagate...${NC}"
    while true; do
        if command -v dig > /dev/null 2>&1; then
            RESOLVED_IP=$(dig +short ${STREAM_DOMAIN} @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
        elif command -v host > /dev/null 2>&1; then
            RESOLVED_IP=$(host ${STREAM_DOMAIN} 8.8.8.8 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
        else
            RESOLVED_IP=$(nslookup ${STREAM_DOMAIN} 8.8.8.8 2>/dev/null | grep -A1 "Name:" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
        fi
        if [[ -n "$RESOLVED_IP" ]] && [[ "$RESOLVED_IP" == "$SERVER_IP" ]]; then
            echo -e "${GREEN}DNS record is correctly configured!${NC}"
            break
        fi
        echo -e "${YELLOW}DNS not ready yet (resolved to: ${RESOLVED_IP:-not found}), waiting 5 seconds...${NC}"
        sleep 5
    done
else
    echo -e "${YELLOW}Could not detect server IP, skipping DNS check.${NC}"
fi

# S2 Configuration
if [[ -z "$S2_ACCESS_TOKEN" ]]; then
    read -p "Enter S2 Access Token: " S2_ACCESS_TOKEN < /dev/tty
    if [[ -z "$S2_ACCESS_TOKEN" ]]; then echo -e "${RED}S2 Token is required.${NC}"; exit 1; fi
else
    echo -e "${GREEN}Using S2_ACCESS_TOKEN from environment.${NC}"
fi

# Resend API Key
if [[ -z "$RESEND_API_KEY" ]]; then
    read -p "Enter Resend API Key (starts with re_): " RESEND_API_KEY < /dev/tty
    if [[ -z "$RESEND_API_KEY" ]]; then echo -e "${RED}Resend API Key is required.${NC}"; exit 1; fi
else
    echo -e "${GREEN}Using RESEND_API_KEY from environment.${NC}"
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
    read -p "Paste the Resend Webhook Secret here: " RESEND_WEBHOOK_SECRET < /dev/tty
    if [[ -z "$RESEND_WEBHOOK_SECRET" ]]; then echo -e "${RED}Webhook Secret is required.${NC}"; exit 1; fi
else
    echo -e "${GREEN}Using RESEND_WEBHOOK_SECRET from environment.${NC}"
fi

# 3. System Dependencies
echo -e "\n${BLUE}Installing system dependencies...${NC}"
apt-get update -qq
apt-get install -y -qq curl jq debian-keyring debian-archive-keyring apt-transport-https

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

# Check if Caddy is running and healthy
if systemctl is-active --quiet caddy 2>/dev/null; then
    if [ "$CADDYFILE_CHANGED" = true ]; then
        echo -e "${BLUE}Reloading Caddy configuration...${NC}"
        systemctl reload caddy || {
            echo -e "${YELLOW}Caddy reload failed, attempting restart...${NC}"
            systemctl restart caddy || echo -e "${YELLOW}Note: Caddy restart had issues, but continuing...${NC}"
        }
    else
        echo -e "${GREEN}Caddy is already running.${NC}"
    fi
else
    # Caddy is not running - check for port conflicts only if we need to start it
    if ss -tuln | grep -q ':443 '; then
        echo -e "${YELLOW}Port 443 is in use, checking for conflicting services...${NC}"
        # Only stop services if Caddy isn't the one using the port
        if ! systemctl is-active --quiet caddy 2>/dev/null; then
            for service in apache2 nginx httpd; do
                if systemctl is-active --quiet $service 2>/dev/null; then
                    echo -e "${YELLOW}Stopping ${service} to free port 443...${NC}"
                    systemctl stop $service
                    systemctl disable $service > /dev/null 2>&1 || true
                fi
            done
            sleep 1
        fi
    fi
    echo -e "${BLUE}Starting Caddy...${NC}"
    systemctl start caddy || {
        echo -e "${YELLOW}Warning: Caddy failed to start. This may be due to port conflicts or configuration issues.${NC}"
        echo -e "${YELLOW}You can check the status with: systemctl status caddy${NC}"
    }
fi

# 6. Install Bento (Stream Processor)
if ! command -v bento &> /dev/null; then
    echo -e "${BLUE}Installing Bento...${NC}"
    # Using the official script to install the binary to /usr/bin
    curl -Lsf https://github.com/warpstreamlabs/bento/releases/latest/download/bento-linux-amd64.tar.gz | tar -xz -C /usr/bin bento
    chmod +x /usr/bin/bento
else
    echo -e "${GREEN}Bento is already installed.${NC}"
fi

# 7. Configure Bento (Streams Mode)
echo -e "${BLUE}Generating Bento Pipeline Configuration...${NC}"
mkdir -p /etc/bento

# We use Bento's 'streams' mode to run isolated pipelines in one process
cat <<EOF > /etc/bento/streams.yaml
# Global HTTP settings for the Bento instance
http:
  enabled: true
  address: 0.0.0.0:4195

# Resources shared across streams
input_resources:
  - label: s2_inbox_reader
    aws_s3:
      bucket: ${BASE_DOMAIN}
      prefix: inbox/reverser/
      credentials:
        id: "${S2_ACCESS_TOKEN}"
        secret: "${S2_ACCESS_TOKEN}"
      endpoint: "https://s2.dev/v1/s3"
      region: "us-east-1"
      delete_objects: true # Queue-like behavior: delete after read

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

output_resources:
  - label: s2_inbox_writer
    aws_s3:
      bucket: ${BASE_DOMAIN}
      path: 'inbox/reverser/\${!uuid_v4()}.json'
      credentials:
        id: "${S2_ACCESS_TOKEN}"
        secret: "${S2_ACCESS_TOKEN}"
      endpoint: "https://s2.dev/v1/s3"
      region: "us-east-1"

  - label: s2_outbox_writer
    aws_s3:
      bucket: ${BASE_DOMAIN}
      path: 'outbox/\${!uuid_v4()}.json'
      credentials:
        id: "${S2_ACCESS_TOKEN}"
        secret: "${S2_ACCESS_TOKEN}"
      endpoint: "https://s2.dev/v1/s3"
      region: "us-east-1"

# ------------------------------------------------------------------------------
# Stream Definitions
# ------------------------------------------------------------------------------
stream_conf:
  # ----------------------------------------------------
  # 1. Ingest: Webhook -> S2 Inbox
  # ----------------------------------------------------
  ingest_email:
    input:
      http_server:
        path: /webhooks/resend
        allowed_verbs: [POST]
        timeout: 5s
    
    pipeline:
      processors:
        # In a strict production environment, you would verify the svix-signature here.
        # Passing raw payload to stream for durability.
        - mapping: root = this
    
    output:
      resource: s2_inbox_writer

  # ----------------------------------------------------
  # 2. Logic: S2 Inbox -> Reverse Text -> S2 Outbox
  # ----------------------------------------------------
  process_reverser:
    input:
      resource: s2_inbox_reader
    
    pipeline:
      processors:
        - bloblang: |
            # Extract relevant fields from Resend Payload
            let original_text = this.data.text | ""
            let sender = this.data.from
            let subject = this.data.subject

            # Business Logic: Reverse the text
            # Splitting by empty string creates array of chars, reverse array, join back
            let reversed_text = \$original_text.split("").reverse().join("")

            # Construct Resend API Payload
            root.from = "Reverser <reverser@${BASE_DOMAIN}>"
            root.to = [\$sender]
            root.subject = "Re: " + \$subject
            root.html = "<p>Here is your reversed text:</p><blockquote>" + \$reversed_text + "</blockquote>"

    output:
      resource: s2_outbox_writer

  # ----------------------------------------------------
  # 3. Egress: S2 Outbox -> Resend API
  # ----------------------------------------------------
  send_email:
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
ExecStart=/usr/bin/bento streams /etc/bento/streams.yaml
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# 9. Start Services
echo -e "${BLUE}Starting Bento...${NC}"
systemctl daemon-reload
systemctl enable bento
systemctl restart bento

# 10. Health Checks
echo -e "\n${BLUE}Running health checks...${NC}"
HEALTH_FAILED=false

# Check Caddy service
if systemctl is-active --quiet caddy; then
    echo -e "${GREEN}✓ Caddy service is running${NC}"
else
    echo -e "${RED}✗ Caddy service is not running${NC}"
    HEALTH_FAILED=true
fi

# Check Bento service
if systemctl is-active --quiet bento; then
    echo -e "${GREEN}✓ Bento service is running${NC}"
else
    echo -e "${RED}✗ Bento service is not running${NC}"
    HEALTH_FAILED=true
fi

# Check Caddy is listening on port 443
if ss -tuln | grep -q ':443 '; then
    echo -e "${GREEN}✓ Caddy is listening on port 443${NC}"
else
    echo -e "${RED}✗ Caddy is not listening on port 443${NC}"
    HEALTH_FAILED=true
fi

# Check Bento is listening on port 4195
if ss -tuln | grep -q ':4195 '; then
    echo -e "${GREEN}✓ Bento is listening on port 4195${NC}"
else
    echo -e "${RED}✗ Bento is not listening on port 4195${NC}"
    HEALTH_FAILED=true
fi

# Check DNS resolution
if [[ -n "$SERVER_IP" ]]; then
    RESOLVED_IP=""
    if command -v dig > /dev/null 2>&1; then
        RESOLVED_IP=$(dig +short ${STREAM_DOMAIN} @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
    elif command -v host > /dev/null 2>&1; then
        RESOLVED_IP=$(host ${STREAM_DOMAIN} 8.8.8.8 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
    fi
    if [[ -n "$RESOLVED_IP" ]] && [[ "$RESOLVED_IP" == "$SERVER_IP" ]]; then
        echo -e "${GREEN}✓ DNS is correctly configured${NC}"
    else
        echo -e "${YELLOW}⚠ DNS may not be fully propagated (resolved to: ${RESOLVED_IP:-not found})${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Could not verify DNS (server IP not detected)${NC}"
fi

# Check HTTPS endpoint (with timeout)
if curl -s --max-time 5 -o /dev/null -w "%{http_code}" https://${STREAM_DOMAIN} > /dev/null 2>&1; then
    HTTP_CODE=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" https://${STREAM_DOMAIN} 2>/dev/null)
    if [[ "$HTTP_CODE" =~ ^[23] ]]; then
        echo -e "${GREEN}✓ HTTPS endpoint is reachable (HTTP ${HTTP_CODE})${NC}"
    else
        echo -e "${YELLOW}⚠ HTTPS endpoint returned HTTP ${HTTP_CODE}${NC}"
    fi
else
    echo -e "${YELLOW}⚠ HTTPS endpoint is not reachable yet${NC}"
fi

if [ "$HEALTH_FAILED" = true ]; then
    echo -e "\n${RED}Some health checks failed. Please check the service status:${NC}"
    echo -e "  systemctl status caddy"
    echo -e "  systemctl status bento"
    echo -e "  journalctl -u caddy -n 20"
    echo -e "  journalctl -u bento -n 20"
    exit 1
fi

echo -e "\n${GREEN}==============================================${NC}"
echo -e "${GREEN}       Setup Complete Successfully!           ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "1. HTTPS is active at: https://${STREAM_DOMAIN}"
echo -e "2. Webhook endpoint:   https://${STREAM_DOMAIN}/webhooks/resend"
echo -e "3. Logic:              Email -> Webhook -> S2 -> Reverse -> Resend"
echo -e "\nSend a test email to ${YELLOW}reverser@${BASE_DOMAIN}${NC} to verify."
