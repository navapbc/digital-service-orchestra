#!/usr/bin/env bash
# tests/agents/test-reviewer-light-checklist.sh
# Verifies the Light tier reviewer (code-reviewer-light.md) contains the expected
# checklist structure, file-type-aware sub-criteria, and linter suppression notes.
#
# Usage: bash tests/agents/test-reviewer-light-checklist.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_FILE="$REPO_ROOT/plugins/dso/agents/code-reviewer-light.md"
DELTA_FILE="$REPO_ROOT/plugins/dso/docs/workflows/prompts/reviewer-delta-light.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-reviewer-light-checklist.sh ==="
echo ""

# ── Prerequisite ─────────────────────────────────────────────────────────────
if [[ ! -f "$AGENT_FILE" ]]; then
    echo "SKIP: $AGENT_FILE not found"
    exit 0
fi

if [[ ! -f "$DELTA_FILE" ]]; then
    echo "SKIP: $DELTA_FILE not found"
    exit 0
fi

# ── Helper: search both agent and delta files ─────────────────────────────────
# The agent file is generated (composed from base + delta). The delta file is
# the source of truth for tier-specific content. We check both to be thorough.
agent_contains() {
    local pattern="$1"
    local _found=0
    grep -qF "$pattern" "$AGENT_FILE" && _found=1
    [[ "$_found" -eq 0 ]] && grep -qF "$pattern" "$DELTA_FILE" && _found=1
    [[ "$_found" -eq 1 ]]
}

# ============================================================
# test_light_checklist_section_present
# The Light Checklist section must exist in both the generated agent file
# and the delta source file.
# ============================================================
echo "--- test_light_checklist_section_present ---"
_snapshot_fail
assert_eq "agent file has Light Checklist section" \
    "0" "$(grep -q 'Light Checklist' "$AGENT_FILE"; echo $?)"
assert_eq "delta file has Light Checklist section" \
    "0" "$(grep -q 'Light Checklist' "$DELTA_FILE"; echo $?)"
assert_pass_if_clean "test_light_checklist_section_present"
echo ""

# ============================================================
# test_functionality_section_present
# Functionality is the highest-signal section — must always be present.
# ============================================================
echo "--- test_functionality_section_present ---"
_snapshot_fail
assert_eq "delta has Functionality section" \
    "0" "$(grep -q 'Functionality' "$DELTA_FILE"; echo $?)"
assert_pass_if_clean "test_functionality_section_present"
echo ""

# ============================================================
# test_bash_file_type_routing_present
# The checklist must contain bash-specific sub-criteria that distinguish
# bash scripts from Python code. We require an explicit "bash scripts" or
# "shell scripts" label in a checklist/review context (not just in header
# prose referencing build scripts).
# ============================================================
echo "--- test_bash_file_type_routing_present ---"
_snapshot_fail
# Require the delta to explicitly mention "bash scripts" or "shell scripts"
# in a checklist context (not just the build-script header references).
_found_bash_routing=0
if grep -qi 'bash scripts\|shell scripts\|\.sh files' "$DELTA_FILE" 2>/dev/null; then
    _found_bash_routing=1
fi
assert_eq "delta contains explicit bash file-type routing reference" \
    "1" "$_found_bash_routing"
assert_pass_if_clean "test_bash_file_type_routing_present"
echo ""

# ============================================================
# test_python_file_type_routing_present
# The checklist must contain Python-specific sub-criteria.
# ============================================================
echo "--- test_python_file_type_routing_present ---"
_snapshot_fail
_found_python_routing=0
if grep -qi '\.py\|python' "$DELTA_FILE" 2>/dev/null; then
    _found_python_routing=1
fi
assert_eq "delta contains Python file-type routing reference" \
    "1" "$_found_python_routing"
assert_pass_if_clean "test_python_file_type_routing_present"
echo ""

# ============================================================
# test_linter_suppression_note_present
# The checklist must instruct the reviewer to suppress findings already
# caught by project linters (ruff for Python, shellcheck for bash).
# ============================================================
echo "--- test_linter_suppression_note_present ---"
_snapshot_fail
_found_ruff=0
_found_shellcheck=0
if grep -qi 'ruff' "$DELTA_FILE" 2>/dev/null; then _found_ruff=1; fi
if grep -qi 'shellcheck' "$DELTA_FILE" 2>/dev/null; then _found_shellcheck=1; fi
assert_eq "delta references ruff (Python linter suppression)" \
    "1" "$_found_ruff"
assert_eq "delta references shellcheck (bash linter suppression)" \
    "1" "$_found_shellcheck"
assert_pass_if_clean "test_linter_suppression_note_present"
echo ""

# ============================================================
# test_bash_variable_quoting_pattern_check
# The bash-specific sub-criteria should include a check for unquoted
# variable expansion in conditionals (a common bash correctness issue
# not caught by shellcheck in all configurations).
# ============================================================
echo "--- test_bash_variable_quoting_pattern_check ---"
_snapshot_fail
_found_quoting=0
if grep -qi 'quot\|unquoted\|\$[{(]' "$DELTA_FILE" 2>/dev/null; then
    _found_quoting=1
fi
assert_eq "delta contains bash variable quoting pattern check" \
    "1" "$_found_quoting"
assert_pass_if_clean "test_bash_variable_quoting_pattern_check"
echo ""

# ============================================================
# test_python_subprocess_pattern_check
# The Python-specific sub-criteria should flag os.system usage in favor
# of subprocess, which is a project-specific correctness pattern.
# ============================================================
echo "--- test_python_subprocess_pattern_check ---"
_snapshot_fail
_found_subprocess=0
if grep -qi 'subprocess\|os\.system' "$DELTA_FILE" 2>/dev/null; then
    _found_subprocess=1
fi
assert_eq "delta contains Python subprocess/os.system pattern check" \
    "1" "$_found_subprocess"
assert_pass_if_clean "test_python_subprocess_pattern_check"
echo ""

# ============================================================
# test_scope_limits_section_present
# The Scope Limits section must exist to constrain the light reviewer.
# ============================================================
echo "--- test_scope_limits_section_present ---"
_snapshot_fail
assert_eq "delta has Scope Limits section" \
    "0" "$(grep -q 'Scope Limits' "$DELTA_FILE"; echo $?)"
assert_pass_if_clean "test_scope_limits_section_present"
echo ""

# ============================================================
# test_finding_count_limit_present
# The 0-5 findings limit must be present to keep the light tier focused.
# ============================================================
echo "--- test_finding_count_limit_present ---"
_snapshot_fail
_found_limit=0
if grep -q '0.5\|0–5\|0-5' "$DELTA_FILE" 2>/dev/null; then
    _found_limit=1
fi
assert_eq "delta contains 0-5 finding count limit" \
    "1" "$_found_limit"
assert_pass_if_clean "test_finding_count_limit_present"
echo ""

# ============================================================
# test_security_check_present
# Security check (injection, user input) must be present in Functionality.
# ============================================================
echo "--- test_security_check_present ---"
_snapshot_fail
_found_security=0
if grep -qi 'security\|sanitiz\|injection' "$DELTA_FILE" 2>/dev/null; then
    _found_security=1
fi
assert_eq "delta contains security check" \
    "1" "$_found_security"
assert_pass_if_clean "test_security_check_present"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
