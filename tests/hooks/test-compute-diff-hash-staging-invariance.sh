#!/usr/bin/env bash
# tests/hooks/test-compute-diff-hash-staging-invariance.sh
# Tests for dso-fqxu and dso-g8cz:
#   dso-fqxu: Untracked temp test fixtures must NOT affect the hash.
#             Only staged/tracked changes should be included in the hash.
#   dso-g8cz: Hash must be staging-invariant for new files:
#             hash(new file staged, pre-review) == hash(new file staged, pre-commit).
#             Untracked files are excluded; new files must be staged before review.
#
# Usage: bash tests/hooks/test-compute-diff-hash-staging-invariance.sh
# Exit code: 0 if all pass, non-zero if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Skip if not inside a git work tree
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "SKIP: not inside a git work tree"
    exit 0
fi

# Work in a temp directory that is a fresh git repo so we don't pollute the
# real working tree with stray test files.
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Initialise a minimal git repo with one tracked file
cd "$TMPDIR_TEST"
git init -q -b main
git config user.email "test@test.com"
git config user.name "Test"
echo "# main module" > main.py
git add main.py
git commit -q -m "init"

# ============================================================
# dso-fqxu: Untracked temp fixture must NOT affect the hash
# ============================================================
echo "--- test_untracked_temp_fixture_does_not_affect_hash (dso-fqxu) ---"

HASH_BASELINE=$(bash "$HOOK" 2>/dev/null)
assert_ne "baseline hash is non-empty" "" "$HASH_BASELINE"

# Create a temp test fixture (not in .gitignore, not excluded by NON_REVIEWABLE_PATTERN)
# These simulate temp files created by test runners during the commit workflow
echo "# temporary test fixture" > "$TMPDIR_TEST/test_fixture_temp.py"

HASH_WITH_TEMP=$(bash "$HOOK" 2>/dev/null)
assert_eq "untracked temp .py fixture does not alter hash (dso-fqxu)" \
    "$HASH_BASELINE" "$HASH_WITH_TEMP"

# Also verify with a .sh temp file
echo "#!/bin/bash" > "$TMPDIR_TEST/run_tests_temp.sh"
HASH_WITH_SH=$(bash "$HOOK" 2>/dev/null)
assert_eq "untracked temp .sh fixture does not alter hash (dso-fqxu)" \
    "$HASH_BASELINE" "$HASH_WITH_SH"

# Also verify with a generic temp .txt file
echo "temp output" > "$TMPDIR_TEST/output.txt"
HASH_WITH_TXT=$(bash "$HOOK" 2>/dev/null)
assert_eq "untracked temp .txt file does not alter hash (dso-fqxu)" \
    "$HASH_BASELINE" "$HASH_WITH_TXT"

# Cleanup temp files
rm -f "$TMPDIR_TEST/test_fixture_temp.py" "$TMPDIR_TEST/run_tests_temp.sh" "$TMPDIR_TEST/output.txt"

# ============================================================
# dso-fqxu: Hash is stable when temp files appear and disappear
# Simulates: test runner creates temp files between review and commit
# ============================================================
echo "--- test_hash_stable_across_temp_file_lifecycle (dso-fqxu) ---"

HASH_PRE_TEMP=$(bash "$HOOK" 2>/dev/null)

# Simulate temp files created by test runner
echo "# conftest" > "$TMPDIR_TEST/conftest_generated.py"
echo "fixture data" > "$TMPDIR_TEST/test_data_fixture.dat"

HASH_DURING_TEMP=$(bash "$HOOK" 2>/dev/null)
assert_eq "hash during temp file presence == hash before (dso-fqxu)" \
    "$HASH_PRE_TEMP" "$HASH_DURING_TEMP"

# Temp files disappear after test run
rm -f "$TMPDIR_TEST/conftest_generated.py" "$TMPDIR_TEST/test_data_fixture.dat"

HASH_POST_TEMP=$(bash "$HOOK" 2>/dev/null)
assert_eq "hash after temp file removal == hash before (dso-fqxu)" \
    "$HASH_PRE_TEMP" "$HASH_POST_TEMP"

# ============================================================
# dso-g8cz: Staging invariance — staged new file gives same hash
# at review time and at pre-commit time.
# The workflow requires staging new files before review.
# ============================================================
echo "--- test_staging_invariance_new_file (dso-g8cz) ---"

# Start clean
HASH_CLEAN=$(bash "$HOOK" 2>/dev/null)
assert_ne "clean hash is non-empty" "" "$HASH_CLEAN"

# Stage a new file (simulates: developer stages before running /dso:review)
echo "def hello(): return 'world'" > "$TMPDIR_TEST/new_feature.py"
git add "$TMPDIR_TEST/new_feature.py"

# Ensure git index mtime advances past seconds-resolution cache key (CI race fix)
sleep 1

# Hash at review time (file is staged)
HASH_AT_REVIEW=$(bash "$HOOK" 2>/dev/null)
assert_ne "hash with staged new file is non-empty (dso-g8cz)" "" "$HASH_AT_REVIEW"
assert_ne "staged new file changes hash from clean (dso-g8cz)" "$HASH_CLEAN" "$HASH_AT_REVIEW"

# Simulate: review completes, nothing changes, pre-commit hook runs
# The hash at pre-commit should equal the hash at review
HASH_AT_PRECOMMIT=$(bash "$HOOK" 2>/dev/null)
assert_eq "hash(staged at review) == hash(staged at pre-commit) (dso-g8cz)" \
    "$HASH_AT_REVIEW" "$HASH_AT_PRECOMMIT"

# Unstage and restage: hash must still be same (staging is idempotent)
git reset HEAD "$TMPDIR_TEST/new_feature.py" 2>/dev/null || true
git add "$TMPDIR_TEST/new_feature.py"
HASH_RESTAGED=$(bash "$HOOK" 2>/dev/null)
assert_eq "hash after unstage+restage == original staged hash (dso-g8cz)" \
    "$HASH_AT_REVIEW" "$HASH_RESTAGED"

# Cleanup staged file
git reset HEAD "$TMPDIR_TEST/new_feature.py" 2>/dev/null || true
rm -f "$TMPDIR_TEST/new_feature.py"

# ============================================================
# dso-g8cz: Staging invariance with temp files present
# Simulates the real scenario: review → temp files created by tests → commit
# ============================================================
echo "--- test_staging_invariance_with_temp_files_present (dso-g8cz) ---"

# Stage a real new file
echo "class Feature: pass" > "$TMPDIR_TEST/real_feature.py"
git add "$TMPDIR_TEST/real_feature.py"

HASH_REVIEW_CLEAN=$(bash "$HOOK" 2>/dev/null)
assert_ne "hash with staged new file (no temp files) is non-empty" "" "$HASH_REVIEW_CLEAN"

# Now temp files appear (as if test runner created them between review and commit)
echo "# temp fixture created by test runner" > "$TMPDIR_TEST/conftest_temp_fixture.py"
echo "test output data" > "$TMPDIR_TEST/test_output.dat"

HASH_PRECOMMIT_WITH_TEMP=$(bash "$HOOK" 2>/dev/null)
assert_eq "hash at pre-commit with temp files == hash at review (dso-fqxu+dso-g8cz)" \
    "$HASH_REVIEW_CLEAN" "$HASH_PRECOMMIT_WITH_TEMP"

# Cleanup
git reset HEAD "$TMPDIR_TEST/real_feature.py" 2>/dev/null || true
rm -f "$TMPDIR_TEST/real_feature.py" "$TMPDIR_TEST/conftest_temp_fixture.py" "$TMPDIR_TEST/test_output.dat"

# ============================================================
# dso-g8cz: Staging multiple new files
# ============================================================
echo "--- test_staging_invariance_multiple_new_files (dso-g8cz) ---"

echo "x = 1" > "$TMPDIR_TEST/module_a.py"
echo "x = 2" > "$TMPDIR_TEST/module_b.py"
git add "$TMPDIR_TEST/module_a.py" "$TMPDIR_TEST/module_b.py"

HASH_BOTH_STAGED_REVIEW=$(bash "$HOOK" 2>/dev/null)
# Simulate nothing changes between review and commit
HASH_BOTH_STAGED_COMMIT=$(bash "$HOOK" 2>/dev/null)

assert_eq "hash(both staged) is stable between review and commit (dso-g8cz)" \
    "$HASH_BOTH_STAGED_REVIEW" "$HASH_BOTH_STAGED_COMMIT"

# Cleanup staged files
git reset HEAD "$TMPDIR_TEST/module_a.py" "$TMPDIR_TEST/module_b.py" 2>/dev/null || true
rm -f "$TMPDIR_TEST/module_a.py" "$TMPDIR_TEST/module_b.py"

# Return to repo root for print_summary
cd "$REPO_ROOT"

print_summary
