#!/bin/bash
set -Eeuo pipefail

# Load environment
ENV_PATH="$(dirname "$0")/../../.env"
source "$ENV_PATH"

mkdir -p "$LOG_DIR"

SOCKS="${1:-}"
if [[ -z "$SOCKS" ]]; then
  echo "❌ SOCKS proxy not provided."
  exit 1
fi

TUN_IP="${2:-}"
if [[ -z "$TUN_IP" ]]; then
  echo "❌ tunnel ip not provided."
  exit 1
fi

DNS_SANDBOX_DIR="/tmp/firejail-dns"
mkdir -p "$DNS_SANDBOX_DIR"

DNSMASQ_CONF="$DNS_SANDBOX_DIR/dnsmasq.conf"
{
  echo "# Auto-generated dnsmasq config for dns2socks"
  echo "no-resolv"
  echo "bind-interfaces"
  echo "listen-address=127.0.0.1,$TUN_IP"
  echo "cache-size=500"
} > "$DNSMASQ_CONF"

# Disable 'exit on error' only for this loop
set +e

dns_index=0
IFS=',' read -ra DNS_ARRAY <<< "$DNS_SERVERS"
for dns in "${DNS_ARRAY[@]}"; do
  port=$((5353 + dns_index))
  echo "server=127.0.0.1#$port" >> "$DNSMASQ_CONF"

  [[ "$dns" == *:* ]] && dns_wrapped="[$dns]" || dns_wrapped="$dns"

  echo "🐛 DEBUG index=$dns_index | dns=$dns_wrapped | port=$port"
  echo "🚀 Launching dns2socks → $dns_wrapped on port $port"

(
  bash -c '
    log_file="$5/dns2socks-$4.log"
    echo "    → log: $log_file"
    exec dns2socks \
      --socks5-settings "$1" \
      --dns-remote-server "$2:53" \
      --listen-addr "127.0.0.1:$3" \
      --force-tcp \
      --cache-records \
      >> "$log_file" 2>&1
  ' _ "$SOCKS" "$dns_wrapped" "$port" "$dns_index" "$LOG_DIR"
) || true &

  echo "✔️  dns2socks[$dns_index] launched"
  ((dns_index++))
done

# Restore error handling
set -e

sleep 1

echo "🚦 Starting dnsmasq..."
exec dnsmasq --no-daemon --dns-forward-max=1000 --conf-file="$DNSMASQ_CONF" >> "$LOG_DIR/dnsmasq.log" 2>&1 &

#exec dnsmasq --no-daemon --conf-file="$DNSMASQ_CONF"
