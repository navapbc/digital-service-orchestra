#!/usr/bin/env bash
# tests/plugin/test-verify-review-diff.sh
# Tests for verify-review-diff.sh — validates review diff hash verification.
#
# Manual run:
#   bash tests/plugin/test-verify-review-diff.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
VERIFY_SCRIPT="$DSO_PLUGIN_DIR/scripts/verify-review-diff.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== verify-review-diff.sh tests ==="
echo ""

# ---------------------------------------------------------------------------
# Prerequisite: script exists and is executable
# ---------------------------------------------------------------------------
echo "--- prerequisite: script exists and is executable ---"

assert_eq "verify-review-diff.sh exists" "true" \
    "$(test -f "$VERIFY_SCRIPT" && echo true || echo false)"

assert_eq "verify-review-diff.sh is executable" "true" \
    "$(test -x "$VERIFY_SCRIPT" && echo true || echo false)"

# ---------------------------------------------------------------------------
# Test A: No arguments — should print usage and exit 1
# ---------------------------------------------------------------------------
echo ""
echo "--- Test A: no arguments prints usage and exits 1 ---"

exit_a=0
output_a=$(bash "$VERIFY_SCRIPT" 2>&1) || exit_a=$?
assert_eq "no-args exits non-zero" "1" "$exit_a"
assert_contains "no-args prints usage" "Usage:" "$output_a"

# ---------------------------------------------------------------------------
# Test B: Non-existent file — should report file not found
# ---------------------------------------------------------------------------
echo ""
echo "--- Test B: non-existent file ---"

exit_b=0
output_b=$(bash "$VERIFY_SCRIPT" "/tmp/nonexistent-review-diff-abc12345.txt" 2>&1) || exit_b=$?
assert_eq "missing-file exits non-zero" "1" "$exit_b"
assert_contains "missing-file reports not found" "DIFF_VALID: no" "$output_b"
assert_contains "missing-file mentions file not found" "file not found" "$output_b"

# ---------------------------------------------------------------------------
# Test C: Empty file — should report file is empty
# ---------------------------------------------------------------------------
echo ""
echo "--- Test C: empty file ---"

TMPDIR_C=$(mktemp -d)
trap 'rm -rf "$TMPDIR_C"' EXIT
EMPTY_FILE="$TMPDIR_C/review-diff-abc12345.txt"
touch "$EMPTY_FILE"

exit_c=0
output_c=$(bash "$VERIFY_SCRIPT" "$EMPTY_FILE" 2>&1) || exit_c=$?
assert_eq "empty-file exits non-zero" "1" "$exit_c"
assert_contains "empty-file reports empty" "file is empty" "$output_c"

# ---------------------------------------------------------------------------
# Test D: Filename without hash pattern — should report cannot extract hash
# ---------------------------------------------------------------------------
echo ""
echo "--- Test D: filename without hash pattern ---"

NO_HASH_FILE="$TMPDIR_C/review-diff-nohash.txt"
echo "some content" > "$NO_HASH_FILE"

exit_d=0
output_d=$(bash "$VERIFY_SCRIPT" "$NO_HASH_FILE" 2>&1) || exit_d=$?
assert_eq "no-hash exits non-zero" "1" "$exit_d"
assert_contains "no-hash reports cannot extract" "could not extract hash" "$output_d"

# ---------------------------------------------------------------------------
# Test E: Filename ending in .patch — should extract hash correctly
# Bug dso-3v94: sed regex used \.txt$ and rejected .patch filenames,
# producing "could not extract hash from filename" errors.
# ---------------------------------------------------------------------------
echo ""
echo "--- Test E: .patch extension — hash extracted correctly ---"

PATCH_FILE="$TMPDIR_C/review-diff-ab12cd34.patch"
echo "some diff content" > "$PATCH_FILE"

exit_e=0
output_e=$(bash "$VERIFY_SCRIPT" "$PATCH_FILE" 2>&1) || exit_e=$?
# The script will fail because the hash won't match, but the key assertion
# is that it does NOT report "could not extract hash" — it gets past that step.
assert_ne "patch-file does NOT report could-not-extract-hash" \
    "true" \
    "$({ _tmp="$output_e"; [[ "$_tmp" =~ could\ not\ extract\ hash ]] && echo true || echo false; })"

# ---------------------------------------------------------------------------
# Test F: CLAUDE_PLUGIN_ROOT unset — should resolve compute-diff-hash.sh via git
# Bug dso-6ea2-fix1: script used ${CLAUDE_PLUGIN_ROOT}/hooks/compute-diff-hash.sh
# with no fallback, causing failures when CLAUDE_PLUGIN_ROOT is unset in worktrees.
# We verify the script does not abort with "unbound variable" when the var is unset.
# ---------------------------------------------------------------------------
echo ""
echo "--- Test F: CLAUDE_PLUGIN_ROOT unset — no unbound variable error ---"

PATCH_HASH_FILE="$TMPDIR_C/review-diff-ab12cd34.patch"
echo "some diff content" > "$PATCH_HASH_FILE"

exit_f=0
output_f=$(env -u CLAUDE_PLUGIN_ROOT bash "$VERIFY_SCRIPT" "$PATCH_HASH_FILE" 2>&1) || exit_f=$?
# Should NOT exit with "unbound variable" (exit 1 due to hash mismatch is OK)
assert_ne "unset-CLAUDE_PLUGIN_ROOT: no unbound-variable error" \
    "true" \
    "$({ _tmp="$output_f"; [[ "$_tmp" =~ unbound\ variable|CLAUDE_PLUGIN_ROOT ]] && echo true || echo false; })"

# ---------------------------------------------------------------------------
# Test G: Full 64-char hash in filename matches current working tree
# Bug ee54-1eeb: file_hash was compared directly to current_hash_short (8 chars),
# so full 64-char hash filenames always produced DIFF_VALID: no.
# ---------------------------------------------------------------------------
echo ""
echo "--- Test G: full 64-char hash filename matches current working tree ---"

# Get the real current hash so the comparison can succeed
CURRENT_HASH=$(CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" bash "$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh" 2>/dev/null || true)
if [ -n "$CURRENT_HASH" ] && [ ${#CURRENT_HASH} -ge 8 ]; then
    FULL_HASH_FILE="$TMPDIR_C/review-diff-${CURRENT_HASH}.txt"
    # Write a non-empty file (content doesn't matter — only the filename hash is checked)
    echo "placeholder diff content" > "$FULL_HASH_FILE"
    exit_g=0
    output_g=$(CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" bash "$VERIFY_SCRIPT" "$FULL_HASH_FILE" 2>&1) || exit_g=$?
    assert_eq "full-hash filename: exits 0" "0" "$exit_g"
    assert_contains "full-hash filename: reports DIFF_VALID yes" "DIFF_VALID: yes" "$output_g"
else
    echo "SKIP: could not compute current hash (not in a git repo)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary
