#!/bin/bash
# Example: Check if Claude Code session usage (5-hour rolling) exceeds a threshold
#
# Exit codes:
#   0 = usage is ABOVE threshold (true — throttle/warn)
#   1 = usage is BELOW threshold (false — safe to proceed)
#   2 = error (missing token, API failure, or parse error — callers should treat as unknown)
#
# Prints "true" on exit 0, "false" on exit 1, "error" on exit 2.
# Useful in hooks to throttle sub-agents or warn before hitting rate limits.
#
# Requirements: jq, curl
# macOS-specific: Uses `security` CLI to read OAuth token from Keychain.
#   For Linux, replace the token retrieval with your platform's equivalent.

THRESHOLD=90

# Fetch OAuth token from macOS Keychain
token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken' 2>/dev/null)

if [ -z "$token" ] || [ "$token" = "null" ]; then
    echo "error"
    exit 2
fi

response=$(curl -s --max-time 8 \
    -H "Authorization: Bearer ${token}" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

# Treat empty response or API error as unknown — exit 2 so callers can distinguish
# from a normal "below threshold" result (exit 1).
if [ -z "$response" ]; then
    echo "error"
    exit 2
fi

if echo "$response" | jq -e '.type == "error"' >/dev/null 2>&1; then
    echo "error"
    exit 2
fi

five_hour=$(echo "$response" | jq -r '.five_hour.utilization // 0')
session_pct=$(printf "%.0f" "$five_hour")

if [ "$session_pct" -gt "$THRESHOLD" ] 2>/dev/null; then
    echo "true"
    exit 0
else
    echo "false"
    exit 1
fi
