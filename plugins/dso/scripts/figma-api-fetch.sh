#!/usr/bin/env bash
# plugins/dso/scripts/figma-api-fetch.sh
# Fetch a Figma file via the Figma REST API using a Personal Access Token (PAT).
#
# Usage: figma-api-fetch.sh <file-key> [<output-path>]
#        figma-api-fetch.sh <file-key> --output <output-path>
#
# PAT source priority:
#   1. FIGMA_PAT environment variable (takes precedence if set and non-empty)
#   2. design.figma_pat key in config file (DSO_CONFIG_FILE or .claude/dso-config.conf)
#
# On success (HTTP 200): writes JSON to output file (if --output given), prints to stdout; exit 0
# On HTTP 401/403: exit 1 with PAT re-provisioning instructions on stderr
# On curl exit 28 (timeout): exit 1 with network/timeout error on stderr
# If no PAT found: exit 1 with configuration instructions on stderr

set -uo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
file_key=""
output_path=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            shift
            output_path="${1:-}"
            shift
            ;;
        -*)
            printf 'Error: Unknown option: %s\n' "$1" >&2
            exit 1
            ;;
        *)
            if [[ -z "$file_key" ]]; then
                file_key="$1"
            elif [[ -z "$output_path" ]]; then
                # Second positional arg is the output path
                output_path="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$file_key" ]]; then
    printf 'Usage: figma-api-fetch.sh <file-key> [<output-path>]\n' >&2
    printf '       figma-api-fetch.sh <file-key> --output <output-path>\n' >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve PAT
# ---------------------------------------------------------------------------
pat="${FIGMA_PAT:-}"

if [[ -z "$pat" ]]; then
    config_file="${DSO_CONFIG_FILE:-.claude/dso-config.conf}"
    pat="$(grep -E '^design\.figma_pat=' "$config_file" 2>/dev/null | cut -d= -f2- | head -1 || true)"
fi

# Note: missing PAT will result in a 401/403 from the API, caught below.

# ---------------------------------------------------------------------------
# Build API endpoint
# ---------------------------------------------------------------------------
api_base="${FIGMA_API_BASE_URL:-https://api.figma.com}"
depth="${FIGMA_FETCH_DEPTH:-4}"
endpoint="${api_base}/v1/files/${file_key}?depth=${depth}"

# ---------------------------------------------------------------------------
# Make API request
# ---------------------------------------------------------------------------
response_body="$(curl -s \
    -H "X-Figma-Token: ${pat}" \
    "${endpoint}")"
curl_exit=$?

# Handle curl-level errors
if [[ "$curl_exit" -eq 28 ]]; then
    printf 'Error: network timeout reaching Figma API.\n' >&2
    printf 'Check your network connection and try again.\n' >&2
    exit 1
elif [[ "$curl_exit" -ne 0 ]]; then
    printf 'Error: curl failed with exit code %d\n' "$curl_exit" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Detect auth failures from embedded JSON status field
# ---------------------------------------------------------------------------
embedded_status=""
if [[ -n "$response_body" ]]; then
    embedded_status="$(printf '%s' "$response_body" | python3 -c '
import sys, json
try:
    data = json.loads(sys.stdin.read())
    status = data.get("status", None)
    if isinstance(status, int):
        print(status)
except Exception:
    pass
' 2>/dev/null || true)"
fi

if [[ -n "$embedded_status" ]] && [[ "$embedded_status" -ge 400 ]]; then
    printf 'Error: Figma API authentication failed (status %s).\n' "$embedded_status" >&2
    printf 'Your PAT may be invalid, expired, or missing.\n' >&2
    printf 'Set FIGMA_PAT environment variable, or add design.figma_pat=<token> to %s\n' \
        "${DSO_CONFIG_FILE:-.claude/dso-config.conf}" >&2
    printf 'Generate a new PAT at https://www.figma.com/settings → Personal access tokens\n' >&2
    printf 'Note: Figma PATs expire after 90 days\n' >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------
printf '%s' "$response_body"

if [[ -n "$output_path" ]]; then
    printf '%s' "$response_body" > "$output_path"
fi

exit 0
