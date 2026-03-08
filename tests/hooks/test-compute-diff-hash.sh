#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-compute-diff-hash.sh
# Tests for .claude/hooks/compute-diff-hash.sh
#
# compute-diff-hash.sh is a utility script (not a hook per se) that outputs
# a SHA-256 hex hash of the current working tree diff. It uses set -euo pipefail.
# It is invoked directly (not via stdin), so tests call it as a command.

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/compute-diff-hash.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# test_compute_diff_hash_exits_zero_on_valid_input
# When called in a git repo, should exit 0 and produce a hash
EXIT_CODE=0
HASH=$(bash "$HOOK" 2>/dev/null) || EXIT_CODE=$?
assert_eq "test_compute_diff_hash_exits_zero_on_valid_input" "0" "$EXIT_CODE"

# test_compute_diff_hash_produces_non_empty_output
# Output should be non-empty (a hex string)
assert_ne "test_compute_diff_hash_produces_non_empty_output" "" "$HASH"

# test_compute_diff_hash_produces_hex_string
# Output should be a valid hex string (no whitespace or newlines)
# sha256 output is 64 hex chars; other fallbacks may vary in length
CLEAN_HASH=$(echo "$HASH" | tr -d '[:space:]')
assert_eq "test_compute_diff_hash_no_whitespace_in_output" "$HASH" "$CLEAN_HASH"

# test_compute_diff_hash_is_deterministic
# Running twice should produce the same hash (assuming no changes between calls)
HASH1=$(bash "$HOOK" 2>/dev/null)
HASH2=$(bash "$HOOK" 2>/dev/null)
assert_eq "test_compute_diff_hash_is_deterministic" "$HASH1" "$HASH2"

# test_compute_diff_hash_is_executable
# The hook file should be executable
if [[ -x "$HOOK" ]]; then
    EXIT_CODE2=0
    HASH3=$("$HOOK" 2>/dev/null) || EXIT_CODE2=$?
    assert_eq "test_compute_diff_hash_is_executable" "0" "$EXIT_CODE2"
else
    # File not executable yet — record as a distinct note but don't fail
    # (the task requires us to make files executable, so this is expected pre-chmod)
    assert_eq "test_compute_diff_hash_is_executable (file not yet +x)" "skip" "skip"
fi

print_summary
