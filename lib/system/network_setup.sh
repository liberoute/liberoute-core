#!/bin/bash
set -e

# Must run inside firejail as root
[ "$EUID" -ne 0 ] && echo "❌ Must be root inside jail" && exit 1

# Load config
ENV_PATH="$(dirname "$0")/../../.env"
source "$ENV_PATH"

# Load forwarding setup (IPv4 and IPv6)
bash "$LIB_DIR/system/set_forwarding.sh"

export eth=$(ip r | awk '/default/ && $5 !~ /tun/ {print $5; exit}')
[ -z "$eth" ] && echo "❌ ERROR: eth interface not detected" && exit 1
export def_gate=$(ip route | awk '/default/ {print $3; exit}')
[ -z "$def_gate" ] && echo "❌ ERROR: default gateway not found" && exit 1

SOCKS="${1:-}"
TUN_IP="${2:-}"

echo "┌─────────────────────────────────────────────"
echo "│ 🔧 Firejail Network Setup"
printf "│ 🌐 Interface (eth): %-20s\n" "$eth"
printf "│ 🔀 TUN Device:       %-20s\n" "$TUN_DEVICE_NAME"
printf "│ 🧦 SOCKS Proxy:      %-20s\n" "$SOCKS"
echo "└─────────────────────────────────────────────"

# Ensure TUN device exists
mkdir -p /dev/net
[ ! -c /dev/net/tun ] && mknod /dev/net/tun c 10 200
chmod 600 /dev/net/tun


# Setup tun0 device
ip tuntap add dev "$TUN_DEVICE_NAME" mode tun || true
ip addr add 10.0.8.2 peer 10.0.8.1 dev "$TUN_DEVICE_NAME"
ip link set "$TUN_DEVICE_NAME" up

# Replace default route to go through tun0
ip route del default || true
ip -6 route del default || true
ip route add default via 10.0.8.1 dev "$TUN_DEVICE_NAME" metric 1
ip -6 route add default via fd00:1::1 dev "$TUN_DEVICE_NAME" metric 1 || true

# Basic NAT setup
$IPTABLES -F
$IPTABLES -t nat -F
$IPTABLES -A FORWARD -i "$TUN_DEVICE_NAME" -o "$eth" -m state --state RELATED,ESTABLISHED -j ACCEPT
$IPTABLES -A FORWARD -i "$eth" -o "$TUN_DEVICE_NAME" -j ACCEPT
$IPTABLES -t nat -A POSTROUTING -o "$TUN_DEVICE_NAME" -j MASQUERADE

$IP6TABLES -F
$IP6TABLES -t nat -F
$IP6TABLES -A FORWARD -i "$TUN_DEVICE_NAME" -o "$eth" -m state --state RELATED,ESTABLISHED -j ACCEPT
$IP6TABLES -A FORWARD -i "$eth" -o "$TUN_DEVICE_NAME" -j ACCEPT
$IP6TABLES -t nat -A POSTROUTING -o "$TUN_DEVICE_NAME" -j MASQUERADE

# DNS setup
#RESOLV_PATH="/etc/resolv.conf"
#[ -w "$RESOLV_PATH" ] || RESOLV_PATH="/tmp/resolv.conf"
#: > "$RESOLV_PATH"

#IFS=',' read -ra DNS <<< "$DNS_SERVERS"
#for dns in "${DNS[@]}"; do
#  echo "nameserver $dns" >> "$RESOLV_PATH"
#done

# DNS configuration (IPv4 ONLY)
generate_resolv_conf() {
  cat > /etc/resolv.conf << EOF_INNER
# IPv4-ONLY DNS - NO LEAKS
nameserver 127.0.0.1
options single-request-reopen
options timeout:2 attempts:1
EOF_INNER
  echo "✅ Generated IPv4-only resolv.conf"
}

generate_resolv_conf

# Launch supporting tools
"$LIB_DIR/system/whitelist.sh" --gateway="$def_gate" --net="$eth" &

bash "$LIB_DIR/system/proxy_run.sh" "$SOCKS" "$TUN_IP"
