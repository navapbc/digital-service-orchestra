#!/usr/bin/env bash
# plugins/dso/scripts/figma-auth.sh
# Validate a Figma Personal Access Token (PAT) via GET /v1/me.
#
# Usage: figma-auth.sh (no positional arguments)
#
# PAT source priority:
#   1. FIGMA_PAT environment variable (takes precedence if set and non-empty)
#   2. design.figma_pat key in config file (DSO_CONFIG_FILE or .claude/dso-config.conf)
#
# Exits 0 if the PAT is valid (HTTP 200 and no error in response).
# Exits 1 with instructions on stderr if the PAT is missing or invalid.

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve PAT
# ---------------------------------------------------------------------------
pat="${FIGMA_PAT:-}"

if [[ -z "$pat" ]]; then
    config_file="${DSO_CONFIG_FILE:-.claude/dso-config.conf}"
    pat="$(grep -E '^design\.figma_pat=' "$config_file" 2>/dev/null | cut -d= -f2- | head -1 || true)"
fi

if [[ -z "$pat" ]]; then
    printf 'Error: No Figma PAT configured.\n' >&2
    printf 'Set FIGMA_PAT environment variable, or add design.figma_pat=<token> to %s\n' \
        "${DSO_CONFIG_FILE:-.claude/dso-config.conf}" >&2
    printf 'Generate a new PAT at https://www.figma.com/settings → Personal access tokens\n' >&2
    printf 'Note: Figma PATs expire after 90 days\n' >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Validate PAT via GET /v1/me
# ---------------------------------------------------------------------------
api_base="${FIGMA_API_BASE_URL:-https://api.figma.com}"
endpoint="${api_base}/v1/me"

# Capture HTTP status code and response body separately
response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT

http_status="$(curl -s -o "$response_file" -w '%{http_code}' \
    -H "X-Figma-Token: ${pat}" \
    "${endpoint}" 2>/dev/null)"

response_body="$(cat "$response_file")"

# Check HTTP status — accept any 2xx as potentially valid
is_2xx=0
if [[ "$http_status" =~ ^2 ]]; then
    is_2xx=1
fi

# Even on HTTP 200, the mock/real API may embed a status error in the JSON body.
# Parse the JSON "status" field with python3 to detect embedded auth failures.
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

# Determine overall success:
# - HTTP status must be 2xx
# - Embedded JSON "status" must not be 4xx/5xx (if present)
auth_failed=0
if [[ "$is_2xx" -eq 0 ]]; then
    auth_failed=1
fi
if [[ -n "$embedded_status" ]] && [[ "$embedded_status" -ge 400 ]]; then
    auth_failed=1
fi

if [[ "$auth_failed" -eq 1 ]]; then
    printf 'Error: Invalid or expired Figma PAT (HTTP %s).\n' "$http_status" >&2
    printf 'Generate a new PAT at https://www.figma.com/settings → Personal access tokens\n' >&2
    printf 'Note: Figma PATs expire after 90 days\n' >&2
    exit 1
fi

exit 0
