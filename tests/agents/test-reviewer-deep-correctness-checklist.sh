#!/usr/bin/env bash
# tests/agents/test-reviewer-deep-correctness-checklist.sh
# Asserts that the Deep Correctness reviewer (code-reviewer-deep-correctness.md) contains:
#   1. Agent and delta files exist
#   2. Tier identity section asserts correctness-only focus
#   3. Correctness Checklist section is present
#   4. Bash-specific correctness patterns (set -euo pipefail, trap handling, exit code propagation, variable quoting)
#   5. Python-specific correctness patterns (exception chaining, resource cleanup, fcntl.flock usage)
#   6. Acceptance criteria validation sub-criteria (when issue context is provided)
#   7. Output constraint section sets non-correctness dimensions to N/A
#   8. No duplicate base guidance (ruff/mypy suppression already in base)
#
# Usage: bash tests/agents/test-reviewer-deep-correctness-checklist.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_FILE="$REPO_ROOT/plugins/dso/agents/code-reviewer-deep-correctness.md"
DELTA_FILE="$REPO_ROOT/plugins/dso/docs/workflows/prompts/reviewer-delta-deep-correctness.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-reviewer-deep-correctness-checklist.sh ==="
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

# ── T1: Tier identity section asserts correctness-only focus ──────────────────
echo "--- T1: tier identity asserts correctness-only focus ---"
_snapshot_fail

_found_identity=0
if grep -qi "Correctness Specialist\|correctness.*specialist\|deep.*correctness" "$DELTA_FILE" 2>/dev/null; then
    _found_identity=1
fi
assert_eq "delta contains Correctness Specialist tier identity" "1" "$_found_identity"
assert_pass_if_clean "tier_identity_correctness_specialist"
echo ""

# ── T2: Correctness Checklist section present ─────────────────────────────────
echo "--- T2: Correctness Checklist section present ---"
_snapshot_fail

_found_checklist=0
if grep -qi "Correctness Checklist\|correctness checklist" "$DELTA_FILE" 2>/dev/null; then
    _found_checklist=1
fi
assert_eq "delta contains Correctness Checklist section" "1" "$_found_checklist"
assert_pass_if_clean "correctness_checklist_section_present"
echo ""

# ── T3: Bash-specific — set -euo pipefail ─────────────────────────────────────
echo "--- T3: bash-specific pattern — set -euo pipefail ---"
_snapshot_fail

_found_set_e=0
if grep -qE "set -euo pipefail|set -e|pipefail" "$DELTA_FILE" 2>/dev/null; then
    _found_set_e=1
fi
assert_eq "delta contains set -euo pipefail bash correctness pattern" "1" "$_found_set_e"
assert_pass_if_clean "bash_set_euo_pipefail_pattern"
echo ""

# ── T4: Bash-specific — trap handling ─────────────────────────────────────────
echo "--- T4: bash-specific pattern — trap handling ---"
_snapshot_fail

_found_trap=0
if grep -qi "trap\|SIGURG\|SIGTERM\|signal handling" "$DELTA_FILE" 2>/dev/null; then
    _found_trap=1
fi
assert_eq "delta contains trap/signal handling bash correctness pattern" "1" "$_found_trap"
assert_pass_if_clean "bash_trap_handling_pattern"
echo ""

# ── T5: Bash-specific — exit code propagation ─────────────────────────────────
echo "--- T5: bash-specific pattern — exit code propagation ---"
_snapshot_fail

_found_exit_code=0
if grep -qiE "exit code|exit status|\\\$\?" "$DELTA_FILE" 2>/dev/null; then
    _found_exit_code=1
fi
assert_eq "delta contains exit code propagation bash correctness pattern" "1" "$_found_exit_code"
assert_pass_if_clean "bash_exit_code_propagation_pattern"
echo ""

# ── T6: Bash-specific — variable quoting ──────────────────────────────────────
echo "--- T6: bash-specific pattern — variable quoting ---"
_snapshot_fail

_found_quoting=0
if grep -qiE "quot|unquoted|word.split" "$DELTA_FILE" 2>/dev/null; then
    _found_quoting=1
fi
assert_eq "delta contains variable quoting bash correctness pattern" "1" "$_found_quoting"
assert_pass_if_clean "bash_variable_quoting_pattern"
echo ""

# ── T7: Python-specific — exception chaining ──────────────────────────────────
echo "--- T7: python-specific pattern — exception chaining ---"
_snapshot_fail

_found_exc_chain=0
if grep -qiE "exception chain|raise.*from|bare.*raise|except.*pass" "$DELTA_FILE" 2>/dev/null; then
    _found_exc_chain=1
fi
assert_eq "delta contains exception chaining Python correctness pattern" "1" "$_found_exc_chain"
assert_pass_if_clean "python_exception_chaining_pattern"
echo ""

# ── T8: Python-specific — resource cleanup (context manager / with) ───────────
echo "--- T8: python-specific pattern — resource cleanup ---"
_snapshot_fail

_found_resource=0
if grep -qiE "context manager|with.*open|with.*lock|resource cleanup|finally" "$DELTA_FILE" 2>/dev/null; then
    _found_resource=1
fi
assert_eq "delta contains resource cleanup Python correctness pattern" "1" "$_found_resource"
assert_pass_if_clean "python_resource_cleanup_pattern"
echo ""

# ── T9: Python-specific — fcntl.flock usage ───────────────────────────────────
echo "--- T9: python-specific pattern — fcntl.flock usage ---"
_snapshot_fail

_found_flock=0
if grep -qiE "fcntl|flock|file lock" "$DELTA_FILE" 2>/dev/null; then
    _found_flock=1
fi
assert_eq "delta contains fcntl.flock Python correctness pattern" "1" "$_found_flock"
assert_pass_if_clean "python_fcntl_flock_pattern"
echo ""

# ── T10: Acceptance criteria validation sub-criteria present ──────────────────
echo "--- T10: acceptance criteria validation sub-criteria present ---"
_snapshot_fail

_found_ac=0
if grep -qiE "acceptance criteria|ticket.*AC|issue context|AC validation|aligns? with.*AC" "$DELTA_FILE" 2>/dev/null; then
    _found_ac=1
fi
assert_eq "delta contains acceptance criteria validation sub-criteria" "1" "$_found_ac"
assert_pass_if_clean "acceptance_criteria_validation"
echo ""

# ── T11: Output constraint sets non-correctness dimensions to N/A ─────────────
echo "--- T11: output constraint sets non-correctness dimensions to N/A ---"
_snapshot_fail

_found_na=0
if grep -qiE "N/A.*hygiene|hygiene.*N/A|non.correctness.*N/A|N/A.*non.correctness" "$DELTA_FILE" 2>/dev/null; then
    _found_na=1
elif grep -q "N/A" "$DELTA_FILE" 2>/dev/null && grep -qi "hygiene\|design\|maintainability\|verification" "$DELTA_FILE" 2>/dev/null; then
    _found_na=1
fi
assert_eq "delta instructs non-correctness dimensions to use N/A" "1" "$_found_na"
assert_pass_if_clean "output_constraint_na_dimensions"
echo ""

# ── T12: No duplicate base guidance (ruff/mypy suppression) ──────────────────
echo "--- T12: delta does not duplicate base no-ruff/mypy guidance ---"
_snapshot_fail

ruff_count=$(grep -c "Do NOT report formatting" "$DELTA_FILE" 2>/dev/null || true)
assert_eq "delta must not duplicate base ruff/mypy suppression instruction" "0" "$ruff_count"
assert_pass_if_clean "no_duplicate_base_guidance"
echo ""

# ── T13: Generated agent file contains bash-specific correctness checks ────────
echo "--- T13: generated agent file contains bash-specific correctness patterns ---"
_snapshot_fail

_found_bash_in_agent=0
if grep -qE "set -euo pipefail|pipefail" "$AGENT_FILE" 2>/dev/null; then
    _found_bash_in_agent=1
fi
assert_eq "generated agent file contains bash set -euo pipefail pattern" "1" "$_found_bash_in_agent"
assert_pass_if_clean "generated_agent_bash_correctness"
echo ""

# ── T14: Generated agent file contains Python-specific correctness checks ──────
echo "--- T14: generated agent file contains Python-specific correctness patterns ---"
_snapshot_fail

_found_python_in_agent=0
if grep -qiE "fcntl|flock" "$AGENT_FILE" 2>/dev/null; then
    _found_python_in_agent=1
fi
assert_eq "generated agent file contains Python fcntl.flock pattern" "1" "$_found_python_in_agent"
assert_pass_if_clean "generated_agent_python_correctness"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
