#!/usr/bin/env bash
# tests/agents/test-reviewer-deep-verification-checklist.sh
# Verifies the Deep Sonnet B (Verification) reviewer contains project-aware
# sub-criteria: bash test helpers, pytest patterns, .test-index associations,
# mock correctness (over-mocking, under-mocking), and test quality patterns.
#
# Usage: bash tests/agents/test-reviewer-deep-verification-checklist.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_FILE="$REPO_ROOT/plugins/dso/agents/code-reviewer-deep-verification.md"
DELTA_FILE="$REPO_ROOT/plugins/dso/docs/workflows/prompts/reviewer-delta-deep-verification.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-reviewer-deep-verification-checklist.sh ==="
echo ""

# ── Prerequisite: files exist ─────────────────────────────────────────────────
echo "--- prerequisite: agent and delta files exist ---"
_snapshot_fail
[[ -f "$AGENT_FILE" ]]
assert_eq "agent file exists" "0" "$?"
[[ -f "$DELTA_FILE" ]]
assert_eq "delta file exists" "0" "$?"
assert_pass_if_clean "file_existence"
echo ""

# ── T1: Verification Checklist section present ───────────────────────────────
echo "--- T1: Verification Checklist section present in delta ---"
_snapshot_fail
assert_eq "delta has Verification Checklist section" \
    "0" "$(grep -q 'Verification Checklist' "$DELTA_FILE"; echo $?)"
assert_pass_if_clean "T1_verification_checklist_section"
echo ""

# ── T2: Tier identity section (Deep Sonnet B) ────────────────────────────────
echo "--- T2: Tier Identity section identifies Deep Sonnet B ---"
_snapshot_fail
_found_tier_identity=0
if grep -q 'Deep Sonnet B' "$DELTA_FILE" 2>/dev/null; then
    _found_tier_identity=1
fi
assert_eq "delta identifies Deep Sonnet B tier" "1" "$_found_tier_identity"
assert_pass_if_clean "T2_tier_identity"
echo ""

# ── T3: Verification-only N/A constraint present ─────────────────────────────
echo "--- T3: N/A constraint for non-verification dimensions present ---"
_snapshot_fail
_found_na_constraint=0
if grep -q '"N/A"' "$DELTA_FILE" 2>/dev/null; then
    _found_na_constraint=1
fi
assert_eq "delta instructs N/A for non-verification dimensions" "1" "$_found_na_constraint"
assert_pass_if_clean "T3_na_constraint"
echo ""

# ── T4: Project test pattern — bash assert.sh helpers ────────────────────────
echo "--- T4: bash assert.sh helper pattern recognition present ---"
_snapshot_fail
_found_assert_helpers=0
if grep -qiE "assert\.sh|assert_eq|assert_contains|assert_ne" "$DELTA_FILE" 2>/dev/null; then
    _found_assert_helpers=1
fi
assert_eq "delta recognizes project bash assert.sh helpers" "1" "$_found_assert_helpers"
assert_pass_if_clean "T4_bash_assert_helpers"
echo ""

# ── T5: Project test pattern — pytest parametrize ────────────────────────────
echo "--- T5: pytest parametrize pattern recognition present ---"
_snapshot_fail
_found_parametrize=0
if grep -qiE "parametrize|pytest\.mark" "$DELTA_FILE" 2>/dev/null; then
    _found_parametrize=1
fi
assert_eq "delta recognizes pytest parametrize patterns" "1" "$_found_parametrize"
assert_pass_if_clean "T5_pytest_parametrize"
echo ""

# ── T6: Project test pattern — .test-index associations ──────────────────────
echo "--- T6: .test-index association awareness present ---"
_snapshot_fail
_found_test_index=0
if grep -qiE "\.test-index|test-index|test_index" "$DELTA_FILE" 2>/dev/null; then
    _found_test_index=1
fi
assert_eq "delta recognizes .test-index associations" "1" "$_found_test_index"
assert_pass_if_clean "T6_test_index_awareness"
echo ""

# ── T7: Mock correctness — over-mocking detection ────────────────────────────
echo "--- T7: over-mocking detection sub-criteria present ---"
_snapshot_fail
_found_over_mocking=0
if grep -qiE "over.mock|mocking the unit under test|mock.*internal|internal.*mock" "$DELTA_FILE" 2>/dev/null; then
    _found_over_mocking=1
fi
assert_eq "delta includes over-mocking detection" "1" "$_found_over_mocking"
assert_pass_if_clean "T7_over_mocking_detection"
echo ""

# ── T8: Mock correctness — under-mocking detection ───────────────────────────
echo "--- T8: under-mocking detection sub-criteria present ---"
_snapshot_fail
_found_under_mocking=0
if grep -qiE "under.mock|real external|external.*resource|calling real" "$DELTA_FILE" 2>/dev/null; then
    _found_under_mocking=1
fi
assert_eq "delta includes under-mocking detection" "1" "$_found_under_mocking"
assert_pass_if_clean "T8_under_mocking_detection"
echo ""

# ── T9: Test quality — cleanup traps in bash tests ───────────────────────────
echo "--- T9: bash test cleanup trap patterns present ---"
_snapshot_fail
_found_cleanup_trap=0
if grep -qiE "cleanup trap|trap.*EXIT|EXIT trap|bash.*cleanup" "$DELTA_FILE" 2>/dev/null; then
    _found_cleanup_trap=1
fi
assert_eq "delta includes bash test cleanup trap patterns" "1" "$_found_cleanup_trap"
assert_pass_if_clean "T9_bash_cleanup_traps"
echo ""

# ── T10: Test quality — fixture isolation in Python tests ────────────────────
echo "--- T10: Python fixture isolation patterns present ---"
_snapshot_fail
_found_fixture_isolation=0
if grep -qiE "fixture.*isolat|isolat.*fixture|tmp_path|tmp_dir|monkeypatch" "$DELTA_FILE" 2>/dev/null; then
    _found_fixture_isolation=1
fi
assert_eq "delta includes Python fixture isolation patterns" "1" "$_found_fixture_isolation"
assert_pass_if_clean "T10_fixture_isolation"
echo ""

# ── T11: RED marker awareness ─────────────────────────────────────────────────
echo "--- T11: RED marker / TDD workflow awareness present ---"
_snapshot_fail
_found_red_marker=0
if grep -qiE "RED marker|red.marker|\[marker\]|tdd" "$DELTA_FILE" 2>/dev/null; then
    _found_red_marker=1
fi
assert_eq "delta recognizes RED marker TDD workflow" "1" "$_found_red_marker"
assert_pass_if_clean "T11_red_marker_awareness"
echo ""

# ── T12: Generated agent file contains project-aware patterns ─────────────────
echo "--- T12: generated agent file contains project-aware test patterns ---"
_snapshot_fail
_found_agent_test_index=0
if grep -qiE "\.test-index|test-index" "$AGENT_FILE" 2>/dev/null; then
    _found_agent_test_index=1
fi
assert_eq "generated agent file references .test-index" "1" "$_found_agent_test_index"
assert_pass_if_clean "T12_generated_agent_test_index"
echo ""

# ── T13: Generated agent has correct dimension N/A output constraint ──────────
echo "--- T13: generated agent file enforces N/A for non-verification dimensions ---"
_snapshot_fail
_found_agent_na=0
if grep -q '"N/A"' "$AGENT_FILE" 2>/dev/null; then
    _found_agent_na=1
fi
assert_eq "generated agent file references N/A for non-verification dims" "1" "$_found_agent_na"
assert_pass_if_clean "T13_generated_agent_na_constraint"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
