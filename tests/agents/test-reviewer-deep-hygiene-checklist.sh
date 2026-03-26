#!/usr/bin/env bash
# tests/agents/test-reviewer-deep-hygiene-checklist.sh
# Verifies the Deep Hygiene tier reviewer (code-reviewer-deep-hygiene.md) contains:
#   1. Agent file structure: tier identity, checklist section, output constraint
#   2. Project architecture compliance sub-criteria (hook dispatcher pattern,
#      skill file structure, config-driven paths via dso-config.conf)
#   3. Plugin portability sub-criteria (hardcoded paths, host-project assumptions)
#   4. Bash/Python specific hygiene patterns
#   5. Correctness and verification scores remain N/A (not blurred into hygiene scope)
#
# Usage: bash tests/agents/test-reviewer-deep-hygiene-checklist.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_FILE="$REPO_ROOT/plugins/dso/agents/code-reviewer-deep-hygiene.md"
DELTA_FILE="$REPO_ROOT/plugins/dso/docs/workflows/prompts/reviewer-delta-deep-hygiene.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-reviewer-deep-hygiene-checklist.sh ==="
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

# ── T1: Tier identity block present ──────────────────────────────────────────
echo "--- T1: tier identity block present ---"
_snapshot_fail
assert_eq "delta has Tier Identity section" \
    "0" "$(grep -q 'Tier Identity' "$DELTA_FILE"; echo $?)"
assert_eq "agent file has Tier Identity section" \
    "0" "$(grep -q 'Tier Identity' "$AGENT_FILE"; echo $?)"
assert_pass_if_clean "T1_tier_identity_present"
echo ""

# ── T2: Checklist section present ────────────────────────────────────────────
echo "--- T2: hygiene/design/maintainability checklist section present ---"
_snapshot_fail
assert_eq "delta has Hygiene, Design, and Maintainability Checklist section" \
    "0" "$(grep -q 'Hygiene, Design, and Maintainability Checklist' "$DELTA_FILE"; echo $?)"
assert_eq "agent file has checklist section" \
    "0" "$(grep -q 'Hygiene, Design, and Maintainability Checklist' "$AGENT_FILE"; echo $?)"
assert_pass_if_clean "T2_checklist_section_present"
echo ""

# ── T3: Output constraint: correctness and verification must be N/A ───────────
echo "--- T3: output constraint enforces N/A for correctness and verification ---"
_snapshot_fail
# The output constraint section must explicitly instruct N/A for correctness+verification
_found_na_constraint=0
if grep -q "N/A" "$DELTA_FILE" && grep -qi "correctness" "$DELTA_FILE" && grep -qi "verification" "$DELTA_FILE"; then
    _found_na_constraint=1
fi
assert_eq "delta enforces N/A for correctness and verification" \
    "1" "$_found_na_constraint"
assert_pass_if_clean "T3_na_output_constraint"
echo ""

# ── T4: Project architecture compliance — hook dispatcher pattern ─────────────
echo "--- T4: project architecture compliance — hook dispatcher pattern present ---"
_snapshot_fail
_found_hook_dispatcher=0
# Must reference hook dispatcher, pre-bash/post-bash, or consolidated dispatchers
if grep -qiE "(dispatcher|pre-bash|post-bash|hook dispatcher)" "$DELTA_FILE"; then
    _found_hook_dispatcher=1
fi
assert_eq "delta contains hook dispatcher pattern check" \
    "1" "$_found_hook_dispatcher"
assert_pass_if_clean "T4_hook_dispatcher_pattern"
echo ""

# ── T5: Project architecture compliance — skill file structure ────────────────
echo "--- T5: project architecture compliance — skill file structure present ---"
_snapshot_fail
_found_skill_structure=0
# Must reference skill file structure, skill namespace, /dso: prefix, or skill qualification
if grep -qiE "(skill file|skill namespace|/dso:|dso:skill|qualified skill|SKILL\.md)" "$DELTA_FILE"; then
    _found_skill_structure=1
fi
assert_eq "delta contains skill file structure check" \
    "1" "$_found_skill_structure"
assert_pass_if_clean "T5_skill_file_structure"
echo ""

# ── T6: Project architecture compliance — config-driven paths ─────────────────
echo "--- T6: project architecture compliance — config-driven paths via dso-config.conf ---"
_snapshot_fail
_found_config_driven=0
# Must reference dso-config.conf, config-driven paths, or paths.app_dir / KEY=VALUE config
if grep -qiE "(dso-config\.conf|config.driven|paths\.app_dir|KEY=VALUE)" "$DELTA_FILE"; then
    _found_config_driven=1
fi
assert_eq "delta contains config-driven paths check (dso-config.conf)" \
    "1" "$_found_config_driven"
assert_pass_if_clean "T6_config_driven_paths"
echo ""

# ── T7: Plugin portability — hardcoded paths check ───────────────────────────
echo "--- T7: plugin portability — hardcoded paths check present ---"
_snapshot_fail
_found_hardcoded_paths=0
# Must flag hardcoded paths, hardcoded host-project assumptions, or plugin portability
if grep -qiE "(hardcod|hard-cod|plugin portab|host.project assumption)" "$DELTA_FILE"; then
    _found_hardcoded_paths=1
fi
assert_eq "delta contains hardcoded paths / plugin portability check" \
    "1" "$_found_hardcoded_paths"
assert_pass_if_clean "T7_plugin_portability_hardcoded_paths"
echo ""

# ── T8: Plugin portability — host-project assumptions mediated by config ──────
echo "--- T8: plugin portability — host-project assumptions mediated by config ---"
_snapshot_fail
_found_host_mediation=0
# Must reference mediating host-project assumptions through config, or dso-config.conf
# as a portability requirement for assumed directories/paths
if grep -qiE "(mediat|host.project.*(path|dir|config)|portab.*(config|dso-config))" "$DELTA_FILE"; then
    _found_host_mediation=1
fi
assert_eq "delta contains host-project assumption mediation check" \
    "1" "$_found_host_mediation"
assert_pass_if_clean "T8_host_project_assumption_mediation"
echo ""

# ── T9: Bash-specific hygiene patterns ───────────────────────────────────────
echo "--- T9: bash-specific hygiene patterns present ---"
_snapshot_fail
_found_bash_hygiene=0
# Must have bash-specific hygiene checks (jq-free, parse_json_field, or set -euo pipefail)
if grep -qiE "(jq.free|parse_json_field|json_build|set -euo|set -eu)" "$DELTA_FILE"; then
    _found_bash_hygiene=1
fi
assert_eq "delta contains bash-specific hygiene pattern checks" \
    "1" "$_found_bash_hygiene"
assert_pass_if_clean "T9_bash_specific_hygiene"
echo ""

# ── T10: Python-specific hygiene patterns ────────────────────────────────────
echo "--- T10: python-specific hygiene patterns present ---"
_snapshot_fail
_found_python_hygiene=0
# Must have Python-specific hygiene checks (subprocess, or fcntl.flock, or typing)
if grep -qiE "(subprocess|fcntl|typing|type hint|python)" "$DELTA_FILE"; then
    _found_python_hygiene=1
fi
assert_eq "delta contains Python-specific hygiene pattern checks" \
    "1" "$_found_python_hygiene"
assert_pass_if_clean "T10_python_specific_hygiene"
echo ""

# ── T11: Correctness and verification bleed guard ────────────────────────────
# These dimensions must remain N/A — the delta must NOT add correctness/verification
# sub-criteria disguised as hygiene items (e.g., logic errors, test coverage).
echo "--- T11: correctness/verification bleed guard (no out-of-scope criteria) ---"
_snapshot_fail
# The Output Constraint section must clearly state these dimensions are N/A
_found_na_explicit=0
if grep -qE '"N/A"' "$DELTA_FILE"; then
    _found_na_explicit=1
fi
assert_eq "delta explicitly uses \"N/A\" string (output constraint present)" \
    "1" "$_found_na_explicit"
# Verify the Output Constraint section exists
_found_output_constraint=0
if grep -qi "Output Constraint" "$DELTA_FILE"; then
    _found_output_constraint=1
fi
assert_eq "delta has Output Constraint section" \
    "1" "$_found_output_constraint"
assert_pass_if_clean "T11_na_bleed_guard"
echo ""

# ── T12: Generated agent contains all new sub-criteria sections ───────────────
echo "--- T12: generated agent file reflects delta content (build artifacts current) ---"
_snapshot_fail
# The generated agent file must match what's in the delta (key patterns propagate)
# Check that hook dispatcher pattern is present in generated file
_found_in_agent=0
if grep -qiE "(dispatcher|pre-bash|post-bash)" "$AGENT_FILE"; then
    _found_in_agent=1
fi
assert_eq "generated agent file contains hook dispatcher references from delta" \
    "1" "$_found_in_agent"
assert_pass_if_clean "T12_generated_agent_current"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
