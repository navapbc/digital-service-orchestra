#!/usr/bin/env bash
# tests/workflows/test-review-workflow-classifier-failure-guards.sh
# Structural tests for 6dbe-667d and 2762-e00e:
#   6dbe-667d: classifier command in REVIEW-WORKFLOW.md uses double-quoted path,
#              causing bash to treat "dso review-complexity-classifier.sh" as a single
#              command name (with embedded space) → exit 127 (command not found).
#   2762-e00e: overlay parsing lines in REVIEW-WORKFLOW.md Step 4b have no fallback
#              guards, causing JSONDecodeError when CLASSIFIER_OUTPUT is empty
#              (e.g., after classifier exit 127 or any other failure).
#
# Per behavioral testing standard Rule 5 (instruction files): test the structural
# boundary of the workflow file, not its content.
#
# Usage: bash tests/workflows/test-review-workflow-classifier-failure-guards.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
REVIEW_WORKFLOW="$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"

source "$REPO_ROOT/tests/lib/assert.sh"

# ── Prerequisite ─────────────────────────────────────────────────────────────
if [[ ! -f "$REVIEW_WORKFLOW" ]]; then
    echo "SKIP: REVIEW-WORKFLOW.md not found at $REVIEW_WORKFLOW"
    exit 0
fi

# ============================================================
# test_classifier_invocation_not_double_quoted (6dbe-667d)
#
# The classifier invocation must NOT wrap the command + arg in double quotes.
#
# BAD (causes exit 127 — bash treats the whole string as a single command name):
#   CLASSIFIER_OUTPUT=$(".claude/scripts/dso review-complexity-classifier.sh" < ...)
#
# GOOD (dso shim is the command; review-complexity-classifier.sh is its arg):
#   CLASSIFIER_OUTPUT=$(.claude/scripts/dso review-complexity-classifier.sh < ...)
# ============================================================
test_classifier_invocation_not_double_quoted() {
    # Detect the BAD pattern: script name embedded inside the double-quoted shim path.
    # BAD: CLASSIFIER_OUTPUT=$("...dso review-complexity-classifier.sh" ...) — the space
    #      inside the quotes makes bash treat the entire string as a single command name,
    #      causing exit 127.
    # GOOD: CLASSIFIER_OUTPUT=$("$REPO_ROOT/.../dso" review-complexity-classifier.sh ...)
    #       — the shim is quoted separately; the script name is a distinct arg.
    local found=0
    # shellcheck disable=SC2016
    # Intentional literal pattern — the test searches for the actual `\$("..."` shell-substitution
    # syntax in REVIEW-WORKFLOW.md prose, which would be lost if the single quotes were doubled.
    grep -q 'CLASSIFIER_OUTPUT=\$(".*dso review-complexity-classifier\.sh"' "$REVIEW_WORKFLOW" 2>/dev/null && found=1 || true
    assert_eq "classifier invocation: script not embedded in quoted shim (6dbe-667d)" "0" "$found"
}

# ============================================================
# test_capture_review_diff_not_double_quoted (6dbe-667d sweep)
#
# All capture-review-diff.sh invocations must not embed the script
# name in the same double-quoted string as the shim path. Same bug class
# as 6dbe-667d — exit 127 when LLM executes the instruction literally.
# ============================================================
test_capture_review_diff_not_double_quoted() {
    # BAD: ".claude/scripts/dso capture-review-diff.sh" (space inside quotes)
    local found=0
    grep -q '"[^"]*dso capture-review-diff\.sh"' "$REVIEW_WORKFLOW" 2>/dev/null && found=1 || true
    assert_eq "capture-review-diff.sh not double-quoted (6dbe-667d sweep)" "0" "$found"
}

# ============================================================
# test_overlay_flags_read_has_guard (2762-e00e, refactored to shared helper)
#
# Overlay-flag reading must have a fallback guard so that an empty or invalid
# CLASSIFIER_OUTPUT (classifier failed) does not propagate a JSONDecodeError
# that exits the workflow with code 1.
#
# Cycle-3 refactor: the three per-flag SECURITY_OVERLAY=... / PERFORMANCE_OVERLAY=...
# / TEST_QUALITY_OVERLAY=... python invocations were consolidated into a single
# call to read-overlay-flags.sh (single source-of-truth shared with record-review.sh).
# The fallback guard now lives on the helper invocation: `... || true` and the
# helper's own python try/except. Test asserts the helper invocation in
# REVIEW-WORKFLOW.md Step 4 retains a stderr-suppression + ||-fallback guard
# so a malformed classifier output cannot abort the orchestrator.
# ============================================================
test_overlay_flags_read_has_guard() {
    local line
    # Find the OVERLAY_DIMS=... line that calls read-overlay-flags.sh
    line=$(grep 'OVERLAY_DIMS=.*read-overlay-flags\.sh' "$REVIEW_WORKFLOW" 2>/dev/null | head -1 || true)
    local has_guard=0
    # Accept either pattern: `2>/dev/null || true` or `2>/dev/null || echo`
    if echo "$line" | grep -qE '2>/dev/null \|\| (true|echo)'; then
        has_guard=1
    fi
    assert_eq "OVERLAY_DIMS read via read-overlay-flags.sh has stderr-suppression + ||-fallback guard (2762-e00e cycle-3 refactor)" "1" "$has_guard"
}

# ============================================================
# test_overlay_helper_used_in_step_4 (cycle-3)
#
# The cycle-3 refactor introduces read-overlay-flags.sh as the single source-of-truth
# for overlay-flag schema. REVIEW-WORKFLOW.md Step 4 must call it (not duplicate
# the schema inline). This locks in that choice: a regression that re-introduces
# inline `'security_overlay'` / `'performance_overlay'` / `'test_quality_overlay'`
# python invocations in REVIEW-WORKFLOW.md (re-creating drift risk vs.
# record-review.sh) is caught here.
# ============================================================
test_overlay_helper_used_in_step_4() {
    local found=0
    if grep -q 'read-overlay-flags\.sh.*--mode classifier' "$REVIEW_WORKFLOW" 2>/dev/null; then
        found=1
    fi
    assert_eq "REVIEW-WORKFLOW.md Step 4 uses read-overlay-flags.sh in classifier mode" "1" "$found"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_classifier_invocation_not_double_quoted
test_capture_review_diff_not_double_quoted
test_overlay_flags_read_has_guard
test_overlay_helper_used_in_step_4

print_summary
