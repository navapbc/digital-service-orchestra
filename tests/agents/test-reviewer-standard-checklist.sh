#!/usr/bin/env bash
# tests/agents/test-reviewer-standard-checklist.sh
# Asserts that code-reviewer-standard.md contains:
#   1. All 5 scoring dimensions in its checklist
#   2. File-type-aware sub-criteria for bash scripts, Python code, and markdown files
#   3. Project-specific pattern checks (≥1 per dimension)
#   4. No duplicate base-guidance content (ruff/mypy suppression already in base)
#
# Usage: bash tests/agents/test-reviewer-standard-checklist.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_FILE="$REPO_ROOT/plugins/dso/agents/code-reviewer-standard.md"
DELTA_FILE="$REPO_ROOT/plugins/dso/docs/workflows/prompts/reviewer-delta-standard.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-reviewer-standard-checklist.sh ==="
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

# ── T1: All 5 dimensions present in checklist headers ─────────────────────────
echo "--- T1: all 5 checklist dimensions present in delta file ---"
_snapshot_fail

for dim_label in "Functionality" "Testing Coverage" "Code Hygiene" "Readability" "Object-Oriented Design"; do
    if grep -qF "### ${dim_label}" "$DELTA_FILE"; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        echo "FAIL: delta missing checklist section: ### ${dim_label}" >&2
    fi
done
assert_pass_if_clean "all_5_dimensions_present"
echo ""

# ── T2: File-type routing — bash script checks present ───────────────────────
echo "--- T2: bash script file-type routing present in delta file ---"
_snapshot_fail

# Must mention bash scripts with variable quoting check
if grep -qi "bash" "$DELTA_FILE" && grep -qi "quot" "$DELTA_FILE"; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: delta missing bash file-type routing with variable quoting check" >&2
fi
assert_pass_if_clean "bash_filetype_routing"
echo ""

# ── T3: File-type routing — Python code checks present ───────────────────────
echo "--- T3: Python code file-type routing present in delta file ---"
_snapshot_fail

# Must mention subprocess (instead of os.system)
if grep -qi "subprocess" "$DELTA_FILE"; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: delta missing Python file-type check (subprocess vs os.system)" >&2
fi
assert_pass_if_clean "python_filetype_routing"
echo ""

# ── T4: File-type routing — markdown/skill files present ─────────────────────
echo "--- T4: markdown/skill file-type routing present in delta file ---"
_snapshot_fail

# Must mention markdown or skill files
if grep -qiE "markdown|\.md|skill" "$DELTA_FILE"; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: delta missing markdown/skill file-type routing" >&2
fi
assert_pass_if_clean "markdown_filetype_routing"
echo ""

# ── T5: Project-specific correctness check ───────────────────────────────────
echo "--- T5: project-specific correctness check present ---"
_snapshot_fail

# Must have at least one project-specific correctness pattern
# e.g., shell injection via subprocess calls, hook exit codes
if grep -qiE "(hook|exit code|fcntl|flock|subprocess|injection)" "$DELTA_FILE"; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: delta missing project-specific correctness check (hook/exit-code/subprocess/injection)" >&2
fi
assert_pass_if_clean "project_specific_correctness"
echo ""

# ── T6: Project-specific verification check ──────────────────────────────────
echo "--- T6: project-specific verification check present ---"
_snapshot_fail

# Must reference test-index or RED marker or TDD patterns
if grep -qiE "(test.index|RED marker|\.test-index|tdd|red.test)" "$DELTA_FILE"; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: delta missing project-specific verification check (.test-index/RED marker/TDD)" >&2
fi
assert_pass_if_clean "project_specific_verification"
echo ""

# ── T7: Project-specific hygiene check ───────────────────────────────────────
echo "--- T7: project-specific hygiene check present ---"
_snapshot_fail

# Must mention hook conventions, jq-free requirement, or parse_json_field
if grep -qiE "(jq.free|parse_json_field|json_build|hook|no.jq)" "$DELTA_FILE"; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: delta missing project-specific hygiene check (jq-free/parse_json_field/hook conventions)" >&2
fi
assert_pass_if_clean "project_specific_hygiene"
echo ""

# ── T8: Project-specific maintainability check ───────────────────────────────
echo "--- T8: project-specific maintainability check present ---"
_snapshot_fail

# Must reference skill qualification, dso: prefix, or agent naming conventions
if grep -qiE "(dso:|skill|qualified|qualify|namespace)" "$DELTA_FILE"; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: delta missing project-specific maintainability check (skill qualification/dso: prefix)" >&2
fi
assert_pass_if_clean "project_specific_maintainability"
echo ""

# ── T9: Project-specific design check ────────────────────────────────────────
echo "--- T9: project-specific design check present ---"
_snapshot_fail

# Must mention hook architecture, dispatcher pattern, or ticket event-sourcing
if grep -qiE "(dispatcher|event.sourc|ticket|hook archit|pre-bash|post-bash)" "$DELTA_FILE"; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: delta missing project-specific design check (dispatcher/event-sourcing/ticket)" >&2
fi
assert_pass_if_clean "project_specific_design"
echo ""

# ── T10: No duplicate base guidance (ruff/mypy) ──────────────────────────────
echo "--- T10: delta does not duplicate base no-ruff/mypy guidance ---"
_snapshot_fail

# The base already says "Do NOT report formatting or linting violations"
# The delta should NOT repeat this same instruction verbatim
ruff_count=$(grep -c "Do NOT report formatting" "$DELTA_FILE" 2>/dev/null || true)
assert_eq "delta must not duplicate base ruff/mypy suppression instruction" "0" "$ruff_count"
assert_pass_if_clean "no_duplicate_base_guidance"
echo ""

# ── T11: Generated agent file contains file-type routing ─────────────────────
echo "--- T11: generated agent file (code-reviewer-standard.md) contains file-type routing ---"
_snapshot_fail

if grep -qi "bash" "$AGENT_FILE" && grep -qi "quot" "$AGENT_FILE"; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: generated agent file missing bash file-type routing" >&2
fi
assert_pass_if_clean "generated_agent_bash_routing"
echo ""

# ── T12: Dimension section headers use the correct mapping ───────────────────
# The delta uses section names that map to the 5 canonical dimensions:
# Functionality -> correctness, Testing Coverage -> verification,
# Code Hygiene -> hygiene, Readability -> maintainability,
# Object-Oriented Design -> design
echo "--- T12: dimension section name mapping is documented ---"
_snapshot_fail

# Expect a mapping comment or a "maps to" / "category:" annotation in the checklist
# OR the file uses the canonical JSON key names in findings-relevant context
for json_key in "correctness" "verification" "hygiene" "maintainability" "design"; do
    _key_found=0; grep -qF "\"${json_key}\"" "$DELTA_FILE" && _key_found=1; [[ "$_key_found" -eq 0 ]] && grep -qF "${json_key}" "$DELTA_FILE" && _key_found=1; if [[ "$_key_found" -eq 1 ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        echo "FAIL: delta missing reference to dimension key: ${json_key}" >&2
    fi
done
assert_pass_if_clean "dimension_key_references"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
