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

# ── Test 11: resolve_scalar_trailers produces DSO-Task/Story/Epic flags ──────
# RED: resolve_scalar_trailers does not exist yet.

test_resolve_scalar_trailers_produces_task_story_epic_flags() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_resolve_scalar_trailers_produces_task_story_epic_flags\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_resolve_scalar_trailers_produces_task_story_epic_flags"
        return
    fi

    # shellcheck disable=SC1090
    source "$SCRIPT"

    if ! declare -f resolve_scalar_trailers > /dev/null 2>&1; then
        (( ++FAIL ))
        printf "FAIL: test_resolve_scalar_trailers_produces_task_story_epic_flags\n  function resolve_scalar_trailers not found in script\n" >&2
        assert_pass_if_clean "test_resolve_scalar_trailers_produces_task_story_epic_flags"
        return
    fi

    # Set up mock dso CLI in a prepended PATH directory
    local _mock_dir
    _mock_dir="$(_make_tmpdir)"
    mkdir -p "$_mock_dir/bin"
    cat > "$_mock_dir/bin/dso" <<'MOCK'
#!/bin/bash
# Mock dso CLI — returns fixture ticket JSON for any ticket show invocation
echo '{"ticket_id": "1234-abcd", "title": "Mock Task", "type": "task", "parent_id": "5678-efgh", "parent_title": "Mock Story", "parent_type": "story", "grandparent_id": "9abc-0000", "grandparent_title": "Mock Epic", "grandparent_type": "epic"}'
MOCK
    chmod +x "$_mock_dir/bin/dso"

    local _artifacts
    _artifacts="$(_make_tmpdir)"

    local output
    output="$(PATH="$_mock_dir/bin:$PATH" ARTIFACTS_DIR="$_artifacts" DSO_TASK_ID="1234-abcd" resolve_scalar_trailers 2>/dev/null || true)"

    local has_task=0 has_story=0 has_epic=0
    printf '%s\n' "$output" | grep -q "DSO-Task"  && has_task=1
    printf '%s\n' "$output" | grep -q "DSO-Story" && has_story=1
    printf '%s\n' "$output" | grep -q "DSO-Epic"  && has_epic=1

    assert_eq "resolve_scalar_trailers: output contains DSO-Task flag"  "1" "$has_task"
    assert_eq "resolve_scalar_trailers: output contains DSO-Story flag" "1" "$has_story"
    assert_eq "resolve_scalar_trailers: output contains DSO-Epic flag"  "1" "$has_epic"

    assert_pass_if_clean "test_resolve_scalar_trailers_produces_task_story_epic_flags"
}

# ── Test 12: resolve_scalar_trailers produces DSO-Review-Score flag ───────────
# RED: resolve_scalar_trailers does not exist yet.

test_resolve_scalar_trailers_produces_review_score_flag() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_resolve_scalar_trailers_produces_review_score_flag\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_resolve_scalar_trailers_produces_review_score_flag"
        return
    fi

    # shellcheck disable=SC1090
    source "$SCRIPT"

    if ! declare -f resolve_scalar_trailers > /dev/null 2>&1; then
        (( ++FAIL ))
        printf "FAIL: test_resolve_scalar_trailers_produces_review_score_flag\n  function resolve_scalar_trailers not found in script\n" >&2
        assert_pass_if_clean "test_resolve_scalar_trailers_produces_review_score_flag"
        return
    fi

    local _artifacts
    _artifacts="$(_make_tmpdir)"

    # Write a fixture reviewer-findings.json with score fields
    cat > "$_artifacts/reviewer-findings.json" <<'JSON'
{"diff_hash": "abc123", "scores": {"hygiene": 4, "design": 5, "maintainability": 4, "correctness": 5, "verification": 4}, "summary": "ok"}
JSON

    local output
    output="$(ARTIFACTS_DIR="$_artifacts" DSO_TASK_ID="" resolve_scalar_trailers 2>/dev/null || true)"

    local has_review_score=0
    printf '%s\n' "$output" | grep -q "DSO-Review-Score" && has_review_score=1

    assert_eq "resolve_scalar_trailers: output contains DSO-Review-Score flag" "1" "$has_review_score"

    assert_pass_if_clean "test_resolve_scalar_trailers_produces_review_score_flag"
}

# ── Test 13: resolve_scalar_trailers produces no flags when no context ─────────
# RED: resolve_scalar_trailers does not exist yet.

test_resolve_scalar_trailers_produces_no_flags_when_no_context() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_resolve_scalar_trailers_produces_no_flags_when_no_context\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_resolve_scalar_trailers_produces_no_flags_when_no_context"
        return
    fi

    # shellcheck disable=SC1090
    source "$SCRIPT"

    if ! declare -f resolve_scalar_trailers > /dev/null 2>&1; then
        (( ++FAIL ))
        printf "FAIL: test_resolve_scalar_trailers_produces_no_flags_when_no_context\n  function resolve_scalar_trailers not found in script\n" >&2
        assert_pass_if_clean "test_resolve_scalar_trailers_produces_no_flags_when_no_context"
        return
    fi

    local _artifacts
    _artifacts="$(_make_tmpdir)"
    # No reviewer-findings.json, no DSO_TASK_ID set

    local output
    output="$(ARTIFACTS_DIR="$_artifacts" DSO_TASK_ID="" resolve_scalar_trailers 2>/dev/null || true)"

    local line_count
    line_count="$(printf '%s' "$output" | grep -c . || true)"

    assert_eq "resolve_scalar_trailers: no context produces 0 output lines" "0" "$line_count"

    assert_pass_if_clean "test_resolve_scalar_trailers_produces_no_flags_when_no_context"
}

# ── Test 14: exits 0 and omits scalar trailers when ticket show fails ──────────
# Verifies graceful degradation: non-zero exit from dso CLI must not propagate.

test_exits_0_and_omits_scalar_trailers_when_ticket_show_fails() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_exits_0_and_omits_scalar_trailers_when_ticket_show_fails\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_exits_0_and_omits_scalar_trailers_when_ticket_show_fails"
        return
    fi

    # shellcheck disable=SC1090
    source "$SCRIPT"

    if ! declare -f resolve_scalar_trailers > /dev/null 2>&1; then
        (( ++FAIL ))
        printf "FAIL: test_exits_0_and_omits_scalar_trailers_when_ticket_show_fails\n  function resolve_scalar_trailers not found in script\n" >&2
        assert_pass_if_clean "test_exits_0_and_omits_scalar_trailers_when_ticket_show_fails"
        return
    fi

    # Mock dso CLI that exits non-zero (simulates CLI failure)
    local _mock_dir
    _mock_dir="$(_make_tmpdir)"
    mkdir -p "$_mock_dir/bin"
    cat > "$_mock_dir/bin/dso" <<'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$_mock_dir/bin/dso"

    local _artifacts
    _artifacts="$(_make_tmpdir)"
    # No reviewer-findings.json — isolate ticket-failure path

    local output exit_code=0
    output="$(PATH="$_mock_dir/bin:$PATH" ARTIFACTS_DIR="$_artifacts" DSO_TASK_ID="fail-1234" resolve_scalar_trailers 2>/dev/null)" || exit_code=$?

    assert_eq "resolve_scalar_trailers: exits 0 when dso ticket show fails" "0" "$exit_code"

    local has_task=0
    printf '%s\n' "$output" | grep -q "DSO-Task" && has_task=1
    assert_eq "resolve_scalar_trailers: no DSO-Task trailer when ticket show fails" "0" "$has_task"

    assert_pass_if_clean "test_exits_0_and_omits_scalar_trailers_when_ticket_show_fails"
}

# ── Test 15: SC-2 guard — exits 0 without modifying commit msg when attribution disabled ──
# RED: main block does not yet check read-config.sh for attribution.enabled.
# Currently the script exits 1 (unknown positional arg) before reaching any guard.

test_script_exits_0_without_modifying_commit_msg_when_attribution_disabled() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_script_exits_0_without_modifying_commit_msg_when_attribution_disabled\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_script_exits_0_without_modifying_commit_msg_when_attribution_disabled"
        return
    fi

    # Set up temp artifacts dir with a populated JSONL (to confirm it is NOT read)
    local _artifacts
    _artifacts="$(_make_tmpdir)"
    printf '%s\n' '{"type":"agent","subagent_type":"dso:red-test-writer","model":"sonnet"}' \
        > "$_artifacts/attribution-contributors.jsonl"

    # Commit message file
    local _commit_msg_file="$_artifacts/COMMIT_EDITMSG"
    printf 'My commit message\n' > "$_commit_msg_file"
    local _original_content
    _original_content="$(cat "$_commit_msg_file")"

    # Mock read-config.sh: attribution.enabled → false
    local _mock_dir
    _mock_dir="$(_make_tmpdir)/bin"
    mkdir -p "$_mock_dir"
    cat > "$_mock_dir/read-config.sh" <<'MOCK'
#!/bin/bash
# Mock: attribution.enabled → false
if [[ "$1" == "attribution.enabled" ]]; then echo "false"; else echo ""; fi
MOCK
    chmod +x "$_mock_dir/read-config.sh"

    local exit_code=0
    ARTIFACTS_DIR="$_artifacts" PATH="$_mock_dir:$PATH" \
        bash "$SCRIPT" "$_commit_msg_file" 2>/dev/null || exit_code=$?

    assert_eq "SC-2 disabled: exits 0" "0" "$exit_code"

    local _current_content
    _current_content="$(cat "$_commit_msg_file")"
    assert_eq "SC-2 disabled: commit msg unchanged" "$_original_content" "$_current_content"

    assert_pass_if_clean "test_script_exits_0_without_modifying_commit_msg_when_attribution_disabled"
}

# ── Test 16: SC-4 guard — exits 0 without modifying commit msg when JSONL absent ─
# RED: main block exits 3 when JSONL file is not found; must exit 0 after SC-4 impl.

test_script_exits_0_without_modifying_commit_msg_when_jsonl_absent() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_script_exits_0_without_modifying_commit_msg_when_jsonl_absent\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_script_exits_0_without_modifying_commit_msg_when_jsonl_absent"
        return
    fi

    # JSONL does not exist — artifacts dir exists but no JSONL file
    local _artifacts
    _artifacts="$(_make_tmpdir)"

    local _commit_msg_file="$_artifacts/COMMIT_EDITMSG"
    printf 'My commit message\n' > "$_commit_msg_file"
    local _original_content
    _original_content="$(cat "$_commit_msg_file")"

    # Mock read-config.sh: attribution.enabled → true (so config gate passes)
    local _mock_dir
    _mock_dir="$(_make_tmpdir)/bin"
    mkdir -p "$_mock_dir"
    cat > "$_mock_dir/read-config.sh" <<'MOCK'
#!/bin/bash
# Mock: attribution.enabled → true
if [[ "$1" == "attribution.enabled" ]]; then echo "true"; else echo ""; fi
MOCK
    chmod +x "$_mock_dir/read-config.sh"

    local exit_code=0
    ARTIFACTS_DIR="$_artifacts" PATH="$_mock_dir:$PATH" \
        bash "$SCRIPT" "$_commit_msg_file" 2>/dev/null || exit_code=$?

    assert_eq "SC-4 absent: exits 0" "0" "$exit_code"

    local _current_content
    _current_content="$(cat "$_commit_msg_file")"
    assert_eq "SC-4 absent: commit msg unchanged" "$_original_content" "$_current_content"

    assert_pass_if_clean "test_script_exits_0_without_modifying_commit_msg_when_jsonl_absent"
}

# ── Test 17: SC-4 guard — exits 0 without modifying commit msg when JSONL empty ──
# RED: main block calls read_and_deduplicate which errors on missing file;
# an empty JSONL must result in graceful exit 0, not a trailer-apply attempt.

test_script_exits_0_without_modifying_commit_msg_when_jsonl_empty() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_script_exits_0_without_modifying_commit_msg_when_jsonl_empty\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_script_exits_0_without_modifying_commit_msg_when_jsonl_empty"
        return
    fi

    local _artifacts
    _artifacts="$(_make_tmpdir)"

    # JSONL file exists but is empty
    touch "$_artifacts/attribution-contributors.jsonl"

    local _commit_msg_file="$_artifacts/COMMIT_EDITMSG"
    printf 'My commit message\n' > "$_commit_msg_file"
    local _original_content
    _original_content="$(cat "$_commit_msg_file")"

    # Mock read-config.sh: attribution.enabled → true (so config gate passes)
    local _mock_dir
    _mock_dir="$(_make_tmpdir)/bin"
    mkdir -p "$_mock_dir"
    cat > "$_mock_dir/read-config.sh" <<'MOCK'
#!/bin/bash
# Mock: attribution.enabled → true
if [[ "$1" == "attribution.enabled" ]]; then echo "true"; else echo ""; fi
MOCK
    chmod +x "$_mock_dir/read-config.sh"

    local exit_code=0
    ARTIFACTS_DIR="$_artifacts" PATH="$_mock_dir:$PATH" \
        bash "$SCRIPT" "$_commit_msg_file" 2>/dev/null || exit_code=$?

    assert_eq "SC-4 empty: exits 0" "0" "$exit_code"

    local _current_content
    _current_content="$(cat "$_commit_msg_file")"
    assert_eq "SC-4 empty: commit msg unchanged" "$_original_content" "$_current_content"

    assert_pass_if_clean "test_script_exits_0_without_modifying_commit_msg_when_jsonl_empty"
}

# ── Test 18: inject DSO-Agent trailer into commit message (end-to-end) ────────
# RED: main block does not call git interpret-trailers yet — commit message file
# will be unchanged after the script runs, so the DSO-Agent assertion will FAIL.

test_injection_appends_dso_agent_trailer_to_commit_message() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_injection_appends_dso_agent_trailer_to_commit_message\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_injection_appends_dso_agent_trailer_to_commit_message"
        return
    fi

    local _artifacts
    _artifacts="$(_make_tmpdir)"

    # Populate JSONL with one agent entry
    printf '{"type":"agent","subagent_type":"dso:red-test-writer","model":"sonnet"}\n' \
        > "$_artifacts/attribution-contributors.jsonl"

    # Commit message file
    local _commit_msg_file="$_artifacts/COMMIT_EDITMSG"
    printf 'Initial commit\n' > "$_commit_msg_file"

    # Mock read-config.sh: attribution.enabled → true
    local _mock_dir
    _mock_dir="$(_make_tmpdir)/bin"
    mkdir -p "$_mock_dir"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n[[ "$1" == "attribution.enabled" ]] && echo "true" || echo ""\n' \
        > "$_mock_dir/read-config.sh"
    chmod +x "$_mock_dir/read-config.sh"

    local exit_code=0
    ARTIFACTS_DIR="$_artifacts" PATH="$_mock_dir:$PATH" \
        bash "$SCRIPT" "$_commit_msg_file" 2>/dev/null || exit_code=$?

    assert_eq "injection: exits 0" "0" "$exit_code"

    # Assert commit message file now contains a DSO-Agent: trailer line
    local has_trailer=0
    grep -q "^DSO-Agent:" "$_commit_msg_file" 2>/dev/null && has_trailer=1
    assert_eq "injection: commit message contains DSO-Agent trailer" "1" "$has_trailer"

    assert_pass_if_clean "test_injection_appends_dso_agent_trailer_to_commit_message"
}

# ── Test 19: two distinct agents produce exactly two DSO-Agent lines ───────────
# RED: no git interpret-trailers call in main block → commit message unchanged
# → count of ^DSO-Agent: lines will be 0, not 2.

test_two_distinct_agents_produce_two_dso_agent_lines() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_two_distinct_agents_produce_two_dso_agent_lines\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_two_distinct_agents_produce_two_dso_agent_lines"
        return
    fi

    local _artifacts
    _artifacts="$(_make_tmpdir)"

    # Two distinct subagent_type values
    printf '{"type":"agent","subagent_type":"dso:red-test-writer","model":"sonnet"}\n' \
        > "$_artifacts/attribution-contributors.jsonl"
    printf '{"type":"agent","subagent_type":"dso:code-reviewer-correctness","model":"sonnet"}\n' \
        >> "$_artifacts/attribution-contributors.jsonl"

    local _commit_msg_file="$_artifacts/COMMIT_EDITMSG"
    printf 'Initial commit\n' > "$_commit_msg_file"

    local _mock_dir
    _mock_dir="$(_make_tmpdir)/bin"
    mkdir -p "$_mock_dir"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n[[ "$1" == "attribution.enabled" ]] && echo "true" || echo ""\n' \
        > "$_mock_dir/read-config.sh"
    chmod +x "$_mock_dir/read-config.sh"

    local exit_code=0
    ARTIFACTS_DIR="$_artifacts" PATH="$_mock_dir:$PATH" \
        bash "$SCRIPT" "$_commit_msg_file" 2>/dev/null || exit_code=$?

    assert_eq "two agents: exits 0" "0" "$exit_code"

    local agent_line_count
    agent_line_count="$(grep -c "^DSO-Agent:" "$_commit_msg_file" 2>/dev/null || true)"
    assert_eq "two agents: exactly 2 DSO-Agent lines in commit message" "2" "$agent_line_count"

    assert_pass_if_clean "test_two_distinct_agents_produce_two_dso_agent_lines"
}

# ── Test 20: old git exits 0, emits TRAILER_SKIPPED, leaves commit msg intact ─
# RED: main block's check_git_version call exits non-zero and propagates as
# exit 2 (the current code path after SC-2 and SC-4 guards, before T6 impl).
# After correct T6 implementation the version check must cause a graceful exit 0
# with TRAILER_SKIPPED on stderr and the commit message file unchanged.

test_injection_emits_trailer_skipped_and_exits_0_when_git_below_2_6() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_injection_emits_trailer_skipped_and_exits_0_when_git_below_2_6\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_injection_emits_trailer_skipped_and_exits_0_when_git_below_2_6"
        return
    fi

    local _artifacts
    _artifacts="$(_make_tmpdir)"
    printf '{"type":"agent","subagent_type":"dso:red-test-writer","model":"sonnet"}\n' \
        > "$_artifacts/attribution-contributors.jsonl"

    local _commit_msg_file="$_artifacts/COMMIT_EDITMSG"
    printf 'Initial commit\n' > "$_commit_msg_file"
    local _original_content
    _original_content="$(cat "$_commit_msg_file")"

    # Mock read-config.sh: attribution.enabled → true
    local _mock_dir
    _mock_dir="$(_make_tmpdir)/bin"
    mkdir -p "$_mock_dir"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n[[ "$1" == "attribution.enabled" ]] && echo "true" || echo ""\n' \
        > "$_mock_dir/read-config.sh"
    chmod +x "$_mock_dir/read-config.sh"

    # Mock git binary that reports version 1.9.0
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n[[ "$1" == "--version" ]] && echo "git version 1.9.0" || git "$@"\n' \
        > "$_mock_dir/mock-git"
    chmod +x "$_mock_dir/mock-git"

    local _stderr_file
    _stderr_file="$(_make_tmpdir)/stderr.txt"

    local exit_code=0
    GIT_BINARY="$_mock_dir/mock-git" ARTIFACTS_DIR="$_artifacts" PATH="$_mock_dir:$PATH" \
        bash "$SCRIPT" "$_commit_msg_file" 2>"$_stderr_file" || exit_code=$?

    assert_eq "old git: exits 0" "0" "$exit_code"

    local has_trailer_skipped=0
    grep -q "TRAILER_SKIPPED" "$_stderr_file" 2>/dev/null && has_trailer_skipped=1
    assert_eq "old git: stderr contains TRAILER_SKIPPED" "1" "$has_trailer_skipped"

    local _current_content
    _current_content="$(cat "$_commit_msg_file")"
    assert_eq "old git: commit message unchanged" "$_original_content" "$_current_content"

    assert_pass_if_clean "test_injection_emits_trailer_skipped_and_exits_0_when_git_below_2_6"
}

# ── Test 21: SC-5 — no WARNING on stderr when DSO-* trailers are at bottom ────
# RED: post-injection placement scan does not exist yet.
# The script never emits a WARNING, so the grep count for WARNING will be 0
# (passing this assertion). But the test itself checks that no spurious warnings
# fire for a well-formed message — this test is expected to PASS once the scan
# is implemented correctly. Until the scan exists, this test also passes (no
# WARNING is emitted by the absent scan code), making this test initially GREEN.
# Marked as RED in .test-index because the scan behaviour can regress: once the
# placement scan IS implemented, a regression that emits spurious WARNINGs for
# valid messages will flip this back to RED.
#
# NOTE: Because this test passes with the current (no-scan) implementation AND
# after correct implementation, it is functionally GREEN now. See .test-index
# for placement — added only if it is confirmed to fail.

test_placement_scan_emits_no_warning_when_trailers_at_bottom() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_placement_scan_emits_no_warning_when_trailers_at_bottom\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_placement_scan_emits_no_warning_when_trailers_at_bottom"
        return
    fi

    local _artifacts
    _artifacts="$(_make_tmpdir)"

    # Populate JSONL with one agent entry
    printf '{"type":"agent","subagent_type":"dso:red-test-writer","model":"sonnet"}\n' \
        > "$_artifacts/attribution-contributors.jsonl"

    # Commit message that already has a DSO-Agent trailer in the proper trailer
    # section (after a blank line at end) — correct placement.
    local _commit_msg_file="$_artifacts/COMMIT_EDITMSG"
    printf 'Fix: improve thing\n\nThis change improves the thing.\n\nDSO-Agent: dso:previous-agent\n' \
        > "$_commit_msg_file"

    # Mock read-config.sh: attribution.enabled → true
    local _mock_dir
    _mock_dir="$(_make_tmpdir)/bin"
    mkdir -p "$_mock_dir"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n[[ "$1" == "attribution.enabled" ]] && echo "true" || echo ""\n' \
        > "$_mock_dir/read-config.sh"
    chmod +x "$_mock_dir/read-config.sh"

    local _stderr_file
    _stderr_file="$(_make_tmpdir)/stderr.txt"

    local exit_code=0
    ARTIFACTS_DIR="$_artifacts" PATH="$_mock_dir:$PATH" \
        bash "$SCRIPT" "$_commit_msg_file" 2>"$_stderr_file" || exit_code=$?

    assert_eq "SC-5 no-warn: exits 0" "0" "$exit_code"

    # No WARNING line on stderr when trailers are placed correctly
    local warning_count=0
    warning_count="$(grep -ci "WARNING" "$_stderr_file" 2>/dev/null || true)"
    assert_eq "SC-5 no-warn: stderr WARNING count is 0 for correct trailer placement" "0" "$warning_count"

    assert_pass_if_clean "test_placement_scan_emits_no_warning_when_trailers_at_bottom"
}

# ── Test 22: SC-5 — WARNING on stderr when DSO-* trailer appears in body ──────
# RED: post-injection placement scan does not exist yet.
# The script never scans placement, so no WARNING is emitted.
# This test asserts that WARNING is present — it FAILS until the scan is added.

test_placement_scan_emits_warning_when_dso_trailer_in_message_body() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_placement_scan_emits_warning_when_dso_trailer_in_message_body\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_placement_scan_emits_warning_when_dso_trailer_in_message_body"
        return
    fi

    local _artifacts
    _artifacts="$(_make_tmpdir)"

    # Populate JSONL with one agent entry so injection proceeds
    printf '{"type":"agent","subagent_type":"dso:red-test-writer","model":"sonnet"}\n' \
        > "$_artifacts/attribution-contributors.jsonl"

    # Malformed commit message: DSO-Agent line appears in the body BEFORE a blank
    # separator line — this simulates trailers that ended up in the body.
    local _commit_msg_file="$_artifacts/COMMIT_EDITMSG"
    printf 'Fix: improve thing\nDSO-Agent: something\nMore body text here.\n' \
        > "$_commit_msg_file"

    # Mock read-config.sh: attribution.enabled → true
    local _mock_dir
    _mock_dir="$(_make_tmpdir)/bin"
    mkdir -p "$_mock_dir"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n[[ "$1" == "attribution.enabled" ]] && echo "true" || echo ""\n' \
        > "$_mock_dir/read-config.sh"
    chmod +x "$_mock_dir/read-config.sh"

    local _stderr_file
    _stderr_file="$(_make_tmpdir)/stderr.txt"

    local exit_code=0
    ARTIFACTS_DIR="$_artifacts" PATH="$_mock_dir:$PATH" \
        bash "$SCRIPT" "$_commit_msg_file" 2>"$_stderr_file" || exit_code=$?

    assert_eq "SC-5 body-warn: exits 0" "0" "$exit_code"

    # A WARNING must appear on stderr when DSO-* lines are in the body
    local has_warning=0
    grep -qi "WARNING" "$_stderr_file" 2>/dev/null && has_warning=1
    assert_eq "SC-5 body-warn: stderr contains WARNING for body-embedded DSO trailer" "1" "$has_warning"

    assert_pass_if_clean "test_placement_scan_emits_warning_when_dso_trailer_in_message_body"
}

# ── Test 23: SC-5 — blank line separator present before first DSO-* trailer ───
# This verifies that git interpret-trailers naturally inserts a blank separator.
# git interpret-trailers handles this natively, so this test is expected to PASS
# already. Written to guard against regressions if the injection approach changes.
# Not added to .test-index as a RED marker (it passes with the current impl).

test_blank_line_separator_present_before_first_dso_trailer_in_output() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_blank_line_separator_present_before_first_dso_trailer_in_output\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_blank_line_separator_present_before_first_dso_trailer_in_output"
        return
    fi

    local _artifacts
    _artifacts="$(_make_tmpdir)"

    # One agent entry in JSONL
    printf '{"type":"agent","subagent_type":"dso:red-test-writer","model":"sonnet"}\n' \
        > "$_artifacts/attribution-contributors.jsonl"

    # Plain commit message with no trailing blank line
    local _commit_msg_file="$_artifacts/COMMIT_EDITMSG"
    printf 'Initial commit\n' > "$_commit_msg_file"

    # Mock read-config.sh: attribution.enabled → true
    local _mock_dir
    _mock_dir="$(_make_tmpdir)/bin"
    mkdir -p "$_mock_dir"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n[[ "$1" == "attribution.enabled" ]] && echo "true" || echo ""\n' \
        > "$_mock_dir/read-config.sh"
    chmod +x "$_mock_dir/read-config.sh"

    local exit_code=0
    ARTIFACTS_DIR="$_artifacts" PATH="$_mock_dir:$PATH" \
        bash "$SCRIPT" "$_commit_msg_file" 2>/dev/null || exit_code=$?

    assert_eq "SC-5 blank-sep: exits 0" "0" "$exit_code"

    # Find the line number of the first DSO-* trailer and the line immediately before it.
    # The line immediately before the first DSO-* trailer must be blank.
    local _first_dso_line _prev_line
    _first_dso_line="$(grep -n "^DSO-" "$_commit_msg_file" 2>/dev/null | head -1 | cut -d: -f1 || true)"

    if [[ -z "$_first_dso_line" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_blank_line_separator_present_before_first_dso_trailer_in_output\n  no DSO-* trailer found in commit message after injection\n" >&2
        assert_pass_if_clean "test_blank_line_separator_present_before_first_dso_trailer_in_output"
        return
    fi

    local _sep_line_num=$(( _first_dso_line - 1 ))
    _prev_line="$(sed -n "${_sep_line_num}p" "$_commit_msg_file" 2>/dev/null || true)"

    # The line before the first DSO-* trailer must be empty (blank separator)
    assert_eq "SC-5 blank-sep: blank line immediately before first DSO-* trailer" "" "$_prev_line"

    assert_pass_if_clean "test_blank_line_separator_present_before_first_dso_trailer_in_output"
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
test_resolve_scalar_trailers_produces_task_story_epic_flags
test_resolve_scalar_trailers_produces_review_score_flag
test_resolve_scalar_trailers_produces_no_flags_when_no_context
test_exits_0_and_omits_scalar_trailers_when_ticket_show_fails
test_script_exits_0_without_modifying_commit_msg_when_attribution_disabled
test_script_exits_0_without_modifying_commit_msg_when_jsonl_absent
test_script_exits_0_without_modifying_commit_msg_when_jsonl_empty
test_injection_appends_dso_agent_trailer_to_commit_message
test_two_distinct_agents_produce_two_dso_agent_lines
test_injection_emits_trailer_skipped_and_exits_0_when_git_below_2_6
test_placement_scan_emits_no_warning_when_trailers_at_bottom
test_placement_scan_emits_warning_when_dso_trailer_in_message_body
test_blank_line_separator_present_before_first_dso_trailer_in_output

# ── SC-6 --truncate tests (RED) ───────────────────────────────────────────────

# ── Test 24: --truncate clears a populated JSONL file to zero bytes ───────────
# RED: --truncate flag is not implemented. The script treats it as an unknown
# positional argument and exits 1 (unknown option error), so the exit-code
# assertion (expects 0) will fail.

test_truncate_clears_populated_jsonl_to_zero_bytes() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_truncate_clears_populated_jsonl_to_zero_bytes\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_truncate_clears_populated_jsonl_to_zero_bytes"
        return
    fi

    local _artifacts
    _artifacts="$(_make_tmpdir)"
    local _jsonl="$_artifacts/attribution-contributors.jsonl"
    printf '{"type":"agent","subagent_type":"dso:red-test-writer","model":"sonnet"}\n' > "$_jsonl"

    local _commit_msg_file="$_artifacts/COMMIT_EDITMSG"
    printf 'My commit message\n' > "$_commit_msg_file"

    # Mock read-config.sh: attribution.enabled → true
    local _mock_dir
    _mock_dir="$(_make_tmpdir)/bin"
    mkdir -p "$_mock_dir"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n[[ "$1" == "attribution.enabled" ]] && echo "true" || echo ""\n' \
        > "$_mock_dir/read-config.sh"
    chmod +x "$_mock_dir/read-config.sh"

    local exit_code=0
    ARTIFACTS_DIR="$_artifacts" PATH="$_mock_dir:$PATH" \
        bash "$SCRIPT" --truncate "$_commit_msg_file" 2>/dev/null || exit_code=$?

    assert_eq "SC-6 truncate populated: exits 0" "0" "$exit_code"

    local byte_count
    # Trim whitespace: macOS `wc -c` pads with leading spaces
    byte_count="$(wc -c < "$_jsonl" 2>/dev/null | tr -d ' ' || echo "-1")"
    assert_eq "SC-6 truncate populated: JSONL has zero bytes after truncation" "0" "$byte_count"

    assert_pass_if_clean "test_truncate_clears_populated_jsonl_to_zero_bytes"
}

# ── Test 25: --truncate exits 0 when JSONL file is absent ─────────────────────
# RED: --truncate flag is not implemented. The script exits 1 on the unknown
# positional; the exit-code assertion (expects 0) will fail.

test_truncate_exits_0_when_jsonl_absent() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_truncate_exits_0_when_jsonl_absent\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_truncate_exits_0_when_jsonl_absent"
        return
    fi

    local _artifacts
    _artifacts="$(_make_tmpdir)"
    # Intentionally no JSONL file in _artifacts

    local _commit_msg_file="$_artifacts/COMMIT_EDITMSG"
    printf 'My commit message\n' > "$_commit_msg_file"

    # Mock read-config.sh: attribution.enabled → true
    local _mock_dir
    _mock_dir="$(_make_tmpdir)/bin"
    mkdir -p "$_mock_dir"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n[[ "$1" == "attribution.enabled" ]] && echo "true" || echo ""\n' \
        > "$_mock_dir/read-config.sh"
    chmod +x "$_mock_dir/read-config.sh"

    local exit_code=0
    ARTIFACTS_DIR="$_artifacts" PATH="$_mock_dir:$PATH" \
        bash "$SCRIPT" --truncate "$_commit_msg_file" 2>/dev/null || exit_code=$?

    assert_eq "SC-6 truncate absent JSONL: exits 0 (graceful no-op)" "0" "$exit_code"

    assert_pass_if_clean "test_truncate_exits_0_when_jsonl_absent"
}

# ── Test 26: --truncate emits warning on stderr and exits 0 when JSONL not writable ──
# RED: --truncate flag is not implemented. The script exits 1 on the unknown
# positional; the exit-code assertion (expects 0) will fail.

test_truncate_emits_warning_and_exits_0_on_truncation_failure() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_truncate_emits_warning_and_exits_0_on_truncation_failure\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_truncate_emits_warning_and_exits_0_on_truncation_failure"
        return
    fi

    # Skip this test when running as root (chmod 000 has no effect for root)
    if [[ "$(id -u)" -eq 0 ]]; then
        printf "SKIP: test_truncate_emits_warning_and_exits_0_on_truncation_failure (running as root)\n"
        assert_pass_if_clean "test_truncate_emits_warning_and_exits_0_on_truncation_failure"
        return
    fi

    local _artifacts
    _artifacts="$(_make_tmpdir)"
    local _jsonl="$_artifacts/attribution-contributors.jsonl"
    printf '{"type":"agent","subagent_type":"dso:red-test-writer","model":"sonnet"}\n' > "$_jsonl"
    chmod 000 "$_jsonl"

    local _commit_msg_file="$_artifacts/COMMIT_EDITMSG"
    printf 'My commit message\n' > "$_commit_msg_file"

    # Mock read-config.sh: attribution.enabled → true
    local _mock_dir
    _mock_dir="$(_make_tmpdir)/bin"
    mkdir -p "$_mock_dir"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n[[ "$1" == "attribution.enabled" ]] && echo "true" || echo ""\n' \
        > "$_mock_dir/read-config.sh"
    chmod +x "$_mock_dir/read-config.sh"

    local _stderr_file
    _stderr_file="$(_make_tmpdir)/stderr.txt"

    local exit_code=0
    ARTIFACTS_DIR="$_artifacts" PATH="$_mock_dir:$PATH" \
        bash "$SCRIPT" --truncate "$_commit_msg_file" 2>"$_stderr_file" || exit_code=$?

    assert_eq "SC-6 truncate unwritable: exits 0 (graceful degradation)" "0" "$exit_code"

    local has_warning=0
    grep -qi "warning" "$_stderr_file" 2>/dev/null && has_warning=1
    assert_eq "SC-6 truncate unwritable: stderr contains 'warning'" "1" "$has_warning"

    # Restore permissions so cleanup trap can delete the temp dir
    chmod 600 "$_jsonl" 2>/dev/null || true

    assert_pass_if_clean "test_truncate_emits_warning_and_exits_0_on_truncation_failure"
}

test_truncate_clears_populated_jsonl_to_zero_bytes
test_truncate_exits_0_when_jsonl_absent
test_truncate_emits_warning_and_exits_0_on_truncation_failure

# ── Idempotency guard tests (RED) ─────────────────────────────────────────────

# ── Test 27: skips injection when trailers already present ────────────────────
# RED: no idempotency guard exists yet.
# The script will call git interpret-trailers a second time, appending a
# duplicate DSO-Agent line. The assertion (count == 1) will FAIL.

test_skips_injection_when_trailers_already_present() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_skips_injection_when_trailers_already_present\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_skips_injection_when_trailers_already_present"
        return
    fi

    local _artifacts
    _artifacts="$(_make_tmpdir)"

    # Populate JSONL with one agent entry (dso:sprint)
    printf '{"type":"agent","subagent_type":"dso:sprint","model":"sonnet"}\n' \
        > "$_artifacts/attribution-contributors.jsonl"

    # Commit message already contains BOTH the DSO-Agent and DSO-Model trailers.
    # git interpret-trailers will re-append them if called again — this is the
    # duplication scenario the idempotency guard must prevent.
    local _commit_msg_file="$_artifacts/COMMIT_EDITMSG"
    printf 'feat: implement sprint task\n\nDSO-Agent: dso:sprint\nDSO-Model: sonnet\n' \
        > "$_commit_msg_file"

    # Mock read-config.sh: attribution.enabled → true
    local _mock_dir
    _mock_dir="$(_make_tmpdir)/bin"
    mkdir -p "$_mock_dir"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n[[ "$1" == "attribution.enabled" ]] && echo "true" || echo ""\n' \
        > "$_mock_dir/read-config.sh"
    chmod +x "$_mock_dir/read-config.sh"

    local exit_code=0
    ARTIFACTS_DIR="$_artifacts" PATH="$_mock_dir:$PATH" \
        bash "$SCRIPT" "$_commit_msg_file" 2>/dev/null || exit_code=$?

    assert_eq "idempotency: exits 0" "0" "$exit_code"

    # The DSO-Agent line count must remain exactly 1 — no duplicate injected
    local agent_line_count
    agent_line_count="$(grep -c "^DSO-Agent:" "$_commit_msg_file" 2>/dev/null || true)"
    assert_eq "idempotency: DSO-Agent line count remains 1 (no duplicate)" "1" "$agent_line_count"

    assert_pass_if_clean "test_skips_injection_when_trailers_already_present"
}

test_skips_injection_when_trailers_already_present

# ── Tests for review-finding fixes ────────────────────────────────────────────
# These tests cover behavior gaps identified in PR #80 review.

# ── Test: no command injection via single-quote in subagent_type (C5/L1) ──────
# RED: trailer flags built from JSONL values are joined and re-parsed by `eval`.
# A subagent_type containing a closing single quote can break out and execute
# arbitrary shell. After fix: trailer values are passed as argv tokens, never
# re-parsed; the malicious payload becomes a literal trailer string.

test_no_command_injection_via_subagent_type_with_single_quote() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_no_command_injection_via_subagent_type_with_single_quote\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_no_command_injection_via_subagent_type_with_single_quote"
        return
    fi

    local _artifacts; _artifacts="$(_make_tmpdir)"
    local _sentinel; _sentinel="$(_make_tmpdir)/INJECTED"

    # Malicious subagent_type: closes the single-quoted trailer flag and embeds
    # a command substitution. `$(touch <sentinel>)` runs during eval's
    # parameter expansion, BEFORE git is invoked — so even if git later fails
    # under `set -e`, the injection has already executed.
    python3 - "$_artifacts/attribution-contributors.jsonl" "$_sentinel" <<'PYEOF'
import json, sys
out = sys.argv[1]
sentinel = sys.argv[2]
payload = "evil' $(touch '" + sentinel + "') '"
with open(out, 'w') as f:
    f.write(json.dumps({"type": "agent", "subagent_type": payload, "model": "sonnet"}) + "\n")
PYEOF

    local _commit_msg_file="$_artifacts/COMMIT_EDITMSG"
    printf 'feat: test injection\n' > "$_commit_msg_file"

    local _mock_dir; _mock_dir="$(_make_tmpdir)/bin"
    mkdir -p "$_mock_dir"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n[[ "$1" == "attribution.enabled" ]] && echo "true" || echo ""\n' \
        > "$_mock_dir/read-config.sh"
    chmod +x "$_mock_dir/read-config.sh"

    ARTIFACTS_DIR="$_artifacts" PATH="$_mock_dir:$PATH" \
        bash "$SCRIPT" "$_commit_msg_file" >/dev/null 2>&1 || true

    # Primary assertion: the injected `touch` MUST NOT have executed.
    local _sentinel_present="absent"
    [[ -e "$_sentinel" ]] && _sentinel_present="present"
    assert_eq "C5: shell-injection sentinel not created" "absent" "$_sentinel_present"

    assert_pass_if_clean "test_no_command_injection_via_subagent_type_with_single_quote"
}

test_no_command_injection_via_subagent_type_with_single_quote

# ── Test: --jsonl flag is honored by SC-4 guard and trailer formatter (C4) ────
# RED: SC-4 guard and format_trailer_flags hardcode
# `$ARTIFACTS_DIR/attribution-contributors.jsonl`. Passing `--jsonl <alt>` while
# the default file is empty/absent makes the script bail out (SC-4) instead of
# reading from the alternate path.

test_jsonl_flag_path_used_for_guard_and_injection() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_jsonl_flag_path_used_for_guard_and_injection\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_jsonl_flag_path_used_for_guard_and_injection"
        return
    fi

    local _artifacts; _artifacts="$(_make_tmpdir)"
    # Default JSONL is intentionally absent — only the alternate file has data.
    local _alt_jsonl; _alt_jsonl="$(_make_tmpdir)/alt.jsonl"
    printf '{"type":"agent","subagent_type":"dso:via-flag","model":"sonnet"}\n' > "$_alt_jsonl"

    local _commit_msg_file="$_artifacts/COMMIT_EDITMSG"
    printf 'feat: alt jsonl\n' > "$_commit_msg_file"

    local _mock_dir; _mock_dir="$(_make_tmpdir)/bin"
    mkdir -p "$_mock_dir"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n[[ "$1" == "attribution.enabled" ]] && echo "true" || echo ""\n' \
        > "$_mock_dir/read-config.sh"
    chmod +x "$_mock_dir/read-config.sh"

    local exit_code=0
    ARTIFACTS_DIR="$_artifacts" PATH="$_mock_dir:$PATH" \
        bash "$SCRIPT" --jsonl "$_alt_jsonl" "$_commit_msg_file" 2>/dev/null || exit_code=$?

    assert_eq "C4: exits 0 with --jsonl <alt>" "0" "$exit_code"

    local _has_via_flag=0
    grep -q "^DSO-Agent: dso:via-flag$" "$_commit_msg_file" 2>/dev/null && _has_via_flag=1
    assert_eq "C4: trailer from --jsonl path injected" "1" "$_has_via_flag"

    assert_pass_if_clean "test_jsonl_flag_path_used_for_guard_and_injection"
}

test_jsonl_flag_path_used_for_guard_and_injection

# ── Test: missing --jsonl value emits clean usage error (C6) ──────────────────
# RED: argparser does `_JSONL_FILE="$2"` unconditionally; under `set -u`, a
# missing value crashes with a cryptic "unbound variable" instead of a
# user-facing usage error.

test_missing_jsonl_value_exits_with_usage_error() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_missing_jsonl_value_exits_with_usage_error\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_missing_jsonl_value_exits_with_usage_error"
        return
    fi

    local _stderr_file; _stderr_file="$(_make_tmpdir)/stderr.txt"
    local exit_code=0
    bash "$SCRIPT" --jsonl 2>"$_stderr_file" >/dev/null || exit_code=$?

    assert_eq "C6: exits 1 (usage error) on missing --jsonl value" "1" "$exit_code"

    local _has_usage=0
    grep -qiE 'usage|requires|expected' "$_stderr_file" 2>/dev/null && _has_usage=1
    assert_eq "C6: stderr describes the missing-value error" "1" "$_has_usage"

    local _has_unbound=0
    grep -qi 'unbound variable' "$_stderr_file" 2>/dev/null && _has_unbound=1
    assert_eq "C6: stderr does NOT contain 'unbound variable'" "0" "$_has_unbound"

    assert_pass_if_clean "test_missing_jsonl_value_exits_with_usage_error"
}

test_missing_jsonl_value_exits_with_usage_error

# ── Test: missing _COMMIT_MSG_FILE emits clean usage error (L5) ───────────────
# RED: when injection should proceed but no positional arg is given, the script
# falls through to `git interpret-trailers --in-place ... ""`, producing a
# cryptic "fatal: : not a regular file" instead of a usage error.

test_missing_commit_msg_file_exits_with_usage_error() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_missing_commit_msg_file_exits_with_usage_error\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_missing_commit_msg_file_exits_with_usage_error"
        return
    fi

    local _artifacts; _artifacts="$(_make_tmpdir)"
    printf '{"type":"agent","subagent_type":"dso:x","model":"sonnet"}\n' \
        > "$_artifacts/attribution-contributors.jsonl"

    local _mock_dir; _mock_dir="$(_make_tmpdir)/bin"
    mkdir -p "$_mock_dir"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n[[ "$1" == "attribution.enabled" ]] && echo "true" || echo ""\n' \
        > "$_mock_dir/read-config.sh"
    chmod +x "$_mock_dir/read-config.sh"

    local _stderr_file; _stderr_file="$(_make_tmpdir)/stderr.txt"
    local exit_code=0
    ARTIFACTS_DIR="$_artifacts" PATH="$_mock_dir:$PATH" \
        bash "$SCRIPT" 2>"$_stderr_file" >/dev/null || exit_code=$?

    assert_ne "L5: exits non-zero when commit-msg file missing" "0" "$exit_code"

    local _has_usage=0
    grep -qiE 'commit.*message|usage' "$_stderr_file" 2>/dev/null && _has_usage=1
    assert_eq "L5: stderr describes missing commit-msg file" "1" "$_has_usage"

    assert_pass_if_clean "test_missing_commit_msg_file_exits_with_usage_error"
}

test_missing_commit_msg_file_exits_with_usage_error

# ── Test: idempotency guard matches case-insensitively (L4) ───────────────────
# RED: idempotency check uses `grep -qF` (case-sensitive). An existing
# lowercase trailer (`dso-agent: foo`) won't match the would-be `DSO-Agent: foo`,
# so a duplicate trailer is appended.

test_idempotency_matches_lowercase_existing_trailer() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_idempotency_matches_lowercase_existing_trailer\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_idempotency_matches_lowercase_existing_trailer"
        return
    fi

    local _artifacts; _artifacts="$(_make_tmpdir)"
    printf '{"type":"agent","subagent_type":"dso:sprint","model":"sonnet"}\n' \
        > "$_artifacts/attribution-contributors.jsonl"

    local _commit_msg_file="$_artifacts/COMMIT_EDITMSG"
    # Pre-existing trailers in lowercase (e.g., from a different tooling).
    printf 'feat: case test\n\ndso-agent: dso:sprint\ndso-model: sonnet\n' > "$_commit_msg_file"

    local _mock_dir; _mock_dir="$(_make_tmpdir)/bin"
    mkdir -p "$_mock_dir"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n[[ "$1" == "attribution.enabled" ]] && echo "true" || echo ""\n' \
        > "$_mock_dir/read-config.sh"
    chmod +x "$_mock_dir/read-config.sh"

    ARTIFACTS_DIR="$_artifacts" PATH="$_mock_dir:$PATH" \
        bash "$SCRIPT" "$_commit_msg_file" 2>/dev/null || true

    # Combined case-insensitive count of ^dso-agent: lines must remain 1.
    local _agent_count
    _agent_count="$(grep -ic '^dso-agent:' "$_commit_msg_file" 2>/dev/null || true)"
    assert_eq "L4: case-insensitive duplicate prevented (still 1 dso-agent line)" "1" "$_agent_count"

    assert_pass_if_clean "test_idempotency_matches_lowercase_existing_trailer"
}

test_idempotency_matches_lowercase_existing_trailer

# ── Test: SC-2 guard resolves read-config.sh via CLAUDE_PLUGIN_ROOT (C3) ──────
# RED: the SC-2 guard calls `read-config.sh` bare-name, expecting it on PATH.
# In normal runtime, the plugin scripts dir is not on PATH, so the guard
# silently treats attribution as disabled and exits 0 — making the entire
# feature dead code.

test_sc2_guard_resolves_read_config_via_claude_plugin_root() {
    _snapshot_fail

    if [[ ! -f "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_sc2_guard_resolves_read_config_via_claude_plugin_root\n  script not found: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_sc2_guard_resolves_read_config_via_claude_plugin_root"
        return
    fi

    local _artifacts; _artifacts="$(_make_tmpdir)"
    printf '{"type":"agent","subagent_type":"dso:via-plugin-root","model":"sonnet"}\n' \
        > "$_artifacts/attribution-contributors.jsonl"

    local _commit_msg_file="$_artifacts/COMMIT_EDITMSG"
    printf 'feat: plugin-root resolution\n' > "$_commit_msg_file"

    # Build a fake plugin tree containing scripts/read-config.sh that returns
    # "true". Do NOT add it to PATH.
    local _plugin_root; _plugin_root="$(_make_tmpdir)/plugin"
    mkdir -p "$_plugin_root/scripts"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\n[[ "$1" == "attribution.enabled" ]] && echo "true" || echo ""\n' \
        > "$_plugin_root/scripts/read-config.sh"
    chmod +x "$_plugin_root/scripts/read-config.sh"

    # Sanitize PATH: only system bins + git, no read-config.sh anywhere.
    local _clean_path="/usr/bin:/bin"

    local exit_code=0
    PATH="$_clean_path" \
        CLAUDE_PLUGIN_ROOT="$_plugin_root" \
        ARTIFACTS_DIR="$_artifacts" \
        bash "$SCRIPT" "$_commit_msg_file" 2>/dev/null || exit_code=$?

    assert_eq "C3: exits 0 with config resolved via CLAUDE_PLUGIN_ROOT" "0" "$exit_code"

    local _has_trailer=0
    grep -q "^DSO-Agent: dso:via-plugin-root$" "$_commit_msg_file" 2>/dev/null && _has_trailer=1
    assert_eq "C3: trailer injected (SC-2 guard did not bail)" "1" "$_has_trailer"

    assert_pass_if_clean "test_sc2_guard_resolves_read_config_via_claude_plugin_root"
}

test_sc2_guard_resolves_read_config_via_claude_plugin_root

print_summary
