#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-version-bump-isolation.sh
# Verifies the Track A fix for cluster aa4f-13b3 / 42bd-5b9b: every call to
# _setup_test_repo in test-merge-to-main-version-bump.sh must yield a unique
# BRANCH so the resulting /tmp/merge-to-main-state-<BRANCH>.json paths do not
# collide across tests in the same script invocation, across parallel CI
# workers, or across re-runs within _state_is_fresh's 4-hour TTL.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SUT="$REPO_ROOT/tests/scripts/test-merge-to-main-version-bump.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# Source the SUT's helpers without executing its tests.
# Stop right after _cleanup_state_file is defined to avoid running the actual
# tests at source time.
_TMP_SUT=$(mktemp "${TMPDIR:-/tmp}/sut-prefix.XXXXXX")
trap 'rm -f "$_TMP_SUT"' EXIT
# Extract everything up to and including _cleanup_state_file's closing brace.
awk '
  /^_cleanup_state_file\(\) \{/ { in_cleanup=1 }
  { print }
  in_cleanup && /^\}/ { print "return 0  # stop sourcing before tests"; exit }
' "$SUT" > "$_TMP_SUT"

# shellcheck disable=SC1090
source "$_TMP_SUT" 2>/dev/null

# --- Invariant 1: _TEST_BRANCH_TAG contains both PID and a RANDOM token ---
if [[ -n "${_TEST_BRANCH_TAG:-}" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: _TEST_BRANCH_TAG_set: var is empty after source" >&2
fi
if [[ "${_TEST_BRANCH_TAG:-}" =~ ^[0-9]+-[0-9]+$ ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: _TEST_BRANCH_TAG_shape: got '${_TEST_BRANCH_TAG:-}' (want '<pid>-<random>')" >&2
fi

# --- Invariant 2: every _setup_test_repo call yields a unique BRANCH ---
declare -A _SEEN_BRANCHES=()
_DUPES=0
for i in 1 2 3 4 5 6 7 8 9 10 11; do
    _setup_test_repo
    if [[ -n "${_SEEN_BRANCHES[$BRANCH]:-}" ]]; then
        _DUPES=$(( _DUPES + 1 ))
        echo "FAIL: duplicate BRANCH at call $i: '$BRANCH'" >&2
    fi
    _SEEN_BRANCHES[$BRANCH]=1
    # Test repo is real on disk; clean up
    rm -rf "$_TEST_BASE" 2>/dev/null || true
done
assert_eq "branches_unique_across_11_setup_calls" "0" "$_DUPES"

# --- Invariant 3: BRANCH includes the per-process tag (parallel-CI isolation) ---
_setup_test_repo
if [[ "$BRANCH" == *"$_TEST_BRANCH_TAG"* ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: branch_contains_tag: BRANCH='$BRANCH' missing tag '$_TEST_BRANCH_TAG'" >&2
fi
rm -rf "$_TEST_BASE" 2>/dev/null || true

# --- Invariant 4: _cleanup_state_file is a no-op when _state_file_path is not
#     available (defensive — supports tests that source partial helpers) ---
if ! declare -F _state_file_path >/dev/null 2>&1; then
    EXIT=0
    _cleanup_state_file || EXIT=$?
    assert_eq "cleanup_noop_without_state_fn" "0" "$EXIT"
fi

print_summary
