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

# Logging system
# LOG_LEVEL can be: DEBUG, INFO, WARN, ERROR
# Defaults to DEBUG if not set
LOG_LEVEL="${LOG_LEVEL:-DEBUG}"

# Function to get numeric log level
# Usage: get_log_level_numeric LEVEL
get_log_level_numeric() {
    case "$1" in
        DEBUG) echo 0 ;;
        INFO)  echo 1 ;;
        WARN)  echo 2 ;;
        ERROR) echo 3 ;;
        *)     echo 0 ;; # Default to DEBUG
    esac
}

# Function to check if log level should be output
# Usage: should_log LEVEL
should_log() {
    local level="$1"
    local current_level_num=$(get_log_level_numeric "$LOG_LEVEL")
    local requested_level_num=$(get_log_level_numeric "$level")
    [[ $requested_level_num -ge $current_level_num ]]
}

# Unified logging function
# Usage: log LEVEL MESSAGE [STDERR]
# LEVEL: DEBUG, INFO, WARN, ERROR
# MESSAGE: The message to log
# STDERR: If set to "1", output to stderr instead of stdout
log() {
    local level="$1"
    shift
    local message="$*"
    local output_fd=1
    
    # Check if we should output this level
    if ! should_log "$level"; then
        return 0
    fi
    
    # Determine output stream and color
    local color=""
    local prefix=""
    case "$level" in
        DEBUG)
            color="${BLUE}"
            prefix="[DEBUG]"
            ;;
        INFO)
            color="${GREEN}"
            prefix="[INFO]"
            ;;
        WARN)
            color="${YELLOW}"
            prefix="[WARN]"
            output_fd=2
            ;;
        ERROR)
            color="${RED}"
            prefix="[ERROR]"
            output_fd=2
            ;;
        *)
            color="${NC}"
            prefix="[LOG]"
            ;;
    esac
    
    # Output the message
    echo -e "${color}${prefix} ${message}${NC}" >&$output_fd
}

# Convenience functions for each log level
log_debug() { log DEBUG "$@"; }
log_info() { log INFO "$@"; }
log_warn() { log WARN "$@"; }
log_error() { log ERROR "$@"; }

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
    log_error "Could not load age key"
    log_debug "Checked the following paths:"
    for path in "${checked_paths[@]}"; do
        log_debug "  - ${path}"
    done
    return 1
}

# Function to extract public key from age key file
# Usage: extract_age_public_key AGE_KEY_FILE
extract_age_public_key() {
    local age_key_file="$1"
    if [[ ! -f "$age_key_file" ]]; then
        log_error "Age key file not found: ${age_key_file}"
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
        log_debug "Using existing ${key_name}"
        return 0
    fi
    
    log_info "🔑 Generating ${key_name}..."
    if ! command -v age-keygen &> /dev/null; then
        log_error "age-keygen is not installed"
        return 1
    fi
    
    age-keygen -o "$age_key_file"
    log_info "✓ ${key_name} created at ${age_key_file}"
    if [[ "$key_name" == *"local"* ]]; then
        log_warn "⚠ Keep this file secure and never commit it to git"
    fi
    return 0
}

# Function to ensure .sops.yaml exists with initial configuration
# Usage: ensure_sops_config [PUBLIC_KEY]
# If PUBLIC_KEY is provided, uses it as the initial recipient
# If not provided and .sops.yaml doesn't exist, tries to get public key from .age-key-local
ensure_sops_config() {
    local public_key="${1:-}"
    local script_dir=$(get_script_dir)
    local sops_config="${script_dir}/.sops.yaml"
    local age_key_file="${script_dir}/.age-key-local"
    
    if [[ -f "$sops_config" ]]; then
        return 0
    fi
    
    # If no public key provided, try to get it from age key file
    if [[ -z "$public_key" ]] && [[ -f "$age_key_file" ]]; then
        public_key=$(extract_age_public_key "$age_key_file")
    fi
    
    log_debug "⚠ .sops.yaml not found, creating it..."
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
        log_error "Public key is required"
        return 1
    fi
    
    if [[ ! -f "$sops_config" ]]; then
        log_error ".sops.yaml not found at ${sops_config}"
        return 1
    fi
    
    # Check if key is already present
    if grep -q "$public_key" "$sops_config" 2>/dev/null; then
        log_debug "✓ Public key already in .sops.yaml"
        return 0
    fi
    
    # Add the key to the age recipients list
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|age: >-|age: >-\\n      ${public_key},|" "$sops_config"
    else
        sed -i "s|age: >-|age: >-\\n      ${public_key},|" "$sops_config"
    fi
    
    log_debug "✓ Added recipient to .sops.yaml"
    return 0
}

# Helper function to check if we should be quiet (called from secrets.sh)
# Usage: is_secrets_quiet
is_secrets_quiet() {
    # Check if we're being called from secrets.sh by checking the call stack
    local i=0
    while [[ $i -lt 10 ]]; do
        local source_file="${BASH_SOURCE[$i]:-}"
        if [[ -n "$source_file" ]]; then
            local basename_file=$(basename "$source_file" 2>/dev/null || echo "")
            if [[ "$basename_file" == "secrets.sh" ]]; then
                return 0  # Yes, be quiet
            fi
        fi
        i=$((i + 1))
    done
    return 1  # No, be verbose
}

# Function to ensure all prerequisites for secrets operations exist
# Usage: ensure_secrets_prerequisites [QUIET]
# Creates: .age-key-local, .sops.yaml, and ensures secrets.encrypted.yaml can be created
# This function should be called before any secrets operation
# If QUIET is set or called from secrets.sh, suppresses debug messages
ensure_secrets_prerequisites() {
    local quiet="${1:-}"
    local script_dir=$(get_script_dir)
    local age_key_file="${script_dir}/.age-key-local"
    local sops_config="${script_dir}/.sops.yaml"
    
    # Auto-detect quiet mode if not explicitly set
    if [[ -z "$quiet" ]] && is_secrets_quiet; then
        quiet="1"
    fi
    
    # Step 1: Ensure age keypair exists
    if [[ -n "$quiet" ]]; then
        ensure_age_keypair "$age_key_file" "local age keypair" > /dev/null 2>&1 || return 1
    else
        ensure_age_keypair "$age_key_file" "local age keypair" || return 1
    fi
    
    # Step 2: Extract public key
    local public_key=$(extract_age_public_key "$age_key_file")
    if [[ -z "$public_key" ]]; then
        log_error "Could not extract public key from ${age_key_file}"
        return 1
    fi
    
    # Step 3: Ensure .sops.yaml exists with the public key
    if [[ ! -f "$sops_config" ]]; then
        if [[ -n "$quiet" ]]; then
            ensure_sops_config "$public_key" > /dev/null 2>&1 || return 1
        else
            ensure_sops_config "$public_key" || return 1
        fi
    else
        # Ensure the public key is in .sops.yaml
        if ! grep -q "$public_key" "$sops_config" 2>/dev/null; then
            if [[ -n "$quiet" ]]; then
                add_sops_recipient "$public_key" > /dev/null 2>&1 || return 1
            else
                add_sops_recipient "$public_key" || return 1
            fi
        fi
    fi
    
    # Step 4: Ensure age key is loaded for SOPS operations
    if [[ -n "$quiet" ]]; then
        ensure_sops_age_key "$age_key_file" > /dev/null 2>&1 || return 1
    else
        ensure_sops_age_key "$age_key_file" || return 1
    fi
    
    return 0
}

# Function to create secrets.encrypted.yaml if it doesn't exist
# Usage: create_secrets_file_if_needed [QUIET]
# Automatically ensures prerequisites exist before creating the file
# If QUIET is set or called from secrets.sh, suppresses debug messages
create_secrets_file_if_needed() {
    local quiet="${1:-}"
    local script_dir=$(get_script_dir)
    local secrets_file="${script_dir}/secrets.encrypted.yaml"
    
    if [[ -f "$secrets_file" ]]; then
        return 0
    fi
    
    # Auto-detect quiet mode if not explicitly set
    if [[ -z "$quiet" ]] && is_secrets_quiet; then
        quiet="1"
    fi
    
    # Ensure all prerequisites exist first
    if [[ -n "$quiet" ]]; then
        ensure_secrets_prerequisites "$quiet" || {
            log_error "Could not set up secrets prerequisites"
            return 1
        }
    else
        ensure_secrets_prerequisites || {
            log_error "Could not set up secrets prerequisites"
            return 1
        }
    fi
    
    # Create empty YAML file first, then encrypt it using SOPS
    # SOPS needs the file path to match against path_regex in .sops.yaml
    local temp_file="${secrets_file}.tmp"
    echo "{}" > "$temp_file"
    
    # Use sops_cmd to encrypt the file in place
    # SOPS will use the file path to match against path_regex in .sops.yaml
    if sops_cmd -e -i "$temp_file" 2>&1 > /dev/null; then
        mv "$temp_file" "$secrets_file"
        if [[ -z "$quiet" ]]; then
            log_info "✓ Created secrets.encrypted.yaml"
        fi
        return 0
    else
        rm -f "$temp_file"
        # Try alternative: create file with correct name in same directory
        echo "{}" > "$secrets_file"
        if sops_cmd -e -i "$secrets_file" 2>&1 > /dev/null; then
            if [[ -z "$quiet" ]]; then
                log_info "✓ Created secrets.encrypted.yaml"
            fi
            return 0
        else
            rm -f "$secrets_file"
            log_error "Failed to create secrets.encrypted.yaml"
            if [[ -z "$quiet" ]]; then
                log_debug "Check that .sops.yaml is properly configured and age key is available"
            fi
            return 1
        fi
    fi
}

# Function to execute SOPS command with proper key setup
# Usage: sops_cmd [SOPS_ARGS...]
# Automatically loads age key and sets up environment
sops_cmd() {
    # Ensure age key is loaded (error message is already printed by ensure_sops_age_key)
    ensure_sops_age_key || {
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
            log_error "Could not decrypt secrets.encrypted.yaml"
            log_error "This indicates a problem with the encryption keys."
            return 1
        fi
        # File doesn't have SOPS metadata - silently skip (will be created during setup)
        rm -f "$temp_secrets"
    fi
}

# Unified secrets operation functions
# These functions ensure prerequisites exist and handle all secrets operations

# Function to get a secret value
# Usage: secrets_get KEY
secrets_get() {
    local key="$1"
    local script_dir=$(get_script_dir)
    local secrets_file="${script_dir}/secrets.encrypted.yaml"
    local quiet=""
    
    if is_secrets_quiet; then
        quiet="1"
    fi
    
    if [[ -z "$key" ]]; then
        log_error "Key is required"
        return 1
    fi
    
    # Ensure prerequisites exist
    ensure_secrets_prerequisites "$quiet" || return 1
    create_secrets_file_if_needed "$quiet" || return 1
    
    # Extract value using SOPS
    local json_path="[\"${key}\"]"
    sops_cmd -d --extract "$json_path" "$secrets_file" 2>/dev/null
    echo
}

# Function to set a secret value
# Usage: secrets_set KEY VALUE
secrets_set() {
    local key="$1"
    local value="$2"
    local script_dir=$(get_script_dir)
    local secrets_file="${script_dir}/secrets.encrypted.yaml"
    local quiet=""
    
    if is_secrets_quiet; then
        quiet="1"
    fi
    
    if [[ -z "$key" ]] || [[ -z "$value" ]]; then
        log_error "Key and value are required"
        return 1
    fi
    
    # Ensure prerequisites exist
    ensure_secrets_prerequisites "$quiet" || return 1
    create_secrets_file_if_needed "$quiet" || return 1
    
    # Set value using SOPS
    sops_cmd set "$secrets_file" "[\"${key}\"]" "\"${value}\"" > /dev/null 2>&1 || return 1
    log_info "✓ Set ${key}"
}

# Function to delete a secret
# Usage: secrets_delete KEY
secrets_delete() {
    local key="$1"
    local script_dir=$(get_script_dir)
    local secrets_file="${script_dir}/secrets.encrypted.yaml"
    local quiet=""
    
    if is_secrets_quiet; then
        quiet="1"
    fi
    
    if [[ -z "$key" ]]; then
        log_error "Key is required"
        return 1
    fi
    
    # Ensure prerequisites exist
    ensure_secrets_prerequisites "$quiet" || return 1
    
    # Check if file exists
    if [[ ! -f "$secrets_file" ]]; then
        log_error "secrets.encrypted.yaml does not exist"
        return 1
    fi
    
    # Delete key using SOPS
    sops_cmd unset "$secrets_file" "[\"${key}\"]" > /dev/null 2>&1 || return 1
    log_info "✓ Deleted ${key}"
}

# Function to list all secret keys
# Usage: secrets_list
secrets_list() {
    local script_dir=$(get_script_dir)
    local secrets_file="${script_dir}/secrets.encrypted.yaml"
    local quiet=""
    
    if is_secrets_quiet; then
        quiet="1"
    fi
    
    # Ensure prerequisites exist
    ensure_secrets_prerequisites "$quiet" || return 1
    
    # Check if file exists
    if [[ ! -f "$secrets_file" ]]; then
        return 0  # Empty list if file doesn't exist
    fi
    
    # Decrypt and extract keys
    sops_cmd -d "$secrets_file" 2>/dev/null | grep -E '^[^#:]+:' | cut -d: -f1 | sort
}

# Function to dump all secrets (decrypted)
# Usage: secrets_dump
secrets_dump() {
    local script_dir=$(get_script_dir)
    local secrets_file="${script_dir}/secrets.encrypted.yaml"
    local quiet=""
    
    if is_secrets_quiet; then
        quiet="1"
    fi
    
    # Ensure prerequisites exist
    ensure_secrets_prerequisites "$quiet" || return 1
    
    # Check if file exists
    if [[ ! -f "$secrets_file" ]]; then
        echo "{}"
        return 0
    fi
    
    # Decrypt and output
    sops_cmd -d "$secrets_file" 2>/dev/null
}

# Function to edit secrets in editor
# Usage: secrets_edit
secrets_edit() {
    local script_dir=$(get_script_dir)
    local secrets_file="${script_dir}/secrets.encrypted.yaml"
    local quiet=""
    
    if is_secrets_quiet; then
        quiet="1"
    fi
    
    # Ensure prerequisites exist
    ensure_secrets_prerequisites "$quiet" || return 1
    create_secrets_file_if_needed "$quiet" || return 1
    
    # Open in editor
    sops_cmd "$secrets_file"
}

# Function to add a recipient to .sops.yaml
# Usage: secrets_add_recipient PUBLIC_KEY
secrets_add_recipient() {
    local public_key="$1"
    local quiet=""
    
    if is_secrets_quiet; then
        quiet="1"
    fi
    
    if [[ -z "$public_key" ]]; then
        log_error "Public key is required"
        return 1
    fi
    
    # Ensure prerequisites exist (creates .sops.yaml if needed)
    ensure_secrets_prerequisites "$quiet" || return 1
    
    # Add recipient
    if [[ -n "$quiet" ]]; then
        add_sops_recipient "$public_key" > /dev/null 2>&1 || return 1
    else
        add_sops_recipient "$public_key" || return 1
    fi
    
    # Note: Secrets will be automatically re-encrypted when next edited
    return 0
}

# Function to update SOPS encrypted secrets
# Usage: update_sops_secret VAR_NAME VAR_VALUE
# This is a convenience wrapper around secrets_set for use by get_config_value
update_sops_secret() {
    local var_name="$1"
    local var_value="$2"
    
    # Use the unified secrets_set function
    secrets_set "$var_name" "$var_value" > /dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        log_debug "✓ Updated ${var_name} in encrypted secrets"
    else
        log_warn "⚠ Failed to update ${var_name} in encrypted secrets"
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
        log_debug "Using ${var_name} from environment: ${var_value}"
        eval "$var_name=\"$var_value\""
        return 0
    fi
    
    # Try to load from encrypted secrets
    load_secrets_from_sops
    var_value="${!var_name}"
    
    # If variable now has a value from secrets, use it immediately
    if [[ -n "$var_value" ]]; then
        log_debug "Using ${var_name} from encrypted secrets"
        eval "$var_name=\"$var_value\""
        return 0
    fi
    
    # Variable is not set, need to get it from user or default
    if [[ -n "$default_value" ]]; then
        # Use default value if provided
        var_value="$default_value"
        log_debug "Using default ${var_name}: ${var_value}"
    elif [ -t 0 ]; then # Check if stdin is a terminal
        read -p "$prompt_msg: " var_value < /dev/tty
        if [[ -z "$var_value" ]] && [[ -n "$error_msg" ]]; then
            log_error "${error_msg}"
            exit 1
        fi
        if [[ -n "$var_value" ]]; then
            was_prompted=true
        fi
    else
        # Non-interactive, variable not set
        if [[ -n "$error_msg" ]]; then
            log_error "${var_name} is required and not set in non-interactive mode."
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
        log_warn "Could not detect server IP, skipping DNS check."
        return 0
    fi
    
    log_info "Waiting for DNS record to propagate..."
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
            log_info "DNS record is correctly configured!"
            return 0
        fi
        
        log_debug "DNS not ready yet (resolved to: ${resolved_ip:-not found}), waiting 5 seconds..."
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    log_warn "DNS check timed out after ${max_wait} seconds"
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
        log_info "✓ ${description} service is running"
        service_ok=true
    else
        log_error "✗ ${description} service is not running"
    fi
    
    if [[ -n "$port" ]]; then
        if is_port_listening "$port"; then
            log_info "✓ ${description} is listening on port ${port}"
            port_ok=true
        else
            log_error "✗ ${description} is not listening on port ${port}"
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
    
    log_info "Starting ${description}..."
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
            log_info "${description} is running"
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
        log_warn "⚠ HTTPS endpoint is not reachable"
        return 1
    fi
    
    # Check if code is in expected list
    if [[ ",${expected_codes}," =~ ,${http_code}, ]]; then
        if [[ "$http_code" = "404" ]]; then
            log_info "✓ HTTPS endpoint is reachable (HTTP 404 is expected)"
        else
            log_info "✓ HTTPS endpoint is reachable (HTTP ${http_code})"
        fi
        return 0
    else
        log_warn "⚠ HTTPS endpoint returned HTTP ${http_code}"
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
