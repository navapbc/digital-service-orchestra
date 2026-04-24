#!/usr/bin/env bash
# tests/unit/scripts/test-adr-upsert.sh
# Behavioral tests for plugins/dso/scripts/onboarding/adr-upsert.sh
#
# Tests verify observable behavior:
#   1. Creates docs/adr/ if it does not exist
#   2. Creates a new ADR file with correct filename pattern (NNNN-slug.md)
#   3. New ADR contains the topic title, status, date, and content
#   4. ADR numbering starts at 0001 for an empty adr dir
#   5. ADR numbering increments beyond the highest existing number
#   6. Duplicate topic (same slug) appends a revision note, not a new file
#   7. --status value is written into the ADR file
#   8. --status default is "Accepted" when omitted
#   9. Missing --topic exits 1 with error on stderr
#  10. Missing --content-file exits 1 with error on stderr
#  11. Non-existent content file exits 2 with error on stderr
#  12. Topic that slugifies to empty string exits 1 with error
#  13. --project-dir=<dir> (= form) is accepted
#  14. Unknown argument exits 1 with error on stderr
#  15. Script is executable
#
# Usage: bash tests/unit/scripts/test-adr-upsert.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/onboarding/adr-upsert.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-adr-upsert.sh ==="

# ── Helper: create an isolated project dir ────────────────────────────────────
_make_project_dir() { mktemp -d; }

# ── Helper: create a temp content file with given text ───────────────────────
_make_content_file() {
    local text="${1:-Some ADR content.}"
    local f; f="$(mktemp)"
    printf '%s\n' "$text" > "$f"
    echo "$f"
}

# ── Test 1: docs/adr/ is created if absent ───────────────────────────────────

test_creates_adr_dir_if_absent() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_creates_adr_dir_if_absent\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_creates_adr_dir_if_absent"
        return
    fi

    local proj_dir content_file
    proj_dir="$(_make_project_dir)"
    content_file="$(_make_content_file)"
    trap 'rm -rf "$proj_dir" "$content_file"' RETURN

    bash "$SCRIPT" --topic "Use Bash" --content-file "$content_file" \
        --project-dir "$proj_dir" >/dev/null 2>&1

    local dir_exists=0
    [[ -d "$proj_dir/docs/adr" ]] && dir_exists=1
    assert_eq "adr dir created" "1" "$dir_exists"

    assert_pass_if_clean "test_creates_adr_dir_if_absent"
}

# ── Test 2: New ADR has correct filename pattern ──────────────────────────────

test_new_adr_filename_pattern() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_new_adr_filename_pattern\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_new_adr_filename_pattern"
        return
    fi

    local proj_dir content_file
    proj_dir="$(_make_project_dir)"
    content_file="$(_make_content_file)"
    trap 'rm -rf "$proj_dir" "$content_file"' RETURN

    bash "$SCRIPT" --topic "Use JSON for config" --content-file "$content_file" \
        --project-dir "$proj_dir" >/dev/null 2>&1

    # Expect a file matching 0001-use-json-for-config.md
    local found=0
    [[ -f "$proj_dir/docs/adr/0001-use-json-for-config.md" ]] && found=1
    assert_eq "filename: 0001-use-json-for-config.md created" "1" "$found"

    assert_pass_if_clean "test_new_adr_filename_pattern"
}

# ── Test 3: ADR file contains topic, status, date, and content ───────────────

test_new_adr_contains_required_sections() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_new_adr_contains_required_sections\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_new_adr_contains_required_sections"
        return
    fi

    local proj_dir content_file
    proj_dir="$(_make_project_dir)"
    content_file="$(_make_content_file "We decided to use Bash for scripts.")"
    trap 'rm -rf "$proj_dir" "$content_file"' RETURN

    bash "$SCRIPT" --topic "Use Bash" --content-file "$content_file" \
        --project-dir "$proj_dir" >/dev/null 2>&1

    local adr_file="$proj_dir/docs/adr/0001-use-bash.md"
    if [[ ! -f "$adr_file" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_new_adr_contains_required_sections\n  ADR file not created\n" >&2
        assert_pass_if_clean "test_new_adr_contains_required_sections"
        return
    fi

    local contents; contents="$(cat "$adr_file")"

    assert_contains "adr body: topic title" "Use Bash"                    "$contents"
    assert_contains "adr body: Status line" "Status:"                     "$contents"
    assert_contains "adr body: Date line"   "Date:"                       "$contents"
    assert_contains "adr body: content"     "We decided to use Bash"      "$contents"

    assert_pass_if_clean "test_new_adr_contains_required_sections"
}

# ── Test 4: First ADR numbered 0001 ──────────────────────────────────────────

test_first_adr_numbered_0001() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_first_adr_numbered_0001\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_first_adr_numbered_0001"
        return
    fi

    local proj_dir content_file
    proj_dir="$(_make_project_dir)"
    content_file="$(_make_content_file)"
    trap 'rm -rf "$proj_dir" "$content_file"' RETURN

    local out
    out=$(bash "$SCRIPT" --topic "First Decision" --content-file "$content_file" \
        --project-dir "$proj_dir" 2>/dev/null)

    assert_contains "first adr: 0001 in output" "0001" "$out"
    local found=0
    [[ -f "$proj_dir/docs/adr/0001-first-decision.md" ]] && found=1
    assert_eq "first adr: file 0001-first-decision.md exists" "1" "$found"

    assert_pass_if_clean "test_first_adr_numbered_0001"
}

# ── Test 5: Numbering increments beyond highest existing ADR ─────────────────

test_adr_number_increments_beyond_existing() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_adr_number_increments_beyond_existing\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_adr_number_increments_beyond_existing"
        return
    fi

    local proj_dir content_file
    proj_dir="$(_make_project_dir)"
    content_file="$(_make_content_file)"
    trap 'rm -rf "$proj_dir" "$content_file"' RETURN

    mkdir -p "$proj_dir/docs/adr"
    touch "$proj_dir/docs/adr/0003-existing-decision.md"

    # New ADR should become 0004
    bash "$SCRIPT" --topic "Another Decision" --content-file "$content_file" \
        --project-dir "$proj_dir" >/dev/null 2>&1

    local found=0
    [[ -f "$proj_dir/docs/adr/0004-another-decision.md" ]] && found=1
    assert_eq "numbering: 0004-another-decision.md created" "1" "$found"

    assert_pass_if_clean "test_adr_number_increments_beyond_existing"
}

# ── Test 6: Duplicate topic appends revision, not a new file ─────────────────

test_duplicate_topic_appends_revision() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_duplicate_topic_appends_revision\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_duplicate_topic_appends_revision"
        return
    fi

    local proj_dir content_file1 content_file2
    proj_dir="$(_make_project_dir)"
    content_file1="$(_make_content_file "Initial content.")"
    content_file2="$(_make_content_file "Revised content.")"
    trap 'rm -rf "$proj_dir" "$content_file1" "$content_file2"' RETURN

    # First call: creates ADR
    bash "$SCRIPT" --topic "My Decision" --content-file "$content_file1" \
        --project-dir "$proj_dir" >/dev/null 2>&1

    # Second call: same topic → should append
    local out exit_code=0
    out=$(bash "$SCRIPT" --topic "My Decision" --content-file "$content_file2" \
        --project-dir "$proj_dir" 2>/dev/null) || exit_code=$?

    assert_eq "duplicate topic: exits 0" "0" "$exit_code"
    assert_contains "duplicate topic: appended message" "appended revision" "$out"

    # Only one .md file should exist (no new file created)
    local file_count
    file_count=$(find "$proj_dir/docs/adr" -maxdepth 1 -name "*.md" -type f | wc -l | tr -d ' ')
    assert_eq "duplicate topic: only one file exists" "1" "$file_count"

    # The file should contain both original and revised content
    local adr_file="$proj_dir/docs/adr/0001-my-decision.md"
    if [[ -f "$adr_file" ]]; then
        local contents; contents="$(cat "$adr_file")"
        assert_contains "duplicate topic: original content preserved" "Initial content" "$contents"
        assert_contains "duplicate topic: revision appended"          "Revised content" "$contents"
        assert_contains "duplicate topic: Revision heading present"   "## Revision"     "$contents"
    else
        (( ++FAIL ))
        printf "FAIL: test_duplicate_topic_appends_revision\n  expected ADR file not found\n" >&2
    fi

    assert_pass_if_clean "test_duplicate_topic_appends_revision"
}

# ── Test 7: --status value appears in ADR ────────────────────────────────────

test_custom_status_written_to_adr() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_custom_status_written_to_adr\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_custom_status_written_to_adr"
        return
    fi

    local proj_dir content_file
    proj_dir="$(_make_project_dir)"
    content_file="$(_make_content_file)"
    trap 'rm -rf "$proj_dir" "$content_file"' RETURN

    bash "$SCRIPT" --topic "Draft ADR" --content-file "$content_file" \
        --status "Proposed" --project-dir "$proj_dir" >/dev/null 2>&1

    local adr_file="$proj_dir/docs/adr/0001-draft-adr.md"
    if [[ ! -f "$adr_file" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_custom_status_written_to_adr\n  ADR file not created\n" >&2
        assert_pass_if_clean "test_custom_status_written_to_adr"
        return
    fi

    local contents; contents="$(cat "$adr_file")"
    assert_contains "custom status: Proposed in file" "Proposed" "$contents"

    assert_pass_if_clean "test_custom_status_written_to_adr"
}

# ── Test 8: Default status is "Accepted" when --status omitted ───────────────

test_default_status_is_accepted() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_default_status_is_accepted\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_default_status_is_accepted"
        return
    fi

    local proj_dir content_file
    proj_dir="$(_make_project_dir)"
    content_file="$(_make_content_file)"
    trap 'rm -rf "$proj_dir" "$content_file"' RETURN

    bash "$SCRIPT" --topic "Default Status ADR" --content-file "$content_file" \
        --project-dir "$proj_dir" >/dev/null 2>&1

    local adr_file="$proj_dir/docs/adr/0001-default-status-adr.md"
    if [[ ! -f "$adr_file" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_default_status_is_accepted\n  ADR file not created\n" >&2
        assert_pass_if_clean "test_default_status_is_accepted"
        return
    fi

    local contents; contents="$(cat "$adr_file")"
    assert_contains "default status: Accepted in file" "Accepted" "$contents"

    assert_pass_if_clean "test_default_status_is_accepted"
}

# ── Test 9: Missing --topic exits 1 with error ───────────────────────────────

test_missing_topic_exits_1() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_missing_topic_exits_1\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_missing_topic_exits_1"
        return
    fi

    local content_file; content_file="$(_make_content_file)"
    trap 'rm -f "$content_file"' RETURN

    local stderr_out exit_code=0
    stderr_out=$(bash "$SCRIPT" --content-file "$content_file" 2>&1 >/dev/null) || exit_code=$?

    assert_eq "missing topic: exits 1" "1" "$exit_code"
    assert_contains "missing topic: error on stderr" "Error" "$stderr_out"

    assert_pass_if_clean "test_missing_topic_exits_1"
}

# ── Test 10: Missing --content-file exits 1 with error ───────────────────────

test_missing_content_file_flag_exits_1() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_missing_content_file_flag_exits_1\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_missing_content_file_flag_exits_1"
        return
    fi

    local stderr_out exit_code=0
    stderr_out=$(bash "$SCRIPT" --topic "Some Topic" 2>&1 >/dev/null) || exit_code=$?

    assert_eq "missing content-file flag: exits 1" "1" "$exit_code"
    assert_contains "missing content-file flag: error on stderr" "Error" "$stderr_out"

    assert_pass_if_clean "test_missing_content_file_flag_exits_1"
}

# ── Test 11: Non-existent content file exits 2 with error ────────────────────

test_nonexistent_content_file_exits_2() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_nonexistent_content_file_exits_2\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_nonexistent_content_file_exits_2"
        return
    fi

    local proj_dir; proj_dir="$(_make_project_dir)"
    trap 'rm -rf "$proj_dir"' RETURN

    local stderr_out exit_code=0
    stderr_out=$(bash "$SCRIPT" --topic "Some Topic" \
        --content-file "/tmp/this-file-definitely-does-not-exist-$$" \
        --project-dir "$proj_dir" 2>&1 >/dev/null) || exit_code=$?

    assert_eq "missing file: exits 2" "2" "$exit_code"
    assert_contains "missing file: error on stderr" "Error" "$stderr_out"

    assert_pass_if_clean "test_nonexistent_content_file_exits_2"
}

# ── Test 12: Topic that slugifies to empty string exits 1 ────────────────────

test_empty_slug_topic_exits_1() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_empty_slug_topic_exits_1\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_empty_slug_topic_exits_1"
        return
    fi

    local proj_dir content_file
    proj_dir="$(_make_project_dir)"
    content_file="$(_make_content_file)"
    trap 'rm -rf "$proj_dir" "$content_file"' RETURN

    # Non-alphanumeric only → slugifies to empty string
    local exit_code=0
    bash "$SCRIPT" --topic "---" --content-file "$content_file" \
        --project-dir "$proj_dir" 2>/dev/null || exit_code=$?

    assert_eq "empty slug: exits 1" "1" "$exit_code"

    assert_pass_if_clean "test_empty_slug_topic_exits_1"
}

# ── Test 13: --project-dir=<dir> (= form) is accepted ────────────────────────

test_project_dir_equals_form_accepted() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_project_dir_equals_form_accepted\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_project_dir_equals_form_accepted"
        return
    fi

    local proj_dir content_file
    proj_dir="$(_make_project_dir)"
    content_file="$(_make_content_file)"
    trap 'rm -rf "$proj_dir" "$content_file"' RETURN

    local exit_code=0
    bash "$SCRIPT" --topic "Equals Form Test" --content-file "$content_file" \
        "--project-dir=$proj_dir" >/dev/null 2>&1 || exit_code=$?

    assert_eq "equals form: exits 0" "0" "$exit_code"

    local found=0
    [[ -f "$proj_dir/docs/adr/0001-equals-form-test.md" ]] && found=1
    assert_eq "equals form: ADR file created" "1" "$found"

    assert_pass_if_clean "test_project_dir_equals_form_accepted"
}

# ── Test 14: Unknown argument exits 1 with error ─────────────────────────────

test_unknown_argument_exits_1() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_unknown_argument_exits_1\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_unknown_argument_exits_1"
        return
    fi

    local stderr_out exit_code=0
    stderr_out=$(bash "$SCRIPT" --not-a-real-flag 2>&1 >/dev/null) || exit_code=$?

    assert_eq "unknown arg: exits 1" "1" "$exit_code"
    assert_contains "unknown arg: error on stderr" "Error" "$stderr_out"

    assert_pass_if_clean "test_unknown_argument_exits_1"
}

# ── Test 15: Script is executable ────────────────────────────────────────────

test_adr_upsert_is_executable() {
    _snapshot_fail

    if [[ -x "$SCRIPT" ]]; then
        assert_eq "executable" "yes" "yes"
    else
        (( ++FAIL ))
        printf "FAIL: test_adr_upsert_is_executable\n  not executable: %s\n" "$SCRIPT" >&2
    fi

    assert_pass_if_clean "test_adr_upsert_is_executable"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

test_creates_adr_dir_if_absent
test_new_adr_filename_pattern
test_new_adr_contains_required_sections
test_first_adr_numbered_0001
test_adr_number_increments_beyond_existing
test_duplicate_topic_appends_revision
test_custom_status_written_to_adr
test_default_status_is_accepted
test_missing_topic_exits_1
test_missing_content_file_flag_exits_1
test_nonexistent_content_file_exits_2
test_empty_slug_topic_exits_1
test_project_dir_equals_form_accepted
test_unknown_argument_exits_1
test_adr_upsert_is_executable

print_summary
