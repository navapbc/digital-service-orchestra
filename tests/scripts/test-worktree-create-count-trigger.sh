#!/usr/bin/env bash
# test-worktree-create-count-trigger.sh — Axis 2 of bug e9cb-3e2e-9b8b-4e5d
#
# The auto-cleanup trigger in worktree-create.sh counts accumulated worktrees and
# fires cleanup at >=10. The original count regex only matched timestamp-named
# worktrees (worktree-YYYYMMDD-HHMMSS), so human/session worktrees named wt-*,
# fix-*, feat-* never counted toward the trigger and accumulated unbounded.
#
# Behavior under test (observable): given a set of registered worktrees, the
# count the script computes for its cleanup trigger MUST include human/session
# worktrees regardless of naming (wt-*, fix-*, worktree-TIMESTAMP) and MUST
# still exclude transient agent-* worktrees, the main repo, and .tickets-tracker.
#
# Strategy: the count expression is not directly callable, so we drive the
# observable trigger behavior end-to-end. We seed a main repo with N human
# worktrees of mixed naming (none timestamp-named) plus an agent-* worktree, then
# create one more worktree and assert the script announces "automatic cleanup"
# (the >=10 trigger). With the old timestamp-only regex the count would be 0 and
# the trigger would NOT fire. We also assert agent-* worktrees alone do NOT trip
# the trigger.

set -uo pipefail

PASS=0
FAIL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/worktree-create.sh"

_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]}"; do
        if [ -d "$d" ]; then
            git -C "$d" worktree list --porcelain 2>/dev/null | grep '^worktree ' | sed 's/^worktree //' | while read -r wt; do
                [ "$wt" != "$d" ] && git -C "$d" worktree remove --force "$wt" 2>/dev/null || true
            done
            rm -rf "$d"
        fi
    done
}
trap _cleanup EXIT

echo "=== test-worktree-create-count-trigger.sh ==="

# Build a main repo with one initial commit and a working CLAUDE_PLUGIN_ROOT.
_setup_repo() {
    local repo
    repo=$(mktemp -d "${TMPDIR:-/tmp}/wt-count-repo.XXXXXX")
    _CLEANUP_DIRS+=("$repo")
    git init -b main "$repo" &>/dev/null
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" commit --allow-empty -m "init" &>/dev/null
    echo "$repo"
}

# Add a worktree with an arbitrary branch/dir name.
_add_wt() {
    local repo="$1" name="$2" dir="$3"
    git -C "$repo" worktree add "$dir/$name" -b "$name" &>/dev/null
}

# ── Test 1: 10 pre-existing human worktrees (non-timestamp names) trip the trigger ──
# The count is computed over ALREADY-registered worktrees BEFORE the new one is
# created, so the fixture needs 10 pre-existing human worktrees named
# wt-*/fix-*/feat-* (none timestamp-named). When an 11th is created, the count is
# 10 → the >=10 trigger fires. With the old timestamp-only regex the count would
# be 0 and the trigger would NOT fire.
echo "Test 1: human worktrees (wt-*/fix-*/feat-*) count toward >=10 trigger"
REPO=$(_setup_repo)
export CLAUDE_PLUGIN_ROOT="$REPO"
WT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wt-count-trees.XXXXXX")
_CLEANUP_DIRS+=("$WT_DIR")
# Create 10 pre-existing human worktrees with assorted non-timestamp names.
for i in 1 2 3 4; do _add_wt "$REPO" "wt-feature-$i" "$WT_DIR"; done
for i in 1 2 3; do _add_wt "$REPO" "fix-bug-$i" "$WT_DIR"; done
for i in 1 2 3; do _add_wt "$REPO" "feat-thing-$i" "$WT_DIR"; done
# Creating one more worktree: the count of pre-existing session worktrees is 10,
# so the >=10 trigger must fire.
out=$(cd "$REPO" && bash "$SCRIPT" --name="wt-eleventh" --dir="$WT_DIR" --skip-pull 2>&1 || true)
if echo "$out" | grep -qiE "automatic cleanup|Running automatic cleanup"; then
    echo "  PASS: trigger fired for accumulated non-timestamp human worktrees"
    PASS=$((PASS+1))
else
    echo "  FAIL: trigger did NOT fire — human worktrees were not counted" >&2
    echo "  --- output ---" >&2
    echo "$out" | sed 's/^/    /' >&2
    FAIL=$((FAIL+1))
fi
_cleanup
_CLEANUP_DIRS=()

# ── Test 2: agent-* worktrees alone do NOT trip the trigger ───────────────────
# Given a repo whose only extra worktrees are transient agent-* worktrees,
# When a new worktree is created, Then the count must NOT reach the trigger
# (agent-* worktrees are excluded by design).
echo "Test 2: agent-* worktrees are excluded from the count"
REPO=$(_setup_repo)
export CLAUDE_PLUGIN_ROOT="$REPO"
AGENT_DIR="$REPO/.claude/worktrees"
mkdir -p "$AGENT_DIR"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    git -C "$REPO" worktree add "$AGENT_DIR/agent-$i" -b "agent-$i" &>/dev/null
done
out=$(cd "$REPO" && bash "$SCRIPT" --name="wt-after-agents" --dir="$(mktemp -d "${TMPDIR:-/tmp}/wt-count-trees2.XXXXXX")" --skip-pull 2>&1 || true)
if echo "$out" | grep -qiE "automatic cleanup"; then
    echo "  FAIL: trigger fired on agent-* worktrees (should be excluded)" >&2
    echo "$out" | sed 's/^/    /' >&2
    FAIL=$((FAIL+1))
else
    echo "  PASS: agent-* worktrees did not trip the trigger"
    PASS=$((PASS+1))
fi
_cleanup
_CLEANUP_DIRS=()

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
