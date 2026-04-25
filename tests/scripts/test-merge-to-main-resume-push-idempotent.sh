#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-resume-push-idempotent.sh
# Structural tests for f9e7-2c50:
#   --resume re-runs _phase_merge after SIGURG interrupted push, creating a
#   duplicate merge commit and causing non-fast-forward push failure.
#
# Root cause: if SIGURG fires after git push succeeds but before
# _state_mark_complete "push", the state file shows push as incomplete.
# --resume re-runs from the first incomplete phase; if origin/main has
# already been updated, re-running _phase_merge creates a new merge commit
# that conflicts with origin/main.
#
# Fix: the --resume block must contain an idempotent push check before
# iterating incomplete phases. If origin/main already contains local HEAD,
# phases through push are pre-marked complete so merge is never re-run.
#
# Per behavioral testing standard Rule 5 (instruction files): test the
# structural boundary of the script, not its runtime behavior.
#
# Usage: bash tests/scripts/test-merge-to-main-resume-push-idempotent.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

if [[ ! -f "$MERGE_SCRIPT" ]]; then
    echo "SKIP: merge-to-main.sh not found at $MERGE_SCRIPT"
    exit 0
fi

# ── Extract the --resume block from the script ────────────────────────────────
# The --resume block starts at: if [[ "$_CLI_RESUME" == "true" ]]; then
# and ends with: fi  (that closes the if block)
_RESUME_BLOCK=$(awk '
    /if \[\[ "\$_CLI_RESUME" == "true" \]\]; then/ { found=1; depth=1; print; next }
    found {
        print
        # Count fi / if to track block depth
        if (/^[[:space:]]*if /) depth++
        if (/^[[:space:]]*fi$/ || /^[[:space:]]*fi[[:space:]]/) {
            depth--
            if (depth == 0) { found=0 }
        }
    }
' "$MERGE_SCRIPT" 2>/dev/null)

# ============================================================
# test_resume_block_has_origin_main_ahead_check (f9e7-2c50)
#
# The --resume block must check if origin/main already contains local HEAD
# before iterating phases. This prevents re-running _phase_merge when push
# already completed but was not recorded in the state file.
#
# Pattern: git log origin/main..HEAD (the idempotent push detection)
# must appear in the --resume block before the phase iteration loop.
# ============================================================
test_resume_block_has_origin_main_ahead_check() {
    local found=0
    grep -q 'origin/main\.\.HEAD' <<< "$_RESUME_BLOCK" 2>/dev/null && found=1 || true
    assert_eq "resume block checks origin/main..HEAD before iterating phases (f9e7-2c50)" "1" "$found"
}

# ============================================================
# test_resume_block_pre_marks_phases_on_push_detected (f9e7-2c50)
#
# When push is detected as already done, the --resume block must call
# _state_mark_complete for phases through push so they are skipped.
# Check that the pre-mark logic exists in the --resume block.
# ============================================================
test_resume_block_pre_marks_phases_on_push_detected() {
    local found=0
    # The fix must mark "push" as complete when origin/main already has HEAD
    grep -q '_state_mark_complete.*push' <<< "$_RESUME_BLOCK" 2>/dev/null && found=1 || true
    assert_eq "resume block marks push as complete when push already done (f9e7-2c50)" "1" "$found"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_resume_block_has_origin_main_ahead_check
test_resume_block_pre_marks_phases_on_push_detected

print_summary
