#!/usr/bin/env bash
# tests/agents/test-agents-have-session-head-sync.sh
# Structural-boundary test (per behavioral testing standard rule 5): every
# named dso:* agent dispatched under `isolation: "worktree"` must include a
# "## Startup: Session HEAD Sync" section so the sub-agent syncs its
# isolated worktree from origin/main → SESSION_HEAD before reading any
# source files. Bug a951-d6f2-0c21-443f tracks the underlying gap.
#
# This is a heading-presence assertion, not a content-string assertion —
# the actual sync logic is tested by tests/hooks/test-worktree-session-head-sync.sh
# (the sync script itself); this test only guards that each agent file
# references it from a startup section.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-agents-have-session-head-sync.sh ==="

AGENTS_DIR="$REPO_ROOT/plugins/dso/agents"

# Target set: agents dispatched under worktree isolation by fix-bug,
# debug-everything, sprint, brainstorm, etc. Composed investigator agents
# inherit the section from investigator-base.md via build-composed-agents.sh.
TARGET_AGENTS=(
    "investigator-basic"
    "investigator-intermediate"
    "investigator-intermediate-fallback"
    "investigator-advanced-code-tracer"
    "investigator-advanced-historical"
    "investigator-escalated-code-tracer"
    "investigator-escalated-empirical"
    "investigator-escalated-history"
    "investigator-escalated-web"
    "bot-psychologist"
    "completion-verifier"
    "red-test-writer"
    "red-test-evaluator"
    "gov-copy-writer"
    "doc-writer"
    "ui-designer"
)

_assert_has_startup_section() {
    local agent_name="$1"
    local agent_file="$AGENTS_DIR/${agent_name}.md"
    local has_section="missing"

    if [[ ! -f "$agent_file" ]]; then
        assert_eq "agent file exists: ${agent_name}.md" "exists" "missing"
        return
    fi

    # Heading-presence check only: look for a level-2 heading whose text
    # starts with "Startup:" and contains "Session HEAD Sync".
    if grep -qE '^## Startup:.*Session HEAD Sync' "$agent_file"; then
        has_section="present"
    fi

    assert_eq "${agent_name}: has '## Startup: Session HEAD Sync' section" \
              "present" "$has_section"
}

for agent in "${TARGET_AGENTS[@]}"; do
    _assert_has_startup_section "$agent"
done

print_summary
