#!/usr/bin/env bash
# lockpick-workflow/hooks/review-integrity-guard.sh
# PreToolUse hook (Bash matcher): blocks direct writes to review-status files.
#
# Replaces hookify rule: block-fabricated-review-hash
#
# The review-status file must only be written by record-review.sh after a real
# code-reviewer sub-agent dispatch. Direct writes bypass review integrity.
#
# BLOCK (exit 2) — this protects a critical safety invariant.
#
# Exemptions:
#   - Commands containing record-review.sh (legitimate invocation)
#   - Writes to plan-review-status (different workflow, different file)

HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"review-integrity-guard.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

INPUT=$(cat)

COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')
if [[ -z "$COMMAND" ]]; then
    exit 0
fi

# Allow legitimate record-review.sh invocations
if [[ "$COMMAND" == *"record-review.sh"* ]]; then
    exit 0
fi

# Check for direct writes to review-status (but NOT plan-review-status)
# Pattern: redirect or tee targeting any path ending in /review-status
if [[ "$COMMAND" =~ (>|>>|tee)[[:space:]]*[^[:space:]]*review-status ]]; then
    # Exclude plan-review-status
    if [[ "$COMMAND" == *"plan-review-status"* ]]; then
        exit 0
    fi
    echo "BLOCKED [review-integrity-guard]: Direct write to review-status file." >&2
    echo "Use the review workflow (record-review.sh) instead." >&2
    echo "See CLAUDE.md rule #14: Never manually generate review JSON." >&2
    exit 2
fi

exit 0
