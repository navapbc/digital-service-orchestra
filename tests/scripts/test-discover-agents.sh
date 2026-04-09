#!/usr/bin/env bash
# tests/scripts/test-discover-agents.sh
# TDD tests for scripts/discover-agents.sh
#
# Usage: bash tests/scripts/test-discover-agents.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/discover-agents.sh"
CONF_FILE="$PLUGIN_ROOT/config/agent-routing.conf"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-discover-agents.sh ==="

# Helper: create a temp dir with mock settings.json and routing conf
_setup_env() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    # Copy the real routing conf
    cp "$CONF_FILE" "$tmpdir/agent-routing.conf"
    echo "$tmpdir"
}

# Helper: create mock settings.json with given enabledPlugins
_write_settings() {
    local dir="$1"
    shift
    # Remaining args are plugin keys to enable
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

# ── test_all_plugins_installed ───────────────────────────────────────────────
# All plugins enabled -> each category resolves to first preference
_snapshot_fail
tmpdir="$(_setup_env)"
_CLEANUP_DIRS+=("$tmpdir")
_write_settings "$tmpdir" \
    "unit-testing@claude-code-workflows" \
    "debugging-toolkit@claude-code-workflows" \
    "error-debugging@claude-code-workflows" \
    "code-simplifier@claude-plugins-official" \
    "backend-api-security@claude-code-workflows"

output=$(bash "$SCRIPT" --settings "$tmpdir/settings.json" --routing "$tmpdir/agent-routing.conf" 2>/dev/null) || true

assert_contains "test_all_plugins_installed: test_fix_unit" "test_fix_unit=unit-testing:debugger" "$output"
assert_contains "test_all_plugins_installed: test_fix_e_to_e" "test_fix_e_to_e=debugging-toolkit:debugger" "$output"
assert_contains "test_all_plugins_installed: test_write" "test_write=unit-testing:test-automator" "$output"
assert_contains "test_all_plugins_installed: mechanical_fix" "mechanical_fix=debugging-toolkit:debugger" "$output"
assert_contains "test_all_plugins_installed: complex_debug" "complex_debug=error-debugging:error-detective" "$output"
assert_contains "test_all_plugins_installed: code_simplify" "code_simplify=code-simplifier:code-simplifier" "$output"
assert_contains "test_all_plugins_installed: security_audit" "security_audit=backend-api-security:backend-security-coder" "$output"
assert_contains "test_all_plugins_installed: llm_behavioral" "llm_behavioral=dso:bot-psychologist" "$output"
assert_pass_if_clean "test_all_plugins_installed"
rm -rf "$tmpdir"

# ── test_no_plugins_installed ────────────────────────────────────────────────
# Empty enabledPlugins -> every category resolves to general-purpose
_snapshot_fail
tmpdir="$(_setup_env)"
_CLEANUP_DIRS+=("$tmpdir")
_write_settings "$tmpdir"  # no plugins

output=$(bash "$SCRIPT" --settings "$tmpdir/settings.json" --routing "$tmpdir/agent-routing.conf" 2>/dev/null) || true

assert_contains "test_no_plugins_installed: test_fix_unit" "test_fix_unit=general-purpose" "$output"
assert_contains "test_no_plugins_installed: test_fix_e_to_e" "test_fix_e_to_e=general-purpose" "$output"
assert_contains "test_no_plugins_installed: test_write" "test_write=general-purpose" "$output"
assert_contains "test_no_plugins_installed: mechanical_fix" "mechanical_fix=general-purpose" "$output"
assert_contains "test_no_plugins_installed: complex_debug" "complex_debug=general-purpose" "$output"
assert_contains "test_no_plugins_installed: code_simplify" "code_simplify=general-purpose" "$output"
assert_contains "test_no_plugins_installed: security_audit" "security_audit=general-purpose" "$output"
# dso: agents always resolve regardless of installed plugins (short-circuit path)
assert_contains "test_no_plugins_installed: llm_behavioral (dso: short-circuit)" "llm_behavioral=dso:bot-psychologist" "$output"
assert_pass_if_clean "test_no_plugins_installed"
rm -rf "$tmpdir"

# ── test_missing_settings_json ───────────────────────────────────────────────
# No settings.json -> all general-purpose, exit 0
_snapshot_fail
tmpdir="$(_setup_env)"
_CLEANUP_DIRS+=("$tmpdir")
# No settings.json written

exit_code=0
output=$(bash "$SCRIPT" --settings "$tmpdir/nonexistent.json" --routing "$tmpdir/agent-routing.conf" 2>/dev/null) || exit_code=$?

assert_eq "test_missing_settings_json: exit code 0" "0" "$exit_code"
assert_contains "test_missing_settings_json: test_fix_unit" "test_fix_unit=general-purpose" "$output"
assert_contains "test_missing_settings_json: security_audit" "security_audit=general-purpose" "$output"
# dso: agents resolve even without settings.json
assert_contains "test_missing_settings_json: llm_behavioral (dso: short-circuit)" "llm_behavioral=dso:bot-psychologist" "$output"
assert_pass_if_clean "test_missing_settings_json"
rm -rf "$tmpdir"

# ── test_malformed_json ──────────────────────────────────────────────────────
# Invalid JSON -> all general-purpose, exit 0
_snapshot_fail
tmpdir="$(_setup_env)"
_CLEANUP_DIRS+=("$tmpdir")
echo "NOT VALID JSON {{{" > "$tmpdir/settings.json"

exit_code=0
output=$(bash "$SCRIPT" --settings "$tmpdir/settings.json" --routing "$tmpdir/agent-routing.conf" 2>/dev/null) || exit_code=$?

assert_eq "test_malformed_json: exit code 0" "0" "$exit_code"
assert_contains "test_malformed_json: test_fix_unit" "test_fix_unit=general-purpose" "$output"
assert_pass_if_clean "test_malformed_json"
rm -rf "$tmpdir"

# ── test_partial_plugins ─────────────────────────────────────────────────────
# Some plugins installed -> correct partial resolution
_snapshot_fail
tmpdir="$(_setup_env)"
_CLEANUP_DIRS+=("$tmpdir")
_write_settings "$tmpdir" \
    "unit-testing@claude-code-workflows" \
    "error-debugging@claude-code-workflows"

output=$(bash "$SCRIPT" --settings "$tmpdir/settings.json" --routing "$tmpdir/agent-routing.conf" 2>/dev/null) || true

# unit-testing available -> first pref
assert_contains "test_partial_plugins: test_fix_unit" "test_fix_unit=unit-testing:debugger" "$output"
# debugging-toolkit NOT available -> fallback
assert_contains "test_partial_plugins: test_fix_e_to_e" "test_fix_e_to_e=general-purpose" "$output"
# unit-testing available
assert_contains "test_partial_plugins: test_write" "test_write=unit-testing:test-automator" "$output"
# debugging-toolkit NOT available, code-simplifier NOT available -> fallback
assert_contains "test_partial_plugins: mechanical_fix" "mechanical_fix=general-purpose" "$output"
# error-debugging available -> first pref
assert_contains "test_partial_plugins: complex_debug" "complex_debug=error-debugging:error-detective" "$output"
# code-simplifier NOT available -> fallback
assert_contains "test_partial_plugins: code_simplify" "code_simplify=general-purpose" "$output"
# backend-api-security NOT available -> fallback
assert_contains "test_partial_plugins: security_audit" "security_audit=general-purpose" "$output"
# dso: agents resolve via short-circuit even with partial plugin installs
assert_contains "test_partial_plugins: llm_behavioral (dso: short-circuit)" "llm_behavioral=dso:bot-psychologist" "$output"
assert_pass_if_clean "test_partial_plugins"
rm -rf "$tmpdir"

# ── test_stderr_logging_format ───────────────────────────────────────────────
# Each category produces one stderr line matching the expected format
_snapshot_fail
tmpdir="$(_setup_env)"
_CLEANUP_DIRS+=("$tmpdir")
_write_settings "$tmpdir" "unit-testing@claude-code-workflows"

stderr_output=$(bash "$SCRIPT" --settings "$tmpdir/settings.json" --routing "$tmpdir/agent-routing.conf" 2>&1 >/dev/null) || true

# Count lines matching the format pattern
match_count=$(echo "$stderr_output" | grep -cE '\[agent-dispatch\] category=.*routed=.*reason=(available|fallback)') || true
expected_log_count=$(grep -cE '^[a-z_]+=.+\|general-purpose$' "$tmpdir/agent-routing.conf")
assert_eq "test_stderr_logging_format: ${expected_log_count} log lines" "$expected_log_count" "$match_count"
assert_pass_if_clean "test_stderr_logging_format"
rm -rf "$tmpdir"

# ── test_stderr_reason_available ─────────────────────────────────────────────
# When preferred plugin installed, reason=available
_snapshot_fail
tmpdir="$(_setup_env)"
_CLEANUP_DIRS+=("$tmpdir")
_write_settings "$tmpdir" "unit-testing@claude-code-workflows"

stderr_output=$(bash "$SCRIPT" --settings "$tmpdir/settings.json" --routing "$tmpdir/agent-routing.conf" 2>&1 >/dev/null) || true

assert_contains "test_stderr_reason_available: test_fix_unit has reason=available" \
    "category=test_fix_unit routed=unit-testing:debugger reason=available" "$stderr_output"
assert_pass_if_clean "test_stderr_reason_available"
rm -rf "$tmpdir"

# ── test_stderr_reason_fallback ──────────────────────────────────────────────
# When no preferred plugin, reason=fallback
_snapshot_fail
tmpdir="$(_setup_env)"
_CLEANUP_DIRS+=("$tmpdir")
_write_settings "$tmpdir"  # no plugins

stderr_output=$(bash "$SCRIPT" --settings "$tmpdir/settings.json" --routing "$tmpdir/agent-routing.conf" 2>&1 >/dev/null) || true

assert_contains "test_stderr_reason_fallback: test_fix_unit has reason=fallback" \
    "category=test_fix_unit routed=general-purpose reason=fallback" "$stderr_output"
assert_pass_if_clean "test_stderr_reason_fallback"
rm -rf "$tmpdir"

# ── test_auto_detect_new_plugin ──────────────────────────────────────────────
# Update mock settings.json between invocations, verify routing changes
_snapshot_fail
tmpdir="$(_setup_env)"
_CLEANUP_DIRS+=("$tmpdir")
_write_settings "$tmpdir"  # no plugins initially

output1=$(bash "$SCRIPT" --settings "$tmpdir/settings.json" --routing "$tmpdir/agent-routing.conf" 2>/dev/null) || true
assert_contains "test_auto_detect_new_plugin: before install fallback" "test_fix_unit=general-purpose" "$output1"

# Now install the unit-testing plugin
_write_settings "$tmpdir" "unit-testing@claude-code-workflows"

output2=$(bash "$SCRIPT" --settings "$tmpdir/settings.json" --routing "$tmpdir/agent-routing.conf" 2>/dev/null) || true
assert_contains "test_auto_detect_new_plugin: after install preferred" "test_fix_unit=unit-testing:debugger" "$output2"
assert_pass_if_clean "test_auto_detect_new_plugin"
rm -rf "$tmpdir"

# ── test_dso_short_circuit_always_resolves ───────────────────────────────────
# dso: prefixed agents bypass plugin availability check and always resolve.
# This verifies the short-circuit path at discover-agents.sh line ~104.
_snapshot_fail
tmpdir="$(_setup_env)"
_CLEANUP_DIRS+=("$tmpdir")
_write_settings "$tmpdir"  # no plugins at all

output=$(bash "$SCRIPT" --settings "$tmpdir/settings.json" --routing "$tmpdir/agent-routing.conf" 2>/dev/null) || true
stderr_output=$(bash "$SCRIPT" --settings "$tmpdir/settings.json" --routing "$tmpdir/agent-routing.conf" 2>&1 >/dev/null) || true

# dso:bot-psychologist must resolve even with zero plugins installed
assert_contains "test_dso_short_circuit_always_resolves: resolves to dso:bot-psychologist" \
    "llm_behavioral=dso:bot-psychologist" "$output"
# Must NOT fall through to general-purpose
_tmp="$output"
if [[ "$_tmp" == *"llm_behavioral=general-purpose"* ]]; then
    actual_no_fallback="fell-through"
else
    actual_no_fallback="short-circuited"
fi
assert_eq "test_dso_short_circuit_always_resolves: not general-purpose" "short-circuited" "$actual_no_fallback"
# Stderr should show reason=available (not fallback)
assert_contains "test_dso_short_circuit_always_resolves: reason=available" \
    "category=llm_behavioral routed=dso:bot-psychologist reason=available" "$stderr_output"
assert_pass_if_clean "test_dso_short_circuit_always_resolves"
rm -rf "$tmpdir"

# ── test_missing_routing_conf_exits_1 ────────────────────────────────────────
# When routing conf absent, script exits 1
_snapshot_fail
tmpdir="$(_setup_env)"
_CLEANUP_DIRS+=("$tmpdir")
_write_settings "$tmpdir"

exit_code=0
output=$(bash "$SCRIPT" --settings "$tmpdir/settings.json" --routing "$tmpdir/nonexistent.conf" 2>&1) || exit_code=$?

assert_eq "test_missing_routing_conf_exits_1: exit code 1" "1" "$exit_code"
assert_pass_if_clean "test_missing_routing_conf_exits_1"
rm -rf "$tmpdir"

# ── test_malformed_routing_conf_line_skipped ─────────────────────────────────
# Malformed lines in agent-routing.conf are skipped with stderr warning
_snapshot_fail
tmpdir="$(_setup_env)"
_CLEANUP_DIRS+=("$tmpdir")
_write_settings "$tmpdir" "unit-testing@claude-code-workflows"

# Write a routing conf with a malformed line mixed in
cat > "$tmpdir/agent-routing.conf" << 'CONF_EOF'
# comment line
test_fix_unit=unit-testing:debugger|general-purpose
THIS IS MALFORMED
test_write=unit-testing:test-automator|general-purpose
CONF_EOF

stderr_output=""
exit_code=0
output=$(bash "$SCRIPT" --settings "$tmpdir/settings.json" --routing "$tmpdir/agent-routing.conf" 2>"$tmpdir/stderr.txt") || exit_code=$?
stderr_output=$(cat "$tmpdir/stderr.txt")

assert_eq "test_malformed_routing_conf_line_skipped: exit code 0" "0" "$exit_code"
assert_contains "test_malformed_routing_conf_line_skipped: valid line processed" "test_fix_unit=unit-testing:debugger" "$output"
assert_contains "test_malformed_routing_conf_line_skipped: second valid line" "test_write=unit-testing:test-automator" "$output"
assert_contains "test_malformed_routing_conf_line_skipped: stderr warning" "skipping malformed" "$stderr_output"
assert_pass_if_clean "test_malformed_routing_conf_line_skipped"
rm -rf "$tmpdir"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
