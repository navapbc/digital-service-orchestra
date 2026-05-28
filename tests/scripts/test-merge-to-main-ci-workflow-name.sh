#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2164  # subshell/cd patterns in test setup
# tests/scripts/test-merge-to-main-ci-workflow-name.sh
# Behavioral tests verifying that merge-to-main resolves CI_WORKFLOW_NAME by:
#   1. Preferring ci.workflow_name (new config key)
#   2. Falling back to merge.ci_workflow_name (deprecated key) when the new
#      key is absent, and emitting a DEPRECATION WARNING to stderr
#   3. Resolving to empty string when both keys are absent
#
# Tests (execution-based — no source-file inspection):
#   1. test_merge_to_main_reads_ci_workflow_name
#      When ci.workflow_name is set in config, CI_WORKFLOW_NAME resolves to
#      the value of ci.workflow_name after the script is sourced.
#   2. test_merge_to_main_fallback_to_merge_ci_workflow_name
#      When ci.workflow_name is absent but merge.ci_workflow_name is set,
#      CI_WORKFLOW_NAME resolves to the merge.ci_workflow_name value.
#   3. test_merge_to_main_deprecation_warning
#      When the fallback to merge.ci_workflow_name is triggered, a
#      DEPRECATION WARNING is emitted to stderr.
#
# Test isolation: WORKFLOW_CONFIG_FILE env var injects a custom dso-config.conf
# without modifying the project config.
#
# Usage: bash tests/scripts/test-merge-to-main-ci-workflow-name.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-direct.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Trap-based cleanup for temp files created at script level
_CLEANUP_FILES=()
trap 'rm -f "${_CLEANUP_FILES[@]:-}"' EXIT

# Helper: source merge-to-main-direct.sh in library mode with a given config file
# and print CI_WORKFLOW_NAME. All stderr (including DEPRECATION warnings) is
# captured separately.
# Args: $1 = path to dso-config.conf to inject
# Prints: "CI_WORKFLOW_NAME=<value>" on stdout; DEPRECATION warnings to stderr
_resolve_ci_workflow_name() {
    local config_file="$1"
    local wrapper rc
    wrapper=$(mktemp "${TMPDIR:-/tmp}/ci-wfname.XXXXXX".sh)
    cat > "$wrapper" << WRAPPER_EOF
#!/usr/bin/env bash
export MERGE_TO_MAIN_DIRECT_LIB=1
export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
export WORKFLOW_CONFIG_FILE="$config_file"
export BRANCH="test-ci-wfname-\$\$"
# shellcheck source=/dev/null
source "$MERGE_SCRIPT"
echo "CI_WORKFLOW_NAME=\${CI_WORKFLOW_NAME:-}"
WRAPPER_EOF
    chmod +x "$wrapper"
    "$wrapper" ; rc=$?
    rm -f "$wrapper"
    return $rc
}

# =============================================================================
# Test 1: test_merge_to_main_reads_ci_workflow_name
# Given: ci.workflow_name = "my-ci-workflow" in dso-config.conf
# When: merge-to-main-direct.sh is sourced in library mode
# Then: CI_WORKFLOW_NAME resolves to "my-ci-workflow"
# =============================================================================
echo ""
echo "--- test_merge_to_main_reads_ci_workflow_name ---"

_T1_CONFIG=$(mktemp "${TMPDIR:-/tmp}/dso-config-t1.XXXXXX".conf)
_CLEANUP_FILES+=("$_T1_CONFIG")
printf 'ci.workflow_name=my-ci-workflow\n' > "$_T1_CONFIG"

_T1_OUTPUT=$(_resolve_ci_workflow_name "$_T1_CONFIG" 2>/dev/null)
_T1_VALUE=$(echo "$_T1_OUTPUT" | grep "^CI_WORKFLOW_NAME=" | cut -d= -f2-)

assert_eq "test_merge_to_main_reads_ci_workflow_name" "my-ci-workflow" "$_T1_VALUE"
rm -f "$_T1_CONFIG"

# =============================================================================
# Test 2: test_merge_to_main_fallback_to_merge_ci_workflow_name
# Given: ci.workflow_name is absent, merge.ci_workflow_name = "legacy-workflow"
# When: merge-to-main-direct.sh is sourced in library mode
# Then: CI_WORKFLOW_NAME resolves to "legacy-workflow" (via deprecated fallback)
# =============================================================================
echo ""
echo "--- test_merge_to_main_fallback_to_merge_ci_workflow_name ---"

_T2_CONFIG=$(mktemp "${TMPDIR:-/tmp}/dso-config-t2.XXXXXX".conf)
_CLEANUP_FILES+=("$_T2_CONFIG")
printf 'merge.ci_workflow_name=legacy-workflow\n' > "$_T2_CONFIG"

_T2_OUTPUT=$(_resolve_ci_workflow_name "$_T2_CONFIG" 2>/dev/null)
_T2_VALUE=$(echo "$_T2_OUTPUT" | grep "^CI_WORKFLOW_NAME=" | cut -d= -f2-)

assert_eq "test_merge_to_main_fallback_to_merge_ci_workflow_name" "legacy-workflow" "$_T2_VALUE"
rm -f "$_T2_CONFIG"

# =============================================================================
# Test 3: test_merge_to_main_deprecation_warning
# Given: ci.workflow_name is absent, merge.ci_workflow_name is set
# When: merge-to-main-direct.sh is sourced in library mode
# Then: a DEPRECATION WARNING is emitted to stderr
# =============================================================================
echo ""
echo "--- test_merge_to_main_deprecation_warning ---"

_T3_CONFIG=$(mktemp "${TMPDIR:-/tmp}/dso-config-t3.XXXXXX".conf)
_CLEANUP_FILES+=("$_T3_CONFIG")
printf 'merge.ci_workflow_name=legacy-workflow\n' > "$_T3_CONFIG"

_T3_WRAPPER=$(mktemp "${TMPDIR:-/tmp}/ci-wfname-t3.XXXXXX".sh)
_CLEANUP_FILES+=("$_T3_WRAPPER")
cat > "$_T3_WRAPPER" << WRAPPER_EOF
#!/usr/bin/env bash
export MERGE_TO_MAIN_DIRECT_LIB=1
export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
export WORKFLOW_CONFIG_FILE="$_T3_CONFIG"
export BRANCH="test-deprecation-\$\$"
# shellcheck source=/dev/null
source "$MERGE_SCRIPT"
WRAPPER_EOF
chmod +x "$_T3_WRAPPER"

_T3_STDERR=$(bash "$_T3_WRAPPER" 2>&1 >/dev/null)
_T3_HAS_DEPRECATION="false"
if echo "$_T3_STDERR" | grep -qi "deprecat"; then
    _T3_HAS_DEPRECATION="true"
fi
assert_eq "test_merge_to_main_deprecation_warning" "true" "$_T3_HAS_DEPRECATION"

rm -f "$_T3_WRAPPER" "$_T3_CONFIG"

# =============================================================================
# Test 4: test_merge_to_main_both_keys_absent_resolves_to_empty
# Given: neither ci.workflow_name nor merge.ci_workflow_name is in config
# When: merge-to-main-direct.sh is sourced in library mode
# Then: CI_WORKFLOW_NAME resolves to empty string
# =============================================================================
echo ""
echo "--- test_merge_to_main_both_keys_absent_resolves_to_empty ---"

_T4_CONFIG=$(mktemp "${TMPDIR:-/tmp}/dso-config-t4.XXXXXX".conf)
_CLEANUP_FILES+=("$_T4_CONFIG")
printf '' > "$_T4_CONFIG"  # empty config — no workflow name keys

_T4_STDERR=$(_resolve_ci_workflow_name "$_T4_CONFIG" 2>&1 >/dev/null) || true
_T4_OUTPUT=$(_resolve_ci_workflow_name "$_T4_CONFIG" 2>/dev/null)
_T4_VALUE=$(echo "$_T4_OUTPUT" | grep "^CI_WORKFLOW_NAME=" | cut -d= -f2-)

assert_eq "test_merge_to_main_both_keys_absent_resolves_to_empty" "" "$_T4_VALUE"

_T4_NO_DEPRECATION="true"
if echo "$_T4_STDERR" | grep -qi "deprecat"; then
    _T4_NO_DEPRECATION="false"
fi
assert_eq "test_merge_to_main_both_keys_absent_no_deprecation_warning" "true" "$_T4_NO_DEPRECATION"

rm -f "$_T4_CONFIG"

# =============================================================================
print_summary
