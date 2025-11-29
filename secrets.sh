#!/bin/bash
# Unified secrets management script using SOPS

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="${SCRIPT_DIR}/secrets.encrypted.yaml"

# Source common functions
source "${SCRIPT_DIR}/common.sh"

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
        create_secrets_file_if_needed || exit 1
        
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
        add_sops_recipient "$PUBLIC_KEY" || exit 1
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

