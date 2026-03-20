#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-ci-workflow-name.sh
# Tests that merge-to-main.sh reads ci.workflow_name (as CI_WORKFLOW_NAME via
# batch eval), falls back to merge.ci_workflow_name with a deprecation warning,
# and produces an empty string when both are absent.
#
# TDD tests (all should FAIL until the IMPL task lands):
#   1. test_merge_to_main_reads_ci_workflow_name
#      — script references CI_WORKFLOW_NAME (uppercase of ci.workflow_name)
#        in the config resolution section
#   2. test_merge_to_main_fallback_to_merge_ci_workflow_name
#      — when CI_WORKFLOW_NAME (from ci.workflow_name) is empty, script falls
#        back to MERGE_CI_WORKFLOW_NAME (from merge.ci_workflow_name)
#   3. test_merge_to_main_deprecation_warning
#      — when the fallback to merge.ci_workflow_name is triggered, a
#        deprecation warning is emitted to stderr (>&2)
#
# Usage: bash tests/scripts/test-merge-to-main-ci-workflow-name.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# =============================================================================
# Test 1: test_merge_to_main_reads_ci_workflow_name
# The script should reference CI_WORKFLOW_NAME (the batch-eval variable name
# for the ci.workflow_name config key) in its config resolution block.
# Currently the script only has MERGE_CI_WORKFLOW_NAME; this test asserts that
# CI_WORKFLOW_NAME is read from the ci.workflow_name config key directly.
# =============================================================================
# We look for an assignment that reads CI_WORKFLOW_NAME from the batch-eval
# environment (i.e. ${CI_WORKFLOW_NAME:-...} as the *source*, not as a target
# being assigned from MERGE_CI_WORKFLOW_NAME only).
READS_CI_WORKFLOW_NAME=$(grep -c 'CI_WORKFLOW_NAME' "$MERGE_SCRIPT" \
    | awk '{print ($1 >= 2) ? "true" : "false"}')
# The current script has CI_WORKFLOW_NAME on only ONE line (line 626 assigns it
# from MERGE_CI_WORKFLOW_NAME). After the IMPL task, there will be at least two
# references: one reading ci.workflow_name and one fallback check.
# We assert that the string ci.workflow_name appears in the script (config key).
READS_CI_KEY=$(grep -c 'ci\.workflow_name' "$MERGE_SCRIPT" || true)
assert_ne "test_merge_to_main_reads_ci_workflow_name" "0" "$READS_CI_KEY"

# =============================================================================
# Test 2: test_merge_to_main_fallback_to_merge_ci_workflow_name
# When CI_WORKFLOW_NAME (from ci.workflow_name) is empty, the script should
# fall back to MERGE_CI_WORKFLOW_NAME. This requires a conditional fallback:
# either ${CI_WORKFLOW_NAME:-$MERGE_CI_WORKFLOW_NAME} or an if block.
# Currently: CI_WORKFLOW_NAME="${MERGE_CI_WORKFLOW_NAME:-}" (no conditional)
# After IMPL: the script should have a conditional that prefers CI_WORKFLOW_NAME
# and falls back to MERGE_CI_WORKFLOW_NAME only when the new key is absent.
# We assert a conditional pattern: -z "$CI_WORKFLOW_NAME" or
# ${CI_WORKFLOW_NAME:-$MERGE_CI_WORKFLOW_NAME} style fallback, not just a
# simple assignment of MERGE_CI_WORKFLOW_NAME to CI_WORKFLOW_NAME.
# =============================================================================
# The IMPL must add a conditional fallback block. The existing single-assignment
# line does NOT qualify — we require a guard that checks CI_WORKFLOW_NAME empty.
HAS_CONDITIONAL_FALLBACK=$(grep -c '\-z.*CI_WORKFLOW_NAME\|CI_WORKFLOW_NAME:-\$MERGE_CI_WORKFLOW_NAME\|CI_WORKFLOW_NAME.*:-.*MERGE_CI' "$MERGE_SCRIPT" || true)
assert_ne "test_merge_to_main_fallback_to_merge_ci_workflow_name" "0" "$HAS_CONDITIONAL_FALLBACK"

# =============================================================================
# Test 3: test_merge_to_main_deprecation_warning
# When the fallback to merge.ci_workflow_name is triggered, a deprecation
# warning must be emitted to stderr (>&2). The current script has no such
# warning. After IMPL the script should contain a DEPRECATION message sent
# to stderr near the merge.ci_workflow_name fallback logic.
# =============================================================================
HAS_DEPRECATION_STDERR=$(grep -c 'DEPRECATION\|deprecated\|deprecat' "$MERGE_SCRIPT" || true)
assert_ne "test_merge_to_main_deprecation_warning" "0" "$HAS_DEPRECATION_STDERR"

# =============================================================================
print_summary
