#!/bin/bash
# Example: Claude Code Status Line - Context, Session & Weekly Usage Percentages
#
# Shows: Model | Ctx: X% | Session: Y% (resets H:MM PM) | Week: Z% (branch)
#
# Setup:
#   1. Copy this file to ~/.claude/statusline.sh
#   2. chmod +x ~/.claude/statusline.sh
#   3. Add to ~/.claude/settings.json (or settings.local.json):
#      { "statusLine": { "type": "command", "command": "~/.claude/statusline.sh" } }
#
# Requirements: jq, curl, git
# macOS-specific: Uses `security` CLI to read OAuth token from Keychain and
#   `date -jf` for ISO 8601 parsing. For Linux, replace the token retrieval
#   and date parsing with platform-appropriate equivalents.

# Read JSON input from stdin (Claude Code passes session context as JSON)
input=$(cat)

# Extract data from status line JSON
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
model=$(echo "$input" | jq -r '.model.display_name')
context_pct=$(echo "$input" | jq -r '.context_window.used_percentage // "0"')

# Format directory
dir="${cwd/#$HOME/~}"

# Git branch
branch=$(git -C "$cwd" branch --show-current 2>/dev/null || echo '')
git_info=''
[ -n "$branch" ] && git_info=" ($branch)"

# Context percentage (how full the conversation is)
context_fmt=$(printf "%.0f" "${context_pct:-0}" 2>/dev/null || echo "0")

# Usage from Anthropic API (cached for 60 seconds)
CACHE_FILE="$HOME/.claude/.usage-cache.json"
CACHE_MAX_AGE=60

get_usage() {
    local now=$(date +%s)
    local cache_valid=false

    # Check cache
    if [ -f "$CACHE_FILE" ]; then
        local cache_time=$(jq -r '.timestamp // 0' "$CACHE_FILE" 2>/dev/null)
        local age=$((now - cache_time))
        if [ "$age" -lt "$CACHE_MAX_AGE" ]; then
            cache_valid=true
        fi
    fi

    if [ "$cache_valid" = true ]; then
        cat "$CACHE_FILE"
        return
    fi

    # Fetch OAuth token from macOS Keychain
    # On Linux, replace this with your token retrieval method
    local token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken' 2>/dev/null)

    if [ -z "$token" ] || [ "$token" = "null" ]; then
        echo '{"five_hour_pct":"?","seven_day_pct":"?"}'
        return
    fi

    local response=$(curl -s --max-time 8 \
        -H "Authorization: Bearer ${token}" \
        -H "anthropic-beta: oauth-2025-04-20" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

    # Treat empty response or API error as failure
    local is_error=false
    if [ -z "$response" ]; then
        is_error=true
    elif echo "$response" | jq -e '.type == "error"' >/dev/null 2>&1; then
        is_error=true
    fi

    if [ "$is_error" = true ]; then
        # Use stale cached values only if they contain real numeric data (not "?" from a prior error).
        # The condition below explicitly rejects "?" values to avoid perpetuating stale error state
        # indefinitely: if the cache holds "?" from a previous failure, we fall through to the
        # live "?" response rather than re-serving the stale error cache.
        if [ -f "$CACHE_FILE" ] && jq -e '(.five_hour_pct | type) == "string" and (.five_hour_pct | test("^[0-9]+$")) and (.seven_day_pct | type) == "string" and (.seven_day_pct | test("^[0-9]+$"))' "$CACHE_FILE" >/dev/null 2>&1; then
            cat "$CACHE_FILE"
        else
            echo "{\"timestamp\": $now, \"five_hour_pct\": \"?\", \"seven_day_pct\": \"?\", \"resets_at\": \"?\"}"
        fi
        return
    fi

    # Extract utilization (already percentages like 82.0 = 82%)
    local five_hour=$(echo "$response" | jq -r '.five_hour.utilization // 0')
    local seven_day=$(echo "$response" | jq -r '.seven_day.utilization // 0')
    local five_hour_pct=$(printf "%.0f" "$five_hour")
    local seven_day_pct=$(printf "%.0f" "$seven_day")

    # Extract reset time (ISO 8601 → local HH:MM)
    local resets_at_raw=$(echo "$response" | jq -r '.five_hour.resets_at // empty')
    local resets_at="?"
    if [ -n "$resets_at_raw" ]; then
        # Normalize: strip fractional seconds and timezone suffix (handles +00:00 and Z)
        local normalized=$(echo "$resets_at_raw" | sed 's/\.[0-9]*//' | sed 's/+00:00$//' | sed 's/Z$//')
        # Parse UTC timestamp to epoch, then convert to local time (macOS date syntax)
        local epoch=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "$normalized" +%s 2>/dev/null)
        if [ -n "$epoch" ]; then
            resets_at=$(date -r "$epoch" +"%l:%M %p" 2>/dev/null | xargs)
        fi
    fi

    # Cache the result
    local cache_data="{\"timestamp\": $now, \"five_hour_pct\": \"$five_hour_pct\", \"seven_day_pct\": \"$seven_day_pct\", \"resets_at\": \"$resets_at\"}"
    echo "$cache_data" > "$CACHE_FILE"
    echo "$cache_data"
}

usage_data=$(get_usage)
session_pct=$(echo "$usage_data" | jq -r '.five_hour_pct // "?"')
weekly_pct=$(echo "$usage_data" | jq -r '.seven_day_pct // "?"')
resets_at=$(echo "$usage_data" | jq -r '.resets_at // "?"')

# Build status line
# Format: Model | Ctx: X% | Session: Y% (resets H:MM PM) | Week: Z% (branch)
printf "%s | Ctx: %s%% | Session: %s%% (resets %s) | Week: %s%%%s" \
    "$model" \
    "$context_fmt" \
    "$session_pct" \
    "$resets_at" \
    "$weekly_pct" \
    "$git_info"
