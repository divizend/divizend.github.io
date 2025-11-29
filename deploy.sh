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
scp common.sh root@${SERVER_IP}:/tmp/common.sh > /dev/null
# Copy templates directory
scp -r templates root@${SERVER_IP}:/tmp/ > /dev/null
# Pass environment variables if they exist in local .env
SSH_CMD=""
[[ -n "$BASE_DOMAIN" ]] && SSH_CMD="${SSH_CMD}BASE_DOMAIN=$(printf %q "$BASE_DOMAIN") "
[[ -n "$S2_ACCESS_TOKEN" ]] && SSH_CMD="${SSH_CMD}S2_ACCESS_TOKEN=$(printf %q "$S2_ACCESS_TOKEN") "
[[ -n "$RESEND_API_KEY" ]] && SSH_CMD="${SSH_CMD}RESEND_API_KEY=$(printf %q "$RESEND_API_KEY") "
[[ -n "$RESEND_WEBHOOK_SECRET" ]] && SSH_CMD="${SSH_CMD}RESEND_WEBHOOK_SECRET=$(printf %q "$RESEND_WEBHOOK_SECRET") "
[[ -n "$TEST_SENDER" ]] && SSH_CMD="${SSH_CMD}TEST_SENDER=$(printf %q "$TEST_SENDER") "
[[ -n "$TEST_TOOL_NAME" ]] && SSH_CMD="${SSH_CMD}TEST_TOOL_NAME=$(printf %q "$TEST_TOOL_NAME") "
[[ -n "$TEST_INPUT_TEXT" ]] && SSH_CMD="${SSH_CMD}TEST_INPUT_TEXT=$(printf %q "$TEST_INPUT_TEXT") "
[[ -n "$TEST_EXPECTED_OUTPUT" ]] && SSH_CMD="${SSH_CMD}TEST_EXPECTED_OUTPUT=$(printf %q "$TEST_EXPECTED_OUTPUT") "
[[ -n "$TOOLS_ROOT_GITHUB" ]] && SSH_CMD="${SSH_CMD}TOOLS_ROOT_GITHUB=$(printf %q "$TOOLS_ROOT_GITHUB") "
[[ -n "$S2_BASIN" ]] && SSH_CMD="${SSH_CMD}S2_BASIN=$(printf %q "$S2_BASIN") "

if ssh -t root@${SERVER_IP} "${SSH_CMD}bash /tmp/setup.sh.local; EXIT_CODE=\$?; rm -rf /tmp/setup.sh.local /tmp/common.sh /tmp/templates; exit \$EXIT_CODE"; then
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
    
    if ssh root@${SERVER_IP} "cd /opt/bento-sync && ${TEST_ENV} bun sync.ts 2>&1"; then
        echo "[INFO] ✓ Sync script test passed."
    else
        echo "[WARNING] ⚠ Sync script test had issues, but deployment succeeded."
        echo "[WARNING] Check Bento API accessibility and environment variables."
    fi
else
    echo "[ERROR] Deployment failed. The setup script on the server terminated with an error."
    exit 1
fi
