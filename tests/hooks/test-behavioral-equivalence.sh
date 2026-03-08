#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-behavioral-equivalence.sh
# RED PHASE tests for behavioral equivalence between .claude/hooks/ and
# lockpick-workflow/hooks/ after Phase 7 migration.
#
# Verifies that the plugin hooks produce identical exit codes to the
# removed .claude/hooks/ scripts. Since the actual hooks already live
# in lockpick-workflow/, this test verifies that settings.json references
# the plugin hooks and they produce correct behavior.
#
# Tests:
#   test_behavioral_equivalence_validation_gate_exempt
#   test_behavioral_equivalence_review_gate_no_pending
#   test_behavioral_equivalence_auto_format_non_py

REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# Temporary directory for test isolation
TEST_TMP=$(mktemp -d)
cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

# ============================================================
# Helper: build JSON tool input and pipe to a hook script
# Returns the exit code.
# ============================================================
run_hook_with_input() {
    local hook_path="$1"
    local tool_name="$2"
    local tool_input_key="$3"
    local tool_input_val="$4"
    local json

    if [[ -n "$tool_input_key" ]]; then
        json=$(jq -n --arg tn "$tool_name" --arg k "$tool_input_key" --arg v "$tool_input_val" \
            '{tool_name: $tn, tool_input: {($k): $v}}')
    else
        json=$(jq -n --arg tn "$tool_name" \
            '{tool_name: $tn, tool_input: {}}')
    fi

    local exit_code=0
    echo "$json" | bash "$hook_path" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# ============================================================
# test_behavioral_equivalence_validation_gate_exempt
#
# The plugin validation-gate.sh should exit 0 for exempt commands
# (e.g., non-Bash/Edit/Write tools). This verifies the plugin hook
# behaves the same as the original .claude/hooks/validation-gate.sh.
#
# Pre-migration: uses .claude/hooks/ path (will work since files exist)
# Post-migration: should use lockpick-workflow/hooks/ path
# ============================================================

PLUGIN_VALIDATION_GATE="$REPO_ROOT/lockpick-workflow/hooks/validation-gate.sh"

if [[ -f "$PLUGIN_VALIDATION_GATE" ]]; then
    # Test with a Read tool call (should be exempt from validation gate)
    EXIT_CODE=$(run_hook_with_input "$PLUGIN_VALIDATION_GATE" "Read" "file_path" "/tmp/test.txt")
    assert_eq \
        "test_behavioral_equivalence_validation_gate_exempt: plugin validation-gate exits 0 for Read tool" \
        "0" \
        "$EXIT_CODE"

    # Test with a WebSearch tool call (also exempt)
    EXIT_CODE=$(run_hook_with_input "$PLUGIN_VALIDATION_GATE" "WebSearch" "" "")
    assert_eq \
        "test_behavioral_equivalence_validation_gate_exempt: plugin validation-gate exits 0 for WebSearch tool" \
        "0" \
        "$EXIT_CODE"
else
    # Plugin hook not found — expected to exist from Phase 1
    assert_eq \
        "test_behavioral_equivalence_validation_gate_exempt: plugin validation-gate.sh exists" \
        "yes" \
        "no"
fi

# ============================================================
# test_behavioral_equivalence_review_gate_no_pending
#
# The plugin review-gate.sh should exit 0 when there is no
# pending review (no review state file). This verifies behavioral
# equivalence with the original .claude/hooks/review-gate.sh.
# ============================================================

PLUGIN_REVIEW_GATE="$REPO_ROOT/lockpick-workflow/hooks/review-gate.sh"

if [[ -f "$PLUGIN_REVIEW_GATE" ]]; then
    # Create a clean environment where no review is pending
    # The review gate checks for pending-review state; without one it should pass
    EXIT_CODE=$(run_hook_with_input "$PLUGIN_REVIEW_GATE" "Bash" "command" "echo hello")
    assert_eq \
        "test_behavioral_equivalence_review_gate_no_pending: plugin review-gate exits 0 when no pending review" \
        "0" \
        "$EXIT_CODE"
else
    assert_eq \
        "test_behavioral_equivalence_review_gate_no_pending: plugin review-gate.sh exists" \
        "yes" \
        "no"
fi

# ============================================================
# test_behavioral_equivalence_auto_format_non_py
#
# The plugin auto-format.sh should exit 0 for non-.py file edits.
# This verifies behavioral equivalence with the original
# .claude/hooks/auto-format.sh.
# ============================================================

PLUGIN_AUTO_FORMAT="$REPO_ROOT/lockpick-workflow/hooks/auto-format.sh"

if [[ -f "$PLUGIN_AUTO_FORMAT" ]]; then
    # Edit a non-.py file — auto-format should pass through (exit 0)
    EXIT_CODE=$(run_hook_with_input "$PLUGIN_AUTO_FORMAT" "Edit" "file_path" "/tmp/test.txt")
    assert_eq \
        "test_behavioral_equivalence_auto_format_non_py: plugin auto-format exits 0 for non-.py file" \
        "0" \
        "$EXIT_CODE"

    # Edit a .md file — also should exit 0
    EXIT_CODE=$(run_hook_with_input "$PLUGIN_AUTO_FORMAT" "Edit" "file_path" "/tmp/README.md")
    assert_eq \
        "test_behavioral_equivalence_auto_format_non_py: plugin auto-format exits 0 for .md file" \
        "0" \
        "$EXIT_CODE"
else
    assert_eq \
        "test_behavioral_equivalence_auto_format_non_py: plugin auto-format.sh exists" \
        "yes" \
        "no"
fi

# ============================================================
# Verify settings.json references plugin hooks (post-migration check)
#
# After migration, settings.json should reference lockpick-workflow/
# or CLAUDE_PLUGIN_ROOT paths. This is a behavioral equivalence
# pre-condition: if settings.json still points to .claude/hooks/,
# the plugin hooks are NOT being used.
#
# MUST FAIL before migration — settings.json still uses .claude/hooks/.
# ============================================================

SETTINGS_FILE="$REPO_ROOT/.claude/settings.json"

USES_OLD_HOOKS="no"
if grep -q '\.claude/hooks' "$SETTINGS_FILE" 2>/dev/null; then
    USES_OLD_HOOKS="yes"
fi

assert_eq \
    "test_behavioral_equivalence_settings_migrated: settings.json no longer references .claude/hooks/" \
    "no" \
    "$USES_OLD_HOOKS"

# ============================================================
# Summary
# ============================================================

print_summary
