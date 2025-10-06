#!/usr/bin/env bash
# liberoute/lib/system/whitelist.sh
set -Eeuo pipefail

# --- Load env -----------------------------------------------------------------
ENV_PATH="$(dirname "$0")/../../.env"
if [[ -f "$ENV_PATH" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_PATH"
else
  echo "❌ .env not found at $ENV_PATH" >&2
  exit 1
fi

# --- Defaults -----------------------------------------------------------------
LOG_DIR="${LOG_DIR:-/root/liberoute/logs}"
WHITELIST_LOG_FILE="${WHITELIST_LOG_FILE:-$LOG_DIR/whitelist.log}"
IPS_DIR="${IPS_DIR:-/root/liberoute/ips}"
WHITELIST_COUNTRIES="${WHITELIST_COUNTRIES:-}"
WHITELIST_MODE="${WHITELIST_MODE:-policy}"       # policy | nat
WL_MARK_HEX="${WL_MARK_HEX:-0x66}"               # fwmark value
WL_MARK_MASK="${WL_MARK_MASK:-0xff}"
WL_TABLE="${WHITELIST_TABLE_ID:-100}"            # routing table id
WL_RULE_PRIO="${WHITELIST_RULE_PRIO:-100}"       # ip rule priority
WHITELIST_CF_TRACE="${WHITELIST_CF_TRACE:-1}"    # 1=enable CF fast-lane
WHITELIST_IPV6="${WHITELIST_IPV6:-0}"            # 1=attempt IPv6 ipset+mark (routing v6 not set here)

mkdir -p "$LOG_DIR"
exec >> "$WHITELIST_LOG_FILE" 2>&1
set -x

# --- Args ---------------------------------------------------------------------
def_gate=""
eth=""
for arg in "$@"; do
  case $arg in
    --gateway=*) def_gate="${arg#*=}" ;;
    --net=*)     eth="${arg#*=}" ;;
    --mode=*)    WHITELIST_MODE="${arg#*=}" ;;
  esac
done
[[ -n "$def_gate" ]] || { echo "❌ Missing --gateway=<ip>"; exit 1; }
[[ -n "$eth"     ]] || { echo "❌ Missing --net=<iface>"; exit 1; }

# --- Binaries (use your env vars; fall back if empty) -------------------------
IPTABLES="${IPTABLES:-$(command -v iptables || command -v iptables-legacy || true)}"
[[ -n "$IPTABLES" ]] || { echo "❌ iptables not found"; exit 1; }

IP6TABLES="${IP6TABLES:-$(command -v ip6tables || command -v ip6tables-legacy || true)}"
[[ -n "$IP6TABLES" ]] || echo "⚠️ ip6tables not found; IPv6 marking will be skipped"

command -v ipset >/dev/null || { echo "❌ ipset not found"; exit 1; }
command -v ip >/dev/null || { echo "❌ ip command not found"; exit 1; }

# --- Helpers ------------------------------------------------------------------
load_set_from_file() {
  # $1=set_name  $2=family (inet|inet6)  $3=file
  local set_name="$1" family="$2" file="$3"
  [[ -f "$file" ]] || return 1

  ipset destroy "$set_name" 2>/dev/null || true
  if [[ "$family" == "inet6" ]]; then
    ipset create "$set_name" hash:net family inet6
  else
    ipset create "$set_name" hash:net
  fi

  while IFS= read -r ip; do
    [[ -z "$ip" || "$ip" =~ ^\# ]] && continue
    if [[ "$family" == "inet6" ]]; then
      [[ "$ip" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]] || continue
    else
      [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]{1,2})?$ ]] || continue
    fi
    ipset add "$set_name" "$ip" 2>/dev/null || true
  done < "$file"

  echo "📦 ipset '$set_name' loaded from $file"
}

ensure_connmark_restore() {
  $IPTABLES -t mangle -D PREROUTING -j CONNMARK --restore-mark 2>/dev/null || true
  $IPTABLES -t mangle -I PREROUTING 1 -j CONNMARK --restore-mark
  $IPTABLES -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null || true
  $IPTABLES -t mangle -I OUTPUT 1 -j CONNMARK --restore-mark
}

add_mark_rules_for_set_v4() {
  # $1=set_name
  local s="$1"
  ensure_connmark_restore

  # mark + save (PREROUTING/OUTPUT)
  $IPTABLES -t mangle -D PREROUTING -i "$eth" -m set --match-set "$s" dst \
    -j MARK --set-xmark "$WL_MARK_HEX/$WL_MARK_MASK" 2>/dev/null || true
  $IPTABLES -t mangle -I PREROUTING 2 -i "$eth" -m set --match-set "$s" dst \
    -j MARK --set-xmark "$WL_MARK_HEX/$WL_MARK_MASK"
  $IPTABLES -t mangle -D PREROUTING -i "$eth" -m set --match-set "$s" dst \
    -j CONNMARK --save-mark 2>/dev/null || true
  $IPTABLES -t mangle -I PREROUTING 3 -i "$eth" -m set --match-set "$s" dst \
    -j CONNMARK --save-mark

  $IPTABLES -t mangle -D OUTPUT -m set --match-set "$s" dst \
    -j MARK --set-xmark "$WL_MARK_HEX/$WL_MARK_MASK" 2>/dev/null || true
  $IPTABLES -t mangle -I OUTPUT 2 -m set --match-set "$s" dst \
    -j MARK --set-xmark "$WL_MARK_HEX/$WL_MARK_MASK"
  $IPTABLES -t mangle -D OUTPUT -m set --match-set "$s" dst \
    -j CONNMARK --save-mark 2>/dev/null || true
  $IPTABLES -t mangle -I OUTPUT 3 -m set --match-set "$s" dst \
    -j CONNMARK --save-mark

  # (optional) keep your NAT RETURN + FORWARD ACCEPT
  $IPTABLES -t nat -D PREROUTING -i "$eth" -m set --match-set "$s" dst -j RETURN 2>/dev/null || true
  $IPTABLES -t nat -I PREROUTING 1 -i "$eth" -m set --match-set "$s" dst -j RETURN

  $IPTABLES -D FORWARD -m set --match-set "$s" dst -j ACCEPT 2>/dev/null || true
  $IPTABLES -I FORWARD 1 -m set --match-set "$s" dst -j ACCEPT

  $IPTABLES -t nat -D OUTPUT -m set --match-set "$s" dst -j RETURN 2>/dev/null || true
  $IPTABLES -t nat -I OUTPUT 1 -m set --match-set "$s" dst -j RETURN
}

add_mark_rules_for_set_v6() {
  # $1=set_name (only if WHITELIST_IPV6=1 and ip6tables present)
  local s="$1"
  [[ "$WHITELIST_IPV6" = "1" ]] || return 0
  [[ -n "${IP6TABLES:-}" ]] || return 0

  $IP6TABLES -t mangle -D PREROUTING -j CONNMARK --restore-mark 2>/dev/null || true
  $IP6TABLES -t mangle -I PREROUTING 1 -j CONNMARK --restore-mark
  $IP6TABLES -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null || true
  $IP6TABLES -t mangle -I OUTPUT 1 -j CONNMARK --restore-mark

  $IP6TABLES -t mangle -D PREROUTING -i "$eth" -m set --match-set "$s" dst \
    -j MARK --set-xmark "$WL_MARK_HEX/$WL_MARK_MASK" 2>/dev/null || true
  $IP6TABLES -t mangle -I PREROUTING 2 -i "$eth" -m set --match-set "$s" dst \
    -j MARK --set-xmark "$WL_MARK_HEX/$WL_MARK_MASK"
  $IP6TABLES -t mangle -D PREROUTING -i "$eth" -m set --match-set "$s" dst \
    -j CONNMARK --save-mark 2>/dev/null || true
  $IP6TABLES -t mangle -I PREROUTING 3 -i "$eth" -m set --match-set "$s" dst \
    -j CONNMARK --save-mark

  $IP6TABLES -t mangle -D OUTPUT -m set --match-set "$s" dst \
    -j MARK --set-xmark "$WL_MARK_HEX/$WL_MARK_MASK" 2>/dev/null || true
  $IP6TABLES -t mangle -I OUTPUT 2 -m set --match-set "$s" dst \
    -j MARK --set-xmark "$WL_MARK_HEX/$WL_MARK_MASK"
  $IP6TABLES -t mangle -D OUTPUT -m set --match-set "$s" dst \
    -j CONNMARK --save-mark 2>/dev/null || true
  $IP6TABLES -t mangle -I OUTPUT 3 -m set --match-set "$s" dst \
    -j CONNMARK --save-mark

  $IP6TABLES -D FORWARD -m set --match-set "$s" dst -j ACCEPT 2>/dev/null || true
  $IP6TABLES -I FORWARD 1 -m set --match-set "$s" dst -j ACCEPT
}

install_policy_routing_v4() {
  # Remove old rule with same prio; install fresh
  ip rule del prio "$WL_RULE_PRIO" 2>/dev/null || true
  ip rule add prio "$WL_RULE_PRIO" fwmark "$WL_MARK_HEX/$WL_MARK_MASK" lookup "$WL_TABLE"

  # Table default via real gateway on $eth
  ip route flush table "$WL_TABLE" 2>/dev/null || true
  ip route add default via "$def_gate" dev "$eth" table "$WL_TABLE"
  echo "✅ Policy v4: fwmark $WL_MARK_HEX → table $WL_TABLE → default via $def_gate dev $eth"
}

resolve_ipv4s() {
  local d="$1"
  if command -v dig >/dev/null; then
    dig +short A "$d" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u
  else
    getent ahostsv4 "$d" | awk '{print $1}' | sort -u
  fi
}

add_cf_fastlane() {
  [[ "$WHITELIST_CF_TRACE" = "1" ]] || return 0

  local set="cf-whitelist"
  ipset destroy "$set" 2>/dev/null || true
  ipset create "$set" hash:ip

  local domains=( www.cloudflare.com ip-api.com )
  local ip
  for d in "${domains[@]}"; do
    while read -r ip; do
      [[ -n "$ip" ]] && ipset add "$set" "$ip" 2>/dev/null || true
    done < <(resolve_ipv4s "$d")
  done

  echo "🌐 CF fast-lane ips loaded into $set"
  add_mark_rules_for_set_v4 "$set"
}

# --- Start --------------------------------------------------------------------
modprobe ip_tables 2>/dev/null || true
modprobe ip6_tables 2>/dev/null || true

if [[ "$WHITELIST_MODE" = "policy" ]]; then
  install_policy_routing_v4
fi

IFS=',' read -r -a COUNTRY_CODES <<< "${WHITELIST_COUNTRIES}"
for CODE in "${COUNTRY_CODES[@]}"; do
  CODE="$(echo "$CODE" | xargs)"   # trim
  [[ -z "$CODE" ]] && continue

  # IPv4
  IPV4_FILE="$(ls -1 "$IPS_DIR"/ipv4_"$CODE"_*.txt 2>/dev/null | sort -r | head -n1 || true)"
  if [[ -n "$IPV4_FILE" && -f "$IPV4_FILE" ]]; then
    SET4="${CODE}-whitelist"
    load_set_from_file "$SET4" inet "$IPV4_FILE"
    add_mark_rules_for_set_v4 "$SET4"
    echo "📁 v4 source: $IPV4_FILE | 🌍 iface: $eth | 🌐 gw: $def_gate"
  else
    echo "⚠️ No IPv4 list found for country: $CODE at $IPS_DIR/ipv4_${CODE}_*.txt"
  fi

  # IPv6 (optional marking)
  IPV6_FILE="$(ls -1 "$IPS_DIR"/ipv6_"$CODE"_*.txt 2>/dev/null | sort -r | head -n1 || true)"
  if [[ -n "$IPV6_FILE" && -f "$IPV6_FILE" ]]; then
    SET6="${CODE}-whitelist6"
    load_set_from_file "$SET6" inet6 "$IPV6_FILE"
    add_mark_rules_for_set_v6 "$SET6"
    echo "📁 v6 source: $IPV6_FILE"
  else
    echo "ℹ️ No IPv6 list found for country: $CODE (or skipped)"
  fi
done

# Custom
CUSTOM_FILE="$IPS_DIR/custom.txt"
if [[ -f "$CUSTOM_FILE" ]]; then
  SETC="custom-whitelist"
  load_set_from_file "$SETC" inet "$CUSTOM_FILE"
  add_mark_rules_for_set_v4 "$SETC"
  echo "📦 Custom whitelist loaded from $CUSTOM_FILE"
else
  echo "ℹ️ No custom.txt found at $CUSTOM_FILE"
fi

# CF trace fast-lane
add_cf_fastlane

echo "✅ Whitelist applied. Mode=${WHITELIST_MODE}, Table=$WL_TABLE, Mark=$WL_MARK_HEX/$WL_MARK_MASK"
