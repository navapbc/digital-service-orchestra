#!/usr/bin/env bash
# tests/agents/test-file-writing-agents-have-retention.sh
# Structural-boundary test (per behavioral testing standard rule 5): every
# named dso:* agent that writes files under `isolation: "worktree"` must
# include a "## Worktree Retention" section instructing it to `git add -A`
# (stage, never commit) before returning, so the harness retains the worktree
# until the orchestrator can harvest the written files. Without this section
# the harness reaps the worktree on a CLEAN tree, losing the agent's work.
# Bug b8c8-8566-646e-4b61 tracks the underlying gap.
#
# This is a heading-presence assertion, not a content-string assertion —
# the actual retention mechanism is tested separately; this test only guards
# that each file-writing agent file references the retention instruction from
# a dedicated section.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-file-writing-agents-have-retention.sh ==="

AGENTS_DIR="$REPO_ROOT/plugins/dso/agents"

# Target set: agents dispatched under worktree isolation that write files
# (and therefore need retention staging). red-test-evaluator produces a verdict
# (read-only) and does not write files, so it is excluded. The four agents below
# all WRITE harvestable files: red-test-writer (test files), gov-copy-writer
# (YAML copy artifact), doc-writer (documentation files), ui-designer (design
# artifacts). Bug b8c8-8566-646e-4b61.
TARGET_AGENTS=(
    "red-test-writer"
    "gov-copy-writer"
    "doc-writer"
    "ui-designer"
)

_assert_has_retention_section() {
    local agent_name="$1"
    local agent_file="$AGENTS_DIR/${agent_name}.md"
    local has_section="missing"

    if [[ ! -f "$agent_file" ]]; then
        assert_eq "agent file exists: ${agent_name}.md" "exists" "missing"
        return
    fi

    # Heading-presence check only: look for a level-2 heading whose text
    # starts with "Worktree Retention".
    if grep -qE '^## Worktree Retention' "$agent_file"; then
        has_section="present"
    fi

    assert_eq "${agent_name}: has '## Worktree Retention' section" \
              "present" "$has_section"
}

for agent in "${TARGET_AGENTS[@]}"; do
    _assert_has_retention_section "$agent"
done

print_summary
