#!/usr/bin/env bash
# tests/unit/scripts/test-write-design-md-additions.sh
# Behavioral tests for scripts/write-design-md-additions.sh
#
# Tests verify observable behavior:
#   1. Happy path: valid payload writes section to existing DESIGN.md
#   2. Creates DESIGN.md when absent
#   3. Rejects empty stdin (exits 1)
#   4. Rejects invalid JSON (exits 1)
#   5. Rejects missing section_heading field (exits 1)
#   6. Rejects missing content_lines field (exits 1)
#   7. Rejects content_lines that is not an array (exits 1)
#   8. Idempotent: duplicate invocations do not create duplicate sections
#   9. Section heading uses ## markdown format
#  10. Script is executable
#
# Usage: bash tests/unit/scripts/test-write-design-md-additions.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/plugins/dso}"
SCRIPT="$_PLUGIN_ROOT/scripts/write-design-md-additions.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-write-design-md-additions.sh ==="

# ── Helper: create an isolated project dir ────────────────────────────────────
_make_project_dir() { mktemp -d; }

# ── Helper: run the script with a given JSON payload in an isolated dir ───────
_run_script() {
    local payload="$1"
    local project_dir="$2"
    echo "$payload" | PROJECT_ROOT="$project_dir" bash "$SCRIPT"
}

# ── Test 1: Happy path — valid payload writes section to existing DESIGN.md ──

test_happy_path_writes_section() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_happy_path_writes_section\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_happy_path_writes_section"
        return
    fi

    local project_dir
    project_dir="$(_make_project_dir)"
    trap 'rm -rf "$project_dir"' RETURN

    # Pre-create DESIGN.md with some content
    echo "# Design Document" > "$project_dir/DESIGN.md"

    local payload='{"section_heading":"Architecture Overview","content_lines":["This is the architecture.","It has two layers."]}'
    local exit_code=0
    _run_script "$payload" "$project_dir" >/dev/null 2>&1 || exit_code=$?

    assert_eq "happy path: exits 0" "0" "$exit_code"

    local found_heading=0
    grep -qF "## Architecture Overview" "$project_dir/DESIGN.md" 2>/dev/null && found_heading=1
    assert_eq "happy path: heading written" "1" "$found_heading"

    local found_content=0
    grep -qF "This is the architecture." "$project_dir/DESIGN.md" 2>/dev/null && found_content=1
    assert_eq "happy path: content written" "1" "$found_content"

    assert_pass_if_clean "test_happy_path_writes_section"
}

# ── Test 2: Creates DESIGN.md when absent ────────────────────────────────────

test_creates_design_md_when_absent() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_creates_design_md_when_absent\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_creates_design_md_when_absent"
        return
    fi

    local project_dir
    project_dir="$(_make_project_dir)"
    trap 'rm -rf "$project_dir"' RETURN

    # Ensure DESIGN.md does NOT exist
    local design_md="$project_dir/DESIGN.md"
    [[ ! -f "$design_md" ]]

    local payload='{"section_heading":"New Section","content_lines":["Created fresh."]}'
    local exit_code=0
    _run_script "$payload" "$project_dir" >/dev/null 2>&1 || exit_code=$?

    assert_eq "creates DESIGN.md: exits 0" "0" "$exit_code"

    local file_exists=0
    [[ -f "$design_md" ]] && file_exists=1
    assert_eq "creates DESIGN.md: file exists" "1" "$file_exists"

    local found_heading=0
    grep -qF "## New Section" "$design_md" 2>/dev/null && found_heading=1
    assert_eq "creates DESIGN.md: heading present" "1" "$found_heading"

    assert_pass_if_clean "test_creates_design_md_when_absent"
}

# ── Test 3: Rejects empty stdin (exits 1) ────────────────────────────────────

test_rejects_empty_stdin() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_rejects_empty_stdin\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_rejects_empty_stdin"
        return
    fi

    local project_dir
    project_dir="$(_make_project_dir)"
    trap 'rm -rf "$project_dir"' RETURN

    local exit_code=0
    echo "" | PROJECT_ROOT="$project_dir" bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq "empty stdin: exits 1" "1" "$exit_code"

    assert_pass_if_clean "test_rejects_empty_stdin"
}

# ── Test 4: Rejects invalid JSON (exits 1) ───────────────────────────────────

test_rejects_invalid_json() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_rejects_invalid_json\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_rejects_invalid_json"
        return
    fi

    local project_dir
    project_dir="$(_make_project_dir)"
    trap 'rm -rf "$project_dir"' RETURN

    local exit_code=0
    echo "not-valid-json" | PROJECT_ROOT="$project_dir" bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq "invalid JSON: exits 1" "1" "$exit_code"

    assert_pass_if_clean "test_rejects_invalid_json"
}

# ── Test 5: Rejects missing section_heading field (exits 1) ──────────────────

test_rejects_missing_section_heading() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_rejects_missing_section_heading\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_rejects_missing_section_heading"
        return
    fi

    local project_dir
    project_dir="$(_make_project_dir)"
    trap 'rm -rf "$project_dir"' RETURN

    local payload='{"content_lines":["Some content."]}'
    local exit_code=0
    _run_script "$payload" "$project_dir" >/dev/null 2>&1 || exit_code=$?

    assert_eq "missing section_heading: exits 1" "1" "$exit_code"

    assert_pass_if_clean "test_rejects_missing_section_heading"
}

# ── Test 6: Rejects missing content_lines field (exits 1) ────────────────────

test_rejects_missing_content_lines() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_rejects_missing_content_lines\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_rejects_missing_content_lines"
        return
    fi

    local project_dir
    project_dir="$(_make_project_dir)"
    trap 'rm -rf "$project_dir"' RETURN

    local payload='{"section_heading":"Some Section"}'
    local exit_code=0
    _run_script "$payload" "$project_dir" >/dev/null 2>&1 || exit_code=$?

    assert_eq "missing content_lines: exits 1" "1" "$exit_code"

    assert_pass_if_clean "test_rejects_missing_content_lines"
}

# ── Test 7: Rejects content_lines that is not an array (exits 1) ─────────────

test_rejects_content_lines_non_array() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_rejects_content_lines_non_array\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_rejects_content_lines_non_array"
        return
    fi

    local project_dir
    project_dir="$(_make_project_dir)"
    trap 'rm -rf "$project_dir"' RETURN

    local payload='{"section_heading":"Some Section","content_lines":"not an array"}'
    local exit_code=0
    _run_script "$payload" "$project_dir" >/dev/null 2>&1 || exit_code=$?

    assert_eq "non-array content_lines: exits 1" "1" "$exit_code"

    assert_pass_if_clean "test_rejects_content_lines_non_array"
}

# ── Test 8: Idempotent — duplicate invocations do not create duplicates ───────

test_idempotent_no_duplicates() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_idempotent_no_duplicates\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_idempotent_no_duplicates"
        return
    fi

    local project_dir
    project_dir="$(_make_project_dir)"
    trap 'rm -rf "$project_dir"' RETURN

    local payload='{"section_heading":"Idempotent Section","content_lines":["Line one.","Line two."]}'

    # First invocation
    local exit_code_1=0
    _run_script "$payload" "$project_dir" >/dev/null 2>&1 || exit_code_1=$?
    assert_eq "idempotent: first call exits 0" "0" "$exit_code_1"

    # Second invocation — same payload
    local exit_code_2=0
    _run_script "$payload" "$project_dir" >/dev/null 2>&1 || exit_code_2=$?
    assert_eq "idempotent: second call exits 0" "0" "$exit_code_2"

    # Count occurrences of the heading
    local heading_count
    heading_count=$(grep -cF "## Idempotent Section" "$project_dir/DESIGN.md" 2>/dev/null || echo "0")
    assert_eq "idempotent: heading appears exactly once" "1" "$heading_count"

    assert_pass_if_clean "test_idempotent_no_duplicates"
}

# ── Test 9: Section heading uses ## markdown format ──────────────────────────

test_section_heading_markdown_format() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_section_heading_markdown_format\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_section_heading_markdown_format"
        return
    fi

    local project_dir
    project_dir="$(_make_project_dir)"
    trap 'rm -rf "$project_dir"' RETURN

    local payload='{"section_heading":"Markdown Heading Test","content_lines":["Content here."]}'
    local exit_code=0
    _run_script "$payload" "$project_dir" >/dev/null 2>&1 || exit_code=$?

    assert_eq "markdown format: exits 0" "0" "$exit_code"

    # Verify the heading is written with ## prefix
    local found=0
    grep -qF "## Markdown Heading Test" "$project_dir/DESIGN.md" 2>/dev/null && found=1
    assert_eq "markdown format: ## prefix present" "1" "$found"

    assert_pass_if_clean "test_section_heading_markdown_format"
}

# ── Test 10: Script is executable ────────────────────────────────────────────

test_script_is_executable() {
    _snapshot_fail

    if [[ -x "$SCRIPT" ]]; then
        assert_eq "executable" "yes" "yes"
    else
        (( ++FAIL ))
        printf "FAIL: test_script_is_executable\n  not executable: %s\n" "$SCRIPT" >&2
    fi

    assert_pass_if_clean "test_script_is_executable"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

test_happy_path_writes_section
test_creates_design_md_when_absent
test_rejects_empty_stdin
test_rejects_invalid_json
test_rejects_missing_section_heading
test_rejects_missing_content_lines
test_rejects_content_lines_non_array
test_idempotent_no_duplicates
test_section_heading_markdown_format
test_script_is_executable

print_summary
