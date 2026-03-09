#!/usr/bin/env bash
# .claude/hooks/commit-failure-tracker.sh
# PreToolUse hook (Bash matcher): at git commit time, warn if validation
# failures exist without corresponding open tracking issues.
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

# Read config-driven issue tracker commands (with fallback defaults)
# Resolve read-config.sh: try HOOK_DIR/../scripts (lockpick-workflow/hooks/ path),
# then HOOK_DIR/../../lockpick-workflow/scripts (.claude/hooks/ path).
# Capture whether caller supplied env vars BEFORE applying defaults.
_SEARCH_CMD_FROM_ENV="${SEARCH_CMD:-}"
_CREATE_CMD_FROM_ENV="${CREATE_CMD:-}"
SEARCH_CMD="${SEARCH_CMD:-grep -rl}"
CREATE_CMD="${CREATE_CMD:-tk create}"
_READ_CONFIG=""
if [[ -f "$HOOK_DIR/../scripts/read-config.sh" ]]; then
    _READ_CONFIG="$HOOK_DIR/../scripts/read-config.sh"
elif [[ -f "$HOOK_DIR/../../lockpick-workflow/scripts/read-config.sh" ]]; then
    _READ_CONFIG="$HOOK_DIR/../../lockpick-workflow/scripts/read-config.sh"
fi
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
   [[ "$FIRST_LINE" != *"merge-to-main"* ]]; then
    exit 0
fi

# Exempt: WIP, merge, pre-compact
if [[ "$COMMAND" =~ [Ww][Ii][Pp] ]] || [[ "$COMMAND" =~ --no-edit ]] || \
   [[ "$COMMAND" =~ git[[:space:]].*merge[[:space:]] ]] || \
   [[ "$COMMAND" =~ pre-compact ]] || [[ "$COMMAND" =~ checkpoint ]]; then
    exit 0
fi

# Only apply config overrides when the caller did NOT supply the env var.
# Caller-supplied env vars (e.g. test mocks) take precedence over config.
# Deferred to here (after early exits) to avoid spawning Python for non-commit commands.
if [[ -n "$_READ_CONFIG" ]] && [[ -z "$_SEARCH_CMD_FROM_ENV" ]]; then
    _SEARCH=$("$_READ_CONFIG" issue_tracker.search_cmd 2>/dev/null || echo '')
    [[ -n "$_SEARCH" ]] && SEARCH_CMD="$_SEARCH"
fi
if [[ -n "$_READ_CONFIG" ]] && [[ -z "$_CREATE_CMD_FROM_ENV" ]]; then
    _CREATE=$("$_READ_CONFIG" issue_tracker.create_cmd 2>/dev/null || echo '')
    [[ -n "$_CREATE" ]] && CREATE_CMD="$_CREATE"
fi

# Check validation state
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$REPO_ROOT" ]]; then
    exit 0
fi

ARTIFACTS_DIR=$(get_artifacts_dir)
VALIDATION_STATE_FILE="$ARTIFACTS_DIR/status"

# Backward-compat: also check old-style artifacts path for test environments that
# write validation state to /tmp/lockpick-test-artifacts-<worktree>/status.
_OLD_ARTIFACTS_DIR="/tmp/lockpick-test-artifacts-$(basename "$REPO_ROOT")"
if [[ ! -f "$VALIDATION_STATE_FILE" ]] && [[ -f "$_OLD_ARTIFACTS_DIR/status" ]]; then
    VALIDATION_STATE_FILE="$_OLD_ARTIFACTS_DIR/status"
elif [[ -f "$VALIDATION_STATE_FILE" ]] && [[ -f "$_OLD_ARTIFACTS_DIR/status" ]]; then
    _OLD_STATUS=$(head -n 1 "$_OLD_ARTIFACTS_DIR/status" 2>/dev/null || echo "")
    if [[ "$_OLD_STATUS" == "failed" ]]; then
        VALIDATION_STATE_FILE="$_OLD_ARTIFACTS_DIR/status"
    fi
fi

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
    # Substring search in .tickets/ files — if any ticket file mentions the category, it's tracked
    RESULT=$($SEARCH_CMD "$category failure" "$(git rev-parse --show-toplevel)/.tickets" 2>/dev/null | head -1 || echo "")
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
echo "Search: $SEARCH_CMD '<check> failure' $(git rev-parse --show-toplevel)/.tickets" >&2
echo "Create manually if needed: tk create \"Fix <check> failure\" -t bug -p 1" >&2
echo "" >&2

# Never block
exit 0
