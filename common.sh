#!/bin/bash
# Common utility functions for setup scripts

# Define colors if not already defined
if [[ -z "${GREEN:-}" ]]; then
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    NC='\033[0m' # No Color
fi

# Function to get config value from environment or prompt user
# Usage: get_config_value VAR_NAME "Prompt message" "Error message if empty"
get_config_value() {
    local var_name="$1"
    local prompt_msg="$2"
    local error_msg="$3"
    local var_value="${!var_name}"
    
    if [[ -z "$var_value" ]]; then
        if [ -t 0 ]; then # Check if stdin is a terminal
            read -p "$prompt_msg: " var_value < /dev/tty
            if [[ -z "$var_value" ]]; then
                echo -e "${RED}${error_msg}${NC}" >&2
                exit 1
            fi
        else
            # Non-interactive, variable not set, exit
            echo -e "${RED}Error: ${var_name} is required and not set in non-interactive mode.${NC}" >&2
            exit 1
        fi
    else
        echo -e "${GREEN}Using ${var_name} from environment: ${var_value}${NC}"
    fi
    
    # Export the value back to the variable name
    eval "$var_name=\"$var_value\""
}

# Function to check if a service is active
# Usage: is_service_active SERVICE_NAME
is_service_active() {
    local service_name="$1"
    systemctl is-active --quiet "$service_name" 2>/dev/null
}

# Function to check if a port is listening
# Usage: is_port_listening PORT
is_port_listening() {
    local port="$1"
    if command -v ss > /dev/null 2>&1; then
        ss -tuln 2>/dev/null | grep -q ":${port} "
    elif command -v netstat > /dev/null 2>&1; then
        netstat -tuln 2>/dev/null | grep -q ":${port} "
    else
        # Fallback: try to connect to the port
        timeout 1 bash -c "echo > /dev/tcp/localhost/${port}" 2>/dev/null
    fi
}

# Function to wait for DNS record to resolve
# Usage: wait_for_dns DOMAIN EXPECTED_IP [MAX_WAIT_SECONDS]
wait_for_dns() {
    local domain="$1"
    local expected_ip="$2"
    local max_wait="${3:-300}"  # Default 5 minutes
    local elapsed=0
    
    if [[ -z "$expected_ip" ]]; then
        echo -e "${YELLOW}Could not detect server IP, skipping DNS check.${NC}"
        return 0
    fi
    
    echo -e "${BLUE}Waiting for DNS record to propagate...${NC}"
    while [ "$elapsed" -lt "$max_wait" ]; do
        local resolved_ip=""
        
        if command -v dig > /dev/null 2>&1; then
            resolved_ip=$(dig +short "${domain}" @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
        elif command -v host > /dev/null 2>&1; then
            resolved_ip=$(host "${domain}" 8.8.8.8 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
        else
            resolved_ip=$(nslookup "${domain}" 8.8.8.8 2>/dev/null | grep -A1 "Name:" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
        fi
        
        if [[ -n "$resolved_ip" ]] && [[ "$resolved_ip" == "$expected_ip" ]]; then
            echo -e "${GREEN}DNS record is correctly configured!${NC}"
            return 0
        fi
        
        echo -e "${YELLOW}DNS not ready yet (resolved to: ${resolved_ip:-not found}), waiting 5 seconds...${NC}"
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    echo -e "${YELLOW}DNS check timed out after ${max_wait} seconds${NC}"
    return 1
}

# Function to check service health
# Usage: check_service_health SERVICE_NAME PORT [DESCRIPTION]
check_service_health() {
    local service_name="$1"
    local port="$2"
    local description="${3:-$service_name}"
    local service_ok=false
    local port_ok=false
    
    if is_service_active "$service_name"; then
        echo -e "${GREEN}✓ ${description} service is running${NC}"
        service_ok=true
    else
        echo -e "${RED}✗ ${description} service is not running${NC}"
    fi
    
    if [[ -n "$port" ]]; then
        if is_port_listening "$port"; then
            echo -e "${GREEN}✓ ${description} is listening on port ${port}${NC}"
            port_ok=true
        else
            echo -e "${RED}✗ ${description} is not listening on port ${port}${NC}"
        fi
    fi
    
    if [[ "$service_ok" = true ]] && ([[ -z "$port" ]] || [[ "$port_ok" = true ]]); then
        return 0
    else
        return 1
    fi
}

# Function to ensure service is running
# Usage: ensure_service_running SERVICE_NAME PORT [DESCRIPTION]
ensure_service_running() {
    local service_name="$1"
    local port="$2"
    local description="${3:-$service_name}"
    
    if is_service_active "$service_name" && ([[ -z "$port" ]] || is_port_listening "$port"); then
        return 0
    fi
    
    echo -e "${YELLOW}Starting ${description}...${NC}"
    systemctl daemon-reload
    systemctl enable "$service_name" > /dev/null 2>&1 || true
    
    if ! is_service_active "$service_name"; then
        systemctl start "$service_name" || return 1
    fi
    
    # Wait for service to start
    local max_wait=10
    local waited=0
    while [ "$waited" -lt "$max_wait" ]; do
        if is_service_active "$service_name" && ([[ -z "$port" ]] || is_port_listening "$port"); then
            echo -e "${GREEN}${description} is running${NC}"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    
    return 1
}

# Function to send email via Resend API
# Usage: send_resend_email FROM TO SUBJECT TEXT [API_KEY]
send_resend_email() {
    local from="$1"
    local to="$2"
    local subject="$3"
    local text="$4"
    local api_key="${5:-$RESEND_API_KEY}"
    
    if [[ -z "$api_key" ]]; then
        echo "Error: RESEND_API_KEY is required" >&2
        return 1
    fi
    
    local response
    response=$(curl -s --max-time 10 -X POST https://api.resend.com/emails \
        -H "Authorization: Bearer ${api_key}" \
        -H "Content-Type: application/json" \
        -d "{
            \"from\": \"${from}\",
            \"to\": [\"${to}\"],
            \"subject\": \"${subject}\",
            \"text\": \"${text}\"
        }" 2>/dev/null)
    
    if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
        echo "$response" | jq -r '.id'
        return 0
    else
        echo "$response" >&2
        return 1
    fi
}

# Function to check HTTPS endpoint
# Usage: check_https_endpoint URL [EXPECTED_CODES]
check_https_endpoint() {
    local url="$1"
    local expected_codes="${2:-200,201,404}"
    local http_code
    
    http_code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    
    if [[ "$http_code" = "000" ]]; then
        echo -e "${YELLOW}⚠ HTTPS endpoint is not reachable${NC}"
        return 1
    fi
    
    # Check if code is in expected list
    if [[ ",${expected_codes}," =~ ,${http_code}, ]]; then
        if [[ "$http_code" = "404" ]]; then
            echo -e "${GREEN}✓ HTTPS endpoint is reachable (HTTP 404 is expected)${NC}"
        else
            echo -e "${GREEN}✓ HTTPS endpoint is reachable (HTTP ${http_code})${NC}"
        fi
        return 0
    else
        echo -e "${YELLOW}⚠ HTTPS endpoint returned HTTP ${http_code}${NC}"
        return 1
    fi
}

# Function to create file backup
# Usage: backup_file FILE_PATH
backup_file() {
    local file_path="$1"
    local backup_path="${file_path}.bak.$(date +%s)"
    
    if [[ ! -f "$file_path" ]]; then
        return 1
    fi
    
    cp "$file_path" "$backup_path"
    echo "$backup_path"
}

# Function to restore file from backup
# Usage: restore_file FILE_PATH BACKUP_PATH
restore_file() {
    local file_path="$1"
    local backup_path="$2"
    
    if [[ ! -f "$backup_path" ]]; then
        return 1
    fi
    
    cp "$backup_path" "$file_path"
    return 0
}

