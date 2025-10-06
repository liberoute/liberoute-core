#!/bin/bash
set -e

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

# Assumes .env has been sourced so INBOUNDS is exported.
# Optional overrides: SOCKS_PORT / INBOUND_TAG.

INB="${INBOUNDS-}"

if [[ -n "$INB" ]] && jq -e . >/dev/null 2>&1 <<<"$INB"; then
  PORT="${SOCKS_PORT:-$(
    jq -r 'if type=="array" then .[0].listen_port // 2801 else .listen_port // 2801 end' <<<"$INB"
  )}"
  TAG="${INBOUND_TAG:-$(
    jq -r 'if type=="array" then .[0].tag // "lan-in" else .tag // "lan-in" end' <<<"$INB"
  )}"
else
  # Fallbacks if INBOUNDS is missing/invalid JSON
  PORT="${SOCKS_PORT:-2801}"
  TAG="${INBOUND_TAG:-lan-in}"
fi

# Prepare logging and temp config
mkdir -p "$LOG_DIR"
PROXY_LOG="$LOG_DIR/proxy-only.log"
TMP_JSON=$(mktemp)

echo $TMP_JSON

# Generate sing-box config
cat > "$TMP_JSON" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "mixed",
      "listen": "0.0.0.0",
      "listen_port": $PORT,
      "tag": "$TAG"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "proxy-out"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": ["$TAG"],
        "outbound": "proxy-out"
      }
    ]
  }
}
EOF

echo "🚀 Starting sing-box (proxy-only mode) on port $PORT"
echo "📄 Config: $TMP_JSON"
echo "📁 Logs: $PROXY_LOG"

# Start sing-box with dynamic config
exec sing-box run -c "$TMP_JSON" >> "$PROXY_LOG" 2>&1
