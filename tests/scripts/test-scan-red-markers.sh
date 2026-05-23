#!/usr/bin/env bash
# tests/scripts/test-scan-red-markers.sh
# RED behavioral tests for plugins/dso/scripts/scan-red-markers.sh
#
# The scanner does not yet exist — all assertions below currently fail RED.
#
# GWT cases:
#  1. Marker present in merged tree → exit non-zero + stderr names marker + source file
#  2. No markers present → exit 0
#  3. Malformed line skipped with warning; well-formed marker still detected
#  4. Empty .test-index → exit 0
#  5. Commented-out marker line (leading #) → ignored, exit 0
#  6. Conflict markers in .test-index (<<<<<<< / ======= / >>>>>>>) → exit non-zero
#     with "cannot scan" message

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/scan-red-markers.sh"

# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-scan-red-markers.sh ==="

# ── Temp-dir isolation ──────────────────────────────────────────────────────
_TEST_TMPDIRS=()
make_tmpdir() {
    local d
    d="$(mktemp -d)"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}
cleanup() { rm -rf "${_TEST_TMPDIRS[@]}"; }
trap cleanup EXIT

# ── Helper: initialise a minimal git repo with a .test-index ───────────────
# Usage: init_repo <dir> <test-index-content>
# Sets up two commits so <base> and <head> refs are available.
# Echoes "<base> <head>" on stdout.
init_repo() {
    local dir="$1"
    local index_content="$2"

    git -C "$dir" init -q
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"

    # base commit — empty .test-index
    touch "$dir/.test-index"
    git -C "$dir" add .test-index
    git -C "$dir" commit -q -m "base"
    local base
    base="$(git -C "$dir" rev-parse HEAD)"

    # head commit — with the test-index content under test
    printf '%s' "$index_content" > "$dir/.test-index"
    git -C "$dir" add .test-index
    git -C "$dir" commit -q -m "head"
    local head
    head="$(git -C "$dir" rev-parse HEAD)"

    echo "$base $head"
}

# ── TEST 1: marker present in merged tree ──────────────────────────────────
# Given .test-index contains a line with [test_foo_explodes]
# When scan-red-markers.sh <base> <head> is invoked
# Then exit code is non-zero AND stderr lists the marker + source file
_snapshot_fail
{
    REPO="$(make_tmpdir)"
    INDEX_CONTENT="src/foo.py: tests/test_foo.py [test_foo_explodes]"
    read -r BASE HEAD <<< "$(init_repo "$REPO" "$INDEX_CONTENT")"

    rc=0
    stderr_out="$(bash "$SCRIPT" "$BASE" "$HEAD" 2>&1 >/dev/null)" || rc=$?

    assert_ne "T1: marker present → exit non-zero" "0" "$rc"
    assert_contains "T1: stderr names the marker" "test_foo_explodes" "$stderr_out"
    assert_contains "T1: stderr names the source file" "src/foo.py" "$stderr_out"
}
assert_pass_if_clean "test_scan_red_markers_unit_marker_present"

# ── TEST 2: no markers present → exit 0 ────────────────────────────────────
_snapshot_fail
{
    REPO="$(make_tmpdir)"
    INDEX_CONTENT="src/bar.py: tests/test_bar.py"
    read -r BASE HEAD <<< "$(init_repo "$REPO" "$INDEX_CONTENT")"

    rc=0
    bash "$SCRIPT" "$BASE" "$HEAD" 2>/dev/null || rc=$?

    assert_eq "T2: no markers → exit 0" "0" "$rc"
}
assert_pass_if_clean "test_scan_red_markers_unit_no_markers"

# ── TEST 3: malformed line skipped + warning; well-formed marker detected ──
# Given one malformed line (no colon separator) and one well-formed marker line
# When invoked
# Then well-formed marker is flagged (exit non-zero) AND stderr contains "warn"
_snapshot_fail
{
    REPO="$(make_tmpdir)"
    INDEX_CONTENT="THIS_LINE_HAS_NO_COLON_AND_TRAILING_GARBAGE_@@@@@@
src/baz.py: tests/test_baz.py [test_baz_fails]"
    read -r BASE HEAD <<< "$(init_repo "$REPO" "$INDEX_CONTENT")"

    rc=0
    stderr_out="$(bash "$SCRIPT" "$BASE" "$HEAD" 2>&1 >/dev/null)" || rc=$?

    assert_ne "T3: malformed+marker → exit non-zero" "0" "$rc"
    assert_contains "T3: stderr names well-formed marker" "test_baz_fails" "$stderr_out"
    # Malformed line must emit a warning (case-insensitive)
    stderr_lower="$(printf '%s' "$stderr_out" | tr '[:upper:]' '[:lower:]')"
    assert_contains "T3: malformed line produces warning" "warn" "$stderr_lower"
}
assert_pass_if_clean "test_scan_red_markers_unit_malformed_line"

# ── TEST 4: empty .test-index → exit 0 ─────────────────────────────────────
_snapshot_fail
{
    REPO="$(make_tmpdir)"
    INDEX_CONTENT=""
    read -r BASE HEAD <<< "$(init_repo "$REPO" "$INDEX_CONTENT")"

    rc=0
    bash "$SCRIPT" "$BASE" "$HEAD" 2>/dev/null || rc=$?

    assert_eq "T4: empty .test-index → exit 0" "0" "$rc"
}
assert_pass_if_clean "test_scan_red_markers_unit_empty_index"

# ── TEST 5: commented-out marker line ignored → exit 0 ─────────────────────
# Given a .test-index line starting with '#' that contains bracket notation
# When invoked
# Then the marker is NOT flagged and the exit code is 0
_snapshot_fail
{
    REPO="$(make_tmpdir)"
    INDEX_CONTENT="# src/foo.py: tests/test_foo.py [test_foo]"
    read -r BASE HEAD <<< "$(init_repo "$REPO" "$INDEX_CONTENT")"

    rc=0
    bash "$SCRIPT" "$BASE" "$HEAD" 2>/dev/null || rc=$?

    assert_eq "T5: commented marker → exit 0" "0" "$rc"
}
assert_pass_if_clean "test_scan_red_markers_unit_commented_marker"

# ── TEST 6 (AC AMENDMENT): conflict markers in .test-index → exit non-zero ─
# Given .test-index contains git conflict markers (<<<<<<<, =======, >>>>>>>)
# When scan-red-markers.sh is invoked
# Then exit code is non-zero AND stderr contains "cannot scan" message
_snapshot_fail
{
    REPO="$(make_tmpdir)"
    INDEX_CONTENT='<<<<<<< HEAD
src/foo.py: tests/test_foo.py
=======
src/foo.py: tests/test_foo_other.py
>>>>>>> feature-branch'
    read -r BASE HEAD <<< "$(init_repo "$REPO" "$INDEX_CONTENT")"

    rc=0
    stderr_out="$(bash "$SCRIPT" "$BASE" "$HEAD" 2>&1 >/dev/null)" || rc=$?

    assert_ne "T6: conflict markers → exit non-zero" "0" "$rc"
    stderr_lower="$(printf '%s' "$stderr_out" | tr '[:upper:]' '[:lower:]')"
    assert_contains "T6: stderr says cannot scan" "cannot scan" "$stderr_lower"
}
assert_pass_if_clean "test_scan_red_markers_unit_conflict_markers"

# ── TEST 7: delta-mode — BASE has pre-existing markers, HEAD adds no new ones ─
# Given BASE commit has .test-index with a RED marker AND
#       HEAD commit changes only an unrelated file (leaves .test-index identical)
# When scan-red-markers.sh <base> <head> is invoked
# Then exit code is 0 (pre-existing markers are not new — no delta introduced)
# AND stderr contains no RED_MARKER: lines (no new markers to report)
#
# This test FAILS under the current all-or-nothing implementation (exits 1
# whenever marker_count > 0) and PASSES after the delta-mode fix.
_snapshot_fail
{
    REPO="$(make_tmpdir)"

    git -C "$REPO" init -q
    git -C "$REPO" config user.email "test@test.com"
    git -C "$REPO" config user.name "Test"

    # base commit — .test-index already contains a RED marker (pre-existing)
    printf '%s\n' "src/legacy.py: tests/test_legacy.py [test_legacy_fails]" > "$REPO/.test-index"
    git -C "$REPO" add .test-index
    git -C "$REPO" commit -q -m "base: pre-existing marker"
    BASE="$(git -C "$REPO" rev-parse HEAD)"

    # head commit — touch only an unrelated file; .test-index is NOT modified
    printf '%s\n' "unrelated change" > "$REPO/unrelated.txt"
    git -C "$REPO" add unrelated.txt
    git -C "$REPO" commit -q -m "head: unrelated change only"
    HEAD="$(git -C "$REPO" rev-parse HEAD)"

    rc=0
    stderr_out="$(GIT_DIR="$REPO/.git" bash "$SCRIPT" "$BASE" "$HEAD" 2>&1 >/dev/null)" || rc=$?

    assert_eq "T7: pre-existing markers, no new ones → exit 0" "0" "$rc"
    assert_not_contains "T7: no RED_MARKER lines emitted for pre-existing markers" "RED_MARKER:" "$stderr_out"
}
assert_pass_if_clean "test_scan_red_markers_delta_preexisting_markers_no_new_exit0"

# ─────────────────────────────────────────────────────────────────────────────
print_summary
