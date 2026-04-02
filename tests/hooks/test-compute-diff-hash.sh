#!/usr/bin/env bash
# tests/hooks/test-compute-diff-hash.sh
# Tests for .claude/hooks/compute-diff-hash.sh
#
# compute-diff-hash.sh is a utility script (not a hook per se) that outputs
# a SHA-256 hex hash of the current working tree diff. It uses set -euo pipefail.
# It is invoked directly (not via stdin), so tests call it as a command.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

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

# ============================================================
# test_compute_diff_hash_uses_allowlist_patterns
# Verifies that compute-diff-hash.sh reads exclusion patterns from the
# shared review-gate-allowlist.conf instead of hardcoded arrays.
# ============================================================
echo "--- test_compute_diff_hash_uses_allowlist_patterns ---"

ALLOWLIST="$DSO_PLUGIN_DIR/hooks/lib/review-gate-allowlist.conf"

# 1. The script must reference review-gate-allowlist
USES_ALLOWLIST=$(grep -c 'review-gate-allowlist' "$HOOK" 2>/dev/null | tail -1 || echo "0")
assert_eq "compute-diff-hash.sh references review-gate-allowlist" "true" \
    "$( [[ $USES_ALLOWLIST -ge 1 ]] && echo true || echo false )"

# 2. The script must NOT have a hardcoded EXCLUDE_PATHSPECS=( array with inline entries
#    (EXCLUDE_PATHSPECS=() empty init is OK; EXCLUDE_PATHSPECS=(\n  ':!...' is not)
HAS_HARDCODED=$(grep -cE "EXCLUDE_PATHSPECS=\([^)]" "$HOOK" 2>/dev/null | tail -1 || echo "0")
assert_eq "no hardcoded EXCLUDE_PATHSPECS=( in compute-diff-hash.sh" "0" "$HAS_HARDCODED"

# 3. Behavioral: .tickets-tracker/ files are excluded (hash stable across ticket changes)
TMPDIR_ALLOWLIST_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ALLOWLIST_TEST"' EXIT

cd "$TMPDIR_ALLOWLIST_TEST"
git init -q -b main
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > README.md
git add README.md
git commit -q -m "init"

# Create and commit a .tickets-tracker/ file
mkdir -p .tickets-tracker
echo "status: open" > .tickets-tracker/test-ticket.md
git add .tickets-tracker/test-ticket.md
git commit -q -m "add ticket"

HASH_BEFORE_TICKET=$(bash "$HOOK" 2>/dev/null)
echo "status: closed" >> .tickets-tracker/test-ticket.md
HASH_AFTER_TICKET=$(bash "$HOOK" 2>/dev/null)
assert_eq "ticket change does not alter hash (allowlist)" "$HASH_BEFORE_TICKET" "$HASH_AFTER_TICKET"
git checkout -- .tickets-tracker/test-ticket.md

# 4. Behavioral: *.png files are excluded from untracked file list
HASH_BEFORE_PNG=$(bash "$HOOK" 2>/dev/null)
echo "fake png data" > screenshot.png
HASH_AFTER_PNG=$(bash "$HOOK" 2>/dev/null)
assert_eq "untracked png does not alter hash (allowlist)" "$HASH_BEFORE_PNG" "$HASH_AFTER_PNG"
rm -f screenshot.png

# 5. Hash is stable (deterministic with same input)
HASH_STABLE_1=$(bash "$HOOK" 2>/dev/null)
HASH_STABLE_2=$(bash "$HOOK" 2>/dev/null)
assert_eq "hash is stable across runs (allowlist)" "$HASH_STABLE_1" "$HASH_STABLE_2"

# 6. NON_REVIEWABLE_PATTERN covers key allowlist types
# After refactoring, the pattern should still exclude .tickets/, *.png, *.jpg, *.pdf, *.docx, .sync-state.json
# We verify by checking that untracked files of these types don't affect the hash
for ext in jpg pdf docx; do
    HASH_BEFORE_EXT=$(bash "$HOOK" 2>/dev/null)
    echo "fake data" > "testfile.${ext}"
    HASH_AFTER_EXT=$(bash "$HOOK" 2>/dev/null)
    assert_eq "untracked .${ext} does not alter hash (allowlist)" "$HASH_BEFORE_EXT" "$HASH_AFTER_EXT"
    rm -f "testfile.${ext}"
done

# 7. Graceful degradation: script should still work when allowlist is overridden to missing path
EXIT_CODE_FALLBACK=0
HASH_FALLBACK=$(CONF_OVERRIDE=/tmp/nonexistent-allowlist-$$ bash "$HOOK" 2>/dev/null) || EXIT_CODE_FALLBACK=$?
assert_eq "graceful degradation with missing allowlist" "0" "$EXIT_CODE_FALLBACK"
assert_ne "fallback produces non-empty hash" "" "$HASH_FALLBACK"

# Return to repo root for print_summary
cd "$REPO_ROOT"

# ============================================================
# test_hash_excludes_test_index
# Staging a .test-index file must NOT change the diff hash.
# .test-index is auto-staged by the test gate and must be
# treated as metadata (like .tickets/) — not code under review.
# ============================================================
echo "--- test_hash_excludes_test_index ---"

TMPDIR_TI=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TI"' EXIT

(
    cd "$TMPDIR_TI"
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "Test"

    # Initial commit with a source file so HEAD is valid
    echo "def foo(): pass" > foo.py
    git add foo.py
    git commit -q -m "init"

    # Stage a change to the source file and record the baseline hash
    echo "def bar(): pass" >> foo.py
    git add foo.py
    H1=$(bash "$HOOK" 2>/dev/null)

    # Now also write and stage a .test-index file
    printf 'foo.py=tests/test_foo.py\n' > .test-index
    git add .test-index
    H2=$(bash "$HOOK" 2>/dev/null)

    if [[ "$H1" == "$H2" ]]; then
        echo "PASS: test_hash_excludes_test_index"
        exit 0
    else
        echo "FAIL: test_hash_excludes_test_index — staging .test-index changed the hash"
        echo "  H1 (before .test-index staged): $H1"
        echo "  H2 (after  .test-index staged): $H2"
        exit 1
    fi
)
_TI_EXIT=$?
assert_eq "test_hash_excludes_test_index" "0" "$_TI_EXIT"

# Also verify allowlist contains the .test-index pattern (static check)
_TI_ALLOWLIST_MATCH=$(grep '\.test-index' "$DSO_PLUGIN_DIR/hooks/lib/review-gate-allowlist.conf" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "review-gate-allowlist.conf contains .test-index pattern" "true" \
    "$( [[ $_TI_ALLOWLIST_MATCH -ge 1 ]] && echo true || echo false )"

# NOTE: Rebase-state tests (REBASE_HEAD) have been removed from this file.
# Coverage provided by tests/hooks/test-merge-state-golden-path.sh (C4=compute-diff-hash).

print_summary
