#!/usr/bin/env bash
# tests/scripts/test-bug-report-cli-validation.sh
# Tests for bug report CLI validation: unicode arrow conversion, title/description warnings.
#
# Covers:
#   - Unicode arrow (U+2192) auto-converted to ASCII (->) in title
#   - Warning emitted to stderr when title doesn't match [Component]: [Condition] -> [Observed Result]
#   - Warning emitted to stderr when description missing Expected Behavior or Actual Behavior headers
#   - Warning emitted to stderr when description exceeds 30K characters
#   - Exit code is always 0 and ticket is persisted regardless of warnings
#   - Title warning disabled when bug_report.title_warning_enabled=false in config
#
# Usage: bash tests/scripts/test-bug-report-cli-validation.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
TICKET_CREATE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-create.sh"
TICKET_EDIT_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-edit.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-bug-report-cli-validation.sh ==="

# ── Helper: create a fresh temp git repo with ticket system initialized ───────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_ticket_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Helper: extract title from a ticket's CREATE event ────────────────────────
_extract_title() {
    local tracker_dir="$1" ticket_id="$2"
    local event_file
    event_file=$(find "$tracker_dir/$ticket_id" -maxdepth 1 -name '*-CREATE.json' ! -name '.*' 2>/dev/null | head -1)
    if [ -z "$event_file" ]; then
        echo "NO_EVENT"
        return
    fi
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    e = json.load(f)
print(e['data']['title'])
" "$event_file"
}

# ── Test 1: Unicode arrow converted to ASCII in title on create ───────────────
echo ""
echo "Test 1: Unicode arrow (U+2192) converted to ASCII (->) in title on create"
test_unicode_arrow_conversion() {
    local repo
    repo=$(_make_test_repo)

    local ticket_id stderr_out
    stderr_out=$(mktemp)
    _CLEANUP_DIRS+=("$stderr_out")
    # Use printf to get the actual unicode arrow character U+2192 (→)
    local unicode_title
    unicode_title=$(printf 'CLI: input fails \xe2\x86\x92 crash')
    ticket_id=$(cd "$repo" && bash "$TICKET_CREATE_SCRIPT" bug "$unicode_title" 2>"$stderr_out") || true

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created with unicode arrow" "non-empty" "empty"
        return
    fi

    local tracker_dir="$repo/.tickets-tracker"
    local stored_title
    stored_title=$(_extract_title "$tracker_dir" "$ticket_id")

    # The stored title should have -> not the unicode arrow
    assert_contains "title contains ASCII arrow" "->" "$stored_title"

    # The stored title should NOT contain the unicode arrow
    local unicode_arrow
    unicode_arrow=$(printf '\xe2\x86\x92')
    if [[ "$stored_title" == *"$unicode_arrow"* ]]; then
        assert_eq "title does not contain unicode arrow" "no unicode arrow" "has unicode arrow"
    else
        assert_eq "title does not contain unicode arrow" "no unicode arrow" "no unicode arrow"
    fi
}
test_unicode_arrow_conversion

# ── Test 2: Warning on non-matching title pattern ─────────────────────────────
echo ""
echo "Test 2: Warning emitted to stderr when title doesn't match pattern"
test_title_pattern_warning() {
    local repo
    repo=$(_make_test_repo)

    local ticket_id stderr_out
    stderr_out=$(mktemp)
    _CLEANUP_DIRS+=("$stderr_out")
    # Title that does NOT match [Component]: [Condition] -> [Observed Result]
    ticket_id=$(cd "$repo" && bash "$TICKET_CREATE_SCRIPT" bug "bad title no pattern" 2>"$stderr_out") || true

    local stderr_content
    stderr_content=$(cat "$stderr_out")

    # Should contain a warning about title pattern
    assert_contains "stderr contains title pattern warning" "title" "$stderr_content"
}
test_title_pattern_warning

# ── Test 3: No title warning when title matches pattern ───────────────────────
echo ""
echo "Test 3: No title warning when title matches [Component]: [Condition] -> [Observed Result]"
test_title_pattern_no_warning() {
    local repo
    repo=$(_make_test_repo)

    local ticket_id stderr_out
    stderr_out=$(mktemp)
    _CLEANUP_DIRS+=("$stderr_out")
    # Title that matches the pattern
    ticket_id=$(cd "$repo" && bash "$TICKET_CREATE_SCRIPT" bug "CLI: input fails -> crash" 2>"$stderr_out") || true

    local stderr_content
    stderr_content=$(cat "$stderr_out")

    # Should NOT contain a title pattern warning
    _tmp="$stderr_content"; shopt -s nocasematch
    if [[ "$_tmp" =~ title.*pattern|title.*format|title.*warning ]]; then
        assert_eq "no title pattern warning for conforming title" "no warning" "has warning"
    else
        assert_eq "no title pattern warning for conforming title" "no warning" "no warning"
    fi; shopt -u nocasematch
}
test_title_pattern_no_warning

# ── Test 4: Warning on missing description headers ────────────────────────────
echo ""
echo "Test 4: Warning when description missing Expected/Actual Behavior headers"
test_description_headers_warning() {
    local repo
    repo=$(_make_test_repo)

    local ticket_id stderr_out
    stderr_out=$(mktemp)
    _CLEANUP_DIRS+=("$stderr_out")
    # Bug with description that lacks Expected/Actual Behavior
    ticket_id=$(cd "$repo" && bash "$TICKET_CREATE_SCRIPT" bug "CLI: input fails -> crash" -d "Some random description without headers" 2>"$stderr_out") || true

    local stderr_content
    stderr_content=$(cat "$stderr_out")

    # Should warn about missing headers
    assert_contains "stderr contains description headers warning" "Expected Behavior" "$stderr_content"
}
test_description_headers_warning

# ── Test 5: No description header warning when headers present ────────────────
echo ""
echo "Test 5: No description header warning when Expected/Actual Behavior present"
test_description_headers_no_warning() {
    local repo
    repo=$(_make_test_repo)

    local ticket_id stderr_out
    stderr_out=$(mktemp)
    _CLEANUP_DIRS+=("$stderr_out")
    ticket_id=$(cd "$repo" && bash "$TICKET_CREATE_SCRIPT" bug "CLI: input fails -> crash" -d "## Expected Behavior
Should work.

## Actual Behavior
Crashes." 2>"$stderr_out") || true

    local stderr_content
    stderr_content=$(cat "$stderr_out")

    # Should NOT contain description header warning
    _tmp="$stderr_content"; shopt -s nocasematch
    if [[ "$_tmp" =~ "Expected Behavior".*missing|description.*header ]]; then
        assert_eq "no description header warning" "no warning" "has warning"
    else
        assert_eq "no description header warning" "no warning" "no warning"
    fi; shopt -u nocasematch
}
test_description_headers_no_warning

# ── Test 6: Warning on description exceeding 30K characters ───────────────────
echo ""
echo "Test 6: Warning when description exceeds 30K characters"
test_description_size_warning() {
    local repo
    repo=$(_make_test_repo)

    # Generate a description > 30000 characters
    local big_desc
    big_desc=$(python3 -c "print('x' * 31000)")

    local ticket_id stderr_out
    stderr_out=$(mktemp)
    _CLEANUP_DIRS+=("$stderr_out")
    ticket_id=$(cd "$repo" && bash "$TICKET_CREATE_SCRIPT" bug "CLI: input fails -> crash" -d "$big_desc" 2>"$stderr_out") || true

    local stderr_content
    stderr_content=$(cat "$stderr_out")

    # Should warn about description size
    assert_contains "stderr contains size warning" "30" "$stderr_content"
}
test_description_size_warning

# ── Test 7: Exit code always 0 and ticket persisted despite warnings ──────────
echo ""
echo "Test 7: Exit code is 0 and ticket persisted regardless of warnings"
test_exit_code_always_zero() {
    local repo
    repo=$(_make_test_repo)

    local ticket_id exit_code
    # Non-conforming bug: bad title, no description headers, should still succeed
    ticket_id=$(cd "$repo" && bash "$TICKET_CREATE_SCRIPT" bug "bad title" -d "no headers" 2>/dev/null)
    exit_code=$?

    assert_eq "exit code is 0" "0" "$exit_code"
    assert_ne "ticket ID is non-empty" "" "$ticket_id"

    # Verify ticket dir exists
    local tracker_dir="$repo/.tickets-tracker"
    if [ -d "$tracker_dir/$ticket_id" ]; then
        assert_eq "ticket directory exists" "exists" "exists"
    else
        assert_eq "ticket directory exists" "exists" "missing"
    fi
}
test_exit_code_always_zero

# ── Test 8: Title warning disabled via config ─────────────────────────────────
echo ""
echo "Test 8: Title warning disabled when bug_report.title_warning_enabled=false"
test_title_warning_config_disabled() {
    local repo
    repo=$(_make_test_repo)

    # Create a dso-config.conf that disables title warning
    mkdir -p "$repo/.claude"
    cat > "$repo/.claude/dso-config.conf" <<'CONF'
bug_report.title_warning_enabled=false
CONF

    local ticket_id stderr_out
    stderr_out=$(mktemp)
    _CLEANUP_DIRS+=("$stderr_out")
    # Non-conforming title — but warning should be suppressed
    ticket_id=$(cd "$repo" && bash "$TICKET_CREATE_SCRIPT" bug "bad title no pattern" 2>"$stderr_out") || true

    local stderr_content
    stderr_content=$(cat "$stderr_out")

    # Should NOT contain a title pattern warning
    _tmp="$stderr_content"; shopt -s nocasematch
    if [[ "$_tmp" =~ title.*pattern|title.*format|"Bug title" ]]; then
        assert_eq "title warning suppressed by config" "no title warning" "has title warning"
    else
        assert_eq "title warning suppressed by config" "no title warning" "no title warning"
    fi; shopt -u nocasematch
}
test_title_warning_config_disabled

# ── Test 9: Unicode arrow conversion in ticket-edit.sh ────────────────────────
echo ""
echo "Test 9: Unicode arrow (U+2192) converted to ASCII (->) in title on edit"
test_unicode_arrow_conversion_edit() {
    local repo
    repo=$(_make_test_repo)

    # First create a ticket
    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_CREATE_SCRIPT" bug "CLI: original title -> ok" 2>/dev/null) || true

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created for edit test" "non-empty" "empty"
        return
    fi

    # Edit with unicode arrow in new title
    # Use printf to get the actual unicode arrow character U+2192 (→)
    local unicode_edit_title
    unicode_edit_title=$(printf 'CLI: edited \xe2\x86\x92 result')
    (cd "$repo" && bash "$TICKET_EDIT_SCRIPT" "$ticket_id" --title="$unicode_edit_title" 2>/dev/null) || true

    # Find the EDIT event and check the title
    local tracker_dir="$repo/.tickets-tracker"
    local edit_file
    edit_file=$(find "$tracker_dir/$ticket_id" -maxdepth 1 -name '*-EDIT.json' ! -name '.*' 2>/dev/null | head -1)

    if [ -z "$edit_file" ]; then
        assert_eq "edit event exists" "exists" "missing"
        return
    fi

    local edited_title
    edited_title=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    e = json.load(f)
print(e['data']['fields'].get('title', 'NO_TITLE'))
" "$edit_file")

    assert_contains "edited title contains ASCII arrow" "->" "$edited_title"
}
test_unicode_arrow_conversion_edit

# ── Test 10: Warnings only apply to bug tickets ──────────────────────────────
echo ""
echo "Test 10: No warnings for non-bug ticket types"
test_no_warnings_for_non_bug() {
    local repo
    repo=$(_make_test_repo)

    local ticket_id stderr_out
    stderr_out=$(mktemp)
    _CLEANUP_DIRS+=("$stderr_out")
    # Create a task (not a bug) with non-conforming title/description
    ticket_id=$(cd "$repo" && bash "$TICKET_CREATE_SCRIPT" task "bad title" -d "no headers" 2>"$stderr_out") || true

    local stderr_content
    stderr_content=$(cat "$stderr_out")

    # Should NOT contain any bug-specific warnings
    _tmp="$stderr_content"; shopt -s nocasematch
    if [[ "$_tmp" =~ title.*pattern|"Expected Behavior"|description.*size|"Bug title" ]]; then
        assert_eq "no bug warnings for task type" "no warnings" "has warnings"
    else
        assert_eq "no bug warnings for task type" "no warnings" "no warnings"
    fi; shopt -u nocasematch
}
test_no_warnings_for_non_bug

print_summary
