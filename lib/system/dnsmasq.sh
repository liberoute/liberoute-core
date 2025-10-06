#!/bin/bash
set -Eeuo pipefail

# Load environment
ENV_PATH="$(dirname "$0")/../../.env"
source "$ENV_PATH"

TUN_IP="${1:-}"

mkdir -p "$LOG_DIR"
DNS_SANDBOX_DIR="/tmp/firejail-dns"
mkdir -p "$DNS_SANDBOX_DIR"

DNSMASQ_CONF="$DNS_SANDBOX_DIR/dnsmasq.conf"
{
  echo "# Auto-generated dnsmasq config"
  echo "bind-interfaces"
  echo "listen-address=127.0.0.1,$TUN_IP"
  echo "cache-size=500"
  echo "no-resolv"
} > "$DNSMASQ_CONF"

IFS=',' read -ra DNS <<< "$DNS_SERVERS"
for dns in "${DNS[@]}"; do
  echo "server=$dns" >> "$DNSMASQ_CONF"
done

echo "🚦 Starting dnsmasq..."
exec dnsmasq --no-daemon --dns-forward-max=1000 --conf-file="$DNSMASQ_CONF" >> "$LOG_DIR/dnsmasq.log" 2>&1
