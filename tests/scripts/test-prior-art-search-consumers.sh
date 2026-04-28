#!/usr/bin/env bash
# tests/scripts/test-prior-art-search-consumers.sh
# TDD RED phase: integration verification that consuming skills reference
# prior-art-search.md at the correct decision points.
#
# All tests are expected to FAIL until the consuming skills are updated.
#
# Section extraction helper:
#   extract_section file header — prints lines within the named section
#   until the next ## header.
#
# Usage: bash tests/scripts/test-prior-art-search-consumers.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-prior-art-search-consumers.sh ==="

FIX_BUG_SKILL="$PLUGIN_ROOT/plugins/dso/skills/fix-bug/SKILL.md"
REVIEW_FIX_DISPATCH="$PLUGIN_ROOT/plugins/dso/docs/workflows/prompts/review-fix-dispatch.md"
TASK_EXECUTION="$PLUGIN_ROOT/plugins/dso/skills/sprint/prompts/task-execution.md"

# Section extraction helper: prints lines in $file belonging to section $header
# (from the line after the header until the next ## header).
extract_section() {
    local file=$1 header=$2
    awk -v h="$header" '$0 ~ h {found=1; next} found && /^##/{exit} found{print}' "$file"
}

# ── test_fix_bug_references_prior_art ─────────────────────────────────────────
# MUST be the first test function — RED marker anchors here.
# Extract the Fix Implementation section from fix-bug/SKILL.md and verify
# 'prior-art-search' appears within it. Proximity check — not whole file.
# (Old SKILL.md called this "Step 6"; refactored to "Phase E Step 3: Fix Implementation".)
test_fix_bug_references_prior_art() {
    _snapshot_fail
    local section actual
    section=""
    if [ -f "$FIX_BUG_SKILL" ]; then
        section=$(extract_section "$FIX_BUG_SKILL" "Step 3: Fix Implementation")
    fi
    if [[ "$section" == *prior-art-search* ]]; then
        actual="found"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_references_prior_art: 'prior-art-search' in Step 3: Fix Implementation section of fix-bug/SKILL.md" "found" "$actual"
    assert_pass_if_clean "test_fix_bug_references_prior_art"
}

# ── test_review_fix_dispatch_references_prior_art ─────────────────────────────
# review-fix-dispatch.md must contain 'prior-art-search'.
test_review_fix_dispatch_references_prior_art() {
    _snapshot_fail
    local actual
    if [ -f "$REVIEW_FIX_DISPATCH" ] && grep -q "prior-art-search" "$REVIEW_FIX_DISPATCH"; then
        actual="found"
    else
        actual="missing"
    fi
    assert_eq "test_review_fix_dispatch_references_prior_art: 'prior-art-search' in review-fix-dispatch.md" "found" "$actual"
    assert_pass_if_clean "test_review_fix_dispatch_references_prior_art"
}

# ── test_task_execution_references_prior_art ─────────────────────────────────
# sprint/prompts/task-execution.md must contain 'prior-art-search'.
test_task_execution_references_prior_art() {
    _snapshot_fail
    local actual
    if [ -f "$TASK_EXECUTION" ] && grep -q "prior-art-search" "$TASK_EXECUTION"; then
        actual="found"
    else
        actual="missing"
    fi
    assert_eq "test_task_execution_references_prior_art: 'prior-art-search' in task-execution.md" "found" "$actual"
    assert_pass_if_clean "test_task_execution_references_prior_art"
}

# ── test_is_executable ────────────────────────────────────────────────────────
# This test file itself must be executable.
test_is_executable() {
    _snapshot_fail
    local self actual
    self="${BASH_SOURCE[0]}"
    if [ -x "$self" ]; then
        actual="executable"
    else
        actual="not_executable"
    fi
    assert_eq "test_is_executable: test file is executable" "executable" "$actual"
    assert_pass_if_clean "test_is_executable"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_fix_bug_references_prior_art
test_review_fix_dispatch_references_prior_art
test_task_execution_references_prior_art
test_is_executable

print_summary
