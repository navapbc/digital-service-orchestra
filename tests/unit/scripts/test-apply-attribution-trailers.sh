#!/usr/bin/env bash
# tests/unit/scripts/test-apply-attribution-trailers.sh
# Behavioral RED tests for plugins/dso/scripts/apply-attribution-trailers.sh
#
# Tests verify observable behavior:
#   1. read_and_deduplicate returns a single value for duplicate agent entries
#   2. read_and_deduplicate preserves two distinct agent types
#   3. check_git_version stub returns 0 for any version
#
# These tests are RED — the target script does not exist yet.
# Once apply-attribution-trailers.sh is implemented, they should turn GREEN.
#
# Usage: bash tests/unit/scripts/test-apply-attribution-trailers.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/apply-attribution-trailers.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-apply-attribution-trailers.sh ==="

# ── Git version guard ─────────────────────────────────────────────────────────
# interpret-trailers requires git >= 2.6. Skip if unavailable.
_GIT_BIN="${GIT_BINARY:-git}"
_git_version_ok() {
    local ver
    ver="$("$_GIT_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+'| head -1)"
    local major minor
    major="${ver%%.*}"
    minor="${ver#*.}"
    minor="${minor%%.*}"
    [[ "$major" -gt 2 || ( "$major" -eq 2 && "$minor" -ge 6 ) ]]
}

if ! _git_version_ok; then
    echo "SKIP: git interpret-trailers requires git >= 2.6; found $("$_GIT_BIN" --version). Skipping all tests."
    exit 0
fi

# ── Temp dir management ───────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]+"${_TEST_TMPDIRS[@]}"}"; do
        rm -rf "$d"
    done
}
trap '_cleanup_tmpdirs' EXIT

_make_tmpdir() {
    local d
    d="$(mktemp -d)"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Helper: write JSONL to a temp file ───────────────────────────────────────
_make_jsonl_file() {
    # Arguments: one JSON object per argument, each on its own line
    local tmpdir; tmpdir="$(_make_tmpdir)"
    local f="$tmpdir/input.jsonl"
    for line in "$@"; do
        printf '%s\n' "$line" >> "$f"
    done
    echo "$f"
}

# ── Test 1: read_and_deduplicate returns single value for duplicate agents ────

test_read_and_deduplicate_returns_single_value_for_duplicate_agents() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_read_and_deduplicate_returns_single_value_for_duplicate_agents\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_read_and_deduplicate_returns_single_value_for_duplicate_agents"
        return
    fi

    # Two identical agent entries — read_and_deduplicate should collapse to one
    local jsonl_file
    jsonl_file="$(_make_jsonl_file \
        '{"type":"agent","subagent_type":"dso:red-test-writer","model":"sonnet"}' \
        '{"type":"agent","subagent_type":"dso:red-test-writer","model":"sonnet"}')"

    # Source the script to bring read_and_deduplicate into scope
    # shellcheck disable=SC1090
    source "$SCRIPT"

    local output
    output="$(read_and_deduplicate "$jsonl_file")"

    # Count how many times the subagent_type appears in output
    local count=0
    while IFS= read -r line; do
        [[ "$line" == *"dso:red-test-writer"* ]] && (( ++count ))
    done <<< "$output"

    assert_eq "dedup: dso:red-test-writer appears exactly once" "1" "$count"

    assert_pass_if_clean "test_read_and_deduplicate_returns_single_value_for_duplicate_agents"
}

# ── Test 2: read_and_deduplicate preserves two distinct agent types ───────────

test_read_and_deduplicate_preserves_two_distinct_agent_types() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_read_and_deduplicate_preserves_two_distinct_agent_types\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_read_and_deduplicate_preserves_two_distinct_agent_types"
        return
    fi

    local jsonl_file
    jsonl_file="$(_make_jsonl_file \
        '{"type":"agent","subagent_type":"dso:red-test-writer","model":"sonnet"}' \
        '{"type":"agent","subagent_type":"dso:code-reviewer-correctness","model":"sonnet"}')"

    # shellcheck disable=SC1090
    source "$SCRIPT"

    local output
    output="$(read_and_deduplicate "$jsonl_file")"

    # Both distinct subagent_type values must appear in the output
    local has_writer=0 has_reviewer=0
    while IFS= read -r line; do
        [[ "$line" == *"dso:red-test-writer"* ]]            && has_writer=1
        [[ "$line" == *"dso:code-reviewer-correctness"* ]]  && has_reviewer=1
    done <<< "$output"

    assert_eq "distinct agents: dso:red-test-writer present"           "1" "$has_writer"
    assert_eq "distinct agents: dso:code-reviewer-correctness present" "1" "$has_reviewer"

    assert_pass_if_clean "test_read_and_deduplicate_preserves_two_distinct_agent_types"
}

# ── Test 3: check_git_version stub returns 0 ─────────────────────────────────

test_check_git_version_stub_returns_0() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_check_git_version_stub_returns_0\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_check_git_version_stub_returns_0"
        return
    fi

    # shellcheck disable=SC1090
    source "$SCRIPT"

    local exit_code=0
    check_git_version "2.6.0" || exit_code=$?

    assert_eq "check_git_version stub: returns 0 for any version" "0" "$exit_code"

    assert_pass_if_clean "test_check_git_version_stub_returns_0"
}

# ── Test 4: format_trailer_flags produces two flags for two distinct agents ────

test_format_trailer_flags_produces_two_flags_for_two_distinct_agents() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_format_trailer_flags_produces_two_flags_for_two_distinct_agents\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_format_trailer_flags_produces_two_flags_for_two_distinct_agents"
        return
    fi

    # shellcheck disable=SC1090
    source "$SCRIPT"

    if ! declare -f format_trailer_flags > /dev/null 2>&1; then
        (( ++FAIL ))
        printf "FAIL: test_format_trailer_flags_produces_two_flags_for_two_distinct_agents\n  function format_trailer_flags not found in script\n" >&2
        assert_pass_if_clean "test_format_trailer_flags_produces_two_flags_for_two_distinct_agents"
        return
    fi

    local jsonl_file
    jsonl_file="$(_make_jsonl_file \
        '{"type":"agent","subagent_type":"dso:red-test-writer","model":"sonnet"}' \
        '{"type":"agent","subagent_type":"dso:code-reviewer-correctness","model":"sonnet"}')"

    local output
    output="$(format_trailer_flags "$jsonl_file")"

    # Count lines matching ^--trailer 'DSO-Agent:
    local count
    count="$(printf '%s\n' "$output" | grep -c "^--trailer 'DSO-Agent:" || true)"

    assert_eq "format_trailer_flags: two distinct agents produce 2 DSO-Agent trailer flags" "2" "$count"

    assert_pass_if_clean "test_format_trailer_flags_produces_two_flags_for_two_distinct_agents"
}

# ── Test 5: format_trailer_flags produces no flags for empty JSONL ────────────

test_format_trailer_flags_produces_no_flags_for_empty_jsonl() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_format_trailer_flags_produces_no_flags_for_empty_jsonl\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_format_trailer_flags_produces_no_flags_for_empty_jsonl"
        return
    fi

    # shellcheck disable=SC1090
    source "$SCRIPT"

    if ! declare -f format_trailer_flags > /dev/null 2>&1; then
        (( ++FAIL ))
        printf "FAIL: test_format_trailer_flags_produces_no_flags_for_empty_jsonl\n  function format_trailer_flags not found in script\n" >&2
        assert_pass_if_clean "test_format_trailer_flags_produces_no_flags_for_empty_jsonl"
        return
    fi

    local jsonl_file
    jsonl_file="$(_make_jsonl_file)"  # no lines → empty file

    local output
    output="$(format_trailer_flags "$jsonl_file")"

    # Use grep -c . to count non-empty lines (avoids wc -c newline ambiguity)
    local line_count
    line_count="$(printf '%s' "$output" | grep -c . || true)"

    assert_eq "format_trailer_flags: empty JSONL produces 0 output lines" "0" "$line_count"

    assert_pass_if_clean "test_format_trailer_flags_produces_no_flags_for_empty_jsonl"
}

# ── Test 6: format_trailer_flags produces DSO-Skill flags for skill entries ───

test_format_trailer_flags_produces_dso_skill_flags() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_format_trailer_flags_produces_dso_skill_flags\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_format_trailer_flags_produces_dso_skill_flags"
        return
    fi

    # shellcheck disable=SC1090
    source "$SCRIPT"

    if ! declare -f format_trailer_flags > /dev/null 2>&1; then
        (( ++FAIL ))
        printf "FAIL: test_format_trailer_flags_produces_dso_skill_flags\n  function format_trailer_flags not found in script\n" >&2
        assert_pass_if_clean "test_format_trailer_flags_produces_dso_skill_flags"
        return
    fi

    local jsonl_file
    jsonl_file="$(_make_jsonl_file \
        '{"type":"skill","skill_name":"dso:sprint"}')"

    local output
    output="$(format_trailer_flags "$jsonl_file")"

    # Count lines matching ^--trailer 'DSO-Skill:
    local count
    count="$(printf '%s\n' "$output" | grep -c "^--trailer 'DSO-Skill:" || true)"

    assert_eq "format_trailer_flags: skill entry produces 1 DSO-Skill trailer flag" "1" "$count"

    assert_pass_if_clean "test_format_trailer_flags_produces_dso_skill_flags"
}

# ── Test 7: check_git_version fails when git version is 1.9 ──────────────────
# RED: current stub always returns 0; real impl must return non-zero for < 2.6

test_check_git_version_fails_when_version_is_1_9() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_check_git_version_fails_when_version_is_1_9\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_check_git_version_fails_when_version_is_1_9"
        return
    fi

    # Create a mock git binary that reports version 1.9.0
    local _mock_dir
    _mock_dir="$(_make_tmpdir)"
    local _fake_git="$_mock_dir/git"
    printf '#!/bin/bash\necho "git version 1.9.0"\n' > "$_fake_git"
    chmod +x "$_fake_git"

    # Capture stderr to check for TRAILER_SKIPPED
    local _stderr_file
    _stderr_file="$(_make_tmpdir)/stderr.txt"

    # shellcheck disable=SC1090
    source "$SCRIPT"

    local exit_code=0
    GIT_BINARY="$_fake_git" check_git_version "2.6.0" 2>"$_stderr_file" || exit_code=$?

    # Real behavior: must return non-zero for git < 2.6
    local nonzero=0
    [[ "$exit_code" -ne 0 ]] && nonzero=1
    assert_eq "check_git_version 1.9: returns non-zero" "1" "$nonzero"

    # Real behavior: stderr must contain TRAILER_SKIPPED
    local has_trailer_skipped=0
    grep -q "TRAILER_SKIPPED" "$_stderr_file" 2>/dev/null && has_trailer_skipped=1
    assert_eq "check_git_version 1.9: stderr contains TRAILER_SKIPPED" "1" "$has_trailer_skipped"

    assert_pass_if_clean "test_check_git_version_fails_when_version_is_1_9"
}

# ── Test 8: check_git_version passes when git version is 2.6 ─────────────────

test_check_git_version_passes_when_version_is_2_6() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_check_git_version_passes_when_version_is_2_6\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_check_git_version_passes_when_version_is_2_6"
        return
    fi

    local _mock_dir
    _mock_dir="$(_make_tmpdir)"
    local _fake_git="$_mock_dir/git"
    printf '#!/bin/bash\necho "git version 2.6.0"\n' > "$_fake_git"
    chmod +x "$_fake_git"

    # shellcheck disable=SC1090
    source "$SCRIPT"

    local exit_code=0
    GIT_BINARY="$_fake_git" check_git_version "2.6.0" || exit_code=$?

    assert_eq "check_git_version 2.6: returns 0" "0" "$exit_code"

    assert_pass_if_clean "test_check_git_version_passes_when_version_is_2_6"
}

# ── Test 9: check_git_version passes when git version is 2.42 ────────────────

test_check_git_version_passes_when_version_is_2_42() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_check_git_version_passes_when_version_is_2_42\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_check_git_version_passes_when_version_is_2_42"
        return
    fi

    local _mock_dir
    _mock_dir="$(_make_tmpdir)"
    local _fake_git="$_mock_dir/git"
    printf '#!/bin/bash\necho "git version 2.42.0"\n' > "$_fake_git"
    chmod +x "$_fake_git"

    # shellcheck disable=SC1090
    source "$SCRIPT"

    local exit_code=0
    GIT_BINARY="$_fake_git" check_git_version "2.6.0" || exit_code=$?

    assert_eq "check_git_version 2.42: returns 0" "0" "$exit_code"

    assert_pass_if_clean "test_check_git_version_passes_when_version_is_2_42"
}

# ── Test 10: check_git_version passes with vendor suffix (e.g. 2.39.3-1.el9) ─

test_check_git_version_passes_with_vendor_suffix() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_check_git_version_passes_with_vendor_suffix\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_check_git_version_passes_with_vendor_suffix"
        return
    fi

    local _mock_dir
    _mock_dir="$(_make_tmpdir)"
    local _fake_git="$_mock_dir/git"
    printf '#!/bin/bash\necho "git version 2.39.3-1.el9"\n' > "$_fake_git"
    chmod +x "$_fake_git"

    # shellcheck disable=SC1090
    source "$SCRIPT"

    local exit_code=0
    GIT_BINARY="$_fake_git" check_git_version "2.6.0" || exit_code=$?

    assert_eq "check_git_version 2.39.3-1.el9: returns 0" "0" "$exit_code"

    assert_pass_if_clean "test_check_git_version_passes_with_vendor_suffix"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

test_read_and_deduplicate_returns_single_value_for_duplicate_agents
test_read_and_deduplicate_preserves_two_distinct_agent_types
test_check_git_version_stub_returns_0
test_format_trailer_flags_produces_two_flags_for_two_distinct_agents
test_format_trailer_flags_produces_no_flags_for_empty_jsonl
test_format_trailer_flags_produces_dso_skill_flags
test_check_git_version_fails_when_version_is_1_9
test_check_git_version_passes_when_version_is_2_6
test_check_git_version_passes_when_version_is_2_42
test_check_git_version_passes_with_vendor_suffix

print_summary
