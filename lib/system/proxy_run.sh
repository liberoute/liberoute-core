#!/bin/bash
set -e

# This script runs inside the TUNNEL firejail to start transparent proxies.

# --- Setup ---
# Get the absolute path of this script's directory
SCRIPT_DIR_HELPER=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# The project root is one level up from the lib/ directory
PROJECT_ROOT="$SCRIPT_DIR_HELPER/../.."
ENV_PATH="$PROJECT_ROOT/.env"

if [ ! -f "$ENV_PATH" ]; then
    echo "❌ FATAL: .env file not found." >&2
    exit 1
fi
source "$ENV_PATH"

# --- Main Logic ---
# Detect the jail's internal interface name (e.g., eth0-12345)
eth=$(ip r | awk '/default/ && $5 !~ /tun/ {print $5; exit}' | cut -d@ -f1)
if [ -z "$eth" ]; then
    eth=$(ip -o link show | awk -F': ' '/eth/ {print $2; exit}' | cut -d@ -f1)
fi
if [ -z "$eth" ]; then
    echo "❌ FATAL: Could not detect jail's internal interface." >&2
    exit 1
fi

# Setup logs
mkdir -p "$LOG_DIR"
exec >> "$PROXY_LOG_FILE" 2>&1
set -x

SOCKS="${1:-}"
TUN_IP="${2:-}"

# Status banner
{
  echo "--- Liberoute Proxy Service ---"
  echo "Timestamp:            $(date)"
  echo "Internal Interface:   $eth"
  echo "Tunnel Device:        $TUN_NAME"
  echo "Target SOCKS5 Proxy:  $SOCKS"
  echo "-------------------------------"
}

# ** THE FIX IS HERE **
# Prepare and run danted using absolute paths
#DANTED_TEMPLATE_PATH="$CONFIG_DIR/danted.conf"
#PRIVOXY_CONF_PATH="$CONFIG_DIR/privoxy.conf"

#if [ ! -f "$DANTED_TEMPLATE_PATH" ]; then
#    echo "❌ FATAL: Dante template not found at $DANTED_TEMPLATE_PATH" >&2
#    exit 1
#fi
#if [ ! -f "$PRIVOXY_CONF_PATH" ]; then
#    echo "❌ FATAL: Privoxy config not found at $PRIVOXY_CONF_PATH" >&2
#    exit 1
#fi

## Create a temporary, per-interface config file for danted
#DANTED_RUNTIME_CONF="$CONFIG_DIR/danted-$eth.conf"
#cp "$DANTED_TEMPLATE_PATH" "$DANTED_RUNTIME_CONF"
#sed -i "s/eth0/$eth/" "$DANTED_RUNTIME_CONF"

#echo "🚀 Starting Dante SOCKS proxy..."
#danted -f "$DANTED_RUNTIME_CONF" -D

#echo "🌐 Starting Privoxy HTTP proxy..."
#privoxy --no-daemon "$PRIVOXY_CONF_PATH" &

if [ -z "$TUN_DEVICE_NAME" ]; then
  echo "❌ ERROR: TUN device is not set. Aborting tun2socks launch."
  exit 1
fi

bash "$LIB_DIR/system/dns2socks.sh" "$SOCKS" "$TUN_IP"&
#bash "$LIB_DIR/dnsmasq.sh" &   # ← keep commented to avoid direct DNS
bash "$LIB_DIR/system/proxy_only.sh" &

echo "===================================================> im fucking here $LIB_DIR <++++++"

echo "🚇 Launching tun2socks..."
tun2socks -device "$TUN_DEVICE_NAME" -proxy "$SOCKS" -interface "$eth"
