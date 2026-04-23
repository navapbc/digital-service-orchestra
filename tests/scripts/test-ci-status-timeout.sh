#!/usr/bin/env bash
# tests/scripts/test-ci-status-timeout.sh
# Tests verifying that VALIDATE_TIMEOUT_CI default in validate.sh is 60s
# (not 30s), preventing spurious timeout errors on slow GitHub API calls.
#
# Root cause (ticket lockpick-doc-to-logic-p8ws):
#   gh run list --workflow=CI makes a GitHub API call that can take >30s
#   under rate limiting or slow network. Previous default of 30s was too
#   tight; 60s provides sufficient headroom.
#
# Usage: bash tests/scripts/test-ci-status-timeout.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
VALIDATE_SH="$DSO_PLUGIN_DIR/scripts/validate.sh"
VALIDATE_CHECK_RUNNERS_SH="$DSO_PLUGIN_DIR/hooks/lib/validate-check-runners.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-ci-status-timeout.sh ==="

# ── test_default_timeout_ci_is_60 ──────────────────────────────────────
_snapshot_fail
actual_default=$(grep 'TIMEOUT_CI=.*VALIDATE_TIMEOUT_CI:-' "$VALIDATE_SH" \
    | grep -oE '[0-9]+' | tail -1)
assert_eq "test_default_timeout_ci_is_60" "60" "$actual_default"
assert_pass_if_clean "test_default_timeout_ci_is_60"

# ── test_doc_comment_says_60 ───────────────────────────────────────────
_snapshot_fail
comment_match=$(grep -c 'VALIDATE_TIMEOUT_CI.*default: 60' "$VALIDATE_SH" || echo "0")
assert_eq "test_doc_comment_says_60" "1" "$comment_match"
assert_pass_if_clean "test_doc_comment_says_60"

# ── test_call_site_uses_timeout_ci_var ─────────────────────────────────
# check_ci() in validate-check-runners.sh is the actual call site; validate.sh
# defines TIMEOUT_CI and delegates to check_ci via sourcing the runners file.
_snapshot_fail
# shellcheck disable=SC2016  # single quotes intentional: grep for literal $TIMEOUT_CI in source file
call_site_count=$(grep -c 'run_with_timeout.*\$TIMEOUT_CI.*ci-status' "$VALIDATE_CHECK_RUNNERS_SH" 2>/dev/null || echo "0")
assert_eq "test_call_site_uses_timeout_ci_var" "1" "$call_site_count"
assert_pass_if_clean "test_call_site_uses_timeout_ci_var"

print_summary
