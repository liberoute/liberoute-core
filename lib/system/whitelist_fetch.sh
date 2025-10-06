
curl_try() {
  local url="$1"
  local dest="$2"

  SOCKS_PORT=$(echo "$INBOUNDS" | jq -r '.[0].listen_port')
  SOCKS_PROXY="socks5h://127.0.0.1:${SOCKS_PORT}"

  echo "🌐 Fetching: $url"
  if curl -fsSL "$url" -o "$dest"; then
    return 0
  fi

  echo "🔁 Fetch failed. Retrying with proxy..."
  if curl -fsSL --socks5-hostname "$SOCKS_PROXY" "$url" -o "$dest"; then
    echo "✅ Fetched via proxy."
    return 0
  fi

  echo "❌ ERROR: Download failed even with proxy: $url"
  return 1
}

#!/bin/bash
set -e

# Load .env
ENV_FILE="$(dirname "$0")/../../.env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

# Default countries if not defined
IFS=',' read -ra COUNTRY_CODES <<< "${WHITELIST_COUNTRIES:-ir}"
echo $IPS_DIR
mkdir -p "$IPS_DIR"

# Base URL
#https://ipv4.fetus.jp/ir.txt
BASE_URL="https://www-public.telecom-sudparis.eu/~maigron/rir-stats/rir-delegations/ip-lists"

fetch_and_store() {
  local url="$1"
  local ipver="$2"
  local country="$3"

  echo "🌐 Fetching $ipver list for $country..."

  # Download temp
  TMP_FILE=$(mktemp)
  curl -fsSL "$url" -o "$TMP_FILE"

  # Extract date from content header
  REMOTE_DATE=$(grep -m1 "^# Date:" "$TMP_FILE" | awk '{print $3}')
  if [[ ! "$REMOTE_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "❌ Failed to detect valid date from: $url"
    rm "$TMP_FILE"
    return 1
  fi

  FILE_NAME="${ipver}_${country}_${REMOTE_DATE}.txt"
  DEST_FILE="$IPS_DIR/$FILE_NAME"

  if [ -f "$DEST_FILE" ]; then
    echo "✅ Already up-to-date: $DEST_FILE"
    rm "$TMP_FILE"
    return 0
  fi

  # Delete older files for this ipver + country
  find "$IPS_DIR" -type f -name "${ipver}_${country}_*.txt" ! -name "$FILE_NAME" -exec rm {} +

  # Prepend metadata and save
  echo "# Source: $url" > "$DEST_FILE"
  echo "# Fetched: $(date '+%Y-%m-%d %H:%M:%S')" >> "$DEST_FILE"
  cat "$TMP_FILE" >> "$DEST_FILE"
  echo "✅ Saved: $DEST_FILE"
  rm "$TMP_FILE"
}

for CODE in "${COUNTRY_CODES[@]}"; do
  fetch_and_store "$BASE_URL/ipv4/${CODE}-ipv4-list.txt" "ipv4" "$CODE"
  fetch_and_store "$BASE_URL/ipv6/${CODE}-ipv6-list.txt" "ipv6" "$CODE"
done
