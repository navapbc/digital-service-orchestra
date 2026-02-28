#!/usr/bin/env bash
# .claude/hooks/commit-failure-tracker.sh
# PreToolUse hook (Bash matcher): at git commit time, warn if validation
# failures exist without corresponding open beads issues.
#
# This is a lightweight safety net. The primary issue creation happens in
# check-validation-failures.sh (PostToolUse) at validation time. This hook
# only warns if somehow issues are still missing at commit time.
#
# NEVER BLOCKS — warnings only (exit 0).

HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"commit-failure-tracker.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

# This hook is non-blocking (warnings only) — skip entirely without jq
check_tool jq || exit 0

INPUT=$(cat)

# Only act on Bash tool calls
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
if [[ "$TOOL_NAME" != "Bash" ]]; then
    exit 0
fi

# Only act on git commit commands (unanchored to catch && chains)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
FIRST_LINE=$(echo "$COMMAND" | head -1)
if ! [[ "$FIRST_LINE" =~ (^|[[:space:]|&;])git[[:space:]]+commit([[:space:]]|$) ]] && \
   ! [[ "$FIRST_LINE" =~ (^|[[:space:]|&;])git[[:space:]]+-[^[:space:]]+.*[[:space:]]commit([[:space:]]|$) ]] && \
   [[ "$FIRST_LINE" != *"sprintend-merge"* ]]; then
    exit 0
fi

# Exempt: WIP, merge, pre-compact
if [[ "$COMMAND" =~ [Ww][Ii][Pp] ]] || [[ "$COMMAND" =~ --no-edit ]] || \
   [[ "$COMMAND" =~ git[[:space:]].*merge[[:space:]] ]] || \
   [[ "$COMMAND" =~ pre-compact ]] || [[ "$COMMAND" =~ checkpoint ]]; then
    exit 0
fi

# Check validation state
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$REPO_ROOT" ]]; then
    exit 0
fi

ARTIFACTS_DIR=$(get_artifacts_dir)
VALIDATION_STATE_FILE="$ARTIFACTS_DIR/status"

if [[ ! -f "$VALIDATION_STATE_FILE" ]]; then
    exit 0
fi

VALIDATION_STATUS=$(head -n 1 "$VALIDATION_STATE_FILE" 2>/dev/null || echo "")
if [[ "$VALIDATION_STATUS" != "failed" ]]; then
    exit 0
fi

# Read failed checks from status file
FAILED_CHECKS_RAW=$(grep '^failed_checks=' "$VALIDATION_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-)

declare -a FAILED_CATEGORIES=()
if [[ -n "$FAILED_CHECKS_RAW" ]]; then
    IFS=',' read -ra FAILED_CATEGORIES <<< "$FAILED_CHECKS_RAW"
else
    FAILED_CATEGORIES+=("validation")
fi

# Quick check: do open issues exist for each category?
declare -a UNTRACKED=()
for category in "${FAILED_CATEGORIES[@]}"; do
    # Simple substring search — if any open issue mentions the category, it's tracked
    RESULT=$(bd search "$category failure" --status=open --quiet 2>/dev/null | grep -vE "^Found [0-9]+ issues|^No issues found" | head -1 || echo "")
    if [[ -z "$RESULT" ]]; then
        UNTRACKED+=("$category")
    fi
done

if [[ ${#UNTRACKED[@]} -eq 0 ]]; then
    exit 0
fi

# Warn (never block) about untracked failures
echo "# WARNING: UNTRACKED VALIDATION FAILURES" >&2
echo "" >&2
echo "These failures have no open tracking issues:" >&2
for category in "${UNTRACKED[@]}"; do
    echo "  - $category" >&2
done
echo "" >&2
echo "Issues should have been auto-created by check-validation-failures.sh." >&2
echo "Create manually if needed: bd q \"Fix <check> failure\" -t bug -p 1" >&2
echo "" >&2

# Never block
exit 0
