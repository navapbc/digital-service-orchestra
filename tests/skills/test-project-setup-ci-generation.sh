#!/usr/bin/env bash
# tests/skills/test-project-setup-ci-generation.sh
# Tests that plugins/dso/skills/project-setup/SKILL.md Step 5 is updated
# to invoke ci-generator.sh when no CI workflows exist, instead of copying
# the static ci.example.yml template.
#
# Validates:
#   - Step 5 references ci-generator.sh (or ci_generator) as the action
#     when no workflows exist
#   - SKILL.md describes passing project-detect.sh --suites output to the generator
#   - SKILL.md does NOT fall back to ci.example.yml copy when suites are discovered
#   - SKILL.md references YAML validation (actionlint or yaml.safe_load)
#   - SKILL.md describes the speed_class=unknown prompting flow
#
# Usage: bash tests/skills/test-project-setup-ci-generation.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/project-setup/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-project-setup-ci-generation.sh ==="

# test_skill_step5_invokes_ci_generator_when_no_workflows:
# SKILL.md Step 5 must reference ci-generator.sh (or ci_generator) as the
# action taken when no CI workflows exist (instead of copying a static template).
_snapshot_fail
if grep -qiE "ci-generator\.sh|ci_generator" "$SKILL_MD" 2>/dev/null; then
    has_ci_generator="found"
else
    has_ci_generator="missing"
fi
assert_eq "test_skill_step5_invokes_ci_generator_when_no_workflows" "found" "$has_ci_generator"
assert_pass_if_clean "test_skill_step5_invokes_ci_generator_when_no_workflows"

# test_skill_step5_passes_suites_json_to_generator:
# SKILL.md must describe passing project-detect.sh --suites output to the generator.
# The step should mention using the suites JSON from project-detect.sh as input.
_snapshot_fail
if grep -qiE "project-detect\.sh.*--suites|--suites.*project-detect\.sh|suites.*json.*generator|generator.*suites.*json" "$SKILL_MD" 2>/dev/null; then
    has_suites_input="found"
else
    has_suites_input="missing"
fi
assert_eq "test_skill_step5_passes_suites_json_to_generator" "found" "$has_suites_input"
assert_pass_if_clean "test_skill_step5_passes_suites_json_to_generator"

# test_skill_step5_does_not_copy_static_template_when_suites_available:
# SKILL.md must not describe falling back to a ci.example.yml copy when
# suites are discovered — the generator replaces the static template copy path.
# We check that the condition for copying ci.example.yml is explicitly tied to
# the absence of suites (not unconditionally copying it).
#
# The current Step 5 text says:
#   "No .github/workflows/*.yml found: copies examples/ci.example.yml"
# After the update, this path should be conditional on no suites being found,
# OR the ci.example.yml fallback should be removed in favor of the generator.
# We test that the old unconditional copy description is gone — replaced by
# generator invocation as the primary path.
_snapshot_fail
# The old unconditional copy behavior reads: "copies `examples/ci.example.yml`"
# without any mention of suites. After the update, ci-generator.sh should be
# the primary path when suites are available.
# We verify: if ci-generator.sh is referenced, the static copy must be conditional
# (qualified by "no suites" or "fallback" language) rather than being the default.
old_copy_unconditional=$(grep -c "copies.*ci\.example\.yml" "$SKILL_MD" 2>/dev/null) || old_copy_unconditional=0
ci_generator_present=$(grep -cE "ci-generator\.sh|ci_generator" "$SKILL_MD" 2>/dev/null) || ci_generator_present=0
# Pass if: ci-generator is referenced AND the old unconditional copy is gone
if [[ "$ci_generator_present" -ge 1 && "$old_copy_unconditional" -eq 0 ]]; then
    static_copy_removed="yes"
else
    static_copy_removed="no"
fi
assert_eq "test_skill_step5_does_not_copy_static_template_when_suites_available" "yes" "$static_copy_removed"
assert_pass_if_clean "test_skill_step5_does_not_copy_static_template_when_suites_available"

# test_skill_step5_runs_actionlint_or_yaml_safe_load:
# SKILL.md must reference YAML validation — either actionlint or yaml.safe_load —
# as a validation step after generating the CI workflow.
_snapshot_fail
if grep -qiE "actionlint|yaml\.safe_load" "$SKILL_MD" 2>/dev/null; then
    has_yaml_validation="found"
else
    has_yaml_validation="missing"
fi
assert_eq "test_skill_step5_runs_actionlint_or_yaml_safe_load" "found" "$has_yaml_validation"
assert_pass_if_clean "test_skill_step5_runs_actionlint_or_yaml_safe_load"

# test_skill_step5_speed_class_prompting_documented:
# SKILL.md must describe the speed_class=unknown prompting flow — when discovered
# test suites have speed_class=unknown, the user should be asked to classify them.
_snapshot_fail
if grep -qiE "speed_class.*unknown|unknown.*speed_class" "$SKILL_MD" 2>/dev/null; then
    has_speed_class_prompting="found"
else
    has_speed_class_prompting="missing"
fi
assert_eq "test_skill_step5_speed_class_prompting_documented" "found" "$has_speed_class_prompting"
assert_pass_if_clean "test_skill_step5_speed_class_prompting_documented"

print_summary
