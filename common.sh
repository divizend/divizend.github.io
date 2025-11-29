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

# Function to get script directory
get_script_dir() {
    if [[ -n "${SCRIPT_DIR:-}" ]]; then
        echo "${SCRIPT_DIR}"
    elif [[ -n "${BASH_SOURCE[1]:-}" ]]; then
        echo "$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    else
        echo "$(pwd)"
    fi
}

# Function to ensure SOPS age key is loaded and available
# Usage: ensure_sops_age_key [AGE_KEY_FILE]
# If AGE_KEY_FILE is provided, loads from that file
# Otherwise tries to load from .age-key-local or uses existing SOPS_AGE_KEY
ensure_sops_age_key() {
    local age_key_file="${1:-}"
    local script_dir=$(get_script_dir)
    local checked_paths=()
    
    # If SOPS_AGE_KEY_FILE is already set, we're good
    if [[ -n "$SOPS_AGE_KEY_FILE" ]] && [[ -f "$SOPS_AGE_KEY_FILE" ]]; then
        return 0
    fi
    if [[ -n "$SOPS_AGE_KEY_FILE" ]]; then
        checked_paths+=("SOPS_AGE_KEY_FILE: $SOPS_AGE_KEY_FILE (not found)")
    fi
    
    # If SOPS_AGE_KEY is already set, create temp file if needed
    if [[ -n "$SOPS_AGE_KEY" ]] && [[ -z "$SOPS_AGE_KEY_FILE" ]]; then
        local temp_key_file=$(mktemp)
        echo "$SOPS_AGE_KEY" > "$temp_key_file"
        export SOPS_AGE_KEY_FILE="$temp_key_file"
        return 0
    fi
    if [[ -z "$SOPS_AGE_KEY" ]]; then
        checked_paths+=("SOPS_AGE_KEY environment variable (not set)")
    fi
    
    # Try to load from provided file or default location
    if [[ -z "$age_key_file" ]]; then
        age_key_file="${script_dir}/.age-key-local"
    fi
    checked_paths+=("$age_key_file")
    
    if [[ -f "$age_key_file" ]]; then
        export SOPS_AGE_KEY=$(cat "$age_key_file")
        # Create temp file for SOPS_AGE_KEY_FILE
        local temp_key_file=$(mktemp)
        echo "$SOPS_AGE_KEY" > "$temp_key_file"
        export SOPS_AGE_KEY_FILE="$temp_key_file"
        return 0
    fi
    
    # Failed to find key - show what we checked
    echo -e "${RED}Error: Could not load age key${NC}" >&2
    echo -e "${YELLOW}Checked the following paths:${NC}" >&2
    for path in "${checked_paths[@]}"; do
        echo -e "  - ${path}" >&2
    done
    return 1
}

# Function to extract public key from age key file
# Usage: extract_age_public_key AGE_KEY_FILE
extract_age_public_key() {
    local age_key_file="$1"
    if [[ ! -f "$age_key_file" ]]; then
        echo -e "${RED}Error: Age key file not found: ${age_key_file}${NC}" >&2
        return 1
    fi
    # The public key is in a comment line like: # public key: age1...
    grep "^# public key:" "$age_key_file" | cut -d' ' -f4
}

# Function to ensure age keypair exists, generates if needed
# Usage: ensure_age_keypair AGE_KEY_FILE [KEY_NAME]
# KEY_NAME is optional, used for display messages
ensure_age_keypair() {
    local age_key_file="$1"
    local key_name="${2:-age keypair}"
    
    if [[ -f "$age_key_file" ]]; then
        echo -e "${GREEN}✓ Using existing ${key_name}${NC}"
        return 0
    fi
    
    echo -e "${BLUE}🔑 Generating ${key_name}...${NC}"
    if ! command -v age-keygen &> /dev/null; then
        echo -e "${RED}Error: age-keygen is not installed${NC}" >&2
        return 1
    fi
    
    age-keygen -o "$age_key_file"
    echo -e "${GREEN}✓ ${key_name} created at ${age_key_file}${NC}"
    if [[ "$key_name" == *"local"* ]]; then
        echo -e "${YELLOW}⚠ Keep this file secure and never commit it to git${NC}"
    fi
    return 0
}

# Function to ensure .sops.yaml exists with initial configuration
# Usage: ensure_sops_config [PUBLIC_KEY]
# If PUBLIC_KEY is provided, uses it as the initial recipient
ensure_sops_config() {
    local public_key="${1:-}"
    local script_dir=$(get_script_dir)
    local sops_config="${script_dir}/.sops.yaml"
    
    if [[ -f "$sops_config" ]]; then
        return 0
    fi
    
    echo -e "${YELLOW}⚠ .sops.yaml not found, creating it...${NC}"
    if [[ -n "$public_key" ]]; then
        cat > "$sops_config" <<EOF
# SOPS configuration for encrypting secrets
# This file supports multiple recipients (local, server, GitHub Actions)
# Each recipient can decrypt the secrets using their private key

creation_rules:
  - path_regex: secrets\.encrypted\.yaml$
    age: >-
      ${public_key}
    # Multiple age public keys (comma-separated):
    # 1. Local machine public key (for editing secrets locally)
    # 2. Server public key (for decrypting during setup.sh)
    # 3. GitHub Actions public key (for CI/CD)
    # Keys will be automatically added/updated by deploy.sh and setup.sh
EOF
    else
        cat > "$sops_config" <<EOF
# SOPS configuration for encrypting secrets
# This file supports multiple recipients (local, server, GitHub Actions)
# Each recipient can decrypt the secrets using their private key

creation_rules:
  - path_regex: secrets\.encrypted\.yaml$
    age: >-
    # Multiple age public keys (comma-separated):
    # 1. Local machine public key (for editing secrets locally)
    # 2. Server public key (for decrypting during setup.sh)
    # 3. GitHub Actions public key (for CI/CD)
    # Keys will be automatically added/updated by deploy.sh and setup.sh
EOF
    fi
}

# Function to add a recipient (public key) to .sops.yaml
# Usage: add_sops_recipient PUBLIC_KEY
add_sops_recipient() {
    local public_key="$1"
    local script_dir=$(get_script_dir)
    local sops_config="${script_dir}/.sops.yaml"
    
    if [[ -z "$public_key" ]]; then
        echo -e "${RED}Error: Public key is required${NC}" >&2
        return 1
    fi
    
    if [[ ! -f "$sops_config" ]]; then
        echo -e "${RED}Error: .sops.yaml not found at ${sops_config}${NC}" >&2
        return 1
    fi
    
    # Check if key is already present
    if grep -q "$public_key" "$sops_config" 2>/dev/null; then
        echo -e "${GREEN}✓ Public key already in .sops.yaml${NC}"
        return 0
    fi
    
    # Add the key to the age recipients list
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|age: >-|age: >-\\n      ${public_key},|" "$sops_config"
    else
        sed -i "s|age: >-|age: >-\\n      ${public_key},|" "$sops_config"
    fi
    
    echo -e "${GREEN}✓ Added recipient to .sops.yaml${NC}"
    return 0
}

# Function to create secrets.encrypted.yaml if it doesn't exist
# Usage: create_secrets_file_if_needed
create_secrets_file_if_needed() {
    local script_dir=$(get_script_dir)
    local secrets_file="${script_dir}/secrets.encrypted.yaml"
    local sops_config="${script_dir}/.sops.yaml"
    
    if [[ -f "$secrets_file" ]]; then
        return 0
    fi
    
    if [[ ! -f "$sops_config" ]]; then
        echo -e "${RED}Error: .sops.yaml not found. Please run deploy.sh first to set up encryption.${NC}" >&2
        return 1
    fi
    
    # Ensure age key is loaded
    ensure_sops_age_key || {
        echo -e "${RED}Error: Could not load age key for encryption${NC}" >&2
        return 1
    }
    
    # Create empty YAML file first, then encrypt it using SOPS
    # SOPS needs the file path to match against path_regex in .sops.yaml
    # Create temp file with the correct name so SOPS can match the creation rule
    local temp_file="${secrets_file}.tmp"
    echo "{}" > "$temp_file"
    
    # Use sops_cmd to encrypt the file in place
    # SOPS will use the file path to match against path_regex in .sops.yaml
    if sops_cmd -e -i "$temp_file" 2>&1; then
        mv "$temp_file" "$secrets_file"
        echo -e "${GREEN}✓ Created secrets.encrypted.yaml${NC}"
        return 0
    else
        rm -f "$temp_file"
        # Try alternative: create file with correct name in same directory
        echo "{}" > "$secrets_file"
        if sops_cmd -e -i "$secrets_file" 2>&1; then
            echo -e "${GREEN}✓ Created secrets.encrypted.yaml${NC}"
            return 0
        else
            rm -f "$secrets_file"
            echo -e "${RED}Error: Failed to create secrets.encrypted.yaml${NC}" >&2
            echo -e "${YELLOW}Debug: Check that .sops.yaml is properly configured and age key is available${NC}" >&2
            return 1
        fi
    fi
}

# Function to execute SOPS command with proper key setup
# Usage: sops_cmd [SOPS_ARGS...]
# Automatically loads age key and sets up environment
sops_cmd() {
    # Ensure age key is loaded
    ensure_sops_age_key || {
        echo -e "${RED}Error: Could not load age key${NC}" >&2
        return 1
    }
    
    # Execute SOPS command with remaining arguments
    sops "$@" || return $?
}

# Function to decrypt and load secrets from SOPS encrypted file
# Usage: load_secrets_from_sops
load_secrets_from_sops() {
    local script_dir=$(get_script_dir)
    local secrets_file="${script_dir}/secrets.encrypted.yaml"
    local temp_secrets=$(mktemp)
    
    # Check if SOPS is available
    if ! command -v sops &> /dev/null; then
        return 0  # Silently skip if SOPS not available
    fi
    
    # Check if secrets.encrypted.yaml exists
    if [[ ! -f "$secrets_file" ]]; then
        return 0  # Silently skip if file doesn't exist
    fi
    
    # Ensure age key is loaded
    ensure_sops_age_key || {
        return 0  # Silently skip if key not available
    }
    
    # Decrypt secrets
    if sops -d "$secrets_file" > "$temp_secrets" 2>&1; then
        # Parse YAML and export as environment variables
        # Use simple YAML parsing (key: "value" format)
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Skip comments and empty lines
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue
            
            # Match YAML key: "value" or key: value format
            if [[ "$line" =~ ^([^:]+):[[:space:]]*(.+)$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"
                
                # Remove leading/trailing whitespace
                key=$(echo "$key" | xargs)
                value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                
                # Remove quotes if present
                value=$(echo "$value" | sed 's/^"//;s/"$//' | sed "s/^'//;s/'$//")
                
                # Export as environment variable if not already set (env vars take precedence)
                if [[ -n "$key" ]] && [[ -n "$value" ]]; then
                    if [[ -z "${!key:-}" ]]; then
                        export "$key=$value"
                    fi
                fi
            fi
        done < "$temp_secrets"
        
        rm -f "$temp_secrets"
    else
        # If decryption failed, check if it's because the file isn't encrypted with SOPS
        if grep -q "^sops:" "$secrets_file" 2>/dev/null; then
            # File has SOPS metadata but decryption failed - this is an error
            echo -e "${RED}Error: Could not decrypt secrets.encrypted.yaml${NC}" >&2
            echo -e "${RED}This indicates a problem with the encryption keys.${NC}" >&2
            return 1
        fi
        # File doesn't have SOPS metadata - silently skip (will be created during setup)
        rm -f "$temp_secrets"
    fi
}

# Function to update SOPS encrypted secrets
# Usage: update_sops_secret VAR_NAME VAR_VALUE
update_sops_secret() {
    local var_name="$1"
    local var_value="$2"
    local script_dir=$(get_script_dir)
    local secrets_file="${script_dir}/secrets.encrypted.yaml"
    local sops_config="${script_dir}/.sops.yaml"
    local secrets_script="${script_dir}/scripts/secrets.sh"
    
    # Check if SOPS is available
    if ! command -v sops &> /dev/null; then
        return 0  # Silently skip if SOPS not available
    fi
    
    # Check if .sops.yaml exists
    if [[ ! -f "$sops_config" ]]; then
        return 0  # Silently skip if config doesn't exist
    fi
    
    # Create secrets.encrypted.yaml if it doesn't exist
    create_secrets_file_if_needed || return 0
    
    # Ensure age key is loaded
    ensure_sops_age_key || {
        return 0  # Silently skip if key not available
    }
    
    # Try to use scripts/secrets.sh if available (preferred method)
    if [[ -f "$secrets_script" ]] && [[ -x "$secrets_script" ]]; then
        if bash "$secrets_script" set "$var_name" "$var_value" > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Updated ${var_name} in encrypted secrets${NC}"
            return 0
        fi
    fi
    
    # Fallback: use sops directly with correct syntax
    # SOPS syntax: sops set secrets.encrypted.yaml '["key"]' "value"
    if sops_cmd set "$secrets_file" "[\"${var_name}\"]" "\"${var_value}\"" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Updated ${var_name} in encrypted secrets${NC}"
    else
        echo -e "${YELLOW}⚠ Failed to update ${var_name} in encrypted secrets${NC}" >&2
    fi
}

# Function to get config value from encrypted secrets, environment, or prompt user
# Usage: get_config_value VAR_NAME "Prompt message" "Error message if empty" [DEFAULT_VALUE]
# Priority: 1. Environment variable, 2. Encrypted secrets, 3. Prompt user, 4. Default value
# Automatically saves to SOPS secrets when a new value is entered
get_config_value() {
    local var_name="$1"
    local prompt_msg="$2"
    local error_msg="$3"
    local default_value="$4"
    local var_value="${!var_name}"
    local was_prompted=false
    local script_dir=$(get_script_dir)
    
    # If variable already has a value from environment, use it immediately
    if [[ -n "$var_value" ]]; then
        echo -e "${GREEN}Using ${var_name} from environment: ${var_value}${NC}"
        eval "$var_name=\"$var_value\""
        return 0
    fi
    
    # Try to load from encrypted secrets
    load_secrets_from_sops
    var_value="${!var_name}"
    
    # If variable now has a value from secrets, use it immediately
    if [[ -n "$var_value" ]]; then
        echo -e "${GREEN}Using ${var_name} from encrypted secrets${NC}"
        eval "$var_name=\"$var_value\""
        return 0
    fi
    
    # Variable is not set, need to get it from user or default
    if [[ -n "$default_value" ]]; then
        # Use default value if provided
        var_value="$default_value"
        echo -e "${GREEN}Using default ${var_name}: ${var_value}${NC}"
    elif [ -t 0 ]; then # Check if stdin is a terminal
        read -p "$prompt_msg: " var_value < /dev/tty
        if [[ -z "$var_value" ]] && [[ -n "$error_msg" ]]; then
            echo -e "${RED}${error_msg}${NC}" >&2
            exit 1
        fi
        if [[ -n "$var_value" ]]; then
            was_prompted=true
        fi
    else
        # Non-interactive, variable not set
        if [[ -n "$error_msg" ]]; then
            echo -e "${RED}Error: ${var_name} is required and not set in non-interactive mode.${NC}" >&2
            exit 1
        fi
        # If error_msg is empty, allow empty value (optional variable)
        var_value=""
    fi
    
    # Export the value back to the variable name
    eval "$var_name=\"$var_value\""
    
    # If value was prompted (user entered it manually) and is not empty, save to SOPS
    if [[ "$was_prompted" = true ]] && [[ -n "$var_value" ]]; then
        update_sops_secret "$var_name" "$var_value"
    fi
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
