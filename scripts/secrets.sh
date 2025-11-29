#!/bin/bash
# Unified secrets management script using SOPS

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGE_KEY_FILE="${SCRIPT_DIR}/../.age-key-local"
SECRETS_FILE="${SCRIPT_DIR}/../secrets.encrypted.yaml"

# Function to load age key and execute SOPS command
sops_cmd() {
    # Load age key from file or environment
    if [[ -z "$SOPS_AGE_KEY" ]] && [[ -f "$AGE_KEY_FILE" ]]; then
        export SOPS_AGE_KEY=$(cat "$AGE_KEY_FILE")
    fi
    
    # Execute SOPS command with remaining arguments
    sops "$@" || exit $?
}

# Main command handler
command="$1"
shift || true

case "$command" in
    get)
        if [[ -z "$1" ]]; then
            echo "Usage: $0 get <key>" >&2
            exit 1
        fi
        KEY="$1"
        JSON_PATH="[\"${KEY}\"]"
        sops_cmd -d --extract "$JSON_PATH" "$SECRETS_FILE"
        echo
        ;;
    
    set)
        if [[ -z "$1" ]] || [[ -z "$2" ]]; then
            echo "Usage: $0 set <key> <value>" >&2
            exit 1
        fi
        KEY="$1"
        VALUE="$2"
        
        # Create secrets.encrypted.yaml if it doesn't exist
        if [[ ! -f "$SECRETS_FILE" ]]; then
            SOPS_CONFIG="${SCRIPT_DIR}/../.sops.yaml"
            if [[ ! -f "$SOPS_CONFIG" ]]; then
                echo "Error: .sops.yaml not found. Please run deploy.sh first to set up encryption." >&2
                exit 1
            fi
            # Create empty YAML file and encrypt it using SOPS
            # Use sops -e to encrypt an empty YAML structure
            echo "{}" | sops_cmd -e /dev/stdin > "$SECRETS_FILE" 2>&1 || {
                echo "Error: Failed to create secrets.encrypted.yaml" >&2
                exit 1
            }
        fi
        
        sops_cmd set "$SECRETS_FILE" "[\"${KEY}\"]" "\"${VALUE}\""
        echo "✓ Set ${KEY}"
        ;;
    
    delete|unset)
        if [[ -z "$1" ]]; then
            echo "Usage: $0 delete <key>" >&2
            exit 1
        fi
        KEY="$1"
        sops_cmd unset "$SECRETS_FILE" "[\"${KEY}\"]"
        echo "✓ Deleted ${KEY}"
        ;;
    
    list)
        sops_cmd -d "$SECRETS_FILE" 2>/dev/null | grep -E '^[^#:]+:' | cut -d: -f1 | sort
        ;;
    
    edit)
        sops_cmd "$SECRETS_FILE"
        ;;
    
    dump)
        sops_cmd -d "$SECRETS_FILE"
        ;;
    
    add-recipient)
        if [[ -z "$1" ]]; then
            echo "Usage: $0 add-recipient <public-key>" >&2
            exit 1
        fi
        PUBLIC_KEY="$1"
        SOPS_CONFIG="${SCRIPT_DIR}/../.sops.yaml"
        
        if [[ ! -f "$SOPS_CONFIG" ]]; then
            echo "Error: .sops.yaml not found at $SOPS_CONFIG" >&2
            exit 1
        fi
        
        # Check if key is already present
        if grep -q "$PUBLIC_KEY" "$SOPS_CONFIG" 2>/dev/null; then
            echo "✓ Public key already in .sops.yaml"
            exit 0
        fi
        
        # Add the key to the age recipients list
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|age: >-|age: >-\\n      ${PUBLIC_KEY},|" "$SOPS_CONFIG"
        else
            sed -i "s|age: >-|age: >-\\n      ${PUBLIC_KEY},|" "$SOPS_CONFIG"
        fi
        
        echo "✓ Added recipient to .sops.yaml"
        # Note: Secrets will be automatically re-encrypted when next edited
        ;;
    
    *)
        echo "Usage: $0 <command> [args...]" >&2
        echo "" >&2
        echo "Commands:" >&2
        echo "  get <key>              Get a secret value" >&2
        echo "  set <key> <value>      Set a secret value" >&2
        echo "  delete <key>           Delete a secret" >&2
        echo "  list                   List all secret keys" >&2
        echo "  edit                   Edit all secrets in editor" >&2
        echo "  dump                   Dump all secrets (decrypted)" >&2
        echo "  add-recipient <key>    Add a recipient to .sops.yaml" >&2
        exit 1
        ;;
esac

