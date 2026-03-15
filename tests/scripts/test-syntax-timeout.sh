#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-syntax-timeout.sh
# Tests verifying that syntax check timeout is 60s and check_bash uses
# parallel execution via ThreadPoolExecutor.
#
# Root cause (ticket lockpick-doc-to-logic-r1ta):
#   check-file-syntax.py's check_bash() spawned sequential subprocess calls
#   for 300+ .sh files, consistently exceeding the 30s timeout. Fix: parallel
#   execution with ThreadPoolExecutor + timeout raised to 60s.
#
# Usage: bash lockpick-workflow/tests/scripts/test-syntax-timeout.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
VALIDATE_SH="$REPO_ROOT/lockpick-workflow/scripts/validate.sh"
SYNTAX_PY="$REPO_ROOT/lockpick-workflow/scripts/check-file-syntax.py"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-syntax-timeout.sh ==="

# ── test_default_timeout_syntax_is_60 ──────────────────────────────────
_snapshot_fail
actual_default=$(grep 'TIMEOUT_SYNTAX=.*VALIDATE_TIMEOUT_SYNTAX:-' "$VALIDATE_SH" \
    | grep -oE 'VALIDATE_TIMEOUT_SYNTAX:-[0-9]+' | grep -oE '[0-9]+')
assert_eq "test_default_timeout_syntax_is_60" "60" "$actual_default"
assert_pass_if_clean "test_default_timeout_syntax_is_60"

# ── test_check_bash_uses_threadpool ────────────────────────────────────
_snapshot_fail
threadpool_count=$(grep -c 'ThreadPoolExecutor' "$SYNTAX_PY" 2>/dev/null || echo "0")
assert_ne "test_check_bash_uses_threadpool" "0" "$threadpool_count"
assert_pass_if_clean "test_check_bash_uses_threadpool"

# ── test_check_bash_imports_concurrent ─────────────────────────────────
_snapshot_fail
import_count=$(grep -c 'from concurrent.futures import' "$SYNTAX_PY" 2>/dev/null || echo "0")
assert_eq "test_check_bash_imports_concurrent" "1" "$import_count"
assert_pass_if_clean "test_check_bash_imports_concurrent"

# ── test_syntax_check_runs_successfully ────────────────────────────────
_snapshot_fail
cd "$REPO_ROOT/app" && make syntax-check > /dev/null 2>&1
syntax_exit=$?
assert_eq "test_syntax_check_runs_successfully" "0" "$syntax_exit"
assert_pass_if_clean "test_syntax_check_runs_successfully"

print_summary
