#!/usr/bin/env bash
# test-worktree-cleanup-scratch-clean.sh — Axis 3 of bug e9cb-3e2e-9b8b-4e5d
#
# Merged worktrees almost always carry regenerable session debris
# (.claude/scratch/), which made the general is_clean check
# (`git status --porcelain` flags ANY untracked file) keep every merged human
# worktree forever.
#
# Behavior under test (observable, via real --all --force removal):
#   - A MERGED worktree whose ONLY untracked/modified content is under
#     .claude/scratch/ IS removed (the regenerable allowlist makes it eligible).
#   - A MERGED worktree with ANY real untracked/modified file OUTSIDE the
#     allowlist is KEPT (its directory still exists after cleanup).
#   - An UNMERGED worktree with only scratch dirt is KEPT — the scratch
#     allowlist must NEVER make an unmerged worktree removable.
#
# Strategy: build a bare origin + clone, create branches, merge the ones that
# should be merged, add worktrees, dirty them in the relevant way, then run
# `worktree-cleanup.sh --all --force --no-branches` and assert on which worktree
# directories remain on disk afterward. Disk presence is the observable outcome.

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

echo "=== test-worktree-cleanup-scratch-clean.sh ==="

# Bare origin + clone, with main pushed.
setup_repo() {
    local origin clone
    origin=$(mktemp -d "${TMPDIR:-/tmp}/wt-scratch-origin.XXXXXX")
    clone=$(mktemp -d "${TMPDIR:-/tmp}/wt-scratch-clone.XXXXXX")
    _CLEANUP_DIRS+=("$origin" "$clone")
    git init --bare "$origin" &>/dev/null
    git clone "$origin" "$clone" &>/dev/null
    git -C "$clone" config user.email "test@example.com"
    git -C "$clone" config user.name "Test"
    git -C "$clone" checkout -b main &>/dev/null 2>&1 || true
    git -C "$clone" commit --allow-empty -m "init" &>/dev/null
    git -C "$clone" push -u origin main &>/dev/null
    echo "$clone"
}

# Add a worktree on a NEW branch, optionally merge it to main first.
# args: repo, wt_parent_dir, name, merged(yes|no)
add_branch_worktree() {
    local repo="$1" parent="$2" name="$3" merged="$4"
    git -C "$repo" branch "$name" main &>/dev/null
    git -C "$repo" worktree add "$parent/$name" "$name" &>/dev/null
    git -C "$parent/$name" commit --allow-empty -m "work on $name" &>/dev/null
    if [ "$merged" = "yes" ]; then
        git -C "$repo" merge --no-ff "$name" -m "Merge $name (merge $name)" &>/dev/null
        git -C "$repo" push origin main &>/dev/null 2>&1 || true
    fi
}

REPO=$(setup_repo)
WT=$(mktemp -d "${TMPDIR:-/tmp}/wt-scratch-trees.XXXXXX")
_CLEANUP_DIRS+=("$WT")

# Scenario A: merged worktree, only .claude/scratch dirt → should be REMOVED.
add_branch_worktree "$REPO" "$WT" "merged-scratch" "yes"
mkdir -p "$WT/merged-scratch/.claude/scratch"
echo "regenerable" > "$WT/merged-scratch/.claude/scratch/notes.txt"

# Scenario B: merged worktree, a REAL untracked file outside allowlist → KEEP.
add_branch_worktree "$REPO" "$WT" "merged-realdirt" "yes"
echo "important uncommitted work" > "$WT/merged-realdirt/IMPORTANT.txt"

# Scenario C: unmerged worktree, only scratch dirt → KEEP (not merged).
add_branch_worktree "$REPO" "$WT" "unmerged-scratch" "no"
mkdir -p "$WT/unmerged-scratch/.claude/scratch"
echo "regenerable" > "$WT/unmerged-scratch/.claude/scratch/notes.txt"

# Make all worktrees old enough to pass the age gate, and run the real removal.
# --no-branches keeps branch deletion out of scope for this disk-presence test.
( cd "$REPO" && AGE_HOURS=0 bash "$SCRIPT" --all --force --no-branches ) >/dev/null 2>&1 || true

# ── Test 1: merged worktree with only scratch dirt is removed ─────────────────
echo "Test 1: merged + scratch-only dirt → removed"
if [ ! -d "$WT/merged-scratch" ]; then
    echo "  PASS: merged-scratch removed (scratch dirt treated as effectively clean)"
    PASS=$((PASS+1))
else
    echo "  FAIL: merged-scratch still present (scratch dirt should not block removal)" >&2
    FAIL=$((FAIL+1))
fi

# ── Test 2: merged worktree with a real untracked file is kept ────────────────
echo "Test 2: merged + real untracked file → kept"
if [ -d "$WT/merged-realdirt" ]; then
    echo "  PASS: merged-realdirt kept (real dirt outside allowlist protected)"
    PASS=$((PASS+1))
else
    echo "  FAIL: merged-realdirt was removed — real untracked work lost" >&2
    FAIL=$((FAIL+1))
fi

# ── Test 3: unmerged worktree with scratch dirt is kept ───────────────────────
echo "Test 3: unmerged + scratch-only dirt → kept (not merged)"
if [ -d "$WT/unmerged-scratch" ]; then
    echo "  PASS: unmerged-scratch kept (allowlist must not apply to unmerged)"
    PASS=$((PASS+1))
else
    echo "  FAIL: unmerged-scratch was removed — scratch allowlist leaked to unmerged" >&2
    FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
