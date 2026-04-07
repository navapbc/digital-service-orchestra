#!/usr/bin/env bash
# tests/hooks/test-test-quality-overlay.sh
# RED tests for test quality review overlay (story 9ebb-43ea, task 389d-505d)
#
# Tests the expected classifier and overlay agent interface for the test quality
# overlay. All tests FAIL in RED phase because:
#   (1) plugins/dso/scripts/review-complexity-classifier.sh does not yet emit
#       test_quality_overlay=true for test-file diffs
#   (2) plugins/dso/agents/code-reviewer-test-quality.md does not exist yet
#
# Expected behavior (to be satisfied by implementation):
#   - Classifier emits test_quality_overlay=true when diff touches test files
#   - Classifier emits test_quality_overlay=false when diff has no test files
#   - plugins/dso/agents/code-reviewer-test-quality.md exists as the overlay agent

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
source "$REPO_ROOT/tests/lib/assert.sh"

CLASSIFIER_SCRIPT="$REPO_ROOT/plugins/dso/scripts/review-complexity-classifier.sh"
OVERLAY_AGENT_FILE="$REPO_ROOT/plugins/dso/agents/code-reviewer-test-quality.md"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_tmpdirs EXIT

make_tmpdir() {
    local d
    d="$(mktemp -d)"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ---------------------------------------------------------------------------
# Helper: build a minimal unified diff touching only test files
# ---------------------------------------------------------------------------
make_test_file_diff() {
    cat <<'DIFF'
diff --git a/tests/unit/test_example.py b/tests/unit/test_example.py
index 0000000..1111111 100644
--- a/tests/unit/test_example.py
+++ b/tests/unit/test_example.py
@@ -1,3 +1,6 @@
+def test_new_behavior():
+    # Added test for new behavior
+    assert 1 + 1 == 2
DIFF
}

# ---------------------------------------------------------------------------
# Helper: build a minimal unified diff touching only non-test source files
# ---------------------------------------------------------------------------
make_source_only_diff() {
    cat <<'DIFF'
diff --git a/app/services/calculator.py b/app/services/calculator.py
index 0000000..2222222 100644
--- a/app/services/calculator.py
+++ b/app/services/calculator.py
@@ -1,3 +1,6 @@
+def add(a, b):
+    return a + b
DIFF
}

# ---------------------------------------------------------------------------
# Helper: extract a field from classifier JSON output
# ---------------------------------------------------------------------------
extract_classifier_field() {
    local json="$1"
    local field="$2"
    python3 -c "
import json, sys
data = json.loads(sys.argv[1])
val = data.get(sys.argv[2], 'FIELD_MISSING')
print(str(val).lower())
" "$json" "$field"
}

echo "=== test-test-quality-overlay.sh ==="
echo ""
# REVIEW-DEFENSE: FAIL counter initialization before _snapshot_fail calls.
# assert.sh (sourced above) initializes FAIL=0 at source time via `: "${FAIL:=0}"` (line 22).
# All _snapshot_fail calls below operate on an already-initialized FAIL counter.
# assert_pass_if_clean checks `[[ -z "${_fail_snapshot+x}" ]]` to guard against
# _snapshot_fail never being called — not against FAIL being uninitialized.
# No explicit `FAIL=0` is needed here; sourcing assert.sh guarantees it.

# ===========================================================================
# Test 1: classifier sets test_quality_overlay=true when diff touches test files
# EXPECTED TO FAIL IN RED PHASE: review-complexity-classifier.sh does not yet
# emit the test_quality_overlay field. This test will produce actual_flag=
# 'CLASSIFIER_NOT_RUN' (classifier exists but field is absent) until the
# classifier is modified to emit test_quality_overlay. The .test-index marker
# [test_classifier_sets_test_quality_overlay_for_test_file_diffs] tolerates
# this failure during the RED phase.
# ===========================================================================
echo "--- classifier sets test_quality_overlay=true for test file diffs ---"
_snapshot_fail

classifier_output=""
if [[ -f "$CLASSIFIER_SCRIPT" ]]; then
    classifier_output="$(make_test_file_diff | bash "$CLASSIFIER_SCRIPT" 2>/dev/null)" || true
fi

actual_flag="CLASSIFIER_NOT_RUN"
if [[ -n "$classifier_output" ]]; then
    actual_flag="$(extract_classifier_field "$classifier_output" "test_quality_overlay" 2>/dev/null)" || actual_flag="FIELD_MISSING"
fi

# RED: assert will fail until classifier emits test_quality_overlay=true
assert_eq \
    "test_quality_overlay: classifier emits true when diff touches test files" \
    "true" \
    "$actual_flag"

assert_pass_if_clean "test_classifier_sets_test_quality_overlay_for_test_file_diffs"

# ===========================================================================
# Test 2: overlay NOT triggered for non-test diffs
# EXPECTED TO FAIL IN RED PHASE: classifier does not yet emit
# test_quality_overlay, so actual_flag='CLASSIFIER_NOT_RUN' rather than
# 'false'. This test will pass once the classifier emits
# test_quality_overlay=false for non-test diffs.
# ===========================================================================
echo "--- classifier sets test_quality_overlay=false for non-test diffs ---"
_snapshot_fail

classifier_output=""
if [[ -f "$CLASSIFIER_SCRIPT" ]]; then
    classifier_output="$(make_source_only_diff | bash "$CLASSIFIER_SCRIPT" 2>/dev/null)" || true
fi

actual_flag="CLASSIFIER_NOT_RUN"
if [[ -n "$classifier_output" ]]; then
    actual_flag="$(extract_classifier_field "$classifier_output" "test_quality_overlay" 2>/dev/null)" || actual_flag="FIELD_MISSING"
fi

# RED: assert will fail until classifier emits test_quality_overlay=false
assert_eq \
    "test_quality_overlay: classifier emits false when diff has no test files" \
    "false" \
    "$actual_flag"

assert_pass_if_clean "test_overlay_not_triggered_for_non_test_diffs"

# ===========================================================================
# Test 3: overlay agent file exists
# EXPECTED TO FAIL IN RED PHASE: plugins/dso/agents/code-reviewer-test-quality.md
# does not yet exist. The .test-index marker [test_overlay_agent_file_exists]
# tolerates this failure until the agent file is created.
# ===========================================================================
echo "--- overlay agent file exists at plugins/dso/agents/code-reviewer-test-quality.md ---"
_snapshot_fail

agent_exists="false"
if [[ -f "$OVERLAY_AGENT_FILE" ]]; then
    agent_exists="true"
fi

# RED: assert will fail until plugins/dso/agents/code-reviewer-test-quality.md is created
assert_eq \
    "overlay agent file: plugins/dso/agents/code-reviewer-test-quality.md must exist" \
    "true" \
    "$agent_exists"

assert_pass_if_clean "test_overlay_agent_file_exists"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
print_summary
