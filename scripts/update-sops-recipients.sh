#!/bin/bash
# Helper script to add a public key to .sops.yaml recipients list

set -e

SCRIPT_DIR="${1:-$(pwd)}"
PUBLIC_KEY="$2"
SOPS_FILE="${SCRIPT_DIR}/.sops.yaml"

if [[ -z "$PUBLIC_KEY" ]]; then
    echo "Usage: $0 <script_dir> <public_key>"
    exit 1
fi

# Check if key is already in the file
if grep -q "$PUBLIC_KEY" "$SOPS_FILE" 2>/dev/null; then
    exit 0  # Already present
fi

# Extract existing keys (all lines starting with age1)
EXISTING_KEYS=$(grep -E "^[[:space:]]*age1[a-z0-9]+" "$SOPS_FILE" 2>/dev/null | sed 's/^[[:space:]]*//;s/,$//' | tr '\n' ',' | sed 's/,$//' || true)

# Build recipients list
if [[ -n "$EXISTING_KEYS" ]]; then
    NEW_RECIPIENTS="${EXISTING_KEYS},${PUBLIC_KEY}"
else
    NEW_RECIPIENTS="$PUBLIC_KEY"
fi

# Create a temporary file with updated recipients
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

# Replace the age recipients section
awk -v new_keys="$NEW_RECIPIENTS" '
    /age: >-/ {
        print "    age: >-"
        # Split comma-separated keys and print each on a new line
        n = split(new_keys, keys, ",")
        for (i = 1; i <= n; i++) {
            print "      " keys[i] (i < n ? "," : "")
        }
        next
    }
    /^[[:space:]]*age1[a-z0-9]+/ {
        next  # Skip old key lines
    }
    { print }
' "$SOPS_FILE" > "$TEMP_FILE"

# Replace original file
mv "$TEMP_FILE" "$SOPS_FILE"

