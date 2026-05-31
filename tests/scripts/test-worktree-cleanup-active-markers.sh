#!/usr/bin/env bash
# test-worktree-cleanup-active-markers.sh — Axis 5 of bug e9cb-3e2e-9b8b-4e5d
#
# A concurrently-active session must NEVER have its worktree reclaimed by cleanup,
# even when that worktree is merged + effectively clean + old. The authoritative
# "do not touch — work in progress" signals are the `.sprint-active` and
# `.debug-active` markers (written by /dso:sprint and /dso:debug-everything).
#
# Before this fix, is_claude_active() only honored a live-PID `.claude-session.lock`
# and `lsof` cwd matching — it ignored `.sprint-active`/`.debug-active`. A paused
# sprint whose worktree happened to be merged+clean+old could be deleted out from
# under the other session. This test pins the marker-based KEEP guard on BOTH the
# `--all` sweep path and the targeted `--worktree` path.
#
# Strategy: bare origin + clone, create merged branches, add worktrees, mark some
# with .sprint-active/.debug-active, run real removal, assert marked worktrees
# remain on disk. Disk presence is the observable outcome.

set -uo pipefail

PASS=0
FAIL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/worktree-cleanup.sh"

_CLEANUP_DIRS=()
_cleanup() {
    local _rc=$?
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

echo "=== test-worktree-cleanup-active-markers.sh ==="

setup_repo() {
    local origin clone
    origin=$(mktemp -d "${TMPDIR:-/tmp}/wt-active-origin.XXXXXX")
    clone=$(mktemp -d "${TMPDIR:-/tmp}/wt-active-clone.XXXXXX")
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

# Add a MERGED worktree on a new branch (so only the active-marker can save it).
add_merged_worktree() {
    local repo="$1" parent="$2" name="$3"
    git -C "$repo" branch "$name" main &>/dev/null
    git -C "$repo" worktree add "$parent/$name" "$name" &>/dev/null
    git -C "$parent/$name" commit --allow-empty -m "work on $name" &>/dev/null
    git -C "$repo" merge --no-ff "$name" -m "Merge $name (merge $name)" &>/dev/null
    git -C "$repo" push origin main &>/dev/null 2>&1 || true
}

REPO=$(setup_repo)
WT=$(mktemp -d "${TMPDIR:-/tmp}/wt-active-trees.XXXXXX")
_CLEANUP_DIRS+=("$WT")

# A: merged + clean + .sprint-active  → KEEP (active sprint)
add_merged_worktree "$REPO" "$WT" "active-sprint"
: > "$WT/active-sprint/.sprint-active"

# B: merged + clean + .debug-active   → KEEP (active debug)
add_merged_worktree "$REPO" "$WT" "active-debug"
: > "$WT/active-debug/.debug-active"

# C: merged + clean + NO marker       → REMOVED (control: proves removal works)
add_merged_worktree "$REPO" "$WT" "inactive-plain"

# Run the real --all removal with age gate disabled.
( cd "$REPO" && AGE_HOURS=0 bash "$SCRIPT" --all --force --no-branches ) >/dev/null 2>&1 || true

echo "Test 1: merged+clean WITH .sprint-active → kept (--all sweep)"
if [ -d "$WT/active-sprint" ]; then
    echo "  PASS: active-sprint kept"
    PASS=$((PASS+1))
else
    echo "  FAIL: active-sprint REMOVED — active sprint worktree destroyed" >&2
    FAIL=$((FAIL+1))
fi

echo "Test 2: merged+clean WITH .debug-active → kept (--all sweep)"
if [ -d "$WT/active-debug" ]; then
    echo "  PASS: active-debug kept"
    PASS=$((PASS+1))
else
    echo "  FAIL: active-debug REMOVED — active debug worktree destroyed" >&2
    FAIL=$((FAIL+1))
fi

echo "Test 3: control — merged+clean, no marker → removed"
if [ ! -d "$WT/inactive-plain" ]; then
    echo "  PASS: inactive-plain removed (removal path works)"
    PASS=$((PASS+1))
else
    echo "  FAIL: inactive-plain still present — removal path not exercised (test invalid)" >&2
    FAIL=$((FAIL+1))
fi

# Targeted --worktree path must ALSO refuse an active-marked worktree.
add_merged_worktree "$REPO" "$WT" "active-targeted"
: > "$WT/active-targeted/.sprint-active"
echo "Test 4: targeted --worktree on .sprint-active worktree → refused, dir remains"
( cd "$REPO" && AGE_HOURS=0 bash "$SCRIPT" --worktree "$WT/active-targeted" --force ) >/dev/null 2>&1 || true
if [ -d "$WT/active-targeted" ]; then
    echo "  PASS: targeted removal refused for active-marked worktree"
    PASS=$((PASS+1))
else
    echo "  FAIL: targeted removal deleted an active-marked worktree" >&2
    FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
