#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Evaluate JSON payloads against configurable triggers and output URL query strings.

Options:
  -c, --config FILE    Path to the JSON configuration file (required)
  -p, --payload FILE   Path to JSON payload file or '-' for stdin (default: stdin if piped)
  -f, --force          Ignore triggers/durations and directly output query parameters
  -d, --dry-run        Evaluate triggers without modifying the state file
  -v, --verbose        Output debug/evaluation details to stderr
  -h, --help           Show this help message and exit

Examples:
  $SCRIPT_NAME -c config.json -p payload.json
  curl -s http://api.example.com/data | $SCRIPT_NAME -c config.json
  $SCRIPT_NAME -c config.json -p payload.json --force
  $SCRIPT_NAME -c config.json -p payload.json --dry-run --verbose
EOF
  exit "${1:-0}"
}

# Default flags
CONFIG_FILE=""
PAYLOAD_FILE=""
FORCE=false
DRY_RUN=false
VERBOSE=false

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo "[DEBUG] $*" >&2
  fi
}

# Parse command line options using getopt
PARSED_ARGS=$(getopt -o c:p:fdvh --long config:,payload:,force,ignore-triggers,dry-run,verbose,help -n "$SCRIPT_NAME" -- "$@") || {
  echo "" >&2
  usage 1
}

eval set -- "$PARSED_ARGS"

while true; do
  case "$1" in
    -c|--config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    -p|--payload)
      PAYLOAD_FILE="$2"
      shift 2
      ;;
    -f|--force|--ignore-triggers)
      FORCE=true
      shift
      ;;
    -d|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "Unexpected option: $1" >&2
      usage 1
      ;;
  esac
done

# Validate config argument
if [[ -z "$CONFIG_FILE" ]]; then
  echo "Error: Configuration file (-c|--config) is required." >&2
  echo "" >&2
  usage 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: Configuration file '$CONFIG_FILE' does not exist or is not a regular file." >&2
  exit 1
fi

# Determine source for payload data
TMP_PAYLOAD=$(mktemp)
trap 'rm -f "$TMP_PAYLOAD"' EXIT

if [[ "$PAYLOAD_FILE" == "-" ]]; then
  cat > "$TMP_PAYLOAD"
elif [[ -n "$PAYLOAD_FILE" ]]; then
  if [[ ! -f "$PAYLOAD_FILE" ]]; then
    echo "Error: Payload file '$PAYLOAD_FILE' does not exist or is not a regular file." >&2
    exit 1
  fi
  cp "$PAYLOAD_FILE" "$TMP_PAYLOAD"
elif [[ ! -t 0 ]]; then
  # Automatically ingest stdin if data is piped into script
  cat > "$TMP_PAYLOAD"
else
  echo "Error: Must specify payload via -p/--payload or pipe data to stdin." >&2
  echo "" >&2
  usage 1
fi

# Validate payload JSON format
if ! jq empty "$TMP_PAYLOAD" 2>/dev/null; then
  echo "Error: Invalid JSON payload provided." >&2
  exit 1
fi

STATE_FILE=$(jq -r '.state_file // "state.json"' "$CONFIG_FILE")
NOW=$(date +%s)

log_verbose "Execution timestamp: $NOW"
log_verbose "Force mode (ignore triggers): $FORCE"
log_verbose "Dry-run mode: $DRY_RUN"
log_verbose "State file: $STATE_FILE"

# Initialize state in memory/file if missing or invalid
if [[ ! -f "$STATE_FILE" ]] || ! jq empty "$STATE_FILE" 2>/dev/null; then
  STATE_JSON="{}"
else
  STATE_JSON=$(cat "$STATE_FILE")
fi

QUERY_PARAMS=()
declare -A SEEN_PARAMS=()

TRIGGER_COUNT=$(jq '.triggers | length' "$CONFIG_FILE")

for (( i=0; i<TRIGGER_COUNT; i++ )); do
  NAME=$(jq -r ".triggers[$i].name" "$CONFIG_FILE")
  JSON_PATH=$(jq -r ".triggers[$i].json_path" "$CONFIG_FILE")
  PARAM_NAME=$(jq -r ".triggers[$i].param_name" "$CONFIG_FILE")
  OPERATOR=$(jq -r ".triggers[$i].operator" "$CONFIG_FILE")
  THRESHOLD=$(jq -r ".triggers[$i].threshold" "$CONFIG_FILE")
  REQUIRED_SECS=$(jq -r ".triggers[$i].required_seconds" "$CONFIG_FILE")

  VALUE=$(jq -r "$JSON_PATH // empty" "$TMP_PAYLOAD")

  if [[ -z "$VALUE" || "$VALUE" == "null" ]]; then
    log_verbose "Trigger [$NAME]: Value at '$JSON_PATH' not found or null. Skipping."
    continue
  fi

  # Bypass state evaluation entirely when --force / --ignore-triggers is set
  if [[ "$FORCE" == "true" ]]; then
    if [[ -z "${SEEN_PARAMS[$PARAM_NAME]:-}" ]]; then
      log_verbose "Trigger [$NAME]: Force mode active. Emitting '${PARAM_NAME}=${VALUE}'."
      QUERY_PARAMS+=("${PARAM_NAME}=${VALUE}")
      SEEN_PARAMS["$PARAM_NAME"]=1
    else
      log_verbose "Trigger [$NAME]: Parameter '$PARAM_NAME' already added. Skipping duplicate."
    fi
    continue
  fi

  CONDITION_MET=$(jq -n --argjson val "$VALUE" --argjson thresh "$THRESHOLD" \
    "if \$val $OPERATOR \$thresh then \"true\" else \"false\" end" 2>/dev/null || echo "false")

  FIRST_SEEN=$(echo "$STATE_JSON" | jq -r --arg name "$NAME" '.[$name].first_seen // empty')

  if [[ "$CONDITION_MET" == "true" ]]; then
    if [[ -z "$FIRST_SEEN" || "$FIRST_SEEN" == "null" ]]; then
      FIRST_SEEN=$NOW
    fi

    DURATION=$(( NOW - FIRST_SEEN ))

    log_verbose "Trigger [$NAME]: Condition MET ($VALUE $OPERATOR $THRESHOLD). Active for $DURATION / ${REQUIRED_SECS}s."

    STATE_JSON=$(echo "$STATE_JSON" | jq --arg name "$NAME" --argjson fs "$FIRST_SEEN" --argjson val "$VALUE" \
      '.[$name] = {"active": true, "first_seen": $fs, "last_value": $val}')

    if (( DURATION >= REQUIRED_SECS )); then
      if [[ -z "${SEEN_PARAMS[$PARAM_NAME]:-}" ]]; then
        log_verbose "Trigger [$NAME]: Target duration reached. Adding '${PARAM_NAME}=${VALUE}'."
        QUERY_PARAMS+=("${PARAM_NAME}=${VALUE}")
        SEEN_PARAMS["$PARAM_NAME"]=1
      else
        log_verbose "Trigger [$NAME]: Target duration reached, but '$PARAM_NAME' was already added by another trigger. Skipping duplicate."
      fi
    fi
  else
    log_verbose "Trigger [$NAME]: Condition NOT MET ($VALUE $OPERATOR $THRESHOLD). Resetting active state."

    STATE_JSON=$(echo "$STATE_JSON" | jq --arg name "$NAME" --argjson val "$VALUE" \
      '.[$name] = {"active": false, "first_seen": null, "last_value": $val}')
  fi
done

# Persist state if dry-run and force modes are disabled
if [[ "$DRY_RUN" == "false" && "$FORCE" == "false" ]]; then
  STATE_FILE_TMP=$(mktemp)
  echo "$STATE_JSON" > "$STATE_FILE_TMP"
  mv "$STATE_FILE_TMP" "$STATE_FILE"
  log_verbose "State updated and saved to $STATE_FILE."
else
  log_verbose "State file unmodified (dry-run or force mode active)."
fi

QUERY_STRING=""
if (( ${#QUERY_PARAMS[@]} > 0 )); then
  IFS='&'
  QUERY_STRING="${QUERY_PARAMS[*]}"
fi

echo "$QUERY_STRING"
