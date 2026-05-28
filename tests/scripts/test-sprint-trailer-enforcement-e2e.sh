#!/usr/bin/env bash
# shellcheck disable=SC2164,SC2030,SC2031  # cd/subshell patterns in test setup
# tests/scripts/test-sprint-trailer-enforcement-e2e.sh
# E2E synthetic-workflow exercise of the Phase F provenance pipeline.
# Bug db71-e078-ec99-4fbf.
#
# Drives merge-story-branch.sh + verify-story-merge-trailer.sh end-to-end
# against three synthetic story branches:
#
#   story-divergent — real work on the story branch (the canonical case)
#   story-same-tip  — story branch tip == session tip (the F3 no-diff case)
#   story-bypassed  — "closed" without ever calling merge-story-branch.sh
#                     (simulates the f360-3a5b cross-contamination pattern)
#
# Assertions:
#   - merge-story-branch.sh against story-divergent emits a real merge commit
#     with the trailer.
#   - merge-story-branch.sh against story-same-tip emits an empty commit
#     with the trailer (F3 fix).
#   - verify-story-merge-trailer.sh exits 0 for both above.
#   - verify-story-merge-trailer.sh exits 1 for story-bypassed.
#
# Real scripts under real paths — no mocks.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MERGE="$REPO_ROOT/plugins/dso/scripts/merge-story-branch.sh"
VERIFY="$REPO_ROOT/plugins/dso/scripts/verify-story-merge-trailer.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-trailer-enforcement-e2e.sh ==="

if [[ ! -x "$MERGE" ]] || [[ ! -x "$VERIFY" ]]; then
    echo "FAIL: required scripts missing or not executable" >&2
    (( ++FAIL ))
    print_summary
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sprint-trailer-e2e.XXXXXX")
trap '[[ -n "${WORK:-}" ]] && rm -rf "$WORK"' EXIT

# Build the synthetic session repo.
git init "$WORK" --initial-branch=session --quiet 2>/dev/null \
    || git init "$WORK" --quiet 2>/dev/null
(
    cd "$WORK" || return
    git config user.email "e2e@test.com"
    git config user.name "E2E"
    echo "init" > README.md
    git add README.md
    git commit -m "session init" --quiet
    # Ensure we are on a branch named 'session' for clarity.
    git branch -M session 2>/dev/null || true
    # Base ref used by the verify gate.
    git branch base-ref HEAD --quiet \
        || git update-ref refs/heads/base-ref HEAD

    # -------------------- story-divergent --------------------
    git checkout -b story/e2e-epic/story-divergent --quiet
    echo "divergent work" > divergent.txt
    git add divergent.txt
    git commit -m "divergent story commit" --quiet
    git checkout session --quiet

    # -------------------- story-same-tip ----------------------
    # Branch tracks the session tip exactly.
    git branch story/e2e-epic/story-same-tip HEAD --quiet \
        || git update-ref refs/heads/story/e2e-epic/story-same-tip HEAD
)

# --- Merge divergent story → expect real merge commit + trailer ---
_snapshot_fail
(
    cd "$WORK" || return
    bash "$MERGE" "story/e2e-epic/story-divergent" "story-divergent" >/dev/null 2>&1
)
_DIV_PARENT_COUNT=$(cd "$WORK" && git log -1 --format=%P HEAD | wc -w | tr -d ' ')
assert_eq "e2e_divergent_creates_merge_commit_two_parents" "2" "$_DIV_PARENT_COUNT"
_DIV_MSG=$(cd "$WORK" && git log -1 --format=%B HEAD)
assert_contains "e2e_divergent_has_trailer" "DSO-Story-Merge: story-divergent" "$_DIV_MSG"
_DIV_VERIFY_RC=0
(
    cd "$WORK" || return
    bash "$VERIFY" "story-divergent" --base=base-ref >/dev/null 2>&1
) || _DIV_VERIFY_RC=$?
assert_eq "e2e_divergent_verify_exits_zero" "0" "$_DIV_VERIFY_RC"
assert_pass_if_clean "e2e_divergent_story_full_pipeline"

# --- Merge same-tip story → expect empty trailer commit (F3) + verify pass ---
_snapshot_fail
_PRE_HEAD=$(cd "$WORK" && git rev-parse HEAD)
(
    cd "$WORK" || return
    bash "$MERGE" "story/e2e-epic/story-same-tip" "story-same-tip" >/dev/null 2>&1
)
_POST_HEAD=$(cd "$WORK" && git rev-parse HEAD)
assert_ne "e2e_same_tip_advances_HEAD" "$_PRE_HEAD" "$_POST_HEAD"
_ST_MSG=$(cd "$WORK" && git log -1 --format=%B HEAD)
assert_contains "e2e_same_tip_has_trailer" "DSO-Story-Merge: story-same-tip" "$_ST_MSG"
_ST_VERIFY_RC=0
(
    cd "$WORK" || return
    bash "$VERIFY" "story-same-tip" --base=base-ref >/dev/null 2>&1
) || _ST_VERIFY_RC=$?
assert_eq "e2e_same_tip_verify_exits_zero" "0" "$_ST_VERIFY_RC"
assert_pass_if_clean "e2e_same_tip_story_full_pipeline"

# --- Bypassed story (never went through merge-story-branch.sh) → verify FAILS ---
_snapshot_fail
_BYPASS_RC=0
(
    cd "$WORK" || return
    bash "$VERIFY" "story-bypassed" --base=base-ref >/dev/null 2>&1
) || _BYPASS_RC=$?
assert_ne "e2e_bypassed_verify_exits_nonzero" "0" "$_BYPASS_RC"
assert_pass_if_clean "e2e_bypassed_story_blocked_at_close"

echo ""
echo "=== E2E synthetic workflow PASS — all three story paths exercised ==="
print_summary
