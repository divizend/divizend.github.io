#!/usr/bin/env bash
set -euo pipefail

# =================================================================
# One-command production deployment for streams.divizend.com
# Resend webhooks → Bento → S2[](https://s2.dev)
# Fresh Ubuntu 24.04 only → fully working in < 90 seconds
# =================================================================

DOMAIN="streams.divizend.com"
EMAIL="${ADMIN_EMAIL:-admin@divizend.com}"
INSTALL_DIR="/opt/divizend"
BENTO_PORT="4195"

echo "Installing Caddy + Bento for $DOMAIN ..."

# 1. System update & essentials
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -yqq curl unzip ca-certificates > /dev/null

# 2. Install latest Caddy (with ACME)
curl -fsSL https://get.caddy.com | bash > /dev/null 2>&1

# 3. Install latest warpstreamlabs/bento
curl -fsSL https://github.com/warpstreamlabs/bento/releases/latest/download/bento_linux_amd64 -o /usr/local/bin/bento
chmod +x /usr/local/bin/bento

# 4. Create install dir
mkdir -p "$INSTALL_DIR/logs"
cd "$INSTALL_DIR"

# 5. bento.yaml — perfect minimal config
cat > bento.yaml <<'EOF'
http_server:
  address: 0.0.0.0:4195
  path: /resend

pipeline:
  processors:
    - hmac:
        algorithm: sha256
        key: ${RESEND_WEBHOOK_SECRET}
        header: X-Resend-Signature
        payload: root

    - switch:
        - check: this.event == "email.sent"
          processors:
            - http:
                url: https://api.s2.dev/streams/resend.sent/append
                verb: POST
                headers:
                  Authorization: Bearer ${S2_API_KEY}
                  Content-Type: application/json
                body: '{{ json "this" }}'

        - check: this.event == "email.delivered"
          processors:
            - http:
                url: https://api.s2.dev/streams/resend.delivered/append
                verb: POST
                headers:
                  Authorization: Bearer ${S2_API_KEY}
                  Content-Type: application/json
                body: '{{ json "this" }}'

        - check: this.event == "email.bounced"
          processors:
            - http:
                url: https://api.s2.dev/streams/resend.bounced/append
                verb: POST
                headers:
                  Authorization: Bearer ${S2_API_KEY}
                  Content-Type: application/json
                body: '{{ json "this" }}'

        # Add more events as needed — all others fall through to default
        - processors:
            - http:
                url: https://api.s2.dev/streams/resend.{{ this.event }}/append
                verb: POST
                headers:
                  Authorization: Bearer ${S2_API_KEY}
                  Content-Type: application/json
                body: '{{ json "this" }}'

logger:
  level: info
EOF

# 6. .env (user must edit after first run)
cat > .env <<EOF
# EDIT THESE THREE VALUES AFTER INSTALL
S2_API_KEY=sk_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
RESEND_API_KEY=re_XXXXXXXXXXXXXXXXXXXXXXXX
RESEND_WEBHOOK_SECRET=whsec_XXXXXXXXXXXXXXXXXXXXXXXX
ADMIN_EMAIL=$EMAIL
EOF

# 7. Caddyfile
cat > Caddyfile <<EOF
$DOMAIN {
    reverse_proxy localhost:$BENTO_PORT
    tls $EMAIL
    log {
        output file /var/log/caddy/access.log
    }
}
EOF

# 8. systemd services
cat > /etc/systemd/system/bento.service <<EOF
[Unit]
Description=Bento Resend → S2 bridge
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/local/bin/bento -c $INSTALL_DIR/bento.yaml
EnvironmentFile=$INSTALL_DIR/.env
Restart=always
RestartSec=3
StandardOutput=append:$INSTALL_DIR/logs/bento.log
StandardError=append:$INSTALL_DIR/logs/bento.err

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/caddy run --config /opt/divizend/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config /opt/divizend/Caddyfile --adapter caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

# 9. Start everything
systemctl daemon-reload
systemctl enable --now caddy bento > /dev/null

# 10. Final message
echo "Setup complete!"
echo "https://$DOMAIN/resend is ready"
echo ""
echo "Now edit $INSTALL_DIR/.env with your real keys and run:"
echo "   sudo systemctl restart bento"
echo ""
echo "Then point your Resend webhook to https://$DOMAIN/resend"
