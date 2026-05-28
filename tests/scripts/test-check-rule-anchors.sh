#!/usr/bin/env bash
# shellcheck disable=SC2016
# Rationale: this test file uses single-quoted strings containing literal
# backticks (e.g., 'See CLAUDE.md `rule:fabrication`...') as test fixture
# content. Single quotes are deliberate — the backticks are literal characters
# the test writes to a target file, NOT command-substitution markers we want
# the shell to evaluate. SC2016 (Expressions don't expand in single quotes) is
# expected and desired here.
#
# tests/scripts/test-check-rule-anchors.sh
# Behavioral tests for plugins/dso/scripts/check-rule-anchors.sh
#
# Tests cover (positive + negative citation paths against the live CLAUDE.md):
#  - clean target (no citations) -> exit 0
#  - valid backticked citation pointing at a defined anchor -> exit 0
#  - invalid backticked citation pointing at undefined anchor -> exit 1
#  - field-name false-positive guard (e.g., "file:line:rule:message") -> exit 0 (not flagged)
#  - mixed valid + invalid -> exit 1 with the invalid one named in stderr
#  - invariant: and always: namespace recognition
#
# Not covered (script's exit-2 paths require overriding REPO_ROOT, which is fixed at
# script load): missing CLAUDE.md and empty CLAUDE.md. These are guarded by
# fail-loud asserts inside the script body; the asserts themselves are
# straight-line code unlikely to regress without an obvious diff.
#
# Usage: bash tests/scripts/test-check-rule-anchors.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# testing-mode: GREEN

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/check-rule-anchors.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-rule-anchors.sh ==="

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# Helper: build a synthetic repo layout with a CLAUDE.md + scan target.
# The script computes CLAUDE.md from REPO_ROOT, where REPO_ROOT is two levels above
# the script's location. To exercise the script against synthetic content we point
# it at a target file explicitly (the script accepts files as positional args, and
# its CLAUDE.md lookup still uses the real one). For the CLAUDE.md "missing" /
# "empty" cases we override CLAUDE_PLUGIN_ROOT and use a wrapper that copies a
# stub CLAUDE.md into place. For the rest we just write a target file and pass it
# as an arg.
_make_target_with_content() {
    local _content="$1"
    local _dir
    _dir=$(mktemp -d "${TMPDIR:-/tmp}/test-check-rule-anchors.XXXXXX")
    _CLEANUP_DIRS+=("$_dir")
    printf '%s\n' "$_content" > "$_dir/target.md"
    echo "$_dir/target.md"
}

# ── test_clean_target_exits_0 ─────────────────────────────────────────────────
test_clean_target_exits_0() {
    _snapshot_fail
    local _target
    _target=$(_make_target_with_content "# Some unrelated content with no citations.")
    local rc=0
    bash "$SCRIPT" "$_target" >/dev/null 2>&1 || rc=$?
    assert_eq "test_clean_target_exits_0: exit 0 for target with no citations" "0" "$rc"
    assert_pass_if_clean "test_clean_target_exits_0"
}

# ── test_valid_backticked_citation_exits_0 ────────────────────────────────────
# `rule:fabrication` is a known anchor defined in CLAUDE.md (PR-D anchored Never #8).
test_valid_backticked_citation_exits_0() {
    _snapshot_fail
    local _target
    _target=$(_make_target_with_content 'See CLAUDE.md `rule:fabrication` for the manual-call prohibition.')
    local rc=0
    bash "$SCRIPT" "$_target" >/dev/null 2>&1 || rc=$?
    assert_eq "test_valid_backticked_citation_exits_0: exit 0 for valid backticked citation" "0" "$rc"
    assert_pass_if_clean "test_valid_backticked_citation_exits_0"
}

# ── test_invalid_backticked_citation_exits_1 ──────────────────────────────────
test_invalid_backticked_citation_exits_1() {
    _snapshot_fail
    local _target
    _target=$(_make_target_with_content 'See CLAUDE.md `rule:nonexistent-anchor` for nothing.')
    local rc=0
    bash "$SCRIPT" "$_target" >/dev/null 2>&1 || rc=$?
    assert_eq "test_invalid_backticked_citation_exits_1: exit 1 for nonexistent anchor" "1" "$rc"
    assert_pass_if_clean "test_invalid_backticked_citation_exits_1"
}

# ── test_field_name_false_positive_not_flagged ───────────────────────────────
# Bare "rule:message" in a structured-output field-name string MUST NOT be flagged.
# (This is the bug the audit's R13 found before — too-permissive matching.)
test_field_name_false_positive_not_flagged() {
    _snapshot_fail
    local _target
    _target=$(_make_target_with_content "# Output format: file:line:rule:message (rule and message are field names)")
    local rc=0
    bash "$SCRIPT" "$_target" >/dev/null 2>&1 || rc=$?
    assert_eq "test_field_name_false_positive_not_flagged: exit 0 for bare prefix:slug in non-citation context" "0" "$rc"
    assert_pass_if_clean "test_field_name_false_positive_not_flagged"
}

# ── test_mixed_valid_and_invalid_exits_1 ──────────────────────────────────────
# A target with both a valid and an invalid citation should exit 1 and report the invalid one.
test_mixed_valid_and_invalid_exits_1() {
    _snapshot_fail
    local _target
    _target=$(_make_target_with_content 'Cite `rule:fabrication` (valid) and `rule:nonexistent-totally` (invalid).')
    local stderr_file
    stderr_file=$(mktemp "${TMPDIR:-/tmp}/test-check-rule-anchors-mixed-stderr.XXXXXX")
    local rc=0
    bash "$SCRIPT" "$_target" >/dev/null 2>"$stderr_file" || rc=$?
    local stderr_content
    stderr_content=$(cat "$stderr_file")
    rm -f "$stderr_file"
    assert_eq "test_mixed_valid_and_invalid_exits_1: exit 1 for mixed valid+invalid" "1" "$rc"
    if echo "$stderr_content" | grep -qF "rule:nonexistent-totally"; then
        echo "  PASS: test_mixed_valid_and_invalid_exits_1: stderr names the invalid anchor"
        (( PASS++ ))
    else
        echo "  FAIL: test_mixed_valid_and_invalid_exits_1: stderr did not name the invalid anchor" >&2
        echo "  Actual stderr: $stderr_content" >&2
        (( FAIL++ ))
    fi
    if echo "$stderr_content" | grep -qF "rule:fabrication"; then
        echo "  FAIL: test_mixed_valid_and_invalid_exits_1: stderr incorrectly named the VALID anchor (false positive)" >&2
        (( FAIL++ ))
    else
        echo "  PASS: test_mixed_valid_and_invalid_exits_1: stderr did not name the valid anchor"
        (( PASS++ ))
    fi
    assert_pass_if_clean "test_mixed_valid_and_invalid_exits_1"
}

# ── test_invariant_anchor_recognized ──────────────────────────────────────────
# Anchors use three prefix namespaces: rule, invariant, always. All three should be recognized.
test_invariant_anchor_recognized() {
    _snapshot_fail
    local _target
    _target=$(_make_target_with_content 'See CLAUDE.md `invariant:claude-md-purpose` for the bloat criteria.')
    local rc=0
    bash "$SCRIPT" "$_target" >/dev/null 2>&1 || rc=$?
    assert_eq "test_invariant_anchor_recognized: exit 0 for valid invariant: citation" "0" "$rc"
    assert_pass_if_clean "test_invariant_anchor_recognized"
}

# ── test_always_anchor_recognized ─────────────────────────────────────────────
test_always_anchor_recognized() {
    _snapshot_fail
    local _target
    _target=$(_make_target_with_content 'See CLAUDE.md `always:test-batched-sh` for the runner-of-record.')
    local rc=0
    bash "$SCRIPT" "$_target" >/dev/null 2>&1 || rc=$?
    assert_eq "test_always_anchor_recognized: exit 0 for valid always: citation" "0" "$rc"
    assert_pass_if_clean "test_always_anchor_recognized"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_clean_target_exits_0
test_valid_backticked_citation_exits_0
test_invalid_backticked_citation_exits_1
test_field_name_false_positive_not_flagged
test_mixed_valid_and_invalid_exits_1
test_invariant_anchor_recognized
test_always_anchor_recognized

print_summary
