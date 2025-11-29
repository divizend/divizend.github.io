#!/bin/bash
# Bento Streams Sync Script
# This script compiles TypeScript exports and syncs them to Bento via HTTP API

set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Default values
BENTO_API_URL="${BENTO_API_URL:-http://localhost:4195}"
TOOLS_ROOT_GITHUB="${TOOLS_ROOT_GITHUB:-}"

if [ -z "$TOOLS_ROOT_GITHUB" ]; then
    echo -e "${RED}Error: TOOLS_ROOT_GITHUB environment variable is required${NC}" >&2
    exit 1
fi

echo -e "${BLUE}🔄 Syncing Bento streams from ${TOOLS_ROOT_GITHUB}...${NC}"

# Parse TOOLS_ROOT_GITHUB to extract repo, branch, and path
# Format: https://github.com/owner/repo[/branch][/path]
if [[ ! "$TOOLS_ROOT_GITHUB" =~ ^https://github\.com/([^/]+)/([^/]+)(/([^/]+))?(/(.*))?$ ]]; then
    echo -e "${RED}Error: Invalid TOOLS_ROOT_GITHUB format. Expected: https://github.com/owner/repo[/branch][/path]${NC}" >&2
    exit 1
fi

OWNER="${BASH_REMATCH[1]}"
REPO="${BASH_REMATCH[2]}"
BRANCH="${BASH_REMATCH[4]}"
PATH_PART="${BASH_REMATCH[6]}"

# If branch not specified, get default branch from GitHub API
if [ -z "$BRANCH" ]; then
    echo -e "${BLUE}📡 Fetching default branch for ${OWNER}/${REPO}...${NC}"
    DEFAULT_BRANCH=$(curl -s "https://api.github.com/repos/${OWNER}/${REPO}" | grep -o '"default_branch":"[^"]*' | cut -d'"' -f4)
    if [ -z "$DEFAULT_BRANCH" ]; then
        echo -e "${YELLOW}⚠ Could not determine default branch, using 'main'${NC}"
        DEFAULT_BRANCH="main"
    fi
    BRANCH="$DEFAULT_BRANCH"
fi

# Construct raw GitHub URL
if [ -n "$PATH_PART" ]; then
    # Remove trailing slash if present
    PATH_PART="${PATH_PART%/}"
    RAW_URL="https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/${PATH_PART}/index.ts"
else
    RAW_URL="https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/index.ts"
fi

echo -e "${BLUE}📥 Fetching index.ts from ${RAW_URL}...${NC}"

# Fetch the index.ts file
TEMP_FILE=$(mktemp)
if ! curl -fsSL "$RAW_URL" -o "$TEMP_FILE"; then
    echo -e "${RED}❌ Failed to fetch index.ts from ${RAW_URL}${NC}" >&2
    rm -f "$TEMP_FILE"
    exit 1
fi

# Check if bun is available
if ! command -v bun &> /dev/null; then
    echo -e "${RED}❌ Error: bun is required but not installed${NC}" >&2
    echo -e "${YELLOW}Install bun: curl -fsSL https://bun.sh/install | bash${NC}" >&2
    rm -f "$TEMP_FILE"
    exit 1
fi

# Compile the TypeScript file to get stream configurations
echo -e "${BLUE}🔧 Compiling TypeScript exports...${NC}"

# Create a temporary directory for compilation
TEMP_DIR=$(mktemp -d)
cp "$TEMP_FILE" "$TEMP_DIR/index.ts"

# Create a minimal package.json for the temp directory
cat > "$TEMP_DIR/package.json" <<EOF
{
  "name": "temp-bentotools",
  "type": "module",
  "dependencies": {
    "bentotools": "^1.1.0"
  }
}
EOF

# Install dependencies
cd "$TEMP_DIR"
bun install --silent > /dev/null 2>&1 || true

# Use bun to evaluate the exports and generate stream configs
# We'll create a simple script that exports the streams
STREAMS_JSON=$(bun -e "
import * as module from './index.ts';
const streams = {};
for (const [key, value] of Object.entries(module)) {
  if (key === 'default' || key.startsWith('_')) continue;
  if (typeof value === 'function') continue;
  if (value && typeof value === 'object' && value.input && value.output) {
    streams[key] = value;
  }
}
console.log(JSON.stringify(streams, null, 2));
" 2>/dev/null)

if [ -z "$STREAMS_JSON" ] || [ "$STREAMS_JSON" = "{}" ]; then
    echo -e "${RED}❌ No stream definitions found in exports${NC}" >&2
    rm -rf "$TEMP_DIR" "$TEMP_FILE"
    exit 1
fi

echo -e "${GREEN}✓ Found $(echo "$STREAMS_JSON" | jq 'keys | length') stream definition(s)${NC}"

# Clean up temp files
rm -rf "$TEMP_DIR" "$TEMP_FILE"

# Substitute variables in stream configs
# Get variables from environment (these should be set by setup.sh or systemd service)
S2_BASIN="${S2_BASIN:-}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
S2_ACCESS_TOKEN="${S2_ACCESS_TOKEN:-}"
RESEND_API_KEY="${RESEND_API_KEY:-}"

if [ -z "$S2_BASIN" ] || [ -z "$BASE_DOMAIN" ] || [ -z "$S2_ACCESS_TOKEN" ] || [ -z "$RESEND_API_KEY" ]; then
    echo -e "${YELLOW}⚠ Warning: Some environment variables are missing. Stream configs may contain unsubstituted variables.${NC}"
    echo -e "${YELLOW}  Missing: S2_BASIN=${S2_BASIN:-MISSING} BASE_DOMAIN=${BASE_DOMAIN:-MISSING} S2_ACCESS_TOKEN=${S2_ACCESS_TOKEN:+SET} RESEND_API_KEY=${RESEND_API_KEY:+SET}${NC}"
fi

# Substitute variables in the JSON
# Convert JSON to string, substitute variables, then validate it's still valid JSON
STREAMS_JSON_SUBSTITUTED=$(echo "$STREAMS_JSON" | \
    sed "s|\${S2_BASIN}|${S2_BASIN}|g" | \
    sed "s|\${BASE_DOMAIN}|${BASE_DOMAIN}|g" | \
    sed "s|\${S2_ACCESS_TOKEN}|${S2_ACCESS_TOKEN}|g" | \
    sed "s|\${RESEND_API_KEY}|${RESEND_API_KEY}|g")

# Validate JSON is still valid after substitution
if ! echo "$STREAMS_JSON_SUBSTITUTED" | jq . > /dev/null 2>&1; then
    echo -e "${RED}❌ Error: JSON became invalid after variable substitution${NC}" >&2
    exit 1
fi

# Check if Bento API is accessible
echo -e "${BLUE}🔍 Checking Bento API at ${BENTO_API_URL}...${NC}"
if ! curl -f -s "${BENTO_API_URL}/ready" > /dev/null 2>&1; then
    echo -e "${YELLOW}⚠ Warning: Bento API at ${BENTO_API_URL} is not accessible${NC}"
    echo -e "${YELLOW}This is expected if Bento is not running or not publicly accessible${NC}"
    exit 0
fi

# Sync streams to Bento via HTTP API
# Bento's streams API endpoint (this may need to be adjusted based on actual Bento API)
echo -e "${BLUE}📤 Syncing streams to Bento...${NC}"

# For each stream, create/update it via Bento API
for stream_name in $(echo "$STREAMS_JSON_SUBSTITUTED" | jq -r 'keys[]'); do
    stream_config=$(echo "$STREAMS_JSON_SUBSTITUTED" | jq ".[\"$stream_name\"]")
    
    echo -e "${BLUE}  → Syncing stream: ${stream_name}${NC}"
    
    # Bento API endpoint for creating/updating streams
    # Try POST first (create), then PUT (update) if that fails
    # This endpoint may need to be adjusted based on actual Bento API documentation
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        "${BENTO_API_URL}/streams/${stream_name}" \
        -H "Content-Type: application/json" \
        -d "$stream_config" 2>&1)
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    
    # If POST fails with 409 (conflict) or similar, try PUT (update)
    if [ "$HTTP_CODE" -eq 409 ] || [ "$HTTP_CODE" -eq 404 ]; then
        RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT \
            "${BENTO_API_URL}/streams/${stream_name}" \
            -H "Content-Type: application/json" \
            -d "$stream_config" 2>&1)
        HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
        BODY=$(echo "$RESPONSE" | sed '$d')
    fi
    
    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        echo -e "${GREEN}    ✓ Stream '${stream_name}' synced successfully${NC}"
    else
        echo -e "${YELLOW}    ⚠ Stream '${stream_name}' sync returned HTTP ${HTTP_CODE}${NC}"
        if [ -n "$BODY" ]; then
            echo -e "${YELLOW}    Response: ${BODY}${NC}"
        fi
    fi
done

echo -e "${GREEN}✅ Stream sync completed${NC}"

