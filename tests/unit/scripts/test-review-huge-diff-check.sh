#!/usr/bin/env bash
# tests/unit/scripts/test-review-huge-diff-check.sh
# TDD RED tests for plugins/dso/scripts/review-huge-diff-check.sh
#
# Tests verify the huge-diff threshold check script:
#   1. Exits 2 when file count is above the configured threshold
#   2. Exits 2 when file count equals the threshold (inclusive boundary)
#   3. Exits 0 when file count is below the threshold
#   4. Exits 1 with stderr when threshold is configured as 0 (invalid)
#   5. Exits 1 with stderr when threshold is configured as negative (invalid)
#   6. Excludes .test-index from the file count (exits 0 when net count is below threshold)
#
# All tests fail in RED phase because the script does not exist yet.
#
# Approach: inject mock `git` and `read-config.sh` binaries via PATH manipulation;
# assert on exit codes and stderr output.
#
# Usage: bash tests/unit/scripts/test-review-huge-diff-check.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SCRIPT_UNDER_TEST="$REPO_ROOT/plugins/dso/scripts/review-huge-diff-check.sh"

PASS=0
FAIL=0

echo "=== test-review-huge-diff-check.sh ==="

# ── Mock helpers ──────────────────────────────────────────────────────────────

# _setup_mock_dir <git_file_list> <threshold>
# Creates a temp dir containing mock `git` and `read-config.sh` on PATH.
# Returns the temp dir path via stdout.
_setup_mock_dir() {
    local file_list="$1"
    local threshold="$2"
    local tmpdir
    tmpdir="$(mktemp -d)"

    # Mock git: responds to `diff --name-only` with the supplied file list
    cat > "$tmpdir/git" <<MOCK
#!/usr/bin/env bash
if [[ "\$*" == *"diff --name-only"* ]]; then
    printf '%s\n' ${file_list}
fi
MOCK
    chmod +x "$tmpdir/git"

    # Mock read-config.sh: returns the configured threshold for the relevant key
    cat > "$tmpdir/read-config.sh" <<MOCK
#!/usr/bin/env bash
# Minimal stub: accepts a key argument, returns threshold for the huge_diff key
case "\${1:-}" in
    review.huge_diff_file_threshold) echo "${threshold}" ;;
    *) echo "" ;;
esac
MOCK
    chmod +x "$tmpdir/read-config.sh"

    echo "$tmpdir"
}

# ── Test 1: above threshold → exit 2 ─────────────────────────────────────────

test_huge_diff_check_above_threshold() {
    local tmpdir exit_code
    # 25 distinct files, threshold 20 → 25 > 20 → should exit 2
    local files
    files="$(printf 'file%02d.sh ' $(seq 1 25))"
    tmpdir="$(_setup_mock_dir "$files" "20")"
    trap 'rm -rf "$tmpdir"' RETURN

    PATH="$tmpdir:$PATH" bash "$SCRIPT_UNDER_TEST" >/dev/null 2>&1
    exit_code=$?

    if [[ "$exit_code" -eq 2 ]]; then
        (( ++PASS ))
        printf "PASS: test_huge_diff_check_above_threshold\n"
    else
        (( ++FAIL ))
        printf "FAIL: test_huge_diff_check_above_threshold\n  expected exit 2, got %d\n" "$exit_code" >&2
    fi
}

# ── Test 2: at threshold → exit 2 (inclusive boundary) ───────────────────────

test_huge_diff_check_at_threshold() {
    local tmpdir exit_code
    # Exactly 20 files, threshold 20 → 20 >= 20 → should exit 2
    local files
    files="$(printf 'file%02d.sh ' $(seq 1 20))"
    tmpdir="$(_setup_mock_dir "$files" "20")"
    trap 'rm -rf "$tmpdir"' RETURN

    PATH="$tmpdir:$PATH" bash "$SCRIPT_UNDER_TEST" >/dev/null 2>&1
    exit_code=$?

    if [[ "$exit_code" -eq 2 ]]; then
        (( ++PASS ))
        printf "PASS: test_huge_diff_check_at_threshold\n"
    else
        (( ++FAIL ))
        printf "FAIL: test_huge_diff_check_at_threshold\n  expected exit 2, got %d\n" "$exit_code" >&2
    fi
}

# ── Test 3: below threshold → exit 0 ─────────────────────────────────────────

test_huge_diff_check_below_threshold() {
    local tmpdir exit_code
    # 19 files, threshold 20 → 19 < 20 → should exit 0
    local files
    files="$(printf 'file%02d.sh ' $(seq 1 19))"
    tmpdir="$(_setup_mock_dir "$files" "20")"
    trap 'rm -rf "$tmpdir"' RETURN

    PATH="$tmpdir:$PATH" bash "$SCRIPT_UNDER_TEST" >/dev/null 2>&1
    exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        (( ++PASS ))
        printf "PASS: test_huge_diff_check_below_threshold\n"
    else
        (( ++FAIL ))
        printf "FAIL: test_huge_diff_check_below_threshold\n  expected exit 0, got %d\n" "$exit_code" >&2
    fi
}

# ── Test 4: threshold=0 → exit 1 with stderr ─────────────────────────────────

test_huge_diff_check_invalid_zero_threshold() {
    local tmpdir exit_code stderr_out
    # threshold=0 is invalid → should exit 1 and write to stderr
    local files
    files="$(printf 'file%02d.sh ' $(seq 1 5))"
    tmpdir="$(_setup_mock_dir "$files" "0")"
    trap 'rm -rf "$tmpdir"' RETURN

    stderr_out="$(PATH="$tmpdir:$PATH" bash "$SCRIPT_UNDER_TEST" 2>&1 >/dev/null)"
    exit_code=$?

    local ok=1
    if [[ "$exit_code" -ne 1 ]]; then
        ok=0
        printf "FAIL: test_huge_diff_check_invalid_zero_threshold\n  expected exit 1, got %d\n" "$exit_code" >&2
    fi
    if [[ -z "$stderr_out" ]]; then
        ok=0
        printf "FAIL: test_huge_diff_check_invalid_zero_threshold\n  expected non-empty stderr for invalid threshold=0\n" >&2
    fi
    if [[ "$ok" -eq 1 ]]; then
        (( ++PASS ))
        printf "PASS: test_huge_diff_check_invalid_zero_threshold\n"
    else
        (( ++FAIL ))
    fi
}

# ── Test 5: threshold=-5 → exit 1 with stderr ────────────────────────────────

test_huge_diff_check_invalid_negative_threshold() {
    local tmpdir exit_code stderr_out
    # threshold=-5 is invalid → should exit 1 and write to stderr
    local files
    files="$(printf 'file%02d.sh ' $(seq 1 5))"
    tmpdir="$(_setup_mock_dir "$files" "-5")"
    trap 'rm -rf "$tmpdir"' RETURN

    stderr_out="$(PATH="$tmpdir:$PATH" bash "$SCRIPT_UNDER_TEST" 2>&1 >/dev/null)"
    exit_code=$?

    local ok=1
    if [[ "$exit_code" -ne 1 ]]; then
        ok=0
        printf "FAIL: test_huge_diff_check_invalid_negative_threshold\n  expected exit 1, got %d\n" "$exit_code" >&2
    fi
    if [[ -z "$stderr_out" ]]; then
        ok=0
        printf "FAIL: test_huge_diff_check_invalid_negative_threshold\n  expected non-empty stderr for invalid threshold=-5\n" >&2
    fi
    if [[ "$ok" -eq 1 ]]; then
        (( ++PASS ))
        printf "PASS: test_huge_diff_check_invalid_negative_threshold\n"
    else
        (( ++FAIL ))
    fi
}

# ── Test 6: .test-index excluded from count ───────────────────────────────────

test_huge_diff_check_excludes_test_index() {
    local tmpdir exit_code
    # 19 regular files + .test-index = 20 raw, but .test-index is excluded
    # Net count = 19 < threshold 20 → should exit 0
    local files
    files="$(printf 'file%02d.sh ' $(seq 1 19)) .test-index"
    tmpdir="$(_setup_mock_dir "$files" "20")"
    trap 'rm -rf "$tmpdir"' RETURN

    PATH="$tmpdir:$PATH" bash "$SCRIPT_UNDER_TEST" >/dev/null 2>&1
    exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        (( ++PASS ))
        printf "PASS: test_huge_diff_check_excludes_test_index\n"
    else
        (( ++FAIL ))
        printf "FAIL: test_huge_diff_check_excludes_test_index\n  expected exit 0 (net 19 files after .test-index exclusion), got %d\n" "$exit_code" >&2
    fi
}

# ── Run all tests ─────────────────────────────────────────────────────────────

test_huge_diff_check_above_threshold
test_huge_diff_check_at_threshold
test_huge_diff_check_below_threshold
test_huge_diff_check_invalid_zero_threshold
test_huge_diff_check_invalid_negative_threshold
test_huge_diff_check_excludes_test_index

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
