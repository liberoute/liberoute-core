#!/bin/bash
set -e

# This script fetches a subscription link OR a direct vmess/vless link,
# decodes it, and manually builds a sing-box JSON configuration file.
# The inbounds are dynamically generated based on the .env file.

# --- Dependency Check ---
if ! command -v jq &> /dev/null; then
    echo "❌ ERROR: 'jq' is not installed, but is required to create a config."
    echo "   -> Please install it (e.g., 'sudo apt-get install jq') and try again."
    exit 1
fi

# Get the absolute path of this script's directory
SCRIPT_DIR_FETCHER=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# The project root is one level up from the lib/ directory
PROJECT_ROOT="$SCRIPT_DIR_FETCHER/../.."
ENV_PATH="$PROJECT_ROOT/.env"

if [ ! -f "$ENV_PATH" ]; then
    echo "❌ ERROR: .env file not found at '$ENV_PATH'."
    exit 1
fi
# Load the environment variables to get INBOUNDS, PROFILE_DIR etc.
source "$ENV_PATH"

# --- Validate Input ---
INPUT="$1"
if [ -z "$INPUT" ]; then
    echo "❌ ERROR: No link or subscription keyword provided."
    echo "Usage: liberoute add <vmess://...>"
    echo "   or: liberoute add sub <url>"
    exit 1
fi

FINAL_LINK=""

# --- Determine Mode (Basic vs. Subscription) ---
if [[ "$INPUT" == "sub" ]]; then
    # --- Subscription Mode ---
    SUBSCRIPTION_URL="$2"
    if [ -z "$SUBSCRIPTION_URL" ]; then
        echo "❌ ERROR: No subscription URL provided for 'sub' mode."
        exit 1
    fi

    echo "⬇️  Fetching subscription from URL..."
    SUB_CONTENT=$(curl -L --fail --show-error -s "$SUBSCRIPTION_URL")
    if [ -z "$SUB_CONTENT" ]; then echo "❌ ERROR: Failed to download or subscription is empty." >&2; exit 1; fi

    echo "🔄 Decoding subscription content..."
    DECODED_LINKS=$(echo "$SUB_CONTENT" | base64 --decode)
    FINAL_LINK=$(echo "$DECODED_LINKS" | head -n 1)
    if [ -z "$FINAL_LINK" ]; then echo "❌ ERROR: No valid links found in the subscription." >&2; exit 1; fi

elif [[ "$INPUT" == vmess://* || "$INPUT" == vless://* ]]; then
    # --- Basic Mode ---
    echo "🔹 Basic mode detected."
    FINAL_LINK="$INPUT"
else
    echo "❌ ERROR: Invalid input. Please provide a vmess/vless link or use 'sub <url>'." >&2
    exit 1
fi

echo "  -> Using link: ${FINAL_LINK:0:40}..."

# --- Decode and Parse Link ---
echo "⚙️  Parsing configuration from link..."
BASE64_PAYLOAD=$(echo "$FINAL_LINK" | sed -E 's/^(vmess|vless):\/\///')
DECODED_JSON=$(echo "$BASE64_PAYLOAD" | base64 --decode)

SERVER=$(echo "$DECODED_JSON" | jq -r '.add // ""')
PORT=$(echo "$DECODED_JSON" | jq -r '.port // ""')
UUID=$(echo "$DECODED_JSON" | jq -r '.id // ""')
AID=$(echo "$DECODED_JSON" | jq -r '.aid // 0')
NET=$(echo "$DECODED_JSON" | jq -r '.net // "tcp"')
TYPE=$(echo "$DECODED_JSON" | jq -r '.type // "none"')
HOST=$(echo "$DECODED_JSON" | jq -r '.host // ""')
V2_PATH=$(echo "$DECODED_JSON" | jq -r '.path // ""')
TLS=$(echo "$DECODED_JSON" | jq -r '.tls // ""')
SNI=$(echo "$DECODED_JSON" | jq -r '.sni // ""')
REMARK=$(echo "$DECODED_JSON" | jq -r '.ps // ""')

# --- Build JSON Transport Object ---
TRANSPORT_JSON=""
if [ "$NET" == "ws" ]; then
    TRANSPORT_JSON=$(jq -n --arg host "$HOST" --arg path "$V2_PATH" \
      '{type: "ws", path: $path, headers: {Host: $host}}')
elif [ "$TYPE" == "http" ]; then
     TRANSPORT_JSON=$(jq -n --arg host "$HOST" --arg path "$V2_PATH" \
      '{type: "http", host: [$host], path: $path}')
else
    TRANSPORT_JSON=$(jq -n '{type: "tcp"}')
fi

# --- Build JSON TLS Object ---
TLS_JSON=""
if [ "$TLS" == "tls" ]; then
    TLS_JSON=$(jq -n --arg sni "$SNI" \
      '{enabled: true, server_name: $sni, insecure: false}')
else
    TLS_JSON=$(jq -n '{enabled: false}')
fi

# --- Debug and Validate INBOUNDS ---
echo "🔍 Validating inbounds configuration..."
COMPACT_INBOUNDS=""
DEFAULT_INBOUNDS='[{"type":"socks","tag":"socks-in","listen":"127.0.0.1","listen_port":1080}]'

# Check if INBOUNDS is not empty and is valid JSON
if [ -n "${INBOUNDS-}" ] && echo "$INBOUNDS" | jq empty 2>/dev/null; then
    COMPACT_INBOUNDS=$(echo "$INBOUNDS" | jq -c '.')
    echo "✅ Using custom inbounds defined in .env file."
else
    echo "⚠️  WARNING: INBOUNDS not defined or invalid in .env. Using default SOCKS listener."
    COMPACT_INBOUNDS=$DEFAULT_INBOUNDS
fi

INBOUND_TAGS=$(echo "$COMPACT_INBOUNDS" | jq -c '[.[] | .tag]')
echo "🏷️  Using inbound tags: $INBOUND_TAGS"

# --- Save Config File ---
# Ensure the profile directory exists before trying to write to it
mkdir -p "$PROFILE_DIR"

FILENAME=$(echo "$REMARK" | sed 's/[^a-zA-Z0-9._-]/_/g')
if [ -z "$FILENAME" ]; then FILENAME="config-$(date +%s)"; fi
JSON_FILENAME="${FILENAME}.json"
JSON_DEST_PATH="$PROFILE_DIR/$JSON_FILENAME"

echo "💾 Building and saving configuration file..."

# Build the main JSON structure without the inbounds
BASE_JSON=$(jq -n \
  --arg server "$SERVER" \
  --argjson server_port "$PORT" \
  --arg uuid "$UUID" \
  --argjson alter_id "$AID" \
  --argjson transport "$TRANSPORT_JSON" \
  --argjson tls "$TLS_JSON" \
  --argjson inbound_tags "$INBOUND_TAGS" \
'{
  "log": { "level": "info", "timestamp": true },
  "outbounds": [
    {
      "type": "vmess",
      "tag": "proxy",
      "server": $server,
      "server_port": $server_port,
      "uuid": $uuid,
      "security": "auto",
      "alter_id": $alter_id,
      "transport": $transport,
      "tls": $tls
    }
  ],
  "route": { "rules": [ { "inbound": $inbound_tags, "outbound": "proxy" } ] }
}')

# Safely merge the INBOUNDS variable by piping it into a second jq call.
echo "$BASE_JSON" | jq --argjson inbounds "$COMPACT_INBOUNDS" '.inbounds = $inbounds' > "$JSON_DEST_PATH"

echo "✅ Successfully created profile: $JSON_DEST_PATH"
echo "💡 You can now set 'PROFILE=$JSON_FILENAME' in your .env file and run 'liberoute restart' to use it."
