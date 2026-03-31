#!/usr/bin/env bash
# tests/scripts/test-claude-md-rule18-task-auth.sh
# Bug 859b-b48b: Verify rule 18 explicitly states that task-level
# instructions ("fix this bug") do NOT constitute user approval
# for editing safeguard files.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-claude-md-rule18-task-auth.sh ==="
echo ""

test_rule18_task_instructions_not_approval() {
    _snapshot_fail
    if [[ ! -f "$CLAUDE_MD" ]]; then
        (( ++FAIL ))
        printf "FAIL: CLAUDE.md not found\n" >&2
        assert_pass_if_clean "test_rule18_task_instructions_not_approval"
        return
    fi
    # Extract rule 18 context (the line containing "Never edit safeguard files")
    local _rule18
    _rule18=$(grep -i "never edit safeguard files" "$CLAUDE_MD" 2>/dev/null || echo "")
    local _has_task_auth_clarification=0
    # Rule 18 must explicitly state that task instructions do not satisfy the approval requirement
    if echo "$_rule18" | grep -qiE '(task.*(instruction|directive|request).*(do(es)? not|cannot|never).*(constitut|satisf|authoriz|override|count as))|(do(es)? not.*(constitut|satisf|count as|authoriz).*(approv|permission))'; then
        _has_task_auth_clarification=1
    fi
    assert_eq "rule 18 clarifies task instructions don't constitute safeguard approval (bug 859b-b48b)" "1" "$_has_task_auth_clarification"
    assert_pass_if_clean "test_rule18_task_instructions_not_approval"
}

echo "--- test_rule18_task_instructions_not_approval ---"
test_rule18_task_instructions_not_approval
echo ""

print_summary
