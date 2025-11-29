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

