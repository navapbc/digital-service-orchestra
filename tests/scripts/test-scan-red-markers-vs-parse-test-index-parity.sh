#!/usr/bin/env bash
# tests/scripts/test-scan-red-markers-grammar-parity.sh
# Parity test: scan-red-markers.sh and bash-runner.sh _RED_MARKER_MAP
# parse the same marker-name set from the same .test-index fixture.
#
# This is a behavioral test — it asserts on the SET of extracted marker names,
# not on stdout format or line order.
#
# Grammar variants exercised (per REVIEW-DEFENSE comment block in .test-index
# and bash-runner.sh _RED_MARKER_MAP canonical grammar):
#
#   1. source-side path (no space before bracket): source.py:test.sh [marker]
#   2. test-side path with space before bracket:   source.py: test.sh [marker]
#   3. comma-separated test list, last entry has marker
#   4. comma-separated test list, multiple entries have markers
#   5. Entry with no marker (should NOT appear in either set)
#   6. Malformed line (no colon) — should be skipped by scan-red-markers.sh
#   7. Comment line — should be skipped by both
#
# Given / When / Then:
#   Given: a fixture git repo with a .test-index containing the above variants
#   When:  (a) scan-red-markers.sh <base> <head> is invoked (extracts via git merge-tree)
#          (b) bash-runner.sh _RED_MARKER_MAP loader is replicated inline against the same file
#   Then:  both produce the identical sorted set of marker names
#
# [test_scan_red_markers_grammar_parity]

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCAN_SCRIPT="$REPO_ROOT/plugins/dso/scripts/scan-red-markers.sh"

# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-scan-red-markers-grammar-parity.sh ==="

# ── Temp-dir isolation ──────────────────────────────────────────────────────
_TEST_TMPDIRS=()
make_tmpdir() {
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/test-parity-XXXXXX")"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}
cleanup() { rm -rf "${_TEST_TMPDIRS[@]}"; }
trap cleanup EXIT

# ── Shared fixture string ───────────────────────────────────────────────────
# Diverse marker forms covering the documented grammar variants:
#   (a) source-side path, no space before colon separator, test path with marker
#   (b) test-side path with space before bracket (valid test-function filter)
#   (c) comma list: first entry no marker, second entry has marker
#   (d) comma list: both entries have distinct markers
#   (e) entry with no marker at all (must NOT appear in either result set)
#   (f) malformed line (no colon) — must be skipped/warned by scan-red-markers.sh
#   (g) comment line — must be ignored by both parsers
FIXTURE_CONTENT='# comment line — must be ignored by both parsers
src/alpha.py:tests/test_alpha.sh [marker_alpha]
src/beta.py: tests/test_beta.sh [marker_beta]
src/gamma.py:tests/test_gamma_a.sh,tests/test_gamma_b.sh [marker_gamma]
src/delta.py:tests/test_delta_a.sh [marker_delta_a],tests/test_delta_b.sh [marker_delta_b]
src/epsilon.py:tests/test_epsilon.sh
MALFORMED_LINE_NO_COLON_SEPARATOR'

# Expected marker names (sorted) — union of all [marker_*] entries in the fixture.
# Note: marker_alpha, marker_beta, marker_gamma, marker_delta_a, marker_delta_b
EXPECTED_MARKERS="marker_alpha
marker_beta
marker_delta_a
marker_delta_b
marker_gamma"

# ── Helper: init minimal git repo for scan-red-markers.sh ──────────────────
# Creates a repo with two commits so scan-red-markers.sh can call merge-tree.
# Echoes "<base-sha> <head-sha>" on stdout.
init_repo_with_index() {
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

    # head commit — fixture content
    printf '%s\n' "$index_content" > "$dir/.test-index"
    git -C "$dir" add .test-index
    git -C "$dir" commit -q -m "head"
    local head
    head="$(git -C "$dir" rev-parse HEAD)"

    echo "$base $head"
}

# ── extract_markers_via_bash_runner_grammar ─────────────────────────────────
# Replicates the _RED_MARKER_MAP loading loop from bash-runner.sh verbatim:
#   - skip blank lines and comments
#   - split on first colon (right side)
#   - split right side on commas
#   - for each part: trim whitespace, apply the marker regex
#     ^(.*[^[:space:]])[[:space:]]+\[([^]]+)\]$
#   - collect BASH_REMATCH[2] (marker name) when the regex matches
# Returns sorted marker names on stdout, one per line.
extract_markers_via_bash_runner_grammar() {
    local index_file="$1"
    local -a collected=()

    local _line _right _part _ppath _pmarker _IFS_save
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        [[ -z "$_line" ]] && continue
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue
        # Require a colon (mirrors bash-runner.sh which does not warn but silently skips)
        [[ "$_line" =~ : ]] || continue
        _right="${_line#*:}"
        _IFS_save="$IFS"
        IFS=','
        # shellcheck disable=SC2206
        local _parts=( $_right )
        IFS="$_IFS_save"
        for _part in "${_parts[@]}"; do
            _part="${_part#"${_part%%[![:space:]]*}"}"
            _part="${_part%"${_part##*[![:space:]]}"}"
            [[ -z "$_part" ]] && continue
            _ppath="" _pmarker=""
            if [[ "$_part" =~ ^(.*[^[:space:]])[[:space:]]+\[([^]]+)\]$ ]]; then
                _pmarker="${BASH_REMATCH[2]}"
                if [[ -n "$_pmarker" ]]; then
                    collected+=("$_pmarker")
                fi
            fi
        done
    done < "$index_file"

    # Print sorted, deduplicated
    if [[ ${#collected[@]} -gt 0 ]]; then
        printf '%s\n' "${collected[@]}" | sort -u
    fi
}

# ── extract_markers_via_scan_red_markers ─────────────────────────────────────
# Invokes scan-red-markers.sh against a git fixture and parses its stderr:
#   "RED_MARKER: <marker_name> for <source_file>"
# Returns sorted marker names on stdout, one per line.
extract_markers_via_scan_red_markers() {
    local base_sha="$1"
    local head_sha="$2"
    local git_dir="$3"
    local -a collected=()

    local stderr_out
    stderr_out="$(GIT_DIR="$git_dir" bash "$SCAN_SCRIPT" "$base_sha" "$head_sha" 2>&1 >/dev/null)" || true

    # Parse lines of the form "RED_MARKER: <name> for <source>"
    while IFS= read -r _sline; do
        if [[ "$_sline" =~ ^RED_MARKER:[[:space:]]+([^[:space:]]+)[[:space:]]+for[[:space:]] ]]; then
            collected+=("${BASH_REMATCH[1]}")
        fi
    done <<< "$stderr_out"

    if [[ ${#collected[@]} -gt 0 ]]; then
        printf '%s\n' "${collected[@]}" | sort -u
    fi
}

# ── PARITY TEST ─────────────────────────────────────────────────────────────
# Given: fixture .test-index with diverse marker grammar forms
# When:  both parsers process the same fixture
# Then:  they produce the identical sorted set of marker names
_snapshot_fail
{
    REPO="$(make_tmpdir)"
    read -r BASE HEAD <<< "$(init_repo_with_index "$REPO" "$FIXTURE_CONTENT")"
    GIT_DIR_PATH="$REPO/.git"

    # Side A: bash-runner.sh grammar replicated inline (reads file directly)
    FIXTURE_FILE="$REPO/.test-index"
    bash_runner_markers="$(extract_markers_via_bash_runner_grammar "$FIXTURE_FILE")"

    # Side B: scan-red-markers.sh (reads from git merge-tree)
    scan_script_markers="$(extract_markers_via_scan_red_markers "$BASE" "$HEAD" "$GIT_DIR_PATH")"

    # Assert: both sides produce the expected marker set
    assert_eq "parity: bash-runner grammar matches expected" \
        "$EXPECTED_MARKERS" "$bash_runner_markers"

    assert_eq "parity: scan-red-markers.sh matches expected" \
        "$EXPECTED_MARKERS" "$scan_script_markers"

    # Assert: both sides agree with each other
    assert_eq "parity: both parsers agree on marker set" \
        "$bash_runner_markers" "$scan_script_markers"
}
assert_pass_if_clean "test_scan_red_markers_grammar_parity"

# ── NEGATIVE CONTROL: no-marker entries are excluded ────────────────────────
# Given: fixture where no entries have [marker] annotations
# When:  both parsers run
# Then:  both return empty (no marker names detected)
_snapshot_fail
{
    REPO2="$(make_tmpdir)"
    NO_MARKER_CONTENT='src/foo.py:tests/test_foo.sh
src/bar.py:tests/test_bar_a.sh,tests/test_bar_b.sh'
    read -r BASE2 HEAD2 <<< "$(init_repo_with_index "$REPO2" "$NO_MARKER_CONTENT")"

    bash_runner_no_markers="$(extract_markers_via_bash_runner_grammar "$REPO2/.test-index")"
    scan_no_markers="$(extract_markers_via_scan_red_markers "$BASE2" "$HEAD2" "$REPO2/.git")"

    assert_eq "no-marker: bash-runner grammar returns empty" "" "$bash_runner_no_markers"
    assert_eq "no-marker: scan-red-markers.sh returns empty (exit 0)" "" "$scan_no_markers"
}
assert_pass_if_clean "test_scan_red_markers_grammar_parity_no_markers"

# ── SET COMPARISON GUARD: order independence ─────────────────────────────────
# Given: fixture with markers in non-alphabetical order
# When:  both parsers run and results are sorted
# Then:  marker sets match regardless of fixture ordering
_snapshot_fail
{
    REPO3="$(make_tmpdir)"
    UNORDERED_CONTENT='src/z.py:tests/test_z.sh [marker_z]
src/a.py:tests/test_a.sh [marker_a]
src/m.py:tests/test_m.sh [marker_m]'
    read -r BASE3 HEAD3 <<< "$(init_repo_with_index "$REPO3" "$UNORDERED_CONTENT")"

    bash_runner_ordered="$(extract_markers_via_bash_runner_grammar "$REPO3/.test-index")"
    scan_ordered="$(extract_markers_via_scan_red_markers "$BASE3" "$HEAD3" "$REPO3/.git")"

    assert_eq "ordering: both produce same sorted set" \
        "$bash_runner_ordered" "$scan_ordered"

    # Confirm the sorted set is correct
    expected_ordered="marker_a
marker_m
marker_z"
    assert_eq "ordering: sorted set is alphabetical" \
        "$expected_ordered" "$bash_runner_ordered"
}
assert_pass_if_clean "test_scan_red_markers_grammar_parity_order_independence"

# ─────────────────────────────────────────────────────────────────────────────
print_summary
