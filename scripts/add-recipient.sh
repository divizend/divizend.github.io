#!/bin/bash
# Add a recipient (age public key) to .sops.yaml

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOPS_CONFIG="${SCRIPT_DIR}/../.sops.yaml"
PUBLIC_KEY="$1"

if [[ -z "$PUBLIC_KEY" ]]; then
    echo "Usage: $0 <public-key>" >&2
    exit 1
fi

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
echo "⚠ Remember to re-encrypt secrets with: npm run secrets:edit"

