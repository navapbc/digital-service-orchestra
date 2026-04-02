#!/usr/bin/env bash
# tests/scripts/test-check-portability.sh
# Behavioral tests for check-portability.sh — portability lint script that
# detects hardcoded home-directory paths (/Users/<name>/ and /home/<name>/).
#
# Tests:
#  1. test_detects_macos_hardcoded_path  — /Users/testuser/... → exit non-zero  # portability-ok
#  2. test_detects_linux_hardcoded_path  — /home/testuser/...  → exit non-zero  # portability-ok
#  3. test_passes_clean_file             — /usr/bin, /etc only → exit 0
#  4. test_portability_ok_suppression    — path # portability-ok → exit 0
#  5. test_multiple_files_mixed          — one clean, one dirty → exit non-zero, dirty file reported
#  6. test_script_does_not_flag_own_regex — script on itself → exit 0
#
# Usage: bash tests/scripts/test-check-portability.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# REVIEW-DEFENSE: '-e' is intentionally omitted. The test harness captures
# non-zero exit codes from script invocations via || assignment. With '-e',
# expected non-zero exits would abort the script before assertions run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/check-portability.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-portability.sh ==="

_TEST_TMPDIRS=()
_cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap '_cleanup' EXIT

_make_tmpdir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── test_detects_macos_hardcoded_path ─────────────────────────────────────────
# A file containing /Users/testuser/some/path must cause the script to exit  # portability-ok
# non-zero and report the violating file in its output.
test_detects_macos_hardcoded_path() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/macos_path.sh"
    printf '#!/usr/bin/env bash\nCONFIG_DIR=/Users/testuser/some/path/config\n' > "$_file"  # portability-ok
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_ne "test_detects_macos_hardcoded_path: exit non-zero" "0" "$_exit"
    assert_contains "test_detects_macos_hardcoded_path: violating file reported" "macos_path.sh" "$_out"
    assert_pass_if_clean "test_detects_macos_hardcoded_path"
}

# ── test_detects_linux_hardcoded_path ─────────────────────────────────────────
# A file containing /home/testuser/some/path must cause the script to exit  # portability-ok
# non-zero and report the violating file in its output.
test_detects_linux_hardcoded_path() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/linux_path.sh"
    printf '#!/usr/bin/env bash\nDATA_DIR=/home/testuser/data\n' > "$_file"  # portability-ok
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_ne "test_detects_linux_hardcoded_path: exit non-zero" "0" "$_exit"
    assert_contains "test_detects_linux_hardcoded_path: violating file reported" "linux_path.sh" "$_out"
    assert_pass_if_clean "test_detects_linux_hardcoded_path"
}

# ── test_passes_clean_file ─────────────────────────────────────────────────────
# A file with only non-home-directory paths (/usr/bin, /etc) must exit 0.
test_passes_clean_file() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/clean.sh"
    printf '#!/usr/bin/env bash\nPATH=/usr/bin:/usr/local/bin\nCONF=/etc/myapp/config\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_eq "test_passes_clean_file: exit 0" "0" "$_exit"
    assert_pass_if_clean "test_passes_clean_file"
}

# ── test_portability_ok_suppression ───────────────────────────────────────────
# A line with /Users/testuser/path followed by # portability-ok must be
# suppressed — the script must exit 0 for that file.
test_portability_ok_suppression() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/suppressed.sh"
    printf '#!/usr/bin/env bash\nEXAMPLE_PATH=/Users/testuser/example # portability-ok\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_eq "test_portability_ok_suppression: exit 0" "0" "$_exit"
    assert_pass_if_clean "test_portability_ok_suppression"
}

# ── test_multiple_files_mixed ──────────────────────────────────────────────────
# When passed one clean file and one dirty file, the script must exit non-zero
# and report the dirty file (not the clean file) in its output.
test_multiple_files_mixed() {
    _snapshot_fail
    local _dir _clean_file _dirty_file _exit _out
    _dir=$(_make_tmpdir)
    _clean_file="$_dir/clean.sh"
    _dirty_file="$_dir/dirty.sh"
    printf '#!/usr/bin/env bash\necho hello\n' > "$_clean_file"
    printf '#!/usr/bin/env bash\nSRC=/home/devuser/project/src\n' > "$_dirty_file"  # portability-ok
    _exit=0
    _out=$(bash "$SCRIPT" "$_clean_file" "$_dirty_file" 2>&1) || _exit=$?
    assert_ne "test_multiple_files_mixed: exit non-zero" "0" "$_exit"
    assert_contains "test_multiple_files_mixed: dirty file reported" "dirty.sh" "$_out"
    assert_pass_if_clean "test_multiple_files_mixed"
}

# ── test_script_does_not_flag_own_regex ───────────────────────────────────────
# The script itself contains the regex patterns it scans for. Those lines must
# carry # portability-ok so the script does not flag itself when run on its own
# source file.
test_script_does_not_flag_own_regex() {
    _snapshot_fail
    local _exit _out
    _exit=0
    _out=$(bash "$SCRIPT" "$SCRIPT" 2>&1) || _exit=$?
    assert_eq "test_script_does_not_flag_own_regex: exit 0" "0" "$_exit"
    assert_pass_if_clean "test_script_does_not_flag_own_regex"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_detects_macos_hardcoded_path
test_detects_linux_hardcoded_path
test_passes_clean_file
test_portability_ok_suppression
test_multiple_files_mixed
test_script_does_not_flag_own_regex

print_summary
