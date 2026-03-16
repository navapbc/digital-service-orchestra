#!/usr/bin/env bash
# tests/scripts/test-log-dispatch.sh
# Baseline tests for scripts/log-dispatch.sh
#
# Usage: bash tests/scripts/test-log-dispatch.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$PLUGIN_ROOT/scripts/log-dispatch.sh"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-log-dispatch.sh ==="

# ── Test 1: Script is executable ──────────────────────────────────────────────
echo "Test 1: Script is executable"
if [ -x "$SCRIPT" ]; then
    echo "  PASS: script is executable"
    (( PASS++ ))
else
    echo "  FAIL: script is not executable" >&2
    (( FAIL++ ))
fi

# ── Test 2: No args exits 1 with usage text ──────────────────────────────────
echo "Test 2: No args exits 1 with usage"
run_test "missing required args exits 1 with usage" 1 "[Uu]sage" bash "$SCRIPT"

# ── Test 3: Only 1 arg (missing agent type) exits 1 ─────────────────────────
echo "Test 3: Only session_id exits 1"
run_test "missing agent_type arg exits 1" 1 "" bash "$SCRIPT" "session-123"

# ── Test 4: Valid dispatch writes JSONL entry ─────────────────────────────────
echo "Test 4: Valid dispatch writes JSONL entry to log file"
TEST_LOG_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$TEST_LOG_DIR")
exit_code=0
HOME="$TEST_LOG_DIR" bash "$SCRIPT" "session-test-123" "debugging-toolkit:debugger" "TASK-42" 2>&1 || exit_code=$?
LOG_FILE="$TEST_LOG_DIR/.claude/logs/dispatch-$(date +%Y-%m-%d).jsonl"
if [ "$exit_code" -eq 0 ] && [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
    echo "  PASS: dispatch writes JSONL entry to log file"
    (( PASS++ ))
else
    echo "  FAIL: dispatch did not write JSONL entry (exit=$exit_code, exists=$(test -f "$LOG_FILE" && echo yes || echo no))" >&2
    (( FAIL++ ))
fi
rm -rf "$TEST_LOG_DIR"

# ── Test 5: Written JSONL entry is valid JSON ─────────────────────────────────
echo "Test 5: Written JSONL entry is valid JSON"
TEST_LOG_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$TEST_LOG_DIR")
HOME="$TEST_LOG_DIR" bash "$SCRIPT" "session-test-456" "code-review:reviewer" "" 2>&1 || true
LOG_FILE="$TEST_LOG_DIR/.claude/logs/dispatch-$(date +%Y-%m-%d).jsonl"
if [ -f "$LOG_FILE" ]; then
    entry=$(tail -1 "$LOG_FILE")
    if echo "$entry" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        echo "  PASS: written entry is valid JSON"
        (( PASS++ ))
    else
        echo "  FAIL: written entry is not valid JSON: $entry" >&2
        (( FAIL++ ))
    fi
else
    echo "  FAIL: log file was not created" >&2
    (( FAIL++ ))
fi
rm -rf "$TEST_LOG_DIR"

# ── Test 6: JSONL entry contains expected fields ─────────────────────────────
echo "Test 6: JSONL entry contains ts, session_id, assigned_agent, task_id fields"
TEST_LOG_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$TEST_LOG_DIR")
HOME="$TEST_LOG_DIR" bash "$SCRIPT" "session-xyz" "sprint:orchestrator" "LOCK-99" 2>&1 || true
LOG_FILE="$TEST_LOG_DIR/.claude/logs/dispatch-$(date +%Y-%m-%d).jsonl"
if [ -f "$LOG_FILE" ]; then
    entry=$(tail -1 "$LOG_FILE")
    if echo "$entry" | python3 -c "
import sys, json
d = json.load(sys.stdin)
required = ['ts', 'session_id', 'assigned_agent', 'task_id']
missing = [k for k in required if k not in d]
if missing:
    print('Missing fields:', missing, file=sys.stderr)
    sys.exit(1)
" 2>/dev/null; then
        echo "  PASS: JSONL entry contains all required fields"
        (( PASS++ ))
    else
        echo "  FAIL: JSONL entry missing required fields. Entry: $entry" >&2
        (( FAIL++ ))
    fi
else
    echo "  FAIL: log file was not created" >&2
    (( FAIL++ ))
fi
rm -rf "$TEST_LOG_DIR"

# ── Test 7: No bash syntax errors ─────────────────────────────────────────────
echo "Test 7: No bash syntax errors"
if bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors"
    (( PASS++ ))
else
    echo "  FAIL: syntax errors found" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
