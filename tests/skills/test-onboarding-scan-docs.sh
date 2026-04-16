#!/usr/bin/env bash
# tests/skills/test-onboarding-scan-docs.sh
# Behavioral tests for the scan-docs.sh helper script's file-type guard.
#
# Tests (RED — fail until plugins/dso/skills/onboarding/scan-docs.sh is created):
#   test_scan_docs_rejects_binary: script skips binary files (non-UTF8)
#   test_scan_docs_rejects_large_files: script skips files > 500KB
#   test_scan_docs_rejects_path_traversal: script rejects paths with ../
#   test_scan_docs_logs_skips: script logs skip reason when skipping
#
# Story: 5e33-60aa
# Task: e0bc-1331
#
# Usage: bash tests/skills/test-onboarding-scan-docs.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCAN_DOCS_SH="$DSO_PLUGIN_DIR/skills/onboarding/scan-docs.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-onboarding-scan-docs.sh ==="

# Helper: create a temp directory with test fixtures, echo the path
_make_test_dir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    echo "$tmpdir"
}

# test_scan_docs_rejects_binary: scan-docs.sh must skip binary (non-UTF8) files.
# Creates a temp binary file, passes it to scan-docs.sh, and verifies it does NOT
# appear in the output (i.e., the file is skipped, not scanned).
test_scan_docs_rejects_binary() {
    _snapshot_fail
    # If scan-docs.sh doesn't exist yet, the test fails RED immediately.
    if [[ ! -x "$SCAN_DOCS_SH" ]]; then
        assert_eq "test_scan_docs_rejects_binary" \
            "scan-docs.sh exists and is executable" \
            "scan-docs.sh not found at $SCAN_DOCS_SH"
        assert_pass_if_clean "test_scan_docs_rejects_binary"
        return
    fi

    local tmpdir
    tmpdir=$(_make_test_dir)
    local binary_file="$tmpdir/binary_file.bin"

    # Write bytes that are not valid UTF-8
    printf '\x80\x81\x82\x83' > "$binary_file"

    # Run scan-docs.sh against the temp dir; capture output
    local output
    output=$(bash "$SCAN_DOCS_SH" "$tmpdir" 2>&1 || true)

    rm -rf "$tmpdir"

    # The binary file name must NOT appear as scanned content in output
    local result="rejected"
    if echo "$output" | grep -q "binary_file.bin" && \
       ! echo "$output" | grep -qi "skip"; then
        result="not-rejected"
    fi

    assert_eq "test_scan_docs_rejects_binary" "rejected" "$result"
    assert_pass_if_clean "test_scan_docs_rejects_binary"
}

# test_scan_docs_rejects_large_files: scan-docs.sh must skip files larger than 500KB.
# Creates a 600KB file, passes it to scan-docs.sh, and verifies it is skipped.
test_scan_docs_rejects_large_files() {
    _snapshot_fail
    if [[ ! -x "$SCAN_DOCS_SH" ]]; then
        assert_eq "test_scan_docs_rejects_large_files" \
            "scan-docs.sh exists and is executable" \
            "scan-docs.sh not found at $SCAN_DOCS_SH"
        assert_pass_if_clean "test_scan_docs_rejects_large_files"
        return
    fi

    local tmpdir
    tmpdir=$(_make_test_dir)
    local large_file="$tmpdir/large_doc.md"

    # Create a file that is exactly 600KB (> 500KB limit)
    dd if=/dev/zero bs=1024 count=600 2>/dev/null | tr '\0' 'a' > "$large_file"

    local output
    output=$(bash "$SCAN_DOCS_SH" "$tmpdir" 2>&1 || true)

    rm -rf "$tmpdir"

    # large_doc.md must appear in the output as skipped, not as scanned content
    local result="rejected"
    if echo "$output" | grep -q "large_doc.md" && \
       ! echo "$output" | grep -qi "skip\|too large\|large"; then
        result="not-rejected"
    fi

    assert_eq "test_scan_docs_rejects_large_files" "rejected" "$result"
    assert_pass_if_clean "test_scan_docs_rejects_large_files"
}

# test_scan_docs_rejects_path_traversal: scan-docs.sh must reject paths containing ../.
# Passes a path argument with ../ to scan-docs.sh and verifies it exits non-zero
# or prints an error/skip message.
test_scan_docs_rejects_path_traversal() {
    _snapshot_fail
    if [[ ! -x "$SCAN_DOCS_SH" ]]; then
        assert_eq "test_scan_docs_rejects_path_traversal" \
            "scan-docs.sh exists and is executable" \
            "scan-docs.sh not found at $SCAN_DOCS_SH"
        assert_pass_if_clean "test_scan_docs_rejects_path_traversal"
        return
    fi

    # Run with a path-traversal argument; expect non-zero exit or error output
    local output exit_code
    output=$(bash "$SCAN_DOCS_SH" "../traversal-attempt" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    local result="rejected"
    # Accept either: non-zero exit, or error/skip message in output
    if [[ "$exit_code" -eq 0 ]] && \
       ! echo "$output" | grep -qiE "error|reject|invalid|skip|traversal|not allowed|denied"; then
        result="not-rejected"
    fi

    assert_eq "test_scan_docs_rejects_path_traversal" "rejected" "$result"
    assert_pass_if_clean "test_scan_docs_rejects_path_traversal"
}

# test_scan_docs_logs_skips: scan-docs.sh must emit a log/skip message when it skips a file.
# Creates a binary file, runs scan-docs.sh, and checks that the output contains
# a skip-related message (e.g., "skip", "skipping", "binary", "too large", etc.)
test_scan_docs_logs_skips() {
    _snapshot_fail
    if [[ ! -x "$SCAN_DOCS_SH" ]]; then
        assert_eq "test_scan_docs_logs_skips" \
            "scan-docs.sh exists and is executable" \
            "scan-docs.sh not found at $SCAN_DOCS_SH"
        assert_pass_if_clean "test_scan_docs_logs_skips"
        return
    fi

    local tmpdir
    tmpdir=$(_make_test_dir)
    local binary_file="$tmpdir/should_be_skipped.bin"

    # Write bytes that are not valid UTF-8
    printf '\x80\x81\x82\x83' > "$binary_file"

    # Capture both stdout and stderr
    local output
    output=$(bash "$SCAN_DOCS_SH" "$tmpdir" 2>&1 || true)

    rm -rf "$tmpdir"

    # Output must contain a skip-related keyword
    local result="logs-skips"
    if ! echo "$output" | grep -qiE "skip|skipping|binary|not utf|non-utf|ignored|omit"; then
        result="no-skip-logged"
    fi

    assert_eq "test_scan_docs_logs_skips" "logs-skips" "$result"
    assert_pass_if_clean "test_scan_docs_logs_skips"
}

# Run all tests
test_scan_docs_rejects_binary
test_scan_docs_rejects_large_files
test_scan_docs_rejects_path_traversal
test_scan_docs_logs_skips

print_summary
