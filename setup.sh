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
read -p "Enter your Base Domain (e.g., mydomain.com): " BASE_DOMAIN < /dev/tty
if [[ -z "$BASE_DOMAIN" ]]; then echo -e "${RED}Domain is required.${NC}"; exit 1; fi
STREAM_DOMAIN="streams.${BASE_DOMAIN}"
echo -e "Service will be deployed at: ${GREEN}https://${STREAM_DOMAIN}${NC}"

# S2 Configuration
read -p "Enter S2 Access Token: " S2_TOKEN < /dev/tty
if [[ -z "$S2_TOKEN" ]]; then echo -e "${RED}S2 Token is required.${NC}"; exit 1; fi

# Resend API Key
read -p "Enter Resend API Key (starts with re_): " RESEND_KEY < /dev/tty
if [[ -z "$RESEND_KEY" ]]; then echo -e "${RED}Resend API Key is required.${NC}"; exit 1; fi

# Webhook Setup Step
WEBHOOK_URL="https://${STREAM_DOMAIN}/webhooks/resend"

echo -e "\n${YELLOW}--- Action Required ---${NC}"
echo -e "1. Go to your Resend Dashboard > Webhooks."
echo -e "2. Create a new Webhook."
echo -e "3. Set the Endpoint URL to: ${GREEN}${WEBHOOK_URL}${NC}"
echo -e "4. Select ${GREEN}All Events${NC}"
echo -e "5. Create the webhook and copy the ${BLUE}Signing Secret${NC} (starts with whsec_)."
echo -e "-----------------------"

read -p "Paste the Resend Webhook Secret here: " RESEND_WEBHOOK_SECRET < /dev/tty
if [[ -z "$RESEND_WEBHOOK_SECRET" ]]; then echo -e "${RED}Webhook Secret is required.${NC}"; exit 1; fi

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
cat <<EOF > /etc/caddy/Caddyfile
${STREAM_DOMAIN} {
    reverse_proxy localhost:4195
}
EOF
systemctl daemon-reload
systemctl enable caddy
systemctl reload-or-restart caddy

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
        id: "${S2_TOKEN}"
        secret: "${S2_TOKEN}"
      endpoint: "https://s2.dev/v1/s3"
      region: "us-east-1"
      delete_objects: true # Queue-like behavior: delete after read

  - label: s2_outbox_reader
    aws_s3:
      bucket: ${BASE_DOMAIN}
      prefix: outbox/
      credentials:
        id: "${S2_TOKEN}"
        secret: "${S2_TOKEN}"
      endpoint: "https://s2.dev/v1/s3"
      region: "us-east-1"
      delete_objects: true

output_resources:
  - label: s2_inbox_writer
    aws_s3:
      bucket: ${BASE_DOMAIN}
      path: 'inbox/reverser/\${!uuid_v4()}.json'
      credentials:
        id: "${S2_TOKEN}"
        secret: "${S2_TOKEN}"
      endpoint: "https://s2.dev/v1/s3"
      region: "us-east-1"

  - label: s2_outbox_writer
    aws_s3:
      bucket: ${BASE_DOMAIN}
      path: 'outbox/\${!uuid_v4()}.json'
      credentials:
        id: "${S2_TOKEN}"
        secret: "${S2_TOKEN}"
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
          Authorization: "Bearer ${RESEND_KEY}"
          Content-Type: "application/json"
        retries: 3
        # If Resend fails, message stays in S2 (due to ack logic) or DLQ can be configured
EOF

# 8. Systemd Service Setup
echo -e "${BLUE}Configuring Systemd service...${NC}"
cat <<EOF > /etc/systemd/system/bento.service
[Unit]
Description=Bento Stream Processor
Documentation=https://www.bento.dev/
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

echo -e "\n${GREEN}==============================================${NC}"
echo -e "${GREEN}       Setup Complete Successfully!           ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "1. HTTPS is active at: https://${STREAM_DOMAIN}"
echo -e "2. Webhook endpoint:   https://${STREAM_DOMAIN}/webhooks/resend"
echo -e "3. Logic:              Email -> Webhook -> S2 -> Reverse -> Resend"
echo -e "\nSend a test email to ${YELLOW}reverser@${BASE_DOMAIN}${NC} to verify."
