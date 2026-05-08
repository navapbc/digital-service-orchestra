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

# ── Run all tests ─────────────────────────────────────────────────────────────

test_read_and_deduplicate_returns_single_value_for_duplicate_agents
test_read_and_deduplicate_preserves_two_distinct_agent_types
test_check_git_version_stub_returns_0

print_summary
