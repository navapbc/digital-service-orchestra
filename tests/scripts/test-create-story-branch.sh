#!/usr/bin/env bash
# tests/scripts/test-create-story-branch.sh
# Behavioral tests for plugins/dso/scripts/create-story-branch.sh
#
# Usage: bash tests/scripts/test-create-story-branch.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/create-story-branch.sh"

# shellcheck source=tests/lib/run_test.sh
source "$SCRIPT_DIR/../lib/run_test.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-create-story-branch.sh ==="

# ── Test 1: Script exists and is executable ──────────────────────────────────
echo "Test 1: Script exists at plugin location and is executable"
if [ -x "$SCRIPT" ]; then
    echo "  PASS: script is executable at $SCRIPT"
    (( PASS++ ))
else
    echo "  FAIL: script not found or not executable at $SCRIPT" >&2
    (( FAIL++ ))
fi

# Helper: initialize a scratch git repo with an initial commit.
# Sets SCRATCH_REPO (the repo path).
_make_scratch_repo() {
    local repo
    repo=$(mktemp -d)
    _CLEANUP_DIRS+=("$repo")
    git init -b main "$repo" >/dev/null 2>&1
    git -C "$repo" commit --allow-empty -m "init" >/dev/null 2>&1
    echo "$repo"
}

# ── Test 2: Given epic-id and story-id, exits 0 ─────────────────────────────
# Given: a git repo and valid epic-id + story-id arguments
# When:  create-story-branch.sh my-epic my-story is invoked
# Then:  the script exits 0
echo "Test 2: Given epic-id and story-id, exits 0"
SCRATCH=$(
    _make_scratch_repo
)
t2_exit=0
( cd "$SCRATCH" && bash "$SCRIPT" my-epic my-story >/dev/null 2>&1 ) || t2_exit=$?
if [ "$t2_exit" -eq 0 ]; then
    echo "  PASS: exits 0 with valid epic-id and story-id"
    (( PASS++ ))
else
    echo "  FAIL: expected exit 0, got $t2_exit" >&2
    (( FAIL++ ))
fi

# ── Test 3: Creates correct branch name in the repo ─────────────────────────
# Given: a fresh git repo
# When:  create-story-branch.sh my-epic my-story is invoked
# Then:  a branch named story/my-epic/my-story exists in the repo
echo "Test 3: Creates branch story/<epic>/<story> in the git repo"
SCRATCH3=$(
    _make_scratch_repo
)
( cd "$SCRATCH3" && bash "$SCRIPT" my-epic my-story >/dev/null 2>&1 ) || true
if git -C "$SCRATCH3" branch --list 'story/my-epic/my-story' | grep -q 'story/my-epic/my-story'; then
    echo "  PASS: branch story/my-epic/my-story exists"
    (( PASS++ ))
else
    echo "  FAIL: branch story/my-epic/my-story not found" >&2
    ( git -C "$SCRATCH3" branch --list ) >&2 || true
    (( FAIL++ ))
fi

# ── Test 4: stdout contains STORY_BRANCH=story/<epic>/<story> ───────────────
# Given: a fresh git repo and valid args
# When:  create-story-branch.sh my-epic my-story is invoked
# Then:  stdout includes the line STORY_BRANCH=story/my-epic/my-story
echo "Test 4: stdout contains STORY_BRANCH=story/my-epic/my-story"
SCRATCH4=$(
    _make_scratch_repo
)
t4_output=""
t4_output=$( cd "$SCRATCH4" && bash "$SCRIPT" my-epic my-story 2>/dev/null ) || true
if echo "$t4_output" | grep -qF "STORY_BRANCH=story/my-epic/my-story"; then
    echo "  PASS: stdout contains STORY_BRANCH=story/my-epic/my-story"
    (( PASS++ ))
else
    echo "  FAIL: stdout did not contain STORY_BRANCH=story/my-epic/my-story" >&2
    echo "  Actual output: $t4_output" >&2
    (( FAIL++ ))
fi

# ── Test 5: Idempotent — calling twice exits 0 both times ───────────────────
# Given: a fresh git repo
# When:  create-story-branch.sh is called twice with the same args
# Then:  both invocations exit 0 (second call does not fail on existing branch)
echo "Test 5: Idempotent — second call with same args exits 0"
SCRATCH5=$(
    _make_scratch_repo
)
t5_first=0
t5_second=0
( cd "$SCRATCH5" && bash "$SCRIPT" my-epic my-story >/dev/null 2>&1 ) || t5_first=$?
( cd "$SCRATCH5" && bash "$SCRIPT" my-epic my-story >/dev/null 2>&1 ) || t5_second=$?
if [ "$t5_first" -eq 0 ] && [ "$t5_second" -eq 0 ]; then
    echo "  PASS: both invocations exit 0"
    (( PASS++ ))
else
    echo "  FAIL: first exit=$t5_first second exit=$t5_second (expected 0 for both)" >&2
    (( FAIL++ ))
fi

# ── Test 6: Missing both args exits non-zero with usage output ──────────────
# Given: no arguments supplied
# When:  create-story-branch.sh is invoked with no args
# Then:  exits non-zero
echo "Test 6: No arguments exits non-zero"
SCRATCH6=$(
    _make_scratch_repo
)
t6_exit=0
( cd "$SCRATCH6" && bash "$SCRIPT" 2>/dev/null ) || t6_exit=$?
if [ "$t6_exit" -ne 0 ]; then
    echo "  PASS: exits non-zero with no arguments (exit $t6_exit)"
    (( PASS++ ))
else
    echo "  FAIL: expected non-zero exit with no arguments, got 0" >&2
    (( FAIL++ ))
fi

# ── Test 7: Missing story-id (only one arg) exits non-zero ──────────────────
# Given: only one argument (epic-id) is supplied
# When:  create-story-branch.sh my-epic is invoked
# Then:  exits non-zero
echo "Test 7: Only epic-id (missing story-id) exits non-zero"
SCRATCH7=$(
    _make_scratch_repo
)
t7_exit=0
( cd "$SCRATCH7" && bash "$SCRIPT" my-epic 2>/dev/null ) || t7_exit=$?
if [ "$t7_exit" -ne 0 ]; then
    echo "  PASS: exits non-zero with only epic-id supplied (exit $t7_exit)"
    (( PASS++ ))
else
    echo "  FAIL: expected non-zero exit with missing story-id, got 0" >&2
    (( FAIL++ ))
fi

# ── Print summary ─────────────────────────────────────────────────────────────
print_results
