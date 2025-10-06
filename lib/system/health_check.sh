#!/bin/bash
set -e

# This script checks the health of the VPN connection.
# It's intended to be run by a systemd timer.

# This script must be run with its working directory as the project root,
# or have the .env file sourced before execution. The systemd service file handles this.
ENV_PATH="./.env"
if [ ! -f "$ENV_PATH" ]; then
    echo "❌ ERROR: .env file not found. This script should be run via manager.sh or its systemd service."
    exit 1
fi
source "$ENV_PATH"

# --- Configuration ---
CHECK_URL="http://ip-api.com/json"
LOG_FILE="$HEALTH_LOG_FILE"
SOCKS_PORT=$(jq -r '.inbounds[0].listen_port' "$PROFILE_DIR/$PROFILE")
SOCKS_PROXY="socks5h://${IP}:${SOCKS_PORT}"

# --- Logic ---

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

echo "--- Health Check Started: $(date) ---" >> "$LOG_FILE"

# Perform the check using curl through the SOCKS proxy
# We use socks5h to ensure DNS resolution also goes through the proxy.
RESPONSE=$(curl --silent --proxy "$SOCKS_PROXY" --connect-timeout 10 "$CHECK_URL")

# Check if the curl command was successful and we got a response
if [ $? -eq 0 ] && [ -n "$RESPONSE" ]; then
    COUNTRY=$(echo "$RESPONSE" | jq -r '.country')
    IP_ADDR=$(echo "$RESPONSE" | jq -r '.query')

    if [ -n "$COUNTRY" ]; then
        echo "✅ HEALTHY: Connection is up. IP is $IP_ADDR ($COUNTRY)." >> "$LOG_FILE"
        exit 0
    else
        echo "❌ UNHEALTHY: Could not parse country from response." >> "$LOG_FILE"
        echo "  -> Response: $RESPONSE" >> "$LOG_FILE"
    fi
else
    echo "❌ UNHEALTHY: curl command failed or timed out." >> "$LOG_FILE"
fi

# If we reach here, the check failed. Restart the services.
echo "🔄 Restarting services due to health check failure..." >> "$LOG_FILE"
systemctl restart liberoute-connection.service

echo "--- Health Check Finished ---" >> "$LOG_FILE"
