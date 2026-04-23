#!/usr/bin/env bash
# .claude/hooks/track-cascade-failures.sh
# PostToolUse hook: track consecutive fix-fail cycles to detect fix cascades
#
# Monitors Bash tool calls for test/lint runs. When a test run fails:
#   - Hashes the error signature (Error/FAILED/Exception lines)
#   - Compares to the previous error hash
#   - If DIFFERENT error: increments cascade counter (fix caused new problems)
#   - If SAME error: does NOT increment (still debugging same issue)
#   - If test PASSES: resets counter and clears error hash
#
# State is isolated per worktree via git toplevel path hash.
# State files: /tmp/claude-cascade-<worktree-hash>/counter
#              /tmp/claude-cascade-<worktree-hash>/last-error-hash
#
# Paired with cascade-circuit-breaker.sh (PreToolUse on Edit/Write).

# DEFENSE-IN-DEPTH: Guarantee exit 0, suppress stderr, and always produce output.
# Claude Code bugs #20334 (matcher fires for all tools) and #10463 (0-byte
# stdout treated as hook error). Fix: always output at least '{}' via EXIT trap.
_HOOK_HAS_OUTPUT=""
trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi; exit 0' EXIT
exec 2>/dev/null

# Log unexpected errors to JSONL (uses stdout redirect, unaffected by exec 2>)
HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"track-cascade-failures.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

# --- Read hook input ---
INPUT=$(cat)

TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
if [[ "$TOOL_NAME" != "Bash" ]]; then
    exit 0
fi

# --- Only act on test/lint commands ---
COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')

# Match test and lint commands that indicate a fix-then-verify cycle
IS_TEST_CMD=false
case "$COMMAND" in
    *"make test"*|*"make lint"*|*"make format-check"*|*"pytest"*|*"validate.sh"*)
        IS_TEST_CMD=true
        ;;
esac

if [[ "$IS_TEST_CMD" != "true" ]]; then
    exit 0
fi

# --- Resolve worktree-scoped state directory ---
WORKTREE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$WORKTREE_ROOT" ]]; then
    exit 0
fi

# Create deterministic hash from worktree path for state isolation
if command -v md5 &>/dev/null; then
    WT_HASH=$(echo -n "$WORKTREE_ROOT" | md5)
elif command -v md5sum &>/dev/null; then
    WT_HASH=$(echo -n "$WORKTREE_ROOT" | md5sum | cut -d' ' -f1)
else
    # Fallback: use simple string substitution
    WT_HASH=$(echo -n "$WORKTREE_ROOT" | tr '/' '_')
fi

STATE_DIR="/tmp/claude-cascade-${WT_HASH}"
mkdir -p "$STATE_DIR"

COUNTER_FILE="$STATE_DIR/counter"
HASH_FILE="$STATE_DIR/last-error-hash"
STALE_MINUTES=30

# --- Staleness check ---
if [[ -f "$COUNTER_FILE" ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        FILE_MOD=$(stat -f %m "$COUNTER_FILE" 2>/dev/null || echo 0)
    else
        FILE_MOD=$(stat -c %Y "$COUNTER_FILE" 2>/dev/null || echo 0)
    fi
    NOW=$(date +%s)
    AGE=$(( NOW - FILE_MOD ))
    if (( AGE > STALE_MINUTES * 60 )); then
        echo "0" > "$COUNTER_FILE"
        rm -f "$HASH_FILE"
    fi
fi

# --- Get command output and exit code ---
STDOUT=$(parse_json_field "$INPUT" '.tool_response.stdout')
STDERR=$(parse_json_field "$INPUT" '.tool_response.stderr')
COMBINED_OUTPUT="${STDOUT}${STDERR}"

# --- Determine pass/fail ---
# Check for common failure indicators
HAS_FAILURE=false

# pytest failures
if echo "$COMBINED_OUTPUT" | grep -qE '(FAILED|ERROR|ERRORS)' 2>/dev/null; then
    HAS_FAILURE=true
fi

# make/validate failures
if echo "$COMBINED_OUTPUT" | grep -qE '(FAIL|Error:|error:|make.*Error|CalledProcessError)' 2>/dev/null; then
    HAS_FAILURE=true
fi

# mypy failures (exclude "Found 0 errors" which is a passing run)
if echo "$COMBINED_OUTPUT" | grep -qE '(error: |Found [1-9][0-9]* error)' 2>/dev/null; then
    HAS_FAILURE=true
fi

# --- Handle pass: reset everything ---
if [[ "$HAS_FAILURE" != "true" ]]; then
    echo "0" > "$COUNTER_FILE"
    rm -f "$HASH_FILE"
    exit 0
fi

# --- Handle fail: compute normalized error signature and compare ---
# Extract error-relevant lines, then normalize to remove incidental variation
# (line numbers, file paths, PIDs, timestamps, memory addresses) so that
# the same logical error produces the same hash even after edits shift line numbers.
ERROR_SIG=$(echo "$COMBINED_OUTPUT" \
    | grep -E '(Error|FAILED|FAIL|assert|Exception|error:|TypeError|ValueError|AttributeError|ImportError|NameError|KeyError|SyntaxError)' \
    | head -30 \
    | sed -E 's|/[^ ]*\/||g' \
    | sed -E 's/:[0-9]+//g' \
    | sed -E 's/line [0-9]+/line N/g' \
    | sed -E 's/0x[0-9a-fA-F]+/0xN/g' \
    | sed -E 's/[0-9]{4,}/N/g' \
    | sort)

if command -v md5 &>/dev/null; then
    CURRENT_HASH=$(echo "$ERROR_SIG" | md5)
elif command -v md5sum &>/dev/null; then
    CURRENT_HASH=$(echo "$ERROR_SIG" | md5sum | cut -d' ' -f1)
else
    CURRENT_HASH=$(echo "$ERROR_SIG" | cksum | cut -d' ' -f1)
fi

PREV_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")

# Read current counter
if [[ -f "$COUNTER_FILE" ]]; then
    COUNTER=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
    if ! [[ "$COUNTER" =~ ^[0-9]+$ ]]; then
        COUNTER=0
    fi
else
    COUNTER=0
fi

if [[ "$CURRENT_HASH" != "$PREV_HASH" ]]; then
    # Different error signature — this fix caused new/different problems
    COUNTER=$(( COUNTER + 1 ))
    echo "$COUNTER" > "$COUNTER_FILE"
    echo "$CURRENT_HASH" > "$HASH_FILE"

    # Early warning at 3/5 — the hard block at 5/5 is handled by cascade-circuit-breaker.sh
    if (( COUNTER >= 3 && COUNTER < 5 )); then
        _HOOK_HAS_OUTPUT=1
        echo "# FIX CASCADE CAUTION"
        echo ""
        echo "Cascade counter: **$COUNTER/5** — $COUNTER different error signatures in consecutive fix attempts."
        echo "Consider stepping back to analyze the root cause before continuing."
    fi
else
    # Same error signature — still debugging the same issue, don't increment
    echo "$CURRENT_HASH" > "$HASH_FILE"
fi

exit 0
