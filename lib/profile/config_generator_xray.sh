#!/usr/bin/env bash
set -euo pipefail

# config_generator_xray
# Generate Xray/V2Ray client JSON from a vmess:// or vless:// link.
# - Default output targets Xray. Set CORE=v2ray for V2Ray-compatible JSON.
# - Reads optional INBOUNDS JSON from .env (INBOUNDS=...), otherwise uses a local SOCKS 127.0.0.1:1080.

# Usage:
#   ./config_generator_xray "<vmess://...>" > client.json
#   ./config_generator_xray "<vless://...>" > client.json
#   CORE=v2ray ./config_generator_xray "<...>" > client.json

# --- Requirements ---
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required." >&2
  exit 1
fi

LINK="${1:-}"
[ -n "$LINK" ] || { echo "Usage: $0 <vmess://... | vless://...>" >&2; exit 1; }
CORE="${CORE:-xray}"  # xray | v2ray

# --- Optional INBOUNDS from .env ---
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
ROOT="$SCRIPT_DIR/../.."
ENV_PATH="$ROOT/.env"
if [ -f "$ENV_PATH" ]; then
  # shellcheck disable=SC1090
  source "$ENV_PATH"
fi

# Default inbounds if .env/INBOUNDS invalid or missing
DEFAULT_INBOUNDS='[{"type":"socks","tag":"socks-in","listen":"127.0.0.1","listen_port":1080}]'
if [ -n "${INBOUNDS-}" ] && echo "$INBOUNDS" | jq empty >/dev/null 2>&1; then
  INBOUNDS_JSON="$INBOUNDS"
else
  INBOUNDS_JSON="$DEFAULT_INBOUNDS"
fi

# --- Helpers ---
urldecode() { local data="${1//+/ }"; printf '%b' "${data//%/\\x}"; }

TMP_NORM="$(mktemp)"   # normalized minimal JSON for jq
trap 'rm -f "$TMP_NORM"' EXIT

SCHEME="${LINK%%://*}"

if [[ "$SCHEME" == "vmess" ]]; then
  # vmess://<base64(json)>
  PAYLOAD="${LINK#vmess://}"
  PAYLOAD="${PAYLOAD//-/+}"
  PAYLOAD="${PAYLOAD//_/\/}"
  PAD=$(( (4 - ${#PAYLOAD} % 4) % 4 ))
  if (( PAD > 0 )); then
    PAYLOAD="${PAYLOAD}$(printf '=%.0s' $(seq 1 $PAD))"
  fi

  VMESS_JSON="$(printf '%s' "$PAYLOAD" | base64 -d 2>/dev/null || true)"
  [ -n "$VMESS_JSON" ] || { echo "ERROR: invalid vmess payload" >&2; exit 2; }

  # Create normalized object with a 'scheme' tag for downstream jq
  echo "$VMESS_JSON" | jq -c '
    {
      scheme: "vmess",
      add: (.add // .address // ""),
      port: ((.port // 0)|tonumber),
      id: (.id // ""),
      net: (.net // ""),
      type: (.type // ""),
      host: (.host // ""),
      path: (.path // "/"),
      tls: (.tls // ""),
      sni: (.sni // "")
    }
  ' > "$TMP_NORM"

elif [[ "$SCHEME" == "vless" ]]; then
  # vless://<uuid>@host:port?key=val...#name
  BODY="${LINK#vless://}"
  # strip fragment
  BODY_NOFRAG="${BODY%%#*}"

  USER="${BODY_NOFRAG%%@*}"
  REST="${BODY_NOFRAG#*@}"
  HOSTPORT="${REST%%\?*}"
  QUERY=""
  if [[ "$REST" == *\?* ]]; then QUERY="${REST#*\?}"; fi

  ADD="${HOSTPORT%%:*}"
  PORT="${HOSTPORT##*:}"

  declare -A Q
  IFS='&' read -r -a KV <<< "$QUERY"
  for kv in "${KV[@]-}"; do
    [[ -z "$kv" ]] && continue
    k="${kv%%=*}"
    v="${kv#*=}"
    # percent-decode
    v="$(urldecode "$v")"
    Q["$k"]="$v"
  done

  # prefer serviceName for grpc, else path
  PATHV="${Q[path]:-${Q[serviceName]:-}}"
  SNI="${Q[sni]:-${Q[host]:-}}"

  jq -n \
    --arg add "$ADD" \
    --argjson port "$(printf '%s' "$PORT" | sed 's/[^0-9]//g')" \
    --arg id "$USER" \
    --arg type "${Q[type]:-}" \
    --arg host "${Q[host]:-}" \
    --arg path "${PATHV:-}" \
    --arg security "${Q[security]:-}" \
    --arg sni "${SNI:-}" \
    --arg flow "${Q[flow]:-}" \
    --arg pbk "${Q[pbk]:-}" \
    --arg sid "${Q[sid]:-}" \
    --arg alpn "${Q[alpn]:-}" '
    {
      scheme: "vless",
      add: $add,
      port: ($port|tonumber),
      id: $id,
      type: ($type // ""),
      host: ($host // ""),
      path: (if ($type//"")=="grpc" then ($path // "") else ($path // "/") end),
      security: ($security // ""),   # tls | reality | ...
      sni: ($sni // ""),
      flow: ($flow // ""),
      pbk: ($pbk // ""),
      sid: ($sid // ""),
      alpn: (if ($alpn//"")!="" then ($alpn|split(",")) else [] end)
    }' > "$TMP_NORM"

else
  echo "ERROR: unsupported scheme: $SCHEME (use vmess:// or vless://)" >&2
  exit 1
fi

# --- Build final JSON (Xray/V2Ray) in jq ---
# We pass INBOUNDS_JSON via --argjson to avoid quoting issues.
jq \
  --arg core "$CORE" \
  --argjson inbounds "$INBOUNDS_JSON" \
  -c -f /dev/stdin "$TMP_NORM" <<'JQ'
  # Read normalized record
  . as $d
  |
  # Select effective transport (prefer .type then .net)
  ($d.type // $d.net // "tcp") as $net
  |
  # Build streamSettings based on transport + security
  def tls_sec:
    ( if ($d.security? // $d.tls? // "") == "tls" or ($d.sni // "") != "" then "tls" else "none" end );

  def ws_stream:
    {
      network: "ws",
      security: tls_sec,
      wsSettings: {
        path: ($d.path // "/"),
        headers: (if ($d.host // "") != "" then { Host: $d.host } else {} end)
      }
    }
    | if .security == "tls" and ($d.sni // "") != "" then . + { tlsSettings: { serverName: $d.sni, allowInsecure: false } } else . end;

  def http_obfs_stream:
    {
      network: "tcp",
      security: "none",
      tcpSettings: {
        header: {
          type: "http",
          request: {
            path: [($d.path // "/")],
            headers: (if ($d.host // "") != "" then { Host: [ $d.host ] } else {} end)
          }
        }
      }
    };

  def grpc_stream:
    {
      network: "grpc",
      security: tls_sec,
      grpcSettings: { serviceName: ($d.path // "") }
    }
    | if .security == "tls" and ($d.sni // "") != "" then . + { tlsSettings: { serverName: $d.sni, allowInsecure: false } } else . end;

  def tcp_stream:
    {
      network: "tcp",
      security: tls_sec
    }
    | if .security == "tls" and ($d.sni // "") != "" then . + { tlsSettings: { serverName: $d.sni, allowInsecure: false } } else . end;

  # Choose stream
  ( if $net == "ws" then ws_stream
    elif $net == "http" then http_obfs_stream
    elif $net == "grpc" then grpc_stream
    else tcp_stream end
  ) as $stream

  |
  # Build outbound based on scheme
  ( if $d.scheme == "vmess" then
      {
        tag: "proxy",
        protocol: "vmess",
        settings: {
          vnext: [
            {
              address: $d.add,
              port: ($d.port|tonumber),
              users: [ { id: $d.id, security: "auto", alterId: 0 } ]
            }
          ]
        },
        streamSettings: $stream
      }
    else
      # vless
      (
        # Build users (flow only for xray)
        ( if $core == "xray" and ($d.flow // "") != "" then
            [ { id: $d.id, encryption: "none", flow: $d.flow } ]
          else
            [ { id: $d.id, encryption: "none" } ]
          end
        ) as $users
        |
        {
          tag: "proxy",
          protocol: "vless",
          settings: {
            vnext: [
              {
                address: $d.add,
                port: ($d.port|tonumber),
                users: $users
              }
            ]
          },
          streamSettings: $stream
        }
      )
    end
  ) as $outbound

  |
  # If CORE=v2ray and (vless with security=reality), downshift to none (no realitySettings)
  ( if $core == "v2ray" and $d.scheme == "vless" and ($d.security // "") == "reality" then
      ($outbound
       | .streamSettings.security = "none"
       | del(.streamSettings.realitySettings) )
    else $outbound end
  ) as $outbound2

  |
  # Final config
  {
    log: { loglevel: "warning" },
    inbounds: $inbounds,
    outbounds: [ $outbound2 ]
  }
JQ
