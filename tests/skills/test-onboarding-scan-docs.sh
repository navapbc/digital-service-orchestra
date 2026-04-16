#!/usr/bin/env bash
# tests/skills/test-onboarding-scan-docs.sh
# Behavioral tests for the scan-docs.sh helper script's file-type guard.
#
# Tests:
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
    # Use a filename with no skip-indicator keywords (skip/large/too) to avoid
    # false-positive grep matches when the file name appears in facts JSON output.
    local large_file="$tmpdir/project_overview.md"

    # Create a file that is exactly 600KB (> 500KB limit)
    dd if=/dev/zero bs=1024 count=600 2>/dev/null | tr '\0' 'a' > "$large_file"

    local stdout_out stderr_out
    stdout_out=$(bash "$SCAN_DOCS_SH" "$tmpdir" 2>/tmp/scan_docs_large_stderr_$$ || true)
    stderr_out=$(cat /tmp/scan_docs_large_stderr_$$ 2>/dev/null || true)
    rm -f /tmp/scan_docs_large_stderr_$$

    rm -rf "$tmpdir"

    # The skip must be reported in stderr (SKIP:size <filename>) OR
    # in the skipped array of the stdout JSON.
    local result="rejected"
    local skipped_in_stderr=0
    local skipped_in_json=0
    echo "$stderr_out" | grep -qi "skip" && skipped_in_stderr=1
    echo "$stdout_out" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read() or '{}')
skipped = data.get('skipped', [])
sys.exit(0 if any('size' in str(s) for s in skipped) else 1)
" 2>/dev/null && skipped_in_json=1
    if [[ "$skipped_in_stderr" -eq 0 && "$skipped_in_json" -eq 0 ]]; then
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

# test_extracts_app_name_from_text: scan-docs.sh must extract app_name from text content.
# Given a text file containing "App name: MyApp", the output facts array must include
# an entry with key="app_name", value="MyApp", confidence="high".
# RED: fails until text extraction logic is implemented in scan-docs.sh.
test_extracts_app_name_from_text() {
    _snapshot_fail
    if [[ ! -x "$SCAN_DOCS_SH" ]]; then
        assert_eq "test_extracts_app_name_from_text" \
            "scan-docs.sh exists and is executable" \
            "scan-docs.sh not found at $SCAN_DOCS_SH"
        assert_pass_if_clean "test_extracts_app_name_from_text"
        return
    fi

    local tmpdir
    tmpdir=$(_make_test_dir)
    local text_file="$tmpdir/readme.txt"
    printf "App name: MyApp\nThis is the main application.\n" > "$text_file"

    local output
    output=$(bash "$SCAN_DOCS_SH" "$tmpdir" 2>/dev/null || true)

    rm -rf "$tmpdir"

    # The facts array must contain an entry with key=app_name, value=MyApp, confidence=high
    local found_key found_value found_confidence
    found_key=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
facts = data.get('facts', [])
for f in facts:
    if isinstance(f, dict) and f.get('key') == 'app_name':
        print('found')
        break
" "$output" 2>/dev/null || echo "not-found")

    found_value=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
facts = data.get('facts', [])
for f in facts:
    if isinstance(f, dict) and f.get('key') == 'app_name' and f.get('value') == 'MyApp':
        print('found')
        break
" "$output" 2>/dev/null || echo "not-found")

    found_confidence=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
facts = data.get('facts', [])
for f in facts:
    if isinstance(f, dict) and f.get('key') == 'app_name' and f.get('confidence') == 'high':
        print('found')
        break
" "$output" 2>/dev/null || echo "not-found")

    assert_eq "test_extracts_app_name_from_text: key=app_name" "found" "$found_key"
    assert_eq "test_extracts_app_name_from_text: value=MyApp" "found" "$found_value"
    assert_eq "test_extracts_app_name_from_text: confidence=high" "found" "$found_confidence"
    assert_pass_if_clean "test_extracts_app_name_from_text"
}

# test_extracts_stack_signal: scan-docs.sh must extract stack signals from text content.
# Given a text file containing "Built with React and Node.js", the output facts array must
# contain an entry with key="stack" and value mentioning "react" or "node" (case-insensitive).
# RED: fails until stack extraction logic is implemented in scan-docs.sh.
test_extracts_stack_signal() {
    _snapshot_fail
    if [[ ! -x "$SCAN_DOCS_SH" ]]; then
        assert_eq "test_extracts_stack_signal" \
            "scan-docs.sh exists and is executable" \
            "scan-docs.sh not found at $SCAN_DOCS_SH"
        assert_pass_if_clean "test_extracts_stack_signal"
        return
    fi

    local tmpdir
    tmpdir=$(_make_test_dir)
    local text_file="$tmpdir/tech-stack.txt"
    printf "Built with React and Node.js\nDeployed via Docker containers.\n" > "$text_file"

    local output
    output=$(bash "$SCAN_DOCS_SH" "$tmpdir" 2>/dev/null || true)

    rm -rf "$tmpdir"

    # The facts array must contain an entry with key=stack and value mentioning react or node
    local found_stack
    found_stack=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
facts = data.get('facts', [])
for f in facts:
    if isinstance(f, dict) and f.get('key') == 'stack':
        val = str(f.get('value', '')).lower()
        if 'react' in val or 'node' in val:
            print('found')
            break
" "$output" 2>/dev/null || echo "not-found")

    assert_eq "test_extracts_stack_signal: stack with react or node" "found" "$found_stack"
    assert_pass_if_clean "test_extracts_stack_signal"
}

# test_extracts_wcag_level: scan-docs.sh must extract WCAG compliance level from text content.
# Given a text file containing "WCAG AA compliance required", the output facts array must
# include an entry with key="wcag_level", value="AA", confidence="high".
# RED: fails until WCAG extraction logic is implemented in scan-docs.sh.
test_extracts_wcag_level() {
    _snapshot_fail
    if [[ ! -x "$SCAN_DOCS_SH" ]]; then
        assert_eq "test_extracts_wcag_level" \
            "scan-docs.sh exists and is executable" \
            "scan-docs.sh not found at $SCAN_DOCS_SH"
        assert_pass_if_clean "test_extracts_wcag_level"
        return
    fi

    local tmpdir
    tmpdir=$(_make_test_dir)
    local text_file="$tmpdir/accessibility.txt"
    printf "WCAG AA compliance required\nAll components must meet accessibility standards.\n" > "$text_file"

    local output
    output=$(bash "$SCAN_DOCS_SH" "$tmpdir" 2>/dev/null || true)

    rm -rf "$tmpdir"

    # The facts array must contain key=wcag_level, value=AA, confidence=high
    local found_key found_value found_confidence
    found_key=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
facts = data.get('facts', [])
for f in facts:
    if isinstance(f, dict) and f.get('key') == 'wcag_level':
        print('found')
        break
" "$output" 2>/dev/null || echo "not-found")

    found_value=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
facts = data.get('facts', [])
for f in facts:
    if isinstance(f, dict) and f.get('key') == 'wcag_level' and f.get('value') == 'AA':
        print('found')
        break
" "$output" 2>/dev/null || echo "not-found")

    found_confidence=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
facts = data.get('facts', [])
for f in facts:
    if isinstance(f, dict) and f.get('key') == 'wcag_level' and f.get('confidence') == 'high':
        print('found')
        break
" "$output" 2>/dev/null || echo "not-found")

    assert_eq "test_extracts_wcag_level: key=wcag_level" "found" "$found_key"
    assert_eq "test_extracts_wcag_level: value=AA" "found" "$found_value"
    assert_eq "test_extracts_wcag_level: confidence=high" "found" "$found_confidence"
    assert_pass_if_clean "test_extracts_wcag_level"
}

# test_facts_elevate_confidence_context: scan-docs.sh must elevate low-confidence dimensions.
# Given a CONFIDENCE_CONTEXT JSON file with stack:"low" and a text file with "python-poetry stack",
# when scan-docs.sh --context-file=<path> is called, the output must include
# "elevated_dimensions":{"stack":"medium"} (low → medium for partial signal).
# RED: fails until confidence context elevation is implemented in scan-docs.sh.
test_facts_elevate_confidence_context() {
    _snapshot_fail
    if [[ ! -x "$SCAN_DOCS_SH" ]]; then
        assert_eq "test_facts_elevate_confidence_context" \
            "scan-docs.sh exists and is executable" \
            "scan-docs.sh not found at $SCAN_DOCS_SH"
        assert_pass_if_clean "test_facts_elevate_confidence_context"
        return
    fi

    local tmpdir
    tmpdir=$(_make_test_dir)
    local text_file="$tmpdir/tech.txt"
    local context_file="$tmpdir/confidence_context.json"

    printf "python-poetry stack\nProject uses poetry for dependency management.\n" > "$text_file"
    printf '{"stack":"low","app_name":"unknown","wcag_level":"unknown"}' > "$context_file"

    local output
    output=$(bash "$SCAN_DOCS_SH" "$tmpdir" --context-file="$context_file" 2>/dev/null || true)

    rm -rf "$tmpdir"

    # Output must include elevated_dimensions with stack at medium
    local elevated_stack
    elevated_stack=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
elevated = data.get('elevated_dimensions', {})
if elevated.get('stack') == 'medium':
    print('found')
else:
    print('not-found')
" "$output" 2>/dev/null || echo "not-found")

    assert_eq "test_facts_elevate_confidence_context: stack elevated to medium" "found" "$elevated_stack"
    assert_pass_if_clean "test_facts_elevate_confidence_context"
}

# test_confidence_never_lowered: scan-docs.sh must never lower already-high confidence.
# Given a CONFIDENCE_CONTEXT JSON file with stack:"high" and a conflicting/ambiguous doc,
# when scan-docs.sh --context-file=<path> is called, the output must NOT downgrade stack.
# Stack remains at "high" in elevated_dimensions (or is absent from elevated_dimensions,
# meaning no change occurred — but it must not appear as lower than high).
# RED: fails until confidence context handling is implemented in scan-docs.sh.
test_confidence_never_lowered() {
    _snapshot_fail
    if [[ ! -x "$SCAN_DOCS_SH" ]]; then
        assert_eq "test_confidence_never_lowered" \
            "scan-docs.sh exists and is executable" \
            "scan-docs.sh not found at $SCAN_DOCS_SH"
        assert_pass_if_clean "test_confidence_never_lowered"
        return
    fi

    local tmpdir
    tmpdir=$(_make_test_dir)
    local text_file="$tmpdir/conflicting.txt"
    local context_file="$tmpdir/confidence_context.json"

    # Conflicting/ambiguous content that mentions multiple stacks
    printf "Maybe python, maybe java, maybe something else entirely.\n" > "$text_file"
    printf '{"stack":"high","app_name":"unknown","wcag_level":"unknown"}' > "$context_file"

    local output
    output=$(bash "$SCAN_DOCS_SH" "$tmpdir" --context-file="$context_file" 2>/dev/null || true)

    rm -rf "$tmpdir"

    # elevated_dimensions must NOT show stack at low or medium (can be high or absent)
    local stack_not_lowered
    stack_not_lowered=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
elevated = data.get('elevated_dimensions', {})
stack_val = elevated.get('stack', None)
# stack should not be downgraded — it's okay if absent or still high
if stack_val is None or stack_val == 'high':
    print('not-lowered')
else:
    print('lowered-to:' + str(stack_val))
" "$output" 2>/dev/null || echo "not-lowered")

    assert_eq "test_confidence_never_lowered: stack not downgraded from high" "not-lowered" "$stack_not_lowered"
    assert_pass_if_clean "test_confidence_never_lowered"
}

# Run all tests
test_scan_docs_rejects_binary
test_scan_docs_rejects_large_files
test_scan_docs_rejects_path_traversal
test_scan_docs_logs_skips
test_extracts_app_name_from_text
test_extracts_stack_signal
test_extracts_wcag_level
test_facts_elevate_confidence_context
test_confidence_never_lowered

# ── Bug 83b5-c9c6: set -euo pipefail (not -uo) ────────────────────────────
# Verifies that scan-docs.sh uses set -euo pipefail so unhandled command
# failures don't pass silently. Without -e, errors in subshells and pipeline
# steps are swallowed, producing silent wrong output.
test_scan_docs_uses_set_euo_pipefail() {
    _snapshot_fail
    local found="missing"
    if grep -q "set -euo pipefail" "$SCAN_DOCS_SH" 2>/dev/null; then
        found="found"
    fi
    assert_eq "test_scan_docs_uses_set_euo_pipefail: set -euo pipefail present" "found" "$found"
    assert_pass_if_clean "test_scan_docs_uses_set_euo_pipefail"
}
test_scan_docs_uses_set_euo_pipefail

# ── Bug 849d-bdeb: no grep -qP (not portable on macOS BSD grep) ───────────
# Verifies that scan-docs.sh does not use grep -qP (Perl regex) which is
# unavailable on macOS BSD grep. The binary detection fallback must use
# portable alternatives (tr/wc) instead.
test_scan_docs_no_grep_perl_flag() {
    _snapshot_fail
    local found="absent"
    # Exclude comment lines before checking — comments may reference grep -qP to explain avoidance
    if grep -vE "^\s*#" "$SCAN_DOCS_SH" 2>/dev/null | grep -qE "grep -[a-zA-Z]*P"; then
        found="present"
    fi
    assert_eq "test_scan_docs_no_grep_perl_flag: no grep -P in scan-docs.sh" "absent" "$found"
    assert_pass_if_clean "test_scan_docs_no_grep_perl_flag"
}
test_scan_docs_no_grep_perl_flag

print_summary
