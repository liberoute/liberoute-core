#!/bin/bash
set -e

# This script establishes the connection using a dynamically generated config.

# --- Setup ---
# Get the absolute path of this script's directory
SCRIPT_DIR_HELPER=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
PROJECT_ROOT="$SCRIPT_DIR_HELPER/../.."
ENV_PATH="$PROJECT_ROOT/.env"

# Source the environment file to get necessary variables
if [ ! -f "$ENV_PATH" ]; then
    echo "❌ FATAL: .env file not found." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$ENV_PATH"

# This script calculates the path to the state file itself for robustness.
LAST_SELECTED_LINK_FILE="$PROJECT_ROOT/data/.last_selected_link"

# --- Main Logic ---
if [ ! -f "$LAST_SELECTED_LINK_FILE" ]; then
    echo "❌ ERROR: No active link selected. Please run 'liberoute select' first." >&2
    exit 1
fi

SELECTED_LINK=$(cat "$LAST_SELECTED_LINK_FILE")
if [ -z "$SELECTED_LINK" ]; then
    echo "❌ ERROR: The selected link file is empty. Please run 'liberoute select' again." >&2
    exit 1
fi

echo "🚀 Generating config for selected link..."
# The config generator also needs to be self-reliant on finding the project root
TEMP_CONFIG_FILE=$(bash "$LIB_DIR/profile/config_generator.sh" "$SELECTED_LINK")

# Ensure the temporary config file is cleaned up on exit
trap 'rm -f "$TEMP_CONFIG_FILE"' EXIT

echo "✅ Config generated at '$TEMP_CONFIG_FILE'. Starting connection..."

# Set Time
source "$LIB_DIR/system/set_time.sh"

# Load network check script AFTER basic validation
source "$LIB_DIR/system/network_check.sh"

# Parse DNS list
IFS=',' read -ra DNS <<< "$DNS_SERVERS"
DNS_ARGS=()
for dns in "${DNS[@]}"; do
  DNS_ARGS+=(--dns="$dns")
done

# Clean up any existing jail
firejail --shutdown="$NAME_SPACE" || true

# Launch selected core (sing-box default)
case "$CORE" in
  sing-box)
    exec firejail --noprofile --net="$eth" --ip="$IP" --defaultgw="$GATEWAY" --name="$NAME_SPACE" "${DNS_ARGS[@]}" \
      sing-box run -c "$TEMP_CONFIG_FILE"
    ;;
  xray|xray-core)
    exec firejail --noprofile --net="$eth" --ip="$IP" --defaultgw="$GATEWAY" --name="$NAME_SPACE" "${DNS_ARGS[@]}" \
      xray run -c "$TEMP_CONFIG_FILE"
    ;;
  v2ray|v2ray-core)
    exec firejail --noprofile --net="$eth" --ip="$IP" --defaultgw="$GATEWAY" --name="$NAME_SPACE" "${DNS_ARGS[@]}" \
      v2ray run -c "$TEMP_CONFIG_FILE"
    ;;
  *)
    echo "❌ Unknown CORE: $CORE" >&2; exit 1;;
esac
