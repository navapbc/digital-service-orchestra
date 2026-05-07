#!/usr/bin/env bash
# tests/scripts/test-worktree-create-from-ref.sh
# Tests for the --from=<ref> option in worktree-create.sh and the corresponding
# pass-through in claude-safe.
#
# Behaviors under test:
#   1. Default behavior — when --from is not specified, the new worktree is
#      based on origin/main (NOT the main repo's current HEAD). This is the
#      regression guard for the bug where a worktree created while the main
#      repo sat on a stale branch started 85 commits behind origin/main.
#   2. Custom --from — when --from=<ref> is supplied, the worktree is based
#      on that ref. Remote refs (`<remote>/<branch>`) trigger a fetch first.
#   3. claude-safe forwards --from — claude-safe parses --from out of its
#      own argv and passes it through to worktree-create.sh.
#
# Usage: bash tests/scripts/test-worktree-create-from-ref.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/worktree-create.sh"
CLAUDE_SAFE="$DSO_PLUGIN_DIR/scripts/claude-safe"

PASS=0
FAIL=0

_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d" 2>/dev/null || true; done; }
trap _cleanup EXIT

echo "=== test-worktree-create-from-ref.sh ==="

# ── Helper: build a smoke repo with a real `origin` remote ───────────────────
# Layout:
#   $TMP/origin.git      — bare repo acting as the remote
#   $TMP/main-repo       — working clone, will host the worktrees
#   $TMP/worktrees       — parent dir for created worktrees
#
# State after setup:
#   origin/main          — 2 commits (init, advance) — SHA: $ORIGIN_MAIN_SHA
#   origin/feature       — 1 commit on top of init   — SHA: $ORIGIN_FEATURE_SHA
#   main-repo HEAD       — 1 commit (init only)      — SHA: $LOCAL_HEAD_SHA
#                          (i.e. local main is STALE relative to origin/main)
_setup_smoke_repo() {
    TMP=$(mktemp -d)
    _CLEANUP_DIRS+=("$TMP")

    # Bare origin
    git init --bare -b main "$TMP/origin.git" &>/dev/null

    # Seed origin via a temporary working clone
    SEED="$TMP/seed"
    git clone -q "$TMP/origin.git" "$SEED" &>/dev/null
    git -C "$SEED" config user.email "test@example.com"
    git -C "$SEED" config user.name  "Test"
    git -C "$SEED" commit --allow-empty -m "init" &>/dev/null
    git -C "$SEED" push -q origin main &>/dev/null
    LOCAL_HEAD_SHA=$(git -C "$SEED" rev-parse HEAD)

    # Now consumer clones at the "init" point
    git clone -q "$TMP/origin.git" "$TMP/main-repo" &>/dev/null
    git -C "$TMP/main-repo" config user.email "test@example.com"
    git -C "$TMP/main-repo" config user.name  "Test"

    # Advance origin/main beyond what the consumer has fetched
    git -C "$SEED" commit --allow-empty -m "advance on main" &>/dev/null
    git -C "$SEED" push -q origin main &>/dev/null
    ORIGIN_MAIN_SHA=$(git -C "$SEED" rev-parse HEAD)

    # Create origin/feature off the init commit
    git -C "$SEED" checkout -q -b feature "$LOCAL_HEAD_SHA" &>/dev/null
    git -C "$SEED" commit --allow-empty -m "feature work" &>/dev/null
    git -C "$SEED" push -q origin feature &>/dev/null
    ORIGIN_FEATURE_SHA=$(git -C "$SEED" rev-parse HEAD)

    rm -rf "$SEED"

    mkdir -p "$TMP/worktrees"
    SMOKE_REPO="$TMP/main-repo"
    SMOKE_WORKTREES="$TMP/worktrees"
    export CLAUDE_PLUGIN_ROOT="$SMOKE_REPO"
}

# ── Test 1: --from accepted in argv parser (no unknown-option failure) ───────
echo "Test 1: --from is a recognized option"
help_out=$(bash "$SCRIPT" --help 2>&1)
if grep -q "\-\-from" <<<"$help_out"; then
    echo "  PASS: --from documented in --help"
    (( PASS++ ))
else
    echo "  FAIL: --from missing from --help output" >&2
    (( FAIL++ ))
fi

# ── Test 2: Default behavior — worktree is based on origin/main ──────────────
# Regression guard: with the main repo's HEAD at the stale "init" commit but
# origin/main advanced one commit ahead, a new worktree (with no --from arg)
# must land on origin/main's SHA, NOT the stale local HEAD.
echo "Test 2: default --from is origin/main (not local HEAD)"
_setup_smoke_repo
out=$(cd "$SMOKE_REPO" && bash "$SCRIPT" --name=wt-default --dir="$SMOKE_WORKTREES" 2>&1) || true
if [ -d "$SMOKE_WORKTREES/wt-default" ]; then
    actual_sha=$(git -C "$SMOKE_WORKTREES/wt-default" rev-parse HEAD)
    if [ "$actual_sha" = "$ORIGIN_MAIN_SHA" ]; then
        echo "  PASS: worktree HEAD == origin/main ($actual_sha)"
        (( PASS++ ))
    elif [ "$actual_sha" = "$LOCAL_HEAD_SHA" ]; then
        echo "  FAIL: worktree HEAD == stale local HEAD ($actual_sha); expected origin/main ($ORIGIN_MAIN_SHA)" >&2
        (( FAIL++ ))
    else
        echo "  FAIL: worktree HEAD ($actual_sha) matches neither origin/main ($ORIGIN_MAIN_SHA) nor local HEAD ($LOCAL_HEAD_SHA)" >&2
        (( FAIL++ ))
    fi
else
    echo "  FAIL: worktree directory not created" >&2
    echo "  Output: $out" >&2
    (( FAIL++ ))
fi

# ── Test 3: --from=origin/feature bases the worktree on that ref ─────────────
echo "Test 3: --from=origin/feature uses the feature ref"
_setup_smoke_repo
out=$(cd "$SMOKE_REPO" && bash "$SCRIPT" --name=wt-feature --dir="$SMOKE_WORKTREES" --from=origin/feature 2>&1) || true
if [ -d "$SMOKE_WORKTREES/wt-feature" ]; then
    actual_sha=$(git -C "$SMOKE_WORKTREES/wt-feature" rev-parse HEAD)
    if [ "$actual_sha" = "$ORIGIN_FEATURE_SHA" ]; then
        echo "  PASS: worktree HEAD == origin/feature ($actual_sha)"
        (( PASS++ ))
    else
        echo "  FAIL: worktree HEAD ($actual_sha) != origin/feature ($ORIGIN_FEATURE_SHA)" >&2
        (( FAIL++ ))
    fi
else
    echo "  FAIL: worktree directory not created" >&2
    echo "  Output: $out" >&2
    (( FAIL++ ))
fi

# ── Test 4: --skip-pull skips the fetch (no network access required) ─────────
# With --skip-pull, the script must not attempt `git fetch`. Verify by pointing
# the repo at a non-existent remote URL and confirming worktree creation still
# succeeds (it falls back to local HEAD because origin/main can't resolve).
echo "Test 4: --skip-pull bypasses fetch"
_setup_smoke_repo
git -C "$SMOKE_REPO" remote set-url origin "/nonexistent/origin.git"
out=$(cd "$SMOKE_REPO" && bash "$SCRIPT" --name=wt-skip --dir="$SMOKE_WORKTREES" --skip-pull 2>&1) || true
if [ -d "$SMOKE_WORKTREES/wt-skip" ]; then
    echo "  PASS: --skip-pull does not require a reachable remote"
    (( PASS++ ))
else
    echo "  FAIL: worktree not created with --skip-pull (output: $out)" >&2
    (( FAIL++ ))
fi

# ── Test 5: claude-safe parses --from in its argv ────────────────────────────
# Static check: claude-safe must extract --from= from "$@" before calling
# worktree-create.sh, and must invoke worktree-create.sh with --from=.
echo "Test 5: claude-safe parses --from and forwards it"
# shellcheck disable=SC2016  # patterns are intentionally literal — we are grepping source text, not expanding
if grep -q -- '--from=\*' "$CLAUDE_SAFE" && \
   grep -q -- '--from="$FROM_REF"' "$CLAUDE_SAFE"; then
    echo "  PASS: claude-safe parses --from and forwards to worktree-create.sh"
    (( PASS++ ))
else
    echo "  FAIL: claude-safe missing --from parsing or forwarding" >&2
    (( FAIL++ ))
fi

# ── Test 6: claude-safe defaults FROM_REF to origin/main ─────────────────────
echo "Test 6: claude-safe defaults --from to origin/main"
if grep -qE 'FROM_REF="origin/main"' "$CLAUDE_SAFE"; then
    echo "  PASS: claude-safe defaults FROM_REF=origin/main"
    (( PASS++ ))
else
    echo "  FAIL: claude-safe does not default FROM_REF to origin/main" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
