#!/usr/bin/env bash
# tests/hooks/test-overlay-dispatch.sh
# RED tests for overlay dispatch logic (story w22-25ui, epic dso-5ooy)
#
# Tests the three dispatch branches of the overlay dispatch helper:
#   parallel  — classifier signals security_overlay=true directly
#   serial    — tier reviewer summary contains security_overlay_warranted: yes
#   no-overlay — both flags absent/false; no overlay warranted
#   graceful degradation — overlay agent failure must not block the commit
#
# All tests FAIL in RED phase because plugins/dso/scripts/overlay-dispatch.sh
# does not exist yet. It will be implemented by task 67e2-2912.
#
# Expected interface (to be satisfied by implementation):
#   source overlay-dispatch.sh
#   overlay_dispatch_mode <classifier_json_file> <reviewer_summary_file>
#   Returns: "parallel" | "serial" | "none" on stdout; exit 0 always.
#   run_overlay_agent <mode> <artifacts_dir>
#   Returns: exit 0 on success, non-zero on failure.
#   overlay_dispatch_with_fallback <classifier_json_file> <reviewer_summary_file> <artifacts_dir>
#   Returns: exit 0 even when overlay agent exits non-zero.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
source "$REPO_ROOT/tests/lib/assert.sh"

OVERLAY_DISPATCH_SCRIPT="$REPO_ROOT/plugins/dso/scripts/overlay-dispatch.sh"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

make_tmpdir() {
    local d
    d="$(mktemp -d)"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ---------------------------------------------------------------------------
# Helper: load the dispatch library (gracefully absent in RED phase)
# ---------------------------------------------------------------------------
_OVERLAY_LOADED=0
if [[ -f "$OVERLAY_DISPATCH_SCRIPT" ]]; then
    # shellcheck source=/dev/null
    source "$OVERLAY_DISPATCH_SCRIPT" && _OVERLAY_LOADED=1
else
    echo "NOTE: overlay-dispatch.sh not found — running in RED phase (all tests expected to FAIL)"
fi

# ---------------------------------------------------------------------------
# Helper: write a classifier JSON fixture to a temp file
# ---------------------------------------------------------------------------
write_classifier_json() {
    local outfile="$1"
    local security_overlay="${2:-false}"
    local performance_overlay="${3:-false}"
    python3 - "$outfile" "$security_overlay" "$performance_overlay" <<'PYEOF'
import json, sys
path, sec, priv = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "w") as f:
    json.dump({
        "selected_tier": "standard",
        "score": 4,
        "security_overlay": sec == "true",
        "performance_overlay": priv == "true"
    }, f)
PYEOF
}

# ---------------------------------------------------------------------------
# Helper: write a reviewer summary fixture to a temp file
# ---------------------------------------------------------------------------
write_reviewer_summary() {
    local outfile="$1"
    local security_warranted="${2:-no}"
    local performance_warranted="${3:-no}"
    cat > "$outfile" <<SUMMARY
security_overlay_warranted: $security_warranted
performance_overlay_warranted: $performance_warranted
SUMMARY
}

echo "=== test-overlay-dispatch.sh ==="
echo ""

# ===========================================================================
# Test 1: parallel dispatch — classifier signals security_overlay=true
# ===========================================================================
echo "--- parallel dispatch (classifier security_overlay=true) ---"
_snapshot_fail

tmpdir="$(make_tmpdir)"
classifier_json="$tmpdir/classifier.json"
reviewer_summary="$tmpdir/reviewer-summary.txt"

write_classifier_json "$classifier_json" "true" "false"
write_reviewer_summary "$reviewer_summary" "no" "no"

actual_mode="FUNCTION_NOT_FOUND"
if [[ "$_OVERLAY_LOADED" -eq 1 ]]; then
    actual_mode="$(overlay_dispatch_mode "$classifier_json" "$reviewer_summary" 2>/dev/null)" || true
fi

assert_eq \
    "parallel dispatch: security_overlay=true in classifier JSON returns 'parallel'" \
    "parallel" \
    "$actual_mode"

assert_pass_if_clean "test_parallel_dispatch_from_classifier_signal"

# ===========================================================================
# Test 2: serial dispatch — reviewer summary contains security_overlay_warranted: yes
# ===========================================================================
echo "--- serial dispatch (reviewer summary security_overlay_warranted: yes) ---"
_snapshot_fail

tmpdir="$(make_tmpdir)"
classifier_json="$tmpdir/classifier.json"
reviewer_summary="$tmpdir/reviewer-summary.txt"

# Classifier says no overlay; reviewer summary says overlay is warranted
write_classifier_json "$classifier_json" "false" "false"
write_reviewer_summary "$reviewer_summary" "yes" "no"

actual_mode="FUNCTION_NOT_FOUND"
if [[ "$_OVERLAY_LOADED" -eq 1 ]]; then
    actual_mode="$(overlay_dispatch_mode "$classifier_json" "$reviewer_summary" 2>/dev/null)" || true
fi

assert_eq \
    "serial dispatch: reviewer summary security_overlay_warranted:yes returns 'serial'" \
    "serial" \
    "$actual_mode"

assert_pass_if_clean "test_serial_dispatch_from_reviewer_summary"

# ===========================================================================
# Test 3: no-overlay — both classifier flags false and reviewer summary both no
# ===========================================================================
echo "--- no-overlay (all flags false/no) ---"
_snapshot_fail

tmpdir="$(make_tmpdir)"
classifier_json="$tmpdir/classifier.json"
reviewer_summary="$tmpdir/reviewer-summary.txt"

write_classifier_json "$classifier_json" "false" "false"
write_reviewer_summary "$reviewer_summary" "no" "no"

actual_mode="FUNCTION_NOT_FOUND"
if [[ "$_OVERLAY_LOADED" -eq 1 ]]; then
    actual_mode="$(overlay_dispatch_mode "$classifier_json" "$reviewer_summary" 2>/dev/null)" || true
fi

assert_eq \
    "no-overlay: both flags absent returns 'none'" \
    "none" \
    "$actual_mode"

assert_pass_if_clean "test_no_overlay_when_all_flags_absent"

# ===========================================================================
# Test 4: graceful degradation — overlay agent failure does NOT block commit
# ===========================================================================
echo "--- graceful degradation (overlay agent failure returns exit 0) ---"
_snapshot_fail

tmpdir="$(make_tmpdir)"
classifier_json="$tmpdir/classifier.json"
reviewer_summary="$tmpdir/reviewer-summary.txt"
artifacts_dir="$tmpdir/artifacts"
mkdir -p "$artifacts_dir"

# Set up a scenario that would trigger parallel dispatch
write_classifier_json "$classifier_json" "true" "false"
write_reviewer_summary "$reviewer_summary" "no" "no"

# Define a failing overlay agent mock (simulates overlay agent crashing)
run_overlay_agent() {
    # Override: always fail to simulate agent crash
    return 1
}
export -f run_overlay_agent 2>/dev/null || true

fallback_exit=1
if [[ "$_OVERLAY_LOADED" -eq 1 ]]; then
    overlay_dispatch_with_fallback \
        "$classifier_json" "$reviewer_summary" "$artifacts_dir" \
        2>/dev/null
    fallback_exit=$?
fi

assert_eq \
    "graceful degradation: overlay agent failure returns exit 0 (commit not blocked)" \
    "0" \
    "$fallback_exit"

assert_pass_if_clean "test_graceful_degradation_overlay_agent_failure"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
print_summary
