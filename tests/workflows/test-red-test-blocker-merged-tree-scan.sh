#!/usr/bin/env bash
# tests/workflows/test-red-test-blocker-merged-tree-scan.sh
# Behavioral RED test for scan-red-markers.sh — two-sub-PR resurfacing scenario.
#
# Story: 3e0e-e533-a130-4175 / Task: 2b99-ea45-ffda-498a (S4.T3)
# DD3: Behavioral test that simulates two sub-PRs on the same session branch —
#      one removes a RED marker, one re-introduces it — asserts that the
#      merged-tree scan blocks the session→main merge.
#
# Tests:
#   1. test_two_subpr_resurfacing_blocks_merge
#      Two commits on session/test (simulating two sub-PRs landing sequentially):
#        Commit A (sub-PR 1): removes [test_foo] from .test-index
#        Commit B (sub-PR 2, later): re-introduces [test_foo] for src/foo.py
#      Expect: exit code non-zero AND stderr lists test_foo RED_MARKER
#
#   2. test_no_resurfacing_control_case_exit_0
#      Control case: session/test contains ONLY Commit A (marker removed, NOT
#      re-introduced). No marker in cumulative merged state.
#      Expect: exit 0
#
# Usage: bash tests/workflows/test-red-test-blocker-merged-tree-scan.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCAN_SCRIPT="$REPO_ROOT/plugins/dso/scripts/scan-red-markers.sh"
# Invoked as: bash plugins/dso/scripts/scan-red-markers.sh "${BASE_SHA}" "${HEAD_SHA}"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-red-test-blocker-merged-tree-scan.sh ==="

# ── Cleanup ───────────────────────────────────────────────────────────────────
_WORK_DIRS=()
_cleanup() {
    for d in "${_WORK_DIRS[@]:-}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap '_cleanup' EXIT

# ── Test 1: resurfacing blocks merge under delta-aware semantics ──────────────
# Fixture: isolated git repo in mktemp dir.
# Commit chain (models sub-PR 1's removal already merged to main; sub-PR 2
# re-introduces the marker on a fresh session branch):
#   (1) Initial commit on main: .test-index with [test_foo] marker present
#   (2) Commit A on main: sub-PR 1 lands — removes [test_foo]
#   (3) session/test branched from main (post sub-PR 1)
#   (4) Commit B on session/test: sub-PR 2 re-introduces [test_foo] — resurfacing
# BASE = main post sub-PR 1 (no marker). HEAD = session tip (marker reintroduced).
# Under delta-aware semantics, the reintroduction is NEW vs BASE → scan blocks.
_snapshot_fail

REPO1=$(mktemp -d "${TMPDIR:-/tmp}/scan-red-markers-fixture.XXXXXX")
_WORK_DIRS+=("$REPO1")

(
    cd "$REPO1" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    git config commit.gpgsign false

    # Initial commit on main: .test-index with [test_foo] marker present.
    printf 'src/foo.py: tests/test_foo.py [test_foo]\n' > .test-index
    git add .test-index
    git commit -q -m "initial: .test-index with [test_foo] marker"

    # Sub-PR 1 lands on main: removes [test_foo]. Now main has no marker.
    printf '' > .test-index
    git add .test-index
    git commit -q -m "sub-PR 1 (on main): remove [test_foo] marker"

    # Branch session/test from current main (post sub-PR 1).
    git checkout -q -b session/test

    # Commit B (sub-PR 2 on session): re-introduces [test_foo] — resurfacing.
    printf 'src/foo.py: tests/test_foo.py [test_foo]\n' > .test-index
    git add .test-index
    git commit -q -m "sub-PR 2 (on session): re-introduce [test_foo] marker for src/foo.py"
)

# BASE = main tip after sub-PR 1 merged (no marker).
# HEAD = session tip after sub-PR 2 re-introduces the marker.
# Pass explicit SHAs (not branch names) to scan-red-markers.sh.
MAIN_SHA=$(git -C "$REPO1" rev-parse session/test~1)
SESSION_SHA=$(git -C "$REPO1" rev-parse session/test)

# Invoke scan-red-markers.sh; capture exit code and stderr.
scan_exit1=0
stderr_out1=$(GIT_DIR="$REPO1/.git" bash "$SCAN_SCRIPT" "${MAIN_SHA}" "${SESSION_SHA}" 2>&1) \
    || scan_exit1=$?

# Assertion 1a: exit code must be non-zero (marker detected → block session→main merge).
assert_ne "test_two_subpr_resurfacing_blocks_merge: exit code is non-zero" "0" "$scan_exit1"

# Assertion 1b: stderr must list test_foo as a flagged RED marker.
# scan-red-markers.sh emits: "RED_MARKER: <marker_name> for <source_file>"
assert_contains "test_two_subpr_resurfacing_blocks_merge: stderr lists test_foo RED_MARKER" \
    "RED_MARKER: test_foo" "$stderr_out1"

assert_pass_if_clean "test_two_subpr_resurfacing_blocks_merge"

# ── Test 2: no resurfacing control case — exit 0 ─────────────────────────────
# Fixture: similar isolated git repo.
# Commit chain:
#   (1) Initial commit on main: .test-index with [test_foo] marker
#   (2) Commit A on session/test: removes [test_foo]  (no re-introduction)
# Cumulative merged-tree state has no marker → scan must exit 0.
_snapshot_fail

REPO2=$(mktemp -d "${TMPDIR:-/tmp}/scan-red-markers-fixture.XXXXXX")
_WORK_DIRS+=("$REPO2")

(
    cd "$REPO2" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    git config commit.gpgsign false

    # Initial commit on main: .test-index with [test_foo] marker present.
    printf 'src/foo.py: tests/test_foo.py [test_foo]\n' > .test-index
    git add .test-index
    git commit -q -m "initial: .test-index with [test_foo] marker"

    git checkout -q -b session/test

    # Only Commit A: removes [test_foo] — no re-introduction (control case).
    printf '' > .test-index
    git add .test-index
    git commit -q -m "sub-PR 1 only: remove [test_foo] — no marker re-introduction"
)

# Collect SHAs; pass explicit SHAs (not branch names) to scan-red-markers.sh.
MAIN_SHA2=$(git -C "$REPO2" rev-parse session/test~1)
SESSION_SHA2=$(git -C "$REPO2" rev-parse session/test)

# Invoke scan-red-markers.sh; capture exit code.
scan_exit2=0
stderr_out2=$(GIT_DIR="$REPO2/.git" bash "$SCAN_SCRIPT" "${MAIN_SHA2}" "${SESSION_SHA2}" 2>&1) \
    || scan_exit2=$?

# Assertion 2: exit 0 — no marker in cumulative state.
assert_eq "test_no_resurfacing_control_case_exit_0: exit 0 when no marker in merged state" \
    "0" "$scan_exit2"

assert_pass_if_clean "test_no_resurfacing_control_case_exit_0"

print_summary
