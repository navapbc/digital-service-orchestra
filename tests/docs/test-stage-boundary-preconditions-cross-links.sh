#!/usr/bin/env bash
# RED test: cross-links from skill/agent files to stage-boundary-preconditions docs
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
source "$REPO_ROOT/tests/lib/assert.sh"
echo "=== test-stage-boundary-preconditions-cross-links.sh ==="

DOC_REF="stage-boundary-preconditions"

_check_file_has_ref() {
    local file="$1"
    local label="$2"
    if [ -f "$file" ]; then
        local has_ref
        has_ref=$(grep -ic "$DOC_REF" "$file" || true)
        assert_eq "$label references $DOC_REF" "1" "$([ "$has_ref" -gt 0 ] && echo 1 || echo 0)"
    else
        assert_eq "$label exists" "exists" "missing"
    fi
}

test_sprint_skill_has_crosslink() {
    _check_file_has_ref "$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md" "sprint/SKILL.md"
}
test_preplanning_skill_has_crosslink() {
    _check_file_has_ref "$REPO_ROOT/plugins/dso/skills/preplanning/SKILL.md" "preplanning/SKILL.md"
}
test_implementation_plan_skill_has_crosslink() {
    _check_file_has_ref "$REPO_ROOT/plugins/dso/skills/implementation-plan/SKILL.md" "implementation-plan/SKILL.md"
}
test_brainstorm_skill_has_crosslink() {
    _check_file_has_ref "$REPO_ROOT/plugins/dso/skills/brainstorm/SKILL.md" "brainstorm/SKILL.md"
}
test_commit_workflow_has_crosslink() {
    _check_file_has_ref "$REPO_ROOT/plugins/dso/docs/workflows/COMMIT-WORKFLOW.md" "COMMIT-WORKFLOW.md"
}
test_completion_verifier_has_crosslink() {
    _check_file_has_ref "$REPO_ROOT/plugins/dso/agents/completion-verifier.md" "completion-verifier.md"
}

test_sprint_skill_has_crosslink
test_preplanning_skill_has_crosslink
test_implementation_plan_skill_has_crosslink
test_brainstorm_skill_has_crosslink
test_commit_workflow_has_crosslink
test_completion_verifier_has_crosslink
print_summary
