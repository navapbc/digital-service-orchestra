#!/usr/bin/env bash
# tests/hooks/test-compute-diff-hash-autostash-invariance.sh
# Tests for 00a5-548f: hash must be invariant to pre-commit auto-stash.
#
# When pre-commit auto-stashes unstaged tracked changes before running hooks,
# compute-diff-hash.sh must produce the same hash it produced at record time.
#
# Usage: bash tests/hooks/test-compute-diff-hash-autostash-invariance.sh
# Exit code: 0 if all pass, non-zero if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
HOOK="$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh"
REAL_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Skip if not inside a git work tree
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "SKIP: not inside a git work tree"
    exit 0
fi

# Work in a temp directory that is a fresh git repo
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

cd "$TMPDIR_TEST" || exit 1
git init -q -b main
git config user.email "test@test.com"
git config user.name "Test"

# Create two tracked files
echo "# main" > main.py
echo "# util" > util.py
git add main.py util.py
git commit -q -m "init"

# ============================================================
# Test: hash is stable when unstaged tracked changes are stashed
# (simulating pre-commit auto-stash behavior)
# ============================================================
echo "--- test_autostash_invariance: hash must not change when unstaged tracked changes are stashed ---"

# Stage a change to main.py (this will be committed)
echo "def hello(): pass" >> main.py
git add main.py

# Also make an UNSTAGED change to util.py (this will be auto-stashed by pre-commit)
echo "# unstaged modification" >> util.py

# Record the hash WITH the unstaged change present (as record-test-status does)
HASH_BEFORE_STASH=$(bash "$HOOK" 2>/dev/null)
assert_ne "hash before stash is non-empty" "" "$HASH_BEFORE_STASH"

# Simulate pre-commit auto-stash: stash unstaged changes while keeping index
git stash push --keep-index -q -m "pre-commit-autostash-test" 2>/dev/null

# Record the hash AFTER auto-stash (as pre-commit-test-gate does)
HASH_AFTER_STASH=$(bash "$HOOK" 2>/dev/null)
assert_ne "hash after stash is non-empty" "" "$HASH_AFTER_STASH"

# Restore the stash
git stash pop -q 2>/dev/null

assert_eq "hash is invariant to auto-stash of unstaged tracked changes (00a5-548f)" \
    "$HASH_BEFORE_STASH" "$HASH_AFTER_STASH"

# Return to real repo root for print_summary
[[ -n "$REAL_REPO_ROOT" ]] && { cd "$REAL_REPO_ROOT" || exit 1; }

print_summary
