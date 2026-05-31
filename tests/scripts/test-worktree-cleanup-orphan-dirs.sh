#!/usr/bin/env bash
# test-worktree-cleanup-orphan-dirs.sh — Axis 1 of bug e9cb-3e2e-9b8b-4e5d
#
# Class A orphans: directories sitting in the worktree-parent dir that are NOT
# registered git worktrees (left behind by manual `git worktree remove`, crashed
# sessions, or `git worktree prune` which only cleans git metadata, not the dir).
# worktree-cleanup.sh enumerated only `git worktree list`, so these were invisible
# to every code path and accumulated unbounded.
#
# Behavior under test (observable, via real --all --force then disk presence):
#   - An EMPTY orphan dir in the worktree-parent is REMOVED.
#   - An orphan dir containing a REAL file is KEPT (data safety).
#   - An orphan dir whose only content is regenerable (.claude/scratch) is REMOVED.
#   - A registered worktree in the same parent is KEPT (never swept).
#   - The current worktree is KEPT.
#
# Strategy: build a repo, create the worktree-parent dir, register one worktree
# there, drop several non-registered sibling dirs, run cleanup, assert which
# directories remain on disk.

set -uo pipefail

PASS=0
FAIL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/worktree-cleanup.sh"

_CLEANUP_DIRS=()
_cleanup() {
    local _rc=$?  # preserve the script's exit status across the EXIT trap
    local d wt
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        [ -d "$d" ] || continue
        while read -r wt; do
            [ -n "$wt" ] && [ "$wt" != "$d" ] && git -C "$d" worktree remove --force "$wt" 2>/dev/null
        done < <(git -C "$d" worktree list --porcelain 2>/dev/null | grep '^worktree ' | sed 's/^worktree //')
        rm -rf "$d"
    done
    return "$_rc"
}
trap _cleanup EXIT

echo "=== test-worktree-cleanup-orphan-dirs.sh ==="

# A repo whose worktree-parent dir is a sibling: <repo>-worktrees.
# worktree-create.sh derives the parent as $(dirname repo)/$(basename repo)-worktrees;
# the cleanup sweep must scan the parent of the registered worktrees.
setup_repo() {
    local base repo
    base=$(mktemp -d "${TMPDIR:-/tmp}/wt-orphan-base.XXXXXX")
    _CLEANUP_DIRS+=("$base")
    repo="$base/proj"
    git init "$repo" &>/dev/null
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" checkout -b main &>/dev/null 2>&1 || true
    git -C "$repo" commit --allow-empty -m "init" &>/dev/null
    echo "$repo"
}

REPO=$(setup_repo)
PARENT="$(dirname "$REPO")/proj-worktrees"
mkdir -p "$PARENT"

# Register a real worktree inside the parent so the sweep can resolve the parent
# from `git worktree list` and so we can assert it is never swept.
git -C "$REPO" branch real-wt main &>/dev/null
git -C "$REPO" worktree add "$PARENT/real-wt" real-wt &>/dev/null
git -C "$PARENT/real-wt" commit --allow-empty -m "work" &>/dev/null
git -C "$REPO" merge --no-ff real-wt -m "Merge real-wt (merge real-wt)" &>/dev/null

# Class A orphan fixtures (siblings of the registered worktree, not registered):
mkdir -p "$PARENT/orphan-empty"                                   # → REMOVE
mkdir -p "$PARENT/orphan-realfile"; echo data > "$PARENT/orphan-realfile/keep.txt"   # → KEEP
mkdir -p "$PARENT/orphan-scratch/.claude/scratch"; echo x > "$PARENT/orphan-scratch/.claude/scratch/n.txt"  # → REMOVE
# A linked-worktree lookalike: has a .git file → must NOT be swept by the orphan
# sweep (the registered-worktree path/branch logic owns those).
mkdir -p "$PARENT/orphan-haslinkgit"; echo "gitdir: /nowhere" > "$PARENT/orphan-haslinkgit/.git"  # → KEEP

# Run real cleanup (age 0 so the merged real-wt is also eligible; sweep honors --force).
( cd "$REPO" && AGE_HOURS=0 bash "$SCRIPT" --all --force --no-branches ) >/dev/null 2>&1 || true

# ── Test 1: empty orphan dir removed ──────────────────────────────────────────
echo "Test 1: empty orphan dir → removed"
if [ ! -d "$PARENT/orphan-empty" ]; then
    echo "  PASS: empty orphan dir removed"
    PASS=$((PASS+1))
else
    echo "  FAIL: empty orphan dir still present" >&2
    FAIL=$((FAIL+1))
fi

# ── Test 2: orphan dir with a real file kept ──────────────────────────────────
echo "Test 2: orphan dir with a real file → kept"
if [ -d "$PARENT/orphan-realfile" ] && [ -f "$PARENT/orphan-realfile/keep.txt" ]; then
    echo "  PASS: orphan dir with real file kept"
    PASS=$((PASS+1))
else
    echo "  FAIL: orphan dir with real file was removed — data loss" >&2
    FAIL=$((FAIL+1))
fi

# ── Test 3: orphan dir with only regenerable content removed ──────────────────
echo "Test 3: orphan dir with only .claude/scratch → removed"
if [ ! -d "$PARENT/orphan-scratch" ]; then
    echo "  PASS: regenerable-only orphan dir removed"
    PASS=$((PASS+1))
else
    echo "  FAIL: regenerable-only orphan dir still present" >&2
    FAIL=$((FAIL+1))
fi

# ── Test 4: dir with a .git link file is not swept ────────────────────────────
echo "Test 4: orphan dir with a .git file → kept (not the sweep's job)"
if [ -d "$PARENT/orphan-haslinkgit" ]; then
    echo "  PASS: .git-bearing dir left untouched by the sweep"
    PASS=$((PASS+1))
else
    echo "  FAIL: .git-bearing dir was swept — sweep must skip linked-worktree lookalikes" >&2
    FAIL=$((FAIL+1))
fi

# ── Test 5: registered worktree is never swept ────────────────────────────────
# (real-wt is merged+clean so the normal removal path may remove it; the SWEEP
# must never be the thing that removes a still-registered worktree. We assert the
# sweep does not delete a registered worktree out from under git: create a second
# registered worktree that is NOT removable, then confirm it survives.)
echo "Test 5: registered (non-removable) worktree survives the sweep"
git -C "$REPO" branch keep-wt main &>/dev/null
git -C "$REPO" worktree add "$PARENT/keep-wt" keep-wt &>/dev/null
git -C "$PARENT/keep-wt" commit --allow-empty -m "unmerged work" &>/dev/null  # unmerged → not removable
( cd "$REPO" && AGE_HOURS=0 bash "$SCRIPT" --all --force --no-branches ) >/dev/null 2>&1 || true
if [ -d "$PARENT/keep-wt" ]; then
    echo "  PASS: registered unmerged worktree survives the orphan sweep"
    PASS=$((PASS+1))
else
    echo "  FAIL: registered worktree was removed by the sweep" >&2
    FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
