#!/bin/bash
set -e

# This script downloads necessary assets for Liberoute.
# It accepts a --force flag to re-download files even if they exist.

# --- Setup ---
# Get the absolute path of this script's directory
SCRIPT_DIR_HELPER=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# The project root is one level up from the lib/ directory
PROJECT_ROOT="$SCRIPT_DIR_HELPER/../.."
ENV_PATH="$PROJECT_ROOT/.env"

if [ ! -f "$ENV_PATH" ]; then
    echo "❌ ERROR: .env file not found at '$ENV_PATH'." >&2
    exit 1
fi
source "$ENV_PATH"

# --- Check for a force flag ---
FORCE_DOWNLOAD=false
if [ "$1" == "--force" ]; then
    FORCE_DOWNLOAD=true
fi

# Ensure the target directory exists
if [ -z "${GEOIP_DIR-}" ]; then
    echo "❌ ERROR: GEOIP_DIR is not defined in your .env file." >&2
    exit 1
fi
mkdir -p "$GEOIP_DIR"

# Define assets to download: "URL|destination_filename"
ASSETS=(
    "https://github.com/SagerNet/sing-geoip/releases/latest/download/geoip.db|geoip.db"
    "https://github.com/SagerNet/sing-geosite/releases/latest/download/geosite.db|geosite.db"
)

echo "⬇️  Checking for required GeoIP assets..."

for asset in "${ASSETS[@]}"; do
    IFS='|' read -r url filename <<< "$asset"
    dest_path="$GEOIP_DIR/$filename"

    # Check if we should download
    if [ "$FORCE_DOWNLOAD" = true ] || [ ! -f "$dest_path" ]; then
        if [ "$FORCE_DOWNLOAD" = true ]; then
             echo "  -> Force downloading '$filename'..."
        else
             echo "  -> Downloading missing asset '$filename'..."
        fi
        
        # Download to a temporary file first
        if curl -L --fail --show-error -o "$dest_path.tmp" "$url"; then
            mv "$dest_path.tmp" "$dest_path"
            echo "  -> Download complete: '$dest_path'"
        else
            echo "❌ ERROR: Failed to download '$filename' from $url." >&2
            # Clean up temp file on failure
            rm -f "$dest_path.tmp"
        fi
    else
        echo "✅ '$filename' already exists. Skipping download. Use 'update geo' to force."
    fi
done
