#!/usr/bin/env bash
# tests/scripts/test-read-overlay-flags.sh
#
# Direct unit tests for plugins/dso/scripts/read-overlay-flags.sh — the single
# source-of-truth for classifier overlay-flag extraction. Both REVIEW-WORKFLOW.md
# Step 4 (orchestrator dispatch decision) and hooks/record-review.sh (post-commit
# enforcement gate) call this script; behavioral regressions silently affect
# both the dispatch and the gate.
#
# Tests cover:
#   1. classifier mode — single JSON object with all flags false → empty output
#   2. classifier mode — flags true emit correct dim names
#   3. classifier mode — malformed JSON fails closed (empty output, exit 0)
#   4. telemetry mode — filters by --diff-hash, ignores non-matching records
#   5. telemetry mode — multi-flag scenarios
#   6. telemetry mode — missing --diff-hash flag is a usage error (exit 1)
#   7. argument validation — unknown --mode value rejected
#   8. argument validation — missing --mode rejected

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HELPER="$REPO_ROOT/plugins/dso/scripts/read-overlay-flags.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-read-overlay-flags.sh ==="

# ── Test 1: classifier mode, all flags false ──────────────────────────────────
echo "--- test_classifier_mode_all_false ---"
_OUT=$(echo '{"test_quality_overlay":false,"security_overlay":false,"performance_overlay":false}' | bash "$HELPER" --mode classifier)
assert_eq "classifier mode: all flags false → empty output" "" "$_OUT"

# ── Test 2: classifier mode, flags true emit dim names ────────────────────────
echo "--- test_classifier_mode_flags_true ---"
_OUT=$(echo '{"test_quality_overlay":true,"security_overlay":false,"performance_overlay":true}' | bash "$HELPER" --mode classifier | sort | tr '\n' ',' | sed 's/,$//')
assert_eq "classifier mode: 2 flags true → 2 dim names emitted" "performance,test-quality" "$_OUT"

# ── Test 3: classifier mode, malformed JSON ───────────────────────────────────
echo "--- test_classifier_mode_malformed_fails_closed ---"
_OUT=$(echo 'not valid json' | bash "$HELPER" --mode classifier)
_EXIT=0
echo 'not valid json' | bash "$HELPER" --mode classifier >/dev/null 2>&1 || _EXIT=$?
assert_eq "classifier mode: malformed input → empty output (fail-closed for caller)" "" "$_OUT"
assert_eq "classifier mode: malformed input → exit 0 (caller handles empty list)" "0" "$_EXIT"

# ── Test 4: telemetry mode filters by diff_hash ───────────────────────────────
echo "--- test_telemetry_mode_filters_by_diff_hash ---"
_TELEMETRY=$(printf '%s\n' \
    '{"diff_hash":"AAA","test_quality_overlay":true,"security_overlay":false,"performance_overlay":false}' \
    '{"diff_hash":"BBB","test_quality_overlay":false,"security_overlay":true,"performance_overlay":false}')
_OUT=$(echo "$_TELEMETRY" | bash "$HELPER" --mode telemetry --diff-hash BBB | sort | tr '\n' ',' | sed 's/,$//')
assert_eq "telemetry mode: filters BBB record → returns security only" "security" "$_OUT"
_OUT=$(echo "$_TELEMETRY" | bash "$HELPER" --mode telemetry --diff-hash AAA | sort | tr '\n' ',' | sed 's/,$//')
assert_eq "telemetry mode: filters AAA record → returns test-quality only" "test-quality" "$_OUT"

# ── Test 5: telemetry mode, multi-flag scenarios ──────────────────────────────
echo "--- test_telemetry_mode_multi_flag ---"
_TELEMETRY='{"diff_hash":"X","test_quality_overlay":true,"security_overlay":true,"performance_overlay":true}'
_OUT=$(echo "$_TELEMETRY" | bash "$HELPER" --mode telemetry --diff-hash X | sort | tr '\n' ',' | sed 's/,$//')
assert_eq "telemetry mode: all 3 flags true → all 3 dim names emitted" "performance,security,test-quality" "$_OUT"

# ── Test 6: telemetry mode requires --diff-hash ───────────────────────────────
echo "--- test_telemetry_mode_requires_diff_hash ---"
_EXIT=0
echo '{"diff_hash":"X","test_quality_overlay":true}' | bash "$HELPER" --mode telemetry >/dev/null 2>&1 || _EXIT=$?
assert_ne "telemetry mode without --diff-hash → exit non-zero (usage error)" "0" "$_EXIT"

# ── Test 7: unknown mode rejected ─────────────────────────────────────────────
echo "--- test_unknown_mode_rejected ---"
_EXIT=0
echo '{}' | bash "$HELPER" --mode invalid >/dev/null 2>&1 || _EXIT=$?
assert_ne "unknown --mode value → exit non-zero" "0" "$_EXIT"

# ── Test 8: missing --mode rejected ───────────────────────────────────────────
echo "--- test_missing_mode_rejected ---"
_EXIT=0
echo '{}' | bash "$HELPER" >/dev/null 2>&1 || _EXIT=$?
assert_ne "missing --mode → exit non-zero" "0" "$_EXIT"

# ── Test 9: telemetry mode with no matching records returns empty ─────────────
echo "--- test_telemetry_mode_no_match ---"
_TELEMETRY='{"diff_hash":"AAA","test_quality_overlay":true}'
_OUT=$(echo "$_TELEMETRY" | bash "$HELPER" --mode telemetry --diff-hash NONEXISTENT)
assert_eq "telemetry mode: no matching diff_hash → empty output" "" "$_OUT"

# ── Test 10: telemetry mode with last-matching-record semantics ───────────────
# When multiple records match the same diff_hash (re-classification), use the LAST.
echo "--- test_telemetry_mode_last_match_wins ---"
_TELEMETRY=$(printf '%s\n' \
    '{"diff_hash":"X","test_quality_overlay":false,"security_overlay":false,"performance_overlay":false}' \
    '{"diff_hash":"X","test_quality_overlay":true,"security_overlay":false,"performance_overlay":false}')
_OUT=$(echo "$_TELEMETRY" | bash "$HELPER" --mode telemetry --diff-hash X)
assert_eq "telemetry mode: multiple matches → last record wins (re-classification semantics)" "test-quality" "$_OUT"

print_summary
