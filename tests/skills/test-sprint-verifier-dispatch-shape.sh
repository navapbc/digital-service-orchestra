#!/usr/bin/env bash
# tests/skills/test-sprint-verifier-dispatch-shape.sh
# Structural-boundary test for the completion-verifier HARD-GATE in sprint SKILL.md.
#
# Per Behavioral Testing Standard Rule 5, instruction files (skills/, agents/,
# prompts/) are tested by their structural boundary — required section
# headings and required commands/script paths — not by raw content strings.
# This test asserts ONLY structural properties (heading presence, required
# subagent_type references, required file-path tokens). It does NOT grep
# arbitrary prose or guidance text; refactoring the HARD-GATE wording must
# not break this test as long as the required structural elements remain.
#
# Bug c716-952a (PR #182): completion-verifier dispatch shape was being
# paraphrased into hand-written prompts by the sprint orchestrator. This
# test guards against silent deletion or breakage of the HARD-GATE block.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$PLUGIN_ROOT/plugins/dso/skills/sprint/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-verifier-dispatch-shape.sh ==="

# ── test_sprint_skill_file_exists ───────────────────────────────────────────
echo "--- test_sprint_skill_file_exists ---"
if [[ -f "$SKILL_FILE" ]]; then
    assert_eq "test_sprint_skill_file_exists: SKILL.md exists" "present" "present"
else
    assert_eq "test_sprint_skill_file_exists: SKILL.md exists" "present" "missing"
    print_summary
    exit 1
fi

# ── test_verifier_dispatch_hard_gate_present ────────────────────────────────
# The HARD-GATE block guarding verifier dispatch shape must exist as a
# structural section in the skill. A test that greps for the literal section
# title would be a change-detector; instead we check that the SKILL.md
# contains at least one <HARD-GATE> block AND that AT LEAST ONE such block
# references the named subagent type "dso:completion-verifier" — the
# structural-boundary property that this dispatch is named-agent-typed.
echo "--- test_verifier_dispatch_hard_gate_present ---"
_hard_gate_count=$(grep -cE "^<HARD-GATE>$" "$SKILL_FILE" 2>/dev/null || echo 0)
assert_ne "test_verifier_dispatch_hard_gate_present: at least one <HARD-GATE> block exists" "0" "$_hard_gate_count"

_named_subagent_count=$(grep -cE '"dso:completion-verifier"' "$SKILL_FILE" 2>/dev/null || echo 0)
assert_ne "test_verifier_dispatch_hard_gate_present: named subagent type referenced" "0" "$_named_subagent_count"

# ── test_verifier_fallback_path_is_resolvable ───────────────────────────────
# The fallback dispatch form must reference the completion-verifier agent
# file at a resolution path that exists on disk. False-positive review
# findings have previously claimed the file is missing when an ambiguous
# relative path (`agents/completion-verifier.md`) was used. The fallback
# form MUST use `${CLAUDE_PLUGIN_ROOT}/agents/completion-verifier.md` (or
# any token that contains that suffix) so the path is unambiguously
# resolvable from a host-project worktree.
echo "--- test_verifier_fallback_path_is_resolvable ---"
_unambig_path_count=$(grep -cE 'CLAUDE_PLUGIN_ROOT.*agents/completion-verifier\.md' "$SKILL_FILE" 2>/dev/null || echo 0)
assert_ne "test_verifier_fallback_path_is_resolvable: SKILL.md uses CLAUDE_PLUGIN_ROOT-anchored path" "0" "$_unambig_path_count"

# Verify the actual file exists at the expected plugin-root-relative location.
_agent_file="$PLUGIN_ROOT/plugins/dso/agents/completion-verifier.md"
if [[ -f "$_agent_file" ]]; then
    _agent_present="present"
else
    _agent_present="missing: $_agent_file"
fi
assert_eq "test_verifier_fallback_path_is_resolvable: completion-verifier.md exists on disk" "present" "$_agent_present"

print_summary
