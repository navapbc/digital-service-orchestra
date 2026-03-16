#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-api-key-hook-removed.sh
# Regression tests for the removal of check-api-key-env.sh and api-key-check pre-commit hook.
# These tests verify the post-deletion invariants remain true:
#   1. scripts/check-api-key-env.sh must NOT exist
#   2. .pre-commit-config.yaml must contain no 'api-key-check' entry
#
# This file intentionally references 'check-api-key-env' as a regression guard —
# having the string here is correct: this test exists to verify the hook is gone.
#
# Usage: bash lockpick-workflow/tests/scripts/test-api-key-hook-removed.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-api-key-hook-removed.sh ==="

# ── test_check_api_key_script_deleted ────────────────────────────────────────
# scripts/check-api-key-env.sh must NOT exist after deletion
_snapshot_fail
script_exists=0
test -f "$REPO_ROOT/scripts/check-api-key-env.sh" && script_exists=1
assert_eq "test_check_api_key_script_deleted: file must not exist" "0" "$script_exists"
assert_pass_if_clean "test_check_api_key_script_deleted"

# ── test_api_key_check_hook_removed ──────────────────────────────────────────
# .pre-commit-config.yaml must contain no 'api-key-check' entry
_snapshot_fail
hook_count=0
hook_count=$(grep -c 'api-key-check' "$REPO_ROOT/.pre-commit-config.yaml" 2>/dev/null || true)
assert_eq "test_api_key_check_hook_removed: no api-key-check entries" "0" "$hook_count"
assert_pass_if_clean "test_api_key_check_hook_removed"

print_summary
