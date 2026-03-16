#!/usr/bin/env bash
# tests/hooks/test-behavioral-equivalence.sh
# RED PHASE tests for behavioral equivalence between .claude/hooks/ and
# hooks/ after Phase 7 migration.
#
# Verifies that the plugin hooks produce identical exit codes to the
# removed .claude/hooks/ scripts. Since the actual hooks already live
# in the plugin root, this test verifies that settings.json references
# the plugin hooks and they produce correct behavior.
#
# Tests:
#   test_behavioral_equivalence_validation_gate_exempt
#   test_behavioral_equivalence_review_gate_no_pending
#   test_behavioral_equivalence_auto_format_non_py

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

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
# test_behavioral_equivalence_review_gate_no_pending
#
# The plugin review-gate.sh should exit 0 when there is no
# pending review (no review state file). This verifies behavioral
# equivalence with the original .claude/hooks/review-gate.sh.
# ============================================================

PLUGIN_REVIEW_GATE="$PLUGIN_ROOT/hooks/review-gate.sh"

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

PLUGIN_AUTO_FORMAT="$PLUGIN_ROOT/hooks/auto-format.sh"

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
# After migration, settings.json should reference plugin paths
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
# test_behavioral_equivalence_post_optimization
#
# Post-optimization: tool logging has been removed from all dispatchers
# (epic put3/ild8). Verify that:
#   1. pre-bash dispatcher does NOT reference tool_logging_pre
#   2. post-bash dispatcher does NOT reference tool_logging_post
#   3. No catch-all (empty-matcher) entries remain in settings.json
# ============================================================

PRE_BASH_DISPATCHER="$PLUGIN_ROOT/hooks/dispatchers/pre-bash.sh"
POST_BASH_DISPATCHER="$PLUGIN_ROOT/hooks/dispatchers/post-bash.sh"

# Verify tool-logging removed from pre-bash
if [[ -f "$PRE_BASH_DISPATCHER" ]]; then
    if grep -q 'tool_logging_pre\|tool.logging.*pre' "$PRE_BASH_DISPATCHER" 2>/dev/null; then
        actual="still_has_tool_logging_pre"
    else
        actual="tool_logging_removed"
    fi
else
    actual="dispatcher_missing"
fi
assert_eq \
    "test_behavioral_equivalence_post_optimization: pre-bash tool-logging removed" \
    "tool_logging_removed" \
    "$actual"

# Verify tool-logging removed from post-bash
if [[ -f "$POST_BASH_DISPATCHER" ]]; then
    if grep -q 'tool_logging_post\|tool.logging.*post' "$POST_BASH_DISPATCHER" 2>/dev/null; then
        actual="still_has_tool_logging_post"
    else
        actual="tool_logging_removed"
    fi
else
    actual="dispatcher_missing"
fi
assert_eq \
    "test_behavioral_equivalence_post_optimization: post-bash tool-logging removed" \
    "tool_logging_removed" \
    "$actual"

# Verify no catch-all empty-matcher in settings.json PreToolUse/PostToolUse
if [[ -f "$SETTINGS_FILE" ]]; then
    HAS_EMPTY_MATCHER="no"
    EMPTY_CHECK=$(SETTINGS_JSON_PATH="$SETTINGS_FILE" python3 -c "
import json, os, sys
with open(os.environ['SETTINGS_JSON_PATH']) as f:
    d = json.load(f)
hooks = d.get('hooks', {})
for event in ['PreToolUse', 'PostToolUse']:
    for group in hooks.get(event, []):
        if group.get('matcher') == '':
            print(f'{event} has empty matcher')
            sys.exit(1)
sys.exit(0)
" 2>&1) || HAS_EMPTY_MATCHER="yes"
fi
assert_eq \
    "test_behavioral_equivalence_post_consolidation: no catch-all empty-matcher hooks" \
    "no" \
    "$HAS_EMPTY_MATCHER"

# ============================================================
# Summary
# ============================================================

print_summary
