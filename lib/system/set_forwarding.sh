#!/usr/bin/env bash
set -Eeuo pipefail

set_sysctl() {
  local key="$1" val="$2"
  if sysctl -qw "$key=$val" 2>/dev/null; then
    return 0
  fi
  # Fallback only if writable
  local path="/proc/sys/${key//./\/}"
  if [ -w "$path" ]; then
    echo "$val" > "$path"
  else
    echo "⚠️ Warning: Could not set $key=$val — read-only or jailed. Configure via /etc/sysctl.d on host." >&2
  fi
}

set_sysctl net.ipv4.ip_forward 1
set_sysctl net.ipv6.conf.all.forwarding 1
