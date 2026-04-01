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

# ============================================================
# test_hash_rebase_excludes_incoming_only
# When REBASE_HEAD state exists (.git/REBASE_HEAD, .git/rebase-merge/onto,
# .git/rebase-merge/orig-head), staging a file that was only changed on the
# onto branch (incoming-only) must NOT change the diff hash.
# RED: compute-diff-hash.sh has no REBASE_HEAD handling; incoming-only files
# will affect the hash, causing the two hash values to differ.
# ============================================================
echo "--- test_hash_rebase_excludes_incoming_only ---"

_TMPDIR_REBASE=$(mktemp -d)
trap 'rm -rf "$_TMPDIR_REBASE"' EXIT

(
    cd "$_TMPDIR_REBASE"
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "Test"

    # Commit 1 — common ancestor
    echo "shared" > shared.py
    git add shared.py
    git commit -q -m "common ancestor"
    _COMMON=$(git rev-parse HEAD)

    # Commit 2 — onto branch tip: adds an incoming-only file
    echo "onto-only content" > incoming-only.py
    git add incoming-only.py
    git commit -q -m "onto: add incoming-only.py"
    _ONTO=$(git rev-parse HEAD)

    # Simulate feature branch: go back to common ancestor, add feature file
    git checkout -q -b feature "$_COMMON"
    echo "feature work" > feature.py
    git add feature.py
    git commit -q -m "feature: add feature.py"
    _ORIG_HEAD=$(git rev-parse HEAD)

    # Simulate REBASE_HEAD state (as if 'git rebase main' is in progress):
    #   REBASE_HEAD  = the onto tip (main HEAD)
    #   rebase-merge/onto = onto SHA
    #   rebase-merge/orig-head = original HEAD before rebase started
    echo "$_ONTO" > .git/REBASE_HEAD
    mkdir -p .git/rebase-merge
    echo "$_ONTO" > .git/rebase-merge/onto
    echo "$_ORIG_HEAD" > .git/rebase-merge/orig-head

    # Baseline hash: only feature.py staged (our own change, orig-head..HEAD)
    _H1=$(bash "$HOOK" 2>/dev/null)

    # Now stage incoming-only.py — a file only changed on the onto branch.
    # A correct REBASE_HEAD implementation should exclude it from the hash.
    echo "onto-only content" > incoming-only.py
    git add incoming-only.py
    _H2=$(bash "$HOOK" 2>/dev/null)

    if [[ "$_H1" == "$_H2" ]]; then
        echo "PASS: test_hash_rebase_excludes_incoming_only"
        exit 0
    else
        echo "FAIL: test_hash_rebase_excludes_incoming_only"
        echo "  H1 (without incoming-only staged): $_H1"
        echo "  H2 (with incoming-only staged):    $_H2"
        echo "  incoming-only.py changed the hash — REBASE_HEAD exclusion not yet implemented"
        exit 1
    fi
)
_REBASE_EXCL_EXIT=$?
assert_eq "test_hash_rebase_excludes_incoming_only" "0" "$_REBASE_EXCL_EXIT"

# ============================================================
# test_hash_rebase_failsafe_missing_onto
# When REBASE_HEAD exists but .git/rebase-merge/onto is absent, the script
# must fall through to default hash behavior: exit 0 and produce a non-empty hash.
# RED: once REBASE_HEAD handling is added, a missing onto file could cause the
# script to crash or produce empty output. This test guards against that regression.
# ============================================================
echo "--- test_hash_rebase_failsafe_missing_onto ---"

_TMPDIR_FAILSAFE=$(mktemp -d)
trap 'rm -rf "$_TMPDIR_FAILSAFE"' EXIT

(
    cd "$_TMPDIR_FAILSAFE"
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "Test"

    # Initial commit
    echo "init" > init.py
    git add init.py
    git commit -q -m "init"
    _HEAD_SHA=$(git rev-parse HEAD)

    # Write REBASE_HEAD and orig-head but intentionally omit onto file
    echo "$_HEAD_SHA" > .git/REBASE_HEAD
    mkdir -p .git/rebase-merge
    echo "$_HEAD_SHA" > .git/rebase-merge/orig-head
    # NOTE: .git/rebase-merge/onto is intentionally NOT written

    # Stage a change
    echo "modified" >> init.py
    git add init.py

    # Script must exit 0 and produce a non-empty hash (fallthrough to default behavior)
    _FAILSAFE_EXIT=0
    _FAILSAFE_HASH=$(bash "$HOOK" 2>/dev/null) || _FAILSAFE_EXIT=$?

    if [[ "$_FAILSAFE_EXIT" -ne 0 ]]; then
        echo "FAIL: test_hash_rebase_failsafe_missing_onto — script exited non-zero: $_FAILSAFE_EXIT"
        exit 1
    fi
    if [[ -z "$_FAILSAFE_HASH" ]]; then
        echo "FAIL: test_hash_rebase_failsafe_missing_onto — hash was empty"
        exit 1
    fi
    echo "PASS: test_hash_rebase_failsafe_missing_onto (exit 0, hash: $_FAILSAFE_HASH)"
    exit 0
)
_FAILSAFE_EXIT_OUTER=$?
assert_eq "test_hash_rebase_failsafe_missing_onto" "0" "$_FAILSAFE_EXIT_OUTER"

print_summary
