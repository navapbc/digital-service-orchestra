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
# test_overlay_security_has_guard (2762-e00e)
#
# SECURITY_OVERLAY parsing must have a fallback guard so that an empty or
# invalid CLASSIFIER_OUTPUT (classifier failed) does not propagate a
# JSONDecodeError that exits the workflow with code 1.
#
# GOOD pattern: ... 2>/dev/null || echo "false"
# ============================================================
test_overlay_security_has_guard() {
    local line
    line=$(grep 'SECURITY_OVERLAY=.*security_overlay' "$REVIEW_WORKFLOW" 2>/dev/null || true)
    local has_guard=0
    if echo "$line" | grep -q '|| echo'; then
        has_guard=1
    fi
    assert_eq "SECURITY_OVERLAY parsing has || fallback guard (2762-e00e)" "1" "$has_guard"
}

# ============================================================
# test_overlay_performance_has_guard (2762-e00e)
# ============================================================
test_overlay_performance_has_guard() {
    local line
    line=$(grep 'PERFORMANCE_OVERLAY=.*performance_overlay' "$REVIEW_WORKFLOW" 2>/dev/null || true)
    local has_guard=0
    if echo "$line" | grep -q '|| echo'; then
        has_guard=1
    fi
    assert_eq "PERFORMANCE_OVERLAY parsing has || fallback guard (2762-e00e)" "1" "$has_guard"
}

# ============================================================
# test_overlay_test_quality_has_guard (2762-e00e)
# ============================================================
test_overlay_test_quality_has_guard() {
    local line
    line=$(grep 'TEST_QUALITY_OVERLAY=.*test_quality_overlay' "$REVIEW_WORKFLOW" 2>/dev/null || true)
    local has_guard=0
    if echo "$line" | grep -q '|| echo'; then
        has_guard=1
    fi
    assert_eq "TEST_QUALITY_OVERLAY parsing has || fallback guard (2762-e00e)" "1" "$has_guard"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_classifier_invocation_not_double_quoted
test_capture_review_diff_not_double_quoted
test_overlay_security_has_guard
test_overlay_performance_has_guard
test_overlay_test_quality_has_guard

print_summary
