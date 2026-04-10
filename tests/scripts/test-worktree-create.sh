#!/usr/bin/env bash
# tests/scripts/test-worktree-create.sh
# Tests for scripts/worktree-create.sh (plugin location)
#
# Usage: bash tests/scripts/test-worktree-create.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/worktree-create.sh"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-worktree-create.sh ==="

# ── Test 1: Script exists at plugin location ─────────────────────────────────
echo "Test 1: Script exists at plugin location"
if [ -x "$SCRIPT" ]; then
    echo "  PASS: script is executable at scripts/"
    (( PASS++ ))
else
    echo "  FAIL: script not found or not executable at scripts/" >&2
    (( FAIL++ ))
fi

# ── Test 2: No bash syntax errors ────────────────────────────────────────────
echo "Test 2: No bash syntax errors"
if bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors"
    (( PASS++ ))
else
    echo "  FAIL: syntax errors found" >&2
    (( FAIL++ ))
fi

# ── Test 3: --help exits 0 with usage text ───────────────────────────────────
echo "Test 3: --help exits 0 with usage text"
run_test "--help exits 0 and prints usage" 0 "[Uu]sage|[Oo]ption|--name" bash "$SCRIPT" --help

# ── Test 4: Unknown option exits non-zero ────────────────────────────────────
echo "Test 4: Unknown option exits non-zero"
run_test "unknown option exits 1" 1 "" bash "$SCRIPT" --unknown-flag-xyz

# ── Test 5: Script requires git repo (exits non-zero outside git) ────────────
echo "Test 5: Script exits non-zero when not in a git repo"
exit_code=0
TMP_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$TMP_DIR")
( cd "$TMP_DIR" && bash "$SCRIPT" 2>/dev/null ) || exit_code=$?
rmdir "$TMP_DIR" 2>/dev/null || true
if [ "$exit_code" -ne 0 ]; then
    echo "  PASS: exits non-zero outside git repo (exit $exit_code)"
    (( PASS++ ))
else
    echo "  FAIL: expected non-zero exit outside git repo" >&2
    (( FAIL++ ))
fi

# ── Test 6: Script supports --name= option ──────────────────────────────────
echo "Test 6: Script supports --name= option"
if grep -q "\-\-name" "$SCRIPT"; then
    echo "  PASS: script supports --name= option"
    (( PASS++ ))
else
    echo "  FAIL: script does not support --name= option" >&2
    (( FAIL++ ))
fi

# ── Test 7: Script supports --validation= option ────────────────────────────
echo "Test 7: Script supports --validation= option"
if grep -q "\-\-validation" "$SCRIPT"; then
    echo "  PASS: script supports --validation= option"
    (( PASS++ ))
else
    echo "  FAIL: script does not support --validation= option" >&2
    (( FAIL++ ))
fi

# ── Test 8: Config-driven post_create_cmd lookup ─────────────────────────────
echo "Test 8: Script uses config-driven post_create_cmd"
if grep -qE "post_create_cmd|read-config" "$SCRIPT"; then
    echo "  PASS: script references post_create_cmd or read-config"
    (( PASS++ ))
else
    echo "  FAIL: script missing post_create_cmd / read-config lookup" >&2
    (( FAIL++ ))
fi

# ── Test 9: Repo-name-derived worktree directory default ─────────────────────
echo "Test 9: Script derives worktree directory from repo name"
if grep -qE 'basename.*repo|repo.*name|worktree.*dir.*base' "$SCRIPT"; then
    echo "  PASS: script derives worktree directory from repo name"
    (( PASS++ ))
else
    echo "  FAIL: script missing repo-name-derived worktree directory logic" >&2
    (( FAIL++ ))
fi

# ── Test 10: Session artifact_prefix config lookup ───────────────────────────
echo "Test 10: Script looks up session.artifact_prefix config"
if grep -q "artifact_prefix" "$SCRIPT"; then
    echo "  PASS: script references artifact_prefix"
    (( PASS++ ))
else
    echo "  FAIL: script missing artifact_prefix config lookup" >&2
    (( FAIL++ ))
fi

# ── Portability smoke-test helper ─────────────────────────────────────────────
# Creates a real temp git repo for smoke tests. Sets SMOKE_REPO and SMOKE_WORKTREES.
# Caller must call _smoke_cleanup after each test.
_smoke_setup() {
    SMOKE_REPO=$(mktemp -d)
    _CLEANUP_DIRS+=("$SMOKE_REPO")
    SMOKE_WORKTREES=$(mktemp -d)
    _CLEANUP_DIRS+=("$SMOKE_WORKTREES")
    git init -b main "$SMOKE_REPO" &>/dev/null
    # Create an initial commit so worktree creation works
    git -C "$SMOKE_REPO" commit --allow-empty -m "init" &>/dev/null
    # Export CLAUDE_PLUGIN_ROOT so subshells in isolated temp repos can resolve
    # hooks/lib and scripts paths (the variable is required by worktree-create.sh
    # under set -u).  Point at the smoke repo so read-config.sh finds the
    # dso-config.conf copied there by individual tests.
    export CLAUDE_PLUGIN_ROOT="$SMOKE_REPO"
}

_smoke_cleanup() {
    # Remove worktrees first (git worktree remove requires the main repo)
    if [ -d "$SMOKE_REPO" ]; then
        git -C "$SMOKE_REPO" worktree list 2>/dev/null | while read -r wt_line; do
            wt_path=$(echo "$wt_line" | awk '{print $1}')
            if [ "$wt_path" != "$SMOKE_REPO" ]; then
                git -C "$SMOKE_REPO" worktree remove --force "$wt_path" 2>/dev/null || true
            fi
        done
    fi
    rm -rf "$SMOKE_REPO" "$SMOKE_WORKTREES" 2>/dev/null || true
}

# ── Test 11: Portability skip-path — no post_create_cmd exits 0 ──────────────
echo "Test 11: Portability skip-path — no post_create_cmd config exits 0"
_smoke_setup
# No dso-config.conf → post_create_cmd is empty → should skip gracefully
smoke_exit=0
smoke_output=""
smoke_output=$(cd "$SMOKE_REPO" && bash "$SCRIPT" --name=smoke-skip --dir="$SMOKE_WORKTREES" --skip-pull 2>&1) || smoke_exit=$?
if [ "$smoke_exit" -eq 0 ]; then
    # Also verify no error about missing hook in output
    if [[ "${smoke_output,,}" =~ hook.*not\ found|post_create.*error ]]; then
        echo "  FAIL: portability skip-path — exit 0 but error about missing hook in output" >&2
        (( FAIL++ ))
    else
        echo "  PASS: portability skip-path — exits 0 with no hook error"
        (( PASS++ ))
    fi
else
    echo "  FAIL: portability skip-path — expected exit 0, got $smoke_exit" >&2
    echo "  Output: $smoke_output" >&2
    (( FAIL++ ))
fi
_smoke_cleanup

# ── Test 12: Portability hook-path — post_create_cmd runs and side effects visible ──
echo "Test 12: Portability hook-path — post_create_cmd creates marker file"
_smoke_setup
# Write dso-config.conf with a post_create_cmd that creates a marker file
mkdir -p "$SMOKE_REPO/scripts"
mkdir -p "$SMOKE_REPO/.claude"
# Copy read-config.sh so the script can find it in the temp repo
cp "$DSO_PLUGIN_DIR/scripts/read-config.sh" "$SMOKE_REPO/scripts/read-config.sh"
cat > "$SMOKE_REPO/.claude/dso-config.conf" <<'CONF'
worktree.post_create_cmd=touch $WORKTREE_PATH/.setup-marker
CONF
smoke_exit=0
smoke_output=""
smoke_output=$(cd "$SMOKE_REPO" && bash "$SCRIPT" --name=smoke-hook --dir="$SMOKE_WORKTREES" --skip-pull 2>&1) || smoke_exit=$?
if [ "$smoke_exit" -eq 0 ] && [ -f "$SMOKE_WORKTREES/smoke-hook/.setup-marker" ]; then
    echo "  PASS: portability hook-path — marker file created by post_create_cmd"
    (( PASS++ ))
elif [ "$smoke_exit" -ne 0 ]; then
    echo "  FAIL: portability hook-path — expected exit 0, got $smoke_exit" >&2
    echo "  Output: $smoke_output" >&2
    (( FAIL++ ))
else
    echo "  FAIL: portability hook-path — marker file not found at $SMOKE_WORKTREES/smoke-hook/.setup-marker" >&2
    echo "  Output: $smoke_output" >&2
    (( FAIL++ ))
fi
_smoke_cleanup

# ── Test 13: Portability hook-failure — failing post_create_cmd causes non-zero exit ──
echo "Test 13: Portability hook-failure — failing post_create_cmd exits non-zero"
_smoke_setup
mkdir -p "$SMOKE_REPO/scripts"
mkdir -p "$SMOKE_REPO/.claude"
cp "$DSO_PLUGIN_DIR/scripts/read-config.sh" "$SMOKE_REPO/scripts/read-config.sh"
cat > "$SMOKE_REPO/.claude/dso-config.conf" <<'CONF'
worktree.post_create_cmd=false
CONF
smoke_exit=0
smoke_output=""
smoke_output=$(cd "$SMOKE_REPO" && bash "$SCRIPT" --name=smoke-fail --dir="$SMOKE_WORKTREES" --skip-pull 2>&1) || smoke_exit=$?
if [ "$smoke_exit" -ne 0 ]; then
    echo "  PASS: portability hook-failure — exits non-zero ($smoke_exit) when post_create_cmd fails"
    (( PASS++ ))
else
    echo "  FAIL: portability hook-failure — expected non-zero exit, got 0" >&2
    echo "  Output: $smoke_output" >&2
    (( FAIL++ ))
fi
_smoke_cleanup

# ── Test 14: CWD of post_create_cmd is WORKTREE_PATH, not REPO_ROOT ──────────
# Bug e1b6-a78c: worktree-create.sh ran the hook from cd "$REPO_ROOT"; it must
# run from cd "$WORKTREE_PATH" so CWD-sensitive commands (e.g. npm install) act
# on the newly-created worktree.
echo "Test 14: post_create_cmd CWD is WORKTREE_PATH not REPO_ROOT"
_smoke_setup
mkdir -p "$SMOKE_REPO/scripts"
mkdir -p "$SMOKE_REPO/.claude"
cp "$DSO_PLUGIN_DIR/scripts/read-config.sh" "$SMOKE_REPO/scripts/read-config.sh"
# Command writes its actual CWD to a known temp file (no $WORKTREE_PATH prefix).
CWD_CAPTURE_FILE=$(mktemp)
_CLEANUP_DIRS+=("$CWD_CAPTURE_FILE")
cat > "$SMOKE_REPO/.claude/dso-config.conf" <<CONF
worktree.post_create_cmd=pwd > $CWD_CAPTURE_FILE
CONF
smoke_exit=0
smoke_output=""
smoke_output=$(cd "$SMOKE_REPO" && bash "$SCRIPT" --name=smoke-cwd --dir="$SMOKE_WORKTREES" --skip-pull 2>&1) || smoke_exit=$?
EXPECTED_WORKTREE="$SMOKE_WORKTREES/smoke-cwd"
ACTUAL_CWD=$(cat "$CWD_CAPTURE_FILE" 2>/dev/null | tr -d '\n')
if [ "$smoke_exit" -eq 0 ] && [ "$ACTUAL_CWD" = "$EXPECTED_WORKTREE" ]; then
    echo "  PASS: post_create_cmd CWD is WORKTREE_PATH ($ACTUAL_CWD)"
    (( PASS++ ))
elif [ "$smoke_exit" -ne 0 ]; then
    echo "  FAIL: worktree creation failed (exit $smoke_exit)" >&2
    echo "  Output: $smoke_output" >&2
    (( FAIL++ ))
else
    echo "  FAIL: post_create_cmd ran in '$ACTUAL_CWD' (expected '$EXPECTED_WORKTREE')" >&2
    (( FAIL++ ))
fi
_smoke_cleanup

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
