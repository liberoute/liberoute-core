#!/bin/bash
set -e

# This script sets up the TUN container and transparent proxy.

# --- Setup ---
# Get the absolute path of this script's directory
SCRIPT_DIR_HELPER=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
PROJECT_ROOT="$SCRIPT_DIR_HELPER/../.."
ENV_PATH="$PROJECT_ROOT/.env"
# Define LIB_DIR directly based on the script's location for robustness.
LIB_DIR="$PROJECT_ROOT/lib"

if [ ! -f "$ENV_PATH" ]; then
    echo "❌ FATAL: .env file not found." >&2
    exit 1
fi
source "$ENV_PATH"

# Load network check script AFTER basic validation to get interface/IP info
# This will now work because LIB_DIR is guaranteed to be set correctly.
source "$LIB_DIR/system/network_check.sh"

# --- Main Logic ---
# Setup logging
mkdir -p "$LOG_DIR"
exec >> "$TUN_LOG_FILE" 2>&1
set -x

echo "🚀 [tunnel.sh] Starting TUN container with proxy routing..."

# Get the port of the FIRST inbound listener defined in the .env file.
# This avoids reading from a temporary or non-existent JSON file.
SOCKS_PORT=$(echo "$INBOUNDS" | jq -r '.[0].listen_port')
if [ -z "$SOCKS_PORT" ] || [ "$SOCKS_PORT" == "null" ]; then
    echo "❌ ERROR: Could not determine SOCKS port from INBOUNDS variable in .env file." >&2
    exit 1
fi

# The SOCKS proxy is running inside the 'connection' jail, so we use its IP.
SOCKS="socks5://$IP:$SOCKS_PORT"

# Print status to the log
{
  echo "--- Liberoute Tunnel Service ---"
  echo "Timestamp:		$(date)"
  echo "TUN Interface:		$TUN_NAME"
  echo "TUN IP Address:		$TUN_IP"
  echo "Physical Interface:	$eth"
  echo "Default Gateway:	$GATEWAY"
  echo "Target SOCKS5 Proxy:	$SOCKS"
  echo "--------------------------------"
}

# Release stuck IP if it was assigned to the main interface
if ip addr show "$eth" | grep -q "$TUN_IP"; then
  echo "⚠️  $TUN_IP may be assigned to $eth, attempting to clean..."
  ip addr flush dev "$eth" || true
  sleep 1
fi

# Ensure the firejail namespace is clean before starting
firejail --shutdown="$TUN_NAME" || true

# Convert comma-separated DNS list to space-separated
DNS_LIST=$(echo "$DNS_SERVERS" | tr ',' ' ')

# Build firejail --dns arguments
FIREJAIL_DNS_ARGS=""
for ip in $DNS_LIST; do
  FIREJAIL_DNS_ARGS+=" --dns=$ip"
done

# Launch the TUN container. It will internally call network_setup.sh
exec firejail --noprofile --net="$eth" \
  $FIREJAIL_DNS_ARGS \
  --ip="$TUN_IP" --defaultgw="$GATEWAY" --name="$TUN_NAME_SPACE" \
  --private-dev --noexec=/tmp --noblacklist=/dev \
  bash "$LIB_DIR/system/network_setup.sh" "$SOCKS" "$TUN_IP"
