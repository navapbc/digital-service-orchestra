#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-pre-compact.sh
# Tests for .claude/hooks/pre-compact-checkpoint.sh
#
# pre-compact-checkpoint.sh is a PreCompact hook that auto-saves work state
# before context compaction. Always exits 0. Outputs structured markdown.

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/pre-compact-checkpoint.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# make_test_repo: create a minimal git repo with one committed file and one
# uncommitted (untracked) file so _HAS_REAL_CHANGES is non-empty.
# Prints the repo path.
make_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    (
        cd "$tmpdir"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "initial" > README.md
        git add README.md
        git commit -q -m "initial commit"
        # Uncommitted work so _HAS_REAL_CHANGES is non-empty
        echo "work-in-progress" > work.txt
    ) 2>/dev/null
    echo "$tmpdir"
}

run_hook_exit() {
    local input="$1"
    local exit_code=0
    local tmpdir
    tmpdir=$(make_test_repo)
    (cd "$tmpdir" && echo "$input" | bash "$HOOK") > /dev/null 2>/dev/null || exit_code=$?
    rm -rf "$tmpdir"
    echo "$exit_code"
}

run_hook_output() {
    local input="$1"
    local tmpdir
    tmpdir=$(make_test_repo)
    local out
    out=$(cd "$tmpdir" && echo "$input" | bash "$HOOK" 2>/dev/null)
    rm -rf "$tmpdir"
    echo "$out"
}

# test_pre_compact_exits_zero_on_valid_hook_input
# Normal invocation from a git repo → exit 0
INPUT='{"hook_type":"PreCompact","session_id":"test-123"}'
EXIT_CODE=$(run_hook_exit "$INPUT")
assert_eq "test_pre_compact_exits_zero_on_valid_hook_input" "0" "$EXIT_CODE"

# test_pre_compact_exits_zero_on_empty_input
# Empty stdin → exit 0 (PreCompact hook doesn't read stdin meaningfully)
EXIT_CODE=$(run_hook_exit "")
assert_eq "test_pre_compact_exits_zero_on_empty_input" "0" "$EXIT_CODE"

# test_pre_compact_produces_recovery_state_output
# Should output "# Recovery State" header in its checkpoint markdown
OUTPUT=$(run_hook_output '{"hook_type":"PreCompact","session_id":"test-123"}')
assert_contains "test_pre_compact_produces_recovery_state_output" "Recovery State" "$OUTPUT"

# test_pre_compact_output_contains_tasks_line
# Output should contain "Tasks:" line
OUTPUT=$(run_hook_output '{"hook_type":"PreCompact","session_id":"test-123"}')
assert_contains "test_pre_compact_output_contains_tasks_line" "Tasks:" "$OUTPUT"

# test_pre_compact_output_contains_changes_line
# Output should contain "Changes:" line
OUTPUT=$(run_hook_output '{"hook_type":"PreCompact","session_id":"test-123"}')
assert_contains "test_pre_compact_output_contains_changes_line" "Changes:" "$OUTPUT"

# ============================================================
# Group: Config-driven checkpoint message
# ============================================================
# These tests verify that pre-compact-checkpoint.sh uses CLAUDE_PLUGIN_ROOT to
# read workflow-config.yaml and uses the configured checkpoint.commit_label
# instead of hardcoding 'checkpoint: pre-compaction auto-save'.
#
# test_pre_compact_config_driven_checkpoint_label
#   MUST FAIL in red phase: hook currently hardcodes 'checkpoint: pre-compaction auto-save'
#   and does not read checkpoint.commit_label from workflow-config.yaml.
# test_pre_compact_backward_compat_default_message
#   MUST PASS in red phase: without CLAUDE_PLUGIN_ROOT, output still contains
#   'Recovery State' header (unchanged backward-compat behavior).

# test_pre_compact_config_driven_checkpoint_label
# CLAUDE_PLUGIN_ROOT with workflow-config.yaml:
#   checkpoint:
#     commit_label: 'checkpoint: my-project auto-save'
# Run hook and check that the git commit message would use that label.
# MUST FAIL — hook currently hardcodes 'checkpoint: pre-compaction auto-save'
#
# Strategy: the hook calls 'git commit -m "checkpoint: pre-compaction auto-save"'
# We can't intercept the git call directly in a unit test, but we can verify
# via the hook's stdout output: when the config-driven label is honored, the hook
# should reflect the configured label in its output (e.g. in a "Checkpoint:" line).
# In red phase, the hook ignores the config and always outputs 'pre-compaction auto-save'.
# We assert that the output contains the configured label string — this FAILS in red phase.
_PC_PLUGIN_ROOT=$(mktemp -d)
cat > "$_PC_PLUGIN_ROOT/workflow-config.yaml" << 'YAML_EOF'
version: "1.0.0"
checkpoint:
  commit_label: 'checkpoint: my-project auto-save'
YAML_EOF

# Probe for python3 with pyyaml using the same portable pattern as other hook tests.
# Tries project venv first (local dev), falls back to system python3 (CI).
_PC_VENV_PYTHON=""
for _py_candidate in \
        "$REPO_ROOT/app/.venv/bin/python3" \
        "$REPO_ROOT/.venv/bin/python3" \
        "/usr/bin/python3" \
        "python3"; do
    [[ -z "$_py_candidate" ]] && continue
    if "$_py_candidate" -c "import yaml" 2>/dev/null; then
        _PC_VENV_PYTHON="$_py_candidate"
        break
    fi
done
_PC_OUTPUT=$(CLAUDE_PLUGIN_ROOT="$_PC_PLUGIN_ROOT" CLAUDE_PLUGIN_PYTHON="$_PC_VENV_PYTHON" run_hook_output \
    '{"hook_type":"PreCompact","session_id":"test-config-label"}')
# When config is honored, the output (or behavior) should reflect 'my-project auto-save'.
# In red phase: hook hardcodes the label and does not read config, so this FAILS.
assert_contains "test_pre_compact_config_driven_checkpoint_label" \
    "my-project auto-save" "$_PC_OUTPUT"

rm -rf "$_PC_PLUGIN_ROOT"

# test_pre_compact_backward_compat_default_message
# No CLAUDE_PLUGIN_ROOT set
# Output still contains 'Recovery State' header (unchanged)
OUTPUT=$(run_hook_output '{"hook_type":"PreCompact","session_id":"test-backward"}')
assert_contains "test_pre_compact_backward_compat_default_message" "Recovery State" "$OUTPUT"

# ============================================================
# Group: bd → tk migration (RED phase)
# ============================================================
# These tests verify that pre-compact-checkpoint.sh has been migrated
# away from bd. They MUST FAIL against the current bd-based implementation.

# test_pre_compact_no_bd_calls_remain
# grep the hook source for 'bd ' — must return zero occurrences once migrated.
# MUST FAIL in red phase: hook calls 'bd list --status=in_progress' and 'bd sync'.
# Note: grep -c exits 1 on macOS when count is 0; use grep -o | wc -l to avoid
# the || fallback running when count is legitimately 0.
_PC2_BD_COUNT=$(grep -o 'bd ' "$HOOK" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "test_pre_compact_no_bd_calls_remain" "0" "$_PC2_BD_COUNT"

# test_pre_compact_output_uses_tk_status
# Run hook and assert the "Next:" recovery line uses 'tk list' rather than 'bd list'.
# MUST FAIL in red phase because the hook outputs:
#   "Next: Run 'bd list --status=in_progress' then 'bd show <id>' ..."
_PC2_OUTPUT=$(run_hook_output '{"hook_type":"PreCompact","session_id":"test-tk-migration"}')
# Extract the "Next:" line to test the specific instruction text
_PC2_NEXT_LINE=$(echo "$_PC2_OUTPUT" | grep '^Next:' || echo "")
assert_contains "test_pre_compact_output_uses_tk_status" "tk list" "$_PC2_NEXT_LINE"

print_summary
