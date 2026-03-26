#!/usr/bin/env bash
# tests/agents/test-reviewer-deep-arch-checklist.sh
# Asserts that the Deep Arch reviewer (code-reviewer-deep-arch.md) contains:
#   1. Agent and delta files exist
#   2. Tier identity section asserts synthesis role
#   3. Synthesis checklist is present (evaluate specialist findings)
#   4. Architectural boundary checks (hook isolation, skill namespacing, ticket system, plugin portability)
#   5. Specialist conflict detection sub-criteria (contradictory findings resolution)
#   6. Awareness of project-specific sub-criteria from specialist agents
#   7. Unified verdict section covers all 5 dimensions
#   8. Output constraint allows scoring all 5 dimensions (not N/A like specialists)
#
# Usage: bash tests/agents/test-reviewer-deep-arch-checklist.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_FILE="$REPO_ROOT/plugins/dso/agents/code-reviewer-deep-arch.md"
DELTA_FILE="$REPO_ROOT/plugins/dso/docs/workflows/prompts/reviewer-delta-deep-arch.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-reviewer-deep-arch-checklist.sh ==="
echo ""

# ── Prerequisite: files exist ─────────────────────────────────────────────────
echo "--- prerequisite: agent and delta files exist ---"
_snapshot_fail
[[ -f "$AGENT_FILE" ]]
assert_eq "agent file exists" "0" "$?"
[[ -f "$DELTA_FILE" ]]
assert_eq "delta file exists" "0" "$?"
assert_pass_if_clean "file_existence"
echo ""

# ── T1: Tier identity section asserts synthesis role ──────────────────────────
echo "--- T1: tier identity asserts synthesis/architectural oversight role ---"
_snapshot_fail

_found_identity=0
if grep -qiE "Architectural Reviewer|architectural.*oversight|synthesis.*specialist|Deep.*Opus" "$DELTA_FILE" 2>/dev/null; then
    _found_identity=1
fi
assert_eq "delta contains Architectural Reviewer / Opus tier identity" "1" "$_found_identity"
assert_pass_if_clean "tier_identity_arch_reviewer"
echo ""

# ── T2: Synthesis checklist section present ───────────────────────────────────
echo "--- T2: synthesis checklist section present ---"
_snapshot_fail

_found_synthesis=0
if grep -qiE "Synthesis|Evaluate Specialist|synthesize.*findings|specialist.*findings" "$DELTA_FILE" 2>/dev/null; then
    _found_synthesis=1
fi
assert_eq "delta contains synthesis / evaluate specialist findings section" "1" "$_found_synthesis"
assert_pass_if_clean "synthesis_checklist_section_present"
echo ""

# ── T3: Architectural boundary — hook isolation ───────────────────────────────
echo "--- T3: architectural boundary check — hook isolation ---"
_snapshot_fail

_found_hook=0
if grep -qiE "hook isolation|hook.*dispatcher|dispatcher.*hook|pre-bash|post-bash" "$DELTA_FILE" 2>/dev/null; then
    _found_hook=1
fi
assert_eq "delta contains hook isolation architectural boundary check" "1" "$_found_hook"
assert_pass_if_clean "arch_boundary_hook_isolation"
echo ""

# ── T4: Architectural boundary — skill namespacing ────────────────────────────
echo "--- T4: architectural boundary check — skill namespacing ---"
_snapshot_fail

_found_skill_ns=0
if grep -qiE "skill.*namespace|namespace.*skill|\/dso:.*skill|skill.*qualified|unqualified.*skill" "$DELTA_FILE" 2>/dev/null; then
    _found_skill_ns=1
fi
assert_eq "delta contains skill namespacing architectural boundary check" "1" "$_found_skill_ns"
assert_pass_if_clean "arch_boundary_skill_namespacing"
echo ""

# ── T5: Architectural boundary — ticket system encapsulation ──────────────────
echo "--- T5: architectural boundary check — ticket system encapsulation ---"
_snapshot_fail

_found_ticket=0
if grep -qiE "ticket.*encapsul|ticket.*system.*bound|tickets.*worktree|ticket.*event.*log|event.sourced" "$DELTA_FILE" 2>/dev/null; then
    _found_ticket=1
fi
assert_eq "delta contains ticket system encapsulation architectural boundary check" "1" "$_found_ticket"
assert_pass_if_clean "arch_boundary_ticket_encapsulation"
echo ""

# ── T6: Architectural boundary — plugin portability ───────────────────────────
echo "--- T6: architectural boundary check — plugin portability ---"
_snapshot_fail

_found_plugin_portability=0
if grep -qiE "plugin.*portab|portab.*plugin|dso-config.*conf|config.*driven.*path|host.*project.*path" "$DELTA_FILE" 2>/dev/null; then
    _found_plugin_portability=1
fi
assert_eq "delta contains plugin portability architectural boundary check" "1" "$_found_plugin_portability"
assert_pass_if_clean "arch_boundary_plugin_portability"
echo ""

# ── T7: Specialist conflict detection — explicit sub-criteria ─────────────────
echo "--- T7: specialist conflict detection sub-criteria present ---"
_snapshot_fail

_found_conflict=0
if grep -qiE "contradict|conflict.*between.*specialist|specialist.*conflict|opposing.*finding|resolution.*conflict|correctness.*hygiene.*conflict" "$DELTA_FILE" 2>/dev/null; then
    _found_conflict=1
fi
assert_eq "delta contains specialist conflict detection sub-criteria" "1" "$_found_conflict"
assert_pass_if_clean "specialist_conflict_detection"
echo ""

# ── T8: Concrete conflict example (correctness vs. hygiene) ───────────────────
echo "--- T8: concrete conflict example — correctness vs. hygiene ---"
_snapshot_fail

_found_example=0
if grep -qiE "error handling.*complex|add.*error.*handling.*reduce.*complex|correctness.*says.*hygiene.*says" "$DELTA_FILE" 2>/dev/null; then
    _found_example=1
fi
assert_eq "delta contains concrete correctness-vs-hygiene conflict example" "1" "$_found_example"
assert_pass_if_clean "conflict_correctness_hygiene_example"
echo ""

# ── T9: Domain-specific contradiction awareness — bash patterns ───────────────
echo "--- T9: domain-specific contradiction awareness — bash patterns ---"
_snapshot_fail

_found_bash_domain=0
if grep -qiE "bash.*pattern|\.sh.*pattern|shell.*specific|bash.*sub.criteria" "$DELTA_FILE" 2>/dev/null; then
    _found_bash_domain=1
fi
assert_eq "delta has domain-specific awareness of bash pattern sub-criteria" "1" "$_found_bash_domain"
assert_pass_if_clean "domain_awareness_bash_patterns"
echo ""

# ── T10: Domain-specific contradiction awareness — Python patterns ─────────────
echo "--- T10: domain-specific contradiction awareness — Python patterns ---"
_snapshot_fail

_found_python_domain=0
if grep -qiE "python.*pattern|\.py.*pattern|python.*sub.criteria|fcntl|flock.*conflict" "$DELTA_FILE" 2>/dev/null; then
    _found_python_domain=1
fi
assert_eq "delta has domain-specific awareness of Python pattern sub-criteria" "1" "$_found_python_domain"
assert_pass_if_clean "domain_awareness_python_patterns"
echo ""

# ── T11: Unified verdict covers all 5 dimensions ──────────────────────────────
echo "--- T11: unified verdict section covers all 5 dimensions ---"
_snapshot_fail

_found_verdict=0
if grep -qiE "Unified Verdict|unified.*verdict" "$DELTA_FILE" 2>/dev/null; then
    _found_verdict=1
fi
assert_eq "delta contains Unified Verdict section" "1" "$_found_verdict"

# Check all 5 dimensions are mentioned in the verdict section
_dimensions_ok=1
for dim in "hygiene" "design" "maintainability" "correctness" "verification"; do
    if ! grep -qF "$dim" "$DELTA_FILE" 2>/dev/null; then
        _dimensions_ok=0
        break
    fi
done
assert_eq "delta unified verdict references all 5 score dimensions" "1" "$_dimensions_ok"
assert_pass_if_clean "unified_verdict_all_dimensions"
echo ""

# ── T12: Generated agent file contains hook isolation check ───────────────────
echo "--- T12: generated agent file contains hook isolation boundary check ---"
_snapshot_fail

_found_hook_in_agent=0
if grep -qiE "hook isolation|hook.*dispatcher|pre-bash|post-bash" "$AGENT_FILE" 2>/dev/null; then
    _found_hook_in_agent=1
fi
assert_eq "generated agent file contains hook isolation boundary check" "1" "$_found_hook_in_agent"
assert_pass_if_clean "generated_agent_hook_isolation"
echo ""

# ── T13: Generated agent file contains skill namespacing check ────────────────
echo "--- T13: generated agent file contains skill namespacing boundary check ---"
_snapshot_fail

_found_skill_in_agent=0
if grep -qiE "skill.*namespace|skill.*qualified|unqualified.*skill" "$AGENT_FILE" 2>/dev/null; then
    _found_skill_in_agent=1
fi
assert_eq "generated agent file contains skill namespacing boundary check" "1" "$_found_skill_in_agent"
assert_pass_if_clean "generated_agent_skill_namespacing"
echo ""

# ── T14: Generated agent file contains specialist conflict detection ───────────
echo "--- T14: generated agent file contains specialist conflict detection ---"
_snapshot_fail

_found_conflict_in_agent=0
if grep -qiE "contradict|conflict.*between.*specialist|specialist.*conflict" "$AGENT_FILE" 2>/dev/null; then
    _found_conflict_in_agent=1
fi
assert_eq "generated agent file contains specialist conflict detection sub-criteria" "1" "$_found_conflict_in_agent"
assert_pass_if_clean "generated_agent_conflict_detection"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
