#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-review-stop.sh
# Tests for .claude/hooks/review-stop-check.sh
#
# review-stop-check.sh is a Stop hook (SOFT GATE) that outputs a reminder
# when uncommitted code changes haven't been reviewed. Always exits 0.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$PLUGIN_ROOT/hooks/review-stop-check.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$PLUGIN_ROOT/hooks/lib/deps.sh"

ARTIFACTS_DIR=$(get_artifacts_dir)
REVIEW_STATE="$ARTIFACTS_DIR/review-status"

run_hook_exit() {
    local exit_code=0
    bash "$HOOK" >/dev/null 2>/dev/null < /dev/null || exit_code=$?
    echo "$exit_code"
}

run_hook_output() {
    bash "$HOOK" 2>/dev/null < /dev/null
}

# test_review_stop_exits_zero_on_non_review_command
# This is a Stop hook, so it takes no stdin. Always exits 0.
EXIT_CODE=$(run_hook_exit)
assert_eq "test_review_stop_exits_zero_on_non_review_command" "0" "$EXIT_CODE"

# test_review_stop_exits_zero_always
# The Stop hook always exits 0 (soft gate, warning only)
EXIT_CODE=$(run_hook_exit)
assert_eq "test_review_stop_exits_zero_always" "0" "$EXIT_CODE"

# test_review_stop_exits_zero_with_passed_current_review
# If review is passed and diff hash is current, no warning → silent exit 0
CURRENT_HASH=$("$PLUGIN_ROOT/hooks/compute-diff-hash.sh" 2>/dev/null || echo "testhash")
mkdir -p "$ARTIFACTS_DIR"
ORIG_STATE=""
if [[ -f "$REVIEW_STATE" ]]; then
    ORIG_STATE=$(cat "$REVIEW_STATE")
fi
printf "passed\ntimestamp=2026-01-01T00:00:00Z\ndiff_hash=%s\nscore=4\nreview_hash=abc\n" "$CURRENT_HASH" > "$REVIEW_STATE"

EXIT_CODE=$(run_hook_exit)
assert_eq "test_review_stop_exits_zero_with_passed_current_review" "0" "$EXIT_CODE"

# Restore state
if [[ -n "$ORIG_STATE" ]]; then
    echo "$ORIG_STATE" > "$REVIEW_STATE"
else
    rm -f "$REVIEW_STATE"
fi

# test_review_stop_exits_zero_with_stale_review
# Even with stale review, still exits 0 (soft gate)
mkdir -p "$ARTIFACTS_DIR"
printf "passed\ntimestamp=2026-01-01T00:00:00Z\ndiff_hash=stale-hash-that-wont-match\nscore=4\nreview_hash=abc\n" > "$REVIEW_STATE"

EXIT_CODE=$(run_hook_exit)
assert_eq "test_review_stop_exits_zero_with_stale_review" "0" "$EXIT_CODE"

# Restore state
if [[ -n "$ORIG_STATE" ]]; then
    echo "$ORIG_STATE" > "$REVIEW_STATE"
else
    rm -f "$REVIEW_STATE"
fi

print_summary
