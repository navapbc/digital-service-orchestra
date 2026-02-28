#!/usr/bin/env bash
# .claude/hooks/check-validation-failures.sh
# PostToolUse hook: auto-create beads tracking issues for validate.sh failures.
#
# Fires after every Bash tool call. When the command was validate.sh and
# produced FAIL lines, this hook:
#   1. Parses failed check names from the output
#   2. Searches beads for existing open issues matching each failure
#   3. Auto-creates tracking issues for any untracked failures
#   4. Reports what it created (or found) back to the agent
#
# Design: auto-creating bugs at validation time (not commit time) means
# tracking issues exist before any other hook can block the workflow.
# This removes the incentive for agents to circumvent blocking hooks.

# DEFENSE-IN-DEPTH: Guarantee exit 0, suppress stderr, and always produce output.
# Claude Code bugs:
#   #20334 - PostToolUse hooks with tool-specific matchers fire for ALL tools
#   #10463 - Exit 0 with 0 bytes stdout is treated as "hook error"
# Fix: Use empty matcher + internal tool_name guard + always output at least '{}'
_HOOK_HAS_OUTPUT=""
trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi; exit 0' EXIT
exec 2>/dev/null

# Log unexpected errors to JSONL (uses stdout redirect, unaffected by exec 2>)
HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"check-validation-failures.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

# This hook is non-blocking (auto-creates tracking issues) — skip entirely without jq
check_tool jq || exit 0

# Read hook input from stdin
INPUT=$(cat)

# Only act on Bash tool calls
# Guard against malformed JSON: if jq fails, treat as non-Bash and exit 0
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
if [[ "$TOOL_NAME" != "Bash" ]]; then
    exit 0
fi

# Only act on validate.sh commands
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
if [[ "$COMMAND" != *"validate.sh"* ]]; then
    exit 0
fi

# Get the command output
STDOUT=$(echo "$INPUT" | jq -r '.tool_response.stdout // empty' 2>/dev/null || echo "")

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
WORKTREE_NAME=$(basename "${REPO_ROOT:-.}")
ARTIFACTS_DIR="/tmp/lockpick-test-artifacts-${WORKTREE_NAME}"
VALIDATION_STATE_FILE="$ARTIFACTS_DIR/status"
LOGFILE=$(grep '^logfile=' "$VALIDATION_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-)

# Check beads for existing open issues and auto-create missing ones.
declare -a CREATED=()
declare -a ALREADY_TRACKED=()
declare -a FAILED_TO_CREATE=()

# Build search terms per category
search_terms_for() {
    local category="$1"
    case "$category" in
        format)    echo "format-check;format failure;formatting failure" ;;
        ruff)      echo "lint failure;ruff failure;lint-ruff" ;;
        mypy)      echo "mypy failure;mypy error;type check failure;lint-mypy" ;;
        tests)     echo "test failure;test-unit;unit test failure" ;;
        e2e)       echo "e2e failure;e2e test;test-e2e" ;;
        migrate)   echo "migration failure;migrate failure;db-migrate" ;;
        ci|ci*)    echo "ci failure;CI failure;github actions" ;;
        docker)    echo "docker failure;docker start;Docker Desktop" ;;
        *)         echo "$category failure" ;;
    esac
}

# Extract error context from the combined validation log
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
            context=$(grep -i "would reformat\|reformatted\|format-check" "$logfile" 2>/dev/null | head -30) ;;
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
            context=$(grep -A 5 -i "migration\|alembic\|heads\|multiple head" "$logfile" 2>/dev/null | head -30) ;;
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

DESC_TMPFILE=$(mktemp "${TMPDIR:-/tmp}/validation-tracker-desc.XXXXXX")

for category in "${FAILED_CATEGORIES[@]}"; do
    # Search for existing open issues
    IFS=';' read -ra TERMS <<< "$(search_terms_for "$category")"
    FOUND=""
    for term in "${TERMS[@]}"; do
        RESULT=$(bd search "$term" --status=open --quiet 2>/dev/null | grep -vE "^Found [0-9]+ issues|^No issues found" | head -1 || echo "")
        if [[ -n "$RESULT" ]]; then
            FOUND="$RESULT"
            break
        fi
    done

    if [[ -n "$FOUND" ]]; then
        ALREADY_TRACKED+=("$category")
        continue
    fi

    # Auto-create tracking issue
    cat > "$DESC_TMPFILE" <<EODESC
Auto-created by check-validation-failures hook.

Validation log: ${LOGFILE:-unknown}

Error output:
EODESC
    echo '```' >> "$DESC_TMPFILE"
    extract_error_context "$category" "$LOGFILE" >> "$DESC_TMPFILE"
    echo '```' >> "$DESC_TMPFILE"

    ISSUE_ID=$(bd create --title="Fix $category failure" --type=bug --priority=1 --description="$(cat "$DESC_TMPFILE")" 2>/dev/null | grep -o 'beads-[0-9]*' | head -1 || echo "")
    if [[ -n "$ISSUE_ID" ]]; then
        CREATED+=("$category ($ISSUE_ID)")
    else
        FAILED_TO_CREATE+=("$category")
    fi
done

rm -f "$DESC_TMPFILE"

# Report results to the agent — single-line CSV format, silent on zero failures
# Format: "Created: format (beads-123), ruff (beads-456); Tracked: mypy (beads-789)"
# Only categories with results are included; output nothing when all arrays empty.

PARTS=()

if [[ ${#CREATED[@]} -gt 0 ]]; then
    CREATED_CSV=$(IFS=', '; echo "${CREATED[*]}")
    PARTS+=("Created: $CREATED_CSV")
fi

if [[ ${#ALREADY_TRACKED[@]} -gt 0 ]]; then
    TRACKED_CSV=$(IFS=', '; echo "${ALREADY_TRACKED[*]}")
    PARTS+=("Tracked: $TRACKED_CSV")
fi

if [[ ${#FAILED_TO_CREATE[@]} -gt 0 ]]; then
    FAILED_CSV=$(IFS=', '; echo "${FAILED_TO_CREATE[*]}")
    PARTS+=("WARNING could not create issues for: $FAILED_CSV — run: bd q \"Fix <check> failure\" -t bug -p 1")
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
