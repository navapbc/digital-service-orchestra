#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-fallback-integration.sh
# Integration test: routing table → discover-agents.sh → fallback prompt coverage
#
# Validates the complete chain from agent routing through prompt dispatch.
# Tests 6 scenarios covering all-disabled routing, prompt file coverage,
# dispatch contract, placeholder substitution, error-detective preference,
# and single-plugin routing.
#
# Usage: bash lockpick-workflow/tests/scripts/test-fallback-integration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DISCOVER_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/discover-agents.sh"
CONF_FILE="$REPO_ROOT/lockpick-workflow/config/agent-routing.conf"
PROMPTS_DIR="$REPO_ROOT/lockpick-workflow/prompts/fallback"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-fallback-integration.sh ==="

# All 7 categories from agent-routing.conf
ALL_CATEGORIES="test_fix_unit test_fix_e_to_e test_write mechanical_fix complex_debug code_simplify security_audit"

# Helper: create a temp dir with real routing conf
_setup_env() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    cp "$CONF_FILE" "$tmpdir/agent-routing.conf"
    echo "$tmpdir"
}

# Helper: create mock settings.json with given enabledPlugins
_write_settings() {
    local dir="$1"
    shift
    local plugins_json="{"
    local first=true
    for plugin in "$@"; do
        if [ "$first" = true ]; then
            first=false
        else
            plugins_json+=","
        fi
        plugins_json+="\"$plugin\": true"
    done
    plugins_json+="}"

    cat > "$dir/settings.json" << SETTINGS_EOF
{
  "enabledPlugins": $plugins_json
}
SETTINGS_EOF
}

# ── Scenario 1: All-disabled routing ──────────────────────────────────────────
# With empty plugins, all 7 categories resolve to general-purpose
_snapshot_fail
tmpdir="$(_setup_env)"
_CLEANUP_DIRS+=("$tmpdir")
_write_settings "$tmpdir"  # no plugins

output=$(bash "$DISCOVER_SCRIPT" --settings "$tmpdir/settings.json" --routing "$tmpdir/agent-routing.conf" 2>/dev/null) || true

for cat in $ALL_CATEGORIES; do
    assert_contains "all_disabled: $cat=general-purpose" "$cat=general-purpose" "$output"
done
assert_pass_if_clean "scenario_1_all_disabled_routing"
rm -rf "$tmpdir"

# ── Scenario 2: Prompt file coverage ─────────────────────────────────────────
# All 7 category prompt files exist under prompts/fallback/
_snapshot_fail

for cat in $ALL_CATEGORIES; do
    if [[ -f "$PROMPTS_DIR/$cat.md" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: prompt_coverage: %s.md not found at %s\n" "$cat" "$PROMPTS_DIR" >&2
    fi
done
assert_pass_if_clean "scenario_2_prompt_file_coverage"

# ── Scenario 3: Dispatch contract ────────────────────────────────────────────
# Every prompt file contains the {context} placeholder
_snapshot_fail

for cat in $ALL_CATEGORIES; do
    prompt_file="$PROMPTS_DIR/$cat.md"
    if [[ -f "$prompt_file" ]]; then
        if grep -q '{context}' "$prompt_file"; then
            (( ++PASS ))
        else
            (( ++FAIL ))
            printf "FAIL: dispatch_contract: %s.md missing {context} placeholder\n" "$cat" >&2
        fi
    else
        (( ++FAIL ))
        printf "FAIL: dispatch_contract: %s.md not found (skipping contract check)\n" "$cat" >&2
    fi
done
assert_pass_if_clean "scenario_3_dispatch_contract"

# ── Scenario 4: Placeholder substitution ─────────────────────────────────────
# Perform sed-based placeholder substitution on test_fix_unit.md and assert
# no {placeholder} tokens remain
_snapshot_fail

prompt_file="$PROMPTS_DIR/test_fix_unit.md"
if [[ -f "$prompt_file" ]]; then
    substituted=$(sed \
        -e 's/{test_command}/tests\/unit\/test_example.py::test_foo/g' \
        -e 's/{exit_code}/1/g' \
        -e 's/{stderr_tail}/AssertionError: expected True/g' \
        -e 's/{changed_files}/src\/services\/example.py/g' \
        -e 's/{context}/Unit test regression after refactor/g' \
        "$prompt_file")

    # Check no {placeholder} tokens remain
    remaining=$(echo "$substituted" | grep -oE '\{[a-z_]+\}' | head -1) || true
    if [[ -z "$remaining" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: placeholder_substitution: residual placeholder found: %s\n" "$remaining" >&2
    fi
else
    (( ++FAIL ))
    printf "FAIL: placeholder_substitution: test_fix_unit.md not found\n" >&2
fi
assert_pass_if_clean "scenario_4_placeholder_substitution"

# ── Scenario 5: Error-detective preference ────────────────────────────────────
# With error-debugging plugin enabled, complex_debug resolves to error-detective.
# Without it, complex_debug resolves to general-purpose.
# Also validates complex_debug.md contains required placeholders.
_snapshot_fail

# 5a: Preferred agent with error-debugging enabled
tmpdir="$(_setup_env)"
_CLEANUP_DIRS+=("$tmpdir")
_write_settings "$tmpdir" "error-debugging@claude-code-workflows"

output=$(bash "$DISCOVER_SCRIPT" --settings "$tmpdir/settings.json" --routing "$tmpdir/agent-routing.conf" 2>/dev/null) || true
assert_contains "error_detective_pref: complex_debug=error-debugging:error-detective" \
    "complex_debug=error-debugging:error-detective" "$output"
rm -rf "$tmpdir"

# 5b: Fallback with empty plugins
tmpdir="$(_setup_env)"
_CLEANUP_DIRS+=("$tmpdir")
_write_settings "$tmpdir"  # no plugins

output=$(bash "$DISCOVER_SCRIPT" --settings "$tmpdir/settings.json" --routing "$tmpdir/agent-routing.conf" 2>/dev/null) || true
assert_contains "error_detective_fallback: complex_debug=general-purpose" \
    "complex_debug=general-purpose" "$output"
rm -rf "$tmpdir"

# 5c: complex_debug.md contains required domain-specific placeholders
prompt_file="$PROMPTS_DIR/complex_debug.md"
if [[ -f "$prompt_file" ]]; then
    for placeholder in '{error_output}' '{stack_trace}' '{affected_files}'; do
        if grep -q "$placeholder" "$prompt_file"; then
            (( ++PASS ))
        else
            (( ++FAIL ))
            printf "FAIL: error_detective_placeholders: complex_debug.md missing %s\n" "$placeholder" >&2
        fi
    done
else
    (( ++FAIL ))
    printf "FAIL: error_detective_placeholders: complex_debug.md not found\n" >&2
fi
assert_pass_if_clean "scenario_5_error_detective_preference"

# ── Scenario 6: Single-plugin routing ────────────────────────────────────────
# With only unit-testing enabled, test_fix_unit resolves to unit-testing:debugger
# while other non-unit-testing categories resolve to general-purpose
_snapshot_fail
tmpdir="$(_setup_env)"
_CLEANUP_DIRS+=("$tmpdir")
_write_settings "$tmpdir" "unit-testing@claude-code-workflows"

output=$(bash "$DISCOVER_SCRIPT" --settings "$tmpdir/settings.json" --routing "$tmpdir/agent-routing.conf" 2>/dev/null) || true

# unit-testing categories resolve to their preferred agents
assert_contains "single_plugin: test_fix_unit=unit-testing:debugger" \
    "test_fix_unit=unit-testing:debugger" "$output"
assert_contains "single_plugin: test_write=unit-testing:test-automator" \
    "test_write=unit-testing:test-automator" "$output"

# non-unit-testing categories fall back to general-purpose
assert_contains "single_plugin: test_fix_e_to_e=general-purpose" \
    "test_fix_e_to_e=general-purpose" "$output"
assert_contains "single_plugin: mechanical_fix=general-purpose" \
    "mechanical_fix=general-purpose" "$output"
assert_contains "single_plugin: complex_debug=general-purpose" \
    "complex_debug=general-purpose" "$output"
assert_contains "single_plugin: code_simplify=general-purpose" \
    "code_simplify=general-purpose" "$output"
assert_contains "single_plugin: security_audit=general-purpose" \
    "security_audit=general-purpose" "$output"

assert_pass_if_clean "scenario_6_single_plugin_routing"
rm -rf "$tmpdir"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
