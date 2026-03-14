#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-tk-close-venv-warning.sh
#
# Tests for `tk close` worktree/venv warning behavior.
#
# Bug: tk close writes status to the file but gives no indication that the
# change hasn't been committed. In worktrees without a Python venv, the
# subsequent git commit via pre-commit hooks will fail, leaving a silent
# partial-close state.
#
# Fix: tk close now prints a warning when it detects that pre-commit
# hooks may fail (venv absent), instructing the user to commit manually
# or via merge-to-main.sh.
#
# Usage: bash lockpick-workflow/tests/scripts/test-tk-close-venv-warning.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TK_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/tk"

source "$SCRIPT_DIR/../lib/run_test.sh"

echo "=== test-tk-close-venv-warning.sh ==="

# ── Helpers ──────────────────────────────────────────────────────────────────

make_ticket() {
    local dir="$1"
    local id="$2"
    local status="${3:-open}"
    cat > "$dir/${id}.md" <<EOF
---
id: ${id}
status: ${status}
title: Ticket ${id}
deps: []
links: []
created: 2026-03-08T00:00:00Z
type: task
priority: 2
---
# Ticket ${id}
EOF
}

# ── Test 1: tk close succeeds writing the file (no venv dependency) ──────────

echo "Test 1: tk close writes status to closed"
TMPDIR_T1=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T1"

make_ticket "$TMPDIR_T1" "test-aaa" "in_progress"

output=$("$TK_SCRIPT" close test-aaa --reason="test closure" 2>&1)
exit_code=$?

status_after=$(grep '^status:' "$TMPDIR_T1/test-aaa.md" | awk '{print $2}')
if [[ "$exit_code" -eq 0 ]] && [[ "$status_after" == "closed" ]]; then
    echo "  PASS: tk close wrote status=closed (was in_progress)"
    (( PASS++ ))
else
    echo "  FAIL: expected status=closed, got status=$status_after, exit=$exit_code" >&2
    echo "  output: $output" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T1"

# ── Test 2: tk close prints venv warning when venv is absent ─────────────────

echo "Test 2: tk close prints venv warning when app/.venv is absent"
TMPDIR_T2=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T2"

# Create a fake repo structure without a venv
mkdir -p "$TMPDIR_T2/app"
# Ensure no .venv exists
rm -rf "$TMPDIR_T2/app/.venv"

make_ticket "$TMPDIR_T2" "test-bbb" "in_progress"

# Set TK_REPO_ROOT to our fake repo (no venv)
output=$(TK_REPO_ROOT="$TMPDIR_T2" "$TK_SCRIPT" close test-bbb --reason="test" 2>&1)
exit_code=$?

if [[ "$exit_code" -eq 0 ]] && echo "$output" | grep -qi "warning\|commit\|merge-to-main"; then
    echo "  PASS: tk close printed venv/commit warning"
    (( PASS++ ))
else
    echo "  FAIL: expected warning about commit/venv in output" >&2
    echo "  exit=$exit_code output: $output" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T2"

# ── Test 3: tk close does NOT print venv warning when venv exists ────────────

echo "Test 3: tk close does not print venv warning when venv exists"
TMPDIR_T3=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T3"

# Create a fake repo structure WITH a venv
mkdir -p "$TMPDIR_T3/app/.venv/bin"
touch "$TMPDIR_T3/app/.venv/bin/python"
chmod +x "$TMPDIR_T3/app/.venv/bin/python"

make_ticket "$TMPDIR_T3" "test-ccc" "in_progress"

output=$(TK_REPO_ROOT="$TMPDIR_T3" "$TK_SCRIPT" close test-ccc --reason="test" 2>&1)
exit_code=$?

if [[ "$exit_code" -eq 0 ]] && ! echo "$output" | grep -qi "warning.*venv\|pre-commit.*fail"; then
    echo "  PASS: no venv warning when venv exists"
    (( PASS++ ))
else
    echo "  FAIL: unexpected venv warning when venv exists" >&2
    echo "  exit=$exit_code output: $output" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T3"

# ── Test 4: tk close reason is written before warning ────────────────────────

echo "Test 4: tk close writes reason note even when venv absent"
TMPDIR_T4=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T4"

mkdir -p "$TMPDIR_T4/app"

make_ticket "$TMPDIR_T4" "test-ddd" "in_progress"

output=$(TK_REPO_ROOT="$TMPDIR_T4" "$TK_SCRIPT" close test-ddd --reason="Fixed: updated config" 2>&1)
exit_code=$?

if [[ "$exit_code" -eq 0 ]] && grep -q "CLOSE REASON: Fixed: updated config" "$TMPDIR_T4/test-ddd.md"; then
    echo "  PASS: reason note written correctly"
    (( PASS++ ))
else
    echo "  FAIL: reason note not found in ticket file" >&2
    echo "  exit=$exit_code" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T4"

# ── Report ────────────────────────────────────────────────────────────────────

print_results
