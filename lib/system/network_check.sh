#!/bin/bash
set -e

# This script detects the primary network interface and gateway.
# It supports both automatic detection and manual overrides from the .env file.
# It is designed to be 'source'd by other scripts that have already loaded .env.

# --- Step 1: Detect Primary Interface and Default Gateway ---
# Wait for a valid default network route to appear (that isn't a tun device).
for i in {1..10}; do
  INTERFACE=$(ip route | awk '/default/ && $5 !~ /tun/ {print $5; exit}')
  if [ -n "$INTERFACE" ]; then break; fi
  echo "⏳ [$i] Waiting for default route..."
  sleep 2
done

if [ -z "$INTERFACE" ]; then
  echo "❌ No default interface detected after 20s. Exiting."
  ip route
  exit 1
fi
export eth="$INTERFACE"

# Always detect the real gateway for routing purposes.
DETECTED_GATEWAY=$(ip route | awk -v iface="$eth" '$1 == "default" && $5 == iface {print $3; exit}')
if [ -z "$DETECTED_GATEWAY" ]; then
  echo "❌ Could not detect the network gateway on interface $eth. Exiting."
  exit 1
fi
export def_gate="$DETECTED_GATEWAY"


# --- Step 2: Determine Gateway and IP addresses for Jails ---
# Check if the main variables are set in the .env file.
if [ -n "$GATEWAY" ] && [ -n "$IP" ] && [ -n "$TUN_IP" ]; then
  # --- MANUAL MODE ---
  echo "✅ Using manual configuration from .env file."
  export SOCKS_BASE_IP="$IP"
  export TUN_GATEWAY="$GATEWAY"

else
  # --- AUTOMATIC MODE ---
  echo "🤖 IP/Gateway not set in .env. Starting automatic detection."

  # Determine the network base from the detected gateway (e.g., 192.168.2)
  AUTO_NETWORK_BASE=$(echo "$DETECTED_GATEWAY" | cut -d. -f1-3)
  echo "  -> Detected Network Base: $AUTO_NETWORK_BASE"

  # Construct the full IPs for the jails
  AUTO_IP_1_FULL="${AUTO_NETWORK_BASE}.${AUTO_IP_1}"
  AUTO_IP_2_FULL="${AUTO_NETWORK_BASE}.${AUTO_IP_2}"
  echo "  -> VPN Jail IP will be: $AUTO_IP_1_FULL"
  echo "  -> TUN Jail IP will be: $AUTO_IP_2_FULL"

  # Export the auto-detected values to override the blank ones from .env
  export GATEWAY="$DETECTED_GATEWAY"
  export IP="$AUTO_IP_1_FULL"
  export TUN_IP="$AUTO_IP_2_FULL"
  export SOCKS_BASE_IP="$IP"
  export TUN_GATEWAY="$GATEWAY"
fi

# --- Final Validation ---
# Final check to ensure all critical variables are set before allowing the calling script to proceed.
if [ -z "$GATEWAY" ] || [ -z "$IP" ] || [ -z "$TUN_IP" ] || [ -z "$SOCKS_BASE_IP" ]; then
    echo "❌ CRITICAL ERROR: Network variables could not be set. Check .env settings and network connection."
    exit 1
fi
