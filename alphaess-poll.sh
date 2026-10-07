#!/bin/bash

# --- VERSION METADATA ---
SCRIPT_VERSION="0.1"

VERBOSE=false
SYS_SN=""
APP_ID=""
APP_SECRET=""
OUTPUT_FILE=""

CURL_BIN=$(which curl)
[ -z "$CURL_BIN" ] && CURL_BIN="/bin/curl"

# --- HELP MENU ---
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -h, --help      Show this help message"
    echo "  -v, --verbose   Enable verbose diagnostic tracing"
    echo "  -s, --sn        AlphaESS Inverter Serial Number"
    echo "  -i, --id        AlphaESS App ID"
    echo "  -k, --secret    AlphaESS App Secret"
    echo "  -o, --output    Optional output file path to write JSON"
}

# --- PARSE COMMAND LINE ARGUMENTS ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)      show_help ; exit 0;;
        -v|--verbose)   VERBOSE=true; shift ;;
        -s|--sn)        SYS_SN="$2"; shift 2 ;;
        -i|--id)        APP_ID="$2"; shift 2 ;;
        -k|--secret)    APP_SECRET="$2"; shift 2 ;;
        -o|--output)    OUTPUT_FILE="$2"; shift 2 ;;
        *)              echo "ERROR: Unknown option: $1" >&2; show_help ;;
    esac
done

# Clean parameters
SYS_SN=$(echo -n "$SYS_SN" | tr -d '\r')
APP_ID=$(echo -n "$APP_ID" | tr -d '\r')
APP_SECRET=$(echo -n "$APP_SECRET" | tr -d '\r')
OUTPUT_FILE=$(echo -n "$OUTPUT_FILE" | tr -d '\r')

if [[ -z "$SYS_SN" || -z "$APP_ID" || -z "$APP_SECRET" ]]; then
    echo "ERROR [v${SCRIPT_VERSION}]: Missing inputs." >&2
    show_help
    exit 2
fi

if [ "$VERBOSE" = true ]; then 
    echo "[DIAGNOSTIC] Engine Version: v${SCRIPT_VERSION}" >&2
    echo "[DIAGNOSTIC] Checking parameters..." >&2
    echo "[DIAGNOSTIC] SYS_SN: '${SYS_SN}'" >&2
fi

API_HOST="openapi.alphaess.com"
API_PATH="/api/getLastPowerData"
API_URL="https://${API_HOST}${API_PATH}?sysSn=${SYS_SN}"

if [ "$VERBOSE" = true ]; then
    echo "[VERBOSE] Target Destination URL: ${API_URL}" >&2
fi

TIMESTAMP=$(date +%s)
SIGN_STRING="${APP_ID}${APP_SECRET}${TIMESTAMP}"
SIGN=$(echo -n "$SIGN_STRING" | sha512sum | awk '{print $1}')

CURL_OPTS=("-s" "-w" "\n%{http_code}" "-X" "GET" \
           "${API_URL}" \
           "-H" "appId: ${APP_ID}" \
           "-H" "timeStamp: ${TIMESTAMP}" \
           "-H" "sign: ${SIGN}")

[ "$VERBOSE" = true ] && CURL_OPTS+=("-v")

RESPONSE=$("$CURL_BIN" "${CURL_OPTS[@]}")
HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)
JSON_BODY=$(echo "$RESPONSE" | sed '$d')
HTTP_STATUS=$(echo -n "$HTTP_STATUS" | tr -d '\r')

if [ "$VERBOSE" = true ]; then
    echo "[VERBOSE] HTTP Status Received: ${HTTP_STATUS}" >&2
    echo "[VERBOSE] Response Payload Received: ${JSON_BODY}" >&2
fi

if [ "$HTTP_STATUS" -ne 200 ]; then
    echo "ERROR [v${SCRIPT_VERSION}]: Host returned code ${HTTP_STATUS}." >&2
    exit 1
fi

if ! echo "$JSON_BODY" | jq empty 2>/dev/null; then
    echo "ERROR [v${SCRIPT_VERSION}]: Response payload is not valid JSON." >&2
    exit 1
fi

# Write output to file if specified, else write to stdout
if [ -n "$OUTPUT_FILE" ]; then
    echo "$JSON_BODY" > "$OUTPUT_FILE"
else
    echo "$JSON_BODY"
fi
