#!/bin/bash

# --- VERSION METADATA ---
SCRIPT_VERSION="0.5"

VERBOSE=false
SYS_SN=""
APP_ID=""
APP_SECRET=""
OUTPUT_FILE=""
API_NAME="getLastPowerData"
EXTRA_PARAMS=""

CURL_BIN=$(which curl)
[ -z "$CURL_BIN" ] && CURL_BIN="/bin/curl"

# --- HELP MENU ---
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -h, --help       Show this help message"
    echo "  -v, --verbose    Enable verbose diagnostic tracing"
    echo "  -s, --sn         AlphaESS Inverter Serial Number"
    echo "  -i, --id         AlphaESS App ID"
    echo "  -k, --secret     AlphaESS App Secret"
    echo "  -a, --api-name   API name endpoint (default: getLastPowerData)"
    echo "  -p, --params     Extra URL query parameters in 'key=val,key2=val2' format"
    echo "  -o, --output     Optional output file path to write JSON"
}

# --- PARSE COMMAND LINE ARGUMENTS ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)      show_help ; exit 0;;
        -v|--verbose)   VERBOSE=true; shift ;;
        -s|--sn)        
            if [ -n "$2" ] && [[ "$2" != -* ]]; then
                SYS_SN="$2"; shift 2
            else
                echo "ERROR: Option '$1' requires a value." >&2; exit 2
            fi
            ;;
        -i|--id)        
            if [ -n "$2" ] && [[ "$2" != -* ]]; then
                APP_ID="$2"; shift 2
            else
                echo "ERROR: Option '$1' requires a value." >&2; exit 2
            fi
            ;;
        -k|--secret)    
            if [ -n "$2" ] && [[ "$2" != -* ]]; then
                APP_SECRET="$2"; shift 2
            else
                echo "ERROR: Option '$1' requires a value." >&2; exit 2
            fi
            ;;
        -a|--api-name)  
            if [ -n "$2" ] && [[ "$2" != -* ]]; then
                API_NAME="$2"; shift 2
            else
                echo "ERROR: Option '$1' requires a value." >&2; exit 2
            fi
            ;;
        -p|--params)    
            if [ -n "$2" ] && [[ "$2" != -* ]]; then
                EXTRA_PARAMS="$2"; shift 2
            else
                echo "ERROR: Option '$1' requires a value." >&2; exit 2
            fi
            ;;
        -o|--output)    
            if [ -n "$2" ] && [[ "$2" != -* ]]; then
                OUTPUT_FILE="$2"; shift 2
            else
                echo "ERROR: Option '$1' requires a value." >&2; exit 2
            fi
            ;;
        *)              
            echo "ERROR: Unknown option: $1" >&2; show_help; exit 2 ;;
    esac
done

# Clean parameters
SYS_SN=$(echo -n "$SYS_SN" | tr -d '\r')
APP_ID=$(echo -n "$APP_ID" | tr -d '\r')
APP_SECRET=$(echo -n "$APP_SECRET" | tr -d '\r')
OUTPUT_FILE=$(echo -n "$OUTPUT_FILE" | tr -d '\r')
API_NAME=$(echo -n "$API_NAME" | tr -d '\r')
EXTRA_PARAMS=$(echo -n "$EXTRA_PARAMS" | tr -d '\r')

if [[ -z "$SYS_SN" || -z "$APP_ID" || -z "$APP_SECRET" ]]; then
    echo "ERROR [v${SCRIPT_VERSION}]: Missing base inputs (-s, -i, -k)." >&2
    show_help
    exit 2
fi

# Define expected query parameter keys per API endpoint
REQ_PARAMS=()
case "$API_NAME" in
    getEvChargerStatusBySn)
        REQ_PARAMS=("evchargerSn")
        ;;
    getLastPowerData|getOneDayPowerBySn|getOneDateEnergyBySn)
        REQ_PARAMS=()
        ;;
    *)
        REQ_PARAMS=()
        ;;
esac

# Parse key-value pairs passed via -p/--params into associative array
declare -A PARSED_PARAMS
if [ -n "$EXTRA_PARAMS" ]; then
    IFS=',' read -ra PAIRS <<< "$EXTRA_PARAMS"
    for pair in "${PAIRS[@]}"; do
        param_key=$(echo "$pair" | cut -d'=' -f1 | tr -d ' \r')
        param_val=$(echo "$pair" | cut -d'=' -f2- | tr -d '\r')
        if [ -n "$param_key" ]; then
            PARSED_PARAMS["$param_key"]="$param_val"
        fi
    done
fi

# Build query string
QUERY_STRING="sysSn=${SYS_SN}"
for key in "${!PARSED_PARAMS[@]}"; do
    QUERY_STRING="${QUERY_STRING}&${key}=${PARSED_PARAMS[$key]}"
done

if [ "$VERBOSE" = true ]; then 
    echo "[DIAGNOSTIC] Engine Version: v${SCRIPT_VERSION}" >&2
    echo "[DIAGNOSTIC] API Name: '${API_NAME}'" >&2
    echo "[DIAGNOSTIC] SYS_SN: '${SYS_SN}'" >&2
    echo "[DIAGNOSTIC] Final Query String: '${QUERY_STRING}'" >&2

    for key in "${!PARSED_PARAMS[@]}"; do
        echo "[DIAGNOSTIC] Parsed CLI param: ${key}='${PARSED_PARAMS[$key]}'" >&2
    done

    for req_key in "${REQ_PARAMS[@]}"; do
        if [[ -z "${PARSED_PARAMS[$req_key]+x}" || -z "${PARSED_PARAMS[$req_key]}" ]]; then
            echo "[DIAGNOSTIC]: Expected parameter '${req_key}' for API '${API_NAME}' is not set in -p/--params. Proceeding anyway..." >&2
        fi
    done

    echo "[DIAGNOSTIC] Final Query String: '${QUERY_STRING}'" >&2
fi

API_HOST="openapi.alphaess.com"
API_PATH="/api/${API_NAME}"
API_URL="https://${API_HOST}${API_PATH}?${QUERY_STRING}"

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
