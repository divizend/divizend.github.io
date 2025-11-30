#!/bin/bash
# Unified secrets management script using SOPS
# This script is a thin wrapper around functions in common.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "${SCRIPT_DIR}/common.sh"

# Main command handler
command="$1"
shift || true

case "$command" in
    get)
        if [[ -z "$1" ]]; then
            log_error "Usage: $0 get <key>"
            exit 1
        fi
        secrets_get "$1"
        ;;
    
    set)
        if [[ -z "$1" ]] || [[ -z "$2" ]]; then
            log_error "Usage: $0 set <key> <value>"
            exit 1
        fi
        secrets_set "$1" "$2"
        ;;
    
    delete|unset)
        if [[ -z "$1" ]]; then
            log_error "Usage: $0 delete <key>"
            exit 1
        fi
        secrets_delete "$1"
        ;;
    
    list)
        secrets_list
        ;;
    
    edit)
        secrets_edit
        ;;
    
    dump)
        secrets_dump
        ;;
    
    add-recipient)
        if [[ -z "$1" ]]; then
            log_error "Usage: $0 add-recipient <public-key>"
            exit 1
        fi
        secrets_add_recipient "$1"
        ;;
    
    *)
        log_error "Usage: $0 <command> [args...]"
        log_error ""
        log_error "Commands:"
        log_error "  get <key>              Get a secret value"
        log_error "  set <key> <value>      Set a secret value"
        log_error "  delete <key>           Delete a secret"
        log_error "  list                   List all secret keys"
        log_error "  edit                   Edit all secrets in editor"
        log_error "  dump                   Dump all secrets (decrypted)"
        log_error "  add-recipient <key>    Add a recipient to .sops.yaml"
        exit 1
        ;;
esac

