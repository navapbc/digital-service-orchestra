#!/usr/bin/env bash
# tests/workflows/test-sprint-fixture-red-marker-blocker.sh
# Sprint-fixture self-test for DD#4: verifies the merge-pipeline-checks
# red-test-blocker detects an intentional RED marker and exits non-zero.
#
# Story: 3e0e-e533-a130-4175 / Task: f23f-346e-1861-4e41 (S4.T6)
# DD4: Epic's own sprint attempts a RED-marker push to main and is blocked by
#      the check (verifying SC4(a) sprint-fixture verification). This test
#      makes that verification explicit via a local scan-red-markers.sh fixture.
#
# Tests:
#   1. test_sprint_fixture_red_marker_blocker_exits_nonzero
#      Fixture: isolated git repo (mktemp — never touches the real repo).
#      Session branch adds an intentional RED marker entry for a throwaway
#      fixture source file. Verifies scan-red-markers.sh exits non-zero AND
#      stderr names the marker [test_fixture_proves_blocker_works].
#
#   2. test_sprint_fixture_cleanup_no_marker_in_real_test_index
#      Verifies the real .test-index contains no [test_fixture_proves_blocker_works]
#      entry (fixture was isolated; real repo is clean).
#
#   3. test_sprint_fixture_cleanup_no_fixture_test_file
#      Verifies tests/test___fixture__.py does not exist in the real working tree.
#
# Usage: bash tests/workflows/test-sprint-fixture-red-marker-blocker.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCAN_SCRIPT="$REPO_ROOT/plugins/dso/scripts/scan-red-markers.sh"

# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-fixture-red-marker-blocker.sh ==="

# ── Cleanup ───────────────────────────────────────────────────────────────────
_WORK_DIRS=()
_cleanup() {
    for d in "${_WORK_DIRS[@]:-}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap '_cleanup' EXIT

# ── Test 1: intentional RED marker on throwaway sub-branch blocks merge ───────
# Fixture: isolated git repo in mktemp dir (real repo is never mutated).
# Commit chain:
#   (1) Initial commit on main-equivalent: .test-index WITHOUT the marker.
#   (2) Commit on "sub-branch": .test-index WITH [test_fixture_proves_blocker_works]
#       for a transient fixture source file.
# When scan-red-markers.sh is invoked with base=main-equiv, head=sub-branch tip,
# it must: (a) exit non-zero, (b) name the marker in stderr.
_snapshot_fail

FIXTURE_REPO=$(mktemp -d "${TMPDIR:-/tmp}/sprint-fixture-red-marker.XXXXXX")
_WORK_DIRS+=("$FIXTURE_REPO")

(
    cd "$FIXTURE_REPO" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    git config commit.gpgsign false

    # Initial commit (simulates session-branch base): .test-index without marker.
    printf 'src/__fixture__.py: tests/test___fixture__.py\n' > .test-index
    git add .test-index
    git commit -q -m "base: .test-index without RED marker"

    # Sub-branch: add intentional RED marker [test_fixture_proves_blocker_works].
    git checkout -q -b red-marker-fixture-test
    printf 'src/__fixture__.py: tests/test___fixture__.py [test_fixture_proves_blocker_works]\n' \
        > .test-index
    git add .test-index
    git commit -q -m "fixture: intentional RED marker to prove blocker works"
)

# Collect SHAs — pass explicit SHAs (not branch names) to scan-red-markers.sh.
FIXTURE_BASE_SHA=$(git -C "$FIXTURE_REPO" rev-parse red-marker-fixture-test~1)
FIXTURE_HEAD_SHA=$(git -C "$FIXTURE_REPO" rev-parse red-marker-fixture-test)

# Invoke scan-red-markers.sh with isolated GIT_DIR; capture exit code + stderr.
scan_exit=0
scan_stderr=$(GIT_DIR="$FIXTURE_REPO/.git" bash "$SCAN_SCRIPT" \
    "$FIXTURE_BASE_SHA" "$FIXTURE_HEAD_SHA" 2>&1) || scan_exit=$?

# Assertion 1a: scan must exit non-zero (RED marker detected → merge blocked).
assert_ne \
    "test_sprint_fixture_red_marker_blocker_exits_nonzero: exit code is non-zero" \
    "0" "$scan_exit"

# Assertion 1b: stderr must name the exact marker used in the fixture.
assert_contains \
    "test_sprint_fixture_red_marker_blocker_exits_nonzero: stderr names test_fixture_proves_blocker_works" \
    "test_fixture_proves_blocker_works" "$scan_stderr"

assert_pass_if_clean "test_sprint_fixture_red_marker_blocker_exits_nonzero"

# ── Test 2: real .test-index has no leftover fixture marker ───────────────────
# The fixture ran entirely inside the isolated $FIXTURE_REPO. Verify the real
# .test-index is clean — no [test_fixture_proves_blocker_works] entry.
_snapshot_fail

real_test_index="$REPO_ROOT/.test-index"
marker_in_real_index=0
if grep -qF 'test_fixture_proves_blocker_works' "$real_test_index" 2>/dev/null; then
    marker_in_real_index=1
fi

assert_eq \
    "test_sprint_fixture_cleanup_no_marker_in_real_test_index: .test-index is clean" \
    "0" "$marker_in_real_index"

assert_pass_if_clean "test_sprint_fixture_cleanup_no_marker_in_real_test_index"

# ── Test 3: real working tree has no fixture test file ────────────────────────
# tests/test___fixture__.py must not exist in the real working tree — the fixture
# was confined to the isolated git repo in TMPDIR.
_snapshot_fail

fixture_file="$REPO_ROOT/tests/test___fixture__.py"
fixture_exists=0
if [[ -f "$fixture_file" ]]; then
    fixture_exists=1
fi

assert_eq \
    "test_sprint_fixture_cleanup_no_fixture_test_file: tests/test___fixture__.py absent" \
    "0" "$fixture_exists"

assert_pass_if_clean "test_sprint_fixture_cleanup_no_fixture_test_file"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
