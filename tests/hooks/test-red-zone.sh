#!/usr/bin/env bash
set -euo pipefail
# tests/hooks/test-red-zone.sh
# Unit tests for plugins/dso/hooks/lib/red-zone.sh
#
# Covers:
#   get_red_zone_line_number()
#   parse_failing_tests_from_output()
#   get_test_line_number()
#   read_red_markers_by_test_file()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$PLUGIN_ROOT/tests/lib"

source "$LIB_DIR/assert.sh"
source "$PLUGIN_ROOT/plugins/dso/hooks/lib/red-zone.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

make_temp_file() {
    mktemp "${TMPDIR:-/tmp}/test-red-zone-XXXXXX"
}

make_temp_dir() {
    mktemp -d "${TMPDIR:-/tmp}/test-red-zone-dir-XXXXXX"
}

# ============================================================
# get_red_zone_line_number tests
# ============================================================
echo ""
echo "=== get_red_zone_line_number ==="

# Test: marker found in bash test file (function definition)
_tf1=$(make_temp_file)
cat > "$_tf1" <<'EOF'
#!/usr/bin/env bash
test_one() { echo pass; }
test_red_start() { echo fail; }
test_after() { echo pass; }
EOF
_repo1=$(make_temp_dir)
mkdir -p "$_repo1/tests"
_rel1="tests/mytest.sh"
cp "$_tf1" "$_repo1/$_rel1"
_line=$(REPO_ROOT="$_repo1" get_red_zone_line_number "$_rel1" "test_red_start")
assert_eq "marker found at correct line" "3" "$_line"
rm -rf "$_repo1" "$_tf1"

# Test: marker not found → returns -1
_tf2=$(make_temp_file)
cat > "$_tf2" <<'EOF'
#!/usr/bin/env bash
test_one() { echo pass; }
EOF
_repo2=$(make_temp_dir)
mkdir -p "$_repo2/tests"
_rel2="tests/mytest.sh"
cp "$_tf2" "$_repo2/$_rel2"
_line2=$(REPO_ROOT="$_repo2" get_red_zone_line_number "$_rel2" "test_nonexistent" 2>/dev/null)
assert_eq "missing marker returns -1" "-1" "$_line2"
rm -rf "$_repo2" "$_tf2"

# Test: file does not exist → returns -1
_repo3=$(make_temp_dir)
_line3=$(REPO_ROOT="$_repo3" get_red_zone_line_number "tests/nofile.sh" "test_foo")
assert_eq "missing file returns -1" "-1" "$_line3"
rm -rf "$_repo3"

# Test: comment-only lines are skipped (no false positive from # test_red_start)
_tf4=$(make_temp_file)
cat > "$_tf4" <<'EOF'
#!/usr/bin/env bash
# test_red_start comment line — should not match
test_green() { echo pass; }
test_red_start() { echo fail; }
EOF
_repo4=$(make_temp_dir)
mkdir -p "$_repo4/tests"
_rel4="tests/mytest.sh"
cp "$_tf4" "$_repo4/$_rel4"
_line4=$(REPO_ROOT="$_repo4" get_red_zone_line_number "$_rel4" "test_red_start")
assert_eq "comment-only line skipped; real match on line 4" "4" "$_line4"
rm -rf "$_repo4" "$_tf4"

# Test: word-boundary: 'test_red' marker must not match 'test_red_extended'
_tf5=$(make_temp_file)
cat > "$_tf5" <<'EOF'
#!/usr/bin/env bash
test_red_extended() { echo pass; }
test_red() { echo fail; }
EOF
_repo5=$(make_temp_dir)
mkdir -p "$_repo5/tests"
_rel5="tests/mytest.sh"
cp "$_tf5" "$_repo5/$_rel5"
_line5=$(REPO_ROOT="$_repo5" get_red_zone_line_number "$_rel5" "test_red")
assert_eq "word-boundary: test_red matches line 3, not line 1" "3" "$_line5"
rm -rf "$_repo5" "$_tf5"

# ============================================================
# parse_failing_tests_from_output tests
# ============================================================
echo ""
echo "=== parse_failing_tests_from_output ==="

# Test: bash-style "test_name: FAIL" lines
_out1=$(make_temp_file)
cat > "$_out1" <<'EOF'
test_alpha: PASS
test_beta: FAIL
test_gamma: FAIL
EOF
_failing=$(parse_failing_tests_from_output "$_out1" | sort | tr '\n' ',' | sed 's/,$//')
assert_eq "bash-style FAIL parsed" "test_beta,test_gamma" "$_failing"
rm -f "$_out1"

# Test: "FAIL: test_name" format (assert_pass_if_clean style)
_out2=$(make_temp_file)
cat > "$_out2" <<'EOF'
FAIL: test_one
FAIL: test_two
EOF
_failing2=$(parse_failing_tests_from_output "$_out2" | sort | tr '\n' ',' | sed 's/,$//')
assert_eq "FAIL: prefix format parsed" "test_one,test_two" "$_failing2"
rm -f "$_out2"

# Test: pytest "FAILED path::test_name" format
_out3=$(make_temp_file)
cat > "$_out3" <<'EOF'
FAILED tests/foo.py::test_bad_thing
PASSED tests/foo.py::test_good_thing
FAILED tests/foo.py::test_other_bad
EOF
_failing3=$(parse_failing_tests_from_output "$_out3" | sort | tr '\n' ',' | sed 's/,$//')
assert_eq "pytest FAILED format parsed" "test_bad_thing,test_other_bad" "$_failing3"
rm -f "$_out3"

# Test: missing file → empty output
_failing4=$(parse_failing_tests_from_output "/tmp/nonexistent-red-zone-XXXXXX-abc")
assert_eq "missing output file returns empty" "" "$_failing4"

# Test: indented "FAIL: test_name" lines (2-space indent) are parsed correctly
_out5=$(make_temp_file)
cat > "$_out5" <<'EOF'
  FAIL: test_indented_one
  FAIL: test_indented_two
EOF
_failing5=$(parse_failing_tests_from_output "$_out5" | sort | tr '\n' ',' | sed 's/,$//')
assert_eq "indented FAIL: prefix format parsed" "test_indented_one,test_indented_two" "$_failing5"
rm -f "$_out5"

# ============================================================
# get_test_line_number tests
# ============================================================
echo ""
echo "=== get_test_line_number ==="

# Test: finds function on correct line
_tf6=$(make_temp_file)
cat > "$_tf6" <<'EOF'
#!/usr/bin/env bash
test_alpha() { echo pass; }
test_beta() { echo fail; }
test_gamma() { echo pass; }
EOF
_repo6=$(make_temp_dir)
mkdir -p "$_repo6/tests"
_rel6="tests/mytest.sh"
cp "$_tf6" "$_repo6/$_rel6"
_line6=$(REPO_ROOT="$_repo6" get_test_line_number "$_rel6" "test_beta")
assert_eq "test_beta found on line 3" "3" "$_line6"
rm -rf "$_repo6" "$_tf6"

# Test: not found → -1
_tf7=$(make_temp_file)
cat > "$_tf7" <<'EOF'
#!/usr/bin/env bash
test_alpha() { echo pass; }
EOF
_repo7=$(make_temp_dir)
mkdir -p "$_repo7/tests"
_rel7="tests/mytest.sh"
cp "$_tf7" "$_repo7/$_rel7"
_line7=$(REPO_ROOT="$_repo7" get_test_line_number "$_rel7" "test_nonexistent")
assert_eq "not found returns -1" "-1" "$_line7"
rm -rf "$_repo7" "$_tf7"

# Test: missing file → -1
_repo8=$(make_temp_dir)
_line8=$(REPO_ROOT="$_repo8" get_test_line_number "tests/nofile.sh" "test_foo")
assert_eq "missing file returns -1" "-1" "$_line8"
rm -rf "$_repo8"

# Test: word-boundary: test_foo doesn't match test_foobar
_tf9=$(make_temp_file)
cat > "$_tf9" <<'EOF'
#!/usr/bin/env bash
test_foobar() { echo pass; }
test_foo() { echo fail; }
EOF
_repo9=$(make_temp_dir)
mkdir -p "$_repo9/tests"
_rel9="tests/mytest.sh"
cp "$_tf9" "$_repo9/$_rel9"
_line9=$(REPO_ROOT="$_repo9" get_test_line_number "$_rel9" "test_foo")
assert_eq "word-boundary: test_foo on line 3, not line 1" "3" "$_line9"
rm -rf "$_repo9" "$_tf9"

# ============================================================
# read_red_markers_by_test_file tests
# ============================================================
echo ""
echo "=== read_red_markers_by_test_file ==="

# Test: basic marker parsing
_repo10=$(make_temp_dir)
cat > "$_repo10/.test-index" <<'EOF'
source/foo.sh: tests/test_foo.sh [test_red_start], tests/test_bar.sh
source/bar.sh: tests/test_baz.sh [test_baz_red]
source/qux.sh: tests/test_qux.sh
EOF
declare -A _markers10=()
REPO_ROOT="$_repo10" read_red_markers_by_test_file _markers10
assert_eq "test_foo.sh has marker test_red_start" "test_red_start" "${_markers10[tests/test_foo.sh]:-}"
assert_eq "test_bar.sh has no marker" "" "${_markers10[tests/test_bar.sh]:-}"
assert_eq "test_baz.sh has marker test_baz_red" "test_baz_red" "${_markers10[tests/test_baz.sh]:-}"
assert_eq "test_qux.sh has no marker" "" "${_markers10[tests/test_qux.sh]:-}"
rm -rf "$_repo10"

# Test: no .test-index → empty result (no error)
_repo11=$(make_temp_dir)
declare -A _markers11=()
REPO_ROOT="$_repo11" read_red_markers_by_test_file _markers11 2>/dev/null
assert_eq "no .test-index → empty result" "0" "${#_markers11[@]}"
rm -rf "$_repo11"

# Test: comments and blank lines are skipped
_repo12=$(make_temp_dir)
cat > "$_repo12/.test-index" <<'EOF'
# This is a comment
source/alpha.sh: tests/test_alpha.sh [test_alpha_red]

# Another comment
source/beta.sh: tests/test_beta.sh
EOF
declare -A _markers12=()
REPO_ROOT="$_repo12" read_red_markers_by_test_file _markers12
assert_eq "alpha marker parsed from non-comment line" "test_alpha_red" "${_markers12[tests/test_alpha.sh]:-}"
assert_eq "beta has no marker" "" "${_markers12[tests/test_beta.sh]:-}"
rm -rf "$_repo12"

# Test: multiple sources mapping to same test file — last non-empty marker wins
_repo13=$(make_temp_dir)
cat > "$_repo13/.test-index" <<'EOF'
source/a.sh: tests/shared_test.sh [marker_from_a]
source/b.sh: tests/shared_test.sh
EOF
declare -A _markers13=()
REPO_ROOT="$_repo13" read_red_markers_by_test_file _markers13
# Per the Bug A fix logic: non-empty marker must not be overwritten by empty
# The result should be marker_from_a (first non-empty wins)
assert_eq "shared test retains non-empty marker" "marker_from_a" "${_markers13[tests/shared_test.sh]:-}"
rm -rf "$_repo13"

# ============================================================
# read_red_markers_by_test_file — 20+ entries per line
# ============================================================
echo ""
echo "=== read_red_markers_by_test_file: 20+ entries per line ==="

# Test: 22 entries on one line, marker at middle position (entry 11)
_repo14=$(make_temp_dir)
_index14="$_repo14/.test-index"
_line14="source/big.sh:"
for _i in $(seq 1 10); do
    _line14="${_line14} tests/test_big_${_i}.sh,"
done
_line14="${_line14} tests/test_big_11.sh [marker_at_11],"
for _i in $(seq 12 22); do
    _line14="${_line14} tests/test_big_${_i}.sh,"
done
_line14="${_line14%,}"
printf '%s\n' "$_line14" > "$_index14"

declare -A _markers14=()
REPO_ROOT="$_repo14" read_red_markers_by_test_file _markers14
assert_eq "22 entries: marker at position 11 is found" "marker_at_11" "${_markers14[tests/test_big_11.sh]:-}"
assert_eq "22 entries: total entry count is 22" "22" "${#_markers14[@]}"
assert_eq "22 entries: entry before marker has no marker" "" "${_markers14[tests/test_big_10.sh]:-}"
assert_eq "22 entries: entry after marker has no marker" "" "${_markers14[tests/test_big_12.sh]:-}"
rm -rf "$_repo14"

# Test: 22 entries on one line, marker at LAST position (entry 22)
_repo15=$(make_temp_dir)
_index15="$_repo15/.test-index"
_line15="source/big.sh:"
for _i in $(seq 1 21); do
    _line15="${_line15} tests/test_big_${_i}.sh,"
done
_line15="${_line15} tests/test_big_22.sh [marker_at_last]"
printf '%s\n' "$_line15" > "$_index15"

declare -A _markers15=()
REPO_ROOT="$_repo15" read_red_markers_by_test_file _markers15
assert_eq "22 entries: marker at last position is found" "marker_at_last" "${_markers15[tests/test_big_22.sh]:-}"
assert_eq "22 entries (last marker): total count is 22" "22" "${#_markers15[@]}"
rm -rf "$_repo15"

# Test: 22 entries on one line, marker at FIRST position (entry 1)
_repo16=$(make_temp_dir)
_index16="$_repo16/.test-index"
_line16="source/big.sh: tests/test_big_1.sh [marker_at_first]"
for _i in $(seq 2 22); do
    _line16="${_line16}, tests/test_big_${_i}.sh"
done
printf '%s\n' "$_line16" > "$_index16"

declare -A _markers16=()
REPO_ROOT="$_repo16" read_red_markers_by_test_file _markers16
assert_eq "22 entries: marker at first position is found" "marker_at_first" "${_markers16[tests/test_big_1.sh]:-}"
assert_eq "22 entries (first marker): total count is 22" "22" "${#_markers16[@]}"
assert_eq "22 entries (first marker): entry 22 has no marker" "" "${_markers16[tests/test_big_22.sh]:-}"
rm -rf "$_repo16"

# Test: calling read_red_markers_by_test_file with 20+ entries must not
# clobber a `parts` variable in the caller's scope.
# Before the fix (adding `local parts` to the function), `parts` and `part`
# would be set to the values from the LAST iteration inside the function.
_repo17=$(make_temp_dir)
_line17="source/big.sh:"
for _i in $(seq 1 20); do
    _line17="${_line17} tests/test_big_${_i}.sh,"
done
_line17="${_line17} tests/test_big_21.sh [no_clobber_marker]"
printf '%s\n' "$_line17" > "$_repo17/.test-index"

# Set caller-scoped parts and part before the call
parts=("caller_part1" "caller_part2" "caller_part3")
part="caller_part_value"
declare -A _markers17=()
REPO_ROOT="$_repo17" read_red_markers_by_test_file _markers17
assert_eq "no clobber: marker still found after call" "no_clobber_marker" "${_markers17[tests/test_big_21.sh]:-}"
assert_eq "no clobber: caller parts array not modified by function" "3" "${#parts[@]}"
assert_eq "no clobber: caller part variable not modified by function" "caller_part_value" "$part"
rm -rf "$_repo17"

# ============================================================
print_summary
