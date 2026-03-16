#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-pre-push-sentinel-check.sh
# Tests for lockpick-workflow/hooks/pre-push-sentinel-check.sh
#
# pre-push-sentinel-check.sh blocks git push if .checkpoint-needs-review
# is tracked in HEAD (HEAD-based check, not stdin parsing).
#
# Usage: bash lockpick-workflow/tests/hooks/test-pre-push-sentinel-check.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/pre-push-sentinel-check.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# ── test_push_blocked_when_sentinel_in_head ──────────────────────────────────
# When .checkpoint-needs-review is committed to HEAD, the hook must exit
# non-zero and emit a message containing "Push blocked" or
# "checkpoint-needs-review".

TEST_GIT_A=$(mktemp -d)
trap 'rm -rf "$TEST_GIT_A"' EXIT

(
    cd "$TEST_GIT_A"
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "Test"
    # Initial commit so HEAD exists
    echo "initial" > README.md
    git add README.md
    git commit -q -m "init"
    # Commit the sentinel so it is tracked in HEAD
    echo "abc123nonce" > .checkpoint-needs-review
    git add .checkpoint-needs-review
    git commit -q -m "checkpoint: pre-compaction auto-save"
) 2>/dev/null

HOOK_EXIT=0
HOOK_OUTPUT=$(cd "$TEST_GIT_A" && bash "$HOOK" 2>&1) || HOOK_EXIT=$?

# Assert: exit code is non-zero (push is blocked)
if [[ "$HOOK_EXIT" -ne 0 ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: test_push_blocked_when_sentinel_in_head\n  expected non-zero exit, got: %s\n" "$HOOK_EXIT" >&2
fi

# Assert: output contains "Push blocked" or "checkpoint-needs-review"
if [[ "$HOOK_OUTPUT" == *"Push blocked"* ]] || [[ "$HOOK_OUTPUT" == *"checkpoint-needs-review"* ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: test_push_blocked_when_sentinel_in_head (output check)\n  expected 'Push blocked' or 'checkpoint-needs-review' in output\n  actual: %s\n" "$HOOK_OUTPUT" >&2
fi

rm -rf "$TEST_GIT_A"
trap - EXIT

# ── test_push_passes_when_sentinel_not_in_head ───────────────────────────────
# When .checkpoint-needs-review is NOT in HEAD, the hook must exit 0.

TEST_GIT_B=$(mktemp -d)
trap 'rm -rf "$TEST_GIT_B"' EXIT

(
    cd "$TEST_GIT_B"
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "Test"
    # Normal commit — no sentinel
    echo "feature code" > feature.py
    git add feature.py
    git commit -q -m "feat: normal work"
) 2>/dev/null

HOOK_EXIT_B=0
cd "$TEST_GIT_B" && bash "$HOOK" 2>/dev/null || HOOK_EXIT_B=$?
cd "$REPO_ROOT"

assert_eq "test_push_passes_when_sentinel_not_in_head" "0" "$HOOK_EXIT_B"

rm -rf "$TEST_GIT_B"
trap - EXIT

print_summary
