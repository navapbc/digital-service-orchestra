#!/usr/bin/env bash
# .claude/hooks/check-validation-failures.sh
# PostToolUse hook: report validate.sh failures to the agent.
#
# Fires after every Bash tool call. When the command was validate.sh and
# produced FAIL lines, this hook:
#   1. Parses failed check names from the output
#   2. Logs untracked failures to the artifacts dir
#   3. Reports what it found back to the agent

# DEFENSE-IN-DEPTH: Guarantee exit 0, suppress stderr, and always produce output.
# Claude Code bugs:
#   #20334 - PostToolUse hooks with tool-specific matchers fire for ALL tools
#   #10463 - Exit 0 with 0 bytes stdout is treated as "hook error"
# Fix: Use empty matcher + internal tool_name guard + always output at least '{}'
_HOOK_HAS_OUTPUT=""
trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi; exit 0' EXIT
exec 2>/dev/null

# Log unexpected errors to JSONL (uses stdout redirect, unaffected by exec 2>)
HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"check-validation-failures.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

# Read hook input from stdin
INPUT=$(cat)

# Only act on Bash tool calls
TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
if [[ "$TOOL_NAME" != "Bash" ]]; then
    exit 0
fi

# Only act on validate.sh commands
COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')
if [[ "$COMMAND" != *"validate.sh"* ]]; then
    exit 0
fi

# Get the command output
STDOUT=$(parse_json_field "$INPUT" '.tool_response.stdout')

# Find FAIL/TIMEOUT lines in the validation summary.
# Format: "  label:  FAIL" or "  label:  FAIL (details)" or "  label:  TIMEOUT (...)"
FAILURES=$(echo "$STDOUT" | grep -E '^\s+\S+:\s+(FAIL|TIMEOUT)' || true)

if [[ -z "$FAILURES" ]]; then
    exit 0
fi

# Parse check names from FAIL lines
declare -a FAILED_CATEGORIES=()
while IFS= read -r line; do
    CHECK_NAME=$(echo "$line" | sed 's/^\s*//; s/:.*//' | tr -d '[:space:]')
    if [[ -n "$CHECK_NAME" ]]; then
        FAILED_CATEGORIES+=("$CHECK_NAME")
    fi
done <<< "$FAILURES"

if [[ ${#FAILED_CATEGORIES[@]} -eq 0 ]]; then
    exit 0
fi

# Determine artifacts dir for log file references
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
ARTIFACTS_DIR=$(get_artifacts_dir)
VALIDATION_STATE_FILE="$ARTIFACTS_DIR/status"
# Parse logfile from validate.sh stdout ("Some checks failed. Details: /path/to/file")
# Fall back to state file (written by validate.sh on exit) if stdout parse fails.
LOGFILE=$(echo "$STDOUT" | grep -oE 'Details: /[^[:space:]]+' | head -1 | sed 's/^Details: //' | tr -d '\r\n')
if [[ -z "$LOGFILE" ]]; then
    LOGFILE=$(grep '^logfile=' "$VALIDATION_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
fi

declare -a UNTRACKED=()

# Extract error context from the combined validation log
# shellcheck disable=SC2329
extract_error_context() {
    local category="$1"
    local logfile="$2"
    local context=""

    if [[ -z "$logfile" || ! -f "$logfile" ]]; then
        echo "(no log file available)"
        return
    fi

    case "$category" in
        format)
            context=$(grep -iE "would reformat|reformatted|format-check" "$logfile" 2>/dev/null | head -30) ;;
        ruff)
            context=$(grep -E "^[^ ]+:[0-9]+:[0-9]+: [A-Z]+[0-9]+ " "$logfile" 2>/dev/null | head -30) ;;
        mypy)
            context=$(grep -E "^[^ ]+:[0-9]+: error:" "$logfile" 2>/dev/null | head -30) ;;
        tests)
            context=$(grep -E "^FAILED |[0-9]+ failed" "$logfile" 2>/dev/null | head -30) ;;
        e2e)
            context=$(grep -A 30 "test-e2e" "$logfile" 2>/dev/null | head -30)
            if [[ -z "$context" ]]; then
                context=$(tail -30 "$logfile" 2>/dev/null)
            fi ;;
        migrate)
            context=$(grep -A 5 -iE "migration|alembic|heads|multiple head" "$logfile" 2>/dev/null | head -30) ;;
        ci|ci*)
            context="CI failure detected. Run: gh run list --workflow=CI --limit 3" ;;
        docker)
            context="Docker Desktop failed to start within timeout." ;;
        *)
            context=$(tail -30 "$logfile" 2>/dev/null) ;;
    esac

    if [[ -z "$context" ]]; then
        context=$(tail -30 "$logfile" 2>/dev/null)
    fi
    if [[ -z "$context" ]]; then
        context="(no error details extracted)"
    fi

    echo "$context"
}

for category in "${FAILED_CATEGORIES[@]}"; do
    # Log untracked failure to artifacts dir
    UNTRACKED_LOG="$ARTIFACTS_DIR/untracked-validation-failures.log"
    {
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | UNTRACKED | $category | logfile: ${LOGFILE:-unknown}"
    } >> "$UNTRACKED_LOG" 2>/dev/null || true

    UNTRACKED+=("$category")
done

# Report results to the agent — single-line CSV format, silent on zero failures
# Format: "Tracked: mypy (dso-abc1); Untracked (logged): format, ruff"
# Only categories with results are included; output nothing when all arrays empty.

PARTS=()

if [[ ${#UNTRACKED[@]} -gt 0 ]]; then
    UNTRACKED_CSV=$(IFS=', '; echo "${UNTRACKED[*]}")
    PARTS+=("Untracked (logged to artifacts): $UNTRACKED_CSV")
fi

if [[ ${#PARTS[@]} -gt 0 ]]; then
    _HOOK_HAS_OUTPUT=1
    # Join all parts with '; '
    OUTPUT=""
    for part in "${PARTS[@]}"; do
        if [[ -z "$OUTPUT" ]]; then
            OUTPUT="$part"
        else
            OUTPUT="$OUTPUT; $part"
        fi
    done
    echo "$OUTPUT"
fi

exit 0
