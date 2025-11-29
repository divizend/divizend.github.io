#!/bin/bash
set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

if ! git diff --quiet setup.sh; then
    echo "[INFO] Committing and pushing setup.sh..."
    git add setup.sh
    git commit -m "Update setup.sh"
    git push
else
    echo "[INFO] setup.sh is unchanged, skipping git operations."
fi

echo "[DEPLOY] Running setup on server..."
# Source .env if it exists (silently handle if it doesn't)
[ -f .env ] && source .env

# Get SERVER_IP using common function
get_config_value SERVER_IP "Enter Server IP address" "SERVER_IP is required"
scp setup.sh root@${SERVER_IP}:/tmp/setup.sh.local > /dev/null
# Pass environment variables if they exist in local .env
SSH_CMD=""
[[ -n "$BASE_DOMAIN" ]] && SSH_CMD="${SSH_CMD}BASE_DOMAIN=$(printf %q "$BASE_DOMAIN") "
[[ -n "$S2_ACCESS_TOKEN" ]] && SSH_CMD="${SSH_CMD}S2_ACCESS_TOKEN=$(printf %q "$S2_ACCESS_TOKEN") "
[[ -n "$RESEND_API_KEY" ]] && SSH_CMD="${SSH_CMD}RESEND_API_KEY=$(printf %q "$RESEND_API_KEY") "
[[ -n "$RESEND_WEBHOOK_SECRET" ]] && SSH_CMD="${SSH_CMD}RESEND_WEBHOOK_SECRET=$(printf %q "$RESEND_WEBHOOK_SECRET") "
[[ -n "$TEST_SENDER" ]] && SSH_CMD="${SSH_CMD}TEST_SENDER=$(printf %q "$TEST_SENDER") "
ssh -t root@${SERVER_IP} "${SSH_CMD}bash /tmp/setup.sh.local; rm /tmp/setup.sh.local"
echo "[INFO] Deployment complete."
