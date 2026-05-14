#!/usr/bin/env bash
# tests/scripts/test-debug-everything-leak-detection.sh
# Structural metadata validation of debug-everything SKILL.md leak-detection invocation contract.
#
# Verifies that the debug-everything skill references detect-session-leakage.sh at:
#   1. After each fix-bug invocation (Bug-Fix Mode section context)
#   2. After each batch completion (Phase F or Phase G context)
#   3. At Phase K (final sweep)
#   4. Using STORY_BRANCH_PREFIX=bug-batch env var override
#   5. Protection against closed-bug trailer race condition
#
# Test status: All 5 tests are RED — SKILL.md does not yet reference detect-session-leakage.sh
# in these contexts.
#
# Exemption: structural metadata validation of prompt file — not executable code.
#
# Usage: bash tests/scripts/test-debug-everything-leak-detection.sh

# pipefail intentionally omitted: grep-q pipelines below trigger SIGPIPE on Linux under pipefail (bug 8142-c280)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_FILE="$DSO_PLUGIN_DIR/skills/debug-everything/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-debug-everything-leak-detection.sh ==="

test_leak_detection_after_fix_bug() {
    local result="missing"
    if grep -qE 'detect-session-leakage\.sh' "$SKILL_FILE" 2>/dev/null && \
       grep -qE '(Bug-Fix Mode|fix.bug invocation|after.*fix.bug|fix.bug.*after)' "$SKILL_FILE" 2>/dev/null && \
       awk '/Bug-Fix Mode/{found=1} found && /detect-session-leakage\.sh/{print; exit}' "$SKILL_FILE" 2>/dev/null | grep -q 'detect-session-leakage'; then
        result="found"
    fi
    assert_eq "test_leak_detection_after_fix_bug: SKILL.md Bug-Fix Mode section references detect-session-leakage.sh after each fix-bug invocation" "found" "$result"
}

test_leak_detection_after_batch() {
    local result="missing"
    if grep -qE 'detect-session-leakage\.sh' "$SKILL_FILE" 2>/dev/null && \
       awk '/## Phase [FG]/{found=1} found && /detect-session-leakage\.sh/{print; exit}' "$SKILL_FILE" 2>/dev/null | grep -q 'detect-session-leakage'; then
        result="found"
    fi
    assert_eq "test_leak_detection_after_batch: SKILL.md Phase F or Phase G section references detect-session-leakage.sh after each batch completion" "found" "$result"
}

test_leak_detection_at_phase_k() {
    local result="missing"
    if grep -qE 'detect-session-leakage\.sh' "$SKILL_FILE" 2>/dev/null && \
       awk '/## Phase K/{found=1} found && /detect-session-leakage\.sh/{print; exit}' "$SKILL_FILE" 2>/dev/null | grep -q 'detect-session-leakage'; then
        result="found"
    fi
    assert_eq "test_leak_detection_at_phase_k: SKILL.md Phase K section references detect-session-leakage.sh for final sweep" "found" "$result"
}

test_leak_detection_uses_story_branch_prefix() {
    local result="missing"
    if grep -qE 'STORY_BRANCH_PREFIX=bug-batch' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_leak_detection_uses_story_branch_prefix: SKILL.md contains STORY_BRANCH_PREFIX=bug-batch env var override for detect-session-leakage.sh calls" "found" "$result"
}

test_closed_bug_trailer_race_protection() {
    local result="missing"
    if grep -qE '(force-route-to-pending|closed-bug-trailer)' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_closed_bug_trailer_race_protection: SKILL.md references force-route-to-pending or closed-bug-trailer protection against closed-bug trailer race condition" "found" "$result"
}

echo ""
echo "--- test_leak_detection_after_fix_bug ---"
test_leak_detection_after_fix_bug
echo ""
echo "--- test_leak_detection_after_batch ---"
test_leak_detection_after_batch
echo ""
echo "--- test_leak_detection_at_phase_k ---"
test_leak_detection_at_phase_k
echo ""
echo "--- test_leak_detection_uses_story_branch_prefix ---"
test_leak_detection_uses_story_branch_prefix
echo ""
echo "--- test_closed_bug_trailer_race_protection ---"
test_closed_bug_trailer_race_protection
echo ""
print_summary
