#!/usr/bin/env bash
# tests/scripts/test-translate-recipe-to-llm-task.sh
# Behavioral tests for plugins/dso/scripts/sprint/translate-recipe-to-llm-task.sh.
#
# Testing mode: GREEN — translate-recipe-to-llm-task.sh is implemented.
#
# The script under test accepts:
#   --recipe=<name>             recipe name (e.g. "add-parameter", "normalize-imports")
#   --intent=<description>      override capability_description text (optional)
#   --param key=value           recipe parameters (zero or more; may repeat)
#   --output-format=task-prompt wraps output in structured sections
#
# Environment:
#   RECIPE_REGISTRY_PATH  — path to recipe-registry.yaml (injectable for test isolation)
#
# Usage: bash tests/scripts/test-translate-recipe-to-llm-task.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/sprint/translate-recipe-to-llm-task.sh"
TEST_FIXTURE_REGISTRY="$REPO_ROOT/tests/fixtures/recipe-registry-translate-test.yaml"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-translate-recipe-to-llm-task.sh ==="

# ── Cleanup ────────────────────────────────────────────────────────────────────
_TMPFILES=()
_TMPDIRS=()
_cleanup() {
    for f in "${_TMPFILES[@]}"; do rm -f "$f"; done
    for d in "${_TMPDIRS[@]}"; do rm -rf "$d"; done
}
trap _cleanup EXIT

# ── test_add_parameter_recipe_includes_capability_description ─────────────────
# Given: --recipe=add-parameter --intent="Add a parameter to a function signature
#        and update all callers" with two --param flags
# When:  the script is invoked
# Then:  output contains the intent text
# AND:   output contains the parameter values
_snapshot_fail
_add_param_output=""
_add_param_exit=0
_add_param_output=$(
    RECIPE_REGISTRY_PATH="$TEST_FIXTURE_REGISTRY" \
    bash "$SCRIPT" \
        --recipe=add-parameter \
        --intent="Add a parameter to a function signature and update all callers" \
        --param function_name=calculate_total \
        --param new_param=tax_rate \
    2>&1
) || _add_param_exit=$?

assert_contains "test_add_parameter_recipe_includes_capability_description: output must contain intent" \
    "Add a parameter to a function signature and update all callers" "$_add_param_output"
assert_contains "test_add_parameter_recipe_includes_capability_description: output must contain function_name value" \
    "calculate_total" "$_add_param_output"
assert_contains "test_add_parameter_recipe_includes_capability_description: output must contain new_param value" \
    "tax_rate" "$_add_param_output"
assert_pass_if_clean "test_add_parameter_recipe_includes_capability_description"

# ── test_normalize_imports_recipe_uses_registry_description ──────────────────
# Given: --recipe=normalize-imports (no --intent) with RECIPE_REGISTRY_PATH pointing
#        to the test fixture containing normalize-imports capability_description
# When:  the script is invoked
# Then:  output contains the registry capability_description text
_snapshot_fail
_norm_output=""
_norm_exit=0
_norm_output=$(
    RECIPE_REGISTRY_PATH="$TEST_FIXTURE_REGISTRY" \
    bash "$SCRIPT" \
        --recipe=normalize-imports \
    2>&1
) || _norm_exit=$?

assert_contains "test_normalize_imports_recipe_uses_registry_description: output must contain registry description" \
    "Sort and deduplicate" "$_norm_output"
assert_pass_if_clean "test_normalize_imports_recipe_uses_registry_description"

# ── test_missing_intent_and_registry_produces_fallback ───────────────────────
# Given: --recipe=unknown-recipe with RECIPE_REGISTRY_PATH pointing to a fixture
#        that does NOT have "unknown-recipe"
# When:  the script is invoked
# Then:  output contains "unknown-recipe" (recipe name appears in fallback message)
# AND:   exit code is 0
_snapshot_fail
_fallback_output=""
_fallback_exit=0
_fallback_output=$(
    RECIPE_REGISTRY_PATH="$TEST_FIXTURE_REGISTRY" \
    bash "$SCRIPT" \
        --recipe=unknown-recipe \
    2>&1
) || _fallback_exit=$?

assert_contains "test_missing_intent_and_registry_produces_fallback: output must contain recipe name" \
    "unknown-recipe" "$_fallback_output"
assert_eq "test_missing_intent_and_registry_produces_fallback: exit code must be 0" \
    "0" "$_fallback_exit"
assert_pass_if_clean "test_missing_intent_and_registry_produces_fallback"

# ── test_params_incorporated_in_output ───────────────────────────────────────
# Given: --recipe=add-parameter --intent="Add param" with --param target_file and
#        --param new_param flags
# When:  the script is invoked
# Then:  output contains the target_file parameter value
# AND:   output contains the new_param parameter value
_snapshot_fail
_params_output=""
_params_exit=0
_params_output=$(
    RECIPE_REGISTRY_PATH="$TEST_FIXTURE_REGISTRY" \
    bash "$SCRIPT" \
        --recipe=add-parameter \
        --intent="Add param" \
        --param target_file=src/api.py \
        --param new_param=timeout \
    2>&1
) || _params_exit=$?

assert_contains "test_params_incorporated_in_output: output must contain target_file value" \
    "src/api.py" "$_params_output"
assert_contains "test_params_incorporated_in_output: output must contain new_param value" \
    "timeout" "$_params_output"
assert_pass_if_clean "test_params_incorporated_in_output"

# ── test_task_prompt_format_has_required_sections ────────────────────────────
# Given: --recipe=add-parameter --intent="Add a parameter" --output-format=task-prompt
# When:  the script is invoked
# Then:  output contains "## What"
# AND:   output contains "## Why"
# AND:   output contains "## Acceptance Criteria"
_snapshot_fail
_prompt_output=""
_prompt_exit=0
_prompt_output=$(
    RECIPE_REGISTRY_PATH="$TEST_FIXTURE_REGISTRY" \
    bash "$SCRIPT" \
        --recipe=add-parameter \
        --intent="Add a parameter" \
        --output-format=task-prompt \
    2>&1
) || _prompt_exit=$?

assert_contains "test_task_prompt_format_has_required_sections: output must contain ## What" \
    "## What" "$_prompt_output"
assert_contains "test_task_prompt_format_has_required_sections: output must contain ## Why" \
    "## Why" "$_prompt_output"
assert_contains "test_task_prompt_format_has_required_sections: output must contain ## Acceptance Criteria" \
    "## Acceptance Criteria" "$_prompt_output"
assert_pass_if_clean "test_task_prompt_format_has_required_sections"

# ── (f) Missing --recipe flag → exits 1 with error ────────────────────────────
_snapshot_fail
{
    _exit_code=0
    bash "$SCRIPT" 2>/dev/null || _exit_code=$?
    assert_ne "test_missing_recipe_flag_exits_nonzero: must exit non-zero" "0" "$_exit_code"
}
assert_pass_if_clean "test_missing_recipe_flag_exits_nonzero"

print_summary
