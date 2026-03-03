#!/usr/bin/env bash
# lockpick-workflow/hooks/tool-use-guard.sh
# PreToolUse hook (Bash matcher): warns when cat/head/tail/grep/rg are used
# via Bash instead of the dedicated Read/Grep tools.
#
# Replaces hookify rules: cat-read-enforcement, grep-read-enforcement
#
# WARNING ONLY (exit 0 + stderr) — agents may have legitimate reasons to use
# these commands (pipes, redirects, scripts).
#
# Fast-path optimization: extracts first token with bash-only parsing before
# sourcing deps.sh, so 95%+ of Bash calls skip the heavier parse entirely.

HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"tool-use-guard.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# Fast-path: read stdin and extract first token without jq
RAW_INPUT=$(cat)

# Quick extraction of command field — look for "command":" then grab content
# This avoids sourcing deps.sh for the 95%+ of Bash calls that aren't cat/grep
QUICK_CMD=""
if [[ "$RAW_INPUT" =~ \"command\"[[:space:]]*:[[:space:]]*\" ]]; then
    local_after="${RAW_INPUT#*\"command\"*:*\"}"
    # Get first token (up to first space or quote)
    QUICK_CMD="${local_after%%[[:space:]\"]*}"
fi

# Fast exit if first token isn't one of our targets
case "$QUICK_CMD" in
    cat|head|tail|grep|rg) ;;
    *) exit 0 ;;
esac

# Slow path: source deps and parse properly
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

COMMAND=$(parse_json_field "$RAW_INPUT" '.tool_input.command')
if [[ -z "$COMMAND" ]]; then
    exit 0
fi

# Extract just the first token of the command
FIRST_TOKEN="${COMMAND%%[[:space:]]*}"

# cat/head/tail check
if [[ "$FIRST_TOKEN" == "cat" || "$FIRST_TOKEN" == "head" || "$FIRST_TOKEN" == "tail" ]]; then
    # Allow if command has pipe, heredoc, or redirect (legitimate shell usage)
    if [[ "$COMMAND" == *"|"* || "$COMMAND" == *"<<"* || "$COMMAND" == *">"* ]]; then
        exit 0
    fi
    echo "WARNING [tool-use-guard]: Consider using the Read tool instead of $FIRST_TOKEN. It provides line numbers and is more token-efficient." >&2
    exit 0
fi

# grep/rg check
if [[ "$FIRST_TOKEN" == "grep" || "$FIRST_TOKEN" == "rg" ]]; then
    # Allow if command has pipe or redirect
    if [[ "$COMMAND" == *"|"* || "$COMMAND" == *">"* ]]; then
        exit 0
    fi
    # Allow if part of known exempt contexts (scripts, make targets, git commands)
    if [[ "$COMMAND" == *"git "* || "$COMMAND" == *"make "* || \
          "$COMMAND" == *"validate"* || "$COMMAND" == *"ci-status"* || \
          "$COMMAND" == *"check_assertion_density"* ]]; then
        exit 0
    fi
    echo "WARNING [tool-use-guard]: Consider using the Grep tool instead of $FIRST_TOKEN. It has structured output and optimized permissions." >&2
    exit 0
fi

exit 0
