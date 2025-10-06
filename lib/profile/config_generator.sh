#!/bin/bash
set -euo pipefail

# Takes a single vmess/vless link and generates a temporary sing-box config file.
# Outputs the path to the temporary file.

if ! command -v jq &> /dev/null; then
    echo "❌ ERROR: 'jq' is not installed, but is required to create a config." >&2
    exit 1
fi

SCRIPT_DIR_HELPER=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
PROJECT_ROOT="$SCRIPT_DIR_HELPER/../.."
ENV_PATH="$PROJECT_ROOT/.env"
[ ! -f "$ENV_PATH" ] && { echo "❌ ERROR: .env file not found." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_PATH"

FINAL_LINK="${1:-}"
[ -z "$FINAL_LINK" ] && { echo "❌ ERROR: No link provided to config generator."; exit 1; }

urldecode() { local data="${1//+/ }"; printf '%b' "${data//%/\\x}"; }

build_transport_json() {
  # $1=type  $2=path  $3=host_header  $4=service_name
  local type="${1:-}"; local path="${2:-/}"; local host="${3:-}"; local svc="${4:-grpc}"
  case "$type" in
    ws)
      jq -n --arg p "$path" --arg h "$host" '
        if ($h|length)>0 then {type:"ws", path:$p, headers:{Host:$h}}
        else {type:"ws", path:$p} end'
      ;;
    grpc)
      jq -n --arg s "$svc" '{type:"grpc", service_name:$s}'
      ;;
    http)
      jq -n --arg p "$path" --arg h "$host" '
        if ($h|length)>0 then {type:"http", path:$p, host:[$h]}
        else {type:"http", path:$p} end'
      ;;
    h2|h3|quic|tcp|"")
      jq -n 'null'
      ;;
    *)
      jq -n 'null'
      ;;
  esac
}

scheme="${FINAL_LINK%%://*}"
case "$scheme" in
  vmess)
    b64="${FINAL_LINK#vmess://}"
    b64="${b64//$'\n'/}"; b64="${b64//$'\r'/}"
    case "$b64" in *…*) echo "❌ ERROR: vmess link appears truncated (contains …). Copy the full link."; exit 2;; esac
    b64="${b64//-/+}"; b64="${b64//_/\/}"
    pad=$(( (4 - ${#b64} % 4) % 4 )); b64="${b64}$(printf '=%.0s' $(seq 1 $pad))"

    DECODED_JSON="$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)"
    [ -z "$DECODED_JSON" ] && { echo "❌ ERROR: Invalid vmess base64 payload (line breaks or truncation?)"; exit 3; }

    SERVER=$(echo "$DECODED_JSON" | jq -r '.add // .address // ""')
    PORT=$(echo "$DECODED_JSON" | jq -r '.port // ""')
    UUID=$(echo "$DECODED_JSON" | jq -r '.id // ""')
    NET=$(echo "$DECODED_JSON" | jq -r '.net // ""')
    TYPE=$(echo "$DECODED_JSON" | jq -r '.type // ""')
    TLS=$(echo "$DECODED_JSON" | jq -r '.tls // ""')
    SNI=$(echo "$DECODED_JSON" | jq -r '.sni // ""')
    HOST=$(echo "$DECODED_JSON" | jq -r '.host // ""')
    V2_PATH=$(echo "$DECODED_JSON" | jq -r '.path // ""')

    # proper validation
    if [ -z "$SERVER" ] || [ -z "$PORT" ] || [ -z "$UUID" ]; then
      echo "❌ ERROR: vmess missing address/port/id"; exit 4
    fi

    # choose transport: TYPE has priority (http/ws/grpc/...), fallback to NET
    SEL="$TYPE"; [ -z "$SEL" ] && SEL="$NET"
    TRANSPORT_JSON="$(build_transport_json "$SEL" "$V2_PATH" "$HOST" "")"

    # TLS heuristic:
    # enable if: explicit tls=="tls" OR sni set OR (host present AND port is commonly-TLS)
    if [ "${TLS,,}" = "tls" ] || [ -n "$SNI" ] || { [ -n "$HOST" ] && [[ "$PORT" =~ ^(443|8443|2053|2083|2087|2096)$ ]]; }; then
      SNI_EFF="$SNI"; [ -z "$SNI_EFF" ] && SNI_EFF="$HOST"
      TLS_JSON=$(jq -n --arg sni "$SNI_EFF" '
        if ($sni|length)>0
        then {enabled:true, server_name:$sni, insecure:false}
        else {enabled:true, insecure:false}
        end')
    else
      TLS_JSON=$(jq -n '{enabled:false}')
    fi

    OUTBOUND_JSON=$(
      jq -n \
        --arg server "$SERVER" \
        --argjson server_port "$PORT" \
        --arg uuid "$UUID" \
        --argjson transport "$TRANSPORT_JSON" \
        --argjson tls "$TLS_JSON" '
        {
          type: "vmess",
          tag:  "proxy",
          server: $server,
          server_port: ($server_port|tonumber),
          uuid: $uuid,
          security: "auto",
          alter_id: 0,
          tls: $tls
        }
        | if ($transport|type)=="object" then . + {transport:$transport} else . end
      '
    )
    ;;

  vless)
    body="${FINAL_LINK#vless://}"

    NAME="vless-out"
    if [[ "$body" == *#* ]]; then
      NAME="$(urldecode "${body#*#}")"
      body="${body%%#*}"
    fi

    USER="${body%%@*}"; REST="${body#*@}"; ID="$USER"
    HOSTPORT="${REST%%\?*}"; QUERY=""
    [[ "$REST" == *\?* ]] && QUERY="${REST#*\?}"

    SERVER="${HOSTPORT%%:*}"; PORT="${HOSTPORT##*:}"

    declare -A Q
    IFS='&' read -r -a kvs <<< "${QUERY:-}"
    for kv in "${kvs[@]:-}"; do
      [ -z "$kv" ] && continue
      k="${kv%%=*}"; v="${kv#*=}"
      k="$(urldecode "$k")"; v="$(urldecode "$v")"
      Q["$k"]="$v"
    done

    SECURITY="${Q[security]:-}"
    FLOW="${Q[flow]:-}"
    SNI="${Q[sni]:-${Q[host]:-}}"
    FP="${Q[fp]:-}"
    ALPN="${Q[alpn]:-}"
    TYPE="${Q[type]:-}"
    V2_PATH="${Q[path]:-}"
    HOST_HDR="${Q[host]:-}"
    PBK="${Q[pbk]:-}"
    SID="${Q[sid]:-}"
    SVC="${Q[serviceName]:-}"

    if [ -z "$SERVER" ] || [ -z "$PORT" ] || [ -z "$ID" ]; then
      echo "❌ ERROR: vless missing host/port/id"; exit 5
    fi

    TRANSPORT_JSON="$(build_transport_json "$TYPE" "$V2_PATH" "$HOST_HDR" "$SVC")"

    if [[ "${SECURITY,,}" == "tls" ]]; then
      TLS_JSON=$(jq -n --arg sni "$SNI" --arg fp "$FP" --arg alpn "$ALPN" '
        if ($sni|length)>0 and ($alpn|length)>0 and ($fp|length)>0 then
          {enabled:true, insecure:false, server_name:$sni, alpn:($alpn|split(",")), utls:{enabled:true, fingerprint:$fp}}
        elif ($sni|length)>0 and ($alpn|length)>0 then
          {enabled:true, insecure:false, server_name:$sni, alpn:($alpn|split(","))}
        elif ($sni|length)>0 then
          {enabled:true, insecure:false, server_name:$sni}
        else
          {enabled:true, insecure:false}
        end')
    elif [[ "${SECURITY,,}" == "reality" ]]; then
      TLS_JSON=$(jq -n --arg sni "$SNI" --arg fp "$FP" --arg pbk "$PBK" --arg sid "$SID" '
        if ($sni|length)>0 and ($fp|length)>0 and ($pbk|length)>0 and ($sid|length)>0 then
          {enabled:true, insecure:false, server_name:$sni, utls:{enabled:true, fingerprint:$fp}, reality:{enabled:true, public_key:$pbk, short_id:$sid}}
        elif ($sni|length)>0 and ($pbk|length)>0 and ($sid|length)>0 then
          {enabled:true, insecure:false, server_name:$sni, reality:{enabled:true, public_key:$pbk, short_id:$sid}}
        elif ($pbk|length)>0 and ($sid|length)>0 then
          {enabled:true, insecure:false, reality:{enabled:true, public_key:$pbk, short_id:$sid}}
        else
          {enabled:true, insecure:false, reality:{enabled:true}}
        end')
    else
      TLS_JSON=$(jq -n '{enabled:false}')
    fi

    if [ -z "${NAME}" ]; then TAG="vless-out"; else TAG="$NAME"; fi

    OUTBOUND_JSON=$(
      jq -n \
        --arg tag "$TAG" \
        --arg server "$SERVER" \
        --argjson server_port "$PORT" \
        --arg uuid "$ID" \
        --arg flow "$FLOW" \
        --argjson transport "$TRANSPORT_JSON" \
        --argjson tls "$TLS_JSON" '
        {
          type: "vless",
          tag:  $tag,
          server: $server,
          server_port: ($server_port|tonumber),
          uuid: $uuid,
          tls: $tls
        }
        | if ($flow|length)>0 then . + {flow:$flow} else . end
        | if ($transport|type)=="object" then . + {transport:$transport} else . end
      '
    )
    ;;

  *)
    echo "❌ ERROR: Unsupported link scheme: $scheme"; exit 10;;
esac

# --- Inbounds ---
COMPACT_INBOUNDS='[{"type":"socks","tag":"socks-in","listen":"127.0.0.1","listen_port":1080}]'
if [ -n "${INBOUNDS-}" ] && echo "$INBOUNDS" | jq empty 2>/dev/null; then
    COMPACT_INBOUNDS=$(echo "$INBOUNDS" | jq -c '.')
fi
INBOUND_TAGS=$(echo "$COMPACT_INBOUNDS" | jq -c '[.[] | .tag]')

TEMP_CONFIG_FILE=$(mktemp --suffix=.json)

BASE_JSON=$(
  jq -n \
    --argjson outbound "$OUTBOUND_JSON" \
    --argjson inbound_tags "$INBOUND_TAGS" '
    {
      log: { level: "info", timestamp: true },
      outbounds: [ $outbound ],
      route: { rules: [ { inbound: $inbound_tags, outbound: ($outbound.tag // "proxy") } ] }
    }'
)

echo "$BASE_JSON" | jq --argjson inbounds "$COMPACT_INBOUNDS" '.inbounds = $inbounds' > "$TEMP_CONFIG_FILE"

echo "$TEMP_CONFIG_FILE"
