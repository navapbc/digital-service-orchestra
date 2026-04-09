#!/usr/bin/env bash
# tests/scripts/test-agent-routing-conf.sh
# TDD tests for config/agent-routing.conf
#
# Usage: bash tests/scripts/test-agent-routing-conf.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: These tests are expected to FAIL until agent-routing.conf is created.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
CONF_FILE="$PLUGIN_ROOT/config/agent-routing.conf"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-agent-routing-conf.sh ==="

# ── test_routing_conf_exists ─────────────────────────────────────────────────
# agent-routing.conf must exist at config/agent-routing.conf
_snapshot_fail
if [[ -f "$CONF_FILE" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_routing_conf_exists: file exists" "exists" "$actual_exists"
assert_pass_if_clean "test_routing_conf_exists"

# ── test_routing_conf_format_valid ───────────────────────────────────────────
# Every non-comment, non-empty line must match: ^[a-z_]+=.+|general-purpose$
_snapshot_fail
if [[ -f "$CONF_FILE" ]]; then
    bad_lines=0
    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        # REVIEW-DEFENSE(finding-2): _tmp is intentionally reused across test functions; in bash [[ =~ ]] context
        # it is overwritten on each iteration — no cross-function leakage occurs. Standard bash test file practice.
        # BUGFIX(finding-1): In bash ERE ([[ =~ ]]), \| matches literal backslash-pipe, not alternation. To match a
        # literal pipe character in the string, use [|]. Pattern intent: key=<agents>[|]general-purpose
        _tmp="$line"; [[ "$_tmp" =~ ^[a-z_]+=.+[|]general-purpose$ ]] || (( bad_lines++ ))
    done < "$CONF_FILE"
    if [[ "$bad_lines" -eq 0 ]]; then
        actual_format="valid"
    else
        actual_format="invalid"
    fi
else
    actual_format="invalid"
fi
assert_eq "test_routing_conf_format_valid: all data lines match format" "valid" "$actual_format"
assert_pass_if_clean "test_routing_conf_format_valid"

# ── test_all_expected_categories_present ─────────────────────────────────────
# All 11 categories must be defined.
EXPECTED_CATEGORIES=(test_fix_unit test_fix_e_to_e test_write mechanical_fix complex_debug code_simplify security_audit llm_behavioral approach_evaluation test_quality_review design_creation)
_snapshot_fail
for cat in "${EXPECTED_CATEGORIES[@]}"; do
    if [[ -f "$CONF_FILE" ]] && grep -qE "^${cat}=" "$CONF_FILE"; then
        actual_cat="present"
    else
        actual_cat="missing"
    fi
    assert_eq "test_all_expected_categories_present: category '$cat'" "present" "$actual_cat"
done
assert_pass_if_clean "test_all_expected_categories_present"

# ── test_fallback_sentinel_always_last ───────────────────────────────────────
# Each routing chain must end with general-purpose.
_snapshot_fail
if [[ -f "$CONF_FILE" ]]; then
    sentinel_ok="yes"
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        # Extract the value after the =
        value="${line#*=}"
        # Check last element in pipe-delimited chain
        last="${value##*|}"
        if [[ "$last" != "general-purpose" ]]; then
            sentinel_ok="no"
        fi
    done < "$CONF_FILE"
else
    sentinel_ok="no"
fi
assert_eq "test_fallback_sentinel_always_last: every chain ends with general-purpose" "yes" "$sentinel_ok"
assert_pass_if_clean "test_fallback_sentinel_always_last"

# ── test_header_documents_interface_contract ─────────────────────────────────
# Header must contain key interface contract terms.
_snapshot_fail
if [[ -f "$CONF_FILE" ]]; then
    header=$(head -30 "$CONF_FILE")
else
    header=""
fi
for term in "format" "category" "preference chain" "fallback"; do
    _tmp="$header"
    shopt -s nocasematch
    if [[ "$_tmp" =~ $term ]]; then
        actual_term="present"
    else
        actual_term="missing"
    fi
    shopt -u nocasematch
    assert_eq "test_header_documents_interface_contract: term '$term' in header" "present" "$actual_term"
done
assert_pass_if_clean "test_header_documents_interface_contract"

# ── test_llm_behavioral_routes_to_bot_psychologist ───────────────────────────
# discover-agents.sh must resolve llm_behavioral to a chain containing dso:bot-psychologist
_snapshot_fail
_tmp_routing_dir="$(mktemp -d)"
trap 'rm -rf "$_tmp_routing_dir"' EXIT
_tmp_routing_conf="$_tmp_routing_dir/agent-routing.conf"

if [[ -f "$CONF_FILE" ]]; then
    cp "$CONF_FILE" "$_tmp_routing_conf"
else
    # If conf doesn't exist yet, create a minimal stand-in so discover-agents.sh
    # can at least run — the category-presence test above will already have failed.
    printf "# stub\n" > "$_tmp_routing_conf"
fi

_discover_script="$PLUGIN_ROOT/plugins/dso/scripts/discover-agents.sh"
_tmp_settings="$_tmp_routing_dir/settings.json"
printf '{"enabledPlugins":{}}' > "$_tmp_settings"

_routing_output=""
if [[ -x "$_discover_script" ]]; then
    _routing_output="$(bash "$_discover_script" \
        --settings "$_tmp_settings" \
        --routing "$_tmp_routing_conf" 2>/dev/null)" || true
fi

# Extract the resolved agent for llm_behavioral
_resolved_agent=""
if [[ -n "$_routing_output" ]]; then
    _resolved_agent="$(printf '%s\n' "$_routing_output" \
        | grep '^llm_behavioral=' | cut -d= -f2)" || true
fi

if grep -q 'dso:bot-psychologist' <<< "$_resolved_agent"; then
    actual_llm_routing="routes_to_bot_psychologist"
else
    actual_llm_routing="missing_or_wrong: '$_resolved_agent'"
fi
assert_eq "test_llm_behavioral_routes_to_bot_psychologist: resolved agent contains dso:bot-psychologist" \
    "routes_to_bot_psychologist" "$actual_llm_routing"
assert_pass_if_clean "test_llm_behavioral_routes_to_bot_psychologist"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
