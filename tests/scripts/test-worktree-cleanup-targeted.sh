#!/usr/bin/env bash
# test-worktree-cleanup-targeted.sh — Axis 4 of bug e9cb-3e2e-9b8b-4e5d
#
# end-session previously only VERIFIED a worktree was merged+clean and printed
# "claude-safe can auto-remove" — it never invoked removal, and claude-safe's own
# hook is TTY-gated, so agent/non-interactive sessions never cleaned up.
#
# To let end-session actually remove the finished worktree, worktree-cleanup.sh
# gains a targeted `--worktree <path>` mode that removes ONLY that worktree when
# it is merged + effectively-clean (regenerable-allowlist dirt tolerated).
#
# Behavior under test (observable, via real removal + disk presence):
#   - `--worktree <path> --force` on a merged + (effectively) clean worktree
#     REMOVES exactly that worktree.
#   - The same on an UNMERGED worktree leaves it in place (non-zero exit).
#   - `--worktree <path> --dry-run` previews and removes nothing.
#   - A merged worktree whose only dirt is .claude/scratch is removed (Axis 3
#     effectively-clean reused).

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

echo "=== test-worktree-cleanup-targeted.sh ==="

setup_repo() {
    local origin clone
    origin=$(mktemp -d "${TMPDIR:-/tmp}/wt-tgt-origin.XXXXXX")
    clone=$(mktemp -d "${TMPDIR:-/tmp}/wt-tgt-clone.XXXXXX")
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
WT=$(mktemp -d "${TMPDIR:-/tmp}/wt-tgt-trees.XXXXXX")
_CLEANUP_DIRS+=("$WT")

add_branch_worktree "$REPO" "$WT" "done-clean" "yes"
add_branch_worktree "$REPO" "$WT" "done-scratch" "yes"
mkdir -p "$WT/done-scratch/.claude/scratch"; echo x > "$WT/done-scratch/.claude/scratch/n.txt"
add_branch_worktree "$REPO" "$WT" "still-working" "no"
add_branch_worktree "$REPO" "$WT" "dryrun-clean" "yes"

# ── Test 1: targeted removal of a merged+clean worktree removes exactly it ─────
echo "Test 1: --worktree on merged+clean worktree removes it"
rc=0
( cd "$REPO" && AGE_HOURS=0 bash "$SCRIPT" --worktree "$WT/done-clean" --force --no-branches ) >/dev/null 2>&1 || rc=$?
if [ ! -d "$WT/done-clean" ] && [ "$rc" -eq 0 ]; then
    echo "  PASS: targeted merged+clean worktree removed (rc=$rc)"
    PASS=$((PASS+1))
else
    echo "  FAIL: targeted removal did not remove merged+clean worktree (present=$([ -d "$WT/done-clean" ] && echo y || echo n), rc=$rc)" >&2
    FAIL=$((FAIL+1))
fi

# ── Test 2: targeted removal leaves other worktrees untouched ─────────────────
echo "Test 2: targeted removal does not touch other worktrees"
if [ -d "$WT/done-scratch" ] && [ -d "$WT/still-working" ] && [ -d "$WT/dryrun-clean" ]; then
    echo "  PASS: only the targeted worktree was removed"
    PASS=$((PASS+1))
else
    echo "  FAIL: targeted mode removed worktrees other than the target" >&2
    FAIL=$((FAIL+1))
fi

# ── Test 3: targeted removal of an UNMERGED worktree refuses (non-zero) ────────
echo "Test 3: --worktree on unmerged worktree refuses and keeps it"
rc=0
( cd "$REPO" && AGE_HOURS=0 bash "$SCRIPT" --worktree "$WT/still-working" --force --no-branches ) >/dev/null 2>&1 || rc=$?
if [ -d "$WT/still-working" ] && [ "$rc" -ne 0 ]; then
    echo "  PASS: unmerged worktree refused (kept, rc=$rc)"
    PASS=$((PASS+1))
else
    echo "  FAIL: unmerged worktree was removed or exit was 0 (present=$([ -d "$WT/still-working" ] && echo y || echo n), rc=$rc)" >&2
    FAIL=$((FAIL+1))
fi

# ── Test 4: targeted dry-run removes nothing ──────────────────────────────────
echo "Test 4: --worktree --dry-run previews only"
( cd "$REPO" && AGE_HOURS=0 bash "$SCRIPT" --worktree "$WT/dryrun-clean" --dry-run ) >/dev/null 2>&1 || true
if [ -d "$WT/dryrun-clean" ]; then
    echo "  PASS: dry-run left the worktree in place"
    PASS=$((PASS+1))
else
    echo "  FAIL: dry-run removed the worktree" >&2
    FAIL=$((FAIL+1))
fi

# ── Test 5: targeted removal tolerates regenerable-only dirt ──────────────────
echo "Test 5: --worktree on merged worktree with only .claude/scratch removes it"
rc=0
( cd "$REPO" && AGE_HOURS=0 bash "$SCRIPT" --worktree "$WT/done-scratch" --force --no-branches ) >/dev/null 2>&1 || rc=$?
if [ ! -d "$WT/done-scratch" ] && [ "$rc" -eq 0 ]; then
    echo "  PASS: merged + scratch-only worktree removed via targeted mode"
    PASS=$((PASS+1))
else
    echo "  FAIL: targeted mode did not remove merged + scratch-only worktree (present=$([ -d "$WT/done-scratch" ] && echo y || echo n), rc=$rc)" >&2
    FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
