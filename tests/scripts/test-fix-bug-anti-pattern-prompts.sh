#!/usr/bin/env bash
# tests/scripts/test-fix-bug-anti-pattern-prompts.sh
# TDD tests for fix-bug anti-pattern prompt templates:
#   anti-pattern-scan.md, anti-pattern-fix-batch.md
#
# Usage: bash tests/scripts/test-fix-bug-anti-pattern-prompts.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: These tests are expected to FAIL until prompt files are created.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROMPTS_DIR="$PLUGIN_ROOT/plugins/dso/skills/fix-bug/prompts"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-fix-bug-anti-pattern-prompts.sh ==="

# ── test_scan_prompt_exists ───────────────────────────────────────────────────
_snapshot_fail
if test -f "$PROMPTS_DIR/anti-pattern-scan.md"; then
    actual_scan_exists="exists"
else
    actual_scan_exists="missing"
fi
assert_eq "test_scan_prompt_exists: anti-pattern-scan.md" "exists" "$actual_scan_exists"
assert_pass_if_clean "test_scan_prompt_exists: anti-pattern-scan.md"

# ── test_scan_prompt_has_output_format ────────────────────────────────────────
_snapshot_fail
if test -f "$PROMPTS_DIR/anti-pattern-scan.md" \
    && grep -qiE "Output Format|Candidate" "$PROMPTS_DIR/anti-pattern-scan.md"; then
    actual_scan_output="present"
else
    actual_scan_output="missing"
fi
assert_eq "test_scan_prompt_has_output_format: contains 'Output Format' or 'Candidate'" "present" "$actual_scan_output"
assert_pass_if_clean "test_scan_prompt_has_output_format: contains 'Output Format' or 'Candidate'"

# ── test_scan_prompt_has_scope_exclusions ─────────────────────────────────────
_snapshot_fail
if test -f "$PROMPTS_DIR/anti-pattern-scan.md" \
    && grep -qiE "exclude|scope" "$PROMPTS_DIR/anti-pattern-scan.md"; then
    actual_scan_scope="present"
else
    actual_scan_scope="missing"
fi
assert_eq "test_scan_prompt_has_scope_exclusions: contains 'exclude' or 'scope'" "present" "$actual_scan_scope"
assert_pass_if_clean "test_scan_prompt_has_scope_exclusions: contains 'exclude' or 'scope'"

# ── test_fix_batch_prompt_exists ──────────────────────────────────────────────
_snapshot_fail
if test -f "$PROMPTS_DIR/anti-pattern-fix-batch.md"; then
    actual_batch_exists="exists"
else
    actual_batch_exists="missing"
fi
assert_eq "test_fix_batch_prompt_exists: anti-pattern-fix-batch.md" "exists" "$actual_batch_exists"
assert_pass_if_clean "test_fix_batch_prompt_exists: anti-pattern-fix-batch.md"

# ── test_fix_batch_prompt_has_red_test ────────────────────────────────────────
_snapshot_fail
if test -f "$PROMPTS_DIR/anti-pattern-fix-batch.md" \
    && grep -qiE "RED test|failing test" "$PROMPTS_DIR/anti-pattern-fix-batch.md"; then
    actual_batch_red="present"
else
    actual_batch_red="missing"
fi
assert_eq "test_fix_batch_prompt_has_red_test: contains 'RED test' or 'failing test'" "present" "$actual_batch_red"
assert_pass_if_clean "test_fix_batch_prompt_has_red_test: contains 'RED test' or 'failing test'"

# ── test_fix_batch_prompt_has_completion_record ───────────────────────────────
_snapshot_fail
if test -f "$PROMPTS_DIR/anti-pattern-fix-batch.md" \
    && grep -qiE "completion record|batch.*status" "$PROMPTS_DIR/anti-pattern-fix-batch.md"; then
    actual_batch_complete="present"
else
    actual_batch_complete="missing"
fi
assert_eq "test_fix_batch_prompt_has_completion_record: contains 'completion record' or 'batch.*status'" "present" "$actual_batch_complete"
assert_pass_if_clean "test_fix_batch_prompt_has_completion_record: contains 'completion record' or 'batch.*status'"

print_summary
